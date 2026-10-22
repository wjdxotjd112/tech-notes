#!/bin/bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root." >&2
  exit 1
fi

if [[ $# -ne 2 || "$2" != "--accept-eula" ]]; then
  echo "Usage: $0 <PRIVATE_NEXUS_IP_OR_DNS> --accept-eula" >&2
  exit 1
fi

NEXUS_HOST="$1"
[[ "${NEXUS_HOST}" != *"://"* && "${NEXUS_HOST}" != *":"* ]] || {
  echo "Enter only an IP address or DNS name without a scheme or port." >&2
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_DIR="${SCRIPT_DIR}"
NEXUS_HOME="${NEXUS_HOME:-/opt/nexus}"
NEXUS_DATA="${NEXUS_DATA:-${NEXUS_HOME}/nexus-data}"
NEXUS_PORT="${NEXUS_PORT:-55555}"
NEXUS_HEAP="${NEXUS_HEAP:-2703m}"
NEXUS_DIRECT_MEMORY="${NEXUS_DIRECT_MEMORY:-2703m}"
[[ "${NEXUS_PORT}" =~ ^[0-9]+$ && "${NEXUS_PORT}" -ge 1 && "${NEXUS_PORT}" -le 65535 ]]
NEXUS_REGISTRY="${NEXUS_HOST}:${NEXUS_PORT}"
NEXUS_ENDPOINT="https://${NEXUS_REGISTRY}"
API="${NEXUS_ENDPOINT}/service/rest/v1"

MANIFEST="${BUNDLE_DIR}/manifest.yaml"
RELEASE_INFO="${BUNDLE_DIR}/release-info.yaml"
IMAGE_MAP="${BUNDLE_DIR}/images/image-map.txt"
IMAGE_ARCHIVE="${BUNDLE_DIR}/images/release-images.tar"
NEXUS_IMAGE_ARCHIVE="${BUNDLE_DIR}/nexus/nexus-image.tar"

for required_file in \
  "${MANIFEST}" \
  "${RELEASE_INFO}" \
  "${IMAGE_MAP}" \
  "${IMAGE_ARCHIVE}" \
  "${NEXUS_IMAGE_ARCHIVE}" \
  "${BUNDLE_DIR}/nexus/compose.yaml" \
  "${BUNDLE_DIR}/nexus/nexus.properties"; do
  [[ -f "${required_file}" ]] || {
    echo "File not found: ${required_file}" >&2
    exit 1
  }
done

NEXUS_IMAGE="$(awk -F'"' '/^  image: / {print $2; exit}' "${MANIFEST}")"
expected_nexus_sha="$(awk -F'"' '/^  archive_sha256: / {print $2; exit}' "${MANIFEST}")"
[[ "${NEXUS_IMAGE}" == */*:* && "${expected_nexus_sha}" =~ ^[0-9a-f]{64}$ ]] || {
  echo "Nexus image or archive checksum is missing from manifest.yaml." >&2
  exit 1
}
export NEXUS_IMAGE NEXUS_PORT NEXUS_DATA NEXUS_HEAP NEXUS_DIRECT_MEMORY

echo "[1/9] Check release artifacts (outer TAR must be verified before extraction)"
[[ "$(sha256sum "${NEXUS_IMAGE_ARCHIVE}" | awk '{print $1}')" == "${expected_nexus_sha}" ]] || {
  echo "Nexus image archive does not match manifest.yaml." >&2
  exit 1
}

runtime_ready=false
if command -v containerd >/dev/null \
  && command -v nerdctl >/dev/null \
  && command -v runc >/dev/null \
  && systemctl is-active --quiet containerd \
  && nerdctl info >/dev/null 2>&1; then
  runtime_ready=true
fi

echo "[2/9] Prepare container runtime"
modprobe overlay
modprobe br_netfilter
printf '%s\n' \
  'net.ipv4.ip_forward = 1' \
  'net.bridge.bridge-nf-call-iptables = 1' \
  | install -m 0644 /dev/stdin /etc/sysctl.d/99-private-nexus.conf
sysctl --system >/dev/null

if [[ "${runtime_ready}" == "true" ]]; then
  echo "Container runtime is already ready."
else
  runtime_file() {
    local path
    path="$(awk -F'"' -v prefix="ansible-runtime/$1" \
      '/^  - path:/ && index($2, prefix) == 1 {print $2; exit}' "${MANIFEST}")"
    [[ -n "${path}" && -f "${BUNDLE_DIR}/raw/${path}" ]] || {
      echo "Runtime artifact not found in bundle: ${prefix}" >&2
      return 1
    }
    printf '%s\n' "${BUNDLE_DIR}/raw/${path}"
  }

  tar -zxf "$(runtime_file containerd-)" -C /usr/local
  install -m 0755 "$(runtime_file runc.amd64)" /usr/local/bin/runc
  tar -zxf "$(runtime_file nerdctl-)" -C /usr/local/bin
  install -d -m 0755 /opt/cni/bin /etc/cni/net.d /etc/containerd /etc/nerdctl
  tar -zxf "$(runtime_file cni-plugins-)" -C /opt/cni/bin

  install -m 0644 \
    "${BUNDLE_DIR}/git/init-container/contrabass-engine/containerd.service" \
    /etc/systemd/system/containerd.service
  install -m 0644 \
    "${BUNDLE_DIR}/git/init-container/contrabass-engine/nerdctl.toml" \
    /etc/nerdctl/nerdctl.toml

  containerd config default > /etc/containerd/config.toml
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
  systemctl daemon-reload
  systemctl enable --now containerd
fi

systemctl is-active --quiet containerd
nerdctl info >/dev/null

echo "[3/9] Configure private registry TLS"
install -d -m 0755 "/etc/containerd/certs.d/${NEXUS_REGISTRY}"
printf 'server = "%s"\n\n[host."%s"]\n  capabilities = ["pull", "resolve", "push"]\n  skip_verify = true\n' \
  "${NEXUS_ENDPOINT}" "${NEXUS_ENDPOINT}" \
  > "/etc/containerd/certs.d/${NEXUS_REGISTRY}/hosts.toml"

echo "[4/9] Load and start Nexus"
install -d -m 0755 "${NEXUS_HOME}"
install -d -m 0755 -o 200 -g 200 "${NEXUS_DATA}" "${NEXUS_DATA}/etc" "${NEXUS_DATA}/etc/ssl"
install -m 0644 "${BUNDLE_DIR}/nexus/compose.yaml" "${NEXUS_HOME}/compose.yaml"
install -m 0644 -o 200 -g 200 "${BUNDLE_DIR}/nexus/nexus.properties" "${NEXUS_DATA}/etc/nexus.properties"
sed -i "s/^application-port-ssl=.*/application-port-ssl=${NEXUS_PORT}/" "${NEXUS_DATA}/etc/nexus.properties"
# Non-secret runtime settings keep a later plain compose up consistent.
printf 'NEXUS_IMAGE=%s\nNEXUS_PORT=%s\nNEXUS_DATA=%s\nNEXUS_HEAP=%s\nNEXUS_DIRECT_MEMORY=%s\n' \
  "${NEXUS_IMAGE}" "${NEXUS_PORT}" "${NEXUS_DATA}" "${NEXUS_HEAP}" "${NEXUS_DIRECT_MEMORY}" > "${NEXUS_HOME}/.env"
chmod 0644 "${NEXUS_HOME}/.env"

nerdctl image inspect "${NEXUS_IMAGE}" >/dev/null 2>&1 \
  || nerdctl load -i "${NEXUS_IMAGE_ARCHIVE}"

if [[ ! -f "${NEXUS_DATA}/etc/ssl/keystore.jks" ]]; then
  short_hostname="$(hostname -s)"
  if [[ "${NEXUS_HOST}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    certificate_san="IP:${NEXUS_HOST},DNS:${short_hostname},DNS:nexus"
  else
    certificate_san="DNS:${NEXUS_HOST},DNS:${short_hostname},DNS:nexus"
  fi
  nerdctl run --rm \
    --entrypoint /usr/bin/keytool \
    -v "${NEXUS_DATA}:/nexus-data" \
    "${NEXUS_IMAGE}" \
    -genkeypair \
    -alias nexus \
    -keyalg RSA \
    -keysize 4096 \
    -validity 3650 \
    -keystore /nexus-data/etc/ssl/keystore.jks \
    -storepass password \
    -keypass password \
    -dname "CN=${NEXUS_HOST},OU=Infrastructure,O=Okestro,C=KR" \
    -ext "SAN=${certificate_san}"
fi

chown -R 200:200 "${NEXUS_DATA}/etc"
if [[ "$(nerdctl container inspect -f '{{.State.Status}}' nexus 2>/dev/null || true)" == "running" ]]; then
  existing_nexus_image="$(nerdctl container inspect -f '{{.Config.Image}}' nexus)"
  [[ "${existing_nexus_image#docker.io/}" == "${NEXUS_IMAGE#docker.io/}" ]] || {
    echo "Running Nexus image differs from this release: ${existing_nexus_image}" >&2
    exit 1
  }
  echo "Nexus is already running."
else
  nerdctl compose -f "${NEXUS_HOME}/compose.yaml" up -d
fi

echo "[5/9] Wait for Nexus HTTPS"
for attempt in $(seq 1 120); do
  if curl -kfsS "${API}/status" >/dev/null 2>&1; then
    break
  fi
  [[ "${attempt}" -lt 120 ]] || {
    echo "Nexus startup timeout." >&2
    nerdctl logs nexus | tail -100 >&2
    exit 1
  }
  sleep 5
done

ADMIN_SECRET="${NEXUS_HOME}/.admin-password"
if [[ -r "${NEXUS_DATA}/admin.password" && ! -e "${ADMIN_SECRET}" ]]; then
  install -m 0600 "${NEXUS_DATA}/admin.password" "${ADMIN_SECRET}"
fi
if [[ -z "${NEXUS_ADMIN_PASSWORD:-}" && -r "${ADMIN_SECRET}" ]]; then
  NEXUS_ADMIN_PASSWORD="$(<"${ADMIN_SECRET}")"
fi
[[ -n "${NEXUS_ADMIN_PASSWORD:-}" ]] || {
  echo "Nexus admin password is unavailable; set NEXUS_ADMIN_PASSWORD or restore ${ADMIN_SECRET}." >&2
  exit 1
}
AUTH="admin:${NEXUS_ADMIN_PASSWORD}"

curl -kfsS -u "${AUTH}" "${API}/security/anonymous" >/dev/null

eula="$(curl -kfsS -u "${AUTH}" "${API}/system/eula")"
if grep -q '"accepted"[[:space:]]*:[[:space:]]*false' <<<"${eula}"; then
  eula="$(sed -E 's/"accepted"[[:space:]]*:[[:space:]]*false/"accepted": true/' <<<"${eula}")"
  curl -kfsS -u "${AUTH}" \
    -H 'Content-Type: application/json' \
    -X POST --data "${eula}" "${API}/system/eula" >/dev/null
fi

api_status() {
  curl -ksS -u "${AUTH}" -o /dev/null -w '%{http_code}' "${API}/$1"
}

echo "[6/9] Create blob store and repositories"
if [[ "$(api_status 'blobstores/file/contrabass-engine')" == "404" ]]; then
  curl -kfsS -u "${AUTH}" \
    -H 'Content-Type: application/json' \
    -X POST \
    --data '{"name":"contrabass-engine","path":"contrabass-engine"}' \
    "${API}/blobstores/file" >/dev/null
fi

if [[ "$(api_status 'repositories/raw/hosted/raw-hosted')" == "404" ]]; then
  curl -kfsS -u "${AUTH}" \
    -H 'Content-Type: application/json' \
    -X POST \
    --data '{"name":"raw-hosted","online":true,"storage":{"blobStoreName":"contrabass-engine","strictContentTypeValidation":false,"writePolicy":"ALLOW_ONCE"},"cleanup":{"policyNames":[]},"raw":{"contentDisposition":"ATTACHMENT"},"component":{"proprietaryComponents":true}}' \
    "${API}/repositories/raw/hosted" >/dev/null
fi

if [[ "$(api_status 'repositories/docker/hosted/docker-hosted')" == "404" ]]; then
  curl -kfsS -u "${AUTH}" \
    -H 'Content-Type: application/json' \
    -X POST \
    --data '{"name":"docker-hosted","online":true,"storage":{"blobStoreName":"contrabass-engine","strictContentTypeValidation":true,"writePolicy":"ALLOW_ONCE","latestPolicy":false},"cleanup":{"policyNames":[]},"docker":{"v1Enabled":false,"forceBasicAuth":false,"pathEnabled":true},"component":{"proprietaryComponents":true}}' \
    "${API}/repositories/docker/hosted" >/dev/null
fi

if [[ "$(api_status 'security/roles/private-anonymous-reader')" == "404" ]]; then
  curl -kfsS -u "${AUTH}" \
    -H 'Content-Type: application/json' \
    -X POST \
    --data '{"id":"private-anonymous-reader","name":"Private Repository Anonymous Reader","description":"Anonymous pull and download","privileges":["nx-repository-view-raw-raw-hosted-read","nx-repository-view-raw-raw-hosted-browse","nx-repository-view-docker-docker-hosted-read","nx-repository-view-docker-docker-hosted-browse"],"roles":[]}' \
    "${API}/security/roles" >/dev/null
fi

curl -kfsS -u "${AUTH}" \
  -H 'Content-Type: application/json' \
  -X PUT \
  --data '["NexusAuthenticatingRealm","DockerToken"]' \
  "${API}/security/realms/active" >/dev/null

curl -kfsS -u "${AUTH}" \
  -H 'Content-Type: application/json' \
  -X PUT \
  --data '{"userId":"anonymous","firstName":"Anonymous","lastName":"User","emailAddress":"anonymous@example.org","source":"default","status":"active","roles":["nx-anonymous","private-anonymous-reader"]}' \
  "${API}/security/users/anonymous" >/dev/null

curl -kfsS -u "${AUTH}" \
  -H 'Content-Type: application/json' \
  -X PUT \
  --data '{"enabled":true,"userId":"anonymous","realmName":"NexusAuthorizingRealm"}' \
  "${API}/security/anonymous" >/dev/null

echo "[7/9] Import Raw artifacts"
awk -F'"' '
  /^  - path:/ {path=$2}
  /^    sha256:/ && path != "" {print path "|" $2; path=""}
' "${MANIFEST}" |
while IFS='|' read -r artifact_path expected_sha; do
  source_file="${BUNDLE_DIR}/raw/${artifact_path}"
  actual_sha="$(sha256sum "${source_file}" | awk '{print $1}')"
  [[ "${actual_sha}" == "${expected_sha}" ]] || {
    echo "Checksum mismatch: ${artifact_path}" >&2
    exit 1
  }

  status="$(curl -ksSI -u "${AUTH}" -o /dev/null -w '%{http_code}' \
    "${NEXUS_ENDPOINT}/repository/raw-hosted/${artifact_path}")"
  if [[ "${status}" == "404" ]]; then
    echo "  ${artifact_path}"
    curl -kfsS -u "${AUTH}" \
      --upload-file "${source_file}" \
      "${NEXUS_ENDPOINT}/repository/raw-hosted/${artifact_path}"
  elif [[ "${status}" != "200" ]]; then
    echo "Raw repository check failed: ${artifact_path}, HTTP ${status}" >&2
    exit 1
  else
    remote_sha="$(curl -kfsS -u "${AUTH}" \
      "${NEXUS_ENDPOINT}/repository/raw-hosted/${artifact_path}" | sha256sum | awk '{print $1}')"
    [[ "${remote_sha}" == "${expected_sha}" ]] || {
      echo "Existing Raw artifact checksum differs: ${artifact_path}" >&2
      exit 1
    }
  fi
done

upload_raw_once() {
  local source_file="$1"
  local target_path="$2"
  local status

  status="$(curl -ksSI -u "${AUTH}" -o /dev/null -w '%{http_code}' \
    "${NEXUS_ENDPOINT}/repository/raw-hosted/${target_path}")"
  if [[ "${status}" == "404" ]]; then
    curl -kfsS -u "${AUTH}" --upload-file "${source_file}" \
      "${NEXUS_ENDPOINT}/repository/raw-hosted/${target_path}" >/dev/null
  elif [[ "${status}" != "200" ]]; then
    echo "Raw repository check failed: ${target_path}, HTTP ${status}" >&2
    exit 1
  else
    curl -kfsS -u "${AUTH}" \
      "${NEXUS_ENDPOINT}/repository/raw-hosted/${target_path}" \
      | cmp -s "${source_file}" - || {
      echo "Existing Raw metadata differs: ${target_path}" >&2
      return 1
    }
  fi
}

release_tag="$(awk -F': *' '$1 == "release_tag" {print $2; exit}' "${RELEASE_INFO}")"
[[ "${release_tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "Invalid release tag in release-info.yaml: ${release_tag}" >&2
  exit 1
}
upload_raw_once "${MANIFEST}" "release/${release_tag}/manifest.yaml"
upload_raw_once "${RELEASE_INFO}" "release/${release_tag}/release-info.yaml"

echo "[8/9] Import Docker images"

read_registry_manifest() {
  local image_name="$1"
  local image_tag="$2"
  local header_file
  local manifest_url

  manifest_url="${NEXUS_ENDPOINT}/v2/docker-hosted/${image_name}/manifests/${image_tag}"
  header_file="$(mktemp)"
  REGISTRY_HTTP_STATUS="$(curl -ksS -u "${AUTH}" -D "${header_file}" -o /dev/null -w '%{http_code}' \
    -H 'Accept: application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.index.v1+json' \
    "${manifest_url}")"
  REGISTRY_DIGEST="$(awk 'BEGIN{IGNORECASE=1} /^Docker-Content-Digest:/{gsub("\\r", "", $2); print $2; exit}' "${header_file}")"
  rm -f "${header_file}"
}

missing_image_count=0
while IFS='|' read -r source_ref image_name image_tag expected_digest; do
  read_registry_manifest "${image_name}" "${image_tag}"
  if [[ "${REGISTRY_HTTP_STATUS}" == "200" ]]; then
    [[ "${REGISTRY_DIGEST}" == "${expected_digest}" ]] || {
      echo "Existing image digest differs: ${image_name}:${image_tag}" >&2
      exit 1
    }
  elif [[ "${REGISTRY_HTTP_STATUS}" == "404" ]]; then
    missing_image_count=$((missing_image_count + 1))
  else
    echo "Docker repository check failed: ${image_name}:${image_tag}, HTTP ${REGISTRY_HTTP_STATUS}" >&2
    exit 1
  fi
done < "${IMAGE_MAP}"

if [[ "${missing_image_count}" -eq 0 ]]; then
  echo "All Docker images are already imported."
else
  nerdctl load -i "${IMAGE_ARCHIVE}"
  printf '%s' "${NEXUS_ADMIN_PASSWORD}" \
    | nerdctl login --username admin --password-stdin "${NEXUS_REGISTRY}"

  while IFS='|' read -r source_ref image_name image_tag expected_digest; do
    target_ref="${NEXUS_REGISTRY}/docker-hosted/${image_name}:${image_tag}"
    read_registry_manifest "${image_name}" "${image_tag}"
    if [[ "${REGISTRY_HTTP_STATUS}" == "200" ]]; then
      continue
    fi

    echo "  ${target_ref}"
    nerdctl tag "${source_ref}" "${target_ref}"
    nerdctl push --quiet "${target_ref}"

    read_registry_manifest "${image_name}" "${image_tag}"
    [[ "${REGISTRY_HTTP_STATUS}" == "200" && "${REGISTRY_DIGEST}" == "${expected_digest}" ]] || {
      echo "Digest mismatch after push: ${image_name}:${image_tag}" >&2
      exit 1
    }
  done < "${IMAGE_MAP}"

  nerdctl logout "${NEXUS_REGISTRY}" >/dev/null 2>&1 || true
fi

echo "[9/9] Final verification"
raw_count=0
while IFS= read -r artifact_path; do
  curl -kfsSI \
    "${NEXUS_ENDPOINT}/repository/raw-hosted/${artifact_path}" \
    >/dev/null
  raw_count=$((raw_count + 1))
done < <(awk -F'"' '/^  - path:/{print $2}' "${MANIFEST}")

image_count="$(wc -l < "${IMAGE_MAP}")"
curl -kfsSI "${NEXUS_ENDPOINT}/repository/raw-hosted/release/${release_tag}/manifest.yaml" >/dev/null

if systemctl is-active --quiet firewalld && command -v firewall-cmd >/dev/null; then
  firewall-cmd --quiet --query-port="${NEXUS_PORT}/tcp" \
    || firewall-cmd --quiet --add-port="${NEXUS_PORT}/tcp"
  firewall-cmd --quiet --permanent --query-port="${NEXUS_PORT}/tcp" \
    || firewall-cmd --quiet --permanent --add-port="${NEXUS_PORT}/tcp"
fi

echo
echo "Private Nexus : ${NEXUS_ENDPOINT}"
echo "Raw artifacts : ${raw_count}"
echo "Docker images : ${image_count}"
git_ref="$(awk -F': *' '$1 == "git_ref" {print $2; exit}' "${RELEASE_INFO}")"
if [[ -z "${git_ref}" ]]; then
  git_ref="$(awk -F': *' '$1 == "git_tag" {print $2; exit}' "${RELEASE_INFO}")"
fi
echo "Git ref       : ${git_ref}"
echo "Admin password: ${NEXUS_DATA}/admin.password"
