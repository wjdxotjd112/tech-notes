---
title: "26GiB Git 저장소 경량화 — Nexus 분리부터 릴리스 패키징 자동화까지"
summary: "과거 이미지가 쌓인 Git 저장소를 분석하고, 코드와 배포 파일을 분리했다. Nexus·Ansible·Gitea Actions로 이어지는 구조 변경과 폐쇄망 반입 방식."
summary_style: editorial
date: 2026-10-08
category: 구축설계
tags:
  - OpenStack
  - CI/CD
  - Linux
---

<section class="editorial-summary" aria-labelledby="editorial-summary-title">
  <div class="editorial-summary-layout">
    <div class="editorial-summary-copy">
      <span class="editorial-summary-label">이 구성의 핵심</span>
      <h2 id="editorial-summary-title" class="editorial-summary-title">코드를 받으려고 과거 이미지까지 내려받고 있었다.</h2>
      <p>OpenStack 구축용 Ansible 저장소에 컨테이너 이미지와 설치 파일을 함께 보관했다. 용량 대부분은 소스가 아니라 교체된 바이너리의 이력이었다. Git에는 코드와 배포 목록을 남기고, 큰 파일은 Nexus로 분리하는 방향을 선택했다.</p>
    </div>
    <aside class="editorial-summary-facts" aria-label="변경 전 분석 기록">
      <div><span class="editorial-fact-label">전체 clone 디렉터리</span><p class="editorial-fact-value">26.25<span>GiB</span></p></div>
      <div><span class="editorial-fact-label">그중 .git</span><p class="editorial-fact-value">19.40<span>GiB</span></p></div>
    </aside>
  </div>
  <p class="editorial-summary-result"><span>용량 문제를 계기로 <strong>코드 관리와 설치 재료 배포를 분리</strong>했다. 최종 반입물은 릴리스에 필요한 재료를 모은 TAR 하나로 정리했다.</span></p>
</section>

## 1. Git 저장소가 설치 미디어를 겸하던 구조

저장소에는 OpenStack 기반 프라이빗 클라우드를 구축하는 Ansible이 들어 있었다. 플레이북과 설정 파일뿐 아니라 Ansible 실행용 컨테이너 이미지, Ceph 이미지, 런타임 바이너리, 사내 프로그램 압축 파일, VM 디스크 이미지까지 같은 Git으로 관리했다.

개발용과 배포용 저장소도 별도로 운영했다. 개발용에 파일을 넣고 커밋한 뒤 배포용에도 변경을 반영했다. 정해진 릴리스 시점보다 수정사항이 생길 때마다 복사하거나 cherry-pick하는 흐름에 가까웠다.

<figure class="flow" aria-label="변경 전 코드와 파일 전달 순서">
  <ol><li>개발용 Git 수정</li><li>배포용 Git에도 반영</li><li>사업팀 전체 clone</li><li>고객사 Ansible 실행</li></ol>
</figure>

사업수행팀은 배포용 저장소의 버전 브랜치를 선택했다. 하지만 브랜치의 현재 파일만 사용하는 것과 Git 이력을 얼마나 내려받는지는 다른 문제였다. 기본 clone에는 과거 객체도 포함됐다.

당시 방식의 장점도 있었다. 저장소 하나를 받으면 설치에 필요한 파일을 찾기 쉬웠고, Ansible의 `files/` 경로에서 바로 복사할 수 있었다. 문제는 이미지 교체가 반복될수록 현재 배포에 필요 없는 내용까지 Git 이력에 누적된다는 점이었다.

## 2. 어디에서 26GiB가 생겼는가

변경 전 clone 로그와 용량 분석 기록을 기준으로 정리한 수치다. 아래 시간은 단일 실행의 전체 경과 시간이며, 인증 대기와 checkout도 포함할 수 있다. 순수 네트워크 전송 시간으로 해석하지 않았다.

| 항목 | 변경 전 기록 | 의미 |
| --- | --- | --- |
| 전체 clone 디렉터리 | 26.25GiB | 작업 트리와 `.git`을 포함한 디스크 사용량 |
| `.git` | 19.40GiB | 대부분 `.git/objects/pack` |
| 작업 트리 | 약 6.85GiB | checkout된 현재 파일 |
| Git 수신 로그 | 19.39GiB | clone 중 수신한 Git 객체 데이터 |
| 전체 경과 시간 | 19분 13.51초 | `/usr/bin/time -v` 기록 |
| 최대 RSS | 약 4.37GiB | 해당 측정에서 기록한 최대 상주 메모리 |

