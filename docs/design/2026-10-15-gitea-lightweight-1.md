---
title: "사내 Gitea 경량화 (1) — 코드만 받으려는데 저장소가 26GiB였다"
summary: "Ansible 코드와 설치 이미지를 함께 보관하던 Git. 26GiB clone의 원인을 확인하고, shallow clone과 LFS를 검토한 끝에 코드·설치 재료·고객사 반입물을 분리한 과정."
summary_style: editorial
date: 2026-10-15
category: 구축설계
tags:
  - OpenStack
  - Automation
  - Linux
---

<section class="editorial-summary" aria-labelledby="editorial-summary-title">
  <div class="editorial-summary-layout">
    <div class="editorial-summary-copy">
      <span class="editorial-summary-label">사내 Gitea 경량화 · 첫 번째 기록</span>
      <h2 id="editorial-summary-title" class="editorial-summary-title">문제는 코드가 아니라, 코드와 함께 받던 설치 파일의 이력이었다.</h2>
      <p>OpenStack 배포용 Ansible 저장소를 clone하니 디렉터리가 26GiB를 넘었다. 현재 파일보다 .git이 더 컸고, 교체한 컨테이너 이미지와 압축 파일이 과거 커밋에 남아 있었다. 대용량 파일을 Nexus로 옮기고, 릴리스마다 필요한 재료를 TAR 하나로 묶는 구조로 바꿨다.</p>
    </div>
    <aside class="editorial-summary-facts" aria-label="기존 전체 clone의 디스크 사용량">
      <div>
        <span class="editorial-fact-label">clone 디렉터리 전체</span>
        <p class="editorial-fact-value">26.25<span>GiB</span></p>
      </div>
      <div>
        <span class="editorial-fact-label">그중 .git</span>
        <p class="editorial-fact-value">19.40<span>GiB</span></p>
      </div>
    </aside>
  </div>
  <p class="editorial-summary-result"><span><strong>Git은 코드, Nexus는 설치 재료, Runner는 패키징</strong>을 맡도록 분리했다. 고객사 반입용 TAR를 내려받아 Private Nexus와 Ansible 컨테이너를 기동하는 것까지 확인했다.</span></p>
</section>

| As-is · 기존 | To-be · 변경 |
| --- | --- |
| Git에 코드·컨테이너 TAR·설치 바이너리 보관 | Git은 코드, 대용량 파일은 Nexus |
| 개발용·최종용 저장소에 같은 변경 반복 반영 | 저장소 하나에서 코드 관리, 태그로 릴리스 지정 |
| 사업수행팀이 버전 브랜치를 전체 clone | 필요한 릴리스의 TAR 하나 다운로드 |
| 받은 Git의 파일로 설치 시작 | TAR에서 Private Nexus와 배포 컨테이너 기동 |

<details class="analysis-toggle" markdown="1">
<summary>시리즈 읽는 순서 — 문제 확인부터 배포·운영·복구까지</summary>

| 편 | 핵심 질문 |
| --- | --- |
| **1. 코드만 받으려는데 저장소가 26GiB였다** | 왜 코드·설치 재료·반입 파일을 분리했나? |
| [2. Gitea·Nexus·Runner 구축하기](2026-10-15-gitea-lightweight-2.md) | 사내 자동화 기반을 어떻게 구성하나? |
| [3. 대용량 파일을 Nexus로 옮기고 Ansible 연결하기](2026-10-15-gitea-lightweight-3.md) | 설치 재료의 위치와 Ansible은 어떻게 바뀌나? |
| [4. 릴리스 태그로 고객사 반입 패키지 자동 만들기](../automation/2026-10-21-gitea-lightweight-4.md) | Runner가 어떤 기준으로 TAR를 만드나? |
| [5. 배포 시험을 통과한 패키지만 릴리스하기](../automation/2026-10-21-gitea-lightweight-5.md) | 만든 TAR를 언제 정식으로 발행하나? |
| [6. TAR 하나로 폐쇄망 배포 환경 준비하기](2026-10-21-gitea-lightweight-6.md) | 사업수행팀은 무엇을 받고 어떻게 사용하나? |
| [7. 자동화에 승인과 릴리스 운영 규칙 붙이기](../automation/2026-10-22-gitea-lightweight-7.md) | 팀은 어떻게 수정·승인·발행하나? |
| [8. 커지는 Nexus와 배포 이미지 관리하기](2026-10-22-gitea-lightweight-8.md) | 파일·캐시·보안 업데이트를 어떻게 관리하나? |
| [9. Gitea·Nexus·Runner 백업과 복구 체계 만들기](2026-10-22-gitea-lightweight-9.md) | 서버 장애 후 무엇을 어떻게 복구하나? |
| [10·마무리. 물리서버에 릴리스 자동화 환경 완성하기](2026-10-22-gitea-lightweight-10.md) | 새 서버에서 전체 설정·스크립트를 어떻게 연결하나? |

