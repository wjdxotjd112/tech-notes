#!/bin/bash
set -euo pipefail
umask 077

: "${SCAN_DIR:?Set SCAN_DIR}"
: "${REGISTRY:?Set REGISTRY to the Nexus host:port}"
: "${NEXUS_CA:?Set NEXUS_CA to the trusted certificate bundle}"
DOCKER_REPOSITORY="${DOCKER_REPOSITORY:-docker-hosted}"
IMAGE_LIST="${IMAGE_LIST:-${SCAN_DIR}/images.txt}"
REPORT_DIR="${REPORT_DIR:-${SCAN_DIR}/reports/images}"
TRIVY_BIN="${TRIVY_BIN:-${SCAN_DIR}/bin/trivy}"
MIN_FREE_GIB="${MIN_FREE_GIB:-10}"
export DOCKER_CONFIG="${DOCKER_CONFIG:-${SCAN_DIR}/auth}"
export TMPDIR="${TMPDIR:-${SCAN_DIR}/tmp}"
export SSL_CERT_FILE="${NEXUS_CA}"

for command in jq sha256sum awk df flock mktemp cmp date grep; do
  command -v "${command}" >/dev/null || { echo "Command not found: ${command}" >&2; exit 1; }
done
test -x "${TRIVY_BIN}"
test -s "${NEXUS_CA}"
test -s "${IMAGE_LIST}"
test -s "${SCAN_DIR}/cache/db/trivy.db"
test -s "${SCAN_DIR}/cache/java-db/trivy-java.db"
[[ "${MIN_FREE_GIB}" =~ ^[0-9]+$ ]]
[[ "${REGISTRY}" != *://* && "${REGISTRY}" != */* ]]
[[ "${DOCKER_REPOSITORY}" =~ ^[A-Za-z0-9._-]+$ ]]
mkdir -p "${REPORT_DIR}" "${TMPDIR}"
exec 9>"${SCAN_DIR}/.image-scan.lock"
flock -n 9 || { echo 'Another list-based image scan is running.' >&2; exit 1; }

context="$(mktemp "${REPORT_DIR}/.context.XXXXXX")"
targets="$(mktemp "${REPORT_DIR}/.targets.XXXXXX")"
trap 'rm -f -- "${context}" "${targets}"' EXIT
{
  "${TRIVY_BIN}" --config '' --cache-dir "${SCAN_DIR}/cache" --version
  sha256sum "${NEXUS_CA}" "${SCAN_DIR}/cache/db/metadata.json" \
    "${SCAN_DIR}/cache/java-db/metadata.json"
  printf '%s\n' 'platform=linux/amd64 scanners=vuln parallel=1 timeout=20m offline-scan=true list-all-pkgs=true ignorefile=disabled'
  printf '%s\n' 'skip-db-update=true skip-java-db-update=true image-src=remote exit-code=0'
} > "${context}"
if [[ -f "${REPORT_DIR}/scan-context.txt" ]]; then
  cmp -s "${context}" "${REPORT_DIR}/scan-context.txt" || {
    echo 'Tool/DB/CA context changed. Use a new REPORT_DIR instead of mixing results.' >&2
    exit 1
  }
else
  cp "${context}" "${REPORT_DIR}/scan-context.txt"
fi

while IFS= read -r image || [[ -n "${image}" ]]; do
  image="${image%$'\r'}"
  [[ -n "${image}" && "${image}" != \#* ]] || continue
  [[ "${image}" == "${REGISTRY}/${DOCKER_REPOSITORY}/"* \
    && "${image}" =~ @sha256:[0-9a-f]{64}$ && "${image}" != *[[:space:]]* ]] || {
    echo "Invalid or unpinned target: ${image}" >&2; exit 1;
  }
  printf '%s\n' "${image}" >> "${targets}"
done < "${IMAGE_LIST}"
test -s "${targets}" || { echo 'Target list is empty.' >&2; exit 1; }
cp "${targets}" "${REPORT_DIR}/images-used.txt"
total="$(awk 'END {print NR}' "${targets}")"
printf 'number\tstatus\timage\tjson\n' > "${REPORT_DIR}/image-status.tsv"
date -Is > "${REPORT_DIR}/started-at.txt"
failed=0
review=0
n=0
priority=()
if command -v nice >/dev/null; then priority=(nice -n 10); fi

while IFS= read -r image; do
  n=$((n + 1))
  free_kib="$(df -Pk "${TMPDIR}" | awk 'NR == 2 {print $4}')"
  ((free_kib >= MIN_FREE_GIB * 1024 * 1024)) || {
    echo 'Free disk space is below MIN_FREE_GIB. Stop and keep existing results.' >&2; exit 1;
  }
  id="$(printf '%s' "${image}" | sha256sum | awk '{print $1}')"
  base="${REPORT_DIR}/${id}"
  printf '[%s/%s] %s\n' "${n}" "${total}" "${image}"
  if [[ -s "${base}.json" && -s "${base}.log" ]] && jq -e --arg image "${image}" \
    '.SchemaVersion and .ArtifactName == $image and ([.Results[]?.Packages[]?] | length > 0)' \
    "${base}.json" >/dev/null; then
    status=reused
  else
    rc=0
    "${priority[@]}" "${TRIVY_BIN}" --config '' --cache-dir "${SCAN_DIR}/cache" \
      --cacert "${NEXUS_CA}" image --image-src remote --platform linux/amd64 \
      --scanners vuln --parallel 1 --timeout 20m --exit-code 0 \
      --skip-db-update --skip-java-db-update --offline-scan \
      --ignorefile '' --list-all-pkgs --format json \
      --output "${base}.partial.json" "${image}" 2> "${base}.log" || rc=$?
    if [[ "${rc}" -eq 0 ]] && jq -e --arg image "${image}" \
      '.SchemaVersion and .ArtifactName == $image' "${base}.partial.json" >/dev/null; then
      mv "${base}.partial.json" "${base}.json"
      if jq -e '[.Results[]?.Packages[]?] | length > 0' "${base}.json" >/dev/null; then
        status=completed
      else
        status=unidentified
        failed=$((failed + 1))
      fi
    else
      status=failed
      failed=$((failed + 1))
    fi
  fi
  if [[ "${status}" == completed || "${status}" == reused ]]; then
    if grep -Eq 'Unsupported os|no longer supported|security updates are not provided' "${base}.log"; then
      status="${status}-review"
      review=$((review + 1))
    fi
  fi
  printf '%s\t%s\t%s\t%s\n' "${n}" "${status}" "${image}" "${base}.json" \
    >> "${REPORT_DIR}/image-status.tsv"
  echo "  ${status}"
done < "${targets}"
date -Is > "${REPORT_DIR}/finished-at.txt"
echo "Targets=${n}, failed-or-unidentified=${failed}, coverage-review=${review}; ${REPORT_DIR}/image-status.tsv"
[[ "${failed}" -eq 0 ]]
