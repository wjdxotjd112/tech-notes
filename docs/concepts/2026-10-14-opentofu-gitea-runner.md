---
title: "OpenTofu 입문 가이드 - 4"
summary: "4편: 태그 push로 Gitea Runner에서 OpenTofu를 실행한다. 발행한 TAR를 VM 4대에 배포하고 Ansible 결과를 Actions에서 확인한다."
summary_style: editorial
date: 2026-10-14
category: 개념
tags:
  - 가이드
  - Automation
  - OpenStack
---

<section class="editorial-summary editorial-summary--text-only" aria-labelledby="editorial-summary-title">
  <div class="editorial-summary-layout">
    <div class="editorial-summary-copy">
      <span class="editorial-summary-label">이 가이드의 흐름</span>
      <h2 id="editorial-summary-title" class="editorial-summary-title">태그를 올리면 Runner가 패키징 다음에 배포 시험까지 이어서 실행한다.</h2>
      <p>수동으로 실행하던 OpenTofu 프로젝트를 Gitea Actions에 연결한다. 기존 파이프라인이 Nexus에 TAR를 게시하면 Runner가 VM 4대를 준비하고, 첫 VM에서 해당 릴리스의 TAR를 설치한다. Ansible의 실행 로그와 성공 여부는 Actions에서 확인한다.</p>
    </div>
  </div>
  <p class="editorial-summary-result"><span><strong>태그 → 패키징·게시 → VM 생성 → deploy.sh → Ansible</strong>. 시험 후 VM과 State는 남겨 두며, staging과 자동 삭제는 이번 구성에서 제외한다.</span></p>
</section>

[3편](2026-10-12-opentofu-ansible-deploy.md)의 VM 생성·SSH 확인·배포 코드를 그대로 이어서 사용한다. 이번 편에서 바꾸는 것은 **실행을 시작하는 방법과 시험할 TAR의 선택**이다. 터미널에서 직접 `tofu apply`를 실행하는 대신, 릴리스 태그 push가 Workflow를 시작한다.

---

## 1. 패키징과 배포 시험을 한 흐름으로 연결

<figure class="flow" aria-label="태그 push부터 Ansible 결과까지의 실행 순서">
  <ol>
    <li>태그 push</li>
    <li>TAR 생성·Nexus 게시</li>
    <li>OpenTofu·VM 배포</li>
    <li>Ansible 결과 확인</li>
  </ol>
</figure>

| 구성 요소 | 담당하는 일 |
| --- | --- |
| Gitea Actions | 태그 이벤트를 받아 Workflow의 작업 순서를 관리 |
| Gitea Runner | 실제 명령 실행. 이번 구성은 컨테이너가 아닌 호스트 실행 방식 |
| 사내 Nexus | 기존 파이프라인이 생성한 릴리스 TAR 제공 |
| Runner의 OpenTofu | vCenter에 VM 4대 생성 요청, 모든 VM의 SSH 준비 확인 |
| 첫 VM `runner01` | 해당 태그의 TAR 다운로드·해제, `deploy.sh` 실행 |
| 첫 VM의 Ansible 컨테이너 | TAR 안의 inventory와 main.yml로 노드에 배포 |

