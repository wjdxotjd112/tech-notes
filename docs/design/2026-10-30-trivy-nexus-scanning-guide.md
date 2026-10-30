---
title: "Trivy 취약점 검사 (2) — Nexus 이미지·Raw 파일 검사하기"
summary: "Nexus 읽기 전용 계정으로 이미지를 직접 검사하고 Raw 파일의 해시와 내장 구성요소를 확인하는 실습 가이드. JSON 원본 보관부터 공식 권고 검토와 재검사까지 이어간다."
summary_style: editorial
date: 2026-10-30
category: 구축설계
tags:
  - Linux
  - Automation
  - 가이드
---

<section class="editorial-summary editorial-summary--text-only" aria-labelledby="editorial-summary-title">
  <div class="editorial-summary-layout">
    <div class="editorial-summary-copy">
      <span class="editorial-summary-label">Trivy 취약점 검사 · 실습 편</span>
      <h2 id="editorial-summary-title" class="editorial-summary-title">검사 대상을 해시로 고정하고, 원본 결과와 판단 근거를 함께 남긴다.</h2>
      <p>Nexus의 컨테이너 이미지는 레지스트리에서 직접 읽고, Raw 파일은 별도 작업 공간으로 내려받아 검사한다. 이미지를 실행하거나 운영 서비스의 런타임 설정을 바꿀 필요는 없다. 한 개를 확인한 뒤 목록으로 범위를 넓히는 순서다.</p>
    </div>
  </div>
  <p class="editorial-summary-result"><span><strong>다운로드·식별·검사 성공과 취약점 미검출은 서로 다른 결과다.</strong> 실패한 대상과 식별하지 못한 파일도 검사 기록에 남긴다.</span></p>
</section>

검사 원리·CVE·DB·도구 선택은 [1편 — 무엇을 근거로 취약하다고 판단할까?](../concepts/2026-10-30-trivy-vulnerability-principles.md)에서 설명한다. 먼저 이미지 한 개와 Raw 한 개를 확인하고, 같은 검사 조건으로 대상 목록 전체에 적용하는 순서다.

## 1. 이번에 검사할 범위와 준비물

| 항목 | 기준 |
| --- | --- |
| 검사하는 서버 | Ubuntu 24.04 LTS, x86_64, 일반 사용자·Bash |
| 도구 | Trivy 0.76.1, curl·jq·Python 3.12 이상 |
| 이미지 저장소 | Docker Registry API를 제공하는 Nexus의 `docker-hosted` |
| 파일 저장소 | `raw-hosted` |
| 계정 | 대상 저장소의 browse·read만 가진 읽기 전용 계정 |
| 기본 검사 | 알려진 취약점. 비밀정보·설정 오류·라이선스 검사는 제외 |
| VM 이미지 | QCOW2·IMG 내부 검사는 별도 범위 |

