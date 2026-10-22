---
title: "사내 Gitea 경량화 (8) — 커지는 Nexus와 배포 이미지 관리하기"
summary: "Git에서 옮긴 대용량 파일은 Nexus에서 계속 관리해야 한다. 계열별 Bundle 3개 보관, staging 자동 정리, Blob 용량 회수와 캐시 재사용, 취약한 배포 재료를 교체하는 기준을 정리한다."
summary_style: editorial
date: 2026-10-22
category: 구축설계
tags:
  - OpenStack
  - Automation
  - Linux
  - 가이드
---

<section class="editorial-summary editorial-summary--text-only" aria-labelledby="editorial-summary-title">
  <div class="editorial-summary-layout">
    <div class="editorial-summary-copy">
      <span class="editorial-summary-label">사내 Gitea 경량화 · 저장소 운영 편</span>
      <h2 id="editorial-summary-title" class="editorial-summary-title">Git을 가볍게 만든 뒤에는 Nexus에 무엇을 남길지 정해야 한다.</h2>
      <p>설치 재료와 최종 TAR를 같은 기준으로 지우면 과거 릴리스를 다시 만들 수 없게 된다. 원본 재료·임시 후보·완성된 배포물을 나누고, 파일 삭제와 실제 디스크 반환도 구분한다.</p>
    </div>
  </div>
  <p class="editorial-summary-result"><span><strong>Bundle은 계열별 최신 3개, staging은 짧게, 원본은 참조를 확인한 뒤 정리한다.</strong> 같은 재료는 캐시로 재사용하고 보안 수정은 새 버전으로 발행한다.</span></p>
</section>

[7편](../automation/2026-10-22-gitea-lightweight-7.md)에서 누가 어떤 버전을 발행할지 정했다. 이번에는 발행을 반복할 때 늘어나는 저장 공간과 설치 재료를 다룬다. Git에서 파일을 옮겼다고 파일 자체가 사라진 것은 아니다. 다만 이제 **코드 이력과 설치 파일의 보관 정책을 따로 적용할 수 있다.**

## 1. 저장소는 역할별로, Blob Store는 하나로 시작

Repository는 사용자가 접근하는 논리 저장소이고, Blob Store는 파일 본문이 실제로 저장되는 공간이다. 아래는 관리 관계를 나타낸 그림이며 Blob 디렉터리에 Repository별 폴더를 직접 만드는 구조는 아니다.

```text title="Nexus의 역할 분리"
Blob Store: contrabass-engine
├── docker-hosted       컨테이너 이미지
├── raw-hosted          프로그램·바이너리·QCOW2·wheel
├── raw-manifest        재료 목록·릴리스 정보·실행 기록·channel 정보
├── raw-release-staging 시험 중인 후보 TAR
└── raw-release-bundle  최종 반입 TAR
```

처음부터 Blob을 제품마다 나눌 필요는 없다. 대신 **여러 Repository가 같은 Blob Store를 쓰면 compact도 공유 공간 전체에 적용**된다는 점을 기억한다. Repository 하나를 정리했다고 그 Repository만 별도의 물리 백업 단위가 되는 것도 아니다.

| 대상 | 남길 기준 | 정리 방식 |
| --- | --- | --- |
| 최종 Bundle | 릴리스 계열별 최신 3개 | 게시 스크립트가 버전 순으로 계산 |
| staging 후보 | 실행이 끝나면 삭제, 오래된 잔여물은 3일 | Workflow 정리 + Nexus Cleanup Policy |
| manifest·실행 기록 | 버전·해시·시험 선택을 추적할 수 있게 보관 | TAR 정리와 분리 |
| Raw·컨테이너 원본 | 지원 릴리스와 배포 현장에서 필요한 재료 | 참조 확인 후 선별 정리 |
| Runner 캐시 | 다시 받을 수 있는 재료 | 사용량을 보고 별도 정리 |

