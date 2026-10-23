---
title: "사내 Gitea 경량화 (7) — 자동화에 승인과 릴리스 운영 규칙 붙이기"
summary: "develop은 직접 push하고 master는 승인된 PR로 합친다. Tag로 패키징을 시작하고 배포 시험 실행·생략을 선택하는 방법, 과거 버전 패치와 Gitea Release 기록까지 팀의 작업 흐름을 정리한다."
summary_style: editorial
date: 2026-10-22
category: 자동화 CI/CD
tags:
  - OpenStack
  - Automation
  - Linux
  - 가이드
---

<section class="editorial-summary editorial-summary--text-only" aria-labelledby="editorial-summary-title">
  <div class="editorial-summary-layout">
    <div class="editorial-summary-copy">
      <span class="editorial-summary-label">사내 Gitea 경량화 · 팀 운영 편</span>
      <h2 id="editorial-summary-title" class="editorial-summary-title">코드를 합치는 승인과 패키지를 발행하는 Tag를 구분한다.</h2>
      <p>자동 패키징이 가능해지자 누가 어떤 코드를 출시하고, 배포 시험을 언제 생략할지 정할 필요가 생겼다. develop은 일상 작업 공간으로 두고 master 반영·릴리스 발행·시험 선택을 각각 기록한다.</p>
    </div>
  </div>
  <p class="editorial-summary-result"><span><strong>수정 → PR 승인·merge → Tag → 시험 선택 → 공식 TAR 게시</strong>. 시험을 생략해도 재료와 TAR 검증은 생략하지 않는다.</span></p>
</section>

[6편](../design/2026-10-21-gitea-lightweight-6.md)까지는 패키지를 만들고 고객사에서 사용하는 과정을 다뤘다. 이번에는 **우리 팀이 무엇을 수정하고, 어떤 절차로 출시할지**를 정리한다. 자동화가 있다고 모든 Git push를 고객사 배포물로 만들 필요는 없다.

## 1. 두 저장소를 맞추던 작업에서 하나의 릴리스 흐름으로

기존에는 `contrabass-engine`에 파일과 코드를 넣고 commit한 뒤, 최종용 `init-container`에도 변경을 반영했다. 사업수행팀은 `v305`, `v306` 같은 브랜치를 선택해 전체 clone했다. 어떤 수정부터 고객사에 제공할지 별도의 출시 기준이 없으면 브랜치의 최신 커밋이 곧 배포 기준이 됐다.

변경 후에는 코드 저장소 하나를 사용한다. **브랜치는 작업을 모으고, Tag는 출시할 커밋을 지정한다.**

| 구분 | 기존 | 변경 후 |
| --- | --- | --- |
| 코드 반영 | 개발용·최종용 두 저장소에 반복 반영 | 한 저장소에서 개발·정식 브랜치 구분 |
| 일상 수정 | 담당자가 수정·시험 후 반영 | develop 직접 push 허용, 필요한 경우 임시 feature 사용 |
| 정식 코드 | 최종용 브랜치 최신 상태 | master에 승인된 PR만 merge |
| 출시 기준 | 버전 브랜치의 최신 커밋 | `v4.1.2` 같은 명시적 Tag |
| 반입 파일 | 사업수행팀이 Git 전체 clone | Tag와 연결된 최종 TAR 다운로드 |

개발자가 VMware에서 직접 시험하는 과정이 없어지는 것은 아니다. 개별 개발 시험에 더해 **릴리스 후보 전체를 자동으로 설치해 보는 단계**가 생긴다.

<figure class="flow" aria-label="팀의 개발과 정식 발행 순서">
  <ol>
    <li>develop 수정·push</li>
    <li>master PR 승인·merge</li>
    <li>확정 커밋에 Tag</li>
    <li>Runner 패키징·게시</li>
  </ol>
</figure>

---

## 2. master는 PR로만, develop은 팀원이 직접 push

PR은 변경을 다른 브랜치에 합쳐 달라는 요청이다. **승인은 검토 결과이고 merge는 실제로 코드를 합치는 동작**이다. 승인만으로 merge·Tag·패키징까지 한꺼번에 실행되는 것은 아니다.