Workflow는 Gitea가 읽는 **작업 순서 파일**이고, Runner는 그 명령을 실행하는 **실행 서버**다. OpenTofu의 SSH 원격 실행 결과도 Runner를 거쳐 Gitea에 전달된다. [Gitea Runner의 역할](https://docs.gitea.com/runner/)

기존 `.gitea/workflows/publish-manifest.yaml`의 패키징 단계 **다음에 시험 단계 하나를 추가**한다. 별도 Workflow를 만들어 같은 태그에 동시에 실행하면 TAR가 완성되기 전에 다운로드할 수 있으므로, 하나의 Job 안에서 순서대로 연결한다. Git도 기존의 태그 기준 shallow clone을 그대로 사용하며 다시 clone하지 않는다.

!!! warning "이번 구성은 발행 후 시험"
    TAR 게시와 current 채널 갱신은 기존 패키징 단계에서 먼저 진행된다. 뒤의 배포 시험이 실패하더라도 게시된 TAR나 current가 자동으로 되돌아가지는 않는다. 시험 통과 후에만 발행하는 방식은 staging·승격 단계가 필요한 별도 구성이다.

이번 편의 자동 시험 완료 기준은 **VM 준비 → Private Nexus·배포 컨테이너 기동 → Ansible 정상 종료**다. OpenStack 기능 테스트 명령은 항목을 정한 뒤 이 마지막 단계에 연결한다.

---

## 2. Runner에서 먼저 준비할 것

이미 패키징을 수행하는 systemd Runner를 사용한다. Runner 설치·등록을 다시 진행할 필요는 없다. 우선 실제 서비스 계정과 실행 파일을 확인한다.

```bash title="Runner 서버 — 서비스와 도구 확인"
systemctl show gitea-runner -p User -p ExecStart
command -v tofu bash curl awk flock ssh scp
tofu version
```

`User=`가 비어 있으면 systemd의 기본 실행 계정은 root다. `User=gitea-runner`라면 터미널의 root가 아니라 **gitea-runner 계정이** 프로젝트와 SSH 개인키를 읽을 수 있어야 한다. 이 글의 경로 예시는 이 전용 계정을 기준으로 한다.

<details class="analysis-toggle" markdown="1">
<summary>Runner 라벨과 실행 제한 시간 확인</summary>

Runner의 실제 `ExecStart`가 사용하는 config.yaml에서 다음 항목을 확인한다. 기존 파일의 다른 설정은 유지하고 필요한 값만 조정한다.

```yaml title="/etc/gitea-runner/config.yaml — 관련 항목"
runner:
  capacity: 1
  timeout: 6h
  labels:
    - "private-cloud-release:host"
```

- `private-cloud-release`는 Workflow의 `runs-on` 이름이다. 이미 다른 라벨을 쓰면 양쪽 이름을 맞춘다.
- `:host`는 해당 Job을 Runner 서버에서 직접 실행한다는 의미다. Workflow에는 `:host`를 붙이지 않는다.
- `capacity: 1`은 이 Runner의 동시 Job 수 제한이다. 다른 Runner와 수동 OpenTofu 실행까지 막아 주지는 않는다.
- `6h`는 패키징과 설치 시간을 위한 예시다. Job의 `timeout-minutes`와 Gitea 서버의 작업 제한도 함께 확인한다. 셋 중 짧은 제한에서 작업이 중단될 수 있다.

Runner 설정 변경은 실행 중인 작업이 없는 시점에 진행한다. 재시작이 필요한 경우 변경 전 config.yaml을 보관하고, 해당 systemd 서비스에만 적용한다. [Runner 라벨](https://docs.gitea.com/runner/labels/), [Runner 설정과 timeout](https://docs.gitea.com/runner/reference/config-example/)

</details>

**접속은 두 경로를 확인한다.** Runner에서 vCenter로는 API 요청, Runner에서 생성한 VM으로는 SSH 명령을 보낸다. 첫 VM에서는 사내 Nexus의 릴리스 TAR에 접근할 수 있어야 한다.

- OpenTofu: [2편](../design/2026-10-08-opentofu-vsphere-rocky.md)의 버전 조건과 vSphere Provider 고정 버전 사용.
- VM 구성: `runner01`~`runner04`, 예약한 고정 IP, 템플릿 NIC와 Port group 순서 유지.
- SSH: Runner 계정의 개인키와 템플릿에 전달하는 `ssh_public_key`가 같은 키 쌍이어야 한다.
- 배포 설정: TAR 내부 inventory와 main.yml에 테스트 VM의 IP·역할·디스크 설정을 미리 반영.

Runner에 inventory·main.yml을 따로 준비하거나 복사하는 단계는 추가하지 않는다.

---

## 3. OpenTofu 프로젝트와 State를 유지할 위치

Job 작업공간은 실행이 끝난 뒤 정리될 수 있다. **OpenTofu 프로젝트는 Job 작업공간 밖의 고정 디렉터리**에서 실행한다. State는 코드의 리소스와 실제 VM을 연결하는 기록이므로 VM을 남기는 동안 함께 보관해야 한다. [OpenTofu State](https://opentofu.org/docs/v1.10/language/state/)

```text
/var/lib/gitea-runner/opentofu/contrabass-packaging/
├── versions.tf
├── providers.tf
├── variables.tf
├── main.tf
├── outputs.tf
├── guest-init.sh.tftpl
├── deployment.tf
├── lab.auto.tfvars
├── .terraform.lock.hcl
├── terraform.tfstate          # 실행 결과: Git에 넣지 않음
└── deploy.tfplan              # 실행 계획: Git에 넣지 않음
```

2·3편에서 준비한 프로젝트를 이 위치에 둔다. 이미 수동 시험으로 VM을 만들었다면 **기존 프로젝트 경로를 그대로 지정하거나 State까지 함께 이전**한다. 코드만 복사하고 빈 State로 시작하면 기존 VM을 관리하지 못한다. 기존 시험 VM은 다음 절의 보호 확인에 걸리므로 결과를 확인하고 수동 정리한 뒤 첫 자동 시험을 시작한다.

이 예제는 고정된 시험 환경을 위한 프로젝트다. 릴리스에 담을 Ansible 코드는 태그의 TAR에서 가져오고, VM을 만드는 OpenTofu 코드는 이 Runner 프로젝트에서 관리한다.

기존 통합 설정 파일에 아래 **두 경로만 추가**한다. Nexus 주소와 저장소 이름은 이미 패키징에서 사용하는 값을 그대로 읽는다.

```bash title="/etc/gitea-runner-env/bundle-pipeline.env — 추가 항목"
TOFU_PROJECT_DIR=/var/lib/gitea-runner/opentofu/contrabass-packaging
TOFU_SSH_PRIVATE_KEY=/var/lib/gitea-runner/.ssh/id_ed25519
```

이번 단계가 기존 설정에서 읽는 값:

| 변수 | 예시·용도 |
| --- | --- |
| `NEXUS_URL` | `https://nexus.example.com` — 사내 Nexus 주소 |
| `BUNDLE_REPOSITORY` | `raw-release-bundle` — 최종 TAR 저장소 |
| `TOFU_PROJECT_DIR` | OpenTofu 코드와 State를 보관하는 고정 경로 |
| `TOFU_SSH_PRIVATE_KEY` | VM의 공개키와 짝이 맞는 Runner 개인키 파일 |

설정 파일을 `source`하는 Step만 이 값을 읽는다. 앞 Step에서 읽은 셸 변수는 다음 Step에 자동으로 이어지지 않으므로, 시험 Step에서도 같은 파일을 읽는다. 이 예제는 2·3편과 같은 **로컬 Backend의 기본 workspace**를 사용한다. 원격 Backend나 별도 workspace를 쓰는 프로젝트라면 그 State를 조회하도록 확인 부분도 맞춰야 한다.

!!! warning "변수 파일의 URL 지정은 제거"
    3편에서 `lab.auto.tfvars`에 넣은 `bundle_url`은 이번 구성에서는 제거한다. Workflow가 `TF_VAR_bundle_url`로 시험할 URL을 전달한다. `.tfvars`의 값은 `TF_VAR_*`보다 우선하므로 남겨 두면 태그별 URL 대신 기존 current URL을 사용할 수 있다. `ssh_private_key_path`도 이 파일에 중복 지정하지 않는다. [변수 입력 우선순위](https://opentofu.org/docs/v1.10/language/values/variables/#variable-definition-precedence)

`deployment.tf`의 `variable "bundle_url"` 선언과 기본값은 남겨도 된다. Workflow 환경변수가 기본값을 덮어쓴다.

---

## 4. 인증정보는 Gitea Secrets로 전달

대상 저장소의 **설정 → Actions → Secrets**에서 아래 이름으로 등록한다. UI 언어에 따라 비밀·시크릿 등으로 표시될 수 있다. 값은 Workflow나 Git에 적지 않는다. [Gitea Secrets](https://docs.gitea.com/usage/actions/secrets/)

| Secret 이름 | 들어갈 값 | 전달되는 환경변수 |
| --- | --- | --- |
| `VSPHERE_USER` | vCenter API 계정 | `VSPHERE_USER` |
| `VSPHERE_PASSWORD` | API 계정 비밀번호 | `VSPHERE_PASSWORD` |
| `NEXUS_DOWNLOAD_USER` | TAR 읽기 권한을 가진 Nexus 계정 | `TF_VAR_nexus_user` |
| `NEXUS_DOWNLOAD_PASSWORD` | 다운로드 계정 비밀번호 | `TF_VAR_nexus_password` |

vCenter 계정은 Provider가 읽고, `TF_VAR_*`는 OpenTofu가 같은 이름의 변수에 전달한다. 예를 들어 `TF_VAR_nexus_user`는 `variable "nexus_user"`의 입력이다. [환경변수 입력](https://opentofu.org/docs/v1.10/cli/config/environment-variables/#tf_var_name), [vSphere Provider 인증](https://github.com/vmware/terraform-provider-vsphere/blob/v2.17.1/docs/index.md)

기존 Git clone·Nexus 게시용 Secrets는 유지한다. Runner 등록 토큰은 위 API·다운로드 인증정보와 다르며, SSH 개인키는 Runner의 파일로 사용한다. 이번 시험 Step에서 Git 인증이나 추가 clone은 필요 없다.

State와 저장된 plan에도 민감한 값이 포함될 수 있다. 디렉터리 접근을 Runner 계정으로 제한하고 Git·공개 로그·공개 산출물에 올리지 않는다. 디버깅을 위해 `set -x`나 환경변수 전체 출력을 추가하지 않는다.

---

## 5. 기존 Workflow 마지막에 시험 Step 추가

파일은 기존 **`.gitea/workflows/publish-manifest.yaml` 하나**를 사용한다. 이벤트는 태그 push이고 Job은 패키징과 시험을 순서대로 실행한다. 아래는 상단에서 확인할 항목이며 기존 env·steps는 유지한다.

```yaml title="publish-manifest.yaml — 이벤트·Job 관련 항목"
"on":
  push:
    tags:
      - "v*"

jobs:
  release:
    runs-on: private-cloud-release
    timeout-minutes: 360
```

이미 수동 실행용 `workflow_dispatch`와 `release_tag` 입력이 있으면 그대로 둔다. 아래 Step은 이벤트 이름 대신 앞 단계에서 만든 `release-info.yaml`의 `release_tag`를 읽으므로 태그 push와 기존 수동 실행에서 같은 릴리스를 선택한다.

**TAR 게시가 성공한 다음**, 기존 `jobs.release.steps` 마지막에 아래 Step을 추가한다. `release-info.yaml`은 앞의 manifest 게시 Step이 만든 작업공간 파일이며, `release_tag: v4.0.7` 같은 항목이 있어야 한다.

<details class="analysis-toggle" open markdown="1">
<summary>추가할 시험 Step 전체</summary>

```yaml title="publish-manifest.yaml — 기존 steps 마지막에 추가"
      - name: Test release with OpenTofu
        shell: bash
        env:
          VSPHERE_USER: ${{ secrets.VSPHERE_USER }}
          VSPHERE_PASSWORD: ${{ secrets.VSPHERE_PASSWORD }}
          TF_VAR_nexus_user: ${{ secrets.NEXUS_DOWNLOAD_USER }}
          TF_VAR_nexus_password: ${{ secrets.NEXUS_DOWNLOAD_PASSWORD }}
        run: |
          set -euo pipefail
          umask 077
          source /etc/gitea-runner-env/bundle-pipeline.env

          : "${TOFU_PROJECT_DIR:?Set TOFU_PROJECT_DIR}"
          : "${TOFU_SSH_PRIVATE_KEY:?Set TOFU_SSH_PRIVATE_KEY}"
          : "${NEXUS_URL:?Set NEXUS_URL}"
          : "${BUNDLE_REPOSITORY:?Set BUNDLE_REPOSITORY}"
          : "${VSPHERE_USER:?Set VSPHERE_USER secret}"
          : "${VSPHERE_PASSWORD:?Set VSPHERE_PASSWORD secret}"
          : "${TF_VAR_nexus_user:?Set NEXUS_DOWNLOAD_USER secret}"
          : "${TF_VAR_nexus_password:?Set NEXUS_DOWNLOAD_PASSWORD secret}"
          test -r "${TOFU_SSH_PRIVATE_KEY}"
          test -s "${TOFU_PROJECT_DIR}/deployment.tf"

          tag="$(awk -F': *' '$1 == "release_tag" {gsub(/"/, "", $2); print $2; exit}' release-info.yaml)"
          [[ "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
          version="${tag#v}"
          line="${version%.*}"
          export TF_VAR_bundle_url="${NEXUS_URL%/}/repository/${BUNDLE_REPOSITORY}/releases/${line}/${tag}/contrabass-engine-deploy.tar"
          export TF_VAR_ssh_private_key_path="${TOFU_SSH_PRIVATE_KEY}"
          export TF_IN_AUTOMATION=1
          export TF_INPUT=0

          cd "${TOFU_PROJECT_DIR}"
          exec 9>.ci.lock
          flock -n 9 || { echo 'OpenTofu project is already in use.' >&2; exit 1; }

          tofu init -input=false -no-color
          tofu fmt -check
          tofu validate -no-color

          # 이전 VM은 남긴다. 자동 재구축·설치 덮어쓰기를 하지 않는다.
          if [[ -f terraform.tfstate ]]; then
            managed="$(tofu state list)"
            if grep -q '^vsphere_virtual_machine\.vm\[' <<< "${managed}"; then
              echo 'Previous test VMs remain. Review and clean them manually before the next test.' >&2
              exit 1
            fi
          fi

          echo "Test release: ${tag}"
          tofu plan -input=false -no-color -out=deploy.tfplan
          tofu apply -input=false -no-color deploy.tfplan
          tofu output -json vm_info > vm-info.json
```

</details>

순서는 **초기화 → 형식·문법 확인 → 이전 VM 확인 → plan → apply**다. 저장한 plan 파일을 apply하므로 확인 질문 없이 실행된다. 이 Workflow는 전용 시험 환경에서만 사용한다. [자동화용 plan 저장](https://opentofu.org/docs/v1.10/cli/commands/plan/), [저장된 plan 적용](https://opentofu.org/docs/v1.10/cli/commands/apply/)

핵심은 `TF_VAR_bundle_url`이다. 예를 들어 `v4.0.7`이면 다음 **실제 버전 경로**를 첫 VM에 전달한다.

```text
https://nexus.example.com/repository/raw-release-bundle/releases/4.0/v4.0.7/contrabass-engine-deploy.tar
```

`channels/current`는 그 사이 다른 릴리스가 발행되면 대상이 바뀔 수 있다. 태그별 경로로 시험해야 **이번 실행이 만든 TAR와 실제 시험한 TAR가 같아진다.** TAR 다운로드·해제는 3편의 `deployment.tf`가 첫 VM에서 수행하므로 Runner에 대용량 TAR를 먼저 받을 필요가 없다.

`flock`은 같은 프로젝트에 대한 시험 Step의 동시 실행을 막는 파일 잠금이다. State 잠금을 끄지는 않는다. 다른 Runner나 수동 실행도 이 프로젝트를 사용한다면 같은 잠금 규칙을 지키고, CI 실행 중에 수동 apply를 하지 않는다.

**컨테이너 안의 셸은 이미지에 맞춘다.** 3편의 Ansible 명령에서 컨테이너에 bash가 없다면 아래처럼 `sh`로 실행한다. Runner와 VM 외부의 스크립트는 계속 bash와 `pipefail`을 사용한다.

```hcl title="deployment.tf — 두 번째 remote-exec의 Ansible 명령"
"nerdctl exec okestro-os-ansible sh -c 'cd /root/okestro/okestro-openstack && ansible-playbook -i inventory/inventory.ini main.yml' 2>&1 | tee /var/log/contrabass-ansible.log",
```

TAR가 선택되고 나면 나머지 동작은 3편과 같다. 모든 VM의 SSH 준비를 기다리고, 첫 VM에서 `deploy.sh`를 실행한다. deploy.sh의 IP는 `runner01`의 첫 번째 NIC IP에서 가져오므로 예제에서는 `192.0.2.101`이다. 컨테이너가 뜬 뒤 inventory·main.yml을 따로 덮어쓰지 않는다.

---

## 6. 태그를 push하고 Actions에서 확인

Workflow 변경을 먼저 commit·push하고, **그 Workflow를 포함한 릴리스 커밋**에 새 태그를 만든다. 태그의 숫자와 manifest의 release는 기존 패키징 규칙대로 일치시킨다.

```bash title="개발자 작업 디렉터리 — 릴리스 태그 생성·push"
git status --short
git show --stat HEAD
git tag -a v4.0.7 -m 'Release v4.0.7'
git push origin v4.0.7
```

`v4.0.7`은 예시다. 이미 발행한 태그를 덮어쓰지 않고 실제 새 버전으로 바꾼다. 코드만 변경한 릴리스와 이미지·manifest를 변경한 릴리스 모두 같은 태그 흐름을 사용한다.

저장소의 **Actions → 해당 태그 실행 → release Job → Test release with OpenTofu**를 연다. 저장소 설정에서 Actions가 활성화돼 있고 해당 Runner가 온라인이어야 한다. [Gitea Actions 활성화와 Workflow 위치](https://docs.gitea.com/usage/actions/quickstart/)

| 화면에서 확인할 부분 | 의미 |
| --- | --- |
| 패키징 Step 완료 | manifest 게시·TAR 생성·Nexus 게시 성공 |
| `vsphere_virtual_machine.vm["runner01"]` 등의 생성 로그 | vCenter의 VM 생성·초기 설정 진행 |
| `terraform_data.ssh_ready` | VM의 SSH와 guest-init 완료 확인 |
| `terraform_data.deploy (remote-exec)` | 첫 VM에서 설치·Ansible 실행 |
| Ansible `PLAY RECAP` | 노드별 실행 결과. 실패·접속 불가 여부 확인 |
| 시험 Step 성공 | 예제에 포함한 VM 준비·설치·Ansible 명령의 정상 종료 |

Runner는 stdout·stderr를 Gitea에 전달하므로 수동 `tofu apply`에서 보던 진행 로그를 Actions에서 볼 수 있다. 다만 인증정보를 사용하는 Provisioner의 출력은 민감정보 보호 때문에 숨겨질 수 있다. 3편처럼 다운로드·설치 블록과 Ansible 블록을 나누고, `-concise`로 로그를 줄이지 않는다. [Provisioner의 민감정보와 로그](https://opentofu.org/docs/v1.10/language/resources/provisioners/syntax/#suppressing-provisioner-logs-in-cli-output)

`Still creating...`은 완료를 기다리며 출력하는 경과 시간이다. 서비스 건강 상태를 확인하는 기능 테스트나 설치 명령을 반복 실행한다는 뜻이 아니다.

시험이 끝나면 첫 VM에 접속해 필요한 결과를 확인한다.

```bash title="첫 VM — 결과 확인"
nerdctl ps
nerdctl exec okestro-os-ansible true
tail -n 80 /var/log/contrabass-ansible.log
```

**Ansible 정상 종료와 OpenStack 기능 정상은 별개의 기준**이다. 이후 정한 기능 테스트가 실패 시 0이 아닌 종료 코드를 반환하도록 마지막 Provisioner 또는 후속 Step에 연결하면 전체 시험 결과에 반영할 수 있다.

---

## 7. VM을 남기는 정책과 다음 실행

이번 Workflow에는 `tofu destroy`와 자동 VM 삭제 Step을 넣지 않는다. 성공·실패 모두 VM과 State를 남겨 콘솔·컨테이너·로그를 확인할 수 있게 한다.

| 상황 | 이번 구성의 동작 |
| --- | --- |
| 처음 실행, 이전 시험 VM 없음 | 태그별 TAR 게시 후 VM 4대 생성·배포 시험 |
| 패키징 실패 | 시험 Step 실행 안 함 |
| VM 생성·설치 중 실패 | Job 실패. 이미 생성된 VM·State는 유지 |
| 성공 후 같은 실행 재시도 | 이전 VM 확인에서 중단. 설치를 무조건 반복하지 않음 |
| VM을 남긴 상태로 새 태그 push | 패키징은 진행. 시험 Step은 이전 VM 확인에서 중단 |
| 이전 환경을 수동 정리한 뒤 새 시험 | 같은 고정 IP·이름으로 다시 생성 가능 |

**자동 삭제를 하지 않으면서 같은 고정 IP 4대를 쓰기 때문에, 다음 시험 전에 수동 정리가 필요하다.** 새 태그라고 기존 OpenStack 클러스터에 다시 설치하거나, URL 변경만으로 VM이 초기 상태로 돌아가는 것은 아니다. 시험 Step의 보호 확인은 이를 막기 위한 것이다.

<details class="analysis-toggle" markdown="1">
<summary>남아 있는 VM 확인과 수동 정리</summary>

Runner에서 기존과 같은 프로젝트·계정·vCenter 인증정보로 확인한다.

```bash title="Runner — 현재 관리 대상 확인"
source /etc/gitea-runner-env/bundle-pipeline.env
cd "${TOFU_PROJECT_DIR}"
tofu state list
tofu output -json vm_info
```

VM과 로그를 보관할지 먼저 결정한다. 수동 삭제는 VM 내부 Nexus 데이터와 설치 결과도 제거한다. CI가 실행 중이면 중단하고, 삭제 대상과 State를 확인한 뒤 진행한다.

```bash title="Runner — 인증 입력 후 삭제 계획 확인"
set -euo pipefail
umask 077
read -r -p 'vCenter API 계정: ' VSPHERE_USER
read -r -s -p 'vCenter API 비밀번호: ' VSPHERE_PASSWORD
printf '\n'
read -r -p 'Nexus 다운로드 계정: ' TF_VAR_nexus_user
read -r -s -p 'Nexus 다운로드 비밀번호: ' TF_VAR_nexus_password
printf '\n'
export VSPHERE_USER VSPHERE_PASSWORD TF_VAR_nexus_user TF_VAR_nexus_password
export TF_VAR_ssh_private_key_path="${TOFU_SSH_PRIVATE_KEY}"

exec 9>.ci.lock
flock -n 9
tofu plan -destroy -out=destroy.tfplan
tofu show destroy.tfplan
```

대상이 이 프로젝트의 테스트 VM인지 확인한 뒤, 같은 셸에서 저장한 계획을 적용한다.

```bash title="Runner — 확인한 삭제 계획 적용"
tofu apply destroy.tfplan
flock -u 9
unset VSPHERE_USER VSPHERE_PASSWORD TF_VAR_nexus_user TF_VAR_nexus_password
```

State 파일만 지워 VM을 잊게 만드는 방법은 사용하지 않는다. 실제 VM이 남아 있으면 이름·고정 IP 충돌이 발생할 수 있다. 중간 실패의 재실행도 원인 확인 없이 기존 설치를 덮어쓰는 대신, 시험 환경을 정리하고 다시 시작한다.

</details>

!!! tip "처음 연결할 때의 확인 기준"
    태그별 TAR가 선택되는지, Runner 계정이 프로젝트·개인키를 읽는지, VM 4대와 SSH 확인 뒤 첫 VM에서 설치가 시작되는지 확인한다. Ansible 실패가 Job 실패로 전달되는지도 확인한다. VM 정리와 기능 테스트를 연결하기 전에는 이 범위를 전체 기능 검증으로 확대하지 않는다.

---

## 8. 참고 자료

- [OpenTofu 입문 가이드 - 2: VMware VM과 게스트 초기화](../design/2026-10-08-opentofu-vsphere-rocky.md)
- [OpenTofu 입문 가이드 - 3: TAR 설치·Ansible 원격 실행](2026-10-12-opentofu-ansible-deploy.md)
- [Gitea Runner와 실행 방식](https://docs.gitea.com/runner/)
- [Runner 라벨](https://docs.gitea.com/runner/labels/)
- [Runner 설정](https://docs.gitea.com/runner/reference/config-example/)
- [Gitea Actions와 Workflow](https://docs.gitea.com/usage/actions/quickstart/)
- [Gitea Secrets](https://docs.gitea.com/usage/actions/secrets/)
- [OpenTofu 환경변수](https://opentofu.org/docs/v1.10/cli/config/environment-variables/)
- [변수 파일과 입력 우선순위](https://opentofu.org/docs/v1.10/language/values/variables/)
- [plan](https://opentofu.org/docs/v1.10/cli/commands/plan/) · [apply](https://opentofu.org/docs/v1.10/cli/commands/apply/)
- [State](https://opentofu.org/docs/v1.10/language/state/) · [Provisioner 실행·실패 처리](https://opentofu.org/docs/v1.10/language/resources/provisioners/syntax/)