Git은 파일 내용을 **blob 객체**로 보관한다. 여러 객체를 압축하고 차이를 표현해 묶어 놓은 것이 **pack**이다. 파일 원본의 크기와 pack에서 차지하는 크기는 같지 않다.

| 분석 항목 | 관측 결과 | 판단 |
| --- | --- | --- |
| Commit 객체 | 229개, 논리 크기 약 58KiB | 커밋 메타데이터 자체는 주요 원인이 아님 |
| Blob 객체 | 3,631개, 논리 크기 30.47GiB | 파일 내용이 큰 비중을 차지 |
| 10MiB 이상 blob | 148개, 현 pack 기여분 약 19.33GiB | 전체 pack의 약 99.66% |
| `.tar` 이력 | 현 pack 기여분 약 15GiB | 가장 큰 원인 |
| `.qcow2` 이력 | 현 pack 기여분 약 2.6GiB | VM 이미지도 상당한 비중 |

여기서 논리 크기는 압축을 풀었을 때의 객체 내용 크기다. 서로 다른 버전의 blob을 합산하므로 현재 작업 트리 크기보다 클 수 있다. pack 기여분은 분석 시점의 저장 표현에 따른 값으로, 파일을 제거했을 때 회수할 공간과 정확히 같지는 않다. 재압축과 객체 간 참조 관계도 영향을 준다.

현재 브랜치들에서 이미 삭제된 대형 TAR도 과거 커밋에는 남아 있었다. 최신 디렉터리만 훑으면 이 부분을 놓친다.

<details class="analysis-toggle" markdown="1">
<summary>Git 용량을 확인할 때 먼저 나눠 볼 항목</summary>

Linux의 clone 디렉터리에서 실행하는 조회 예시다. 저장소를 변경하지 않으며, 아래 명령을 이 글 작성 중 운영 서버에서 다시 실행한 것은 아니다.

```bash
du -sh . .git .git/objects/pack
git count-objects -vH
git rev-parse --is-shallow-repository
```

`du`는 디스크 사용량, `count-objects`는 loose 객체와 pack 구성을 확인한다. shallow 여부는 전체 이력을 받은 저장소인지 구분하는 데 필요하다. 대용량 원본 blob을 찾는 예시는 다음과 같다.

```bash
git rev-list --objects --all |
  git cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' |
  awk '$1 == "blob"' |
  sort -k3,3nr |
  head -20
```

세 번째 열은 원본 크기인 byte 값이다. **이 명령만으로 pack 물리 기여분을 계산한 것은 아니다.** `--all`도 로컬에서 알고 있는 참조를 기준으로 하므로 서버의 숨겨진 참조·unreachable 객체까지 전수 조사하는 명령은 아니다.

</details>

**다른 브랜치를 받아서 커진 것일까?**

