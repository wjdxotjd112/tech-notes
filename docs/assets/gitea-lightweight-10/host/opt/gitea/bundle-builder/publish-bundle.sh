#!/bin/bash
set -euo pipefail

release_info="${1:-release-info.yaml}"
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
: "${NEXUS_PASSWORD:?Set NEXUS_RUNNER_PASSWORD in Gitea Actions Secrets}"
[[ "${RELEASE_KEEP_COUNT}" =~ ^[1-9][0-9]*$ ]]

require_commands awk cmp curl grep jq mktemp paste sha256sum sort stat sudo

[[ -s "${release_info}" ]] || {
  echo "Release information was not found: ${release_info}" >&2
  exit 1
}

manifest_id="$(yaml_value "${release_info}" manifest_id)"
release="$(yaml_value "${release_info}" release)"
release_line="$(yaml_value "${release_info}" release_line)"
release_tag="$(yaml_value "${release_info}" release_tag)"
git_commit="$(yaml_value "${release_info}" git_commit)"
git_ref="$(yaml_value "${release_info}" git_ref)"

[[ "${manifest_id}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
[[ "${release}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ "${release_line}" == "${release%.*}" ]]
[[ "${release_tag}" == "v${release}" ]]
[[ "${git_commit}" =~ ^[0-9a-f]{40}$ ]]
[[ "${git_ref}" == "${release_tag}" ]]

bundle_name="contrabass-engine-deploy.tar"
bundle_file="${BUNDLE_WORK_DIR}/${manifest_id}.tar"
checksum_file="${bundle_file}.sha256"
version_path="releases/${release_line}/${release_tag}"
bundle_path="${version_path}/${bundle_name}"

local_bundle_ready=false
if [[ -s "${bundle_file}" && -s "${checksum_file}" ]]; then
  local_bundle_ready=true
  bundle_sha256="$(sha256sum "${bundle_file}" | awk '{print $1}')"
  expected_sha256="$(awk '{print $1; exit}' "${checksum_file}")"
  bundle_size_bytes="$(stat -c '%s' "${bundle_file}")"
  [[ "${bundle_sha256}" == "${expected_sha256}" ]] || {
    echo "Local bundle checksum mismatch." >&2
    exit 1
  }
elif [[ -e "${bundle_file}" || -e "${checksum_file}" ]]; then
  echo "Incomplete local bundle: ${bundle_file}" >&2
  exit 1
fi

repository_url="${NEXUS_URL%/}/repository/${BUNDLE_REPOSITORY}"
bundle_url="${repository_url}/${bundle_path}"
existing_checksum_file="$(mktemp)"
trap 'rm -f -- "${existing_checksum_file}"' EXIT
remote_checksum=""
if nexus_get_optional "${bundle_url}.sha256" "${existing_checksum_file}"; then
  remote_checksum="$(awk '{print $1; exit}' "${existing_checksum_file}")"
fi

if [[ "${local_bundle_ready}" == true ]]; then
  if [[ -n "${remote_checksum}" ]]; then
    [[ "${remote_checksum}" == "${bundle_sha256}" ]] || {
      echo "An immutable bundle already exists with different content: ${bundle_path}" >&2
      exit 1
    }
    echo "Reuse existing Nexus bundle: ${bundle_path}"
  else
    echo "Upload bundle: ${bundle_path}"
    nexus_curl -fsS --retry "${HTTP_RETRY_COUNT}" --upload-file "${bundle_file}" "${bundle_url}"
    printf '%s  %s\n' "${bundle_sha256}" "${bundle_name}" > "${existing_checksum_file}"
    nexus_curl -fsS --retry "${HTTP_RETRY_COUNT}" --upload-file "${existing_checksum_file}" "${bundle_url}.sha256"
  fi
else
  [[ "${remote_checksum}" =~ ^[0-9a-f]{64}$ ]] || {
    echo "No complete local or remote bundle exists: ${bundle_path}" >&2
    exit 1
  }
  bundle_sha256="${remote_checksum}"
  echo "Finalize existing Nexus bundle without rebuilding: ${bundle_path}"
fi

remote_size="$(nexus_curl -fsSI "${bundle_url}" \
  | awk 'BEGIN {IGNORECASE=1} /^Content-Length:/ {gsub("\r", "", $2); print $2; exit}')"
remote_sha256="$(nexus_curl -fsS "${bundle_url}.sha256" | awk '{print $1; exit}')"
if [[ "${local_bundle_ready}" == false ]]; then
  bundle_size_bytes="${remote_size}"
fi
[[ "${bundle_size_bytes}" =~ ^[1-9][0-9]*$ ]]
[[ "${remote_size}" == "${bundle_size_bytes}" ]]
[[ "${remote_sha256}" == "${bundle_sha256}" ]]

bundle_release_info="$(mktemp)"
assets_file="$(mktemp)"
response_file="$(mktemp)"
line_index="$(mktemp)"
all_index="$(mktemp)"
keep_file="$(mktemp)"
cleanup() {
  rm -f -- "${existing_checksum_file}" "${bundle_release_info}" "${assets_file}" "${response_file}" \
    "${line_index}" "${all_index}" "${keep_file}"
}
trap cleanup EXIT

printf '%s\n' \
  'schema_version: 2' \
  "manifest_id: ${manifest_id}" \
  "release: \"${release}\"" \
  "release_line: \"${release_line}\"" \
  "release_tag: ${release_tag}" \
  "git_commit: ${git_commit}" \
  "git_ref: ${git_ref}" \
  'git_ref_type: tag' \
  "bundle_repository: ${BUNDLE_REPOSITORY}" \
  "bundle_path: ${bundle_path}" \
  "bundle_sha256: ${bundle_sha256}" \
  "bundle_size_bytes: ${bundle_size_bytes}" \
  > "${bundle_release_info}"

if nexus_get_optional "${repository_url}/${version_path}/release-info.yaml" "${response_file}"; then
  cmp -s "${response_file}" "${bundle_release_info}" || {
    echo "An immutable release-info.yaml already exists with different content." >&2
    exit 1
  }
else
  nexus_curl -fsS --upload-file "${bundle_release_info}" \
    "${repository_url}/${version_path}/release-info.yaml"
fi

: > "${assets_file}"
continuation_token=""
while true; do
  request=(-fsS --get --data-urlencode "repository=${BUNDLE_REPOSITORY}")
  if [[ -n "${continuation_token}" ]]; then
    request+=(--data-urlencode "continuationToken=${continuation_token}")
  fi
  nexus_curl "${request[@]}" "${NEXUS_URL%/}/service/rest/v1/search/assets" -o "${response_file}"
  jq -r '.items[] | [.id, .path] | @tsv' "${response_file}" >> "${assets_file}"
  continuation_token="$(jq -r '.continuationToken // empty' "${response_file}")"
  [[ -n "${continuation_token}" ]] || break
done

awk -F '\t' -v line="${release_line}" '
  {
    path=$2
    sub(/^\/+/, "", path)
    split(path, item, "/")
    if (item[1] == "releases" && item[2] == line && item[3] ~ /^v[0-9]+\.[0-9]+\.[0-9]+$/) {
      print substr(item[3], 2)
    }
  }
' "${assets_file}" | sort -Vu -r > "${line_index}"

printf '%s\n' "${release}" >> "${line_index}"
sort -Vu -r -o "${line_index}" "${line_index}"

awk -F '\t' '
  {
    path=$2
    sub(/^\/+/, "", path)
    split(path, item, "/")
    if (item[1] == "releases" && item[2] ~ /^[0-9]+\.[0-9]+$/ && item[3] ~ /^v[0-9]+\.[0-9]+\.[0-9]+$/) {
      print substr(item[3], 2)
    }
  }
' "${assets_file}" | sort -Vu -r > "${all_index}"

printf '%s\n' "${release}" >> "${all_index}"
sort -Vu -r -o "${all_index}" "${all_index}"

awk -v limit="${RELEASE_KEEP_COUNT}" 'NR <= limit {print "v" $0}' "${line_index}" > "${keep_file}"
latest_line_release="$(awk 'NR == 1 {print; exit}' "${line_index}")"
current_release="$(awk 'NR == 1 {print; exit}' "${all_index}")"

update_manifest_pointer() {
  local channel="$1" manifest_copy
  manifest_copy="${response_file}"
  local manifest_url="${NEXUS_URL%/}/repository/${MANIFEST_REPOSITORY}"
  nexus_curl -fsS "${manifest_url}/${version_path}/manifest.yaml" -o "${manifest_copy}"
  [[ "$(file_sha256 "${manifest_copy}")" == "$(yaml_value "${release_info}" manifest_sha256)" ]]
  nexus_curl -fsS --upload-file "${manifest_copy}" "${manifest_url}/channels/${channel}/manifest.yaml"
  nexus_curl -fsS --upload-file "${release_info}" "${manifest_url}/channels/${channel}/release-info.yaml"
}

if [[ "${release}" == "${latest_line_release}" ]]; then
  printf '%s\n' "${NEXUS_PASSWORD}" |
  sudo -n /usr/local/sbin/update-release-alias "${release_line}" "${release_tag}"
  update_manifest_pointer "${release_line}"
  nexus_curl -fsS --upload-file "${bundle_release_info}" \
    "${repository_url}/channels/${release_line}/release-info.yaml"
  nexus_curl -fsS "${repository_url}/channels/${release_line}/release-info.yaml" \
    | cmp -s "${bundle_release_info}" -
fi

if [[ "${release}" == "${current_release}" ]]; then
  printf '%s\n' "${NEXUS_PASSWORD}" |
  sudo -n /usr/local/sbin/update-release-alias current "${release_tag}"
  update_manifest_pointer current
  nexus_curl -fsS --upload-file "${bundle_release_info}" \
    "${repository_url}/channels/current/release-info.yaml"
  nexus_curl -fsS "${repository_url}/channels/current/release-info.yaml" \
    | cmp -s "${bundle_release_info}" -
fi

while IFS= read -r indexed_release; do
  [[ -n "${indexed_release}" ]] || continue
  indexed_tag="v${indexed_release}"
  grep -Fxq "${indexed_tag}" "${keep_file}" && continue

  echo "Delete old ${release_line} release: ${indexed_tag}"
  while IFS=$'\t' read -r asset_id asset_path; do
    normalized_path="${asset_path#/}"
    [[ "${normalized_path}" == "releases/${release_line}/${indexed_tag}/"* ]] || continue
    encoded_asset_id="$(jq -rn --arg value "${asset_id}" '$value | @uri')"
    nexus_curl -fsS -X DELETE \
      "${NEXUS_URL%/}/service/rest/v1/assets/${encoded_asset_id}"
  done < "${assets_file}"
done < "${line_index}"

nexus_curl -fsS --upload-file "${keep_file}" \
  "${repository_url}/channels/${release_line}/retained-releases.txt"
nexus_curl -fsS "${repository_url}/channels/${release_line}/retained-releases.txt" \
  | cmp -s "${keep_file}" -

downloaded_info="$(nexus_curl -fsS "${repository_url}/${version_path}/release-info.yaml")"
cmp -s "${bundle_release_info}" <(printf '%s\n' "${downloaded_info}")

if [[ "${local_bundle_ready}" == true ]]; then
  rm -f -- "${bundle_file}" "${checksum_file}"
  echo "Removed verified local bundle after Nexus upload."
fi

echo "Bundle  : ${bundle_url}"
echo "Channel : ${repository_url}/channels/${release_line}/release-info.yaml"
echo "Current : ${repository_url}/channels/current/release-info.yaml"
echo "Retained: $(paste -sd ', ' "${keep_file}")"
