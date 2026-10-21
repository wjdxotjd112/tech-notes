---
title: "OpenTofu 입문 가이드 - 7"
summary: "7편: PR 승인과 Tag를 릴리스의 기준으로 삼고, 배포 시험 실행·생략을 선택한다. Nexus 역할, 사내·폐쇄망 설치 인증, TAR 검증과 수동 Release 기록까지 운영 흐름을 정리한다."
summary_style: editorial
date: 2026-10-21
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
      <h2 id="editorial-summary-title" class="editorial-summary-title">릴리스 기준은 Tag로 남기고, 배포 시험 여부는 명시적으로 선택한다.</h2>
      <p>모든 수정에 VMware·OpenStack 배포 시험을 반복하지는 않는다. master 반영은 PR 승인으로 통제하고, 릴리스 Tag가 올라왔을 때 PR 라벨을 읽어 전체 시험 또는 시험 생략을 결정한다. 어느 쪽이든 재료와 최종 TAR의 무결성 검사는 유지한다.</p>
    </div>
  </div>
  <p class="editorial-summary-result"><span><strong>개발 → 승인·merge → Tag → 시험 선택 → 공식 게시</strong>. 사업수행팀은 같은 channel 주소에서 TAR를 받고, 고객사에서는 인증 입력 없이 Private Nexus와 배포 컨테이너를 준비한다.</span></p>
</section>

[6편](2026-10-15-opentofu-functional-test-cleanup.md)까지는 배포·기능 시험을 통과해야 공식 패키지를 게시했다. 이번 편은 그 흐름에 **시험 생략 선택과 팀 운영 규칙**을 추가한다. Workflow는 `.gitea/workflows/publish-manifest.yaml` 하나를 유지한다.

---

## 1. push·승인·merge·Tag는 서로 다른 동작

PR(Pull Request)은 변경한 코드를 대상 브랜치에 합쳐 달라는 요청이다. **승인**은 검토 결과이고, **merge**는 코드를 합치는 동작이다. 승인 버튼을 누른 것만으로 merge나 패키징이 실행되지는 않는다.

<figure class="flow" aria-label="개발에서 릴리스까지">
  <ol>
    <li>develop 수정·push</li>
    <li>master PR 승인·merge</li>
    <li>merge 커밋에 Tag</li>
    <li>Runner 패키징</li>
  </ol>
</figure>

| 동작 | 결과 | 릴리스 Workflow |
| --- | --- | --- |
| develop에 push | 개발 코드 갱신 | 실행하지 않음 |
| PR 승인 | 검토 결과 기록 | 실행하지 않음 |
| master로 PR merge | 정식 코드 기준 갱신 | 실행하지 않음 |
| `v4.1.2` Tag push | 특정 커밋을 릴리스로 지정 | 실행 |
| Actions 수동 실행 | 기존 Tag를 지정해 재시도 | 실행 |

`master`, `develop`은 이동하는 브랜치다. Tag는 출시할 특정 커밋을 가리키는 이름이다. Git Tag, Gitea Release, Nexus TAR는 같은 것이 아니다.

- **Tag:** 어떤 코드로 만들었는가.
- **Gitea Release:** 무엇이 바뀌었고 어디서 받는가.
- **Nexus TAR:** 실제 고객사로 가져가는 배포물.

---

## 2. master는 승인 후 merge, develop은 직접 push

