#!/bin/bash
set -euo pipefail

source "${BUNDLE_BUILDER_DIR:?}/common.sh"
release_tag="${1:?Release tag required}"
source_dir="$(realpath -e -- "${2:?Source directory required}")"
[[ "${source_dir}" == "${RUNNER_WORKSPACE}/"* ]] || {
  echo "Source must be inside RUNNER_WORKSPACE." >&2
  exit 1
}
[[ -d "${source_dir}/.git" && ! -L "${source_dir}/.git" ]]
source_git() { runuser -u "${RUNNER_USER}" -- git -C "${source_dir}" "$@"; }

: "${NEXUS_URL:?}"
: "${NEXUS_USER:?}"
: "${NEXUS_PASSWORD:?}"
: "${NEXUS_BASE_IMAGE:?}"
: "${TEMPLATE_DIR:?}"
: "${BUNDLE_WORK_DIR:?}"
: "${RAW_CACHE_DIR:?}"
NEXUS_URL="${NEXUS_URL%/}"
NEXUS_REGISTRY="${NEXUS_URL#http://}"
NEXUS_REGISTRY="${NEXUS_REGISTRY#https://}"

require_commands curl git nerdctl sha256sum tar awk jq install mktemp ln cp chown runuser realpath

for required_file in \
  "${NEXUS_BASE_IMAGE}" \
  "${TEMPLATE_DIR}/compose.yaml" \
  "${TEMPLATE_DIR}/nexus.properties" \
  "${TEMPLATE_DIR}/setup-private-environment.sh" \
  "${TEMPLATE_DIR}/deploy.sh"; do
  [[ -f "${required_file}" ]] || {
    echo "File not found: ${required_file}" >&2
    exit 1
  }
done

