---
title: "OpenTofu 입문 가이드 - 5"
summary: "5편: TAR를 staging에 먼저 게시하고 VM에서 설치를 시험한다. 통과한 동일 TAR만 최종 release에 게시하고 current 채널을 갱신한다."
summary_style: editorial
date: 2026-10-15
category: 개념
tags:
  - 가이드
  - Automation
  - OpenStack
---

<section class="editorial-summary editorial-summary--text-only" aria-labelledby="editorial-summary-title">
  <div class="editorial-summary-layout">
    <div class="editorial-summary-copy">
      <span class="editorial-summary-label">이 구성의 핵심</span>
      <h2 id="editorial-summary-title" class="editorial-summary-title">만든 TAR를 바로 공개하지 않고, 설치 시험을 통과한 파일만 발행한다.</h2>
      <p>패키징 결과를 시험용 Nexus 저장소에 먼저 올린다. OpenTofu가 만든 첫 VM이 그 TAR를 받아 Private Nexus와 Ansible을 실행한다. 시험이 통과하면 같은 파일을 최종 저장소에 게시하고, 사업수행팀이 사용하는 current 주소를 갱신한다.</p>
    </div>
  </div>
  <p class="editorial-summary-result"><span><strong>한 번 빌드 → staging 게시 → 배포 시험 → 동일 TAR 승격</strong>. 시험 실패 시 기존 current를 유지하고, staging은 정리하되 시험 VM과 State는 남긴다.</span></p>
</section>

[4편](2026-10-14-opentofu-gitea-runner.md)은 최종 TAR를 먼저 게시한 뒤 배포를 시험하는 구성이다. 이번 편에서는 **최종 게시 시점만 시험 뒤로 옮긴다.** VM 생성·SSH 확인·Ansible 실행은 앞의 구성을 이어서 사용한다.

**staging**은 아직 배포 검증을 마치지 않은 후보 파일을 두는 공간이다. **승격**은 그 후보가 시험을 통과했을 때 정식 배포 대상으로 발행하는 과정이다. 여기서는 일반 Raw Hosted 저장소와 HTTP 업로드를 사용하며, Nexus의 별도 Staging 제품 기능이나 전용 이동 API를 전제로 하지 않는다.

---

## 1. 4편에서 바뀌는 실행 순서

<figure class="flow" aria-label="릴리스 후보의 시험과 최종 게시 순서">
  <ol>
    <li>한 번 빌드</li>
    <li>staging 게시</li>
    <li>VM 배포 시험</li>
    <li>release·current 갱신</li>
  </ol>
</figure>

```text
태그 push
  → shallow clone → manifest 게시 → TAR 생성
  → raw-release-staging에 후보 TAR 게시
  → OpenTofu로 VM 4대 생성
  → 첫 VM이 staging TAR 다운로드·SHA256 확인
  → deploy.sh → Ansible → 기본 연결 시험
      ├─ 성공: 같은 TAR를 raw-release-bundle에 게시 → current 갱신
      └─ 실패: 최종 게시 안 함 → 기존 current 유지
  → 이번 후보의 staging 파일 정리
  → VM·State는 유지
```

SHA256은 파일 내용으로 계산하는 해시다. 파일이 바뀌면 해시도 달라지므로 **빌드한 TAR, VM에서 설치한 TAR, 최종 게시할 TAR가 같은지** 비교하는 기준으로 사용한다.

이 흐름에서 빌더를 두 번 호출하면 안 된다. 시험이 끝난 뒤 다시 TAR를 만들면 시험하지 않은 파일을 발행할 수 있다. staging의 파일을 최종 저장소에 복사하고 검증 후 staging을 지우는 방식이며, 아래 예제는 Runner에 보관한 동일 원본 TAR를 최종 업로드에 재사용한다.

| 시점 | 실행할 작업 | 아직 하지 않을 작업 |
| --- | --- | --- |
| 빌드 직후 | staging에 TAR와 체크섬 게시 | 최종 TAR 게시, current 갱신, 이전 릴리스 삭제 |
| 배포 시험 중 | 첫 VM에서 staging TAR 설치 | 사업수행팀 다운로드 주소 변경 |
| 시험 통과 후 | 기존 최종 게시 스크립트 실행 | TAR 재빌드 |
| 시험 실패 후 | 로그 확인, 후보 파일 정리 | 최종 게시·채널 변경 |

---

