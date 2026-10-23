#!/bin/bash
source /etc/gitea-runner-env/bundle-pipeline.env

http_curl() {
  local tls=()
  [[ "${TLS_SKIP_VERIFY}" == true ]] && tls=(--insecure)
  command curl --connect-timeout "${HTTP_CONNECT_TIMEOUT}" "${tls[@]}" "$@"
}

curl_config_value() {
  local value="$1"
  [[ "${value}" != *$'\n'* && "${value}" != *$'\r'* ]] || return 1
  value="${value//\\/\\\\}"
  printf '%s' "${value//\"/\\\"}"
}

nexus_curl() {
  local credential
  credential="$(curl_config_value "${NEXUS_USER:?}:${NEXUS_PASSWORD:?}")" || return 1
  http_curl --config <(printf 'user = "%s"\n' "${credential}") "$@"
}

export_test_inputs() {
  local info="${1:-staging-info.yaml}" manifest_info="${2:-release-info.yaml}" path sha id
  path="$(yaml_value "${info}" bundle_path)"
  sha="$(yaml_value "${info}" bundle_sha256)"
  id="$(yaml_value "${manifest_info}" manifest_id)"
  [[ "${sha}" =~ ^[0-9a-f]{64}$ && "${id}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
  [[ "${path}" == "candidates/${id}/${sha}/contrabass-engine-deploy.tar" ]]
  test -r "${TOFU_SSH_PRIVATE_KEY}"
  test -s "${TOFU_SSH_PUBLIC_KEY}"
  export TF_VAR_bundle_url="${NEXUS_URL%/}/repository/${STAGING_REPOSITORY}/${path}"
  export TF_VAR_bundle_sha256="${sha}"
  export TF_VAR_ssh_private_key_path="${TOFU_SSH_PRIVATE_KEY}"
  export TF_VAR_ssh_public_key="$(<"${TOFU_SSH_PUBLIC_KEY}")"
  export TF_VAR_nexus_user="${NEXUS_USER}"
  export TF_VAR_nexus_password="${NEXUS_PASSWORD}"
  export TF_VAR_nexus_skip_verify="${TLS_SKIP_VERIFY}"
  export TF_IN_AUTOMATION=1 TF_INPUT=0
}

yaml_value() {
  awk -F': *' -v key="$2" '$1 == key {gsub(/"/, "", $2); print $2; exit}' "$1"
}

file_sha256() { sha256sum "$1" | awk '{print $1}'; }

nexus_get_optional() {
  local status
  status="$(nexus_curl -sS -o "$2" -w '%{http_code}' "$1")" || exit 1
  case "$status" in
    200) return 0 ;;
    404) return 1 ;;
    *) echo "Nexus request failed: HTTP $status ($1)" >&2; exit 1 ;;
  esac
}

require_commands() {
  local name
  for name in "$@"; do
    command -v "$name" >/dev/null || { echo "Command not found: $name" >&2; return 1; }
  done
}