Trivy 0.76.1은 이 글의 명령 기준 버전이다. 향후 설치 시에는 [공식 릴리스](https://github.com/aquasecurity/trivy/releases)와 보안 공지도 확인한다.

**기존 Gitea·Nexus·Docker를 재시작하거나 운영 이미지·Blob을 정리하는 과정은 없다.** 다만 Nexus 읽기 부하, DB 다운로드, CPU·메모리·디스크 사용은 발생한다. 패키징 작업과 겹치지 않는 시간대에 하나씩 검사하는 방식으로 시작한다.

검사 서버는 다음 경로에 접근할 수 있어야 한다.

- Nexus의 이미지 API와 Raw 다운로드 주소
- 도구 설치 시 GitHub 릴리스 다운로드 경로
- 취약점 DB 배포 레지스트리와 필요한 인증·파일 배포 경로
- 서명 검증을 수행한다면 관련 Sigstore 경로

기능별 외부 통신은 [공식 네트워크 문서](https://trivy.dev/docs/latest/advanced/air-gap/)에서 확인한다. 이미지·Raw 파일을 외부 SaaS에 업로드하는 구성이 아니다.

---

## 2. 독립된 작업 공간과 검사기 준비

<p class="subsection-title"><strong>2-1. 작업 디렉터리 만들기</strong></p>

<div class="section-body" markdown="1">

실행 위치는 검사 담당자의 작업 디렉터리다. `SCAN_DIR`만 충분한 공간이 있는 경로 아래에 만든다. 아래 명령은 현재 디렉터리에 이름이 겹치지 않는 새 작업 공간을 만든다.

```bash
umask 077
export SCAN_DIR="$(mktemp -d "${PWD}/trivy-audit.XXXXXX")"
mkdir -p "${SCAN_DIR}"/{downloads,bin,cache,tmp,auth,raw,unpacked,reports}
export TMPDIR="${SCAN_DIR}/tmp"
export DOCKER_CONFIG="${SCAN_DIR}/auth"
df -h "${SCAN_DIR}"
df -i "${SCAN_DIR}"
```

`DOCKER_CONFIG`는 이번 검사에서 사용할 로그인 파일 위치다. 기존 `~/.docker/config.json`을 덮어쓰지 않도록 분리한다. 이름에 Docker가 들어가도 Docker 데몬을 설치·재시작하는 옵션은 아니다.

Trivy의 임시파일은 `TMPDIR`로 옮길 수 있다. 디스크 피크 사용량은 압축 크기와 같지 않으므로, 여유 공간과 inode를 함께 확인한다. 아래 검사에서는 `--parallel 1`로 동시 레이어 처리를 줄인다. [공식 디스크 부족 대응](https://trivy.dev/docs/latest/guide/references/troubleshooting/#running-out-of-space-during-image-scans)

</div>

<p class="subsection-title"><strong>2-2. 필요한 명령과 Trivy 설치</strong></p>

<div class="section-body" markdown="1">

아래 패키지는 검사 서버에 설치한다. 기존 런타임을 교체하는 명령이 아니다.

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl jq python3 python3-venv
```

Trivy는 시스템 경로 대신 이번 작업 공간에 설치한다. 아래 SHA256은 [공식 0.76.1 릴리스](https://github.com/aquasecurity/trivy/releases/tag/v0.76.1)의 Linux x86_64 아카이브 값이다.

```bash
(
  set -euo pipefail
  cd "${SCAN_DIR}/downloads"
  curl -fSL --connect-timeout 10 --max-time 300 --retry 3 \
    https://github.com/aquasecurity/trivy/releases/download/v0.76.1/trivy_0.76.1_Linux-64bit.tar.gz \
    -o trivy_0.76.1_Linux-64bit.tar.gz
  printf '%s  %s\n' \
    c7cbe3137fb8a48a17574bede3dd6beb16742d1e9772929940fc90082c39d9c0 \
    trivy_0.76.1_Linux-64bit.tar.gz | sha256sum -c -
)
```

체크섬이 일치하지 않으면 압축을 풀거나 실행하지 않는다. 체크섬 비교는 내용 일치 확인이고, 서명 검증과 같은 의미는 아니다. 배포자 서명까지 확인할 때는 다음 절차를 실행한 뒤 압축을 푼다.

</div>

<details class="analysis-toggle" markdown="1">
<summary>2-3. 배포자의 서명까지 확인하려면</summary>

Cosign 3 이상이 준비된 검사 서버에서, Trivy 바이너리를 실행하기 **전에** 아카이브 서명을 확인한다. Cosign의 설치와 신뢰 확인은 [Cosign 공식 설치 안내](https://docs.sigstore.dev/cosign/system_config/installation/)를 따른다.

```bash
(
  set -euo pipefail
  cd "${SCAN_DIR}/downloads"
  curl -fSL --connect-timeout 10 --max-time 60 \
    https://github.com/aquasecurity/trivy/releases/download/v0.76.1/trivy_0.76.1_Linux-64bit.tar.gz.sigstore.json \
    -o trivy_0.76.1_Linux-64bit.tar.gz.sigstore.json
  cosign verify-blob trivy_0.76.1_Linux-64bit.tar.gz \
    --bundle trivy_0.76.1_Linux-64bit.tar.gz.sigstore.json \
    --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
    --certificate-identity \
    'https://github.com/aquasecurity/trivy/.github/workflows/reusable-release.yaml@refs/tags/v0.76.1'
)
```

성공 종료와 검증 메시지를 확인한다. 파일 이름만 바꾸고 버전·서명·인증서 identity를 서로 다르게 두면 안 된다. 근거: [Trivy 공식 서명 검증](https://trivy.dev/docs/latest/getting-started/signature-verification/).

</details>

검증을 마친 아카이브에서 실행파일만 꺼낸다.

```bash
tar -xzf "${SCAN_DIR}/downloads/trivy_0.76.1_Linux-64bit.tar.gz" \
  -C "${SCAN_DIR}/bin" trivy
export PATH="${SCAN_DIR}/bin:${PATH}"
trivy --version
```

출력 버전이 `0.76.1`인지 확인한 뒤 다음 절차로 진행한다.

---

## 3. Nexus 주소·인증서·읽기 전용 로그인

<p class="subsection-title"><strong>3-1. 환경에 맞는 값 지정</strong></p>

<div class="section-body" markdown="1">

예시 주소는 실제 Nexus 주소로 교체한다. `NEXUS_URL`은 HTTPS 주소, `REGISTRY`는 프로토콜을 제외한 호스트·포트다. Raw 저장소 이름을 바꿨다면 다운로드 경로의 `raw-hosted`도 맞춘다.

```bash
export NEXUS_URL=https://192.0.2.10:55555
export REGISTRY="${NEXUS_URL#https://}"
export NEXUS_CA=/etc/ssl/certs/ca-certificates.crt
read -r -p 'Nexus 읽기 전용 사용자 ID: ' NEXUS_USER
```

공인 인증서라면 시스템 CA 번들을 사용한다. 사내 CA·자체 서명 인증서라면 담당자로부터 신뢰할 CA 인증서를 받아 `NEXUS_CA`를 해당 PEM 파일 경로로 바꾼다. 접속 IP·DNS가 인증서의 SAN과도 일치해야 한다. TLS 검증 실패를 비밀번호 오류와 혼동하지 않는다.

</div>

<p class="subsection-title"><strong>3-2. 이번 검사 전용 로그인</strong></p>

<div class="section-body" markdown="1">

비밀번호는 숨김 입력하고 표준입력으로 전달한다.

```bash
read -r -s -p 'Nexus 비밀번호: ' NEXUS_PASSWORD
printf '\n'
printf '%s' "${NEXUS_PASSWORD}" |
  trivy --config '' --cacert "${NEXUS_CA}" registry login \
    --username "${NEXUS_USER}" --password-stdin "${REGISTRY}"
unset NEXUS_PASSWORD
```

로그인 파일은 `SCAN_DIR/auth`에만 생긴다. 별도 credential helper가 없다면 파일의 인증정보는 암호화 저장이 아니므로 공유·커밋하지 않는다.

[공식 인증 설명](https://trivy.dev/docs/latest/advanced/private-registries/)은 환경변수로 전달한 자격정보가 여러 레지스트리에 사용될 수 있다고 경고한다. 여기서는 레지스트리별 로그인 파일을 사용한다. Raw의 curl 인증은 별개이며 해당 명령을 실행할 때 비밀번호를 입력한다.

</div>

<details class="analysis-toggle" markdown="1">
<summary>3-3. 자체 서명 인증서에서 검증 생략이 꼭 필요한 일회성 시험</summary>

우선 CA 등록을 권장한다. 검증을 생략하면 연결 상대를 신뢰할 수 있는지 확인하지 못하므로 읽기 전용 자격정보도 노출될 위험이 있다.

한정된 시험에서만 위 로그인 명령에 `--insecure`, 아래 이미지 검사 명령에도 `--insecure`를 각각 추가한다. Raw 다운로드의 curl은 별도로 `--insecure`가 필요하다. 이 예외를 Docker의 전역 설정이나 서비스 재시작으로 확대하지 않는다.

</details>

---

## 4. 취약점 DB를 준비하고 검사 조건 기록

검사 전에 DB 다운로드를 분리하면 인증 오류와 DB 네트워크 오류를 구분하기 쉽다.

```bash
trivy --config '' --cache-dir "${SCAN_DIR}/cache" image \
  --download-db-only --timeout 15m
trivy --config '' --cache-dir "${SCAN_DIR}/cache" image \
  --download-java-db-only --timeout 15m
trivy --cache-dir "${SCAN_DIR}/cache" --version \
  > "${SCAN_DIR}/reports/trivy-version.txt"
date -Is > "${SCAN_DIR}/reports/scan-started-at.txt"
```

Java DB는 JAR 분석에 필요한 별도 식별 정보다. Java 파일을 포함할 수 있는 전체 이미지 검사를 기준으로 미리 준비한 것이다. Java를 검사 범위에서 제외한다면 그 제외 사실을 기록하고 관련 분석기를 별도로 관리한다.

이후 명령은 `--skip-db-update`와 `--skip-java-db-update`를 사용해 준비된 DB를 재사용한다. 처음부터 DB가 없는 상태에서 생략 옵션만 넣으면 안 된다. [공식 DB 관리](https://trivy.dev/docs/latest/guide/configuration/db/)

`--offline-scan`은 의존성 식별을 위한 추가 API 조회를 줄이는 옵션이다. **Nexus 이미지 다운로드까지 막거나 모든 네트워크 통신을 차단하는 옵션은 아니다.** 검사 옵션과 DB 준비 시점을 기록해야 결과를 비교할 수 있다.

---

## 5. 컨테이너 이미지 한 개부터 검사

<p class="subsection-title"><strong>5-1. 게시된 digest 확인</strong></p>

<div class="section-body" markdown="1">

Tag는 사람이 사용하는 이름이다. 같은 이름의 내용이 바뀔 수 있으므로 검사 기록에는 내용 식별 값인 digest도 남긴다.

아래는 Nexus에서 사용하는 경로 기반 Docker 저장소의 예다. `IMAGE_NAME`과 `IMAGE_TAG`를 실제 대상으로 바꾼다.

```bash
IMAGE_NAME=ansible/openstack-ansible
IMAGE_TAG=v1.6
curl --fail --silent --show-error --head \
  --connect-timeout 10 --max-time 60 \
  --cacert "${NEXUS_CA}" --user "${NEXUS_USER}" \
  -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json' \
  "${NEXUS_URL}/v2/docker-hosted/${IMAGE_NAME}/manifests/${IMAGE_TAG}" \
  > "${SCAN_DIR}/reports/image-headers.txt"
IMAGE_DIGEST="$(awk 'tolower($1)=="docker-content-digest:" {gsub("\r", "", $2); print $2; exit}' \
  "${SCAN_DIR}/reports/image-headers.txt")"
printf '%s\n' "${IMAGE_DIGEST}"
```

HTTP 오류가 없고 `sha256:` 뒤에 64자리 16진수가 나오는지 확인한다. 릴리스 manifest에 digest가 이미 있다면 그 값과도 대조한다. 전용 Docker connector나 reverse proxy를 사용한다면 API·이미지 경로를 실제 라우팅에 맞춘다.

```bash
export IMAGE_REF="${REGISTRY}/docker-hosted/${IMAGE_NAME}@${IMAGE_DIGEST}"
printf '%s\n' "${IMAGE_REF}" > "${SCAN_DIR}/reports/image-ref.txt"
```

</div>

<p class="subsection-title"><strong>5-2. 운영 런타임을 거치지 않고 원격 이미지 검사</strong></p>

<div class="section-body" markdown="1">

`--image-src remote`를 명시하면 Docker·containerd의 로컬 캐시 대신 레지스트리를 직접 사용한다. 검사 대상 컨테이너를 띄우지 않는다. [공식 이미지 소스 설명](https://trivy.dev/docs/latest/guide/target/container_image/#supported)

```bash
trivy --config '' --cache-dir "${SCAN_DIR}/cache" \
  --cacert "${NEXUS_CA}" image \
  --image-src remote --platform linux/amd64 \
  --scanners vuln --parallel 1 --timeout 20m \
  --skip-db-update --skip-java-db-update --offline-scan \
  --ignorefile '' --list-all-pkgs \
  --format json --output "${SCAN_DIR}/reports/image.json" \
  "${IMAGE_REF}" \
  2> "${SCAN_DIR}/reports/image.log"
```

- `--scanners vuln`: 취약점 검사만 수행.
- `--platform linux/amd64`: 다중 아키텍처 이미지에서 이번 검사 플랫폼 고정.
- `--ignorefile ''`: 작업 위치의 기존 ignore 파일이 조용히 적용되는 것을 방지.
- `--list-all-pkgs`: 취약점이 없는 것으로 나온 식별 패키지도 JSON에 남김.
- `--timeout`: 개별 검사 제한. 초과는 검사 실패이지 취약점 미검출이 아님.

실행 직후 종료 코드를 확인하고 JSON이 정상인지 검사한다.

```bash
printf '검사 종료 코드: %s\n' "$?"
jq -e '.SchemaVersion and (.ArtifactName | type == "string")' \
  "${SCAN_DIR}/reports/image.json"
tail -n 30 "${SCAN_DIR}/reports/image.log"
```

기본 취약점 검사에서 성공 종료는 보통 “검사를 수행했다”는 의미다. 취약점 0개나 배포 승인이라는 뜻으로 읽지 않는다. 결과에서 사용된 OS·분석기·경고도 확인한다.

</div>

---

## 6. Raw 파일은 해시 확인 후 필요한 형태로 검사

<p class="subsection-title"><strong>6-1. 원본 내려받기와 SHA256 확인</strong></p>

<div class="section-body" markdown="1">

예시는 containerd 압축파일이다. 버전은 검사 방법을 설명하기 위한 대상으로, 설치 권장 버전이 아니다. `RAW_PATH`와 SHA256은 실제 배포 manifest·관리 중인 기준값에서 가져온다.

```bash
RAW_PATH=ansible-runtime/containerd-2.1.5-linux-amd64.tar.gz
read -r -p 'manifest에 기록된 Raw SHA256: ' RAW_SHA256
export RAW_FILE="${SCAN_DIR}/raw/${RAW_PATH##*/}"
curl --fail --show-error --location \
  --connect-timeout 10 --max-time 600 --retry 3 \
  --cacert "${NEXUS_CA}" --user "${NEXUS_USER}" \
  "${NEXUS_URL}/repository/raw-hosted/${RAW_PATH}" \
  -o "${RAW_FILE}"
printf '%s  %s\n' "${RAW_SHA256}" "${RAW_FILE}" | sha256sum -c -
```

해시가 다르거나 다운로드가 실패하면 검사 대상으로 사용하지 않는다. 같은 URL에서 받은 파일과 체크섬이 함께 바뀌었을 가능성까지 SHA256 하나로 해결되는 것은 아니다. 기준 manifest의 출처도 신뢰할 수 있어야 한다.

</div>

<p class="subsection-title"><strong>6-2. 압축을 풀되 프로그램은 실행하지 않기</strong></p>

<div class="section-body" markdown="1">

아래는 Python 3.12 이상의 TAR 필터를 사용한다. 관리자 권한 없이 새 디렉터리에만 압축을 푼다.

```bash
export RAW_UNPACK="${SCAN_DIR}/unpacked/containerd"
mkdir -p "${RAW_UNPACK}"
python3 -m tarfile --extract "${RAW_FILE}" "${RAW_UNPACK}" --filter=data
trivy --config '' --cache-dir "${SCAN_DIR}/cache" rootfs \
  --scanners vuln --parallel 1 --timeout 20m \
  --skip-db-update --skip-java-db-update --offline-scan \
  --ignorefile '' --list-all-pkgs \
  --format json --output "${SCAN_DIR}/reports/raw-containerd.json" \
  "${RAW_UNPACK}" \
  2> "${SCAN_DIR}/reports/raw-containerd.log"
```

프로그램 설치·실행이나 `pip install`이 아니라 파일 분석이다. 악성 파일일 가능성이 있는 재료는 분리된 검사 환경에서 다루며, 압축 해제 필터가 자원 고갈 같은 모든 위험을 막아주는 것은 아니다.

`rootfs`는 디렉터리 내부의 OS·라이브러리 분석을 위한 검사 대상이다. Go 실행파일도 내부 빌드 정보로 식별할 수 있지만, 제품 자체 버전과 모든 보조 프로그램의 탐지를 보장하지는 않는다. [Rootfs 설명](https://trivy.dev/docs/latest/guide/target/rootfs/) · [Go 바이너리 분석](https://trivy.dev/docs/latest/guide/coverage/language/golang/)

</div>

<details class="analysis-toggle" markdown="1">
<summary>6-3. 단일 바이너리·Wheel·소스 TAR는 어떻게 다른가?</summary>

| Raw 형태 | 처리 | 결과에서 확인할 것 |
| --- | --- | --- |
| 단일 Go 실행파일 | 전용 디렉터리에 두고 rootfs 검사 | Go·모듈 이름과 버전이 식별됐는지 |
| Wheel | ZIP 형식으로 별도 디렉터리에 해제한 뒤 검사 | dist-info의 이름·버전 인식 여부 |
| 소스 TAR | 별도 디렉터리에 해제한 뒤 fs 또는 rootfs 검사 | 지원되는 의존성 명세·패키지 정보가 있는지 |
| QCOW2·IMG | 이번 Raw 디렉터리 검사에서 제외 | 게스트 내부 검사 절차를 별도 준비 |

Wheel을 풀 때는 `RAW_FILE`과 출력 디렉터리를 해당 대상으로 바꾼다.

```bash
python3 -m zipfile -e "${RAW_FILE}" "${SCAN_DIR}/unpacked/wheel"
```

Wheel의 의존성 이름이 적혀 있어도 실제 설치될 모든 전이 의존성의 버전을 확정할 수는 없다. 전이 의존성은 라이브러리가 다시 의존하는 다른 라이브러리다. 소스 TAR에 의존성 파일이 없거나 버전이 고정되지 않았다면 그 사실을 추가 확인 항목으로 남긴다.

단일 파일·명세 검사에는 `trivy fs`도 사용할 수 있다. 분석 대상에 맞는 차이는 [파일시스템 검사](https://trivy.dev/docs/latest/guide/target/filesystem/)와 [Python 지원 범위](https://trivy.dev/docs/latest/guide/coverage/language/python/)에서 확인한다.

</details>

---

## 7. 한 개에서 배포 재료 목록으로 범위 넓히기

**릴리스 manifest 한 개를 검사하는 것과 Nexus 전체를 검사하는 것은 다르다.** 한 릴리스의 manifest는 그 버전에서 사용하는 재료만 포함한다. 저장소 전체 점검이라면 다른 릴리스와 manifest에 없는 등록본도 목록에 포함해야 한다.

<p class="subsection-title"><strong>7-1. manifest에서 이름·해시 목록 만들기</strong></p>

<div class="section-body" markdown="1">

다음 선택 절차는 앞선 Gitea 경량화 구성의 `release/manifest.yaml` 형식에 맞춘 것이다. 제품 저장소의 루트 디렉터리에서 실행한다. 기존 파일은 수정하지 않는다.

YAML 파싱 도구는 별도 가상환경에 둔다.

```bash
python3 -m venv "${SCAN_DIR}/manifest-tools"
"${SCAN_DIR}/manifest-tools/bin/python" -m pip install 'PyYAML==6.0.3'
```

manifest의 `images: name/tag/digest`, `artifacts: path/sha256`을 각각 목록으로 만든다. VM 디스크 파일은 별도 목록으로 분리한다.

```bash
"${SCAN_DIR}/manifest-tools/bin/python" - <<'PY'
import os
import re
from pathlib import Path, PurePosixPath
import yaml

out = Path(os.environ["SCAN_DIR"])
registry = os.environ["REGISTRY"]
data = yaml.safe_load(Path("release/manifest.yaml").read_text())
images, raw, vm = [], [], []
for image in data["images"]:
    digest = image["digest"]
    assert re.fullmatch(r"sha256:[0-9a-f]{64}", digest), digest
    images.append(f'{registry}/docker-hosted/{image["name"]}@{digest}')
for artifact in data["artifacts"]:
    path, sha = artifact["path"], artifact["sha256"]
    assert re.fullmatch(r"[0-9a-f]{64}", sha), path
    assert not PurePosixPath(path).is_absolute() and ".." not in PurePosixPath(path).parts
    assert not any(c in path for c in "\t\r\n"), path
    row = f"{path}\t{sha}"
    (vm if path.endswith((".qcow2", ".img")) else raw).append(row)
for name, rows in [("images.txt", images), ("raw.tsv", raw), ("vm-images.tsv", vm)]:
    (out / name).write_text("".join(row + "\n" for row in rows))
print(f"Images={len(images)}, Raw={len(raw)}, VM disks={len(vm)}")
PY
```

출력되는 숫자는 검사 대상 목록의 개수이지 검사 성공 건수가 아니다. manifest 구조가 다르면 키를 맞추고, 생성한 목록도 확인한다.

</div>

<p class="subsection-title"><strong>7-2. 이미지 목록을 순서대로 검사</strong></p>

<div class="section-body" markdown="1">

아래는 한 개씩 검사하고 실패를 기록한 뒤 다음 대상으로 진행하는 명령이다. 마지막에 실패가 하나라도 있으면 전체를 비정상 종료한다. 이전 결과와 섞이지 않도록 실행마다 새로 만든 `SCAN_DIR`를 사용한다.

```bash
(
  set -euo pipefail
  failed=0
  n=0
  printf 'number\tstatus\timage\n' > "${SCAN_DIR}/reports/image-status.tsv"
  while IFS= read -r image || [[ -n "${image}" ]]; do
    [[ -n "${image}" ]] || continue
    n=$((n + 1))
    base="${SCAN_DIR}/reports/image-${n}"
    if trivy --config '' --cache-dir "${SCAN_DIR}/cache" \
      --cacert "${NEXUS_CA}" image \
      --image-src remote --platform linux/amd64 \
      --scanners vuln --parallel 1 --timeout 20m \
      --skip-db-update --skip-java-db-update --offline-scan \
      --ignorefile '' --list-all-pkgs --format json \
      --output "${base}.json" "${image}" 2> "${base}.log" \
      && jq -e '.SchemaVersion and .ArtifactName' "${base}.json" >/dev/null; then
      status=completed
    else
      status=failed
      failed=$((failed + 1))
    fi
    printf '%s\t%s\t%s\n' "${n}" "${status}" "${image}" \
      >> "${SCAN_DIR}/reports/image-status.tsv"
  done < "${SCAN_DIR}/images.txt"
  [[ "${n}" -gt 0 && "${failed}" -eq 0 ]]
)
```

`completed`는 취약점이 없다는 뜻이 아니라 처리와 JSON 출력이 완료됐다는 의미다. 이미지 내부에서 식별하지 못한 프로그램은 별도로 확인한다. 빈 목록도 성공으로 처리하지 않는다.

</div>

<details class="analysis-toggle" markdown="1">
<summary>7-3. Raw 목록 전체를 내려받으려면</summary>

`raw.tsv`에는 상대 경로와 SHA256이 탭으로 구분돼 있다. 아래 명령은 원본을 경로별로 보관하고 해시가 다르면 중단한다. `--user`는 각 다운로드에서 비밀번호를 물을 수 있다. 반복 작업에는 별도 승인된 자격정보 관리 방식을 사용하고, 비밀번호를 명령 인자에 직접 넣지 않는다.

```bash
(
  set -euo pipefail
  while IFS=$'\t' read -r path sha; do
    file="${SCAN_DIR}/raw/${path}"
    mkdir -p "$(dirname "${file}")"
    curl --fail --show-error --location \
      --connect-timeout 10 --max-time 600 --retry 3 \
      --cacert "${NEXUS_CA}" --user "${NEXUS_USER}" \
      "${NEXUS_URL}/repository/raw-hosted/${path}" -o "${file}"
    printf '%s  %s\n' "${sha}" "${file}" | sha256sum -c -
  done < "${SCAN_DIR}/raw.tsv"
)
```

그다음 6절 방식으로 원본별 압축을 별도 하위 디렉터리에 푼다. 제품별 경로를 유지하면 내장 바이너리에서 나온 결과가 어느 재료에 속하는지 추적하기 쉽다.

전체 디렉터리 한 번 검사는 다음처럼 실행한다.

```bash
trivy --config '' --cache-dir "${SCAN_DIR}/cache" rootfs \
  --scanners vuln --parallel 1 --timeout 60m \
  --skip-db-update --skip-java-db-update --offline-scan \
  --ignorefile '' --list-all-pkgs \
  --format json --output "${SCAN_DIR}/reports/raw-all.json" \
  "${SCAN_DIR}/unpacked" \
  2> "${SCAN_DIR}/reports/raw-all.log"
```

검사 디렉터리를 만든 것만으로 모든 압축파일을 검사한 것은 아니다. `raw.tsv`의 원본별로 **다운로드·해시 확인·해제·식별·검사 결과**를 대응시킨다. 소스 메타데이터가 없거나 분석기가 인식하지 못한 재료는 수동 권고 검토 대상으로 남긴다.

</details>

---

## 8. JSON에서 읽어야 할 것

전체 JSON을 한 번에 읽기보다 출처와 대상을 유지하면서 표로 정리한다. 아래 예시는 이미지 한 개의 결과 파일을 읽는다. 묶음 검사 결과라면 해당 JSON 경로로 바꾼다.

<p class="subsection-title"><strong>8-1. 식별한 패키지 수와 대상</strong></p>

<div class="section-body" markdown="1">

```bash
jq -r '.Results[]? |
  [.Target, .Class, .Type,
   ((.Packages // []) | length),
   ((.Vulnerabilities // []) | length)] | @tsv' \
  "${SCAN_DIR}/reports/image.json"
```

출력 열은 Target·Class·Type·패키지 수·취약점 항목 수다. Results가 비었거나 기대한 프로그램이 없으면 “0개이므로 안전”이 아니라 식별 범위를 확인한다. 같은 CVE가 여러 패키지·파일에 나오면 행 수가 늘어날 수 있다.

</div>

<p class="subsection-title"><strong>8-2. 패키지·현재 버전·수정 버전·근거 링크</strong></p>

<div class="section-body" markdown="1">

```bash
jq -r '.Results[]? as $r |
  $r.Vulnerabilities[]? |
  [$r.Target, .PkgName, .InstalledVersion, .VulnerabilityID,
   .Severity, (.FixedVersion // ""),
   (.SeveritySource // ""), (.PrimaryURL // "")] | @tsv' \
  "${SCAN_DIR}/reports/image.json" \
  > "${SCAN_DIR}/reports/image-findings.tsv"
```

| 필드 | 해석 |
| --- | --- |
| Target | 어떤 이미지 내부 파일·패키지 묶음에서 나왔는지 |
| PkgName·InstalledVersion | 식별한 패키지와 현재 버전 |
| VulnerabilityID | CVE·GHSA 등 취약점 식별자 |
| Severity·SeveritySource | 심각도와 그 평가 출처 |
| FixedVersion | 해당 권고의 수정 기준. 제품 전체의 최종 권장 버전과는 다름 |
| PrimaryURL·References | 상세 권고를 확인할 출발점 |
| DataSource | 취약점 판정 정보의 출처 |

`FixedVersion`이 비어 있어도 무시하지 않는다. 미수정·수정 정보 부재 등을 확인하고, 첫 검사에서는 `--ignore-unfixed`로 이런 항목을 숨기지 않는다. [공식 필터 설명](https://trivy.dev/docs/latest/guide/configuration/filtering/)

</div>

<p class="subsection-title"><strong>8-3. 원본은 전체, 우선 검토 표는 High·Critical</strong></p>

<div class="section-body" markdown="1">

```bash
jq -r '.Results[]? as $r |
  $r.Vulnerabilities[]? |
  select(.Severity == "HIGH" or .Severity == "CRITICAL") |
  [$r.Target, .PkgName, .InstalledVersion, .VulnerabilityID,
   .Severity, (.FixedVersion // ""), (.PrimaryURL // "")] | @tsv' \
  "${SCAN_DIR}/reports/image.json"
```

이 명령은 표시를 줄이는 것이지 Medium 이하를 안전하다고 승인하는 기준이 아니다. JSON 원본은 그대로 보관한다. 취약점 고유 식별자 수는 별도로 계산한다.

```bash
jq '[.Results[]?.Vulnerabilities[]?.VulnerabilityID] | unique | length' \
  "${SCAN_DIR}/reports/image.json"
```

이 값도 영향받는 이미지 개수와 같지 않다. 여러 결과를 합칠 때는 이미지·패키지·현재 버전과 CVE의 대응 관계를 지우지 않는다.

</div>

---

## 9. 실패·오탐·미검출을 구분하기

| 증상 | 확인할 부분 |
| --- | --- |
| 401·403 | ID·비밀번호, 저장소 read·browse 권한, Docker Bearer Token Realm·토큰 경로 |
| 429 | DB 레지스트리 제한 또는 Nexus 인증 시도 제한 등 어느 서버의 응답인지 |
| x509 오류 | CA 신뢰·SAN·접속 주소·유효기간 |
| timeout·no route to host | 검사 서버에서 Nexus·DB 배포 경로로 가는 네트워크 |
| no space left on device | TMPDIR·캐시 파일시스템·inode, 동시 처리 수 |
| 같은 버전인데 다른 결과 | 이미지 digest·플랫폼·DB 시점·옵션·검사기 버전 |
| 취약점은 있는데 사용하지 않는 기능 | 공식 권고의 조건과 실제 설정 검토 |
| 패키지가 하나도 식별되지 않음 | 지원 형식·압축 해제 여부·메타데이터. 안전 판정 금지 |

보안 수정의 백포트가 있으면 upstream 버전 숫자만으로 판단하지 않는다. JSON의 출처와 배포판 패키지 revision을 확인한 뒤 공식 권고·사내 patch를 대조한다.

예외로 제외할 때는 식별자만 ignore 목록에 추가하지 말고 대상 해시·사유·근거·검토일·재검토 조건을 함께 남긴다. 이번 기본 명령은 자동 예외 처리를 하지 않는다.

---

## 10. 조치와 재검사까지 연결

검출 이후에는 다음 항목으로 정리하면 된다.

| 대상 | 식별 버전·해시 | CVE | 사용 조건·판정 | 공식 근거 | 조치·재검사 |
| --- | --- | --- | --- | --- | --- |
| 이미지·Raw 상대 경로 | 현재 버전과 digest·SHA256 | 결과의 실제 식별자 | 영향·조건부·비해당·추가 확인 | 공급사 권고·배포판 수정 정보 | 교체 버전·시험·결과 |

표의 행은 실제 결과로 채운다. 스캐너가 제시한 수정 버전만 보고 곧바로 운영 프로그램을 교체하지 않는다. 지원 계열, 후속 CVE, Ansible 설정, 데이터 형식과 업그레이드 절차까지 확인한다.

배포 재료를 바꾼 뒤에는 다음 순서로 이어간다.

<figure class="flow" aria-label="취약 배포 재료의 조치 순서">
  <ol>
    <li>새 버전·해시 등록</li>
    <li>manifest·참조 갱신</li>
    <li>배포 시험·재검사</li>
    <li>새 릴리스 발행</li>
  </ol>
</figure>

새 재료를 등록해도 이미 만들어진 TAR나 고객사에 설치된 프로그램이 자동으로 바뀌지는 않는다. 과거 배포물에 대한 영향 범위도 따로 관리한다.

검사 종료 시 기록을 마무리한다.

```bash
date -Is > "${SCAN_DIR}/reports/scan-finished-at.txt"
trivy --cache-dir "${SCAN_DIR}/cache" --version \
  > "${SCAN_DIR}/reports/trivy-version-at-finish.txt"
du -sh "${SCAN_DIR}/cache" "${SCAN_DIR}/tmp" "${SCAN_DIR}/reports"
trivy --config '' registry logout "${REGISTRY}"
```

보관 대상은 manifest·대상 목록·해시, 도구·DB 정보, 옵션, 성공·실패 기록, 로그·JSON 원본과 검토표다. `auth`의 로그인 정보는 결과 묶음·공유 디렉터리에 포함하지 않는다. 캐시나 해제본을 정리하더라도 Nexus 원본·운영 런타임의 이미지를 삭제하는 명령과 섞지 않는다.

공식 참고:

- [Trivy 0.76.1 배포본](https://github.com/aquasecurity/trivy/releases/tag/v0.76.1)
- [설치](https://trivy.dev/docs/latest/getting-started/installation/) · [서명 검증](https://trivy.dev/docs/latest/getting-started/signature-verification/)
- [사설 레지스트리 인증](https://trivy.dev/docs/latest/advanced/private-registries/)
- [이미지 검사](https://trivy.dev/docs/latest/guide/target/container_image/) · [Rootfs 검사](https://trivy.dev/docs/latest/guide/target/rootfs/)
- [결과 출력](https://trivy.dev/docs/latest/guide/configuration/reporting/) · [DB 관리](https://trivy.dev/docs/latest/guide/configuration/db/)
- [오류 구분](https://trivy.dev/docs/latest/guide/references/troubleshooting/)