if [[ ! "${release_tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid release tag: ${release_tag}" >&2
  exit 1
fi

install -d -m 0755 "${RAW_CACHE_DIR}"
install -d -o root -g "${RUNNER_GROUP}" -m 2775 "${BUNDLE_WORK_DIR}"
latest_info="$(mktemp)"
latest_manifest="$(mktemp)"
work_root=""
download_tmp=""

cleanup() {
  rm -f -- "${latest_info}" "${latest_manifest}"
  [[ -z "${download_tmp}" ]] || rm -f -- "${download_tmp}"
  if [[ -n "${work_root}" && -d "${work_root}" ]]; then
    rm -rf -- "${work_root}"
  fi
}
trap cleanup EXIT

release_version="${release_tag#v}"
release_info_path="releases/${release_version%.*}/${release_tag}/release-info.yaml"

nexus_curl -fsSL \
  "${NEXUS_URL}/repository/${MANIFEST_REPOSITORY}/${release_info_path}" \
  -o "${latest_info}"

manifest_id="$(yaml_value "${latest_info}" manifest_id)"
git_ref="$(yaml_value "${latest_info}" git_ref)"
git_commit="$(yaml_value "${latest_info}" git_commit)"
manifest_path="$(yaml_value "${latest_info}" manifest_path)"
expected_manifest_sha="$(yaml_value "${latest_info}" manifest_sha256)"

[[ "${manifest_id}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
if [[ "${git_ref}" != "${release_tag}" ]]; then
  echo "Release tag mismatch: expected ${release_tag}, got ${git_ref}" >&2
  exit 1
fi
[[ "${manifest_path}" == "releases/${release_version%.*}/${release_tag}/manifest.yaml" ]] || {
  echo "Manifest path does not match release tag." >&2
  exit 1
}
[[ "${git_commit}" =~ ^[0-9a-f]{40}$ ]] || {
  echo "Invalid Git commit: ${git_commit}" >&2
  exit 1
}
[[ "${expected_manifest_sha}" =~ ^[0-9a-f]{64}$ ]] || {
  echo "Invalid manifest checksum." >&2
  exit 1
}

bundle_name="contrabass-engine-deploy"
bundle_tar="${BUNDLE_WORK_DIR}/${manifest_id}.tar"
checksum_file="${bundle_tar}.sha256"
bundle_url="${NEXUS_URL}/repository/${BUNDLE_REPOSITORY}/releases/${release_version%.*}/${release_tag}/${bundle_name}.tar"
[[ ! -L "${bundle_tar}" && ! -L "${checksum_file}" ]] || { echo 'Bundle outputs must not be symlinks.' >&2; exit 1; }
remote_bundle_status="$(nexus_curl -sSI -o /dev/null -w '%{http_code}' "${bundle_url}")"
remote_checksum_status="$(nexus_curl -sSI -o /dev/null -w '%{http_code}' "${bundle_url}.sha256")"
if [[ "${remote_bundle_status}" == 200 && "${remote_checksum_status}" == 200 ]]; then
  # A re-run can switch PR labels from skip to full. Restore the SAME TAR,
  # rather than rebuilding it with newer templates or tools.
  expected_bundle_sha="$(nexus_curl -fsS "${bundle_url}.sha256" | awk '{print $1; exit}')"
  [[ "${expected_bundle_sha}" =~ ^[0-9a-f]{64}$ ]]
  if [[ ! -s "${bundle_tar}" ]]; then
    download_tmp="$(mktemp "${BUNDLE_WORK_DIR}/.published-bundle.XXXXXX")"
    nexus_curl -fsSL --retry "${HTTP_RETRY_COUNT}" \
      "${bundle_url}" -o "${download_tmp}"
    [[ "$(file_sha256 "${download_tmp}")" == "${expected_bundle_sha}" ]] || {
      echo 'Published bundle checksum mismatch.' >&2; exit 1;
    }
    mv -- "${download_tmp}" "${bundle_tar}"
    download_tmp=""
  fi
  [[ "$(file_sha256 "${bundle_tar}")" == "${expected_bundle_sha}" ]]
  printf '%s  %s\n' "${expected_bundle_sha}" "${manifest_id}.tar" > "${checksum_file}"
  chown "${RUNNER_USER}:${RUNNER_GROUP}" "${bundle_tar}" "${checksum_file}"
  echo "Reuse published bundle without rebuilding: ${bundle_url}"
  exit 0
fi
[[ "${remote_bundle_status}" == 404 && "${remote_checksum_status}" == 404 ]] || {
  echo "Incomplete or inaccessible Nexus bundle: tar=${remote_bundle_status}, sha256=${remote_checksum_status}" >&2
  exit 1
}

if [[ -s "${bundle_tar}" && -s "${checksum_file}" ]]; then
  expected_bundle_sha="$(awk '{print $1; exit}' "${checksum_file}")"
  actual_bundle_sha="$(sha256sum "${bundle_tar}" | awk '{print $1}')"
  if [[ "${actual_bundle_sha}" == "${expected_bundle_sha}" ]]; then
    chown "${RUNNER_USER}:${RUNNER_GROUP}" "${bundle_tar}" "${checksum_file}"
    echo "Reuse existing bundle: ${bundle_tar}"
    exit 0
  fi
  echo "Existing bundle checksum mismatch: ${bundle_tar}" >&2
  exit 1
fi
if [[ -e "${bundle_tar}" || -e "${checksum_file}" ]]; then
  echo "Incomplete bundle output already exists: ${bundle_tar}" >&2
  exit 1
fi

work_root="$(mktemp -d "${BUNDLE_WORK_DIR}/.${bundle_name}.work.XXXXXX")"
bundle_dir="${work_root}/${bundle_name}"
install -d -m 0755 \
  "${bundle_dir}/git" \
  "${bundle_dir}/images" \
  "${bundle_dir}/nexus" \
  "${bundle_dir}/raw"

nexus_curl -fsSL \
  "${NEXUS_URL}/repository/${MANIFEST_REPOSITORY}/${manifest_path}" \
  -o "${latest_manifest}"

actual_manifest_sha="$(sha256sum "${latest_manifest}" | awk '{print $1}')"
[[ "${actual_manifest_sha}" == "${expected_manifest_sha}" ]] || {
  echo "Manifest checksum mismatch." >&2
  exit 1
}

nexus_image="$(awk -F'"' '/^  image: / {print $2; exit}' "${latest_manifest}")"
expected_archive_sha="$(awk -F'"' '/^  archive_sha256: / {print $2; exit}' "${latest_manifest}")"
[[ "${nexus_image}" == */*:* && "${expected_archive_sha}" =~ ^[0-9a-f]{64}$ ]] || {
  echo "Invalid Nexus image metadata in manifest." >&2
  exit 1
}
[[ "$(file_sha256 "${NEXUS_BASE_IMAGE}")" == "${expected_archive_sha}" ]] || {
  echo "Nexus image archive checksum does not match manifest." >&2
  exit 1
}
tar -Oxf "${NEXUS_BASE_IMAGE}" manifest.json \
  | jq -e --arg image "${nexus_image#docker.io/}" \
      '[.[].RepoTags[]] | index($image) != null' >/dev/null || {
  echo "Nexus image archive tag does not match manifest: ${nexus_image}" >&2
  exit 1
}

install -m 0644 "${latest_manifest}" "${bundle_dir}/manifest.yaml"
install -m 0644 "${latest_info}" "${bundle_dir}/release-info.yaml"
install -m 0644 "${NEXUS_BASE_IMAGE}" "${bundle_dir}/nexus/nexus-image.tar"
install -m 0644 "${TEMPLATE_DIR}/compose.yaml" "${bundle_dir}/nexus/compose.yaml"
install -m 0644 "${TEMPLATE_DIR}/nexus.properties" "${bundle_dir}/nexus/nexus.properties"
install -m 0755 "${TEMPLATE_DIR}/setup-private-environment.sh" "${bundle_dir}/setup-private-environment.sh"
install -m 0755 "${TEMPLATE_DIR}/deploy.sh" "${bundle_dir}/deploy.sh"

echo "[1/5] Reuse Workflow source: ${git_ref}"
[[ "$(source_git rev-parse HEAD)" == "${git_commit}" ]]
[[ "$(source_git rev-list --count HEAD)" == "1" ]]
[[ -z "$(source_git status --porcelain)" ]]
[[ "$(runuser -u "${RUNNER_USER}" -- sha256sum "${source_dir}/release/manifest.yaml" | awk '{print $1}')" == "${expected_manifest_sha}" ]]

# Copy with Runner permissions; keep the shallow .git but not credentials/hooks.
chmod 0711 "${work_root}"
install -d -o "${RUNNER_USER}" -g "${RUNNER_GROUP}" -m 0700 "${bundle_dir}/git/init-container"
runuser -u "${RUNNER_USER}" -- cp -a --no-preserve=ownership \
  "${source_dir}/." "${bundle_dir}/git/init-container/"
chown root:root "${bundle_dir}/git/init-container"
chmod 0700 "${bundle_dir}/git/init-container"
copied_git="${bundle_dir}/git/init-container/.git"
[[ -d "${copied_git}" && ! -L "${copied_git}" ]]
rm -f -- "${copied_git}/config"
printf '[core]\n\trepositoryformatversion = 0\n\tbare = false\n\tfilemode = true\n' > "${copied_git}/config"
printf '[remote "origin"]\n\turl = %s\n' "${GITEA_REPO_URL}" >> "${copied_git}/config"
rm -rf -- "${copied_git}/hooks"
chown -hR root:root "${bundle_dir}/git/init-container"
chmod -R go-w "${bundle_dir}/git/init-container"
chmod 0755 "${bundle_dir}/git/init-container"

echo "[2/5] Restore Raw artifacts from SHA256 cache"
awk -F'"' '
  /^  - path:/ {path=$2}
  /^    sha256:/ && path != "" {print path "|" $2; path=""}
' "${bundle_dir}/manifest.yaml" |
while IFS='|' read -r artifact_path expected_sha; do
  [[ "${expected_sha}" =~ ^[0-9a-f]{64}$ ]] || {
    echo "Invalid artifact checksum: ${artifact_path}" >&2
    exit 1
  }
  case "/${artifact_path}/" in
    */../*|*/./*)
      echo "Invalid artifact path: ${artifact_path}" >&2
      exit 1
      ;;
  esac
  [[ "${artifact_path}" != /* ]] || {
    echo "Absolute artifact path is not allowed: ${artifact_path}" >&2
    exit 1
  }

  cache_file="${RAW_CACHE_DIR}/${expected_sha}"
  destination="${bundle_dir}/raw/${artifact_path}"
  install -d -m 0755 "$(dirname "${destination}")"

  if [[ -f "${cache_file}" ]] &&
     [[ "$(sha256sum "${cache_file}" | awk '{print $1}')" == "${expected_sha}" ]]; then
    echo "  [cache] ${artifact_path}"
  else
    echo "  [download] ${artifact_path}"
    cache_temp="$(mktemp "${RAW_CACHE_DIR}/.${expected_sha}.XXXXXX")"
    if ! nexus_curl -fsSL --retry "${HTTP_RETRY_COUNT}" \
      "${NEXUS_URL}/repository/${RAW_REPOSITORY}/${artifact_path}" \
      -o "${cache_temp}"; then
      rm -f -- "${cache_temp}"
      echo "Download failed: ${artifact_path}" >&2
      exit 1
    fi
    actual_sha="$(sha256sum "${cache_temp}" | awk '{print $1}')"
    [[ "${actual_sha}" == "${expected_sha}" ]] || {
      rm -f -- "${cache_temp}"
      echo "Checksum mismatch: ${artifact_path}" >&2
      exit 1
    }
    chmod 0644 "${cache_temp}"
    mv -f -- "${cache_temp}" "${cache_file}"
  fi

  ln "${cache_file}" "${destination}" 2>/dev/null ||
    cp --reflink=auto -- "${cache_file}" "${destination}"
done

echo "[3/5] Verify and pull Docker images"
export DOCKER_CONFIG="${work_root}/registry-auth"
install -d -m 0700 "${DOCKER_CONFIG}"
printf '%s' "${NEXUS_PASSWORD}" | nerdctl login --username "${NEXUS_USER}" --password-stdin "${NEXUS_REGISTRY}" >/dev/null
image_map="${bundle_dir}/images/image-map.txt"
awk -F'"' '
  /^images:/ {in_images=1; next}
  in_images && /^  - name:/ {name=$2}
  in_images && /^    tag:/ {tag=$2}
  in_images && /^    digest:/ {print name "|" tag "|" $2; name=""; tag=""}
' "${bundle_dir}/manifest.yaml" |
while IFS='|' read -r image_name image_tag expected_digest; do
  source_ref="${NEXUS_REGISTRY}/${DOCKER_REPOSITORY}/${image_name}:${image_tag}"
  registry_path="${DOCKER_REPOSITORY}/${image_name}"
  actual_digest="$(nexus_curl -fsSI \
    -H 'Accept: application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.index.v1+json' \
    "${NEXUS_URL}/v2/${registry_path}/manifests/${image_tag}" \
    | awk 'BEGIN{IGNORECASE=1} /^Docker-Content-Digest:/{gsub("\\r", "", $2); print $2; exit}')"
  [[ "${actual_digest}" == "${expected_digest}" ]] || {
    echo "Digest mismatch: ${image_name}:${image_tag}" >&2
    exit 1
  }
  echo "  ${source_ref}"
  pinned_ref="${source_ref%:*}@${expected_digest}"
  nerdctl pull "${pinned_ref}"
  nerdctl tag "${pinned_ref}" "${source_ref}"
  printf '%s|%s|%s|%s\n' \
    "${source_ref}" "${image_name}" "${image_tag}" "${expected_digest}" \
    >> "${image_map}"
done

echo "[4/5] Save Docker images"
mapfile -t image_refs < <(awk -F'|' '{print $1}' "${image_map}")
[[ "${#image_refs[@]}" -gt 0 ]] || {
  echo "No Docker images were found in the manifest." >&2
  exit 1
}
nerdctl save -o "${bundle_dir}/images/release-images.tar" "${image_refs[@]}"

echo "[5/5] Create archive and outer TAR checksum"
download_tmp="$(mktemp "${BUNDLE_WORK_DIR}/.bundle-output.XXXXXX")"
tar -C "${work_root}" -cf "${download_tmp}" "${bundle_name}"
mv -T -- "${download_tmp}" "${bundle_tar}"
download_tmp=""
(
  cd "${BUNDLE_WORK_DIR}"
  sha256sum "${manifest_id}.tar" > "${manifest_id}.tar.sha256"
)

chown "${RUNNER_USER}:${RUNNER_GROUP}" "${bundle_tar}" "${checksum_file}"

rm -rf -- "${work_root}"
work_root=""

echo
echo "Bundle : ${bundle_tar}"
echo "SHA256: ${checksum_file}"
du -sh "${bundle_tar}"