</details>

## 1. Git만 받으면 됐던 시절

우리 팀은 OpenStack 기반 프라이빗 클라우드를 Ansible로 구축한다. Ansible은 여러 서버에 설치와 설정 명령을 순서대로 수행하는 자동화 도구다. 여기에는 코드뿐 아니라 실제 설치에 사용할 재료도 필요했다.

- Ansible 실행 환경을 담은 `openstack-ansible.tar`
- Ceph 등 서비스의 컨테이너 이미지
- containerd·nerdctl·BuildKit 등 런타임과 도구
- 사내 프로그램인 Contrabass Mole의 압축 파일
- QCOW2 형식의 가상머신 디스크 이미지와 Python wheel

이 파일들을 Ansible 코드와 같은 Git 저장소에 넣었다. 역할별 `files/` 디렉터리나 설치 스크립트 옆에 두고, 배포할 때 복사하거나 불러오는 방식이었다.

폐쇄망에 반입할 때도 설명이 간단했다. **Git을 받아 가면 코드와 설치 파일이 함께 준비됐다.** 별도 파일 서버에 접근하거나 버전별 파일을 따로 수집할 필요가 없었다.

코드는 두 저장소로 나눠 관리했다.

| 저장소 | 역할 | 실제 작업 |
| --- | --- | --- |
| `contrabass-engine` | 우리 팀의 개발용 저장소 | 코드 수정, 이미지·설치 파일 교체 후 commit |
| `init-container` | 사업수행팀이 사용하는 최종 저장소 | 개발용 저장소의 변경을 cherry-pick 등으로 반영 |

사업수행팀은 항상 `init-container`를 받되 `v305`, `v306` 같은 브랜치로 사용할 버전을 골랐다. 별도의 릴리스 시점이 정해져 있던 것은 아니어서, 수정이나 테스트가 필요하면 개발용 저장소에서 작업하고 최종 저장소에도 옮겼다.

<figure class="flow" aria-label="기존 개발 및 전달 순서">
  <ol><li>개발용 저장소 수정</li><li>최종 저장소에도 반영</li><li>사업팀 전체 clone</li><li>포함된 파일로 배포</li></ol>
</figure>

처음에는 이 방식으로 충분했다. 다만 이미지와 프로그램 버전을 계속 교체하면서, Git에 넣어 둔 설치 재료가 점점 부담이 됐다.

---

## 2. 코드 수정에도 대용량 다운로드가 따라왔다

가장 직접적인 불편은 작업을 시작할 때 생겼다. 새 환경에서 Ansible 코드만 확인하거나 수정하려고 해도 이미지와 바이너리를 함께 받아야 했다. 저장소를 clone한 뒤에는 그 파일과 Git 이력을 보관할 디스크도 필요했다.

**개발팀에는 반복 반영 작업도 있었다.** `contrabass-engine`에 수정한 내용을 `init-container`에도 옮겼다. 두 저장소에 무엇이 반영됐는지 확인해야 했고, 구버전·신버전에 공통으로 필요한 수정은 각 브랜치에도 적용했다. 버전별로 필요 없는 변경은 사람이 골라 제외했다.