---

## 2. Bundle은 계열별 최신 3개만 남긴다

정식 패키지를 게시하고 조회·해시 확인을 마친 뒤 보관 목록을 계산한다. 이 시리즈의 보관 기준은 **계열별 3개**다.

```bash title="bundle-pipeline.env의 보관 정책"
RELEASE_KEEP_COUNT=3
```

| 계열 | 발행된 버전 | 정리 후 남는 TAR |
| --- | --- | --- |
| 4.0 | 4.0.5, 4.0.6, 4.0.7, 4.0.8 | 4.0.6, 4.0.7, 4.0.8 |
| 4.1 | 4.1.1, 4.1.2, 4.1.3, 4.1.4 | 4.1.2, 4.1.3, 4.1.4 |
| 4.2 | 4.2.0, 4.2.1 | 두 버전 모두 |

문자열 순서나 업로드 시각이 아니라 **릴리스 버전 순서**로 판단한다. `4.1.10`은 `4.1.9`보다 최신이다. 나중에 발행한 과거 계열 패치가 전체 최신 릴리스를 밀어내서도 안 된다.

<p class="subsection-title"><strong>2-1. 파일 한 벌과 channel 포인터</strong></p>

<div class="section-body" markdown="1">

실제 TAR는 `raw-release-bundle/releases/<계열>/<Tag>/`에 한 번 저장한다. `current`와 계열별 주소에 대용량 TAR를 다시 복사하지 않는다.

```text title="4.1.4가 발행되고 전체 최신은 4.2.1인 경우"
channels/4.1/contrabass-engine-deploy.tar
    → 302 → releases/4.1/v4.1.4/contrabass-engine-deploy.tar

channels/current/contrabass-engine-deploy.tar
    → 302 → releases/4.2/v4.2.1/contrabass-engine-deploy.tar
```

새 4.1 패치는 4.1 채널만 갱신한다. 전체 최신이 바뀌는 경우에만 current도 바뀐다. `update-release-alias`가 HAProxy map의 대응 주소를 바꾸고, HAProxy는 사용자의 고정 URL을 실제 버전 URL로 안내한다.

</div>

<p class="subsection-title"><strong>2-2. 오래된 버전을 지울 때 남기는 것</strong></p>

<div class="section-body" markdown="1">

- 삭제 대상은 해당 버전의 **최종 TAR·체크섬·번들용 정보**다.
- Git Tag·Ansible 코드·manifest 이력은 삭제하지 않는다.
- `retained-releases.txt`에는 현재 보관 중인 버전 목록을 기록한다.
- 원본 Raw·이미지는 Bundle을 지웠다는 이유만으로 함께 지우지 않는다.
- 채널이 삭제할 버전을 가리키지 않는지 먼저 확인한다.