Gitea 저장소의 **Settings → Branches**에서 브랜치 보호 규칙을 설정한다. 사용자가 저장소에 쓰기 권한을 갖는 것과 보호 브랜치에 직접 push할 수 있는 것은 별개다. [Gitea 브랜치 보호](https://docs.gitea.com/1.25/usage/access-control/protected-branches/)

| 설정 | master | develop |
| --- | --- | --- |
| 직접 push | 금지 | 허용 |
| force push | 금지 | 금지 |
| PR 필수 승인 | 1명 | 필수 아님 |
| 새 커밋 추가 시 이전 승인 해제 | 사용 | 사용 |
| 거절된 리뷰가 있으면 merge 차단 | 사용 | 사용 |
| 관리자 승인 조건 우회 | 금지 | 금지 |
| master merge 담당자 | 지정한 담당자만 허용 | 별도 제한 없음 |

팀원은 개인 계정으로 저장소 쓰기 권한을 받고 develop에서 작업한다. master로 보낼 때 PR을 만들고 **작성자가 아닌 검토자**가 승인한 뒤 담당자가 merge한다. feature 브랜치를 반드시 쓰게 할지, develop에서 바로 수정할지는 별도 팀 정책으로 남겨 둔다.

**관리자 1명만 있는 저장소에서는 이 승인 절차를 완성할 수 없다.** 실제 다른 팀원 계정에 검토 가능한 권한을 부여해야 한다. 이번 변경도 develop에 올리고 master 대상 PR로 남겼으며, 자기 승인이나 관리자 우회로 merge하지 않았다.

Tag는 **Settings → Tags**에서 `v*` 보호 규칙을 만들고 릴리스 담당자만 생성·수정할 수 있게 한다. 보호 Tag가 허용된 담당자까지 영구적으로 수정을 못 하게 만드는 것은 아니다. 기존 Tag를 지우거나 같은 이름으로 다시 올리지 않는 운영 원칙도 필요하다. [Gitea Tag 보호](https://docs.gitea.com/1.25/usage/access-control/protected-tags/)

!!! warning "보호 규칙과 보안 패치는 별개"
    확인한 Gitea 버전은 1.25.4다. 이 버전은 PR 대상 브랜치를 바꿀 때 이전 승인 상태가 남는 공식 보안 공지의 영향 범위에 포함된다. 보호 규칙만으로 해당 취약점이 해결되지는 않는다. 업그레이드는 백업·호환성 점검과 별도 일정으로 다룬다. [Gitea 공식 보안 공지](https://github.com/go-gitea/gitea/security/advisories/GHSA-w5pg-649r-p6gg)

---

## 3. PR 라벨로 배포 시험을 선택

PR을 검토하는 담당자가 웹 PR 페이지에서 `release:skip-test` 라벨을 붙인다. 라벨이 없으면 전체 시험이다. 일반적인 코드 승인과 배포 시험 생략 승인은 구분해서 판단한다.

| 선택 | VMware·Ansible·OpenStack 시험 | staging TAR 업로드 | 공식 게시·channel 갱신 |
| --- | --- | --- | --- |
| 라벨 없음: `full` | 실행 | 실행 | 시험 통과 후 |
| `release:skip-test`: `skip` | 생략 | 생략 | 재료·TAR 검증 후 |
| 전체 시험 실패 | 실패 처리 | 이번 후보 정리 | 게시하지 않음 |

`skip`은 검증 실패를 무시하는 옵션이 아니다. **시간이 오래 걸리는 배포 시험을 의도적으로 생략하는 선택**이다. 이미지 digest, Raw·바이너리 SHA256, 최종 TAR SHA256은 계속 확인한다.

<p class="subsection-title"><strong>3-1. 어떤 PR의 라벨을 읽는가</strong></p>

<div class="section-body" markdown="1">

`common.sh`의 `select_test_mode`가 Tag의 커밋에 연결된 PR을 Gitea API로 찾는다. 단순히 같은 이름의 라벨만 검색하지 않는다.

1. Tag와 `manifest.yaml`의 `release`가 일치하는지 확인.
2. 원격 Tag 커밋과 내려받은 소스의 HEAD가 같은지 확인.
3. 해당 커밋이 master 대상 PR의 실제 merge 커밋인지 확인.
4. 마지막 검토 대상 커밋에 유효한 승인이 있는지 확인.
5. 그 PR의 현재 라벨을 읽어 `full` 또는 `skip` 결정.

API 조회가 실패하거나 승인 조건을 확인할 수 없으면 중단한다. 오류를 시험 생략으로 처리하지 않는다. 일반 릴리스에서는 **PR을 merge한 정확한 커밋에 Tag를 생성**한다.

</div>

<p class="subsection-title"><strong>3-2. merge 후 Tag 생성</strong></p>

<div class="section-body" markdown="1">

먼저 PR에서 `release/manifest.yaml`의 `release: "4.1.2"`까지 검토·merge한다. 다음 명령은 개발 PC의 저장소에서 실행한다. 다른 PR이 추가로 merge됐다면 `origin/master` 대신 발행할 PR의 정확한 merge 커밋을 지정한다.

```bash title="확정한 merge 커밋에 Tag 생성"
git fetch origin master
git show origin/master:release/manifest.yaml
git tag -a v4.1.2 origin/master -m "Release v4.1.2"
git push origin v4.1.2
```

이미 존재하는 Tag에는 `-f`를 사용하지 않는다. 코드만 바뀌어도, 이미지·manifest만 바뀌어도 새 버전 Tag를 만든다. [git tag](https://git-scm.com/docs/git-tag)

</div>

<p class="subsection-title"><strong>3-3. skip으로 발행한 뒤 full로 다시 시험하려면</strong></p>

<div class="section-body" markdown="1">

같은 PR에서 `release:skip-test` 라벨을 제거하고 Actions 수동 실행에 기존 Tag를 넣는다. 재실행은 **그 시점의 PR 라벨**을 다시 읽는다. 별도 시험 모드 입력은 두지 않는다.

이미 발행된 TAR가 있으면 Nexus에서 그 TAR를 다시 받아 SHA256을 확인한 뒤 시험한다. 새 템플릿으로 같은 버전 TAR를 다시 만들지 않는다. 시험 결과는 별도 실행 기록으로 남기고 기존 Tag·manifest·TAR는 유지한다.

이는 이미 공개한 패키지를 뒤늦게 시험하는 것이다. 나중의 시험이 실패해도 이전에 공개된 TAR나 channel을 자동 회수하지는 않는다.

```text title="실행별 기록 위치"
raw-manifest/
└── executions/
    └── v4.1.2/
        ├── <run-id>-<attempt>-<시각>.yaml
        └── <다음 실행 기록>.yaml
```

각 기록에는 Tag·커밋·시험 모드·선택 근거·PR 번호·게시 여부·시험 결과·TAR SHA256을 남긴다. `skipped`를 `passed`로 기록하지 않는다. 버전별 불변 `release-info.yaml`에 시험 결과를 계속 덮어쓰지 않는 이유다.

</div>

---

## 4. 과거 계열만 수정할 때는 Tag에서 시작

master가 4.2 계열이어도 4.0만 고칠 수 있다. 원격 유지보수 브랜치를 계속 운영하지 않고, **로컬 임시 브랜치와 새 Tag**를 사용한다. 이 예외 경로는 master보다 오래된 계열에만 허용한다.

```bash title="4.0.5에서 4.0.6 패치 시작"
git fetch origin tag v4.0.5
git switch -c patch/4.0.6 v4.0.5
# 필요한 코드와 release/manifest.yaml의 release를 4.0.6으로 수정
git add release/manifest.yaml
# 나머지 수정 파일도 경로를 지정해 git add
git commit -m "Fix 4.0 release configuration"

# 전체 시험: [skip-test] 문구 없이 annotated Tag 생성
git tag -a v4.0.6 -m "Release v4.0.6"
git push origin v4.0.6
```

시험 생략이 필요하면 **Tag를 처음 만들 때** 다음과 같이 메시지에 남긴다. 위 명령과 둘 중 하나만 선택한다.

```bash title="과거 계열 패치의 시험 생략 선택"
git tag -a v4.0.6 -m "Release v4.0.6 [skip-test]"
git push origin v4.0.6
```

4.0.6이 완료되면 작업하지 않는 다른 브랜치로 이동한 뒤 로컬 `patch/4.0.6`을 삭제해도 **원격 Tag와 그 커밋은 남는다**. 4.0.7은 다시 `v4.0.6`에서 시작한다. master나 4.1·4.2 코드에는 자동으로 반영되지 않는다.

PR이 없는 현재·미래 계열의 새 Tag는 이 경로로 통과시키지 않는다. 정책 도입 전에 이미 발행한 Tag 목록은 `LEGACY_RELEASE_TAGS`에 명시하고 기존 버전 재시도만 전체 시험으로 허용한다. 앞으로 만드는 Tag를 이 예외 목록에 추가해서 승인 절차를 우회하지 않는다.

!!! note "오래된 Tag에는 오래된 Workflow도 들어 있다"
    예전 버전에서 새 패치를 만들 때는 현재 운영 정책에 맞는 Workflow와 설치 스크립트 변경도 필요한지 함께 확인한다. 과거 Actions의 재실행 버튼은 당시 Workflow를 재사용할 수 있다. 새 정책으로 기존 버전을 다시 처리하려면 **변경이 merge된 master의 수동 실행**에서 대상 Tag를 지정한다. 과거 패치 Tag 메시지는 바꾸지 않으므로, 시험 선택을 달리해야 한다면 새 패치 버전을 발행한다.

---

## 5. 하나의 Workflow에서 full과 skip 연결

전체 구조는 그대로다. Tag 소스는 한 번만 shallow clone하고, 동일 소스를 manifest 게시와 TAR 생성에 사용한다. 시험 선택 함수는 `/opt/gitea/bundle-builder/common.sh`에 모은다.

| 순서 | Step | 주요 동작 |
| --- | --- | --- |
| 1 | Shallow clone release tag | Tag 소스를 `--depth=1`로 받음 |
| 2 | Select tests from PR label or patch tag | `release-policy.yaml` 생성, `TEST_MODE` 전달 |
| 3 | Publish manifest, build bundle | manifest 불변 게시, 재료 검증·TAR 생성 또는 기존 TAR 재사용 |
| 4 | Fingerprint bundle and stage full-test candidate | TAR SHA256 기록. full만 staging 업로드 |
| 5 | Test release with OpenTofu | full만 VMware VM 생성·Ansible 배포 |
| 6 | Test OpenStack functions | full만 OpenStack 시험·시험 자원 정리 |
| 7 | Publish tested or explicitly skipped bundle | 같은 TAR인지 확인하고 공식 게시·channel 처리 |
| 8–9 | Clean test VMs / Clean staging candidate | 실제 시작 표시가 있는 자원만 정리 |
| 10 | Record release execution | 성공·실패·생략 결과 기록 |

full 경로의 시험·승격·정리 코드는 [5편](2026-10-15-opentofu-staging-release.md), [6편](2026-10-15-opentofu-functional-test-cleanup.md)의 구성을 이어 쓴다. 아래는 이번에 추가한 연결 부분이다.

<details class="analysis-toggle" markdown="1">
<summary>Workflow에서 시험 모드 전달과 공식 게시 조건 보기</summary>

설정은 `/etc/gitea-runner-env/bundle-pipeline.env`에서 읽는다. Git 소스를 받은 직후 다음 Step을 배치한다.

```yaml title="publish-manifest.yaml — 소스 clone 다음"
- name: Select tests from PR label or patch tag
  shell: bash
  run: |
    set -euo pipefail
    source /etc/gitea-runner-env/bundle-pipeline.env
    source "${BUNDLE_BUILDER_DIR}/common.sh"
    select_test_mode source "${MANUAL_RELEASE_TAG:-${EVENT_REF_NAME}}" release-policy.yaml
    mode="$(yaml_value release-policy.yaml test_mode)"
    [[ "${mode}" == full || "${mode}" == skip ]]
    printf 'TEST_MODE=%s\n' "${mode}" >> "${GITHUB_ENV}"
```

VMware 시험과 OpenStack 기능 시험 Step에는 각각 같은 조건을 붙인다. 실제 `run` 본문은 기존 시험 코드를 유지한다.

```yaml title="시험 Step의 실행 조건"
# 기존 Step의 run 본문은 그대로 두고 if만 추가
- name: Test release with OpenTofu
  if: env.TEST_MODE == 'full'
```

공식 게시 직전에는 다음 조건을 확인한다. full은 실제 성공 표시와 TAR SHA256이 일치해야 하고, skip은 명시적으로 시험 생략을 기록한다. 둘 다 게시할 TAR의 해시는 확인한다.

```bash title="Publish tested or explicitly skipped bundle — 핵심 부분"
expected="$(yaml_value staging-info.yaml bundle_sha256)"
case "${TEST_MODE:?Missing release policy}" in
  full) [[ "$(<test-passed.sha256)" == "${expected}" ]] ;;
  skip) echo 'Publish without deployment tests, as explicitly selected.' ;;
  *) exit 1 ;;
esac
[[ "$(file_sha256 "${BUNDLE_WORK_DIR}/${manifest_id}.tar")" == "${expected}" ]]
bash "${BUNDLE_BUILDER_DIR}/publish-bundle.sh" release-info.yaml
```

skip 경로에서도 TAR 지문을 전달하기 위해 `staging-info.yaml`을 로컬에 만든다. 이 파일이 있다는 사실만으로 staging에 업로드했다는 의미는 아니다. 업로드 시작 표시는 `staging-upload.enabled`, VM 생성 시작 표시는 `vm-cleanup.enabled`로 따로 구분한다. 항상 실행되는 정리 Step은 이 표시가 있는 경우에만 자원 정리를 시도한다.

</details>

<p class="subsection-title"><strong>5-1. 주소·경로와 비밀은 분리</strong></p>

<div class="section-body" markdown="1">

주소·저장소·운영 정책은 하나의 설정 파일에 둔다. 아래는 기존 설정에 추가·정리한 항목이며 파일 전체가 아니다.

```bash title="/etc/gitea-runner-env/bundle-pipeline.env — 주요 항목"
GITEA_URL=https://gitea.example.com
GITEA_REPOSITORY=cloud/private-cloud-v4
GITEA_REPO_URL="${GITEA_URL}/${GITEA_REPOSITORY}.git"
RELEASE_BRANCH=master
TEST_SKIP_LABEL=release:skip-test

NEXUS_URL=https://192.0.2.10:55555
NEXUS_USER=release-ci
BUNDLE_BUILDER_DIR=/opt/gitea/bundle-builder
RELEASE_KEEP_COUNT=2
```

파일은 `root:gitea-runner`, `0640`으로 두고 비밀번호를 넣지 않는다. Workflow는 `REPO_READ_TOKEN`, `NEXUS_RUNNER_PASSWORD`, `VSPHERE_USER`, `VSPHERE_PASSWORD`, `OPENSTACK_PASSWORD`를 Gitea Actions Secrets에서 받는다.

시험 VM이 staging TAR를 받을 때도 Runner 계정을 사용한다. 사업수행팀 다운로드 계정은 staging을 읽지 못하므로 이 용도에 재사용하지 않는다.

</div>

---

## 6. Nexus 역할은 세 가지로 정리

역할(Role)은 여러 권한을 묶은 이름이다. 계정과 역할은 다르므로, 같은 다운로드 역할을 여러 개인 계정에 부여할 수 있다. 아래는 이번 운영 방식의 구분이다.

| 역할 | 대상 | 허용 범위 |
| --- | --- | --- |
| `runner` | CI 전용 계정 | 모든 저장소 콘텐츠 조회·추가·갱신·삭제, 검색 |
| `download` | 사업수행팀 개인 계정 | `raw-manifest`, `raw-release-bundle` 조회·다운로드 |
| `nx-admin` | 우리팀 관리자 계정 | Nexus 구성·사용자·저장소 관리 |

Runner의 모든 콘텐츠 권한은 모든 관리자 권한과 다르다. 저장소 생성·서버 설정 권한은 주지 않는다. 대신 콘텐츠 삭제 권한은 넓으므로 CI Secrets와 Workflow 수정 권한을 함께 관리한다. 사내 Nexus의 익명 접근은 비활성화하고, 고객사 Private Nexus의 배포물 읽기만 익명으로 구성한다.

<details class="analysis-toggle" markdown="1">
<summary>Nexus UI에 등록할 privileges 보기</summary>

**Runner**

```text
nx-search-read
nx-repository-view-*-*-browse
nx-repository-view-*-*-read
nx-repository-view-*-*-add
nx-repository-view-*-*-edit
nx-repository-view-*-*-delete
```

**사업수행팀 다운로드**

```text
nx-search-read
nx-repository-view-raw-raw-manifest-browse
nx-repository-view-raw-raw-manifest-read
nx-repository-view-raw-raw-release-bundle-browse
nx-repository-view-raw-raw-release-bundle-read
```

관리자는 내장 `nx-admin`을 사용한다. 기능별로 나뉘었던 이전 Runner 역할은 사용자 연결을 새 역할로 옮긴 뒤 정리했다. 제품의 `add`, `edit`, `delete`는 콘텐츠 작업 권한이며 관리 권한과 구분된다. [Nexus privileges](https://help.sonatype.com/en/privileges.html)

</details>

사업수행팀 다운로드 역할은 설치 재료 저장소인 `raw-hosted`, `docker-hosted`를 읽지 않는다. 사내에서 Git을 clone해 직접 설치하는 우리팀은 해당 저장소에 접근 가능한 관리자 계정을 사용한다.

---

## 7. install.sh 하나로 사내 인증과 고객사 자동 설치

스크립트 본문을 고객사마다 고쳐 저장하지 않는다. **기본 주소 + 실행 인자 + 익명 모드**로 나눈다.

| 사용자 | 실행 | Nexus 인증 |
| --- | --- | --- |
| 사내 팀원 | `sudo ./install.sh` | 사내 기본 주소, ID·비밀번호 한 번 입력 |
| 다른 사내 Nexus 사용 | `sudo ./install.sh 192.0.2.20:55555` | 지정한 주소, ID·비밀번호 입력 |
| 고객사 자동화 | `deploy.sh`가 내부에서 주소와 `--anonymous` 전달 | 입력하지 않음 |

사내에서 `contrabass-engine` 디렉터리의 `install.sh`를 실행하면 manifest에 지정한 containerd·runc·nerdctl·BuildKit·CNI와 CirrOS를 Nexus에서 받는다. Raw는 SHA256을 확인하고, Ansible 컨테이너 이미지는 manifest의 digest로 받는다.

```bash title="install.sh — 주소와 모드 선택의 핵심"
# 스크립트 기본값은 사내 주소로 설정
NEXUS_ADDRESS="${1:-192.0.2.10:55555}"
NEXUS_URL="https://${NEXUS_ADDRESS}"

# 실제 스크립트는 인자 형식·root 실행도 확인한다.
# --anonymous가 없으면 터미널에서 ID·비밀번호를 입력받는다.
```

입력한 인증정보는 실행 중 임시 디렉터리의 curl 설정과 Registry 로그인에만 사용하고 종료 시 지운다. 비밀번호를 소스·Git remote·영구 `.env`에 저장하지 않는다. 비밀번호 입력을 숨겨도 터미널 녹화·디버그 출력까지 자동으로 안전해지는 것은 아니므로 `set -x`는 사용하지 않는다.

고객사에서는 최종 TAR를 검증·압축 해제하고 다음 명령 하나를 사용한다. 예시 주소는 고객사 Deploy Node의 API IP로 바꾼다.

```bash title="고객사에서 실행"
sudo ./deploy.sh 192.0.2.101 --accept-eula
```

`deploy.sh`는 Private Nexus 기동·재료 반입 후 다음과 같이 호출한다. 고객사에서 따로 ID·비밀번호를 넣을 필요가 없다.

```bash title="deploy.sh 내부의 install.sh 호출"
bash "${bundle_dir}/git/init-container/contrabass-engine/install.sh" "${nexus_host}:55555" --anonymous
```

기존 컨테이너의 네트워크 방식, 코드 마운트, SSH 기동·계정 설정은 이번 인증 변경과 별개다. 임의로 host network로 바꾸거나 기존 컨테이너를 강제로 삭제하는 동작을 추가하지 않는다. Ansible용 Nexus 주소도 기존처럼 Ansible 설정에서 관리한다.

---

## 8. 사업팀은 TAR 전체만 확인하고 압축을 푼다

SHA256은 파일 내용을 읽어 계산하는 지문이다. 두 해시가 다르면 같은 파일이 아니다. 컨테이너 이미지의 digest도 콘텐츠를 식별하는 값이지만, 단순히 TAR 파일 크기나 이미지 Tag 이름과 같은 의미는 아니다.

| 시점 | 확인 대상 | 기준 |
| --- | --- | --- |
| 재료 수집 | 컨테이너 이미지 | manifest의 digest |
| 재료 수집·다운로드 | Raw 파일·런타임 바이너리 | manifest의 SHA256 |
| 시험 후 승격 | 시험한 TAR와 게시할 TAR | 동일 SHA256 |
| 사업수행팀 다운로드 | 최종 TAR 전체 | 공식 `.tar.sha256` |

TAR 안의 **모든 소스 파일을 나열한 `SHA256SUMS` 생성과 deploy-time 전체 파일 검사는 제거**했다. 배포 스크립트의 필수 파일 확인이나 Nexus 반입 재료 검증까지 없앤 것은 아니다. 고객사에서 수정할 inventory·main.yml 때문에 소스 전체 체크섬 목록을 다시 관리할 필요도 없다.

고정 버전 주소로 TAR와 체크섬을 함께 받아 검증한다. 두 파일을 받는 도중 channel이 새 버전으로 바뀌는 혼선을 피하기 위해, 실제 다운로드 대상 버전은 같은 것으로 맞춘다. channel 리다이렉트와 사업수행팀 반입 절차는 기존 방식을 유지한다.

```bash title="사업수행팀 PC — 같은 버전 TAR와 체크섬 다운로드"
base=https://nexus.example.com/repository/raw-release-bundle/releases/4.1/v4.1.2
read -r -p 'Nexus ID: ' nexus_user
curl -fSL --user "${nexus_user}" \
  "${base}/contrabass-engine-deploy.tar" -o contrabass-engine-deploy.tar
curl -fSL --user "${nexus_user}" \
  "${base}/contrabass-engine-deploy.tar.sha256" -o contrabass-engine-deploy.tar.sha256
sha256sum -c contrabass-engine-deploy.tar.sha256
tar -xf contrabass-engine-deploy.tar
```

curl은 비밀번호를 터미널에서 묻는다. 사설 CA를 사용하면 신뢰할 CA를 설치하거나 `--cacert`로 지정한다. 내부 시험 환경의 자체 서명 인증서 때문에 `-k`를 사용할 때는 인증서 검증을 생략한다는 점을 알고 사용한다. SHA256 비교만으로 서버의 신원까지 검증되는 것은 아니다. [curl 옵션](https://curl.se/docs/manpage.html)

이미 발행한 과거 TAR에는 이전 `SHA256SUMS`와 스크립트가 남아 있다. 이번 변경은 새 버전 패키지부터 적용한다. 같은 버전의 불변 TAR를 새 내용으로 덮어쓰지 않는다.

---

## 9. .gitignore와 Gitea Release로 운영 기록 마무리

<p class="subsection-title"><strong>9-1. Git에는 소스와 lock 파일만</strong></p>

<div class="section-body" markdown="1">

`.gitignore`에 배포물, 비밀 파일, OpenTofu 실행 중 생성물을 추가한다. `.terraform.lock.hcl`은 Provider 버전을 재현하는 잠금 파일이므로 유지한다.

```gitignore title=".gitignore — 주요 항목"
*.tar
*.tar.gz
*.tgz
*.qcow2
*.img
*.iso
*.whl
.env
.env.*
!.env.example
.secret
.secret.*
*.key
*.pem
id_rsa
id_ed25519
**/.terraform/
*.tfstate
*.tfstate.*
*.tfplan
*.plan
*.tfvars
*.tfvars.json
!*.tfvars.example
!*.tfvars.json.example
```

이미 추적 중인 개인키가 발견됐다면 이 설정만으로 없어지지 않는다. 먼저 참조하는 배포 로직과 키 교체 방식을 정한 뒤 추적 해제·키 교체를 별도 진행한다. 파일을 무작정 지워 기존 배포를 깨뜨리지 않는다. [gitignore의 적용 범위](https://git-scm.com/docs/gitignore)

</div>

<p class="subsection-title"><strong>9-2. Release는 기존 Tag의 설명서</strong></p>

<div class="section-body" markdown="1">

Gitea 저장소 **Releases → New Release**에서 이미 발행한 Tag를 선택한다. 자동 릴리스 노트·Confluence 게시 기능은 이번 Workflow에 넣지 않는다. 담당자가 변경 요약을 작성한다.

```markdown title="Release 본문 작성 항목"
## 변경 사항
- 사용자에게 영향을 주는 변경과 주의사항

## 형상
- Tag: v4.1.2
- Git commit: 해당 Tag의 커밋

## 배포 시험
- 전체 시험 통과 / 배포 시험 생략
- Actions 실행 링크와 생략 사유

## 배포물
- 같은 버전의 Nexus TAR 링크
- TAR SHA256 링크

## 보관 정책
- 계열별 최신 2개 TAR 보관. 오래된 TAR 링크는 만료될 수 있음.
```

실제로는 기존 성공 실행과 이미 게시된 TAR를 대조해 `v4.1.1` Release를 수동 작성했다. 새 Tag나 배포 시험은 만들지 않았다. 이후 코드를 예전 Tag에 소급 적용했다고 적지 않는다.

Gitea의 일반 저장소 읽기 권한을 Release만 볼 수 있는 별도 권한으로 오해하지 않는다. 소스를 열지 않을 사업수행팀에는 Nexus 다운로드 권한을 제공하고, 대외 설명은 공개 범위가 맞는 문서에 별도로 작성한다.

</div>

<p class="subsection-title"><strong>9-3. 반영과 확인 범위</strong></p>

<div class="section-body" markdown="1">

| 항목 | 확인 범위 |
| --- | --- |
| Gitea 보호 규칙·라벨, Nexus 역할 | API 반영 후 재조회 |
| 공통 설정·빌더·고객사 템플릿 | 설치 파일 점검, Bash 문법 검사 |
| Workflow·install.sh·.gitignore | develop push 및 master PR 작성, YAML·shell·diff 정적 검사 |
| master 활성화 | 실제 팀원 승인·merge 필요 |
| 새 full·skip 경로의 실제 배포 | [확인 필요] 다음 릴리스에서 확인 |

다음 실동작 확인에서는 full 성공, skip 성공, full 실패 시 미게시, 기존 TAR 재시험을 구분한다. 보호 규칙을 풀어 시험을 강행하지 않는다. 기존 서비스는 재기동하지 않았다.

</div>

---

## 10. 이어서 읽기

- [이전: OpenTofu 입문 가이드 - 6 — 기능 시험과 자동 정리](2026-10-15-opentofu-functional-test-cleanup.md)
- [5편 — staging 게시와 공식 release 승격](2026-10-15-opentofu-staging-release.md)
- [4편 — Runner와 OpenTofu 연결](2026-10-14-opentofu-gitea-runner.md)
- [Gitea 저장소 권한](https://docs.gitea.com/1.25/usage/access-control/permissions/)
- [nerdctl 2.1.6 — Registry 인증과 설정](https://github.com/containerd/nerdctl/blob/v2.1.6/docs/registry.md)