**사업수행팀에는 브랜치 최신 상태가 전달됐다.** 특정 릴리스를 고정한 결과물을 받는 대신, 다운로드 당시 브랜치가 가리키던 코드를 사용했다. 같은 브랜치를 받더라도 그사이 변경이 올라오면 구성은 달라질 수 있었다.

결국 세 가지가 한 저장소 사용 방식에 묶여 있었다.

| 필요한 일 | 함께 따라오던 일 |
| --- | --- |
| 코드 확인·수정 | 현재 설치 파일과 과거 바이너리 이력 받기 |
| 변경사항 전달 | 개발용·최종용 저장소에 반복 반영 |
| 고객사 설치 준비 | 배포할 형상 대신 버전 브랜치 전체 clone |

단순히 “용량이 크다”는 것보다, **코드를 다루는 사람과 배포 재료를 가져가는 사람이 같은 방식으로 전체 저장소를 받아야 한다는 점**이 문제였다.

---

## 3. 열어 보니 현재 파일보다 .git이 더 컸다

먼저 기존 저장소를 일반적인 방식으로 clone하고 시간과 디스크 사용량을 확인했다. `--depth=1` 없이 `v3.0.6` 브랜치를 선택한 clone이었다.

아래는 측정에 사용한 명령 형태다. `/usr/bin/time -v`는 명령의 전체 경과 시간과 메모리 사용량 등을 함께 출력한다.

```bash title="전체 이력을 받는 clone의 시간 측정"
/usr/bin/time -v git clone -b v3.0.6 \
  https://gitea.example.com/team/init-container.git
```

clone 후에는 저장소 내부에서 작업 디렉터리와 `.git`을 나눠 확인했다.

```bash title="저장소 디렉터리와 Git 이력의 디스크 사용량 확인"
cd init-container
du -sh .
du -sh .git
```

| 확인 대상 | 측정값 | 의미 |
| --- | --- | --- |
| clone 디렉터리 전체 | **26.25GiB** | 현재 파일과 `.git`을 합친 디스크 사용량 |
| `.git` | **19.40GiB** | Git 객체와 이력 등을 저장하는 내부 디렉터리 |
| 현재 작업 트리 | 약 **6.85GiB** | 체크아웃되어 보이는 현재 파일 |
| clone 중 수신한 데이터 | **19.39GiB** | Git 수신 로그에 표시된 크기 |
| clone 명령 전체 경과 시간 | **19분 13.51초** | 명령 시작부터 체크아웃 완료까지의 시간 |

제목의 26GiB는 네트워크 전송량이 아니라 **clone을 마친 디렉터리의 크기**다. 그중 약 74%를 `.git`이 차지했다.

처음에는 현재 들어 있는 이미지가 커서 그런 줄 알았다. 그런데 현재 파일은 약 6.85GiB인데 Git 내부 디렉터리는 약 19.40GiB였다. 최신 파일만 큰 문제가 아니었다.

