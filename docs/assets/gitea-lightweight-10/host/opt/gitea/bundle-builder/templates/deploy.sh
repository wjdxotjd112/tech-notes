#!/bin/bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 || $# -ne 2 || "$2" != "--accept-eula" ]]; then
  echo "Usage: sudo ./deploy.sh <PRIVATE_NEXUS_IP_OR_DNS> --accept-eula" >&2
  exit 1
fi

nexus_host="$1"
export NEXUS_PORT="${NEXUS_PORT:-55555}"
export NEXUS_HOME="${NEXUS_HOME:-/opt/nexus}"
export NEXUS_DATA="${NEXUS_DATA:-${NEXUS_HOME}/nexus-data}"
export DEPLOY_CONTAINER_NAME="${DEPLOY_CONTAINER_NAME:-okestro-os-ansible}"
bundle_dir="$(cd "$(dirname "$0")" && pwd)"

[[ "${nexus_host}" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || {
  echo "Enter an IP address or DNS name without a scheme or port." >&2
  exit 1
}

PRIVATE_IMAGE_CLEANUP_DIR="$(mktemp -d)"
export PRIVATE_IMAGE_CLEANUP_DIR
trap 'rm -rf -- "${PRIVATE_IMAGE_CLEANUP_DIR}"' EXIT

cleanup_imported_image_refs() {
  local address namespace ref digest source_ref name tag expected target_ref archive index_sha used_refs
  local -a cleanup_ctr
  [[ -s "${PRIVATE_IMAGE_CLEANUP_DIR}/connection" && -f "${PRIVATE_IMAGE_CLEANUP_DIR}/before" ]] || return 1
  {
    IFS= read -r address
    IFS= read -r namespace
  } < "${PRIVATE_IMAGE_CLEANUP_DIR}/connection"
  cleanup_ctr=(ctr --address "${address}" --namespace "${namespace}")
  "${cleanup_ctr[@]}" images list | awk 'NR > 1 {print $1 "|" $3}' > "${PRIVATE_IMAGE_CLEANUP_DIR}/after"
  cut -d '|' -f 1 "${PRIVATE_IMAGE_CLEANUP_DIR}/before" > "${PRIVATE_IMAGE_CLEANUP_DIR}/existing"
  : > "${PRIVATE_IMAGE_CLEANUP_DIR}/candidates"
  : > "${PRIVATE_IMAGE_CLEANUP_DIR}/digests"
  : > "${PRIVATE_IMAGE_CLEANUP_DIR}/keep"
  while IFS='|' read -r source_ref name tag expected; do
    [[ -n "${source_ref}" && "${expected}" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
    target_ref="${nexus_host}:${NEXUS_PORT}/docker-hosted/${name}:${tag}"
    printf '%s\n' "${target_ref}" >> "${PRIVATE_IMAGE_CLEANUP_DIR}/keep"
    if grep -Fxq "${target_ref}|${expected}" "${PRIVATE_IMAGE_CLEANUP_DIR}/after"; then
      printf '%s\n' "${source_ref}" >> "${PRIVATE_IMAGE_CLEANUP_DIR}/candidates"
      printf '%s\n' "${expected}" >> "${PRIVATE_IMAGE_CLEANUP_DIR}/digests"
    fi
  done < "${bundle_dir}/images/image-map.txt"
  ref="$(awk -F'"' '/^  image: / {print $2; exit}' "${bundle_dir}/manifest.yaml")"
  printf '%s\n' "${ref}" "${ref#docker.io/}" "docker.io/${ref#docker.io/}" >> "${PRIVATE_IMAGE_CLEANUP_DIR}/keep"
  awk -F '|' -v ref="${ref}" '$1 == ref || "docker.io/" $1 == ref || $1 == "docker.io/" ref {print $2}' \
    "${PRIVATE_IMAGE_CLEANUP_DIR}/after" >> "${PRIVATE_IMAGE_CLEANUP_DIR}/digests"
  for archive in "${bundle_dir}/images/release-images.tar" "${bundle_dir}/nexus/nexus-image.tar"; do
    if index_sha="$(tar -xOf "${archive}" index.json 2>/dev/null | sha256sum)"; then
      printf 'import@sha256:%s\n' "${index_sha%% *}" >> "${PRIVATE_IMAGE_CLEANUP_DIR}/candidates"
    fi
  done
  echo 'Remove temporary imported image references'
  while IFS='|' read -r ref digest; do
    grep -Fxq "${ref}" "${PRIVATE_IMAGE_CLEANUP_DIR}/existing" && continue
    grep -Fxq "${ref}" "${PRIVATE_IMAGE_CLEANUP_DIR}/keep" && continue
    if ! grep -Fxq "${ref}" "${PRIVATE_IMAGE_CLEANUP_DIR}/candidates"; then
      [[ "${ref}" =~ ^sha256:[0-9a-f]{64}$ ]] || continue
      grep -Fxq "${digest}" "${PRIVATE_IMAGE_CLEANUP_DIR}/digests" || continue
    fi
    used_refs="$("${cleanup_ctr[@]}" containers list | awk 'NR > 1 {print $2}')"
    grep -Fxq "${ref}" <<< "${used_refs}" && continue
    "${cleanup_ctr[@]}" images remove "${ref}"
  done < "${PRIVATE_IMAGE_CLEANUP_DIR}/after"
}

echo "[1/3] Prepare private Nexus and import release artifacts"
bash "${bundle_dir}/setup-private-environment.sh" "${nexus_host}" --accept-eula

echo "[2/3] Start Ansible deploy container"
bash "${bundle_dir}/git/init-container/contrabass-engine/install.sh" "${nexus_host}:${NEXUS_PORT}" --anonymous

echo "[3/3] Verify services"
curl -kfsS --connect-timeout 10 "https://${nexus_host}:${NEXUS_PORT}/service/rest/v1/status" >/dev/null
[[ "$(nerdctl container inspect -f '{{.State.Status}}' nexus)" == running ]]
[[ "$(nerdctl container inspect -f '{{.State.Status}}' "${DEPLOY_CONTAINER_NAME}")" == running ]]
cleanup_imported_image_refs
echo "Private Nexus and ${DEPLOY_CONTAINER_NAME} are running."
