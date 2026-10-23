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

echo "[1/3] Prepare private Nexus and import release artifacts"
bash "${bundle_dir}/setup-private-environment.sh" "${nexus_host}" --accept-eula

echo "[2/3] Start Ansible deploy container"
bash "${bundle_dir}/git/init-container/contrabass-engine/install.sh" "${nexus_host}:${NEXUS_PORT}" --anonymous

echo "[3/3] Verify services"
curl -kfsS --connect-timeout 10 "https://${nexus_host}:${NEXUS_PORT}/service/rest/v1/status" >/dev/null
[[ "$(nerdctl container inspect -f '{{.State.Status}}' nexus)" == running ]]
[[ "$(nerdctl container inspect -f '{{.State.Status}}' "${DEPLOY_CONTAINER_NAME}")" == running ]]
echo "Private Nexus and ${DEPLOY_CONTAINER_NAME} are running."
