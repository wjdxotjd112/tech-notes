#!/bin/bash
set -euo pipefail

manifest="${1:-release/manifest.yaml}"
release_info="${2:-release-info.yaml}"

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
: "${NEXUS_PASSWORD:?Set NEXUS_RUNNER_PASSWORD in Gitea Actions Secrets}"
: "${GITEA_COMMIT:?Missing Gitea commit}"

require_commands awk curl date git sha256sum sort mktemp cmp

[[ -s "${manifest}" ]] || {
  echo "Manifest was not found: ${manifest}" >&2
  exit 1
}

release="$(yaml_value "${manifest}" release)"
[[ "${release}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "Invalid release version: ${release}" >&2
  exit 1
}
grep -Eq '^schema_version:[[:space:]]*2$' "${manifest}"
grep -Eq '^  image: "[^"]+"$' "${manifest}"
if grep -q '^  archive_sha256:' "${manifest}"; then
  grep -Eq '^  archive_sha256: "[0-9a-f]{64}"$' "${manifest}"
fi
grep -q '^artifacts:$' "${manifest}"
grep -q '^images:$' "${manifest}"
grep -q '^  - path:' "${manifest}"
grep -q '^  - name:' "${manifest}"
if grep -E '^[[:space:]]+(sha256|digest):[[:space:]]*"' "${manifest}" \
  | grep -Ev '"(sha256:)?[0-9a-f]{64}"$'; then
  echo "Invalid artifact checksum or image digest." >&2
  exit 1
fi

release_line="${release%.*}"
release_tag="v${release}"
[[ "${GITEA_REF_NAME:-}" == "${release_tag}" ]] || {
  echo "Tag and manifest release do not match: ${GITEA_REF_NAME:-empty} != ${release_tag}" >&2
  exit 1
}

short_sha="${GITEA_COMMIT:0:7}"
commit_epoch="$(git -C source show -s --format=%ct HEAD)"
commit_time="$(TZ=Asia/Seoul date -d "@${commit_epoch}" +%Y%m%d-%H%M%S)"
manifest_id="manifest-v${release}-${commit_time}-${short_sha}"
manifest_sha256="$(file_sha256 "${manifest}")"
version_path="releases/${release_line}/${release_tag}"
manifest_path="${version_path}/manifest.yaml"

printf '%s\n' \
  'schema_version: 2' \
  "manifest_id: ${manifest_id}" \
  "release: \"${release}\"" \
  "release_line: \"${release_line}\"" \
  "release_tag: ${release_tag}" \
  "git_commit: ${GITEA_COMMIT}" \
  "git_ref: ${GITEA_REF_NAME}" \
  'git_ref_type: tag' \
  "manifest_sha256: ${manifest_sha256}" \
  "manifest_path: ${manifest_path}" \
  > "${release_info}"

repository_url="${NEXUS_URL%/}/repository/${MANIFEST_REPOSITORY}"
existing_manifest="$(mktemp)"
downloaded_manifest="$(mktemp)"
cleanup() {
  rm -f -- "${existing_manifest}" "${downloaded_manifest}"
}
trap cleanup EXIT

if nexus_get_optional "${repository_url}/${manifest_path}" "${existing_manifest}"; then
  existing_sha256="$(sha256sum "${existing_manifest}" | awk '{print $1}')"
  [[ "${existing_sha256}" == "${manifest_sha256}" ]] || {
    echo "An immutable manifest already exists with different content: ${manifest_path}" >&2
    exit 1
  }
  echo "Reuse existing manifest: ${manifest_path}"
else
  nexus_curl -fsS --upload-file "${manifest}" \
    "${repository_url}/${manifest_path}"
fi

if nexus_get_optional "${repository_url}/${version_path}/release-info.yaml" "${existing_manifest}"; then
  cmp -s "${existing_manifest}" "${release_info}" || {
    echo "Release metadata already exists with different content; use a new tag." >&2
    exit 1
  }
else
  nexus_curl -fsS --upload-file "${release_info}" \
    "${repository_url}/${version_path}/release-info.yaml"
fi

nexus_curl -fsS "${repository_url}/${manifest_path}" -o "${downloaded_manifest}"
test "$(sha256sum "${downloaded_manifest}" | awk '{print $1}')" = "${manifest_sha256}"
rm -f -- "${downloaded_manifest}"

echo "Published manifest : ${manifest_id}"
echo "Release line       : ${release_line}"