기존 명령은 `git clone -b <버전브랜치>`였다. `-b`는 최초 checkout 대상을 고르는 옵션이지 다른 브랜치의 객체를 모두 제외하는 옵션이 아니다. 다만 당시 분석에서 다른 브랜치에만 필요한 고유 객체는 약 175.5MiB였고, 선택한 브랜치가 이어받은 과거 바이너리 이력이 더 큰 원인이었다. [Git clone 옵션](https://git-scm.com/docs/git-clone)

## 3. Shallow clone이나 LFS만으로 해결하지 않은 이유

| 방법 | 달라지는 점 | 이 환경에서 남는 문제 |
| --- | --- | --- |
| `--depth=1` | 받는 커밋 이력을 제한 | 현재 대형 파일은 여전히 Git 안에 존재. 원격의 과거 이력도 그대로 |
| Git LFS | Git에는 작은 포인터, 파일 본체는 LFS 저장소에 보관 | 현재 배포 파일과 로컬 LFS 캐시 공간이 필요. 폐쇄망 반입 절차도 필요 |
| Nexus 분리 | Git은 코드·목록, Nexus는 이미지·파일 관리 | 다운로드 로직, 버전 연결, 반입 패키징을 별도로 구성해야 함 |

LFS가 잘못된 선택이라서 제외한 것은 아니다. 기본적으로 checkout에 필요한 LFS 파일을 받고, 과거 모든 파일을 한 번에 받는 방식은 아니다. 다만 작업 트리와 `.git/lfs/objects` 캐시에 같은 내용이 각각 존재할 수 있어, Git 객체가 작아진 만큼 전체 로컬 공간도 그대로 줄어든다고 계산할 수는 없다. 기존 큰 blob을 과거 이력까지 LFS로 옮기는 작업 역시 별도 마이그레이션이다. [LFS fetch](https://github.com/git-lfs/git-lfs/blob/main/docs/man/git-lfs-fetch.adoc), [LFS migrate](https://github.com/git-lfs/git-lfs/blob/main/docs/man/git-lfs-migrate.adoc)

우리에게 필요한 것은 이미지의 Git 보관 방식을 바꾸는 것만이 아니었다. **사내에서는 필요한 버전을 내려받고, 폐쇄망에서는 그 버전들만 담은 배포 재료를 공급하는 구조**가 필요했다. 컨테이너 Registry와 일반 파일 저장소를 함께 운영할 수 있는 Nexus로 분리했다.

## 4. 코드·파일·패키징의 역할 분리

| 구성 요소 | 맡은 역할 |
| --- | --- |
| Gitea | Ansible 코드, 설치 스크립트, manifest, 릴리스 태그 |
| Nexus `docker-hosted` | Ansible 실행 이미지, Ceph 등 컨테이너 이미지 |
| Nexus `raw-hosted` | TAR.GZ, 런타임 바이너리, wheel, QCOW2 등 일반 파일 |
| Nexus `raw-manifest` | 릴리스별 배포 목록과 식별 정보 |
| Nexus `raw-release-bundle` | 고객사 반입용 최종 TAR와 체크섬 |
| Gitea Actions·Runner | 릴리스 이벤트 처리와 패키징 작업 실행 |
| HAProxy | 고정 다운로드 주소를 실제 버전별 TAR 주소로 연결 |

<figure class="flow" aria-label="변경 후 릴리스 패키징 구성">
  <ol><li>Gitea 코드·태그</li><li>Runner가 Nexus 재료 수집</li><li>Nexus에 Bundle 게시</li><li>사업팀 TAR 다운로드</li></ol>
</figure>

Repository는 파일을 제공하는 형식과 경로의 단위다. Nexus의 Blob Store는 그 내용이 저장되는 공간이다. Docker와 Raw를 같은 Blob Store에 연결하더라도, 하나의 Repository에서 두 프로토콜을 함께 제공하는 것은 아니다.

컨테이너 이미지는 TAR 파일을 Raw에 올리는 것으로 끝내지 않고 Registry에 이미지로 등록한다. 반대로 프로그램 압축 파일이나 QCOW2는 Raw에 파일 그대로 둔다.

**manifest는 릴리스에 들어갈 재료 목록이다.** Raw 경로와 SHA256, 이미지 식별 정보를 코드와 함께 관리한다. SHA256은 파일 내용이 같은지 확인하는 해시이며, 이미지 digest도 특정 이미지 내용을 식별하는 데 사용한다. 이름이 같다고 내용까지 같다고 가정하지 않기 위한 장치다.

## 5. Ansible은 Git의 files 대신 Nexus를 참조

기존에는 Ansible 실행 환경에 대형 파일이 있어야 했다. 변경 후에는 대상 서버가 Nexus에서 정해진 파일을 받는다. 아래는 변경 원리를 보여 주는 축약 예시이며, 운영 코드 전체나 실제 diff는 아니다.

**변경 전 — role의 files 디렉터리에서 복사**

```yaml title="기존 task의 형태"
- name: Copy application package
  ansible.builtin.copy:
    src: app-agent.tar.gz
    dest: /var/tmp/app-agent.tar.gz
    mode: '0644'
```

**변경 후 — inventory 주소와 파일 식별값으로 다운로드**

주소는 사용자 inventory의 공통 변수에 둔다. 같은 값을 Runner 환경변수에서도 넘겨야 하는 구조로 만들지는 않는다. 예시는 스킴을 포함한 주소를 사용하는 형태다.

```yaml title="inventory/group_vars/all/main.yml — 설명용 예시"
nexus_url: "https://nexus.example.com"
```

아래는 변수 치환이 끝난 값을 보여 주는 예시다. 실제 task에서는 `nexus_url`, 패키지 경로, SHA256을 변수로 연결한다. 예시의 도메인과 경로는 실제 다운로드 주소가 아니며, 파일을 받을 서버가 Nexus에 접근할 수 있고 인증서를 신뢰한다는 전제다. 체크섬 URL을 쓰는 예시와 달리, manifest에 기록한 SHA256 값을 직접 지정할 수도 있다.

```yaml title="Nexus 다운로드 task의 형태"
- name: Download application package
  ansible.builtin.get_url:
    url: "https://nexus.example.com/repository/raw-hosted/app-agent/4.0.1/app-agent.tar.gz"
    dest: /var/tmp/app-agent.tar.gz
    checksum: "sha256:https://nexus.example.com/repository/raw-hosted/app-agent/4.0.1/SHA256SUMS"
    mode: '0644'
```

`get_url`은 기본적으로 task가 실행되는 대상 노드에서 다운로드한다. 파일 목적지를 명시하고 checksum을 제공하면, 기존 파일의 해시가 일치할 때 불필요한 다운로드를 피할 수 있다. [Ansible get_url 문서](https://docs.ansible.com/projects/ansible/latest/collections/ansible/builtin/get_url_module.html)

사내 테스트에서는 사내 Nexus, 고객사에서는 반입한 Private Nexus를 바라본다. 파일의 Repository 내부 경로를 유지하면 설치 주소만 환경에 맞게 바꿀 수 있다.

!!! warning "배포 목록과 Ansible 참조는 일치해야 함"
    패키징용 `manifest.yaml`과 Ansible용 `nexus.yml`을 별도로 관리하던 단계에서는 두 파일의 버전·경로를 함께 수정해야 했다. 목록에 빠진 파일은 고객사 Nexus에 없을 수 있다. Ansible이 manifest를 직접 읽도록 통합하는 방식은 별도 개선 대상으로, 이 글에서 구현 완료로 다루지 않는다.

## 6. 태그에서 고객사 반입 TAR까지

Gitea Actions는 어떤 이벤트에 어떤 작업을 실행할지 정의하고, Runner는 실제 명령을 수행한다. 이 구성의 Runner는 호스트 실행 방식이며 동시 작업 수는 1개로 제한했다. Git clone, Raw 다운로드, 이미지 저장, TAR 생성과 업로드가 같은 작업 흐름 안에서 이어진다.

| 단계 | 입력 | 출력·처리 |
| --- | --- | --- |
| 릴리스 시작 | `v4.x.x` 태그 또는 별도로 허용한 수동 실행 | 대상 릴리스 확정 |
| 소스 확보 | 확정한 Git 참조 | shallow clone한 소스. 뒤 단계에서 재사용 |
| manifest 게시 | 소스 안의 `manifest.yaml` | 릴리스·커밋·해시를 기록한 식별 정보와 배포 목록 |
| Bundle 생성 | 소스, manifest, Nexus 아티팩트 | 필요한 재료와 설치 스크립트를 모은 TAR·체크섬 |
| Bundle 게시 | 완성된 TAR | 버전별 Nexus 경로에 업로드 |
| 다운로드 주소 갱신 | 성공적으로 게시한 릴리스 | 해당 계열과 전체 현재 릴리스의 연결 갱신 |
| 보관 정리 | 계열별 릴리스 목록 | 각 계열의 최신 Bundle 2개 유지 |

일반 코드 push마다 대용량 Bundle을 만드는 방식은 제외했다. 코드만 바뀌었든 이미지 목록이 바뀌었든 배포할 시점에 새 태그로 형상을 확정한다. 여기서 형상은 그 릴리스에 사용할 코드와 파일 목록의 조합이다.

`release-info.yaml`은 그 조합의 식별 정보다. manifest 게시 단계에서는 Git 커밋과 manifest 해시를 연결하고, Bundle 게시 단계에서는 완성된 TAR 경로·크기·해시 정보까지 연결한다. **같은 파일명이라도 단계별 내용과 역할은 다르다.**

**이미 받았던 파일은 다시 내려받지 않도록**

- Raw는 SHA256 기준 캐시를 확인하고, 일치하면 재사용한다.
- 이미지는 containerd에 보관된 콘텐츠를 활용한다. 필요한 digest·레이어가 있으면 전체 재다운로드를 피하지만 원격 메타데이터 조회까지 없다는 뜻은 아니다.
- 코드만 달라져도 최종 TAR 생성과 업로드는 다시 필요하다. 캐시는 네트워크 전송을 줄이는 장치이지 패키징 전체를 생략하는 장치가 아니다.
- 계열별 최신 2개 보관 정책은 **최종 Bundle** 기준이다. 원본 이미지·Raw와 Git 태그의 보존 정책은 별도로 관리한다.

예를 들어 4.1 계열에 `4.1.1`, `4.1.2`, `4.1.3` Bundle이 있으면 `4.1.2`, `4.1.3`을 유지한다. 4.2 계열의 보관 개수와는 독립적이다. Nexus에서 오래된 Bundle을 제거하는 일과 Git 태그를 지우는 일도 다르다.

## 7. 사업수행팀은 TAR 하나를 반입

개발팀은 코드와 아티팩트를 관리하고, 사업수행팀은 게시된 릴리스 Bundle을 선택한다. 사업팀이 Git 이력과 Nexus 전체 데이터를 각각 챙길 필요가 없도록 필요한 설치 재료를 하나로 묶었다.

<figure class="flow" aria-label="사업수행팀의 고객사 설치 순서">
  <ol><li>현재 릴리스 선택·다운로드</li><li>TAR 하나 고객사 반입</li><li>압축 해제·deploy.sh</li><li>Private Nexus·Ansible 기동</li></ol>
</figure>

다운로드 진입점은 전체 현재 릴리스와 계열별 현재 릴리스로 구분한다. 예를 들어 전체 현재 릴리스가 4.2.x여도, 4.1 계열을 선택하면 4.1.x 중 게시된 현재 버전을 받을 수 있다. `current`는 무조건 가장 최근에 실행한 작업이 아니라, 게시 로직이 선택한 릴리스를 뜻한다.

고정 주소마다 대형 TAR를 복제해 두지는 않는다. HAProxy가 주소 매핑을 조회하고 **302 리다이렉트**, 즉 실제 파일 주소로 이동하라는 응답을 돌려준다. 다운로드 클라이언트는 그 주소를 따라 Nexus의 버전별 TAR를 받는다. 릴리스 게시 후 매핑을 갱신하므로 사업팀의 진입 주소는 유지할 수 있다.

Bundle에는 다음 재료가 함께 필요하다.

- 확정한 Ansible 소스와 배포 목록·식별 정보
- 필요한 Raw 파일과 컨테이너 이미지 아카이브
- Nexus 자체 이미지와 실행 설정
- containerd·nerdctl 등 초기 기동에 필요한 바이너리와 설정
- Nexus 초기 구성·아티팩트 적재·Ansible 컨테이너 실행을 연결하는 `deploy.sh`

특히 런타임 준비 파일을 빠뜨리면 순환 의존이 생긴다. Nexus를 띄워야 containerd를 받을 수 있는데, containerd가 없어서 Nexus를 띄우지 못하는 상황이다. 그래서 최초 기동에 필요한 재료는 실행 중인 Nexus 없이도 사용할 수 있게 Bundle에 포함한다.

`deploy.sh`는 중간 실패 후 재실행을 고려하는 구조로 정리했다. 이미 설치된 런타임이나 기동된 서비스를 무조건 덮어쓰는 방식보다, 상태를 확인하고 필요한 단계를 진행하는 것이 목적이다. **Nexus와 Ansible 컨테이너 기동은 OpenStack 전체 구축 성공과는 별도의 완료 지점**이다.

## 8. 저장소 운영 방식도 함께 정리

개발용·배포용 저장소 사이의 반복 반영 대신, 하나의 저장소에서 개발 흐름과 릴리스 태그를 관리하는 방향으로 바꿨다. 아래는 팀 운영 규칙으로 정리한 흐름이며, 모든 보호 정책의 적용 완료를 뜻하지 않는다.

```text
feature/* → develop → master → v4.x.x 태그
```

- `master`: 릴리스 기준 코드
- `develop`: 다음 릴리스를 위한 변경 통합
- `feature/*`: 기능 작업 중 사용하는 임시 브랜치
- `v4.x.x`: 배포 기준 커밋을 가리키는 릴리스 태그

master 직접 push 차단과 PR·merge 강제는 적용할 보호 규칙으로 구분했다. develop 직접 push 허용 여부도 팀 정책으로 결정할 부분이다. 브랜치 이름만 만들었다고 리뷰나 검증이 자동으로 강제되지는 않는다.

과거 계열에만 패치가 필요하면 해당 태그에서 임시 패치 브랜치를 만든다. `v4.0.5`에서 수정해 `v4.0.6` 태그를 남기는 방식이다. master에 그 변경을 merge하지 않으면 최신 계열에는 반영되지 않는다. 임시 브랜치를 삭제해도 태그가 남아 있으면 그 커밋과 연결된 이력을 참조할 수 있다. 다음 패치는 `v4.0.6`에서 시작할 수 있다.

## 9. 줄어든 책임과 남아 있는 비용

| 항목 | 기존 | 변경한 구조 |
| --- | --- | --- |
| 개발 코드 확보 | 대형 바이너리와 과거 이력까지 Git으로 수신 | 코드와 배포 목록 중심 |
| 버전 연결 | 브랜치 최신 상태와 수동 반영에 의존 | 태그·manifest·체크섬으로 연결 |
| 배포 파일 확보 | 사업팀이 전체 clone | 필요한 릴리스 Bundle 다운로드 |
| 반복 패키징 | 파일 수집과 반입 준비의 수작업 | Runner 실행과 캐시 재사용 |
| 대용량 파일 저장 | Git blob 이력 | Nexus 아티팩트·버전별 Bundle |

변경 후 clone 용량·시간의 동일 조건 측정값은 이 기록에 포함하지 않았다. 따라서 몇 퍼센트 감소했다거나 몇 배 빨라졌다는 수치는 제시하지 않는다. 확인한 변화는 코드·배포 재료·반입물의 책임을 나눴다는 점이다.

!!! warning "Nexus로 옮겼다고 과거 Git 이력이 자동 삭제되지는 않음"
    최신 커밋에서 파일을 지워도 과거 커밋이 참조하는 blob은 남는다. 기존 이력을 유지하며 다시 쓰는 방식인지, 코드를 옮긴 새 저장소에서 시작하는지 구분해야 한다. 이력 재작성은 커밋 ID·태그·협업자의 clone에 영향을 주므로 백업과 별도 전환 계획이 필요한 작업이다.

Nexus에도 원본 아티팩트와 최종 Bundle의 저장 비용이 남고, Runner에는 캐시와 임시 작업 공간이 필요하다. 폐쇄망 설치에 필요한 파일 자체가 작아진 것은 아니다. **불필요한 Git 이력 전송을 줄이는 것과 전체 배포 시스템의 디스크를 줄이는 것은 서로 다른 목표**다.

다음 개선 대상으로는 패키징 이후의 설치 검증을 두었다. 빌드한 TAR를 staging에 게시하고, OpenTofu로 만든 VMware 테스트 VM에서 설치 시험을 통과했을 때만 정식 releases와 current 연결을 갱신하는 방식이다. 실패 시 기존 연결을 유지하고 테스트 VM·staging 산출물을 정리한다. 이 단계는 향후 계획이며 현재 파이프라인의 검증 완료 항목으로 포함하지 않았다.

## 10. 참고 자료

- [Git clone — branch, depth, single-branch 옵션](https://git-scm.com/docs/git-clone)
- [Git 객체와 packfile](https://git-scm.com/book/en/v2/Git-Internals-Packfiles)
- [Git LFS fetch](https://github.com/git-lfs/git-lfs/blob/main/docs/man/git-lfs-fetch.adoc)
- [Git LFS migrate](https://github.com/git-lfs/git-lfs/blob/main/docs/man/git-lfs-migrate.adoc)
- [Ansible get_url](https://docs.ansible.com/projects/ansible/latest/collections/ansible/builtin/get_url_module.html)
- [Gitea Runner](https://docs.gitea.com/runner/)