이 정책을 일반적인 “30일 지난 파일 삭제”로 바꾸지 않는다. 자주 출시하는 계열과 드물게 출시하는 계열을 같은 일수로 지우면, 지원 중인 계열의 유일한 TAR까지 없어질 수 있다. 새 Nexus의 버전 수 보관 기능도 제품·DB·포맷 조건이 있으므로 **임의 Raw 경로를 계열별로 3개 남기는 기능과 같다고 가정하지 않는다.** [Nexus Retain Select Versions](https://help.sonatype.com/en/cleanup-policies.html#retain-select-versions)

</div>

---

## 3. staging은 Workflow 정리와 3일 정책을 함께 사용

정상 실행은 승격·실패 처리 뒤 이번 후보를 정리한다. 그러나 Runner 강제 종료나 과거 코드의 정리 누락까지 현재 Workflow 한 번으로 해결되지는 않는다. 그래서 **정상 정리와 오래된 잔여물 정리**를 나눈다.

<figure class="flow" aria-label="staging 후보의 정리 순서">
  <ol>
    <li>후보 업로드</li>
    <li>시험·승격 또는 실패</li>
    <li>이번 후보 삭제</li>
    <li>오래된 잔여물 정리</li>
  </ol>
</figure>

Nexus 3.96 계열의 Classic UI에서는 **설정 → Repository → Cleanup Policies → Create Cleanup Policy**에서 다음 정책을 만든다. 등록 후 **Repositories → raw-release-staging → Cleanup Policies**에 연결한다.

| 설정 | 권장 시작값 | 이유 |
| --- | --- | --- |
| Name | `staging-expire-3d` | 정책 목적과 기간을 이름으로 표시 |
| Format | `raw` | staging은 Raw Hosted 저장소 |
| Component Age | 3일 | 업로드·갱신된 지 오래된 후보 제거 |
| Component Usage | 사용하지 않음 | 누가 다시 다운로드했다고 잔여물이 계속 남지 않게 함 |
| 적용 Repository | `raw-release-staging`만 | 최종 TAR·manifest·원본 파일에 오적용 방지 |

3일은 짧은 설치 시험을 위한 시작값이다. **최대 시험 시간과 재시도 시간보다 길어야 한다.** 며칠씩 진행하는 시험이라면 기간을 늘리거나 실행 중 후보를 보호하는 별도 처리가 필요하다. Hosted의 Component Age는 업로드·갱신 시각을 기준으로 한다. [Nexus Cleanup Criteria](https://help.sonatype.com/en/cleanup-policies.html#component-age-days)

정책은 대상을 정의할 뿐 실행 자체가 아니다. **System → Tasks**에서 `Admin - Cleanup repositories using their associated policies` 작업의 일정을 확인한다. 백업과 겹치지 않는 새벽 유지보수 시간에 실행한다. 처음에는 Preview로 삭제 후보를 확인하고, 이미 진행 중인 시험이 없는지 점검한다.

<details class="analysis-toggle" markdown="1">
<summary>후보가 계속 남을 때 확인할 것</summary>

1. 성공·실패 경로 모두에 정리 Step이 있는가.
2. 업로드를 시작한 실행만 자기 후보를 지우는가.
3. Nexus API의 `path`에 맨 앞 `/`가 붙어 비교가 어긋나지 않는가.
4. 조회 API의 다음 페이지까지 확인하는가.
5. Runner 계정에 staging `delete` 권한이 있는가.

예를 들어 API 응답은 `/candidates/...`인데 코드가 `candidates/...`와 비교하면 같은 파일을 찾지 못할 수 있다. API의 경로 표현을 정규화한 뒤 **정확한 후보 경로**와 비교해야 한다. 오래됐다는 이유만으로 다른 실행의 후보까지 통째로 삭제하지 않는다.

Cleanup Policy는 이런 오류를 고치는 기능이 아니라 장기 잔여물을 정리하는 안전망이다.

</details>

---

## 4. 웹에서 지웠는데 디스크가 그대로인 이유

Nexus에서 파일을 삭제하면 논리적으로 삭제된 상태가 되고, 실제 Blob 본문은 즉시 없어지지 않을 수 있다. UI에서 보이지 않는 것과 운영체제의 남은 공간이 늘어나는 것은 다른 단계다.

```text title="삭제와 공간 반환은 두 단계"
Workflow/API/UI/Cleanup Policy로 삭제
    → soft delete: 서비스에서는 사라졌지만 본문은 남을 수 있음
    → Admin - Compact blob store
    → 실제 디스크 공간 회수
```

**System → Tasks → Create task → Admin - Compact blob store**에서 `contrabass-engine` Blob Store를 선택한다. `Blobs Older Than`은 삭제 표시 뒤 물리 정리까지 기다릴 기간이다. 실수 삭제에 대응할 여유를 두려면 1일로 시작하고, 즉시 회수가 필요할 때만 영향 범위를 확인한 뒤 0일을 검토한다. [Nexus Compact blob store](https://help.sonatype.com/en/cleanup-policies.html#hard-deleting-components-with-the-compact-blob-store-task)

!!! warning "공유 Blob Store의 물리 삭제는 되돌리기 어렵다"
    compact는 staging만 정리하는 작업이 아니다. 같은 Blob Store에 있는 다른 Repository의 삭제 표시된 파일도 대상이 될 수 있다. DB·Blob 백업과 삭제 대상을 확인하고, Nexus 데이터 디렉터리 안에서 `.bytes`나 `.properties`를 직접 지우지 않는다.

호스트에서 아래 명령으로 파일시스템 여유와 실제 점유를 함께 본다. 경로는 Nexus 데이터 볼륨에 맞춘다. 아래 출력값을 대입해 운영 전후를 비교한다.

```bash title="Nexus 호스트에서 공간 확인"
df -h /data/nexus/nexus-data
du -sh /data/nexus/nexus-data/blobs
```

Docker의 미참조 layer·manifest 정리는 별도의 주의가 필요하다. **digest로 참조하는 이미지가 단순히 Tag가 없다는 이유로 제거되지 않게** 한다. 원본 manifest가 사용하는 digest를 확인하지 않은 채 `Docker - Delete unused manifests and images`를 무조건 예약하지 않는다. [Nexus Docker Cleanup Strategies](https://help.sonatype.com/en/cleanup-policies.html#docker-cleanup-strategies)

---

## 5. 같은 재료는 다시 받지 않지만 TAR는 새로 만든다

코드 한 줄이 바뀌었다고 모든 이미지를 처음부터 다시 내려받을 필요는 없다. 반대로 캐시가 있다고 새 릴리스의 최종 TAR 생성까지 생략할 수는 없다.

| 대상 | 재사용 기준 | 남는 작업 |
| --- | --- | --- |
| Raw·바이너리 | manifest SHA256과 로컬 캐시 내용 일치 | 새 TAR 구성에 포함 |
| 컨테이너 이미지 | manifest digest와 containerd 콘텐츠 일치 | 필요한 참조 확인·이미지 export |
| 코드 | 새 Tag의 소스 | 해당 코드로 새 TAR 구성 |
| 최종 TAR | 같은 릴리스의 같은 SHA256 | 이미 게시한 파일이면 재사용·재실행 |

Raw 캐시는 SHA256을 경로로 사용한다. 파일명이 같아도 내용이 달라지면 다른 캐시가 되고, 파일명이 달라도 내용이 같으면 재사용할 수 있다. containerd는 이미 가진 이미지 콘텐츠를 재사용하므로 매번 모든 layer를 전송하는 방식과 다르다. Registry에 digest·manifest를 확인하는 짧은 요청까지 전혀 없어진다는 뜻은 아니다.

캐시를 지워도 원본이 있으면 다시 받을 수 있다. **캐시는 백업의 최우선 대상이 아니며 원본 Repository와 역할이 다르다.** 운영체제 루트 디스크, Nexus Blob, Raw 캐시, containerd 콘텐츠, TAR 작업 공간을 나눠 관찰한다.

최종 TAR를 업로드하고 검증한 뒤에는 로컬 임시 TAR를 지운다. 생성 전에는 최소한 **재료를 조립할 공간 + 이미지 export + 최종 TAR**를 고려해야 한다. 원본 이미지 크기만 보고 여유 용량을 잡으면 패키징 중에 디스크가 찰 수 있다.

---

## 6. Nexus로 옮긴 이미지도 보안 점검은 필요하다

Nexus로 저장 위치를 옮기는 것은 취약점을 패치하는 일이 아니다. 컨테이너에는 베이스 OS 패키지와 프로그램이 함께 들어 있고, Raw 압축 파일에도 실행 바이너리가 포함될 수 있다. 파일 확장자만으로 검사 대상을 정하면 놓치는 항목이 생긴다.

| 점검 대상 | 실제로 확인할 것 | 흔한 오해 |
| --- | --- | --- |
| 컨테이너 이미지 | digest, OS·패키지·프로그램 버전 | Tag에 적힌 버전이 내부 모든 패키지의 버전은 아님 |
| BuildKit·런타임 압축 파일 | 압축 안의 runc 등 포함 바이너리 | 호스트 runc만 갱신하면 내장 runc도 바뀐다고 생각 |
| 사내 프로그램 | 포함 라이브러리·빌드 의존성 | 직접 개발했으므로 외부 CVE와 무관하다고 생각 |
| QCOW2 | 게스트 OS·설치 패키지 | QCOW2 파일에 일반 파일 스캔만 하고 OS까지 검사했다고 판단 |

예를 들어 오래된 BuildKit 묶음 안의 runc도 따로 확인해야 한다. runc의 CVE-2024-21626은 공식 공지에서 영향 버전과 수정 버전을 제시한다. Grafana CVE-2025-4123도 10.4 계열의 수정 버전을 `10.4.18+security-01`로 명시한다. **이 버전으로 올리면 앞으로의 모든 CVE가 해결된다는 뜻은 아니다.** [runc 공식 보안 공지](https://github.com/opencontainers/runc/security/advisories/GHSA-xr7r-f8xq-vfvv), [Grafana 공식 보안 공지](https://grafana.com/security/security-advisories/cve-2025-4123/)

<p class="subsection-title"><strong>6-1. 교체는 기존 Tag 덮어쓰기 대신 새 릴리스로</strong></p>

<div class="section-body" markdown="1">

1. 실제 이미지 digest·압축 내부 버전을 목록으로 만든다.
2. 스캐너 결과를 공식 공지·배포판 보안 정보와 대조한다.
3. 보안 수정이 포함된 이미지·바이너리로 교체한다.
4. Nexus에 새 버전으로 게시하고 manifest와 필요한 nexus.yml을 함께 갱신한다.
5. 새 릴리스 Tag로 설치·기능 시험을 수행한다.
6. Gitea Release에 교체 이유·영향·적용 시 주의점을 남긴다.

같은 Tag를 덮어쓰면 “어제 받은 v4.1.2와 오늘 받은 v4.1.2가 다른 파일”이 된다. 보안 패치도 이 규칙의 예외가 아니다. 긴급하면 배포 중단·노출 차단을 먼저 판단하고 새 패치 버전을 발행한다.

</div>

<p class="subsection-title"><strong>6-2. 운영 점검의 시작 주기</strong></p>

<div class="section-body" markdown="1">

| 시점 | 점검 |
| --- | --- |
| 새 재료를 게시할 때 | digest·SHA256·프로그램 버전 확인, 이미지·바이너리 스캔 |
| 주 1회 | 지원 중인 재료 재스캔, CVE DB 갱신, staging 잔여물·여유 공간 확인 |
| 월 1회 | 지원 종료 이미지·사용하지 않는 재료·캐시 정리 후보 검토 |
| 보안 공지·긴급 패치 시 | 정기 주기와 무관하게 영향 버전 확인·조치 |

CVE 개수가 0이라고 안전을 보장하지 않는다. 스캐너가 인식하지 못한 OS·직접 빌드한 파일·비활성화한 검사도 함께 봐야 한다. 반대로 버전 문자열만 비슷한 오탐을 확인 없이 취약점으로 확정하지 않는다.

</div>

Nexus 정리는 **재료를 잃지 않으면서 임시 파일과 오래된 배포물을 줄이는 일**이다. 삭제 실수나 물리서버 장애까지 대비하려면, 다음 단계는 독립된 백업과 복구다.

[← 7편: 승인과 릴리스 운영](../automation/2026-10-22-gitea-lightweight-7.md) · [9편: 백업과 복구 →](2026-10-22-gitea-lightweight-9.md)