## 2. Nexus에 시험 저장소 하나 추가

Nexus 관리 화면의 **Repositories → Create repository → raw (hosted)**에서 `raw-release-staging`을 만든다. Raw Hosted는 TAR 같은 파일을 경로 단위로 업로드·다운로드하는 저장소다. [Raw 저장소와 HTTP PUT](https://help.sonatype.com/en/raw-repositories.html#uploading-files-to-hosted-raw-repositories)

| 항목 | 구성 |
| --- | --- |
| Name | `raw-release-staging` |
| Format / Type | Raw / Hosted |
| Blob Store | 기존 아티팩트용 Blob Store 사용 가능 |
| Deployment Policy | `Disable redeploy` — 같은 후보 경로 덮어쓰기 방지 |
| CI 게시 계정 | staging 읽기·업로드·삭제 권한, 기존 최종 게시 권한 유지 |
| VM 다운로드 계정 | staging 읽기 권한 추가 |
| 사업수행팀 계정 | 최종 저장소 읽기 권한 유지. staging 접근은 부여하지 않음 |

후보마다 `manifest_id`와 TAR 해시를 경로에 포함한다. 같은 버전이라도 내용이 다른 후보는 다른 주소를 사용하며, 같은 주소를 재사용할 때는 기존 체크섬과 일치해야 한다.

```text
raw-release-staging/
└── candidates/<manifest_id>/<sha256>/
    ├── contrabass-engine-deploy.tar
    └── contrabass-engine-deploy.tar.sha256

raw-release-bundle/
├── releases/4.0/v4.0.8/
│   ├── contrabass-engine-deploy.tar
│   ├── contrabass-engine-deploy.tar.sha256
│   └── release-info.yaml
└── channels/4.0/, channels/current/
    └── release-info.yaml 등 채널 정보
```

사업수행팀의 TAR 주소는 계속 HAProxy가 제공하는 `raw-manifest/channels/current/contrabass-engine-deploy.tar` 또는 `channels/4.0/…`다. **후보 파일에는 이 별칭을 만들지 않는다.**

기존 `/etc/gitea-runner-env/bundle-pipeline.env`에는 저장소 이름 한 개만 추가한다. 기존 `BUNDLE_REPOSITORY`는 최종 저장소 이름으로 유지한다.

```bash title="bundle-pipeline.env — 추가"
STAGING_REPOSITORY=raw-release-staging
```

Nexus 인증은 4편의 Secrets를 그대로 사용한다. `NEXUS_PASSWORD`는 CI 게시 계정, `TF_VAR_nexus_user`와 `TF_VAR_nexus_password`는 VM의 읽기 전용 계정에 대응한다.

---

## 3. 기존 Workflow를 네 단계로 나누기

Workflow는 **`.gitea/workflows/publish-manifest.yaml` 하나**를 유지한다. 별도 태그 Workflow를 만들어 병렬로 실행하지 않고, 같은 `release` Job 안에서 순서를 바꾼다. [Gitea Actions의 Workflow 위치](https://docs.gitea.com/usage/actions/quickstart/)

```text
기존: clone → manifest·빌드·최종 게시 → 시험
변경: clone → manifest·빌드 → staging → 시험 → 최종 게시 → staging 정리
```

먼저 기존 패키징 Step에서 아래 호출을 떼어내 뒤로 옮긴다.

```bash title="시험 뒤로 옮길 기존 명령"
bash "${BUNDLE_BUILDER_DIR}/publish-bundle.sh" release-info.yaml
```

`publish-manifest.sh`와 `/usr/local/sbin/build-private-release`는 앞에 둔다. 기존처럼 태그의 manifest를 기록하고 TAR를 만드는 역할이다. 이 두 단계에서는 **current 갱신이나 최종 TAR 업로드를 하지 않는 구조**를 사용한다. `raw-manifest/releases/…`의 manifest는 빌더가 읽는 재료 목록이지, 배포 시험 통과 표시가 아니다.

이하 예제는 기존 `common.sh`의 `yaml_value`, `file_sha256`, `nexus_get_optional`을 재사용한다. 마지막 함수는 파일이 없을 때만 false를 반환하고 인증·서버 오류에서는 실패해야 한다. HTTP 오류를 모두 “파일 없음”으로 취급하지 않는다.

| Job 작업공간의 파일 | 만드는 단계 | 다음에 읽는 단계 |
| --- | --- | --- |
| `release-info.yaml` | 기존 manifest 게시 | 빌더·staging 게시·최종 게시. Git·manifest 식별 정보 |
| `staging-info.yaml` | staging 게시 | 시험·승격·정리. 후보 경로와 TAR 해시 |
| `test-passed.sha256` | 배포 시험 성공 직후 | 승격. 이번 시험을 통과한 TAR의 해시 |

세 파일은 같은 `release` Job의 작업공간에서 전달한다. 최종 저장소의 번들용 `release-info.yaml`은 기존 게시 스크립트가 만드는 별도 메타데이터다. 이름이 같다고 Job 작업공간의 manifest용 파일과 바꿔 사용하지 않는다.

<details class="analysis-toggle" markdown="1">
<summary>staging 게시 Step — TAR는 삭제하지 않고 그대로 유지</summary>

기존 빌드 Step 바로 뒤에 추가한다. `BUNDLE_WORK_DIR/<manifest_id>.tar`와 `.sha256`은 기존 빌더가 만든 파일이다. 게시 계정 인증 환경변수도 기존 Job에서 이어받는다.

```yaml title="publish-manifest.yaml — 빌드 다음에 추가"
      - name: Publish staging candidate
        shell: bash
        run: |
          set -euo pipefail
          umask 077
          source /etc/gitea-runner-env/bundle-pipeline.env
          source "${BUNDLE_BUILDER_DIR}/common.sh"
          : "${NEXUS_PASSWORD:?Missing CI publishing password}"
          : "${STAGING_REPOSITORY:?Set STAGING_REPOSITORY}"
          [[ "${STAGING_REPOSITORY}" != "${BUNDLE_REPOSITORY}" ]]

          manifest_id="$(yaml_value release-info.yaml manifest_id)"
          [[ "${manifest_id}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
          bundle="${BUNDLE_WORK_DIR}/${manifest_id}.tar"
          test -s "${bundle}"
          sha="$(file_sha256 "${bundle}")"
          [[ "${sha}" == "$(awk '{print $1; exit}' "${bundle}.sha256")" ]]

          path="candidates/${manifest_id}/${sha}/contrabass-engine-deploy.tar"
          url="${NEXUS_URL%/}/repository/${STAGING_REPOSITORY}/${path}"
          printf '%s\n' "bundle_path: ${path}" "bundle_sha256: ${sha}" > staging-info.yaml
          printf '%s  %s\n' "${sha}" contrabass-engine-deploy.tar > staging.sha256

          if nexus_get_optional "${url}.sha256" staging.remote.sha256; then
            [[ "$(awk '{print $1; exit}' staging.remote.sha256)" == "${sha}" ]]
          else
            curl -kfsS --retry 3 -u "${NEXUS_USER}:${NEXUS_PASSWORD}" \
              --upload-file "${bundle}" "${url}"
            curl -kfsS --retry 3 -u "${NEXUS_USER}:${NEXUS_PASSWORD}" \
              --upload-file staging.sha256 "${url}.sha256"
          fi
```

`staging-info.yaml`은 다음 Step이 읽는 **같은 Job 작업공간의 결과 파일**이다. VM 설정 파일이 아니며 TAR 안에 다시 넣지 않는다. 기록하는 값도 URL 전체가 아니라 후보의 경로와 해시 두 개뿐이다.

staging을 올리기 위해 `BUNDLE_REPOSITORY`를 시험 저장소 이름으로 바꾸고 기존 최종 게시 스크립트를 호출하지 않는다. 그 스크립트에는 채널 갱신·보관 개수 정리까지 포함돼 있기 때문이다.

</details>

`curl -k`는 앞 편과 동일하게 자체 서명 인증서를 쓰는 시험 환경의 예시다. 인증서 신뢰 구성이 끝난 환경에서는 검증을 생략하지 않는다.

---

## 4. 첫 VM이 받은 파일의 해시까지 확인

4편의 시험 Step은 최종 release URL을 계산했다. 이제 그 부분을 `staging-info.yaml`의 후보 경로로 바꾼다. **current 주소나 최종 release 경로를 받으면 안 된다.**

아래 코드는 기존 시험 Step의 `source …/bundle-pipeline.env` 다음에 놓는다. 기존 태그 기반 `TF_VAR_bundle_url` 계산은 제거한다.

```bash title="시험 Step — staging URL과 예상 해시 전달"
job_dir="${PWD}"
source "${BUNDLE_BUILDER_DIR}/common.sh"
path="$(yaml_value staging-info.yaml bundle_path)"
sha="$(yaml_value staging-info.yaml bundle_sha256)"
[[ "${sha}" =~ ^[0-9a-f]{64}$ ]]
manifest_id="$(yaml_value release-info.yaml manifest_id)"
[[ "${path}" == "candidates/${manifest_id}/${sha}/contrabass-engine-deploy.tar" ]]

export TF_VAR_bundle_url="${NEXUS_URL%/}/repository/${STAGING_REPOSITORY}/${path}"
export TF_VAR_bundle_sha256="${sha}"
export TF_VAR_ssh_private_key_path="${TOFU_SSH_PRIVATE_KEY}"
rm -f -- "${job_dir}/test-passed.sha256"
```

Secrets의 `VSPHERE_USER`·`VSPHERE_PASSWORD`, `TF_VAR_nexus_user`·`TF_VAR_nexus_password`는 4편과 같은 방식으로 전달한다. 이번 Step도 기존의 host 라벨·동시 Job 1개·배포에 충분한 timeout 설정을 사용한다.

OpenTofu의 `deployment.tf`에는 해시 입력 변수 하나를 추가하고 `terraform_data.deploy`의 교체 조건에도 포함한다. `TF_VAR_bundle_sha256`는 이 변수에 전달된다. `.auto.tfvars`에는 `bundle_url`과 `bundle_sha256`을 중복 지정하지 않는다. [입력 변수와 우선순위](https://opentofu.org/docs/v1.10/language/values/variables/#variable-definition-precedence)

```hcl title="deployment.tf — 추가할 입력 변수"
variable "bundle_sha256" {
  type = string

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.bundle_sha256))
    error_message = "bundle_sha256 must be a SHA256 hex string."
  }
}
```

```hcl title="terraform_data.deploy — 기존 triggers_replace에 한 항목 추가"
triggers_replace = {
  vm_ids        = [for name in sort(keys(var.vms)) : vsphere_virtual_machine.vm[name].id]
  bundle_url    = var.bundle_url
  bundle_sha256 = var.bundle_sha256
}
```

첫 번째 `remote-exec`의 **TAR 다운로드 바로 다음, 압축 해제 이전**에 아래 한 줄을 추가한다. 따옴표를 포함한 HCL 리스트 항목이다.

```hcl title="deployment.tf — 다운로드한 TAR 검증"
"printf '%s  %s\\n' '${var.bundle_sha256}' contrabass-engine-deploy.tar | sha256sum -c -",
```

해시가 다르면 설치를 시작하지 않고 실패한다. 첫 VM이 staging의 실제 TAR 전체를 읽어 확인하는 것이므로, 체크섬 파일만 확인하는 것과 구분된다. `set -euo pipefail`은 그대로 유지한다.

<details class="analysis-toggle" markdown="1">
<summary>Ansible 뒤에 넣을 기본 시험 예시</summary>

기존 `terraform_data.deploy` 안에서 Ansible 실행 Provisioner **다음에** 추가한다. 아래는 컨테이너 기동과 inventory 대상의 SSH·Python 실행을 확인하는 기본 시험이다. OpenStack API·가상머신 생성까지 검증하는 명령은 아니다.

```hcl title="deployment.tf — 마지막 Provisioner로 추가"
provisioner "remote-exec" {
  inline = [
    "#!/bin/bash",
    "set -euo pipefail",
    "nerdctl exec nexus true",
    "nerdctl exec okestro-os-ansible sh -c 'cd /root/okestro/okestro-openstack && ansible all -i inventory/inventory.ini -m ansible.builtin.ping'",
  ]
}
```

Private Nexus 컨테이너 이름은 앞의 패키징 구성과 같은 `nexus`를 기준으로 한다. 이름이 다르면 이 한 곳을 맞춘다. Ansible 컨테이너는 `bash` 유무에 의존하지 않도록 `sh -c`를 사용한다.

추후 OpenStack 기능 테스트를 정하면 이 마지막 시험에 연결한다. 실패는 0이 아닌 종료 코드로 전달해야 한다. `|| true`나 `continue-on-error`로 실패를 숨기면 최종 게시를 막을 수 없다. Provisioner는 순서대로 실행되며 기본적으로 실패를 apply 실패로 전달한다. [Provisioner 순서·실패 처리](https://opentofu.org/docs/v1.10/language/resources/provisioners/syntax/)

</details>

시험 Step은 4편처럼 고정 프로젝트 디렉터리로 이동해 잠금을 잡고, 기존 VM 유무를 확인한 다음 실행한다. **apply 성공 직후** 아래처럼 시험한 해시를 Job 작업공간에 기록한다.

```bash title="시험 Step — 기존 apply와 마지막 출력 명령을 교체"
tofu plan -input=false -no-color -out=deploy.tfplan
tofu apply -input=false -no-color deploy.tfplan
printf '%s\n' "${TF_VAR_bundle_sha256}" > "${job_dir}/test-passed.sha256"
```

`tofu output -json vm_info`는 필수 단계에서 뺀다. 출력 정의가 없다는 이유로 배포 시험을 실패시키지 않도록, VM 목록 저장은 `output "vm_info"`를 준비한 경우에만 별도로 사용한다. HCL을 수정한 뒤에는 Runner의 프로젝트에서 `tofu fmt`와 `tofu validate`로 먼저 확인한다.

---

## 5. 통과한 동일 TAR만 최종 게시

다음 Step은 시험 Step이 성공했을 때만 실행한다. `if: always()`나 `continue-on-error`를 붙이지 않는다. 아래 조건을 모두 확인한 뒤 기존 `publish-bundle.sh`를 호출한다.

1. staging에 올린 TAR의 해시.
2. 배포 시험이 성공한 해시.
3. Runner에 남아 있는 최종 업로드용 TAR의 실제 해시.

```yaml title="publish-manifest.yaml — 시험 다음에 추가"
      - name: Promote tested bundle
        shell: bash
        run: |
          set -euo pipefail
          source /etc/gitea-runner-env/bundle-pipeline.env
          source "${BUNDLE_BUILDER_DIR}/common.sh"
          manifest_id="$(yaml_value release-info.yaml manifest_id)"
          [[ "${manifest_id}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
          expected="$(yaml_value staging-info.yaml bundle_sha256)"
          [[ "${expected}" =~ ^[0-9a-f]{64}$ ]]
          [[ "$(<test-passed.sha256)" == "${expected}" ]]
          [[ "$(file_sha256 "${BUNDLE_WORK_DIR}/${manifest_id}.tar")" == "${expected}" ]]
          bash "${BUNDLE_BUILDER_DIR}/publish-bundle.sh" release-info.yaml
```

이 단계에서는 빌더를 다시 호출하지 않는다. HTTP PUT으로 동일 내용을 다른 저장소에 게시하므로 승격 중에는 staging과 release에 TAR가 각각 존재할 수 있다. 시험 파일과 다른 결과물을 새로 만드는 과정은 아니다.

기존 최종 게시 스크립트가 맡는 작업은 유지한다.

- `raw-release-bundle/releases/<계열>/<태그>/`에 TAR·체크섬·번들용 release-info 게시.
- 기존 버전 경로가 있으면 내용 일치 확인. 다른 내용으로 덮어쓰지 않음.
- 계열 최신이면 `channels/<계열>/` 정보와 HAProxy 별칭 갱신.
- 전체 최신이면 `channels/current/` 정보와 별칭 갱신.
- 최종 Bundle은 계열별 최신 2개 유지.

예를 들어 `v4.0.8` 시험이 통과해도 전체 최신 계열이 4.2라면 4.0 채널만 바뀐다. current를 무조건 마지막에 실행한 태그로 바꾸지 않는다.

**HAProxy 구성 자체를 새로 만들 필요는 없다.** 최종 게시 시점이 뒤로 옮겨져 `update-release-alias` 호출도 시험 뒤에 실행되는 구조다. 별칭은 최종 저장소의 TAR만 가리키며 staging을 직접 가리키지 않는다.

!!! warning "시험 실패와 승격 중 실패는 다름"
    시험 실패는 최종 게시 Step에 도달하지 않으므로 기존 current를 유지한다. 반면 최종 업로드·메타데이터·HAProxy 갱신 도중 실패하면 일부 작업이 반영돼 있을 수 있다. 여러 시스템의 갱신이 하나의 원자적 작업은 아니므로, 실패 지점과 실제 채널을 확인하고 같은 해시의 산출물로 마무리한다. 통과한 TAR가 없다고 새로 빌드해 승격하지 않는다.

---

## 6. staging은 정리하고 VM은 남기기

Job 마지막에 staging 정리 Step을 둔다. 시험 성공·실패와 관계없이 실행하도록 **이 Step에만 `if: always()`**를 사용한다. 단, Runner 강제 종료나 서버 장애에서는 실행을 보장하지 못한다. [상태 조건 함수](https://docs.github.com/en/actions/reference/workflows-and-actions/expressions#always), [Gitea Actions 호환 범위](https://docs.gitea.com/usage/actions/comparison/)

Nexus에서는 개별 파일인 Asset의 ID를 조회한 뒤 삭제한다. 후보 경로 전체를 재귀 삭제하거나 Blob 파일을 직접 지우지 않는다. [Nexus Assets API](https://help.sonatype.com/en/assets-api.html)

<details class="analysis-toggle" markdown="1">
<summary>이번 후보의 TAR와 체크섬만 지우는 정리 Step</summary>

후보 업로드 전부터 기록해 둔 `staging-info.yaml`을 사용한다. 목록은 페이지를 모두 조회해 모은 뒤 삭제하므로 삭제 도중 페이지 경계가 바뀌는 문제를 피한다.

```yaml title="publish-manifest.yaml — 마지막 Step"
      - name: Clean staging candidate
        if: always()
        shell: bash
        run: |
          set -euo pipefail
          [[ -s staging-info.yaml ]] || exit 0
          source /etc/gitea-runner-env/bundle-pipeline.env
          source "${BUNDLE_BUILDER_DIR}/common.sh"
          [[ "${STAGING_REPOSITORY}" != "${BUNDLE_REPOSITORY}" ]]
          path="$(yaml_value staging-info.yaml bundle_path)"
          sha="$(yaml_value staging-info.yaml bundle_sha256)"
          manifest_id="$(yaml_value release-info.yaml manifest_id)"
          [[ "${manifest_id}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
          [[ "${sha}" =~ ^[0-9a-f]{64}$ ]]
          [[ "${path}" == "candidates/${manifest_id}/${sha}/contrabass-engine-deploy.tar" ]]

          ids="$(mktemp)"
          trap 'rm -f -- "${ids}"' EXIT
          next_page=""
          while true; do
            request=(-kfsS -u "${NEXUS_USER}:${NEXUS_PASSWORD}" --get \
              --data-urlencode "repository=${STAGING_REPOSITORY}")
            if [[ -n "${next_page}" ]]; then
              request+=(--data-urlencode "continuationToken=${next_page}")
            fi
            page="$(curl "${request[@]}" "${NEXUS_URL%/}/service/rest/v1/assets")"
            jq -r --arg path "${path}" \
              '.items[] | select(.path == $path or .path == ($path + ".sha256")) | .id' \
              <<< "${page}" >> "${ids}"
            next_page="$(jq -r '.continuationToken // empty' <<< "${page}")"
            [[ -n "${next_page}" ]] || break
          done

          while IFS= read -r id; do
            encoded="$(jq -rn --arg id "${id}" '$id | @uri')"
            curl -kfsS -u "${NEXUS_USER}:${NEXUS_PASSWORD}" -X DELETE \
              "${NEXUS_URL%/}/service/rest/v1/assets/${encoded}"
          done < "${ids}"
```

강제 종료로 남은 후보에는 일수 기준의 정기 Cleanup 정책을 보조로 사용한다. 예를 들어 최대 6시간인 Job보다 충분히 긴 3일을 기준으로 하고, `raw-release-staging`의 `candidates/` 영역에만 적용한다. 실행 중인 후보를 지우지 않도록 최대 작업 시간보다 긴 보관 기간을 잡는다.

</details>

!!! note "staging 삭제와 디스크 공간 회수는 별개"
    Nexus에서 파일을 지워도 Blob Store의 물리 파일은 바로 사라지지 않을 수 있다. 디스크 공간 회수에는 `Admin - Compact blob store` 작업도 구분해 운영한다. 삭제 정책만으로 빈 공간이 즉시 늘어난다고 가정하지 않는다. [Cleanup과 Compact](https://help.sonatype.com/en/cleanup-policies.html#hard-deleting-components-with-the-compact-blob-store-task)

시험 VM은 삭제하지 않는다. 첫 VM이 받아 둔 TAR와 배포 로그도 그대로 남아 있으므로 실패 분석에 사용할 수 있다. Runner의 실패한 후보 TAR도 조사·같은 파일 재사용을 위해 당장은 유지하고, 최종 게시 성공 후의 로컬 TAR 정리는 기존 게시 스크립트에 맡긴다.

고정 이름과 IP를 사용하는 만큼 다음 시험 전에는 남은 VM을 확인하고 수동 정리한다. 자동 삭제는 별도로 추가할 항목이며, 이번 Workflow에는 `tofu destroy`를 넣지 않는다.

수동 삭제 계획을 만들 때도 변경한 `deployment.tf`가 요구하는 입력은 전달한다. 4편의 인증정보·개인키 경로에 더해 `TF_VAR_bundle_url`과 `TF_VAR_bundle_sha256`도 시험 때의 값으로 설정한다. 값은 시험 기록이나 State의 `terraform_data.deploy` 교체 조건에서 확인할 수 있다. staging 파일을 지웠다고 State까지 지우지는 않는다.

---

## 7. 실패 위치에 따라 판단하기

| 실패 위치 | 최종 release·current | 남는 결과·다음 확인 |
| --- | --- | --- |
| 빌드·staging 업로드 | 변경 없음 | 로컬 TAR·업로드 로그. 생성된 staging 파일은 정리 Step 대상 |
| VM 생성·SHA256 검증·설치 | 변경 없음 | 생성된 VM과 State·로컬 TAR 유지. 설치 전 해시부터 확인 |
| Ansible·기본 연결 시험 | 변경 없음 | 첫 VM의 배포 로그와 서비스 상태 확인 |
| 시험 성공, 최종 게시 전 해시 불일치 | 변경 없음 | staging 기록·시험 결과·로컬 TAR 중 무엇이 달라졌는지 확인 |
| 최종 게시 도중 | 일부 반영 가능 | 버전 경로·채널 정보·HAProxy 목적지 확인 |
| 최종 게시 성공, staging 정리 실패 | 발행 완료 | Job은 실패할 수 있어도 무조건 재배포하지 않음. staging 정리만 재시도 |

VM이 남은 상태에서 Workflow 전체를 다시 실행하면 4편의 보호 확인에서 중단된다. **실패한 Job이라는 이유만으로 VM 생성부터 반복하지 않는다.** 특히 최종 게시가 이미 끝난 경우에는 배포 재시험과 후보 정리 재시도를 구분한다.

**적용 후 확인할 기준**

- 의도적으로 기본 시험을 실패시키면 최종 게시 Step이 실행되지 않고 current가 이전 주소를 유지하는지.
- 정상 시험에서는 staging 기록·시험 결과·최종 TAR의 SHA256이 일치하는지.
- 시험 후 같은 TAR를 다시 빌드하지 않는지.
- 정리 Step이 다른 후보나 최종 저장소의 파일을 삭제하지 않는지.
- 시험 VM과 State가 자동 삭제되지 않는지.

OpenTofu의 `apply` 성공은 예제에 넣은 설치·시험 명령의 정상 종료다. 현재 기본 시험은 컨테이너 기동과 Ansible 연결 확인까지이며, OpenStack API·인스턴스·스토리지 기능 검증은 팀에서 정한 명령을 추가해 범위를 넓힌다.

---

## 8. 참고 자료

- [다음: OpenTofu 입문 가이드 - 6 — OpenStack 기능 시험과 VM 자동 정리](2026-10-15-opentofu-functional-test-cleanup.md)
- [OpenTofu 입문 가이드 - 3: 첫 VM에서 TAR 설치·Ansible 실행](2026-10-12-opentofu-ansible-deploy.md)
- [OpenTofu 입문 가이드 - 4: Gitea Runner와 태그 연결](2026-10-14-opentofu-gitea-runner.md)
- [Nexus Raw Repositories](https://help.sonatype.com/en/raw-repositories.html)
- [Nexus Assets API — 조회·개별 삭제](https://help.sonatype.com/en/assets-api.html)
- [Nexus Cleanup·Compact](https://help.sonatype.com/en/cleanup-policies.html)
- [Gitea Actions](https://docs.gitea.com/usage/actions/quickstart/)
- [OpenTofu 입력 변수](https://opentofu.org/docs/v1.10/language/values/variables/)
- [OpenTofu Provisioner의 순서와 실패 처리](https://opentofu.org/docs/v1.10/language/resources/provisioners/syntax/)