**교체하거나 삭제한 대용량 파일이 과거 커밋에 남아 있었다.** Git은 현재 디렉터리만 저장하는 도구가 아니다. 과거 커밋으로 돌아갈 수 있도록 파일 내용도 보관한다. 현재 브랜치에서 TAR를 삭제해도, 그 파일이 들어 있던 과거 커밋이 이력에 연결돼 있으면 clone 대상에서 저절로 빠지지 않는다. [Git 객체와 packfile 설명](https://git-scm.com/book/en/v2/Git-Internals-Packfiles)

여기서 pack은 여러 Git 객체를 압축하거나 차이 형태로 묶어 저장한 파일이다. 분석 당시 `.git/objects/pack`이 `.git` 용량의 사실상 전부였다.

| 분석 결과 | 확인한 내용 |
| --- | --- |
| 10MiB 이상 blob 148개 | 분석 당시 전체 pack 용량의 약 **99.66%** 차지 |
| `.tar` 이력 | pack 내 기여분 약 **15GiB** |
| `.qcow2` 이력 | pack 내 기여분 약 **2.6GiB** |
| Commit 객체 229개 | 객체 자체의 원본 내용 합계 약 **58KiB** |

blob은 Git이 저장한 파일 내용이다. 같은 파일이라도 버전이 바뀌면 서로 다른 blob이 생길 수 있다. 위의 148개는 현재 디렉터리에 있는 대형 파일 148개라는 뜻이 아니라, **이력에 포함된 서로 다른 파일 내용의 개수**다.

커밋 개수가 많아서 무거운 것이 아니었다. 컨테이너 TAR와 압축 파일, VM 이미지의 과거 버전이 핵심이었다.

<details class="analysis-toggle" markdown="1">
<summary>다른 브랜치까지 받아서 커진 것은 아니었을까?</summary>

`git clone -b v3.0.6`의 `-b`는 처음 체크아웃할 브랜치를 고르는 옵션이다. `--single-branch`를 지정하지 않은 일반 clone에서는 다른 브랜치의 객체도 수신에 영향을 줄 수 있다. [git clone 옵션](https://git-scm.com/docs/git-clone)

하지만 이번 저장소에서 다른 브랜치에만 있는 객체의 pack 기여분은 약 175.5MiB였다. 약 19.40GiB의 핵심 원인은 다른 브랜치가 아니라, 선택한 브랜치가 이어받은 과거 대형 파일 이력이었다.

pack 내 기여분은 분석 당시 압축·차이 저장 상태에 따른 값이다. 파일을 분리한 뒤 다시 pack을 만들었을 때의 절감량과 정확히 같은 값은 아니다.

</details>

---

## 4. shallow clone과 LFS도 검토했다

원인을 확인한 다음에는 가능한 방법을 하나씩 따져 봤다. 당장 다운로드를 줄이는 방법과, 앞으로도 대용량 파일이 쌓이는 구조를 바꾸는 방법은 구분할 필요가 있었다.

<p class="subsection-title"><strong>현재 파일을 삭제하면 해결될까?</strong></p>

<div class="section-body" markdown="1">

현재 디렉터리에서 오래된 이미지를 지우는 것만으로는 과거 커밋의 파일 내용까지 없어지지 않는다. 기존 Git 이력에 이미 들어간 대형 파일을 정리하는 작업은 별도다.

더구나 배포에 필요한 현재 이미지까지 없앨 수는 없었다. 파일을 빼려면 Ansible이 어디서 그 파일을 구할지부터 정해야 했다.

</div>

<p class="subsection-title"><strong>최신 커밋만 받으면 어떨까?</strong></p>

<div class="section-body" markdown="1">

`--depth=1`로 과거 이력을 제한하는 shallow clone도 시험했다. 최신 커밋에 필요한 파일은 받으면서, 클라이언트에 전체 커밋 이력을 가져오지 않는 방식이다. [git clone의 depth 옵션](https://git-scm.com/docs/git-clone)

이력 다운로드를 줄이는 데는 맞는 방법이었다. 하지만 최신 커밋에 들어 있는 이미지와 바이너리는 여전히 함께 내려왔다. 사내 저장소가 대용량 파일의 버전까지 계속 보관하는 구조도 그대로였다.

따라서 shallow clone은 이후에도 **코드를 가볍게 가져오는 수단**으로 쓰되, 파일 관리 구조 자체의 해결책으로 삼지는 않았다.

</div>

<p class="subsection-title"><strong>대용량 파일을 LFS로 바꾸면 어떨까?</strong></p>

<div class="section-body" markdown="1">

Git LFS는 Git에 작은 포인터를 저장하고 파일 본체는 별도 저장소에서 관리하는 방식이다. 대형 바이너리를 Git 객체에서 분리한다는 점에서는 잘 맞았다.

다만 우리가 가져갈 것은 일반 파일만이 아니었다. 컨테이너 이미지는 Registry에서 공급하고 싶었고, 압축 파일과 바이너리는 URL로 받아야 했다. 고객사 폐쇄망에는 그중 필요한 버전만 골라 가져가야 했다.

LFS를 사용하더라도 이 반입·공급 방식은 따로 만들어야 했다. 그래서 LFS 자체의 문제라기보다, **우리가 바꾸려는 범위가 Git의 파일 저장 방식보다 넓었다.**

</div>

| 방법 | 도움이 되는 부분 | 우리 환경에서 남는 일 |
| --- | --- | --- |
| 현재 파일 삭제 | 현재 작업 파일 감소 | 과거 이력과 배포 파일 공급 문제 |
| shallow clone | 클라이언트가 받는 과거 이력 제한 | 현재 대형 파일과 서버의 누적 구조 |
| Git LFS | 대형 파일 본체를 Git 객체에서 분리 | 이미지 공급·파일 수집·폐쇄망 반입 자동화 |
| Nexus 분리 | 컨테이너와 일반 파일을 전용 저장소에서 공급 | Ansible 연결과 릴리스 패키징 구현 |

<details class="analysis-toggle" markdown="1">
<summary>LFS라면 같은 브랜치의 과거 이미지도 전부 내려받을까?</summary>

기본 LFS clone·checkout은 현재 체크아웃에 필요한 파일을 받는다. 같은 브랜치에 이미지 v1부터 v9까지의 이력이 있더라도, 최신 v9을 체크아웃한다고 과거 파일 본체를 전부 받는 것은 아니다. 과거 커밋으로 이동하면 그 커밋에 필요한 객체가 추가로 필요하다. [LFS fetch](https://github.com/git-lfs/git-lfs/blob/main/docs/man/git-lfs-fetch.adoc)

파일 본체는 작업 디렉터리 외에 로컬 LFS 캐시에도 존재할 수 있다. 또 기존 Git 이력의 대형 blob까지 포인터로 바꾸려면 이력 마이그레이션이 필요하다. 단순히 LFS 추적 설정을 추가하는 것과는 다르다. [LFS migrate](https://github.com/git-lfs/git-lfs/blob/main/docs/man/git-lfs-migrate.adoc)

</details>

---

## 5. 목표를 Git 용량에서 배포 구조로 넓혔다

고민 끝에 목표를 이렇게 정리했다.

!!! tip "코드를 받을 때와 배포 재료를 받을 때를 분리한다"
    개발자는 코드와 설정을 받는다. 배포할 때는 해당 릴리스에 필요한 이미지와 파일을 받는다. 사업수행팀에는 그 재료를 모은 결과물을 전달한다.

이 기준으로 역할을 세 가지로 나눴다.

| 구성 요소 | 맡길 일 | 저장하거나 만드는 것 |
| --- | --- | --- |
| **Gitea** | 코드와 릴리스 기준 관리 | Ansible, 설치 스크립트, 파일 목록, 릴리스 태그 |
| **Nexus** | 설치 재료와 반입 파일 공급 | 컨테이너 이미지, 일반 파일, 최종 TAR |
| **Runner** | 태그 기준으로 패키징 명령 실행 | 코드·이미지·파일을 모은 릴리스 Bundle |

Gitea는 기존에 사용하던 Git 서버다. Nexus는 설치 파일과 컨테이너 이미지를 보관하고 내려주는 저장소다. Gitea Actions는 이벤트에 따라 실행할 작업 순서를 정의하고, Runner가 그 명령을 실제로 실행한다. [Gitea Actions 개요](https://docs.gitea.com/usage/actions/overview/)

여기서 Bundle은 고객사에 가져갈 코드·설치 재료·실행 스크립트를 하나로 묶은 배포 패키지다.

Nexus 내부도 파일 형식과 역할에 맞게 나눴다.

| Repository | 담는 것 |
| --- | --- |
| `docker-hosted` | Ansible 실행 이미지, Ceph 등 컨테이너 이미지 |
| `raw-hosted` | 프로그램 압축 파일, 런타임 바이너리, wheel, QCOW2 |
| `raw-manifest` | 릴리스별 파일 목록과 코드 식별 정보 |
| `raw-release-staging` | 배포 시험 전의 후보 TAR와 체크섬 |
| `raw-release-bundle` | 고객사 반입용 최종 TAR와 체크섬 |

**Ansible도 파일을 찾는 위치를 바꿨다.** Git의 `files/`에서 복사하던 파일은 Nexus URL에서 다운로드하고, 컨테이너 TAR를 불러오던 부분은 Registry의 이미지를 사용하도록 바꿨다. `get_url`은 Ansible 대상 서버가 URL에서 파일을 받는 모듈이다. [Ansible get_url](https://docs.ansible.com/projects/ansible/latest/collections/ansible/builtin/get_url_module.html)

```text title="설치 재료를 가져오는 경로의 변화"
기존: Git의 files/ 디렉터리 → 파일 복사 → 대상 서버
변경: Nexus의 Repository → URL 다운로드 → 대상 서버
```

사내에서는 사내 Nexus를 바라보고, 고객사에서는 반입한 Private Nexus를 바라본다. 주소는 달라도 Repository 안의 파일 경로는 같게 유지했다.

이때 중요한 경계가 하나 있었다. **파일을 구하는 방법은 바꾸되, 기존 Ansible이 수행하던 설치·설정 동작은 유지하는 것**이다. Git 경량화를 이유로 서비스 실행 방식이나 배포 정책까지 함께 바꾸면, 문제가 생겼을 때 원인을 구분하기 어려워진다.

또 Nexus로 옮겼다고 기존 Git 이력이 자동으로 작아지는 것은 아니다. 새로운 코드 저장소에는 과거 바이너리 이력을 다시 가져오지 않는 방향으로 분리하고, 기존 3.x 저장소는 별도로 관리하는 전제로 잡았다.

---

## 6. 사업수행팀은 Git 대신 TAR 하나를 받는다

설치 파일을 Nexus로 옮기고 끝내면 사업수행팀의 일이 늘 수도 있었다. Git과 이미지를 각각 받아 버전을 맞추고, 고객사에서 다시 Nexus를 구성해야 하기 때문이다.

그래서 파일 수집과 반입 준비도 패키징 과정에 넣었다.

**릴리스의 기준은 브랜치 최신 상태가 아니라 태그다.** 태그는 특정 Git 커밋에 붙이는 이름이다. 코드와 설치 파일 목록이 확정되면 `v4.x.x` 태그를 붙이고, 그 태그로 패키징을 시작한다.

기존의 개발용·최종용 저장소는 하나의 저장소에서 관리하는 방향으로 정리했다. 개발·릴리스 흐름은 `feature/* → develop → master → 릴리스 태그`를 기준으로 잡았다. master 보호나 develop 직접 push 허용 범위는 별도의 팀 운영 정책이다.

패키징에는 `manifest.yaml`이라는 파일 목록을 사용한다. 해당 릴리스에 필요한 Raw 파일의 경로·SHA256과 컨테이너 이미지의 버전·digest를 기록한다. SHA256과 digest는 이름이 같은 재료라도 내용이 맞는지 식별하는 값이다.

<figure class="flow" aria-label="릴리스 태그에서 고객사 반입 파일 생성까지">
  <ol><li>릴리스 태그 push</li><li>재료 수집·TAR 생성</li><li>staging 배포 시험</li><li>통과한 동일 TAR 게시</li></ol>
</figure>

만든 TAR를 곧바로 사업수행팀에 공개하지 않고, 시험 VM에서 설치와 기본 기능을 확인하는 단계를 둔다. 실패하면 기존 다운로드 채널을 유지하고, 통과한 것과 같은 파일만 최종 게시한다. 이 발행 조건은 5편에서 다룬다.

Runner는 호스트에서 작업을 실행하고, 동시 작업 수는 1개로 구성했다. Raw 파일은 SHA256 캐시가 일치하면 재사용하고, 컨테이너 이미지도 containerd의 로컬 콘텐츠를 재사용한다. 코드만 바뀌었는데 같은 설치 재료를 매번 전부 다시 받지 않도록 한 것이다.

일반 Git push마다 대형 TAR를 만드는 대신, 릴리스 태그나 수동 실행으로 패키징한다. 완성된 Bundle은 **릴리스 계열별 최신 3개**를 보관한다. 예를 들어 4.1.4가 올라오면 4.1.1·4.1.2·4.1.3·4.1.4 중 오래된 4.1.1 Bundle을 정리하고 4.1.2·4.1.3·4.1.4를 남긴다. Git 태그와 원본 이미지까지 지우는 정책은 아니다.

사업수행팀이 받는 파일명은 `contrabass-engine-deploy.tar`로 통일했다. 전체 현재 릴리스나 특정 계열의 현재 릴리스를 선택할 수 있게 고정 다운로드 주소를 제공한다.

실제 TAR는 버전별로 한 번만 저장한다. 앞단의 HAProxy가 고정 주소를 실제 파일 주소로 연결하므로, 전체 현재 버전과 4.1 계열 현재 버전이 같아도 같은 TAR를 중복 게시할 필요가 없다. 이 연결 방식은 [4편](../automation/2026-10-21-gitea-lightweight-4.md)에서 다룬다.

TAR에는 설치 대상 이미지뿐 아니라 **Nexus 자체 이미지와 containerd·nerdctl 등 처음 기동하는 데 필요한 재료**도 넣었다. 고객사에 Nexus가 아직 없는데 Nexus에서 런타임을 다운로드해야 하는 순환을 피하기 위해서다.

<figure class="flow" aria-label="사업수행팀의 고객사 배포 준비 순서">
  <ol><li>TAR 하나 다운로드</li><li>고객사로 반입·압축 해제</li><li>deploy.sh 실행</li><li>Private Nexus·Ansible 컨테이너 기동</li></ol>
</figure>

여기까지가 배포 환경 준비다. 이후 Ansible 컨테이너에서 고객사의 inventory와 공통 설정을 맞추고 OpenStack 구축을 진행한다. TAR를 푸는 것과 OpenStack 전체 설치가 끝나는 것은 구분했다.

---

## 7. 바뀐 것은 용량보다 전달 방식이었다

태그를 올렸을 때 패키징이 실행되고, 완성된 TAR가 Nexus에 게시되는 흐름을 구성했다. 클라이언트에서 TAR를 내려받아 새 서버로 옮긴 뒤, Private Nexus와 Ansible 배포 컨테이너를 기동하는 것도 확인했다.

| 관점 | 기존 | 변경 |
| --- | --- | --- |
| 개발자가 받는 것 | 코드와 대용량 파일, 과거 파일 이력 | 코드와 설정·파일 목록 |
| 설치 재료의 위치 | Git의 현재 파일과 과거 커밋 | Nexus의 이미지·파일 Repository |
| 릴리스 기준 | 다운로드 시점의 브랜치 최신 상태 | 특정 커밋을 가리키는 릴리스 태그 |
| 반입 준비 | 사업수행팀이 최종 Git을 전체 clone | Runner가 준비한 TAR 하나 다운로드 |
| 고객사 파일 공급 | Git에 포함된 파일 사용 | 함께 반입한 Private Nexus 사용 |

배포에 필요한 이미지 자체가 사라진 것은 아니다. 고객사에는 여전히 해당 버전의 설치 재료가 필요하다. 대신 **코드를 보기 위해 과거 이미지까지 받는 일과, 현장에서 반입 재료를 다시 모으는 일을 분리했다.**

처음에는 `.git`이 왜 이렇게 큰지 확인하려고 시작했다. 분석해 보니 설치 파일을 Git 이력으로 관리하는 문제였고, 이를 풀다 보니 릴리스와 고객사 전달 방식까지 함께 정리하게 됐다.

다음 [2편 — Gitea·Nexus·Runner 구축하기](2026-10-15-gitea-lightweight-2.md)에서는 사내 자동화 서버를 준비한다. 파일 이관은 3편, 패키징과 발행 조건은 4·5편, 고객사 반입은 6편으로 이어진다. 7~9편에서는 팀의 릴리스 규칙과 Nexus 관리·백업·복구를 다룬다. 마지막 10편은 새 물리서버에서 따라 구성하는 통합 구축 가이드다.