Gitea 저장소의 **Settings → Branches → 보호 규칙**에서 다음 기준을 적용한다. 메뉴 설명은 Gitea 1.25 계열을 기준으로 한다. [Gitea Protected branches](https://docs.gitea.com/1.25/usage/access-control/protected-branches/)

| 항목 | master | develop |
| --- | --- | --- |
| 팀원 직접 push | 금지 | 허용 |
| force push | 금지 | 금지 |
| 반영 방식 | 승인된 PR을 담당자가 merge | 직접 push 또는 PR |
| 필수 승인 | 작성자가 아닌 검토자 1명 | 필수로 두지 않음 |
| 검토 뒤 코드 추가 | 이전 승인을 해제하고 재검토 | PR을 쓰는 경우 같은 기준 적용 |
| 관리자 승인 조건 우회 | 허용하지 않음 | master 우회 수단으로 사용하지 않음 |

일반 릴리스의 자동화는 **master 대상 PR의 merge 커밋**을 확인한다. 이 연결을 단순하게 유지하려면 merge commit 방식으로 통일하고 squash·rebase merge는 섞지 않는다. Git 기능 자체의 제한이 아니라 이 파이프라인의 승인 확인 방식에 맞춘 선택이다.

Tag는 **Settings → Tags**에서 `v*`를 보호하고 지정한 릴리스 담당자만 발행하게 한다. 보호 규칙과 별개로 **발행한 Tag를 삭제하거나 같은 이름으로 옮기지 않는 원칙**을 둔다. [Gitea Protected tags](https://docs.gitea.com/1.25/usage/access-control/protected-tags/)

!!! tip "무엇을 했을 때 Runner가 도는가"
    develop push, PR 승인, master merge만으로는 릴리스 패키징을 시작하지 않는다. 확정 커밋의 `v*` Tag를 push하거나 기존 Tag를 지정해 수동 실행할 때 시작한다. 개발 변경과 정식 발행을 나누는 기준이다.

---

## 3. 우리 팀이 실제로 수정하는 파일과 Tag 생성

코드만 바꾸든 설치 이미지만 바꾸든, 고객사에 새 패키지를 제공한다면 새 릴리스 번호를 사용한다.

| 변경 대상 | 팀이 할 일 |
| --- | --- |
| Ansible 작업·설정 | 해당 role·inventory·공통 변수 수정 |
| 컨테이너 이미지 | Nexus에 이미지 게시, `release/manifest.yaml`의 이름·Tag·digest 갱신 |
| Raw·런타임 파일 | Nexus에 새 버전 경로로 게시, manifest의 경로·SHA256 갱신 |
| Ansible이 다운로드하는 항목 | `nexus.yml`의 대응 항목도 같은 버전·경로로 수정 |
| 릴리스 번호 | manifest의 `release` 수정, 동일 번호의 Git Tag 생성 |
| 현장 Nexus 주소 | Ansible `inventory/group_vars/all/main.yml`의 `nexus_url` 지정 |

**manifest는 반입할 재료 목록이고 nexus.yml은 Ansible의 다운로드 설정**이다. 현재 두 파일에 중복 정의된 항목은 함께 맞춰야 한다. manifest에서 Ansible 설정을 자동 생성하는 기능이 있다고 가정하지 않는다. 주소만 바꾸는 경우에는 버전 파일을 다시 업로드할 필요가 없다.

```text title="새 설치 재료를 반영하는 순서"
Nexus에 새 파일·이미지 업로드
  → manifest의 버전·경로·SHA256 또는 digest 갱신
  → 필요한 nexus.yml 항목과 코드 수정
  → develop 반영 → master PR 검토·merge
  → 해당 merge 커밋에 릴리스 Tag 생성
```

다음은 개발 PC의 저장소에서 실행한다. 먼저 Gitea PR 화면에서 **발행할 merge 커밋**을 확인한다. 그 뒤 다른 PR이 merge됐을 수 있으므로 무조건 최신 master에 Tag를 붙이지 않는다.

```bash title="검토·merge한 정확한 커밋에 v4.1.2 발행"
git fetch origin master
read -r -p 'Release merge commit: ' release_commit
git show "${release_commit}:release/manifest.yaml"
# release: "4.1.2"와 변경 내용을 확인한 뒤 실행
git tag -a v4.1.2 "${release_commit}" -m "Release v4.1.2"
git push origin v4.1.2
```

Tag의 `v4.1.2`와 manifest의 `release: "4.1.2"`가 다르면 패키징을 중단한다. `git push --tags` 대신 **이번에 발행할 Tag 하나만 push**한다.

---

## 4. 긴 배포 시험을 생략해도 검증과 기록은 남긴다

[5편](2026-10-21-gitea-lightweight-5.md)의 기본 경로는 staging에 후보를 올리고 VMware·Ansible·OpenStack 시험을 수행하는 방식이었다. 여기에 **검토자가 선택한 시험 생략**을 추가한다. Workflow는 `publish-manifest.yaml` 하나를 유지한다.

| 선택 | 선택 방법 | 배포 시험 | 정식 게시 조건 |
| --- | --- | --- | --- |
| `full` | PR에 생략 라벨 없음 | staging → VM 생성 → 설치·기능 시험 | 시험한 TAR와 게시할 TAR의 SHA256 일치 |
| `skip` | 검토자가 PR에 `release:skip-test` 라벨 부여 | VMware·OpenStack 시험 생략 | 재료·TAR 검증 통과, 생략 기록 |

PR 라벨만 만들면 Gitea가 자동으로 시험을 생략하는 것은 아니다. `common.sh`의 `select_test_mode`가 **Tag의 커밋 → master로 merge된 PR → 유효한 승인 → 현재 라벨**을 확인하고, Workflow가 그 결과로 시험 Step을 실행하거나 건너뛴다. PR/API를 확인하지 못하면 중단하며 오류를 skip으로 처리하지 않는다.

PR의 develop 브랜치가 나중에 계속 바뀌어도 출시 당시 승인 대상을 확인해야 한다. merge commit 방식에서는 **merge 커밋의 두 번째 부모**를 당시 PR 소스의 기준으로 사용한다. 계속 이동하는 develop의 현재 HEAD와 비교하면 이미 승인한 릴리스를 잘못 거절할 수 있다.

<details class="analysis-toggle" markdown="1">
<summary>같은 Tag를 다시 실행할 때의 시험 선택과 기록</summary>

일반 릴리스는 실행할 때 해당 PR의 현재 라벨을 다시 읽는다. skip으로 발행한 뒤 full 시험이 필요하면 라벨을 제거하고 **기존 Tag를 지정해 수동 실행**한다.

- Tag·manifest·이미 게시한 TAR를 바꾸지 않는다.
- 기존 TAR가 있으면 그 파일을 받아 해시를 확인하고 시험한다.
- 이전 실행의 성공 표시를 새 실행의 시험 통과로 사용하지 않는다.
- 실행별 시험 선택·근거 PR·성공/실패/생략·TAR SHA256을 별도 기록한다.

```text title="버전과 실행 기록은 구분한다"
raw-manifest/
├── releases/4.1/v4.1.2/       # 버전의 manifest·release-info
└── executions/v4.1.2/
    ├── <첫 실행 ID>.yaml      # skip, 게시 결과
    └── <재실행 ID>.yaml       # full, 시험 결과
```

나중의 시험이 실패했다고 이미 공개한 TAR를 자동 회수하는 것은 아니다. 이 경우 배포 중단 공지나 채널 전환은 별도로 판단한다. `skipped`를 `passed`라고 적지 않는 것이 중요하다.

</details>

시험 여부와 무관하게 아래 검증은 유지한다.

| 시점 | 확인할 것 |
| --- | --- |
| 재료 수집 | 컨테이너 digest, Raw·런타임 SHA256 |
| full 시험 후 승격 | 시험한 TAR와 게시할 TAR의 SHA256 |
| 최종 게시·다운로드 | 최종 TAR 전체 SHA256 |

사업수행팀은 TAR와 **같은 버전의 `.tar.sha256`**을 받아 검증한 뒤 푼다. deploy.sh에서 소스 파일 전체를 `SHA256SUMS`로 다시 검사하는 방식은 사용하지 않는다. 그렇다고 필수 파일 확인이나 Nexus 반입 재료 검증을 없애는 것은 아니다.

---

## 5. master를 바꾸지 않고 과거 4.0만 패치하기

master가 4.2 계열이어도 4.0.6만 만들 수 있다. 항상 유지보수 브랜치를 열어 둘 필요는 없다. **기존 Tag에서 로컬 임시 브랜치를 만들고 새 Tag만 push**한다.

```text title="서로 다른 출시 이력"
master:      ... ── v4.1.0 ── v4.2.0 ── v4.2.1

v4.0.5:      ● ── 4.0 전용 수정 ── ● v4.0.6
                  patch/4.0.6에서 작업
```

다음은 개발 PC에서 실행하는 과거 계열 패치 예다. 현재 운영 Workflow가 없는 오래된 Tag라면 필요한 파이프라인 변경도 먼저 포함한다.

```bash title="v4.0.5에서 시작해 v4.0.6만 발행"
git fetch origin tag v4.0.5
git switch -c patch/4.0.6 v4.0.5
# 코드와 release/manifest.yaml의 release를 4.0.6으로 수정
git add release/manifest.yaml
# 수정한 다른 파일도 경로를 지정해 git add
git commit -m "Fix 4.0 release configuration"
git tag -a v4.0.6 -m "Release v4.0.6"
git push origin v4.0.6
```

이 경로에는 master PR이 없으므로 시험 선택도 Tag 메시지로 구분한다. 기본은 full이며, 생략을 승인한 경우 **처음 Tag를 만들 때** 메시지에 `[skip-test]`를 포함한다. 위 Tag 생성 명령과 아래 명령은 둘 중 하나만 사용한다.

```bash title="과거 계열에서 시험 생략을 명시하는 Tag 메시지"
git tag -a v4.0.6 -m "Release v4.0.6 [skip-test]"
```

발행 후 로컬 임시 브랜치를 삭제해도 **원격 Tag가 그 커밋을 가리키므로 코드가 사라지지 않는다.** 다음 4.0.7은 `v4.0.6`에서 시작한다. master나 다른 계열에 수정이 자동 반영되지는 않는다. 여러 계열에 필요하면 각 계열에서 적용·시험·발행한다.

!!! warning "과거 패치 예외를 일반 릴리스의 우회로로 쓰지 않는다"
    이 방식은 현재 정식 계열보다 오래된 계열에만 허용한다. 현재·미래 계열은 master PR 승인을 확인한다. 정책 도입 전 Tag의 재시도 허용 목록도 새 릴리스의 승인 우회 수단으로 늘리지 않는다.

---

## 6. 권한과 비밀은 자동화의 입력으로 관리

Runner가 실행하는 것은 결국 저장소의 셸 명령이다. Workflow를 수정할 수 있는 권한과 Runner의 서버 권한을 함께 봐야 한다.

| 구분 | 권한과 역할 |
| --- | --- |
| 개발팀 개인 계정 | 코드 수정, develop push, PR 검토. 운영 관리자 권한은 필요한 사람만 |
| 릴리스 담당자 | 승인된 PR merge, 보호 Tag 발행 |
| CI 계정 | Git 읽기·정책 조회, Nexus 콘텐츠 게시·정리 |
| 사업수행팀 | 최종 manifest·Bundle 읽기. staging·재료 저장소·관리 API는 불필요 |

Nexus는 `runner-role`, `download-role`, 관리자 역할의 세 구분으로 시작할 수 있다. 역할 하나를 여러 개인 계정에 연결하되 공유 비밀번호 하나로 모든 사람을 묶지 않는다. Runner 콘텐츠 권한과 Nexus 서버 관리자 권한도 구분한다. [Nexus privileges](https://help.sonatype.com/en/privileges.html)

주소·경로·저장소 이름은 `/etc/gitea-runner-env/services.env` 한 곳에서 지정한다. `bundle-pipeline.env`는 이 값을 읽어 URL과 파생 경로를 계산한다. 비밀번호·API Token은 Gitea Actions Secrets로 전달한다. 소스 코드에 같은 URL의 기본값을 여러 번 넣지 않는다. host 방식 Runner는 동시 실행 1개를 유지하고, root 작업은 제한된 wrapper로만 수행한다.

<details class="analysis-toggle" markdown="1">
<summary>Git에 넣지 않을 파일과 사내 설치 인증</summary>

```gitignore title=".gitignore — 자동화 결과와 비밀 제외 예시"
.terraform/
*.tfstate
*.tfstate.*
*.tfplan
*.plan
.env
.env.*
!.env.example
*.secret
id_rsa
id_ed25519
vm-info.json
test-passed.sha256
vm-cleanup.enabled
```

`.terraform.lock.hcl`은 provider 버전 고정에 사용하므로 commit한다. `.gitignore`는 이미 추적 중인 비밀이나 과거 이력을 지우지 않는다. 유출한 자격증명은 교체해야 한다. OpenTofu State는 Git에서는 제외하되 운영 백업에는 포함한다.

사내 팀원은 Git을 가볍게 clone하고 `install.sh`를 실행한다. 사내 기본 Nexus 주소를 사용하며 ID·비밀번호를 입력한다. 고객사에서는 deploy.sh가 Private Nexus 주소와 익명 읽기 모드를 전달하므로 입력을 요구하지 않는다. 코드마다 비밀번호를 저장하거나 고객사마다 install.sh를 편집할 필요는 없다.

Ansible이 사용할 `nexus_url`은 별개다. `inventory/group_vars/all/main.yml`에 `IP:PORT`로 지정하고 nexus.yml이 참조한다. 이 주소를 컨테이너의 환경변수로 다시 넘겨야 한다고 가정하지 않는다.

</details>

---

## 7. Tag는 코드 기준점, Release는 변경 설명, Nexus TAR는 배포물

Gitea Release는 Tag와 연결되는 설명 페이지다. TAR를 Gitea에 다시 올릴 필요는 없다. **어떤 패치인지, 시험은 했는지, 어디서 받는지**를 적는다. Release 본문이 자동으로 정확한 패치 노트가 되는 것은 아니므로 변경 요약은 팀이 작성한다.

Nexus 게시가 성공한 뒤 Gitea의 **Releases → New Release**에서 기존 Tag를 선택한다. 새 Tag를 실수로 만들지 않도록 한다. 준비 중에는 Draft를 사용하고, 패키지가 준비됐을 때 공개한다.

```markdown title="v4.1.2 Release 본문 예시"
## 변경 사항
- Contrabass Mole 버전 갱신
- 배포 시 공통 옵션 처리 수정

## 시험
- full 또는 skip
- Actions 실행 링크, skip이면 선택 이유

## 다운로드
- 릴리스: v4.1.2
- 고정 버전: /repository/raw-release-bundle/releases/4.1/v4.1.2/contrabass-engine-deploy.tar
- TAR SHA256: 해당 버전의 체크섬 파일 참조
- 변경 파일·관련 PR 링크

## 적용 전 확인
- 기존 사이트에 추가할 변수와 알려진 제한
```

Release는 코드·Tag의 설명이지 영구 TAR 보관을 보장하는 장소는 아니다. **Bundle은 계열별 최신 3개만 보관**하므로 오래된 Release에는 “패키지 보관 종료, 코드는 Tag로 확인”처럼 상태를 남긴다. 과거 배포물 복원은 [9편의 백업·복구](../design/2026-10-22-gitea-lightweight-9.md)와 별도로 연결된다.

이제 누가 수정·승인·발행했는지와 어떤 시험을 선택했는지가 같은 릴리스에 연결된다. 다음은 자동화가 계속 돌아갈 때 쌓이는 **파일·캐시·이미지의 운영 기준**이다.

[← 6편: 고객사 반입과 실행](../design/2026-10-21-gitea-lightweight-6.md) · [8편: Nexus와 배포 이미지 관리 →](../design/2026-10-22-gitea-lightweight-8.md)