select_test_mode() (
  set -euo pipefail
  local source_dir="$1" tag="$2" output="$3" commit release line api scratch status mode=full reason pr=0
  require_commands curl jq git awk sort mktemp
  : "${REPO_READ_TOKEN:?Set REPO_READ_TOKEN secret}"
  : "${GITEA_URL:?}" "${GITEA_REPOSITORY:?}" "${RELEASE_BRANCH:?}" "${TEST_SKIP_LABEL:?}"
  [[ "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
  commit="$(git -C "${source_dir}" rev-parse HEAD)"
  release="$(yaml_value "${source_dir}/release/manifest.yaml" release)"
  [[ "${tag}" == "v${release}" ]] || { echo 'Tag and manifest release differ.' >&2; exit 1; }
  line="${release%.*}"
  api="${GITEA_URL%/}/api/v1/repos/${GITEA_REPOSITORY}"
  scratch="$(mktemp -d)"
  trap 'rm -rf -- "${scratch}"' EXIT

  gitea_get() {
    status="$(http_curl -sS --header @<(printf 'Authorization: token %s\n' "${REPO_READ_TOKEN}") \
      -o "$2" -w '%{http_code}' "${api}/$1")" || exit 1
    case "${status}" in
      200) return 0 ;;
      404) return 1 ;;
      *) echo "Gitea lookup failed: HTTP ${status} ($1). No release." >&2; exit 1 ;;
    esac
  }

  gitea_get "tags/${tag}" "${scratch}/tag.json" || { echo 'Remote tag is missing.' >&2; exit 1; }
  [[ "$(jq -r '.commit.sha' "${scratch}/tag.json")" == "${commit}" ]] || {
    echo 'Remote tag and checked-out commit differ.' >&2; exit 1;
  }

  if gitea_get "commits/${commit}/pull" "${scratch}/pr.json"; then
    jq -e --arg sha "${commit}" --arg branch "${RELEASE_BRANCH}" \
      '.merged == true and .merge_commit_sha == $sha and .base.ref == $branch' \
      "${scratch}/pr.json" >/dev/null || {
      echo 'Tag must point to the approved master PR merge commit.' >&2; exit 1;
    }
    pr="$(jq -r '.number' "${scratch}/pr.json")"
    gitea_get "pulls/${pr}" "${scratch}/pr.json" || exit 1
    gitea_get "git/commits/${commit}" "${scratch}/merge.json" || exit 1
    [[ "$(jq '.parents | length' "${scratch}/merge.json")" == 2 ]] || {
      echo 'Release PRs must use a normal merge commit (not squash/rebase).' >&2; exit 1;
    }
    reviewed_sha="$(jq -r '.parents[1].sha' "${scratch}/merge.json")"
    printf '[]\n' > "${scratch}/reviews.json"
    page=1
    while true; do
      gitea_get "pulls/${pr}/reviews?limit=50&page=${page}" "${scratch}/page.json" || exit 1
      jq -s '.[0] + .[1]' "${scratch}/reviews.json" "${scratch}/page.json" > "${scratch}/combined.json"
      mv "${scratch}/combined.json" "${scratch}/reviews.json"
      [[ "$(jq 'length' "${scratch}/page.json")" -ge 50 ]] || break
      page=$((page + 1))
    done
    jq -e --arg sha "${reviewed_sha}" \
      '[.[] | select(.official == true and .dismissed != true and .stale != true
        and .state == "APPROVED" and .commit_id == $sha)] | length >= 1' \
      "${scratch}/reviews.json" >/dev/null || {
      echo 'PR has no valid approval for its reviewed head commit.' >&2; exit 1;
    }
    if jq -e --arg label "${TEST_SKIP_LABEL}" \
      'any(.labels[]?; .name == $label)' "${scratch}/pr.json" >/dev/null; then mode=skip; fi
    reason=pr-label
  elif [[ " ${LEGACY_RELEASE_TAGS:-} " == *" ${tag} "* ]]; then
    reason=historical-tag
  else
    gitea_get "raw/release/manifest.yaml?ref=${RELEASE_BRANCH}" "${scratch}/master.yaml" || exit 1
    master_release="$(yaml_value "${scratch}/master.yaml" release)"
    [[ "${master_release}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
    master_line="${master_release%.*}"
    [[ "${line}" != "${master_line}" \
      && "$(printf '%s\n' "${line}" "${master_line}" | sort -V | head -1)" == "${line}" ]] || {
      echo 'A new current/future-line tag requires an approved master PR.' >&2; exit 1;
    }
    [[ "$(git -C "${source_dir}" cat-file -t "refs/tags/${tag}")" == tag ]] || {
      echo 'Use an annotated tag: git tag -a VERSION -m MESSAGE.' >&2; exit 1;
    }
    message="$(git -C "${source_dir}" for-each-ref --format='%(contents)' "refs/tags/${tag}")"
    if grep -Fq '[skip-test]' <<< "${message}"; then mode=skip; fi
    reason=patch-tag-message
  fi

  printf '%s\n' "release_tag: ${tag}" "git_commit: ${commit}" \
    "test_mode: ${mode}" "decision_source: ${reason}" "pull_request: ${pr}" > "${output}"
  echo "Release policy: tag=${tag}, mode=${mode}, source=${reason}, PR=${pr}"
)
