---
title: "사내 Gitea 경량화 (10·마무리) — 물리서버에 릴리스 자동화 환경 완성하기"
summary: "새 Ubuntu 물리서버에 Gitea·Nexus·host Runner·HAProxy를 구성하고, Tag 패키징부터 VMware·OpenStack 시험과 고객사 반입까지 연결하는 통합 구축 가이드다. 전체 설정·스크립트와 다운로드 묶음을 함께 제공한다."
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
      <span class="editorial-summary-label">사내 Gitea 경량화 · 물리서버 통합 구축 편</span>
      <h2 id="editorial-summary-title" class="editorial-summary-title">서비스를 띄우는 데서 끝내지 않고, Tag 하나가 배포물로 이어지게 만든다.</h2>
      <p>앞선 글에서 나눠 설명한 설정을 한 서버에 연결한다. 설치 순서, 계정·권한, 모든 실행 파일, 시험 환경과 최종 다운로드를 순서대로 구성한다. 긴 파일은 본문의 펼침 영역과 동일한 다운로드 묶음에 담았다.</p>
    </div>
  </div>
  <p class="editorial-summary-result"><span><strong>런타임 → 서비스 → 재료·코드 → Runner·빌더 → 시험 → 릴리스</strong>. 사내 자동화 서버와 고객사에 반입할 TAR는 별개의 구성이다.</span></p>
</section>

## 1. 완성할 환경과 먼저 준비할 것

기준은 **새 Ubuntu 24.04 LTS x86_64 물리서버 한 대**다. 기존 운영 서버에 아래 디렉터리나 설정을 덮어쓰는 절차가 아니다. 서비스·데이터를 그대로 옮기는 작업이라면 DB와 Blob을 함께 복구하는 방식을 사용한다.

```text title="한 물리서버에 구성할 서비스"
Git 사용자 ── Gitea + PostgreSQL
                    │ Tag 작업 수신
                    ▼
              Gitea Runner (systemd, host, 동시 작업 1개)
                    ├── 빌더 + Raw 캐시 + containerd 이미지 캐시
                    ├── Nexus: 재료·staging·최종 TAR
                    └── OpenTofu → vCenter → VMware 시험 VM 4대

사업수행팀 ── HAProxy channel URL ── 302 ── Nexus의 실제 버전 TAR
```

| 항목 | 이 가이드의 기준 |
| --- | --- |
| Gitea / DB | Gitea 1.25.4, PostgreSQL 14 이미지 |
| Nexus | 3.96.1, 내장 H2, 파일 Blob Store 하나 |
| Runner | 4.0.0, host 실행, label `contrabass-engine-release` |
| 런타임 | nerdctl Full 2.2.2로 신규 설치 |
| VMware 시험 | 기존 Rocky 9.6 템플릿, 단일 ESXi, VM 4대 |
| provider | VMware 2.17.1 / OpenStack 1.53.0 |
| 최종 TAR 보관 | 릴리스 계열별 최신 3개 |

버전은 기존 파이프라인을 재현하는 기준이다. 최신 보안 패치 버전이라는 의미는 아니다. 이미지·바이너리를 업그레이드할 때는 설치 시험과 manifest 변경을 함께 수행한다.

필수 준비물은 다음과 같다.

- root 권한과 고정 서비스 주소. 예시의 `192.0.2.10`은 실제 사내 주소로 교체한다.
- 서비스 데이터, Raw 캐시, 이미지 export와 최종 TAR를 동시에 둘 디스크.
- vCenter API 접근, 복제할 템플릿과 시험용 예약 IP·Port group.
- **검증된 기존 `contrabass-engine-deploy.tar`와 그 체크섬.** 여기서 제품 코드와 최초 설치 재료를 가져온다.
- 시험 VM이 접근할 OS 패키지 저장소. 제품 Ansible의 `package_ip`도 맞춰야 한다.

사내 프로그램·Ansible 전체 소스·QCOW2·이미지 본문은 공개 설정 묶음에 들어 있지 않다. 이미 검증한 배포 TAR를 초기 재료로 쓰므로, 새 Nexus가 비어 있어도 파일을 하나씩 다시 찾을 필요는 없다.

---

## 2. 전체 설정 받기와 주소·경로 확정

[전체 구성 파일 받기](../assets/gitea-lightweight-10/release-platform-config.tar.gz) · [구성 묶음 체크섬](../assets/gitea-lightweight-10/release-platform-config.tar.gz.sha256)

이것은 **서비스 구축용 설정 묶음**이며 사업수행팀이 가져갈 제품 TAR가 아니다. 먼저 root 셸에서 기본 도구를 설치한다. 이후 명령도 별도 표시가 없으면 새 물리서버의 root 셸에서 실행한다.

```bash title="기본 도구와 구축 설정 다운로드"
apt-get update
apt-get install -y ca-certificates curl git jq openssl util-linux iptables \
  sudo socat haproxy unzip rsync restic gnupg iproute2
install -d -m 0700 /root/release-platform-setup
cd /root/release-platform-setup
base=https://wjdxotjd112.github.io/tech-notes/assets/gitea-lightweight-10
curl -fLO "${base}/release-platform-config.tar.gz"
curl -fLO "${base}/release-platform-config.tar.gz.sha256"
sha256sum -c release-platform-config.tar.gz.sha256
tar -xzf release-platform-config.tar.gz
export CONFIG_SRC=/root/release-platform-setup/release-platform-config
```

```text title="압축 안의 파일 배치"
release-platform-config/
├── host/             물리서버의 같은 절대 경로에 설치할 파일
│   ├── etc/          통합 환경·Runner·systemd·HAProxy·sudoers
│   ├── root/compose/ Gitea·Nexus Compose
│   ├── opt/gitea/    빌더와 고객사 기동 템플릿
│   ├── usr/local/   제한된 root wrapper와 백업 명령
│   └── var/lib/     VMware·OpenStack 시험 프로젝트
└── repository/       제품 Git에 반영할 Workflow·gitignore·manifest 예시
```

**host 전체를 `/`에 한 번에 덮어쓰지 않는다.** 아래 순서대로 파일을 설치한다. 새 셸을 열었다면 `CONFIG_SRC`를 다시 지정하고 `/etc/gitea-runner-env/bundle-pipeline.env`를 읽는다. 6절 이후에는 `SEED_DIR=/root/release-seed/contrabass-engine-deploy`도 다시 지정한다.

먼저 Runner 계정과 환경설정 경로를 만든다. `nologin` 계정도 systemd와 `sudo -u`로 명령을 실행할 수 있다.

```bash title="Runner 사용자와 통합 설정 설치"
useradd --system --user-group --home-dir /var/lib/gitea-runner \
  --create-home --shell /usr/sbin/nologin gitea-runner
install -d -m 0750 -o root -g gitea-runner /etc/gitea-runner-env /etc/gitea-runner
install -m 0640 -o root -g gitea-runner \
  "${CONFIG_SRC}/host/etc/gitea-runner-env/services.env" /etc/gitea-runner-env/services.env
install -m 0640 -o root -g gitea-runner \
  "${CONFIG_SRC}/host/etc/gitea-runner-env/bundle-pipeline.env" /etc/gitea-runner-env/bundle-pipeline.env
vi /etc/gitea-runner-env/services.env
vi /etc/gitea-runner-env/bundle-pipeline.env
```

<details class="analysis-toggle" markdown="1">
<summary>/etc/gitea-runner-env/services.env — 전체 내용</summary>

<div class="highlight" data-source-path="host/etc/gitea-runner-env/services.env"><pre><code><span class="c1"># Compose와 HAProxy가 함께 읽는다. 비밀번호를 넣지 않는다.</span>
<span class="nv">SERVER_HOST</span><span class="o">=</span><span class="m">192</span>.0.2.10
<span class="nv">GITEA_HTTPS_PORT</span><span class="o">=</span><span class="m">30000</span>
<span class="nv">GITEA_SSH_PORT</span><span class="o">=</span><span class="m">222</span>
<span class="nv">NEXUS_HTTPS_PORT</span><span class="o">=</span><span class="m">55555</span>
<span class="nv">RELEASE_HTTPS_PORT</span><span class="o">=</span><span class="m">8443</span>
<span class="nv">RELEASE_MAP_FILE</span><span class="o">=</span>/etc/haproxy/bundle-channels.map
<span class="nv">RELEASE_SOCKET</span><span class="o">=</span>/run/haproxy/admin.sock
<span class="nv">TZ</span><span class="o">=</span>Asia/Seoul

<span class="nv">GITEA_IMAGE</span><span class="o">=</span>gitea/gitea:1.25.4@sha256:17d18218be2dad1f8ed402a4f906989505c90ab8b66ee9befcecfb5d470133e7
<span class="nv">POSTGRES_IMAGE</span><span class="o">=</span>postgres:14@sha256:c2427de38f998489d36de7ca3553db2134872c400f2b08be4b824e5c50e4d619
<span class="nv">NEXUS_IMAGE</span><span class="o">=</span>sonatype/nexus3:3.96.1@sha256:56142f13432cf072e017aebb2025f201e42ae36ff40bb82618c702504c61f7dd
<span class="nv">GITEA_DATA_DIR</span><span class="o">=</span>/data/gitea/gitea-data
<span class="nv">GITEA_DB_DATA_DIR</span><span class="o">=</span>/data/gitea/postgres-data
<span class="nv">GITEA_CERT_DIR</span><span class="o">=</span>/data/gitea/certs
<span class="nv">GITEA_DB_USER</span><span class="o">=</span>root
<span class="nv">GITEA_DB_NAME</span><span class="o">=</span>gitea
<span class="nv">NEXUS_DATA_DIR</span><span class="o">=</span>/data/nexus/nexus-data
<span class="nv">NEXUS_HEAP</span><span class="o">=</span>2703m
<span class="nv">NEXUS_DIRECT_MEMORY</span><span class="o">=</span>2703m

<span class="nv">MANIFEST_REPOSITORY</span><span class="o">=</span>raw-manifest
<span class="nv">BUNDLE_REPOSITORY</span><span class="o">=</span>raw-release-bundle
<span class="nv">RAW_REPOSITORY</span><span class="o">=</span>raw-hosted
<span class="nv">DOCKER_REPOSITORY</span><span class="o">=</span>docker-hosted
<span class="nv">STAGING_REPOSITORY</span><span class="o">=</span>raw-release-staging
</code></pre></div>

</details>

<details class="analysis-toggle" markdown="1">
<summary>/etc/gitea-runner-env/bundle-pipeline.env — 전체 내용</summary>

<div class="highlight" data-source-path="host/etc/gitea-runner-env/bundle-pipeline.env"><pre><code><span class="c1"># root 소유. Secrets는 Workflow에서 전달한다.</span>
<span class="nb">source</span><span class="w"> </span>/etc/gitea-runner-env/services.env
<span class="nv">NEXUS_URL</span><span class="o">=</span><span class="s2">"https://</span><span class="si">${</span><span class="nv">SERVER_HOST</span><span class="si">}</span><span class="s2">:</span><span class="si">${</span><span class="nv">NEXUS_HTTPS_PORT</span><span class="si">}</span><span class="s2">"</span>
<span class="nv">GITEA_URL</span><span class="o">=</span><span class="s2">"https://</span><span class="si">${</span><span class="nv">SERVER_HOST</span><span class="si">}</span><span class="s2">:</span><span class="si">${</span><span class="nv">GITEA_HTTPS_PORT</span><span class="si">}</span><span class="s2">"</span>
<span class="nv">GITEA_REPOSITORY</span><span class="o">=</span>platform/private-cloud-v4
<span class="nv">GITEA_REPO_URL</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">GITEA_URL</span><span class="si">}</span><span class="s2">/</span><span class="si">${</span><span class="nv">GITEA_REPOSITORY</span><span class="si">}</span><span class="s2">.git"</span>
<span class="nv">RELEASE_BRANCH</span><span class="o">=</span>master
<span class="nv">TEST_SKIP_LABEL</span><span class="o">=</span>release:skip-test
<span class="c1"># 신규 환경은 비운다. 승인 확인을 피하려고 새 Tag를 추가하지 않는다.</span>
<span class="nv">LEGACY_RELEASE_TAGS</span><span class="o">=</span><span class="s2">""</span>
<span class="nv">NEXUS_USER</span><span class="o">=</span>release-ci
<span class="nv">PUBLIC_RELEASE_URL</span><span class="o">=</span><span class="s2">"https://</span><span class="si">${</span><span class="nv">SERVER_HOST</span><span class="si">}</span><span class="s2">:</span><span class="si">${</span><span class="nv">RELEASE_HTTPS_PORT</span><span class="si">}</span><span class="s2">"</span>

<span class="nv">BUNDLE_WORK_DIR</span><span class="o">=</span>/data/private-release
<span class="nv">RAW_CACHE_DIR</span><span class="o">=</span>/data/private-release-cache/raw/sha256
<span class="nv">BUNDLE_BUILDER_DIR</span><span class="o">=</span>/opt/gitea/bundle-builder
<span class="nv">NEXUS_BASE_IMAGE</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">BUNDLE_BUILDER_DIR</span><span class="si">}</span><span class="s2">/nexus3-3.96.1-image.tar"</span>
<span class="nv">TEMPLATE_DIR</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">BUNDLE_BUILDER_DIR</span><span class="si">}</span><span class="s2">/templates"</span>
<span class="nv">RELEASE_KEEP_COUNT</span><span class="o">=</span><span class="m">3</span>

<span class="c1"># 자체 서명 재현 구성. 사내 CA 신뢰 구성 후에는 false로 바꾼다.</span>
<span class="nv">TLS_SKIP_VERIFY</span><span class="o">=</span><span class="nb">true</span>
<span class="nv">HTTP_CONNECT_TIMEOUT</span><span class="o">=</span><span class="m">10</span>
<span class="nv">HTTP_RETRY_COUNT</span><span class="o">=</span><span class="m">3</span>
<span class="nv">HAPROXY_MAP_FILE</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">RELEASE_MAP_FILE</span><span class="si">}</span><span class="s2">"</span>
<span class="nv">HAPROXY_SOCKET</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">RELEASE_SOCKET</span><span class="si">}</span><span class="s2">"</span>

<span class="nv">RUNNER_USER</span><span class="o">=</span>gitea-runner
<span class="nv">RUNNER_GROUP</span><span class="o">=</span>gitea-runner
<span class="nv">RUNNER_WORKSPACE</span><span class="o">=</span>/var/lib/gitea-runner/workspace
<span class="nv">TOFU_PROJECT_DIR</span><span class="o">=</span>/var/lib/gitea-runner/opentofu/contrabass-packaging
<span class="nv">TOFU_SSH_PRIVATE_KEY</span><span class="o">=</span>/var/lib/gitea-runner/.ssh/id_rsa
<span class="nv">TOFU_SSH_PUBLIC_KEY</span><span class="o">=</span>/var/lib/gitea-runner/.ssh/id_rsa.pub

<span class="nv">OPENSTACK_TEST_DIR</span><span class="o">=</span>/var/lib/gitea-runner/opentofu/openstack-smoke
<span class="nv">OPENSTACK_IMAGE_FILE</span><span class="o">=</span>noble-qemu-okestro2018.qcow2
<span class="nv">OPENSTACK_AUTH_URL</span><span class="o">=</span>https://192.0.2.100:15000/v3
<span class="nv">OPENSTACK_USERNAME</span><span class="o">=</span>admin
<span class="nv">OPENSTACK_PROJECT_NAME</span><span class="o">=</span>admin
<span class="nv">OPENSTACK_USER_DOMAIN_NAME</span><span class="o">=</span>Default
<span class="nv">OPENSTACK_PROJECT_DOMAIN_NAME</span><span class="o">=</span>Default
<span class="nb">export</span><span class="w"> </span><span class="nv">OS_INSECURE</span><span class="o">=</span><span class="nb">true</span>
</code></pre></div>

</details>

| 먼저 바꿀 값 | 의미 |
| --- | --- |
| SERVER_HOST | Gitea·Nexus·다운로드 공통 IP 또는 DNS |
| GITEA_REPOSITORY | 실제 소유자/저장소. 예시 `platform/private-cloud-v4` |
| NEXUS_USER | 뒤에서 생성할 CI 전용 Nexus 사용자 |
| 데이터·캐시·작업 경로 | 용량을 확보한 실제 마운트 경로 |
| OPENSTACK_AUTH_URL | 시험 OpenStack의 Keystone VIP |

`services.env`는 단순 `KEY=value` 형식으로 Compose·systemd도 읽는다. `bundle-pipeline.env`는 Bash가 앞 파일을 읽고 URL·파이프라인 경로를 구성한다. 비밀번호는 어느 파일에도 넣지 않는다.

포트는 외부 포워딩과 컨테이너 내부 포트를 구분한다. 이 예시에서 Gitea 내부는 30000, Nexus 내부는 55555다. 외부 포트만 바꾸면 Compose 매핑과 접속 URL이 이를 반영한다. 내부 포트까지 바꾸려면 대응 설정도 수정해야 한다.

---

## 3. 런타임·디렉터리·인증서 준비

기존 containerd가 없는 새 서버에서만 Full 패키지를 설치한다. 실행 중인 런타임에 덮어쓰지 않는다. Full에는 containerd·runc·CNI 등이 들어 있다. [nerdctl 배포 파일](https://github.com/containerd/nerdctl/releases/tag/v2.2.2)

```bash title="호스트 런타임 설치"
install -d /root/downloads/nerdctl
cd /root/downloads/nerdctl
curl -fLO https://github.com/containerd/nerdctl/releases/download/v2.2.2/nerdctl-full-2.2.2-linux-amd64.tar.gz
curl -fLO https://github.com/containerd/nerdctl/releases/download/v2.2.2/SHA256SUMS
grep ' nerdctl-full-2.2.2-linux-amd64.tar.gz$' SHA256SUMS | sha256sum -c -
tar -xzf nerdctl-full-2.2.2-linux-amd64.tar.gz -C /usr/local
systemctl daemon-reload
systemctl enable --now containerd
nerdctl info
```

호스트는 이미 만들어진 이미지를 pull·save하므로 BuildKit 서비스를 별도로 켤 필요가 없다. 고객사 제품 install.sh가 준비하는 실행 환경과는 구분한다.

아래는 빈 데이터 경로의 초기 설정이다. 기존 데이터에 재귀 chown을 적용하는 명령이 아니다.

```bash title="데이터와 작업 영역"
source /etc/gitea-runner-env/bundle-pipeline.env
install -d -m 0700 /root/compose /root/compose/secrets
install -d -m 0755 "${GITEA_CERT_DIR}" "${GITEA_DB_DATA_DIR}"
install -d -m 0755 -o 1000 -g 1000 "${GITEA_DATA_DIR}"
install -d -m 0755 -o 200 -g 200 "${NEXUS_DATA_DIR}" "${NEXUS_DATA_DIR}/etc"
install -d -m 0700 -o 200 -g 200 "${NEXUS_DATA_DIR}/etc/ssl"
install -d -m 0755 /opt/gitea "${BUNDLE_BUILDER_DIR}" "${RAW_CACHE_DIR}"
install -d -m 2775 -o root -g gitea-runner "${BUNDLE_WORK_DIR}"
install -d -m 0750 -o gitea-runner -g gitea-runner \
  /var/lib/gitea-runner/workspace /var/lib/gitea-runner/logs
ln -s /etc/gitea-runner-env/services.env /root/compose/.env
```

`/root/compose/.env`는 공통 설정의 링크다. Compose가 환경변수를 저장하는 것이 아니라 실행할 때 읽는다. 이후 Compose 명령은 `/root/compose`에서 실행한다.

사내 CA 인증서가 있다면 그 인증서와 개인키를 사용한다. 아래는 독립된 사내 시험망의 자체 서명 예시다. SAN에는 접속할 IP·DNS를 넣는다.

```bash title="Gitea와 HAProxy 인증서"
source /etc/gitea-runner-env/services.env
san="DNS:${SERVER_HOST},IP:127.0.0.1"
if [[ "${SERVER_HOST}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  san="IP:${SERVER_HOST},IP:127.0.0.1"
fi
openssl req -x509 -nodes -newkey rsa:3072 -days 365 \
  -keyout "${GITEA_CERT_DIR}/gitea.key" -out "${GITEA_CERT_DIR}/gitea.crt" \
  -subj "/CN=${SERVER_HOST}" -addext "subjectAltName=${san}"
chown 1000:1000 "${GITEA_CERT_DIR}/gitea.key" "${GITEA_CERT_DIR}/gitea.crt"
chmod 0600 "${GITEA_CERT_DIR}/gitea.key"
chmod 0644 "${GITEA_CERT_DIR}/gitea.crt"
cat "${GITEA_CERT_DIR}/gitea.crt" "${GITEA_CERT_DIR}/gitea.key" > "${GITEA_CERT_DIR}/gitea.pem"
chmod 0600 "${GITEA_CERT_DIR}/gitea.pem"
```

자체 서명용 `TLS_SKIP_VERIFY=true`, Runner의 `insecure: true`, `OS_INSECURE=true`는 대상이 서로 다르다. 사내 CA를 신뢰하도록 준비한 뒤에는 클라이언트별 인증서 검증을 켠다. 검증 생략을 외부 공개 서비스의 기본 보안 설정으로 사용하지 않는다.

---

## 4. Gitea와 PostgreSQL 기동

Compose가 환경변수에서 DB·HTTPS·등록 제한 등을 Gitea 설정으로 반영한다. 생성된 app.ini는 `${GITEA_DATA_DIR}/gitea/conf/app.ini`에 남는다. **기존 서버의 암호화 키가 들어 있는 app.ini를 복사할 필요는 없다.** [Gitea Docker 환경설정](https://docs.gitea.com/1.25/installation/install-with-docker/)

<details class="analysis-toggle" markdown="1">
<summary>/root/compose/gitea-compose.yaml — 전체 내용</summary>

<div class="highlight" data-source-path="host/root/compose/gitea-compose.yaml"><pre><code><span class="nt">services</span><span class="p">:</span>
<span class="w">  </span><span class="nt">db</span><span class="p">:</span>
<span class="w">    </span><span class="nt">image</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">${POSTGRES_IMAGE:?Set POSTGRES_IMAGE in .env}</span>
<span class="w">    </span><span class="nt">container_name</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">gitea-db</span>
<span class="w">    </span><span class="nt">restart</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">unless-stopped</span>
<span class="w">    </span><span class="nt">environment</span><span class="p">:</span>
<span class="w">      </span><span class="nt">POSTGRES_USER</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">${GITEA_DB_USER}</span>
<span class="w">      </span><span class="nt">POSTGRES_DB</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">${GITEA_DB_NAME}</span>
<span class="w">      </span><span class="nt">POSTGRES_PASSWORD_FILE</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">/run/secrets/gitea-db-password</span>
<span class="w">      </span><span class="nt">TZ</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">${TZ}</span>
<span class="w">    </span><span class="nt">volumes</span><span class="p">:</span>
<span class="w">      </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">${GITEA_DB_DATA_DIR}:/var/lib/postgresql/data</span>
<span class="w">      </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">./secrets/gitea-db-password:/run/secrets/gitea-db-password:ro</span>
<span class="w">    </span><span class="nt">logging</span><span class="p">:</span>
<span class="w">      </span><span class="nt">driver</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">json-file</span>
<span class="w">      </span><span class="nt">options</span><span class="p">:</span><span class="w"> </span><span class="p p-Indicator">{</span><span class="nt">max-size</span><span class="p">:</span><span class="w"> </span><span class="s">"20m"</span><span class="p p-Indicator">,</span><span class="nt"> max-file</span><span class="p">:</span><span class="w"> </span><span class="s">"5"</span><span class="p p-Indicator">}</span>
<span class="w">    </span><span class="nt">networks</span><span class="p">:</span><span class="w"> </span><span class="p p-Indicator">[</span><span class="nv">gitea-net</span><span class="p p-Indicator">]</span>

<span class="w">  </span><span class="nt">gitea</span><span class="p">:</span>
<span class="w">    </span><span class="nt">image</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">${GITEA_IMAGE:?Set GITEA_IMAGE in .env}</span>
<span class="w">    </span><span class="nt">container_name</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">gitea</span>
<span class="w">    </span><span class="nt">restart</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">unless-stopped</span>
<span class="w">    </span><span class="nt">depends_on</span><span class="p">:</span><span class="w"> </span><span class="p p-Indicator">[</span><span class="nv">db</span><span class="p p-Indicator">]</span>
<span class="w">    </span><span class="nt">environment</span><span class="p">:</span>
<span class="w">      </span><span class="nt">USER_UID</span><span class="p">:</span><span class="w"> </span><span class="s">"1000"</span>
<span class="w">      </span><span class="nt">USER_GID</span><span class="p">:</span><span class="w"> </span><span class="s">"1000"</span>
<span class="w">      </span><span class="nt">TZ</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">${TZ}</span>
<span class="w">      </span><span class="nt">GITEA__database__DB_TYPE</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">postgres</span>
<span class="w">      </span><span class="nt">GITEA__database__HOST</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">db:5432</span>
<span class="w">      </span><span class="nt">GITEA__database__NAME</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">${GITEA_DB_NAME}</span>
<span class="w">      </span><span class="nt">GITEA__database__USER</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">${GITEA_DB_USER}</span>
<span class="w">      </span><span class="nt">GITEA__database__PASSWD__FILE</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">/run/secrets/gitea-db-password</span>
<span class="w">      </span><span class="nt">GITEA__server__PROTOCOL</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">https</span>
<span class="w">      </span><span class="nt">GITEA__server__DOMAIN</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">${SERVER_HOST}</span>
<span class="w">      </span><span class="nt">GITEA__server__ROOT_URL</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">https://${SERVER_HOST}:${GITEA_HTTPS_PORT}/</span>
<span class="w">      </span><span class="nt">GITEA__server__HTTP_ADDR</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">0.0.0.0</span>
<span class="w">      </span><span class="nt">GITEA__server__HTTP_PORT</span><span class="p">:</span><span class="w"> </span><span class="s">"30000"</span>
<span class="w">      </span><span class="nt">GITEA__server__SSH_DOMAIN</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">${SERVER_HOST}</span>
<span class="w">      </span><span class="nt">GITEA__server__SSH_PORT</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">${GITEA_SSH_PORT}</span>
<span class="w">      </span><span class="nt">GITEA__server__CERT_FILE</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">/opt/certs/gitea.crt</span>
<span class="w">      </span><span class="nt">GITEA__server__KEY_FILE</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">/opt/certs/gitea.key</span>
<span class="w">      </span><span class="nt">GITEA__server__OFFLINE_MODE</span><span class="p">:</span><span class="w"> </span><span class="s">"true"</span>
<span class="w">      </span><span class="nt">GITEA__actions__ENABLED</span><span class="p">:</span><span class="w"> </span><span class="s">"true"</span>
<span class="w">      </span><span class="nt">GITEA__service__DISABLE_REGISTRATION</span><span class="p">:</span><span class="w"> </span><span class="s">"true"</span>
<span class="w">      </span><span class="nt">GITEA__service__REQUIRE_SIGNIN_VIEW</span><span class="p">:</span><span class="w"> </span><span class="s">"true"</span>
<span class="w">      </span><span class="nt">GITEA__service__DEFAULT_KEEP_EMAIL_PRIVATE</span><span class="p">:</span><span class="w"> </span><span class="s">"true"</span>
<span class="w">      </span><span class="nt">GITEA__service__DEFAULT_ALLOW_CREATE_ORGANIZATION</span><span class="p">:</span><span class="w"> </span><span class="s">"false"</span>
<span class="w">      </span><span class="nt">GITEA__openid__ENABLE_OPENID_SIGNIN</span><span class="p">:</span><span class="w"> </span><span class="s">"false"</span>
<span class="w">      </span><span class="nt">GITEA__openid__ENABLE_OPENID_SIGNUP</span><span class="p">:</span><span class="w"> </span><span class="s">"false"</span>
<span class="w">      </span><span class="nt">GITEA__session__COOKIE_SECURE</span><span class="p">:</span><span class="w"> </span><span class="s">"true"</span>
<span class="w">      </span><span class="nt">GITEA__session__SAME_SITE</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">lax</span>
<span class="w">      </span><span class="nt">GITEA__security__REVERSE_PROXY_TRUSTED_PROXIES</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">127.0.0.0/8,::1/128</span>
<span class="w">      </span><span class="nt">GITEA__security__DISABLE_GIT_HOOKS</span><span class="p">:</span><span class="w"> </span><span class="s">"true"</span>
<span class="w">    </span><span class="nt">volumes</span><span class="p">:</span>
<span class="w">      </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">${GITEA_DATA_DIR}:/data</span>
<span class="w">      </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">${GITEA_CERT_DIR}:/opt/certs:ro</span>
<span class="w">      </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">./secrets/gitea-db-password:/run/secrets/gitea-db-password:ro</span>
<span class="w">    </span><span class="nt">ports</span><span class="p">:</span>
<span class="w">      </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="s">"${GITEA_HTTPS_PORT}:30000"</span>
<span class="w">      </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="s">"${GITEA_SSH_PORT}:22"</span>
<span class="w">    </span><span class="nt">ulimits</span><span class="p">:</span>
<span class="w">      </span><span class="nt">nofile</span><span class="p">:</span><span class="w"> </span><span class="p p-Indicator">{</span><span class="nt">soft</span><span class="p">:</span><span class="w"> </span><span class="nv">65536</span><span class="p p-Indicator">,</span><span class="nt"> hard</span><span class="p">:</span><span class="w"> </span><span class="nv">65536</span><span class="p p-Indicator">}</span>
<span class="w">    </span><span class="nt">logging</span><span class="p">:</span>
<span class="w">      </span><span class="nt">driver</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">json-file</span>
<span class="w">      </span><span class="nt">options</span><span class="p">:</span><span class="w"> </span><span class="p p-Indicator">{</span><span class="nt">max-size</span><span class="p">:</span><span class="w"> </span><span class="s">"20m"</span><span class="p p-Indicator">,</span><span class="nt"> max-file</span><span class="p">:</span><span class="w"> </span><span class="s">"5"</span><span class="p p-Indicator">}</span>
<span class="w">    </span><span class="nt">networks</span><span class="p">:</span><span class="w"> </span><span class="p p-Indicator">[</span><span class="nv">gitea-net</span><span class="p p-Indicator">]</span>

<span class="nt">networks</span><span class="p">:</span>
<span class="w">  </span><span class="nt">gitea-net</span><span class="p">:</span>
<span class="w">    </span><span class="nt">driver</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">bridge</span>
</code></pre></div>

</details>

<details class="analysis-toggle" markdown="1">
<summary>/etc/systemd/system/gitea-stack.service — 전체 내용</summary>

<div class="highlight" data-source-path="host/etc/systemd/system/gitea-stack.service"><pre><code><span class="k">[Unit]</span>
<span class="na">Description</span><span class="o">=</span><span class="s">Gitea and PostgreSQL Compose stack</span>
<span class="na">Requires</span><span class="o">=</span><span class="s">containerd.service</span>
<span class="na">Wants</span><span class="o">=</span><span class="s">network-online.target</span>
<span class="na">After</span><span class="o">=</span><span class="s">containerd.service network-online.target</span>

<span class="k">[Service]</span>
<span class="na">Type</span><span class="o">=</span><span class="s">oneshot</span>
<span class="na">RemainAfterExit</span><span class="o">=</span><span class="s">yes</span>
<span class="na">WorkingDirectory</span><span class="o">=</span><span class="s">/root/compose</span>
<span class="na">ExecStart</span><span class="o">=</span><span class="s">/usr/local/bin/nerdctl compose -p gitea -f gitea-compose.yaml up -d</span>
<span class="na">ExecStop</span><span class="o">=</span><span class="s">/usr/local/bin/nerdctl stop -t 120 gitea</span>
<span class="na">ExecStop</span><span class="o">=</span><span class="s">/usr/local/bin/nerdctl stop -t 120 gitea-db</span>
<span class="na">TimeoutStartSec</span><span class="o">=</span><span class="s">15min</span>
<span class="na">TimeoutStopSec</span><span class="o">=</span><span class="s">5min</span>

<span class="k">[Install]</span>
<span class="na">WantedBy</span><span class="o">=</span><span class="s">multi-user.target</span>
</code></pre></div>

</details>

DB 비밀번호는 새 파일로 생성한다. 기존 파일을 덮어쓰지 않는다.

```bash title="Gitea 최초 기동"
install -m 0644 "${CONFIG_SRC}/host/root/compose/gitea-compose.yaml" /root/compose/gitea-compose.yaml
(set -o noclobber; umask 077; openssl rand -base64 36 > /root/compose/secrets/gitea-db-password)
chmod 0400 /root/compose/secrets/gitea-db-password
install -m 0644 "${CONFIG_SRC}/host/etc/systemd/system/gitea-stack.service" /etc/systemd/system/gitea-stack.service
systemctl daemon-reload
systemctl enable --now gitea-stack
nerdctl logs --tail 50 gitea-db
nerdctl logs --tail 50 gitea
curl -kfsS "https://${SERVER_HOST}:${GITEA_HTTPS_PORT}/api/healthz"
```

브라우저에서 Gitea를 열고 초기 설치 화면의 PostgreSQL·외부 URL·SSH 포트를 확인한다. Compose에 지정한 값과 맞추고 첫 관리자를 만든다. 초기 설치를 마친 뒤 app.ini의 설치 잠금이 켜졌는지 확인한다.

| 확인 항목 | 맞춰야 할 상태 |
| --- | --- |
| DB | db:5432, Gitea용 DB |
| Root URL | 실제 `https://호스트:30000/` |
| SSH Port | 외부 포트 222 |
| Actions | 활성화 |
| 자유 가입·익명 조회 | 비활성화 |
| 데이터 | 컨테이너와 독립된 호스트 볼륨 |

재기동은 `systemctl restart gitea-stack`으로 한다. 접속이 끊기므로 유지보수 시간에 수행한다. `down -v`나 DB 디렉터리 삭제를 설정 수정의 대안으로 사용하지 않는다.

---

## 5. Nexus HTTPS·Repository·권한 구성

<details class="analysis-toggle" markdown="1">
<summary>/root/compose/nexus-compose.yaml — 전체 내용</summary>

<div class="highlight" data-source-path="host/root/compose/nexus-compose.yaml"><pre><code><span class="nt">services</span><span class="p">:</span>
<span class="w">  </span><span class="nt">nexus</span><span class="p">:</span>
<span class="w">    </span><span class="nt">image</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">${NEXUS_IMAGE:?Set NEXUS_IMAGE in .env}</span>
<span class="w">    </span><span class="nt">container_name</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">nexus</span>
<span class="w">    </span><span class="nt">hostname</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">nexus</span>
<span class="w">    </span><span class="nt">restart</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">unless-stopped</span>

<span class="w">    </span><span class="nt">ports</span><span class="p">:</span>
<span class="w">      </span><span class="c1"># Nexus Web UI 및 REST API - HTTPS</span>
<span class="w">      </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="s">"${NEXUS_HTTPS_PORT}:55555"</span>

<span class="w">    </span><span class="nt">environment</span><span class="p">:</span>
<span class="w">      </span><span class="nt">INSTALL4J_ADD_VM_PARAMS</span><span class="p">:</span><span class="w"> </span><span class="p p-Indicator">&gt;-</span>
<span class="w">        </span><span class="no">-Xms${NEXUS_HEAP}</span>
<span class="w">        </span><span class="no">-Xmx${NEXUS_HEAP}</span>
<span class="w">        </span><span class="no">-XX:MaxDirectMemorySize=${NEXUS_DIRECT_MEMORY}</span>
<span class="w">        </span><span class="no">-Djava.util.prefs.userRoot=/nexus-data/javaprefs</span>
<span class="w">        </span><span class="no">-Duser.timezone=${TZ}</span>

<span class="w">    </span><span class="nt">volumes</span><span class="p">:</span>
<span class="w">      </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">${NEXUS_DATA_DIR}:/nexus-data</span>

<span class="w">    </span><span class="nt">ulimits</span><span class="p">:</span>
<span class="w">      </span><span class="nt">nofile</span><span class="p">:</span>
<span class="w">        </span><span class="nt">soft</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">65536</span>
<span class="w">        </span><span class="nt">hard</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">65536</span>


<span class="w">    </span><span class="nt">logging</span><span class="p">:</span>
<span class="w">      </span><span class="nt">driver</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">json-file</span>
<span class="w">      </span><span class="nt">options</span><span class="p">:</span>
<span class="w">        </span><span class="nt">max-size</span><span class="p">:</span><span class="w"> </span><span class="s">"20m"</span>
<span class="w">        </span><span class="nt">max-file</span><span class="p">:</span><span class="w"> </span><span class="s">"5"</span>

<span class="w">    </span><span class="nt">networks</span><span class="p">:</span>
<span class="w">      </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">nexus-net</span>

<span class="nt">networks</span><span class="p">:</span>
<span class="w">  </span><span class="nt">nexus-net</span><span class="p">:</span>
<span class="w">    </span><span class="nt">driver</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">bridge</span>
</code></pre></div>

</details>

<details class="analysis-toggle" markdown="1">
<summary>/data/nexus/nexus-data/etc/nexus.properties — 전체 내용</summary>

<div class="highlight" data-source-path="host/data/nexus/nexus-data/etc/nexus.properties"><pre><code><span class="na">application-host</span><span class="o">=</span><span class="s">0.0.0.0</span>
<span class="na">application-port-ssl</span><span class="o">=</span><span class="s">55555</span>
<span class="na">nexus-args</span><span class="o">=</span><span class="s">${jetty.etc}/jetty.xml,${jetty.etc}/jetty-https.xml,${jetty.etc}/jetty-requestlog.xml</span>
<span class="na">ssl.etc</span><span class="o">=</span><span class="s">${karaf.data}/etc/ssl</span>
<span class="na">nexus-context-path</span><span class="o">=</span><span class="s">/</span>
</code></pre></div>

</details>

<details class="analysis-toggle" markdown="1">
<summary>/etc/systemd/system/nexus-stack.service — 전체 내용</summary>

<div class="highlight" data-source-path="host/etc/systemd/system/nexus-stack.service"><pre><code><span class="k">[Unit]</span>
<span class="na">Description</span><span class="o">=</span><span class="s">Nexus Compose stack</span>
<span class="na">Requires</span><span class="o">=</span><span class="s">containerd.service</span>
<span class="na">Wants</span><span class="o">=</span><span class="s">network-online.target</span>
<span class="na">After</span><span class="o">=</span><span class="s">containerd.service network-online.target</span>

<span class="k">[Service]</span>
<span class="na">Type</span><span class="o">=</span><span class="s">oneshot</span>
<span class="na">RemainAfterExit</span><span class="o">=</span><span class="s">yes</span>
<span class="na">WorkingDirectory</span><span class="o">=</span><span class="s">/root/compose</span>
<span class="na">ExecStart</span><span class="o">=</span><span class="s">/usr/local/bin/nerdctl compose -p nexus -f nexus-compose.yaml up -d</span>
<span class="na">ExecStop</span><span class="o">=</span><span class="s">/usr/local/bin/nerdctl stop -t 180 nexus</span>
<span class="na">TimeoutStartSec</span><span class="o">=</span><span class="s">15min</span>
<span class="na">TimeoutStopSec</span><span class="o">=</span><span class="s">4min</span>

<span class="k">[Install]</span>
<span class="na">WantedBy</span><span class="o">=</span><span class="s">multi-user.target</span>
</code></pre></div>

</details>

Nexus HTTPS는 Java keystore를 사용한다. 아래의 `password`는 Jetty 기본값에 맞춘 **keystore 암호**이며 Nexus 관리자 로그인 비밀번호가 아니다. 사내 CA와 별도 암호를 사용한다면 Jetty 설정도 함께 맞춘다. [Nexus SSL](https://help.sonatype.com/en/configuring-ssl.html)

```bash title="Nexus 인증서와 최초 기동"
source /etc/gitea-runner-env/services.env
san="DNS:${SERVER_HOST},IP:127.0.0.1"
if [[ "${SERVER_HOST}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then san="IP:${SERVER_HOST},IP:127.0.0.1"; fi
nerdctl pull "${NEXUS_IMAGE}"
install -m 0644 -o 200 -g 200 \
  "${CONFIG_SRC}/host/data/nexus/nexus-data/etc/nexus.properties" "${NEXUS_DATA_DIR}/etc/nexus.properties"
nerdctl run --rm --user 200:200 --entrypoint keytool \
  -v "${NEXUS_DATA_DIR}:/nexus-data" "${NEXUS_IMAGE}" \
  -genkeypair -alias nexus -keyalg RSA -keysize 3072 -storetype JKS \
  -validity 365 -keystore /nexus-data/etc/ssl/keystore.jks \
  -storepass password -keypass password -dname "CN=${SERVER_HOST}" \
  -ext "SAN=${san},DNS:nexus"
chmod 0600 "${NEXUS_DATA_DIR}/etc/ssl/keystore.jks"
install -m 0644 "${CONFIG_SRC}/host/root/compose/nexus-compose.yaml" /root/compose/nexus-compose.yaml
install -m 0644 "${CONFIG_SRC}/host/etc/systemd/system/nexus-stack.service" /etc/systemd/system/nexus-stack.service
systemctl daemon-reload
systemctl enable --now nexus-stack
nerdctl logs --tail 50 nexus
curl -kfsS "https://${SERVER_HOST}:${NEXUS_HTTPS_PORT}/service/rest/v1/status"
```

HTTPS가 HTTP 200을 반환할 때까지 기다린다. nerdctl 2.2.2 Compose의 `healthcheck`와 `stop_grace_period`는 미구현이므로 제공 파일에서 제외했다. 준비 상태는 curl, 종료 대기는 systemd의 `nerdctl stop -t`로 지정한다. [Compose 지원 항목](https://github.com/containerd/nerdctl/blob/v2.2.2/docs/compose.md)

초기 사용자는 admin이다. `${NEXUS_DATA_DIR}/admin.password`를 관리용 터미널에서 확인하고 UI에서 변경한다. EULA를 검토해 동의하고, **사내 Nexus의 Anonymous access는 끈다.**

<p class="subsection-title"><strong>5-1. Blob Store와 Repository</strong></p>

<div class="section-body" markdown="1">

Classic UI의 **설정 → Repository → Blob Stores → Create blob store**에서 File 형식, 이름과 상대 Path는 `contrabass-engine`으로 만든다. 호스트 볼륨의 `/data/...`와 Blob의 상대 경로를 혼동하지 않는다.

**Repository → Repositories → Create repository**에서 다음을 만든다.

| Name | Type | Blob | Deployment policy |
| --- | --- | --- | --- |
| docker-hosted | docker (hosted) | contrabass-engine | Disable redeploy |
| raw-hosted | raw (hosted) | contrabass-engine | Disable redeploy |
| raw-manifest | raw (hosted) | contrabass-engine | Allow redeploy |
| raw-release-staging | raw (hosted) | contrabass-engine | Allow redeploy |
| raw-release-bundle | raw (hosted) | contrabass-engine | Allow redeploy |

Raw는 Strict Content Type Validation을 끈다. manifest·최종 저장소는 channel의 작은 파일을 갱신하므로 redeploy를 허용하고 **버전 경로의 불변성은 스크립트에서 대조**한다. staging은 부분 업로드 후 재시도를 고려한다.

Docker는 **Path-based routing을 켜고** 별도 8082/8083 connector는 만들지 않는다. **Security → Realms**에서 Docker Bearer Token Realm을 활성화한다. Raw는 `/repository/raw-hosted/...`, Docker는 `호스트:55555/docker-hosted/이름:Tag`다. Docker 주소에는 `/repository/`가 없다. [Nexus Docker Registry](https://help.sonatype.com/en/docker-registry.html)

</div>

<p class="subsection-title"><strong>5-2. Role과 User</strong></p>

<div class="section-body" markdown="1">

**Security → Roles → Create role → Nexus role**에서 만든다. 역할은 세 가지로 정리하되 사람의 계정과 CI 계정을 분리한다.

| Role | 대상 | 권한 |
| --- | --- | --- |
| runner-role | release-ci | 전체 재료 읽기, manifest·staging·Bundle 게시, staging·Bundle 삭제 |
| download-role | 사업수행팀 개인 계정 | raw-manifest·raw-release-bundle 조회·다운로드 |
| admin-role | 관리 담당자 | 내장 nx-admin 상속 |

Runner privileges는 다음과 같다. 콘텐츠 add/edit/delete와 서버 설정 관리 권한은 다르다.

```text title="runner-role privileges"
nx-search-read
nx-repository-view-*-*-browse
nx-repository-view-*-*-read
nx-repository-view-raw-raw-manifest-add
nx-repository-view-raw-raw-manifest-edit
nx-repository-view-raw-raw-release-staging-add
nx-repository-view-raw-raw-release-staging-edit
nx-repository-view-raw-raw-release-staging-delete
nx-repository-view-raw-raw-release-bundle-add
nx-repository-view-raw-raw-release-bundle-edit
nx-repository-view-raw-raw-release-bundle-delete
```

```text title="download-role privileges"
nx-repository-view-raw-raw-manifest-browse
nx-repository-view-raw-raw-manifest-read
nx-repository-view-raw-raw-release-bundle-browse
nx-repository-view-raw-raw-release-bundle-read
```

**Security → Users → Create local user**에서 release-ci를 만들어 runner-role을 연결한다. 비밀번호는 뒤에서 Gitea Secrets에 넣는다. 사업수행팀은 download-role, 관리자는 admin-role을 연결한다. CI에 관리자 역할을 주지 않는다. [Nexus privileges](https://help.sonatype.com/en/privileges.html)

</div>

---

## 6. 검증된 TAR에서 최초 재료와 제품 코드 준비

새 Nexus는 비어 있으므로 이 단계를 건너뛰면 Tag를 발행해도 재료를 받을 수 없다. 검증된 기존 제품 TAR와 해당 체크섬을 `/root/release-seed`에 둔다. 아래는 파일명을 맞춘 예다.

```bash title="초기 재료 준비"
install -d -m 0700 /root/release-seed
cd /root/release-seed
sha256sum -c contrabass-engine-deploy.tar.sha256
tar -xf contrabass-engine-deploy.tar
export SEED_DIR=/root/release-seed/contrabass-engine-deploy
test -s "${SEED_DIR}/manifest.yaml"
test -s "${SEED_DIR}/nexus/nexus-image.tar"
test -f "${SEED_DIR}/git/init-container/contrabass-engine/install.sh"
```

<p class="subsection-title"><strong>6-1. Raw와 Docker 최초 등록</strong></p>

<div class="section-body" markdown="1">

관리 담당 Nexus 계정으로 실행한다. Runner 역할에는 원본 재료 게시 권한이 없다. 비밀번호 입력은 화면에 표시하지 않는다.

```bash title="Raw 최초 등록 — 비어 있는 새 Repository에서 실행"
source /etc/gitea-runner-env/bundle-pipeline.env
source "${CONFIG_SRC}/host/opt/gitea/bundle-builder/common.sh"
read -r -p 'Nexus 관리 사용자: ' NEXUS_USER
read -r -s -p 'Nexus 비밀번호: ' NEXUS_PASSWORD
printf '\n'
while IFS='|' read -r path expected; do
  test "$(sha256sum "${SEED_DIR}/raw/${path}" | awk '{print $1}')" = "${expected}" || exit 1
  nexus_curl -fsS --upload-file "${SEED_DIR}/raw/${path}" \
    "${NEXUS_URL}/repository/${RAW_REPOSITORY}/${path}"
  actual="$(nexus_curl -fsS "${NEXUS_URL}/repository/${RAW_REPOSITORY}/${path}" | sha256sum | awk '{print $1}')"
  test "${actual}" = "${expected}" || exit 1
done < <(awk -F'"' '/^  - path:/{path=$2} /^    sha256:/{print path "|" $2}' "${SEED_DIR}/manifest.yaml")
```

Docker는 load 후 새 서버의 같은 Repository 경로에 tag·push한다.

```bash title="Docker 최초 등록"
registry="${NEXUS_URL#https://}"
install -d -m 0755 "/etc/containerd/certs.d/${registry}"
printf 'server = "%s"\n[host."%s"]\n capabilities = ["pull", "resolve", "push"]\n skip_verify = true\n' \
  "${NEXUS_URL}" "${NEXUS_URL}" > "/etc/containerd/certs.d/${registry}/hosts.toml"
nerdctl load -i "${SEED_DIR}/images/release-images.tar"
printf '%s' "${NEXUS_PASSWORD}" | nerdctl login --username "${NEXUS_USER}" --password-stdin "${registry}"
while IFS='|' read -r original name tag digest; do
  target="${registry}/${DOCKER_REPOSITORY}/${name}:${tag}"
  nerdctl tag "${original}" "${target}"
  nerdctl push "${target}"
  actual="$(nexus_curl -fsSI \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
    "${NEXUS_URL}/v2/${DOCKER_REPOSITORY}/${name}/manifests/${tag}" \
    | awk 'tolower($1)=="docker-content-digest:" {gsub("\r", "", $2); print $2; exit}')"
  test "${actual}" = "${digest}" || exit 1
done < "${SEED_DIR}/images/image-map.txt"
nerdctl logout "${registry}"
unset NEXUS_PASSWORD
```

기존 경로를 덮어쓰는 명령이 아니다. 실패 후에는 같은 파일을 무조건 재게시하지 않고 이미 있는 파일의 SHA256·이미지 digest를 확인한다.

</div>

<p class="subsection-title"><strong>6-2. 새 Gitea에 제품 코드 등록</strong></p>

<div class="section-body" markdown="1">

Gitea에 소유자와 빈 private Repository를 만든다. 예시는 `platform/private-cloud-v4`다. README 자동 생성은 끄고 기본 브랜치는 master로 한다. 예전 사용자·PR·이력을 복제하는 것이 아니라 새 운영 저장소의 초기 코드를 준비하는 절차다.

Repository의 **Settings → Repository → Advanced Settings**에서도 Actions 사용이 켜져 있는지 확인한다. 서버의 Actions 활성화와 저장소의 실행 허용을 구분한다. 조직으로 운영한다면 개발팀·검토자 팀에 해당 저장소의 Code·Pull Requests 권한을 명시하고, CI 읽기 계정은 관리자 팀에 넣지 않는다.

```bash title="기존 .git을 섞지 않고 새 저장소의 초기 코드 준비"
install -d -m 0700 /root/private-cloud-v4
tar -C "${SEED_DIR}/git/init-container" --exclude='./.git' --exclude='./.gitea/workflows' -cf - . \
  | tar -C /root/private-cloud-v4 -xf -
cd /root/private-cloud-v4
install -d .gitea/workflows
install -m 0644 "${CONFIG_SRC}/repository/workflows/publish-manifest.yaml" .gitea/workflows/publish-manifest.yaml
install -m 0644 "${CONFIG_SRC}/repository/gitignore" .gitignore
git init -b master
# 본인의 Git user.name / user.email 설정 후 commit
git add .
git commit -m 'Initialize release platform source'
source /etc/gitea-runner-env/bundle-pipeline.env
git remote add origin "${GITEA_REPO_URL}"
git -c http.sslVerify=false push -u origin master
git switch -c develop
git -c http.sslVerify=false push -u origin develop
```

제품 install.sh, containerd.service, nerdctl.toml, BuildKit 설정과 Ansible 코드를 보존한다. **대용량 파일을 Git에서 빼는 것과 작은 서비스 설정까지 지우는 것은 다르다.**

<details class="analysis-toggle" markdown="1">
<summary>repository/release/manifest.example.yaml — 전체 내용</summary>

<div class="highlight" data-source-path="repository/release/manifest.example.yaml"><pre><code><span class="nt">schema_version</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">2</span>
<span class="nt">release</span><span class="p">:</span><span class="w"> </span><span class="s">"4.1.2"</span>
<span class="nt">nexus</span><span class="p">:</span>
<span class="w">  </span><span class="nt">image</span><span class="p">:</span><span class="w"> </span><span class="s">"docker.io/sonatype/nexus3:3.96.1"</span>
<span class="w">  </span><span class="nt">archive_sha256</span><span class="p">:</span><span class="w"> </span><span class="s">"bdb047b4821dab2ce46da1be87b98b52d6bd56d24a02b331144e3cbe5a334318"</span>
<span class="nt">artifacts</span><span class="p">:</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">path</span><span class="p">:</span><span class="w"> </span><span class="s">"ansible-runtime/buildkit-v0.12.4.linux-amd64.tar.gz"</span>
<span class="w">    </span><span class="nt">sha256</span><span class="p">:</span><span class="w"> </span><span class="s">"75ffe406e4284b77af35447d829767cfa935eb7dd2ea2e3407223d6885bd8ebd"</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">path</span><span class="p">:</span><span class="w"> </span><span class="s">"ansible-runtime/cni-plugins-linux-amd64-v1.8.0.tgz"</span>
<span class="w">    </span><span class="nt">sha256</span><span class="p">:</span><span class="w"> </span><span class="s">"ab3bda535f9d90766cccc90d3dddb5482003dd744d7f22bcf98186bf8eea8be6"</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">path</span><span class="p">:</span><span class="w"> </span><span class="s">"ansible-runtime/containerd-2.1.5-linux-amd64.tar.gz"</span>
<span class="w">    </span><span class="nt">sha256</span><span class="p">:</span><span class="w"> </span><span class="s">"403af72d9f956ed8a5ad5b0ac0f1e8e371a1488f2b9edf9b4ba13db0653936ea"</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">path</span><span class="p">:</span><span class="w"> </span><span class="s">"ansible-runtime/nerdctl-2.1.6-linux-amd64.tar.gz"</span>
<span class="w">    </span><span class="nt">sha256</span><span class="p">:</span><span class="w"> </span><span class="s">"22857b373edea479a4534ba62cae1c77f2af38f0aac4c91c1c68cf09e29d6f9e"</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">path</span><span class="p">:</span><span class="w"> </span><span class="s">"ansible-runtime/runc.amd64"</span>
<span class="w">    </span><span class="nt">sha256</span><span class="p">:</span><span class="w"> </span><span class="s">"5966ca40b6187b30e33bfc299c5f1fe72e8c1aa01cf3fefdadf391668f47f103"</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">path</span><span class="p">:</span><span class="w"> </span><span class="s">"contrabass-mole/3.0.6/contrabass-mole.tar.gz"</span>
<span class="w">    </span><span class="nt">sha256</span><span class="p">:</span><span class="w"> </span><span class="s">"68c14a2c9c6d881ce40c38f6abd0e6acc24c46b8076a00d56b626f443a208fab"</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">path</span><span class="p">:</span><span class="w"> </span><span class="s">"monitoring/alertmanager/0.25.1/alertmanager-linux-amd64"</span>
<span class="w">    </span><span class="nt">sha256</span><span class="p">:</span><span class="w"> </span><span class="s">"7f2b055f1753a4fa7e88d50d083a11f47bd8da8b84695c08f5c53f4afb977919"</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">path</span><span class="p">:</span><span class="w"> </span><span class="s">"monitoring/alertmanager/0.25.1/amtool-linux-amd64"</span>
<span class="w">    </span><span class="nt">sha256</span><span class="p">:</span><span class="w"> </span><span class="s">"a654924183be383901d312933fcf44e571ff1bd0ef5cf52c8cf01505de604bab"</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">path</span><span class="p">:</span><span class="w"> </span><span class="s">"monitoring/alloy/1.10.1/alloy-linux-amd64"</span>
<span class="w">    </span><span class="nt">sha256</span><span class="p">:</span><span class="w"> </span><span class="s">"965275e2ec6cea0fde5546159a019daeaaf7560745c9743f6dbb94a78cf9e4e5"</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">path</span><span class="p">:</span><span class="w"> </span><span class="s">"monitoring/contrabass-exporter/1.7.2/contrabass-exporter-linux-amd64"</span>
<span class="w">    </span><span class="nt">sha256</span><span class="p">:</span><span class="w"> </span><span class="s">"e984f5bcaf558dfcabc511cfdc45233078fc5207b6eff397285f66fcb7b5aab8"</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">path</span><span class="p">:</span><span class="w"> </span><span class="s">"monitoring/ha-cluster-exporter/1.4.0/ha_cluster-exporter-linux-amd64"</span>
<span class="w">    </span><span class="nt">sha256</span><span class="p">:</span><span class="w"> </span><span class="s">"6b9f97d96fe5c1d63bda5bc03116ece75fccd8da4606e957f75d849040ad30a2"</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">path</span><span class="p">:</span><span class="w"> </span><span class="s">"monitoring/haproxy-exporter/0.15.0/haproxy-exporter-linux-amd64"</span>
<span class="w">    </span><span class="nt">sha256</span><span class="p">:</span><span class="w"> </span><span class="s">"7abaa0d0de96b313b81613fc4030b6fcd3cbe2777b91d86aae910488c4a385f6"</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">path</span><span class="p">:</span><span class="w"> </span><span class="s">"monitoring/ipmi-exporter/1.10.0/ipmi-exporter-linux-amd64"</span>
<span class="w">    </span><span class="nt">sha256</span><span class="p">:</span><span class="w"> </span><span class="s">"763b21416c02848ead1bf5afd26bfd390da3aef06aae2d7961616f92aa43dd54"</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">path</span><span class="p">:</span><span class="w"> </span><span class="s">"monitoring/loki/3.3.0/loki-linux-amd64"</span>
<span class="w">    </span><span class="nt">sha256</span><span class="p">:</span><span class="w"> </span><span class="s">"80be7644e4fe4a3dca3732b55f0abfff8ebfb897aec050dba26c75e5aa99e9f5"</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">path</span><span class="p">:</span><span class="w"> </span><span class="s">"monitoring/memcached-exporter/0.15.0/memcached-exporter-linux-amd64"</span>
<span class="w">    </span><span class="nt">sha256</span><span class="p">:</span><span class="w"> </span><span class="s">"f727807d51846622c0fada4692373a8f14bc5ad71b7d3690884e74fafd85a79e"</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">path</span><span class="p">:</span><span class="w"> </span><span class="s">"monitoring/mysqld-exporter/0.16.0/mysqld-exporter-linux-amd64"</span>
<span class="w">    </span><span class="nt">sha256</span><span class="p">:</span><span class="w"> </span><span class="s">"0374e5968ddd52b098fd605c8a653728927cae3e5cc3c155a04c5bdfe2479511"</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">path</span><span class="p">:</span><span class="w"> </span><span class="s">"monitoring/node-exporter/1.6.1/node_exporter-linux-amd64"</span>
<span class="w">    </span><span class="nt">sha256</span><span class="p">:</span><span class="w"> </span><span class="s">"1a6ff4c715bd59fc3108188d602a7086e80b61b06c4cb3a92a1d2cb66e077d4e"</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">path</span><span class="p">:</span><span class="w"> </span><span class="s">"monitoring/openstack-exporter/1.7.0/openstack-exporter-linux-amd64"</span>
<span class="w">    </span><span class="nt">sha256</span><span class="p">:</span><span class="w"> </span><span class="s">"4827ad4a95c3af9f56c026e168168050429793c3406c0330b9f9c4049e8bca3f"</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">path</span><span class="p">:</span><span class="w"> </span><span class="s">"monitoring/ovs-exporter/1.0.7/ovs-exporter-linux-amd64"</span>
<span class="w">    </span><span class="nt">sha256</span><span class="p">:</span><span class="w"> </span><span class="s">"0b01674c16502fa74d11d95630028aee8879efed27086d74bda942555c62aff8"</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">path</span><span class="p">:</span><span class="w"> </span><span class="s">"monitoring/prometheus-am-executor/prometheus-am-executor-linux-amd64"</span>
<span class="w">    </span><span class="nt">sha256</span><span class="p">:</span><span class="w"> </span><span class="s">"8e2ee12a065532e615fafd1e92059953df76a8e485893373afe0723abc93649a"</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">path</span><span class="p">:</span><span class="w"> </span><span class="s">"monitoring/prometheus/3.5.0/prometheus-linux-amd64"</span>
<span class="w">    </span><span class="nt">sha256</span><span class="p">:</span><span class="w"> </span><span class="s">"4ee49f574d80682b6571f017c8f42f2532aa3603b725b51ecb0cb864f06c2282"</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">path</span><span class="p">:</span><span class="w"> </span><span class="s">"monitoring/prometheus/3.5.0/promtool-linux-amd64"</span>
<span class="w">    </span><span class="nt">sha256</span><span class="p">:</span><span class="w"> </span><span class="s">"e59210d5474e2c811a4460fb1593d708b94d58107ae62e9d44e88029bb7e5805"</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">path</span><span class="p">:</span><span class="w"> </span><span class="s">"monitoring/thanos/0.33.0/thanos-linux-amd64"</span>
<span class="w">    </span><span class="nt">sha256</span><span class="p">:</span><span class="w"> </span><span class="s">"07563feeab74f599d384447a8f2753c49a9336ad818bcdefc4ddb05838d61dea"</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">path</span><span class="p">:</span><span class="w"> </span><span class="s">"openstack/cinder/24.5.0/cinder-24.5.0.tar.gz"</span>
<span class="w">    </span><span class="nt">sha256</span><span class="p">:</span><span class="w"> </span><span class="s">"9164d571c9c5703715b7d8ed1a0302dd6a90c135d24d36e3c4e511d1c2747ecb"</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">path</span><span class="p">:</span><span class="w"> </span><span class="s">"openstack/masakari-monitors/caracal/masakari-monitors-caracal.tar"</span>
<span class="w">    </span><span class="nt">sha256</span><span class="p">:</span><span class="w"> </span><span class="s">"064e064977e7bef8b55586ea82e2a9c16de8d3cbaef496aac68ad33229a3d55e"</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">path</span><span class="p">:</span><span class="w"> </span><span class="s">"openstack/masakari-monitors/epoxy/masakari-monitors-epoxy.tar"</span>
<span class="w">    </span><span class="nt">sha256</span><span class="p">:</span><span class="w"> </span><span class="s">"ce8b7f5d0c47736cbcfa9157dbc75b1b0806a6e5ac6ce97fdf944bba0a7fd118"</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">path</span><span class="p">:</span><span class="w"> </span><span class="s">"openstack/masakari/caracal/masakari-caracal.tar"</span>
<span class="w">    </span><span class="nt">sha256</span><span class="p">:</span><span class="w"> </span><span class="s">"b4c00d3e6b8f5691c125324f22b5eea3d67c1200a05e1646f365804cb0648245"</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">path</span><span class="p">:</span><span class="w"> </span><span class="s">"openstack/masakari/epoxy/masakari-epoxy.tar"</span>
<span class="w">    </span><span class="nt">sha256</span><span class="p">:</span><span class="w"> </span><span class="s">"acbfb4bb01fa0494d2c6f3a23f0aa16395c4d03475ba04e9a78bf9d92828b87c"</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">path</span><span class="p">:</span><span class="w"> </span><span class="s">"python-wheel/os-brick/6.7.3/os_brick-6.7.3-py3-none-any.whl"</span>
<span class="w">    </span><span class="nt">sha256</span><span class="p">:</span><span class="w"> </span><span class="s">"83d558bc1c501fd911a7735bb5a19e54e19ee4394e1e9527ed36bc326a3ffaa8"</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">path</span><span class="p">:</span><span class="w"> </span><span class="s">"python-wheel/oslo-messaging/14.7.2/oslo.messaging-14.7.2-py3-none-any.whl"</span>
<span class="w">    </span><span class="nt">sha256</span><span class="p">:</span><span class="w"> </span><span class="s">"d3e0dd551785c23d208f2be9b550c9308d63abd0d322d74390a81e5b88cc7e2c"</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">path</span><span class="p">:</span><span class="w"> </span><span class="s">"storage/s3cmd/2.4.0/s3cmd-2.4.0.tar.gz"</span>
<span class="w">    </span><span class="nt">sha256</span><span class="p">:</span><span class="w"> </span><span class="s">"6b567521be1c151323f2059c8feec85ded96b6f184ff80535837fea33798b40b"</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">path</span><span class="p">:</span><span class="w"> </span><span class="s">"storage/seaweedfs/4.0.5/mc-linux-amd64"</span>
<span class="w">    </span><span class="nt">sha256</span><span class="p">:</span><span class="w"> </span><span class="s">"ac90da87a35641be5a0ac75d49de5161ddb47d629b5ba01261b0ae9e00aea15f"</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">path</span><span class="p">:</span><span class="w"> </span><span class="s">"storage/seaweedfs/4.0.5/weed-linux-amd64"</span>
<span class="w">    </span><span class="nt">sha256</span><span class="p">:</span><span class="w"> </span><span class="s">"058fca2d7884f8fa2b3897b6dff3c4f5387377f64dd0a1418aed398193048c64"</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">path</span><span class="p">:</span><span class="w"> </span><span class="s">"vm-image/cirros-0.6.2-x86_64-disk.img"</span>
<span class="w">    </span><span class="nt">sha256</span><span class="p">:</span><span class="w"> </span><span class="s">"07e44a73e54c94d988028515403c1ed762055e01b83a767edf3c2b387f78ce00"</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">path</span><span class="p">:</span><span class="w"> </span><span class="s">"vm-image/noble-qemu-okestro2018.qcow2"</span>
<span class="w">    </span><span class="nt">sha256</span><span class="p">:</span><span class="w"> </span><span class="s">"02b9ac80e4aad165e63d084acaed5fea2aca049205faa98c1acb7770202da8a0"</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">path</span><span class="p">:</span><span class="w"> </span><span class="s">"vm-image/octavia-amphora-haproxy-2024.1-qemu.qcow2"</span>
<span class="w">    </span><span class="nt">sha256</span><span class="p">:</span><span class="w"> </span><span class="s">"de9636775f2c41ecb76cca4a3920528810c964a4132d74d9233545d34c94c9ac"</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">path</span><span class="p">:</span><span class="w"> </span><span class="s">"vm-image/ubuntu-22.04-qemu.qcow2"</span>
<span class="w">    </span><span class="nt">sha256</span><span class="p">:</span><span class="w"> </span><span class="s">"f1ec59a47d7681dd643e624a20f6e76c76c395a3303f8d7360b3ca0e67a83d9f"</span>
<span class="nt">images</span><span class="p">:</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">name</span><span class="p">:</span><span class="w"> </span><span class="s">"ansible/openstack-ansible"</span>
<span class="w">    </span><span class="nt">tag</span><span class="p">:</span><span class="w"> </span><span class="s">"v1.6"</span>
<span class="w">    </span><span class="nt">digest</span><span class="p">:</span><span class="w"> </span><span class="s">"sha256:c950fff9abb30c0070da407c31f8ed6d3bbc783f7e2f417f8ab97916b8e88409"</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">name</span><span class="p">:</span><span class="w"> </span><span class="s">"ceph19.2.3/alertmanager"</span>
<span class="w">    </span><span class="nt">tag</span><span class="p">:</span><span class="w"> </span><span class="s">"v0.25.0"</span>
<span class="w">    </span><span class="nt">digest</span><span class="p">:</span><span class="w"> </span><span class="s">"sha256:642dcafd0ad4f5d9cbada7cfd59ca4dd244118e622e815417d49c52282504fc5"</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">name</span><span class="p">:</span><span class="w"> </span><span class="s">"ceph19.2.3/anomaly-predictor"</span>
<span class="w">    </span><span class="nt">tag</span><span class="p">:</span><span class="w"> </span><span class="s">"v1.8.0"</span>
<span class="w">    </span><span class="nt">digest</span><span class="p">:</span><span class="w"> </span><span class="s">"sha256:641d43d2292f2d4c1e2d51fd7e7cb0d396238a28d5b8c1fd913bce1b06cb5c4e"</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">name</span><span class="p">:</span><span class="w"> </span><span class="s">"ceph19.2.3/ceph"</span>
<span class="w">    </span><span class="nt">tag</span><span class="p">:</span><span class="w"> </span><span class="s">"v19.2.3"</span>
<span class="w">    </span><span class="nt">digest</span><span class="p">:</span><span class="w"> </span><span class="s">"sha256:34c8780c13ff694d77d65e4705b3f355fabff8a9e0db13e42677f802ed389a44"</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">name</span><span class="p">:</span><span class="w"> </span><span class="s">"ceph19.2.3/grafana"</span>
<span class="w">    </span><span class="nt">tag</span><span class="p">:</span><span class="w"> </span><span class="s">"10.4.0"</span>
<span class="w">    </span><span class="nt">digest</span><span class="p">:</span><span class="w"> </span><span class="s">"sha256:9e7c1c9cc9fd0ec7e50f8a3ed6f83a5ce42a5a1e2188f6b865dd853540ff35a9"</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">name</span><span class="p">:</span><span class="w"> </span><span class="s">"ceph19.2.3/node-exporter"</span>
<span class="w">    </span><span class="nt">tag</span><span class="p">:</span><span class="w"> </span><span class="s">"v1.7.0"</span>
<span class="w">    </span><span class="nt">digest</span><span class="p">:</span><span class="w"> </span><span class="s">"sha256:569a995b0ba280e6d62e579a33765f5d22538fba98100b4938032430367d8f92"</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">name</span><span class="p">:</span><span class="w"> </span><span class="s">"ceph19.2.3/nvmeof"</span>
<span class="w">    </span><span class="nt">tag</span><span class="p">:</span><span class="w"> </span><span class="s">"1.2.5"</span>
<span class="w">    </span><span class="nt">digest</span><span class="p">:</span><span class="w"> </span><span class="s">"sha256:2360f22b6d8279d93d16e166802df6ee3550f84ee9c824fe7cf0ef82edcb7334"</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">name</span><span class="p">:</span><span class="w"> </span><span class="s">"ceph19.2.3/nvmeof-cli"</span>
<span class="w">    </span><span class="nt">tag</span><span class="p">:</span><span class="w"> </span><span class="s">"1.2.5"</span>
<span class="w">    </span><span class="nt">digest</span><span class="p">:</span><span class="w"> </span><span class="s">"sha256:f8bdcc2372b0d5ab3d1861af6caf652e66845f94fb693a82bc0298500418ae39"</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">name</span><span class="p">:</span><span class="w"> </span><span class="s">"ceph19.2.3/prometheus"</span>
<span class="w">    </span><span class="nt">tag</span><span class="p">:</span><span class="w"> </span><span class="s">"v2.51.0"</span>
<span class="w">    </span><span class="nt">digest</span><span class="p">:</span><span class="w"> </span><span class="s">"sha256:bef0e7e1da4db383504b13abd8ddc7c0fa66ecc9e03a0b122a35db1e455bdf6f"</span>
<span class="w">  </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">name</span><span class="p">:</span><span class="w"> </span><span class="s">"ceph19.2.3/registry"</span>
<span class="w">    </span><span class="nt">tag</span><span class="p">:</span><span class="w"> </span><span class="s">"2.8.3"</span>
<span class="w">    </span><span class="nt">digest</span><span class="p">:</span><span class="w"> </span><span class="s">"sha256:14ccb20da68fa94ee09519b8ab7569347d0e74009e8823816d64e3f6f5787208"</span>
</code></pre></div>

</details>

<details class="analysis-toggle" markdown="1">
<summary>.gitignore — 전체 내용</summary>

<div class="highlight" data-source-path="repository/gitignore"><pre><code><span class="na">.terraform/</span>
<span class="na">*.tfstate</span>
<span class="na">*.tfstate.*</span>
<span class="na">*.tfplan</span>
<span class="na">*.plan</span>
<span class="na">.env</span>
<span class="na">.env.*</span>
<span class="na">!.env.example</span>
<span class="na">*.secret</span>
<span class="na">id_rsa</span>
<span class="na">id_ed25519</span>
<span class="na">vm-info.json</span>
<span class="na">*-cleanup.enabled</span>
<span class="na">staging-upload.enabled</span>
<span class="na">bundle-published.enabled</span>
<span class="na">test-passed.sha256</span>
<span class="na">*.tar</span>
<span class="na">*.tar.gz</span>
<span class="na">*.qcow2</span>
</code></pre></div>

</details>

manifest 예시는 형식과 재료 목록의 참고본이다. 실제로는 seed의 `release/manifest.yaml`과 바깥 `manifest.yaml`이 같은지 확인하고 새 Nexus에 등록한 내용을 기준으로 사용한다. Nexus archive를 다시 export하면 파일 해시가 달라질 수 있으므로 검증한 archive 자체를 가져온다.

```bash title="빌더용 Nexus 이미지와 해시 확인"
source /etc/gitea-runner-env/bundle-pipeline.env
install -m 0644 "${SEED_DIR}/nexus/nexus-image.tar" "${NEXUS_BASE_IMAGE}"
sha256sum "${NEXUS_BASE_IMAGE}"
cmp /root/private-cloud-v4/release/manifest.yaml "${SEED_DIR}/manifest.yaml"
```

`archive_sha256`은 첫 출력과 맞아야 한다. cmp는 두 manifest가 다르면 실패한다. 최초 등록 명령도 Raw의 전후 SHA256과 Docker의 `Docker-Content-Digest`를 대조한다. Tag 이름만으로 같은 이미지라고 판단하지 않는다.

</div>

<p class="subsection-title"><strong>6-3. Ansible 설정과 사내 install.sh</strong></p>

<div class="section-body" markdown="1">

제품 코드에서 아래를 확인한다. manifest와 nexus.yml이 별도 정의이므로 같은 재료의 버전·경로를 맞춘다.

| 파일 | 확인·수정할 것 |
| --- | --- |
| release/manifest.yaml | release, 재료 경로·SHA256, 이미지 digest |
| inventory/group_vars/all/nexus.yml | Ansible이 사용할 재료와 경로 |
| inventory/group_vars/all/main.yml | nexus_url, package_ip, VIP·네트워크·배포 인증 설정 |
| inventory/inventory.ini | 노드 IP·역할, 호스트별 SeaweedFS·OSD 디바이스 |

`nexus_url`은 `192.0.2.101:55555`처럼 **scheme 없는 IP:PORT**로 지정한다. Ansible 다운로드 설정이 HTTPS를 붙인다. 컨테이너 환경변수로 다시 전달하는 방식이 아니다.

full 시험의 inventory는 `192.0.2.101~104`와 맞춘다. 처음 3대는 Controller + Compute + Ceph, 4번째는 Compute + Ceph OSD다. 이 설정은 시험용이며 고객사 반입 후에는 현장 값으로 바꾼다. Runner가 inventory를 임의로 생성·복사한다고 가정하지 않는다.

사내 install.sh는 인자 없이 실행하면 사내 Nexus에 인증을 요청한다. 다른 주소는 `install.sh IP:PORT`, 고객사 deploy.sh는 `--anonymous`를 전달한다. 가져온 제품 코드가 이 규격인지 확인하고 사내 기본 주소를 새 서버로 맞춘다. 이 과정에서 원래 컨테이너의 네트워크·SSH·비밀번호 로직까지 무관하게 바꾸지 않는다.

</div>

---

## 7. Gitea 사용자·보호 규칙·Secrets

<p class="subsection-title"><strong>7-1. 사용자와 브랜치</strong></p>

<div class="section-body" markdown="1">

관리 화면에서 개발자·검토자·CI 읽기 사용자를 만들고 Repository 권한을 연결한다. 개발·검토 계정은 Code와 Pull Requests에 Write, CI는 코드·PR 읽기 권한을 준다. 관리자 1명이 자기 PR을 승인하는 구조로 만들지 않는다.

Repository의 **Settings → Branches**에서 설정한다.

| 규칙 | master | develop |
| --- | --- | --- |
| 직접 push | 금지 | 팀원 허용 |
| force push | 금지 | 금지 |
| 필수 승인 | 작성자 외 1명 | 필수로 두지 않음 |
| 새 commit 뒤 이전 승인 | 해제 | PR을 쓰는 경우 같은 기준 |
| 거절 리뷰가 있는 PR | merge 차단 | 필요에 따라 동일 적용 |
| 관리자 승인 조건 우회 | 금지 | master 우회로 사용하지 않음 |

merge 방법은 **merge commit만** 사용하고 squash·rebase merge를 끈다. 파이프라인이 merge commit의 두 번째 부모에서 승인 대상을 확인하기 때문이다. [Gitea 브랜치 보호](https://docs.gitea.com/1.25/usage/access-control/protected-branches/)

**Settings → Tags**에서 `v*`를 보호하고 릴리스 담당자만 발행하게 한다. Labels에 `release:skip-test`를 만들고 시험 생략을 판단하는 검토자가 PR에 붙인다.

</div>

<p class="subsection-title"><strong>7-2. Token과 Secret 구분</strong></p>

<div class="section-body" markdown="1">

CI 읽기 사용자로 **사용자 Settings → Applications → Generate New Token**에서 개인 액세스 토큰을 만든다. 대상 Repository·PR 조회에 필요한 `read:repository`, `read:issue` 범위를 사용한다. 저장소 자체의 접근 권한도 있어야 하며 scope만으로 권한이 늘어나지는 않는다.

Repository의 **Settings → Actions → Secrets**에 등록한다.

| Secret 이름 | 값과 용도 |
| --- | --- |
| REPO_READ_TOKEN | CI 사용자의 Git·PR 읽기 토큰 |
| NEXUS_RUNNER_PASSWORD | release-ci의 Nexus 비밀번호 |
| VSPHERE_USER | SSO domain을 포함한 vCenter API 사용자 |
| VSPHERE_PASSWORD | 해당 API 계정의 비밀번호 |
| OPENSTACK_PASSWORD | 시험 OpenStack admin 비밀번호 |

Runner 등록 Token은 다음 절의 등록에만 사용한다. REPO_READ_TOKEN에 넣지 않는다. `.runner`도 Git 인증용 파일이 아니다. Secrets를 호스트 `.secret`이나 Git 코드에 다시 저장하지 않는다.

skip은 VMware·OpenStack을 쓰지 않지만 Git과 Nexus 인증은 필요하다. Nexus 사용자 이름은 `bundle-pipeline.env`와 실제 생성한 계정을 맞춘다.

</div>

---

## 8. Runner 등록과 SSH·실행 권한 준비

<details class="analysis-toggle" markdown="1">
<summary>/etc/gitea-runner/config.yaml — 전체 내용</summary>

<div class="highlight" data-source-path="host/etc/gitea-runner/config.yaml"><pre><code><span class="nt">log</span><span class="p">:</span>
<span class="w">  </span><span class="nt">level</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">info</span>
<span class="w">  </span><span class="nt">job</span><span class="p">:</span>
<span class="w">    </span><span class="nt">dir</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">/var/lib/gitea-runner/logs</span>
<span class="w">    </span><span class="nt">retention</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">168h</span>
<span class="w">    </span><span class="nt">max_size</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">20MB</span>

<span class="nt">runner</span><span class="p">:</span>
<span class="w">  </span><span class="nt">file</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">/var/lib/gitea-runner/.runner</span>
<span class="w">  </span><span class="nt">capacity</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">1</span>
<span class="w">  </span><span class="nt">timeout</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">3h</span>
<span class="w">  </span><span class="nt">shutdown_timeout</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">3h</span>
<span class="w">  </span><span class="nt">insecure</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">true</span>

<span class="w">  </span><span class="nt">labels</span><span class="p">:</span>
<span class="w">    </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="s">"contrabass-engine-release:host"</span>

<span class="w">  </span><span class="nt">action_shallow_clone</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">true</span>

<span class="w">  </span><span class="nt">workdir_cleanup_age</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">24h</span>
<span class="w">  </span><span class="nt">idle_cleanup_interval</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">10m</span>

<span class="nt">cache</span><span class="p">:</span>
<span class="w">  </span><span class="nt">enabled</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">false</span>

<span class="nt">host</span><span class="p">:</span>
<span class="w">  </span><span class="nt">workdir_parent</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">/var/lib/gitea-runner/workspace</span>

<span class="nt">health_check</span><span class="p">:</span>
<span class="w">  </span><span class="nt">enabled</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">true</span>
<span class="w">  </span><span class="nt">min_free_disk_space_mb</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">20480</span>
<span class="w">  </span><span class="nt">interval</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">30s</span>
<span class="w">  </span><span class="nt">timeout</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">10s</span>

<span class="nt">metrics</span><span class="p">:</span>
<span class="w">  </span><span class="nt">enabled</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">true</span>
<span class="w">  </span><span class="nt">addr</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">127.0.0.1:9101</span>
<span class="w">  </span><span class="nt">readiness_grace</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">30s</span>
</code></pre></div>

</details>

<details class="analysis-toggle" markdown="1">
<summary>/etc/systemd/system/gitea-runner.service — 전체 내용</summary>

<div class="highlight" data-source-path="host/etc/systemd/system/gitea-runner.service"><pre><code><span class="k">[Unit]</span>
<span class="na">Description</span><span class="o">=</span><span class="s">Gitea Actions Runner 4.0.0</span>
<span class="na">Documentation</span><span class="o">=</span><span class="s">https://docs.gitea.com/runner/</span>
<span class="na">Wants</span><span class="o">=</span><span class="s">network-online.target containerd.service gitea-stack.service nexus-stack.service haproxy.service</span>
<span class="na">After</span><span class="o">=</span><span class="s">network-online.target containerd.service gitea-stack.service nexus-stack.service haproxy.service</span>

<span class="k">[Service]</span>
<span class="na">Type</span><span class="o">=</span><span class="s">simple</span>

<span class="na">User</span><span class="o">=</span><span class="s">gitea-runner</span>
<span class="na">Group</span><span class="o">=</span><span class="s">gitea-runner</span>

<span class="na">WorkingDirectory</span><span class="o">=</span><span class="s">/var/lib/gitea-runner</span>

<span class="na">Environment</span><span class="o">=</span><span class="s">"HOME=/var/lib/gitea-runner"</span>
<span class="na">Environment</span><span class="o">=</span><span class="s">"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"</span>

<span class="na">ExecStart</span><span class="o">=</span><span class="s">/usr/local/bin/gitea-runner daemon --config /etc/gitea-runner/config.yaml</span>

<span class="na">Restart</span><span class="o">=</span><span class="s">on-failure</span>
<span class="na">RestartSec</span><span class="o">=</span><span class="s">5s</span>

<span class="na">TimeoutStopSec</span><span class="o">=</span><span class="s">185min</span>
<span class="na">KillSignal</span><span class="o">=</span><span class="s">SIGTERM</span>

<span class="na">LimitNOFILE</span><span class="o">=</span><span class="s">65536</span>
<span class="na">UMask</span><span class="o">=</span><span class="s">0077</span>
<span class="c1"># sudo is required by the two root-owned release wrappers.</span>
<span class="c1"># NoNewPrivileges would break those wrappers.</span>
<span class="na">PrivateTmp</span><span class="o">=</span><span class="s">true</span>
<span class="na">ProtectKernelTunables</span><span class="o">=</span><span class="s">true</span>
<span class="na">ProtectKernelModules</span><span class="o">=</span><span class="s">true</span>
<span class="na">ProtectControlGroups</span><span class="o">=</span><span class="s">true</span>

<span class="na">StandardOutput</span><span class="o">=</span><span class="s">journal</span>
<span class="na">StandardError</span><span class="o">=</span><span class="s">journal</span>

<span class="k">[Install]</span>
<span class="na">WantedBy</span><span class="o">=</span><span class="s">multi-user.target</span>
</code></pre></div>

</details>

```bash title="Runner 4.0.0과 설정 파일 설치"
install -d /root/downloads/runner
cd /root/downloads/runner
curl -fLO https://dl.gitea.com/gitea-runner/4.0.0/gitea-runner-4.0.0-linux-amd64
curl -fLO https://dl.gitea.com/gitea-runner/4.0.0/gitea-runner-4.0.0-linux-amd64.sha256
sha256sum -c gitea-runner-4.0.0-linux-amd64.sha256
install -m 0755 gitea-runner-4.0.0-linux-amd64 /usr/local/bin/gitea-runner
install -m 0640 -o root -g gitea-runner "${CONFIG_SRC}/host/etc/gitea-runner/config.yaml" /etc/gitea-runner/config.yaml
install -m 0644 "${CONFIG_SRC}/host/etc/systemd/system/gitea-runner.service" /etc/systemd/system/gitea-runner.service
gitea-runner --version
```

host 실행, 동시 작업 1개를 사용한다. Raw SHA256 캐시와 containerd 캐시는 Actions의 cache.enabled와 별개다. [Runner 4.0.0](https://blog.gitea.com/release-of-runner-4.0.0/)

Repository의 **Settings → Actions → Runners**에서 등록 Token을 발급받아 아래 대화형 등록에 입력한다.

```bash title="최초 한 번만 Runner 등록"
cd /var/lib/gitea-runner
sudo -u gitea-runner /usr/local/bin/gitea-runner \
  --config /etc/gitea-runner/config.yaml register
```

URL은 새 Gitea, label은 **`contrabass-engine-release:host`**다. Workflow의 runs-on은 `contrabass-engine-release`이며 `:host`를 붙이지 않는다. label이 맞지 않으면 YAML뿐 아니라 실제 등록 label과 서비스가 읽는 config 경로도 확인한다.

```bash title="등록 파일과 VM 접속용 RSA 키"
chown gitea-runner:gitea-runner /var/lib/gitea-runner/.runner
chmod 0600 /var/lib/gitea-runner/.runner
install -d -m 0700 -o gitea-runner -g gitea-runner /var/lib/gitea-runner/.ssh
sudo -u gitea-runner ssh-keygen -t rsa -b 4096 -N '' \
  -f /var/lib/gitea-runner/.ssh/id_rsa
```

기존 키가 있으면 덮어쓰지 않는다. 공개키는 VMware Tools 초기화 스크립트가 VM에 등록하고, 개인키는 Runner의 SSH 접속에 사용한다. VM root 비밀번호나 Nexus 비밀번호와는 다르다.

아직 Runner를 기동하지 않는다. 빌더·HAProxy·시험 파일을 먼저 준비한다.

---

## 9. 빌더·root wrapper·고객사 템플릿 배치

<details class="analysis-toggle" markdown="1">
<summary>/opt/gitea/bundle-builder/common.sh — 전체 내용</summary>

<div class="highlight" data-source-path="host/opt/gitea/bundle-builder/common.sh"><pre><code><span class="ch">#!/bin/bash</span>
<span class="c1"># Shared configuration and helpers. No downloads or mutations when sourced.</span>
<span class="nb">source</span><span class="w"> </span>/etc/gitea-runner-env/bundle-pipeline.env

<span class="c1"># Keep passwords/tokens out of curl's process arguments. FD contents are temporary.</span>
http_curl<span class="o">()</span><span class="w"> </span><span class="o">{</span>
<span class="w">  </span><span class="nb">local</span><span class="w"> </span><span class="nv">tls</span><span class="o">=()</span>
<span class="w">  </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">TLS_SKIP_VERIFY</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="nb">true</span><span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">&amp;&amp;</span><span class="w"> </span><span class="nv">tls</span><span class="o">=(</span>--insecure<span class="o">)</span>
<span class="w">  </span><span class="nb">command</span><span class="w"> </span>curl<span class="w"> </span>--connect-timeout<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">HTTP_CONNECT_TIMEOUT</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">tls</span><span class="p">[@]</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="nv">$@</span><span class="s2">"</span>
<span class="o">}</span>

curl_config_value<span class="o">()</span><span class="w"> </span><span class="o">{</span>
<span class="w">  </span><span class="nb">local</span><span class="w"> </span><span class="nv">value</span><span class="o">=</span><span class="s2">"</span><span class="nv">$1</span><span class="s2">"</span>
<span class="w">  </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">value</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>!<span class="o">=</span><span class="w"> </span>*<span class="s1">$'\n'</span>*<span class="w"> </span><span class="o">&amp;&amp;</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">value</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>!<span class="o">=</span><span class="w"> </span>*<span class="s1">$'\r'</span>*<span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="k">return</span><span class="w"> </span><span class="m">1</span>
<span class="w">  </span><span class="nv">value</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">value</span><span class="p">//</span><span class="se">\\</span><span class="p">/</span><span class="se">\\\\</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span><span class="nb">printf</span><span class="w"> </span><span class="s1">'%s'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">value</span><span class="p">//</span><span class="se">\"</span><span class="p">/</span><span class="se">\\\"</span><span class="si">}</span><span class="s2">"</span>
<span class="o">}</span>

nexus_curl<span class="o">()</span><span class="w"> </span><span class="o">{</span>
<span class="w">  </span><span class="nb">local</span><span class="w"> </span>credential
<span class="w">  </span><span class="nv">credential</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>curl_config_value<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_USER</span><span class="p">:?</span><span class="si">}</span><span class="s2">:</span><span class="si">${</span><span class="nv">NEXUS_PASSWORD</span><span class="p">:?</span><span class="si">}</span><span class="s2">"</span><span class="k">)</span><span class="s2">"</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="k">return</span><span class="w"> </span><span class="m">1</span>
<span class="w">  </span>http_curl<span class="w"> </span>--config<span class="w"> </span>&lt;<span class="o">(</span><span class="nb">printf</span><span class="w"> </span><span class="s1">'user = "%s"\n'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">credential</span><span class="si">}</span><span class="s2">"</span><span class="o">)</span><span class="w"> </span><span class="s2">"</span><span class="nv">$@</span><span class="s2">"</span>
<span class="o">}</span>

export_test_inputs<span class="o">()</span><span class="w"> </span><span class="o">{</span>
<span class="w">  </span><span class="nb">local</span><span class="w"> </span><span class="nv">info</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">1</span><span class="k">:-</span><span class="nv">staging</span><span class="p">-info.yaml</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="nv">manifest_info</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">2</span><span class="k">:-</span><span class="nv">release</span><span class="p">-info.yaml</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>path<span class="w"> </span>sha<span class="w"> </span>id
<span class="w">  </span><span class="nv">path</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>yaml_value<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">info</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>bundle_path<span class="k">)</span><span class="s2">"</span>
<span class="w">  </span><span class="nv">sha</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>yaml_value<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">info</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>bundle_sha256<span class="k">)</span><span class="s2">"</span>
<span class="w">  </span><span class="nv">id</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>yaml_value<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">manifest_info</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>manifest_id<span class="k">)</span><span class="s2">"</span>
<span class="w">  </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">sha</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">=</span>~<span class="w"> </span>^<span class="o">[</span><span class="m">0</span>-9a-f<span class="o">]{</span><span class="m">64</span><span class="o">}</span>$<span class="w"> </span><span class="o">&amp;&amp;</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">id</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">=</span>~<span class="w"> </span>^<span class="o">[</span>A-Za-z0-9<span class="o">][</span>A-Za-z0-9._-<span class="o">]</span>*$<span class="w"> </span><span class="o">]]</span>
<span class="w">  </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">path</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"candidates/</span><span class="si">${</span><span class="nv">id</span><span class="si">}</span><span class="s2">/</span><span class="si">${</span><span class="nv">sha</span><span class="si">}</span><span class="s2">/contrabass-engine-deploy.tar"</span><span class="w"> </span><span class="o">]]</span>
<span class="w">  </span><span class="nb">test</span><span class="w"> </span>-r<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">TOFU_SSH_PRIVATE_KEY</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span><span class="nb">test</span><span class="w"> </span>-s<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">TOFU_SSH_PUBLIC_KEY</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span><span class="nb">export</span><span class="w"> </span><span class="nv">TF_VAR_bundle_url</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_URL</span><span class="p">%/</span><span class="si">}</span><span class="s2">/repository/</span><span class="si">${</span><span class="nv">STAGING_REPOSITORY</span><span class="si">}</span><span class="s2">/</span><span class="si">${</span><span class="nv">path</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span><span class="nb">export</span><span class="w"> </span><span class="nv">TF_VAR_bundle_sha256</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">sha</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span><span class="nb">export</span><span class="w"> </span><span class="nv">TF_VAR_ssh_private_key_path</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">TOFU_SSH_PRIVATE_KEY</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span><span class="nb">export</span><span class="w"> </span><span class="nv">TF_VAR_ssh_public_key</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>&lt;<span class="s2">"</span><span class="si">${</span><span class="nv">TOFU_SSH_PUBLIC_KEY</span><span class="si">}</span><span class="s2">"</span><span class="k">)</span><span class="s2">"</span>
<span class="w">  </span><span class="nb">export</span><span class="w"> </span><span class="nv">TF_VAR_nexus_user</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_USER</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span><span class="nb">export</span><span class="w"> </span><span class="nv">TF_VAR_nexus_password</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_PASSWORD</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span><span class="nb">export</span><span class="w"> </span><span class="nv">TF_VAR_nexus_skip_verify</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">TLS_SKIP_VERIFY</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span><span class="nb">export</span><span class="w"> </span><span class="nv">TF_IN_AUTOMATION</span><span class="o">=</span><span class="m">1</span><span class="w"> </span><span class="nv">TF_INPUT</span><span class="o">=</span><span class="m">0</span>
<span class="o">}</span>

yaml_value<span class="o">()</span><span class="w"> </span><span class="o">{</span>
<span class="w">  </span>awk<span class="w"> </span>-F<span class="s1">': *'</span><span class="w"> </span>-v<span class="w"> </span><span class="nv">key</span><span class="o">=</span><span class="s2">"</span><span class="nv">$2</span><span class="s2">"</span><span class="w"> </span><span class="s1">'$1 == key {gsub(/"/, "", $2); print $2; exit}'</span><span class="w"> </span><span class="s2">"</span><span class="nv">$1</span><span class="s2">"</span>
<span class="o">}</span>

file_sha256<span class="o">()</span><span class="w"> </span><span class="o">{</span><span class="w"> </span>sha256sum<span class="w"> </span><span class="s2">"</span><span class="nv">$1</span><span class="s2">"</span><span class="w"> </span><span class="p">|</span><span class="w"> </span>awk<span class="w"> </span><span class="s1">'{print $1}'</span><span class="p">;</span><span class="w"> </span><span class="o">}</span>

<span class="c1"># Return 1 only for a missing asset; authentication/server errors stop the job.</span>
nexus_get_optional<span class="o">()</span><span class="w"> </span><span class="o">{</span>
<span class="w">  </span><span class="nb">local</span><span class="w"> </span>status
<span class="w">  </span><span class="nv">status</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>nexus_curl<span class="w"> </span>-sS<span class="w"> </span>-o<span class="w"> </span><span class="s2">"</span><span class="nv">$2</span><span class="s2">"</span><span class="w"> </span>-w<span class="w"> </span><span class="s1">'%{http_code}'</span><span class="w"> </span><span class="s2">"</span><span class="nv">$1</span><span class="s2">"</span><span class="k">)</span><span class="s2">"</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="w">  </span><span class="k">case</span><span class="w"> </span><span class="s2">"</span><span class="nv">$status</span><span class="s2">"</span><span class="w"> </span><span class="k">in</span>
<span class="w">    </span><span class="m">200</span><span class="o">)</span><span class="w"> </span><span class="k">return</span><span class="w"> </span><span class="m">0</span><span class="w"> </span><span class="p">;;</span>
<span class="w">    </span><span class="m">404</span><span class="o">)</span><span class="w"> </span><span class="k">return</span><span class="w"> </span><span class="m">1</span><span class="w"> </span><span class="p">;;</span>
<span class="w">    </span>*<span class="o">)</span><span class="w"> </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Nexus request failed: HTTP </span><span class="nv">$status</span><span class="s2"> (</span><span class="nv">$1</span><span class="s2">)"</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span><span class="p">;</span><span class="w"> </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span><span class="w"> </span><span class="p">;;</span>
<span class="w">  </span><span class="k">esac</span>
<span class="o">}</span>

require_commands<span class="o">()</span><span class="w"> </span><span class="o">{</span>
<span class="w">  </span><span class="nb">local</span><span class="w"> </span>name
<span class="w">  </span><span class="k">for</span><span class="w"> </span>name<span class="w"> </span><span class="k">in</span><span class="w"> </span><span class="s2">"</span><span class="nv">$@</span><span class="s2">"</span><span class="p">;</span><span class="w"> </span><span class="k">do</span>
<span class="w">    </span><span class="nb">command</span><span class="w"> </span>-v<span class="w"> </span><span class="s2">"</span><span class="nv">$name</span><span class="s2">"</span><span class="w"> </span>&gt;/dev/null<span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span><span class="w"> </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Command not found: </span><span class="nv">$name</span><span class="s2">"</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span><span class="p">;</span><span class="w"> </span><span class="k">return</span><span class="w"> </span><span class="m">1</span><span class="p">;</span><span class="w"> </span><span class="o">}</span>
<span class="w">  </span><span class="k">done</span>
<span class="o">}</span>

<span class="c1"># One policy for tag pushes and manual retries. Never treat API failure as skip.</span>
<span class="c1"># Read CURRENT PR labels on each run; do not modify an existing Git tag.</span>
select_test_mode<span class="o">()</span><span class="w"> </span><span class="o">(</span>
<span class="w">  </span><span class="nb">set</span><span class="w"> </span>-euo<span class="w"> </span>pipefail
<span class="w">  </span><span class="nb">local</span><span class="w"> </span><span class="nv">source_dir</span><span class="o">=</span><span class="s2">"</span><span class="nv">$1</span><span class="s2">"</span><span class="w"> </span><span class="nv">tag</span><span class="o">=</span><span class="s2">"</span><span class="nv">$2</span><span class="s2">"</span><span class="w"> </span><span class="nv">output</span><span class="o">=</span><span class="s2">"</span><span class="nv">$3</span><span class="s2">"</span><span class="w"> </span>commit<span class="w"> </span>release<span class="w"> </span>line<span class="w"> </span>api<span class="w"> </span>scratch<span class="w"> </span>status<span class="w"> </span><span class="nv">mode</span><span class="o">=</span>full<span class="w"> </span>reason<span class="w"> </span><span class="nv">pr</span><span class="o">=</span><span class="m">0</span>
<span class="w">  </span>require_commands<span class="w"> </span>curl<span class="w"> </span>jq<span class="w"> </span>git<span class="w"> </span>awk<span class="w"> </span>sort<span class="w"> </span>mktemp
<span class="w">  </span>:<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">REPO_READ_TOKEN</span><span class="p">:?Set REPO_READ_TOKEN secret</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span>:<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">GITEA_URL</span><span class="p">:?</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">GITEA_REPOSITORY</span><span class="p">:?</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">RELEASE_BRANCH</span><span class="p">:?</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">TEST_SKIP_LABEL</span><span class="p">:?</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">tag</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">=</span>~<span class="w"> </span>^v<span class="o">[</span><span class="m">0</span>-9<span class="o">]</span>+<span class="se">\.</span><span class="o">[</span><span class="m">0</span>-9<span class="o">]</span>+<span class="se">\.</span><span class="o">[</span><span class="m">0</span>-9<span class="o">]</span>+$<span class="w"> </span><span class="o">]]</span>
<span class="w">  </span><span class="nv">commit</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>git<span class="w"> </span>-C<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">source_dir</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>rev-parse<span class="w"> </span>HEAD<span class="k">)</span><span class="s2">"</span>
<span class="w">  </span><span class="nv">release</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>yaml_value<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">source_dir</span><span class="si">}</span><span class="s2">/release/manifest.yaml"</span><span class="w"> </span>release<span class="k">)</span><span class="s2">"</span>
<span class="w">  </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">tag</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"v</span><span class="si">${</span><span class="nv">release</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span><span class="w"> </span><span class="nb">echo</span><span class="w"> </span><span class="s1">'Tag and manifest release differ.'</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span><span class="p">;</span><span class="w"> </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span><span class="p">;</span><span class="w"> </span><span class="o">}</span>
<span class="w">  </span><span class="nv">line</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">release</span><span class="p">%.*</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span><span class="nv">api</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">GITEA_URL</span><span class="p">%/</span><span class="si">}</span><span class="s2">/api/v1/repos/</span><span class="si">${</span><span class="nv">GITEA_REPOSITORY</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span><span class="nv">scratch</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>mktemp<span class="w"> </span>-d<span class="k">)</span><span class="s2">"</span>
<span class="w">  </span><span class="nb">trap</span><span class="w"> </span><span class="s1">'rm -rf -- "${scratch}"'</span><span class="w"> </span>EXIT

<span class="w">  </span>gitea_get<span class="o">()</span><span class="w"> </span><span class="o">{</span>
<span class="w">    </span><span class="nv">status</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>http_curl<span class="w"> </span>-sS<span class="w"> </span>--header<span class="w"> </span>@&lt;<span class="o">(</span><span class="nb">printf</span><span class="w"> </span><span class="s1">'Authorization: token %s\n'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">REPO_READ_TOKEN</span><span class="si">}</span><span class="s2">"</span><span class="k">)</span><span class="s2"> \</span>
<span class="s2">      -o "</span><span class="nv">$2</span><span class="s2">" -w '%{http_code}' "</span><span class="si">${</span><span class="nv">api</span><span class="si">}</span>/<span class="nv">$1</span><span class="s2">")"</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="w">    </span><span class="k">case</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">status</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="k">in</span>
<span class="w">      </span><span class="m">200</span><span class="o">)</span><span class="w"> </span><span class="k">return</span><span class="w"> </span><span class="m">0</span><span class="w"> </span><span class="p">;;</span>
<span class="w">      </span><span class="m">404</span><span class="o">)</span><span class="w"> </span><span class="k">return</span><span class="w"> </span><span class="m">1</span><span class="w"> </span><span class="p">;;</span>
<span class="w">      </span>*<span class="o">)</span><span class="w"> </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Gitea lookup failed: HTTP </span><span class="si">${</span><span class="nv">status</span><span class="si">}</span><span class="s2"> (</span><span class="nv">$1</span><span class="s2">). No release."</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span><span class="p">;</span><span class="w"> </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span><span class="w"> </span><span class="p">;;</span>
<span class="w">    </span><span class="k">esac</span>
<span class="w">  </span><span class="o">}</span>

<span class="w">  </span>gitea_get<span class="w"> </span><span class="s2">"tags/</span><span class="si">${</span><span class="nv">tag</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">scratch</span><span class="si">}</span><span class="s2">/tag.json"</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span><span class="w"> </span><span class="nb">echo</span><span class="w"> </span><span class="s1">'Remote tag is missing.'</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span><span class="p">;</span><span class="w"> </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span><span class="p">;</span><span class="w"> </span><span class="o">}</span>
<span class="w">  </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="k">$(</span>jq<span class="w"> </span>-r<span class="w"> </span><span class="s1">'.commit.sha'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">scratch</span><span class="si">}</span><span class="s2">/tag.json"</span><span class="k">)</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">commit</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">    </span><span class="nb">echo</span><span class="w"> </span><span class="s1">'Remote tag and checked-out commit differ.'</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span><span class="p">;</span><span class="w"> </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span><span class="p">;</span>
<span class="w">  </span><span class="o">}</span>

<span class="w">  </span><span class="k">if</span><span class="w"> </span>gitea_get<span class="w"> </span><span class="s2">"commits/</span><span class="si">${</span><span class="nv">commit</span><span class="si">}</span><span class="s2">/pull"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">scratch</span><span class="si">}</span><span class="s2">/pr.json"</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">    </span>jq<span class="w"> </span>-e<span class="w"> </span>--arg<span class="w"> </span>sha<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">commit</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>--arg<span class="w"> </span>branch<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">RELEASE_BRANCH</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">      </span><span class="s1">'.merged == true and .merge_commit_sha == $sha and .base.ref == $branch'</span><span class="w"> </span><span class="se">\</span>
<span class="w">      </span><span class="s2">"</span><span class="si">${</span><span class="nv">scratch</span><span class="si">}</span><span class="s2">/pr.json"</span><span class="w"> </span>&gt;/dev/null<span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">      </span><span class="nb">echo</span><span class="w"> </span><span class="s1">'Tag must point to the approved master PR merge commit.'</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span><span class="p">;</span><span class="w"> </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span><span class="p">;</span>
<span class="w">    </span><span class="o">}</span>
<span class="w">    </span><span class="nv">pr</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>jq<span class="w"> </span>-r<span class="w"> </span><span class="s1">'.number'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">scratch</span><span class="si">}</span><span class="s2">/pr.json"</span><span class="k">)</span><span class="s2">"</span>
<span class="w">    </span>gitea_get<span class="w"> </span><span class="s2">"pulls/</span><span class="si">${</span><span class="nv">pr</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">scratch</span><span class="si">}</span><span class="s2">/pr.json"</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="w">    </span><span class="c1"># A closed PR's head.sha follows its branch. Use the immutable merge parent.</span>
<span class="w">    </span>gitea_get<span class="w"> </span><span class="s2">"git/commits/</span><span class="si">${</span><span class="nv">commit</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">scratch</span><span class="si">}</span><span class="s2">/merge.json"</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="w">    </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="k">$(</span>jq<span class="w"> </span><span class="s1">'.parents | length'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">scratch</span><span class="si">}</span><span class="s2">/merge.json"</span><span class="k">)</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="m">2</span><span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">      </span><span class="nb">echo</span><span class="w"> </span><span class="s1">'Release PRs must use a normal merge commit (not squash/rebase).'</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span><span class="p">;</span><span class="w"> </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span><span class="p">;</span>
<span class="w">    </span><span class="o">}</span>
<span class="w">    </span><span class="nv">reviewed_sha</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>jq<span class="w"> </span>-r<span class="w"> </span><span class="s1">'.parents[1].sha'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">scratch</span><span class="si">}</span><span class="s2">/merge.json"</span><span class="k">)</span><span class="s2">"</span>
<span class="w">    </span><span class="nb">printf</span><span class="w"> </span><span class="s1">'[]\n'</span><span class="w"> </span>&gt;<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">scratch</span><span class="si">}</span><span class="s2">/reviews.json"</span>
<span class="w">    </span><span class="nv">page</span><span class="o">=</span><span class="m">1</span>
<span class="w">    </span><span class="k">while</span><span class="w"> </span>true<span class="p">;</span><span class="w"> </span><span class="k">do</span>
<span class="w">      </span>gitea_get<span class="w"> </span><span class="s2">"pulls/</span><span class="si">${</span><span class="nv">pr</span><span class="si">}</span><span class="s2">/reviews?limit=50&amp;page=</span><span class="si">${</span><span class="nv">page</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">scratch</span><span class="si">}</span><span class="s2">/page.json"</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="w">      </span>jq<span class="w"> </span>-s<span class="w"> </span><span class="s1">'.[0] + .[1]'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">scratch</span><span class="si">}</span><span class="s2">/reviews.json"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">scratch</span><span class="si">}</span><span class="s2">/page.json"</span><span class="w"> </span>&gt;<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">scratch</span><span class="si">}</span><span class="s2">/combined.json"</span>
<span class="w">      </span>mv<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">scratch</span><span class="si">}</span><span class="s2">/combined.json"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">scratch</span><span class="si">}</span><span class="s2">/reviews.json"</span>
<span class="w">      </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="k">$(</span>jq<span class="w"> </span><span class="s1">'length'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">scratch</span><span class="si">}</span><span class="s2">/page.json"</span><span class="k">)</span><span class="s2">"</span><span class="w"> </span>-ge<span class="w"> </span><span class="m">50</span><span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="k">break</span>
<span class="w">      </span><span class="nv">page</span><span class="o">=</span><span class="k">$((</span><span class="nv">page</span><span class="w"> </span><span class="o">+</span><span class="w"> </span><span class="m">1</span><span class="k">))</span>
<span class="w">    </span><span class="k">done</span>
<span class="w">    </span>jq<span class="w"> </span>-e<span class="w"> </span>--arg<span class="w"> </span>sha<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">reviewed_sha</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">      </span><span class="s1">'[.[] | select(.official == true and .dismissed != true and .stale != true</span>
<span class="s1">        and .state == "APPROVED" and .commit_id == $sha)] | length &gt;= 1'</span><span class="w"> </span><span class="se">\</span>
<span class="w">      </span><span class="s2">"</span><span class="si">${</span><span class="nv">scratch</span><span class="si">}</span><span class="s2">/reviews.json"</span><span class="w"> </span>&gt;/dev/null<span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">      </span><span class="nb">echo</span><span class="w"> </span><span class="s1">'PR has no valid approval for its reviewed head commit.'</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span><span class="p">;</span><span class="w"> </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span><span class="p">;</span>
<span class="w">    </span><span class="o">}</span>
<span class="w">    </span><span class="k">if</span><span class="w"> </span>jq<span class="w"> </span>-e<span class="w"> </span>--arg<span class="w"> </span>label<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">TEST_SKIP_LABEL</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">      </span><span class="s1">'any(.labels[]?; .name == $label)'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">scratch</span><span class="si">}</span><span class="s2">/pr.json"</span><span class="w"> </span>&gt;/dev/null<span class="p">;</span><span class="w"> </span><span class="k">then</span><span class="w"> </span><span class="nv">mode</span><span class="o">=</span>skip<span class="p">;</span><span class="w"> </span><span class="k">fi</span>
<span class="w">    </span><span class="nv">reason</span><span class="o">=</span>pr-label
<span class="w">  </span><span class="k">elif</span><span class="w"> </span><span class="o">[[</span><span class="w"> </span><span class="s2">" </span><span class="si">${</span><span class="nv">LEGACY_RELEASE_TAGS</span><span class="k">:-</span><span class="si">}</span><span class="s2"> "</span><span class="w"> </span><span class="o">==</span><span class="w"> </span>*<span class="s2">" </span><span class="si">${</span><span class="nv">tag</span><span class="si">}</span><span class="s2"> "</span>*<span class="w"> </span><span class="o">]]</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">    </span><span class="c1"># Preserve retries of already-published pre-policy versions, without inventing a PR.</span>
<span class="w">    </span><span class="nv">reason</span><span class="o">=</span>historical-tag
<span class="w">  </span><span class="k">else</span>
<span class="w">    </span><span class="c1"># A missing PR is allowed ONLY for an older release line, not new master releases.</span>
<span class="w">    </span>gitea_get<span class="w"> </span><span class="s2">"raw/release/manifest.yaml?ref=</span><span class="si">${</span><span class="nv">RELEASE_BRANCH</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">scratch</span><span class="si">}</span><span class="s2">/master.yaml"</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="w">    </span><span class="nv">master_release</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>yaml_value<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">scratch</span><span class="si">}</span><span class="s2">/master.yaml"</span><span class="w"> </span>release<span class="k">)</span><span class="s2">"</span>
<span class="w">    </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">master_release</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">=</span>~<span class="w"> </span>^<span class="o">[</span><span class="m">0</span>-9<span class="o">]</span>+<span class="se">\.</span><span class="o">[</span><span class="m">0</span>-9<span class="o">]</span>+<span class="se">\.</span><span class="o">[</span><span class="m">0</span>-9<span class="o">]</span>+$<span class="w"> </span><span class="o">]]</span>
<span class="w">    </span><span class="nv">master_line</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">master_release</span><span class="p">%.*</span><span class="si">}</span><span class="s2">"</span>
<span class="w">    </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">line</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>!<span class="o">=</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">master_line</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">      </span><span class="o">&amp;&amp;</span><span class="w"> </span><span class="s2">"</span><span class="k">$(</span><span class="nb">printf</span><span class="w"> </span><span class="s1">'%s\n'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">line</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">master_line</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="p">|</span><span class="w"> </span>sort<span class="w"> </span>-V<span class="w"> </span><span class="p">|</span><span class="w"> </span>head<span class="w"> </span>-1<span class="k">)</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">line</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">      </span><span class="nb">echo</span><span class="w"> </span><span class="s1">'A new current/future-line tag requires an approved master PR.'</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span><span class="p">;</span><span class="w"> </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span><span class="p">;</span>
<span class="w">    </span><span class="o">}</span>
<span class="w">    </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="k">$(</span>git<span class="w"> </span>-C<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">source_dir</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>cat-file<span class="w"> </span>-t<span class="w"> </span><span class="s2">"refs/tags/</span><span class="si">${</span><span class="nv">tag</span><span class="si">}</span><span class="s2">"</span><span class="k">)</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span>tag<span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">      </span><span class="nb">echo</span><span class="w"> </span><span class="s1">'Use an annotated tag: git tag -a VERSION -m MESSAGE.'</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span><span class="p">;</span><span class="w"> </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span><span class="p">;</span>
<span class="w">    </span><span class="o">}</span>
<span class="w">    </span><span class="nv">message</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>git<span class="w"> </span>-C<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">source_dir</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>for-each-ref<span class="w"> </span>--format<span class="o">=</span><span class="s1">'%(contents)'</span><span class="w"> </span><span class="s2">"refs/tags/</span><span class="si">${</span><span class="nv">tag</span><span class="si">}</span><span class="s2">"</span><span class="k">)</span><span class="s2">"</span>
<span class="w">    </span><span class="k">if</span><span class="w"> </span>grep<span class="w"> </span>-Fq<span class="w"> </span><span class="s1">'[skip-test]'</span><span class="w"> </span><span class="o">&lt;&lt;&lt;</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">message</span><span class="si">}</span><span class="s2">"</span><span class="p">;</span><span class="w"> </span><span class="k">then</span><span class="w"> </span><span class="nv">mode</span><span class="o">=</span>skip<span class="p">;</span><span class="w"> </span><span class="k">fi</span>
<span class="w">    </span><span class="nv">reason</span><span class="o">=</span>patch-tag-message
<span class="w">  </span><span class="k">fi</span>

<span class="w">  </span><span class="nb">printf</span><span class="w"> </span><span class="s1">'%s\n'</span><span class="w"> </span><span class="s2">"release_tag: </span><span class="si">${</span><span class="nv">tag</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"git_commit: </span><span class="si">${</span><span class="nv">commit</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">    </span><span class="s2">"test_mode: </span><span class="si">${</span><span class="nv">mode</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"decision_source: </span><span class="si">${</span><span class="nv">reason</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"pull_request: </span><span class="si">${</span><span class="nv">pr</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">output</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Release policy: tag=</span><span class="si">${</span><span class="nv">tag</span><span class="si">}</span><span class="s2">, mode=</span><span class="si">${</span><span class="nv">mode</span><span class="si">}</span><span class="s2">, source=</span><span class="si">${</span><span class="nv">reason</span><span class="si">}</span><span class="s2">, PR=</span><span class="si">${</span><span class="nv">pr</span><span class="si">}</span><span class="s2">"</span>
<span class="o">)</span>
</code></pre></div>

</details>

<details class="analysis-toggle" markdown="1">
<summary>/opt/gitea/bundle-builder/publish-manifest.sh — 전체 내용</summary>

<div class="highlight" data-source-path="host/opt/gitea/bundle-builder/publish-manifest.sh"><pre><code><span class="ch">#!/bin/bash</span>
<span class="nb">set</span><span class="w"> </span>-euo<span class="w"> </span>pipefail

<span class="nv">manifest</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">1</span><span class="k">:-</span><span class="nv">release</span><span class="p">/manifest.yaml</span><span class="si">}</span><span class="s2">"</span>
<span class="nv">release_info</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">2</span><span class="k">:-</span><span class="nv">release</span><span class="p">-info.yaml</span><span class="si">}</span><span class="s2">"</span>

<span class="nb">source</span><span class="w"> </span><span class="s2">"</span><span class="k">$(</span>dirname<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">BASH_SOURCE</span><span class="p">[0]</span><span class="si">}</span><span class="s2">"</span><span class="k">)</span><span class="s2">/common.sh"</span>
:<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_PASSWORD</span><span class="p">:?Set NEXUS_RUNNER_PASSWORD in Gitea Actions Secrets</span><span class="si">}</span><span class="s2">"</span>
:<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">GITEA_COMMIT</span><span class="p">:?Missing Gitea commit</span><span class="si">}</span><span class="s2">"</span>

require_commands<span class="w"> </span>awk<span class="w"> </span>curl<span class="w"> </span>date<span class="w"> </span>git<span class="w"> </span>sha256sum<span class="w"> </span>sort<span class="w"> </span>mktemp<span class="w"> </span>cmp

<span class="o">[[</span><span class="w"> </span>-s<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">manifest</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">  </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Manifest was not found: </span><span class="si">${</span><span class="nv">manifest</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">  </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="o">}</span>

<span class="nv">release</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>yaml_value<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">manifest</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>release<span class="k">)</span><span class="s2">"</span>
<span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">release</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">=</span>~<span class="w"> </span>^<span class="o">[</span><span class="m">0</span>-9<span class="o">]</span>+<span class="se">\.</span><span class="o">[</span><span class="m">0</span>-9<span class="o">]</span>+<span class="se">\.</span><span class="o">[</span><span class="m">0</span>-9<span class="o">]</span>+$<span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">  </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Invalid release version: </span><span class="si">${</span><span class="nv">release</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">  </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="o">}</span>
grep<span class="w"> </span>-Eq<span class="w"> </span><span class="s1">'^schema_version:[[:space:]]*2$'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">manifest</span><span class="si">}</span><span class="s2">"</span>
grep<span class="w"> </span>-Eq<span class="w"> </span><span class="s1">'^  image: "[^"]+"$'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">manifest</span><span class="si">}</span><span class="s2">"</span>
<span class="k">if</span><span class="w"> </span>grep<span class="w"> </span>-q<span class="w"> </span><span class="s1">'^  archive_sha256:'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">manifest</span><span class="si">}</span><span class="s2">"</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">  </span>grep<span class="w"> </span>-Eq<span class="w"> </span><span class="s1">'^  archive_sha256: "[0-9a-f]{64}"$'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">manifest</span><span class="si">}</span><span class="s2">"</span>
<span class="k">fi</span>
grep<span class="w"> </span>-q<span class="w"> </span><span class="s1">'^artifacts:$'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">manifest</span><span class="si">}</span><span class="s2">"</span>
grep<span class="w"> </span>-q<span class="w"> </span><span class="s1">'^images:$'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">manifest</span><span class="si">}</span><span class="s2">"</span>
grep<span class="w"> </span>-q<span class="w"> </span><span class="s1">'^  - path:'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">manifest</span><span class="si">}</span><span class="s2">"</span>
grep<span class="w"> </span>-q<span class="w"> </span><span class="s1">'^  - name:'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">manifest</span><span class="si">}</span><span class="s2">"</span>
<span class="k">if</span><span class="w"> </span>grep<span class="w"> </span>-E<span class="w"> </span><span class="s1">'^[[:space:]]+(sha256|digest):[[:space:]]*"'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">manifest</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="p">|</span><span class="w"> </span>grep<span class="w"> </span>-Ev<span class="w"> </span><span class="s1">'"(sha256:)?[0-9a-f]{64}"$'</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">  </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Invalid artifact checksum or image digest."</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">  </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="k">fi</span>

<span class="nv">release_line</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">release</span><span class="p">%.*</span><span class="si">}</span><span class="s2">"</span>
<span class="nv">release_tag</span><span class="o">=</span><span class="s2">"v</span><span class="si">${</span><span class="nv">release</span><span class="si">}</span><span class="s2">"</span>
<span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">GITEA_REF_NAME</span><span class="k">:-</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">release_tag</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">  </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Tag and manifest release do not match: </span><span class="si">${</span><span class="nv">GITEA_REF_NAME</span><span class="k">:-</span><span class="nv">empty</span><span class="si">}</span><span class="s2"> != </span><span class="si">${</span><span class="nv">release_tag</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">  </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="o">}</span>

<span class="nv">short_sha</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">GITEA_COMMIT</span><span class="p">:</span><span class="nv">0</span><span class="p">:</span><span class="nv">7</span><span class="si">}</span><span class="s2">"</span>
<span class="nv">commit_epoch</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>git<span class="w"> </span>-C<span class="w"> </span><span class="nb">source</span><span class="w"> </span>show<span class="w"> </span>-s<span class="w"> </span>--format<span class="o">=</span>%ct<span class="w"> </span>HEAD<span class="k">)</span><span class="s2">"</span>
<span class="nv">commit_time</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span><span class="nv">TZ</span><span class="o">=</span>Asia/Seoul<span class="w"> </span>date<span class="w"> </span>-d<span class="w"> </span><span class="s2">"@</span><span class="si">${</span><span class="nv">commit_epoch</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>+%Y%m%d-%H%M%S<span class="k">)</span><span class="s2">"</span>
<span class="nv">manifest_id</span><span class="o">=</span><span class="s2">"manifest-v</span><span class="si">${</span><span class="nv">release</span><span class="si">}</span><span class="s2">-</span><span class="si">${</span><span class="nv">commit_time</span><span class="si">}</span><span class="s2">-</span><span class="si">${</span><span class="nv">short_sha</span><span class="si">}</span><span class="s2">"</span>
<span class="nv">manifest_sha256</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>file_sha256<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">manifest</span><span class="si">}</span><span class="s2">"</span><span class="k">)</span><span class="s2">"</span>
<span class="nv">version_path</span><span class="o">=</span><span class="s2">"releases/</span><span class="si">${</span><span class="nv">release_line</span><span class="si">}</span><span class="s2">/</span><span class="si">${</span><span class="nv">release_tag</span><span class="si">}</span><span class="s2">"</span>
<span class="nv">manifest_path</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">version_path</span><span class="si">}</span><span class="s2">/manifest.yaml"</span>

<span class="nb">printf</span><span class="w"> </span><span class="s1">'%s\n'</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s1">'schema_version: 2'</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s2">"manifest_id: </span><span class="si">${</span><span class="nv">manifest_id</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s2">"release: \"</span><span class="si">${</span><span class="nv">release</span><span class="si">}</span><span class="s2">\""</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s2">"release_line: \"</span><span class="si">${</span><span class="nv">release_line</span><span class="si">}</span><span class="s2">\""</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s2">"release_tag: </span><span class="si">${</span><span class="nv">release_tag</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s2">"git_commit: </span><span class="si">${</span><span class="nv">GITEA_COMMIT</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s2">"git_ref: </span><span class="si">${</span><span class="nv">GITEA_REF_NAME</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s1">'git_ref_type: tag'</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s2">"manifest_sha256: </span><span class="si">${</span><span class="nv">manifest_sha256</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s2">"manifest_path: </span><span class="si">${</span><span class="nv">manifest_path</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span>&gt;<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">release_info</span><span class="si">}</span><span class="s2">"</span>

<span class="nv">repository_url</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_URL</span><span class="p">%/</span><span class="si">}</span><span class="s2">/repository/</span><span class="si">${</span><span class="nv">MANIFEST_REPOSITORY</span><span class="si">}</span><span class="s2">"</span>
<span class="nv">existing_manifest</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>mktemp<span class="k">)</span><span class="s2">"</span>
<span class="nv">downloaded_manifest</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>mktemp<span class="k">)</span><span class="s2">"</span>
cleanup<span class="o">()</span><span class="w"> </span><span class="o">{</span>
<span class="w">  </span>rm<span class="w"> </span>-f<span class="w"> </span>--<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">existing_manifest</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">downloaded_manifest</span><span class="si">}</span><span class="s2">"</span>
<span class="o">}</span>
<span class="nb">trap</span><span class="w"> </span>cleanup<span class="w"> </span>EXIT

<span class="k">if</span><span class="w"> </span>nexus_get_optional<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">repository_url</span><span class="si">}</span><span class="s2">/</span><span class="si">${</span><span class="nv">manifest_path</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">existing_manifest</span><span class="si">}</span><span class="s2">"</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">  </span><span class="nv">existing_sha256</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>sha256sum<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">existing_manifest</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="p">|</span><span class="w"> </span>awk<span class="w"> </span><span class="s1">'{print $1}'</span><span class="k">)</span><span class="s2">"</span>
<span class="w">  </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">existing_sha256</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">manifest_sha256</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">    </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"An immutable manifest already exists with different content: </span><span class="si">${</span><span class="nv">manifest_path</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">    </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="w">  </span><span class="o">}</span>
<span class="w">  </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Reuse existing manifest: </span><span class="si">${</span><span class="nv">manifest_path</span><span class="si">}</span><span class="s2">"</span>
<span class="k">else</span>
<span class="w">  </span>nexus_curl<span class="w"> </span>-fsS<span class="w"> </span>--upload-file<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">manifest</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">    </span><span class="s2">"</span><span class="si">${</span><span class="nv">repository_url</span><span class="si">}</span><span class="s2">/</span><span class="si">${</span><span class="nv">manifest_path</span><span class="si">}</span><span class="s2">"</span>
<span class="k">fi</span>

<span class="k">if</span><span class="w"> </span>nexus_get_optional<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">repository_url</span><span class="si">}</span><span class="s2">/</span><span class="si">${</span><span class="nv">version_path</span><span class="si">}</span><span class="s2">/release-info.yaml"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">existing_manifest</span><span class="si">}</span><span class="s2">"</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">  </span>cmp<span class="w"> </span>-s<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">existing_manifest</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">release_info</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">    </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Release metadata already exists with different content; use a new tag."</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">    </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="w">  </span><span class="o">}</span>
<span class="k">else</span>
<span class="w">  </span>nexus_curl<span class="w"> </span>-fsS<span class="w"> </span>--upload-file<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">release_info</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">    </span><span class="s2">"</span><span class="si">${</span><span class="nv">repository_url</span><span class="si">}</span><span class="s2">/</span><span class="si">${</span><span class="nv">version_path</span><span class="si">}</span><span class="s2">/release-info.yaml"</span>
<span class="k">fi</span>
<span class="c1"># Channel pointers are published only after the Bundle upload succeeds.</span>

nexus_curl<span class="w"> </span>-fsS<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">repository_url</span><span class="si">}</span><span class="s2">/</span><span class="si">${</span><span class="nv">manifest_path</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>-o<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">downloaded_manifest</span><span class="si">}</span><span class="s2">"</span>
<span class="nb">test</span><span class="w"> </span><span class="s2">"</span><span class="k">$(</span>sha256sum<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">downloaded_manifest</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="p">|</span><span class="w"> </span>awk<span class="w"> </span><span class="s1">'{print $1}'</span><span class="k">)</span><span class="s2">"</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">manifest_sha256</span><span class="si">}</span><span class="s2">"</span>
rm<span class="w"> </span>-f<span class="w"> </span>--<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">downloaded_manifest</span><span class="si">}</span><span class="s2">"</span>

<span class="nb">echo</span><span class="w"> </span><span class="s2">"Published manifest : </span><span class="si">${</span><span class="nv">manifest_id</span><span class="si">}</span><span class="s2">"</span>
<span class="nb">echo</span><span class="w"> </span><span class="s2">"Release line       : </span><span class="si">${</span><span class="nv">release_line</span><span class="si">}</span><span class="s2">"</span>
</code></pre></div>

</details>

<details class="analysis-toggle" markdown="1">
<summary>/opt/gitea/bundle-builder/build-bundle.sh — 전체 내용</summary>

<div class="highlight" data-source-path="host/opt/gitea/bundle-builder/build-bundle.sh"><pre><code><span class="ch">#!/bin/bash</span>
<span class="nb">set</span><span class="w"> </span>-euo<span class="w"> </span>pipefail

<span class="nb">source</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">BUNDLE_BUILDER_DIR</span><span class="p">:?</span><span class="si">}</span><span class="s2">/common.sh"</span>
<span class="nv">release_tag</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">1</span><span class="p">:?Release tag required</span><span class="si">}</span><span class="s2">"</span>
<span class="nv">source_dir</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>realpath<span class="w"> </span>-e<span class="w"> </span>--<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">2</span><span class="p">:?Source directory required</span><span class="si">}</span><span class="s2">"</span><span class="k">)</span><span class="s2">"</span>
<span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">source_dir</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">RUNNER_WORKSPACE</span><span class="si">}</span><span class="s2">/"</span>*<span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">  </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Source must be inside RUNNER_WORKSPACE."</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">  </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="o">}</span>
<span class="o">[[</span><span class="w"> </span>-d<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">source_dir</span><span class="si">}</span><span class="s2">/.git"</span><span class="w"> </span><span class="o">&amp;&amp;</span><span class="w"> </span>!<span class="w"> </span>-L<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">source_dir</span><span class="si">}</span><span class="s2">/.git"</span><span class="w"> </span><span class="o">]]</span>
source_git<span class="o">()</span><span class="w"> </span><span class="o">{</span><span class="w"> </span>runuser<span class="w"> </span>-u<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">RUNNER_USER</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>--<span class="w"> </span>git<span class="w"> </span>-C<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">source_dir</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="nv">$@</span><span class="s2">"</span><span class="p">;</span><span class="w"> </span><span class="o">}</span>

:<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_URL</span><span class="p">:?</span><span class="si">}</span><span class="s2">"</span>
:<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_USER</span><span class="p">:?</span><span class="si">}</span><span class="s2">"</span>
:<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_PASSWORD</span><span class="p">:?</span><span class="si">}</span><span class="s2">"</span>
:<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_BASE_IMAGE</span><span class="p">:?</span><span class="si">}</span><span class="s2">"</span>
:<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">TEMPLATE_DIR</span><span class="p">:?</span><span class="si">}</span><span class="s2">"</span>
:<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">BUNDLE_WORK_DIR</span><span class="p">:?</span><span class="si">}</span><span class="s2">"</span>
:<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">RAW_CACHE_DIR</span><span class="p">:?</span><span class="si">}</span><span class="s2">"</span>
<span class="nv">NEXUS_URL</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_URL</span><span class="p">%/</span><span class="si">}</span><span class="s2">"</span>
<span class="nv">NEXUS_REGISTRY</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_URL</span><span class="p">#http://</span><span class="si">}</span><span class="s2">"</span>
<span class="nv">NEXUS_REGISTRY</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_REGISTRY</span><span class="p">#https://</span><span class="si">}</span><span class="s2">"</span>

require_commands<span class="w"> </span>curl<span class="w"> </span>git<span class="w"> </span>nerdctl<span class="w"> </span>sha256sum<span class="w"> </span>tar<span class="w"> </span>awk<span class="w"> </span>jq<span class="w"> </span>install<span class="w"> </span>mktemp<span class="w"> </span>ln<span class="w"> </span>cp<span class="w"> </span>chown<span class="w"> </span>runuser<span class="w"> </span>realpath

<span class="k">for</span><span class="w"> </span>required_file<span class="w"> </span><span class="k">in</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_BASE_IMAGE</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s2">"</span><span class="si">${</span><span class="nv">TEMPLATE_DIR</span><span class="si">}</span><span class="s2">/compose.yaml"</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s2">"</span><span class="si">${</span><span class="nv">TEMPLATE_DIR</span><span class="si">}</span><span class="s2">/nexus.properties"</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s2">"</span><span class="si">${</span><span class="nv">TEMPLATE_DIR</span><span class="si">}</span><span class="s2">/setup-private-environment.sh"</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s2">"</span><span class="si">${</span><span class="nv">TEMPLATE_DIR</span><span class="si">}</span><span class="s2">/deploy.sh"</span><span class="p">;</span><span class="w"> </span><span class="k">do</span>
<span class="w">  </span><span class="o">[[</span><span class="w"> </span>-f<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">required_file</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">    </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"File not found: </span><span class="si">${</span><span class="nv">required_file</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">    </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="w">  </span><span class="o">}</span>
<span class="k">done</span>

<span class="k">if</span><span class="w"> </span><span class="o">[[</span><span class="w"> </span>!<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">release_tag</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">=</span>~<span class="w"> </span>^v<span class="o">[</span><span class="m">0</span>-9<span class="o">]</span>+<span class="se">\.</span><span class="o">[</span><span class="m">0</span>-9<span class="o">]</span>+<span class="se">\.</span><span class="o">[</span><span class="m">0</span>-9<span class="o">]</span>+$<span class="w"> </span><span class="o">]]</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">  </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Invalid release tag: </span><span class="si">${</span><span class="nv">release_tag</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">  </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="k">fi</span>

install<span class="w"> </span>-d<span class="w"> </span>-m<span class="w"> </span><span class="m">0755</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">RAW_CACHE_DIR</span><span class="si">}</span><span class="s2">"</span>
install<span class="w"> </span>-d<span class="w"> </span>-o<span class="w"> </span>root<span class="w"> </span>-g<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">RUNNER_GROUP</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>-m<span class="w"> </span><span class="m">2775</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">BUNDLE_WORK_DIR</span><span class="si">}</span><span class="s2">"</span>
<span class="nv">latest_info</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>mktemp<span class="k">)</span><span class="s2">"</span>
<span class="nv">latest_manifest</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>mktemp<span class="k">)</span><span class="s2">"</span>
<span class="nv">work_root</span><span class="o">=</span><span class="s2">""</span>
<span class="nv">download_tmp</span><span class="o">=</span><span class="s2">""</span>

cleanup<span class="o">()</span><span class="w"> </span><span class="o">{</span>
<span class="w">  </span>rm<span class="w"> </span>-f<span class="w"> </span>--<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">latest_info</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">latest_manifest</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span><span class="o">[[</span><span class="w"> </span>-z<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">download_tmp</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span>rm<span class="w"> </span>-f<span class="w"> </span>--<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">download_tmp</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span><span class="k">if</span><span class="w"> </span><span class="o">[[</span><span class="w"> </span>-n<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">work_root</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">&amp;&amp;</span><span class="w"> </span>-d<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">work_root</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">    </span>rm<span class="w"> </span>-rf<span class="w"> </span>--<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">work_root</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span><span class="k">fi</span>
<span class="o">}</span>
<span class="nb">trap</span><span class="w"> </span>cleanup<span class="w"> </span>EXIT

<span class="nv">release_version</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">release_tag</span><span class="p">#v</span><span class="si">}</span><span class="s2">"</span>
<span class="nv">release_info_path</span><span class="o">=</span><span class="s2">"releases/</span><span class="si">${</span><span class="nv">release_version</span><span class="p">%.*</span><span class="si">}</span><span class="s2">/</span><span class="si">${</span><span class="nv">release_tag</span><span class="si">}</span><span class="s2">/release-info.yaml"</span>

nexus_curl<span class="w"> </span>-fsSL<span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_URL</span><span class="si">}</span><span class="s2">/repository/</span><span class="si">${</span><span class="nv">MANIFEST_REPOSITORY</span><span class="si">}</span><span class="s2">/</span><span class="si">${</span><span class="nv">release_info_path</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span>-o<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">latest_info</span><span class="si">}</span><span class="s2">"</span>

<span class="nv">manifest_id</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>yaml_value<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">latest_info</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>manifest_id<span class="k">)</span><span class="s2">"</span>
<span class="nv">git_ref</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>yaml_value<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">latest_info</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>git_ref<span class="k">)</span><span class="s2">"</span>
<span class="nv">git_commit</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>yaml_value<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">latest_info</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>git_commit<span class="k">)</span><span class="s2">"</span>
<span class="nv">manifest_path</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>yaml_value<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">latest_info</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>manifest_path<span class="k">)</span><span class="s2">"</span>
<span class="nv">expected_manifest_sha</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>yaml_value<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">latest_info</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>manifest_sha256<span class="k">)</span><span class="s2">"</span>

<span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">manifest_id</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">=</span>~<span class="w"> </span>^<span class="o">[</span>A-Za-z0-9<span class="o">][</span>A-Za-z0-9._-<span class="o">]</span>*$<span class="w"> </span><span class="o">]]</span>
<span class="k">if</span><span class="w"> </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">git_ref</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>!<span class="o">=</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">release_tag</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">  </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Release tag mismatch: expected </span><span class="si">${</span><span class="nv">release_tag</span><span class="si">}</span><span class="s2">, got </span><span class="si">${</span><span class="nv">git_ref</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">  </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="k">fi</span>
<span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">manifest_path</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"releases/</span><span class="si">${</span><span class="nv">release_version</span><span class="p">%.*</span><span class="si">}</span><span class="s2">/</span><span class="si">${</span><span class="nv">release_tag</span><span class="si">}</span><span class="s2">/manifest.yaml"</span><span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">  </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Manifest path does not match release tag."</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">  </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="o">}</span>
<span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">git_commit</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">=</span>~<span class="w"> </span>^<span class="o">[</span><span class="m">0</span>-9a-f<span class="o">]{</span><span class="m">40</span><span class="o">}</span>$<span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">  </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Invalid Git commit: </span><span class="si">${</span><span class="nv">git_commit</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">  </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="o">}</span>
<span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">expected_manifest_sha</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">=</span>~<span class="w"> </span>^<span class="o">[</span><span class="m">0</span>-9a-f<span class="o">]{</span><span class="m">64</span><span class="o">}</span>$<span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">  </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Invalid manifest checksum."</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">  </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="o">}</span>

<span class="nv">bundle_name</span><span class="o">=</span><span class="s2">"contrabass-engine-deploy"</span>
<span class="nv">bundle_tar</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">BUNDLE_WORK_DIR</span><span class="si">}</span><span class="s2">/</span><span class="si">${</span><span class="nv">manifest_id</span><span class="si">}</span><span class="s2">.tar"</span>
<span class="nv">checksum_file</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_tar</span><span class="si">}</span><span class="s2">.sha256"</span>
<span class="nv">bundle_url</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_URL</span><span class="si">}</span><span class="s2">/repository/</span><span class="si">${</span><span class="nv">BUNDLE_REPOSITORY</span><span class="si">}</span><span class="s2">/releases/</span><span class="si">${</span><span class="nv">release_version</span><span class="p">%.*</span><span class="si">}</span><span class="s2">/</span><span class="si">${</span><span class="nv">release_tag</span><span class="si">}</span><span class="s2">/</span><span class="si">${</span><span class="nv">bundle_name</span><span class="si">}</span><span class="s2">.tar"</span>
<span class="o">[[</span><span class="w"> </span>!<span class="w"> </span>-L<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_tar</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">&amp;&amp;</span><span class="w"> </span>!<span class="w"> </span>-L<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">checksum_file</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span><span class="w"> </span><span class="nb">echo</span><span class="w"> </span><span class="s1">'Bundle outputs must not be symlinks.'</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span><span class="p">;</span><span class="w"> </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span><span class="p">;</span><span class="w"> </span><span class="o">}</span>
<span class="nv">remote_bundle_status</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>nexus_curl<span class="w"> </span>-sSI<span class="w"> </span>-o<span class="w"> </span>/dev/null<span class="w"> </span>-w<span class="w"> </span><span class="s1">'%{http_code}'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_url</span><span class="si">}</span><span class="s2">"</span><span class="k">)</span><span class="s2">"</span>
<span class="nv">remote_checksum_status</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>nexus_curl<span class="w"> </span>-sSI<span class="w"> </span>-o<span class="w"> </span>/dev/null<span class="w"> </span>-w<span class="w"> </span><span class="s1">'%{http_code}'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_url</span><span class="si">}</span><span class="s2">.sha256"</span><span class="k">)</span><span class="s2">"</span>
<span class="k">if</span><span class="w"> </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">remote_bundle_status</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="m">200</span><span class="w"> </span><span class="o">&amp;&amp;</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">remote_checksum_status</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="m">200</span><span class="w"> </span><span class="o">]]</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">  </span><span class="c1"># A re-run can switch PR labels from skip to full. Restore the SAME TAR,</span>
<span class="w">  </span><span class="c1"># rather than rebuilding it with newer templates or tools.</span>
<span class="w">  </span><span class="nv">expected_bundle_sha</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>nexus_curl<span class="w"> </span>-fsS<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_url</span><span class="si">}</span><span class="s2">.sha256"</span><span class="w"> </span><span class="p">|</span><span class="w"> </span>awk<span class="w"> </span><span class="s1">'{print $1; exit}'</span><span class="k">)</span><span class="s2">"</span>
<span class="w">  </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">expected_bundle_sha</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">=</span>~<span class="w"> </span>^<span class="o">[</span><span class="m">0</span>-9a-f<span class="o">]{</span><span class="m">64</span><span class="o">}</span>$<span class="w"> </span><span class="o">]]</span>
<span class="w">  </span><span class="k">if</span><span class="w"> </span><span class="o">[[</span><span class="w"> </span>!<span class="w"> </span>-s<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_tar</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">    </span><span class="nv">download_tmp</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>mktemp<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">BUNDLE_WORK_DIR</span><span class="si">}</span><span class="s2">/.published-bundle.XXXXXX"</span><span class="k">)</span><span class="s2">"</span>
<span class="w">    </span>nexus_curl<span class="w"> </span>-fsSL<span class="w"> </span>--retry<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">HTTP_RETRY_COUNT</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">      </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_url</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>-o<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">download_tmp</span><span class="si">}</span><span class="s2">"</span>
<span class="w">    </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="k">$(</span>file_sha256<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">download_tmp</span><span class="si">}</span><span class="s2">"</span><span class="k">)</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">expected_bundle_sha</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">      </span><span class="nb">echo</span><span class="w"> </span><span class="s1">'Published bundle checksum mismatch.'</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span><span class="p">;</span><span class="w"> </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span><span class="p">;</span>
<span class="w">    </span><span class="o">}</span>
<span class="w">    </span>mv<span class="w"> </span>--<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">download_tmp</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_tar</span><span class="si">}</span><span class="s2">"</span>
<span class="w">    </span><span class="nv">download_tmp</span><span class="o">=</span><span class="s2">""</span>
<span class="w">  </span><span class="k">fi</span>
<span class="w">  </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="k">$(</span>file_sha256<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_tar</span><span class="si">}</span><span class="s2">"</span><span class="k">)</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">expected_bundle_sha</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span>
<span class="w">  </span><span class="nb">printf</span><span class="w"> </span><span class="s1">'%s  %s\n'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">expected_bundle_sha</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">manifest_id</span><span class="si">}</span><span class="s2">.tar"</span><span class="w"> </span>&gt;<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">checksum_file</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span>chown<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">RUNNER_USER</span><span class="si">}</span><span class="s2">:</span><span class="si">${</span><span class="nv">RUNNER_GROUP</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_tar</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">checksum_file</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Reuse published bundle without rebuilding: </span><span class="si">${</span><span class="nv">bundle_url</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span><span class="nb">exit</span><span class="w"> </span><span class="m">0</span>
<span class="k">fi</span>
<span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">remote_bundle_status</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="m">404</span><span class="w"> </span><span class="o">&amp;&amp;</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">remote_checksum_status</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="m">404</span><span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">  </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Incomplete or inaccessible Nexus bundle: tar=</span><span class="si">${</span><span class="nv">remote_bundle_status</span><span class="si">}</span><span class="s2">, sha256=</span><span class="si">${</span><span class="nv">remote_checksum_status</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">  </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="o">}</span>

<span class="k">if</span><span class="w"> </span><span class="o">[[</span><span class="w"> </span>-s<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_tar</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">&amp;&amp;</span><span class="w"> </span>-s<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">checksum_file</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">  </span><span class="nv">expected_bundle_sha</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>awk<span class="w"> </span><span class="s1">'{print $1; exit}'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">checksum_file</span><span class="si">}</span><span class="s2">"</span><span class="k">)</span><span class="s2">"</span>
<span class="w">  </span><span class="nv">actual_bundle_sha</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>sha256sum<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_tar</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="p">|</span><span class="w"> </span>awk<span class="w"> </span><span class="s1">'{print $1}'</span><span class="k">)</span><span class="s2">"</span>
<span class="w">  </span><span class="k">if</span><span class="w"> </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">actual_bundle_sha</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">expected_bundle_sha</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">    </span>chown<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">RUNNER_USER</span><span class="si">}</span><span class="s2">:</span><span class="si">${</span><span class="nv">RUNNER_GROUP</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_tar</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">checksum_file</span><span class="si">}</span><span class="s2">"</span>
<span class="w">    </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Reuse existing bundle: </span><span class="si">${</span><span class="nv">bundle_tar</span><span class="si">}</span><span class="s2">"</span>
<span class="w">    </span><span class="nb">exit</span><span class="w"> </span><span class="m">0</span>
<span class="w">  </span><span class="k">fi</span>
<span class="w">  </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Existing bundle checksum mismatch: </span><span class="si">${</span><span class="nv">bundle_tar</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">  </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="k">fi</span>
<span class="k">if</span><span class="w"> </span><span class="o">[[</span><span class="w"> </span>-e<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_tar</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">||</span><span class="w"> </span>-e<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">checksum_file</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">  </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Incomplete bundle output already exists: </span><span class="si">${</span><span class="nv">bundle_tar</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">  </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="k">fi</span>

<span class="nv">work_root</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>mktemp<span class="w"> </span>-d<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">BUNDLE_WORK_DIR</span><span class="si">}</span><span class="s2">/.</span><span class="si">${</span><span class="nv">bundle_name</span><span class="si">}</span><span class="s2">.work.XXXXXX"</span><span class="k">)</span><span class="s2">"</span>
<span class="nv">bundle_dir</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">work_root</span><span class="si">}</span><span class="s2">/</span><span class="si">${</span><span class="nv">bundle_name</span><span class="si">}</span><span class="s2">"</span>
install<span class="w"> </span>-d<span class="w"> </span>-m<span class="w"> </span><span class="m">0755</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_dir</span><span class="si">}</span><span class="s2">/git"</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_dir</span><span class="si">}</span><span class="s2">/images"</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_dir</span><span class="si">}</span><span class="s2">/nexus"</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_dir</span><span class="si">}</span><span class="s2">/raw"</span>

nexus_curl<span class="w"> </span>-fsSL<span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_URL</span><span class="si">}</span><span class="s2">/repository/</span><span class="si">${</span><span class="nv">MANIFEST_REPOSITORY</span><span class="si">}</span><span class="s2">/</span><span class="si">${</span><span class="nv">manifest_path</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span>-o<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">latest_manifest</span><span class="si">}</span><span class="s2">"</span>

<span class="nv">actual_manifest_sha</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>sha256sum<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">latest_manifest</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="p">|</span><span class="w"> </span>awk<span class="w"> </span><span class="s1">'{print $1}'</span><span class="k">)</span><span class="s2">"</span>
<span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">actual_manifest_sha</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">expected_manifest_sha</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">  </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Manifest checksum mismatch."</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">  </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="o">}</span>

<span class="nv">nexus_image</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>awk<span class="w"> </span>-F<span class="s1">'"'</span><span class="w"> </span><span class="s1">'/^  image: / {print $2; exit}'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">latest_manifest</span><span class="si">}</span><span class="s2">"</span><span class="k">)</span><span class="s2">"</span>
<span class="nv">expected_archive_sha</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>awk<span class="w"> </span>-F<span class="s1">'"'</span><span class="w"> </span><span class="s1">'/^  archive_sha256: / {print $2; exit}'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">latest_manifest</span><span class="si">}</span><span class="s2">"</span><span class="k">)</span><span class="s2">"</span>
<span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">nexus_image</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span>*/*:*<span class="w"> </span><span class="o">&amp;&amp;</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">expected_archive_sha</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">=</span>~<span class="w"> </span>^<span class="o">[</span><span class="m">0</span>-9a-f<span class="o">]{</span><span class="m">64</span><span class="o">}</span>$<span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">  </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Invalid Nexus image metadata in manifest."</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">  </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="o">}</span>
<span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="k">$(</span>file_sha256<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_BASE_IMAGE</span><span class="si">}</span><span class="s2">"</span><span class="k">)</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">expected_archive_sha</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">  </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Nexus image archive checksum does not match manifest."</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">  </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="o">}</span>
tar<span class="w"> </span>-Oxf<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_BASE_IMAGE</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>manifest.json<span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="p">|</span><span class="w"> </span>jq<span class="w"> </span>-e<span class="w"> </span>--arg<span class="w"> </span>image<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">nexus_image</span><span class="p">#docker.io/</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">      </span><span class="s1">'[.[].RepoTags[]] | index($image) != null'</span><span class="w"> </span>&gt;/dev/null<span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">  </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Nexus image archive tag does not match manifest: </span><span class="si">${</span><span class="nv">nexus_image</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">  </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="o">}</span>

install<span class="w"> </span>-m<span class="w"> </span><span class="m">0644</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">latest_manifest</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_dir</span><span class="si">}</span><span class="s2">/manifest.yaml"</span>
install<span class="w"> </span>-m<span class="w"> </span><span class="m">0644</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">latest_info</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_dir</span><span class="si">}</span><span class="s2">/release-info.yaml"</span>
install<span class="w"> </span>-m<span class="w"> </span><span class="m">0644</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_BASE_IMAGE</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_dir</span><span class="si">}</span><span class="s2">/nexus/nexus-image.tar"</span>
install<span class="w"> </span>-m<span class="w"> </span><span class="m">0644</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">TEMPLATE_DIR</span><span class="si">}</span><span class="s2">/compose.yaml"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_dir</span><span class="si">}</span><span class="s2">/nexus/compose.yaml"</span>
install<span class="w"> </span>-m<span class="w"> </span><span class="m">0644</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">TEMPLATE_DIR</span><span class="si">}</span><span class="s2">/nexus.properties"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_dir</span><span class="si">}</span><span class="s2">/nexus/nexus.properties"</span>
install<span class="w"> </span>-m<span class="w"> </span><span class="m">0755</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">TEMPLATE_DIR</span><span class="si">}</span><span class="s2">/setup-private-environment.sh"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_dir</span><span class="si">}</span><span class="s2">/setup-private-environment.sh"</span>
install<span class="w"> </span>-m<span class="w"> </span><span class="m">0755</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">TEMPLATE_DIR</span><span class="si">}</span><span class="s2">/deploy.sh"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_dir</span><span class="si">}</span><span class="s2">/deploy.sh"</span>

<span class="nb">echo</span><span class="w"> </span><span class="s2">"[1/5] Reuse Workflow source: </span><span class="si">${</span><span class="nv">git_ref</span><span class="si">}</span><span class="s2">"</span>
<span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="k">$(</span>source_git<span class="w"> </span>rev-parse<span class="w"> </span>HEAD<span class="k">)</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">git_commit</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span>
<span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="k">$(</span>source_git<span class="w"> </span>rev-list<span class="w"> </span>--count<span class="w"> </span>HEAD<span class="k">)</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"1"</span><span class="w"> </span><span class="o">]]</span>
<span class="o">[[</span><span class="w"> </span>-z<span class="w"> </span><span class="s2">"</span><span class="k">$(</span>source_git<span class="w"> </span>status<span class="w"> </span>--porcelain<span class="k">)</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span>
<span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="k">$(</span>runuser<span class="w"> </span>-u<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">RUNNER_USER</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>--<span class="w"> </span>sha256sum<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">source_dir</span><span class="si">}</span><span class="s2">/release/manifest.yaml"</span><span class="w"> </span><span class="p">|</span><span class="w"> </span>awk<span class="w"> </span><span class="s1">'{print $1}'</span><span class="k">)</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">expected_manifest_sha</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span>

<span class="c1"># Copy with Runner permissions; keep the shallow .git but not credentials/hooks.</span>
chmod<span class="w"> </span><span class="m">0711</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">work_root</span><span class="si">}</span><span class="s2">"</span>
install<span class="w"> </span>-d<span class="w"> </span>-o<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">RUNNER_USER</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>-g<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">RUNNER_GROUP</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>-m<span class="w"> </span><span class="m">0700</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_dir</span><span class="si">}</span><span class="s2">/git/init-container"</span>
runuser<span class="w"> </span>-u<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">RUNNER_USER</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>--<span class="w"> </span>cp<span class="w"> </span>-a<span class="w"> </span>--no-preserve<span class="o">=</span>ownership<span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s2">"</span><span class="si">${</span><span class="nv">source_dir</span><span class="si">}</span><span class="s2">/."</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_dir</span><span class="si">}</span><span class="s2">/git/init-container/"</span>
chown<span class="w"> </span>root:root<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_dir</span><span class="si">}</span><span class="s2">/git/init-container"</span>
chmod<span class="w"> </span><span class="m">0700</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_dir</span><span class="si">}</span><span class="s2">/git/init-container"</span>
<span class="nv">copied_git</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_dir</span><span class="si">}</span><span class="s2">/git/init-container/.git"</span>
<span class="o">[[</span><span class="w"> </span>-d<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">copied_git</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">&amp;&amp;</span><span class="w"> </span>!<span class="w"> </span>-L<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">copied_git</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span>
rm<span class="w"> </span>-f<span class="w"> </span>--<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">copied_git</span><span class="si">}</span><span class="s2">/config"</span>
<span class="nb">printf</span><span class="w"> </span><span class="s1">'[core]\n\trepositoryformatversion = 0\n\tbare = false\n\tfilemode = true\n'</span><span class="w"> </span>&gt;<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">copied_git</span><span class="si">}</span><span class="s2">/config"</span>
<span class="nb">printf</span><span class="w"> </span><span class="s1">'[remote "origin"]\n\turl = %s\n'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">GITEA_REPO_URL</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;&gt;<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">copied_git</span><span class="si">}</span><span class="s2">/config"</span>
rm<span class="w"> </span>-rf<span class="w"> </span>--<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">copied_git</span><span class="si">}</span><span class="s2">/hooks"</span>
chown<span class="w"> </span>-hR<span class="w"> </span>root:root<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_dir</span><span class="si">}</span><span class="s2">/git/init-container"</span>
chmod<span class="w"> </span>-R<span class="w"> </span>go-w<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_dir</span><span class="si">}</span><span class="s2">/git/init-container"</span>
chmod<span class="w"> </span><span class="m">0755</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_dir</span><span class="si">}</span><span class="s2">/git/init-container"</span>

<span class="nb">echo</span><span class="w"> </span><span class="s2">"[2/5] Restore Raw artifacts from SHA256 cache"</span>
awk<span class="w"> </span>-F<span class="s1">'"'</span><span class="w"> </span><span class="s1">'</span>
<span class="s1">  /^  - path:/ {path=$2}</span>
<span class="s1">  /^    sha256:/ &amp;&amp; path != "" {print path "|" $2; path=""}</span>
<span class="s1">'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_dir</span><span class="si">}</span><span class="s2">/manifest.yaml"</span><span class="w"> </span><span class="p">|</span>
<span class="k">while</span><span class="w"> </span><span class="nv">IFS</span><span class="o">=</span><span class="s1">'|'</span><span class="w"> </span><span class="nb">read</span><span class="w"> </span>-r<span class="w"> </span>artifact_path<span class="w"> </span>expected_sha<span class="p">;</span><span class="w"> </span><span class="k">do</span>
<span class="w">  </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">expected_sha</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">=</span>~<span class="w"> </span>^<span class="o">[</span><span class="m">0</span>-9a-f<span class="o">]{</span><span class="m">64</span><span class="o">}</span>$<span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">    </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Invalid artifact checksum: </span><span class="si">${</span><span class="nv">artifact_path</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">    </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="w">  </span><span class="o">}</span>
<span class="w">  </span><span class="k">case</span><span class="w"> </span><span class="s2">"/</span><span class="si">${</span><span class="nv">artifact_path</span><span class="si">}</span><span class="s2">/"</span><span class="w"> </span><span class="k">in</span>
<span class="w">    </span>*/../*<span class="p">|</span>*/./*<span class="o">)</span>
<span class="w">      </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Invalid artifact path: </span><span class="si">${</span><span class="nv">artifact_path</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">      </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="w">      </span><span class="p">;;</span>
<span class="w">  </span><span class="k">esac</span>
<span class="w">  </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">artifact_path</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>!<span class="o">=</span><span class="w"> </span>/*<span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">    </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Absolute artifact path is not allowed: </span><span class="si">${</span><span class="nv">artifact_path</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">    </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="w">  </span><span class="o">}</span>

<span class="w">  </span><span class="nv">cache_file</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">RAW_CACHE_DIR</span><span class="si">}</span><span class="s2">/</span><span class="si">${</span><span class="nv">expected_sha</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span><span class="nv">destination</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_dir</span><span class="si">}</span><span class="s2">/raw/</span><span class="si">${</span><span class="nv">artifact_path</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span>install<span class="w"> </span>-d<span class="w"> </span>-m<span class="w"> </span><span class="m">0755</span><span class="w"> </span><span class="s2">"</span><span class="k">$(</span>dirname<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">destination</span><span class="si">}</span><span class="s2">"</span><span class="k">)</span><span class="s2">"</span>

<span class="w">  </span><span class="k">if</span><span class="w"> </span><span class="o">[[</span><span class="w"> </span>-f<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">cache_file</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">&amp;&amp;</span>
<span class="w">     </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="k">$(</span>sha256sum<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">cache_file</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="p">|</span><span class="w"> </span>awk<span class="w"> </span><span class="s1">'{print $1}'</span><span class="k">)</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">expected_sha</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">    </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"  [cache] </span><span class="si">${</span><span class="nv">artifact_path</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span><span class="k">else</span>
<span class="w">    </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"  [download] </span><span class="si">${</span><span class="nv">artifact_path</span><span class="si">}</span><span class="s2">"</span>
<span class="w">    </span><span class="nv">cache_temp</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>mktemp<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">RAW_CACHE_DIR</span><span class="si">}</span><span class="s2">/.</span><span class="si">${</span><span class="nv">expected_sha</span><span class="si">}</span><span class="s2">.XXXXXX"</span><span class="k">)</span><span class="s2">"</span>
<span class="w">    </span><span class="k">if</span><span class="w"> </span>!<span class="w"> </span>nexus_curl<span class="w"> </span>-fsSL<span class="w"> </span>--retry<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">HTTP_RETRY_COUNT</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">      </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_URL</span><span class="si">}</span><span class="s2">/repository/</span><span class="si">${</span><span class="nv">RAW_REPOSITORY</span><span class="si">}</span><span class="s2">/</span><span class="si">${</span><span class="nv">artifact_path</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">      </span>-o<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">cache_temp</span><span class="si">}</span><span class="s2">"</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">      </span>rm<span class="w"> </span>-f<span class="w"> </span>--<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">cache_temp</span><span class="si">}</span><span class="s2">"</span>
<span class="w">      </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Download failed: </span><span class="si">${</span><span class="nv">artifact_path</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">      </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="w">    </span><span class="k">fi</span>
<span class="w">    </span><span class="nv">actual_sha</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>sha256sum<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">cache_temp</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="p">|</span><span class="w"> </span>awk<span class="w"> </span><span class="s1">'{print $1}'</span><span class="k">)</span><span class="s2">"</span>
<span class="w">    </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">actual_sha</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">expected_sha</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">      </span>rm<span class="w"> </span>-f<span class="w"> </span>--<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">cache_temp</span><span class="si">}</span><span class="s2">"</span>
<span class="w">      </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Checksum mismatch: </span><span class="si">${</span><span class="nv">artifact_path</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">      </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="w">    </span><span class="o">}</span>
<span class="w">    </span>chmod<span class="w"> </span><span class="m">0644</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">cache_temp</span><span class="si">}</span><span class="s2">"</span>
<span class="w">    </span>mv<span class="w"> </span>-f<span class="w"> </span>--<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">cache_temp</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">cache_file</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span><span class="k">fi</span>

<span class="w">  </span>ln<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">cache_file</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">destination</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="m">2</span>&gt;/dev/null<span class="w"> </span><span class="o">||</span>
<span class="w">    </span>cp<span class="w"> </span>--reflink<span class="o">=</span>auto<span class="w"> </span>--<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">cache_file</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">destination</span><span class="si">}</span><span class="s2">"</span>
<span class="k">done</span>

<span class="nb">echo</span><span class="w"> </span><span class="s2">"[3/5] Verify and pull Docker images"</span>
<span class="nb">export</span><span class="w"> </span><span class="nv">DOCKER_CONFIG</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">work_root</span><span class="si">}</span><span class="s2">/registry-auth"</span>
install<span class="w"> </span>-d<span class="w"> </span>-m<span class="w"> </span><span class="m">0700</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">DOCKER_CONFIG</span><span class="si">}</span><span class="s2">"</span>
<span class="nb">printf</span><span class="w"> </span><span class="s1">'%s'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_PASSWORD</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="p">|</span><span class="w"> </span>nerdctl<span class="w"> </span>login<span class="w"> </span>--username<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_USER</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>--password-stdin<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_REGISTRY</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;/dev/null
<span class="nv">image_map</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_dir</span><span class="si">}</span><span class="s2">/images/image-map.txt"</span>
awk<span class="w"> </span>-F<span class="s1">'"'</span><span class="w"> </span><span class="s1">'</span>
<span class="s1">  /^images:/ {in_images=1; next}</span>
<span class="s1">  in_images &amp;&amp; /^  - name:/ {name=$2}</span>
<span class="s1">  in_images &amp;&amp; /^    tag:/ {tag=$2}</span>
<span class="s1">  in_images &amp;&amp; /^    digest:/ {print name "|" tag "|" $2; name=""; tag=""}</span>
<span class="s1">'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_dir</span><span class="si">}</span><span class="s2">/manifest.yaml"</span><span class="w"> </span><span class="p">|</span>
<span class="k">while</span><span class="w"> </span><span class="nv">IFS</span><span class="o">=</span><span class="s1">'|'</span><span class="w"> </span><span class="nb">read</span><span class="w"> </span>-r<span class="w"> </span>image_name<span class="w"> </span>image_tag<span class="w"> </span>expected_digest<span class="p">;</span><span class="w"> </span><span class="k">do</span>
<span class="w">  </span><span class="nv">source_ref</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_REGISTRY</span><span class="si">}</span><span class="s2">/</span><span class="si">${</span><span class="nv">DOCKER_REPOSITORY</span><span class="si">}</span><span class="s2">/</span><span class="si">${</span><span class="nv">image_name</span><span class="si">}</span><span class="s2">:</span><span class="si">${</span><span class="nv">image_tag</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span><span class="nv">registry_path</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">DOCKER_REPOSITORY</span><span class="si">}</span><span class="s2">/</span><span class="si">${</span><span class="nv">image_name</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span><span class="nv">actual_digest</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>nexus_curl<span class="w"> </span>-fsSI<span class="w"> </span><span class="se">\</span>
<span class="w">    </span>-H<span class="w"> </span><span class="s1">'Accept: application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.index.v1+json'</span><span class="w"> </span><span class="se">\</span>
<span class="w">    </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_URL</span><span class="si">}</span><span class="s2">/v2/</span><span class="si">${</span><span class="nv">registry_path</span><span class="si">}</span><span class="s2">/manifests/</span><span class="si">${</span><span class="nv">image_tag</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">    </span><span class="p">|</span><span class="w"> </span>awk<span class="w"> </span><span class="s1">'BEGIN{IGNORECASE=1} /^Docker-Content-Digest:/{gsub("\\r", "", $2); print $2; exit}'</span><span class="k">)</span><span class="s2">"</span>
<span class="w">  </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">actual_digest</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">expected_digest</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">    </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Digest mismatch: </span><span class="si">${</span><span class="nv">image_name</span><span class="si">}</span><span class="s2">:</span><span class="si">${</span><span class="nv">image_tag</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">    </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="w">  </span><span class="o">}</span>
<span class="w">  </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"  </span><span class="si">${</span><span class="nv">source_ref</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span><span class="nv">pinned_ref</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">source_ref</span><span class="p">%:*</span><span class="si">}</span><span class="s2">@</span><span class="si">${</span><span class="nv">expected_digest</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span>nerdctl<span class="w"> </span>pull<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">pinned_ref</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span>nerdctl<span class="w"> </span>tag<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">pinned_ref</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">source_ref</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span><span class="nb">printf</span><span class="w"> </span><span class="s1">'%s|%s|%s|%s\n'</span><span class="w"> </span><span class="se">\</span>
<span class="w">    </span><span class="s2">"</span><span class="si">${</span><span class="nv">source_ref</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">image_name</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">image_tag</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">expected_digest</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">    </span>&gt;&gt;<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">image_map</span><span class="si">}</span><span class="s2">"</span>
<span class="k">done</span>

<span class="nb">echo</span><span class="w"> </span><span class="s2">"[4/5] Save Docker images"</span>
mapfile<span class="w"> </span>-t<span class="w"> </span>image_refs<span class="w"> </span>&lt;<span class="w"> </span>&lt;<span class="o">(</span>awk<span class="w"> </span>-F<span class="s1">'|'</span><span class="w"> </span><span class="s1">'{print $1}'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">image_map</span><span class="si">}</span><span class="s2">"</span><span class="o">)</span>
<span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${#</span><span class="nv">image_refs</span><span class="p">[@]</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>-gt<span class="w"> </span><span class="m">0</span><span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">  </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"No Docker images were found in the manifest."</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">  </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="o">}</span>
nerdctl<span class="w"> </span>save<span class="w"> </span>-o<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_dir</span><span class="si">}</span><span class="s2">/images/release-images.tar"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">image_refs</span><span class="p">[@]</span><span class="si">}</span><span class="s2">"</span>

<span class="nb">echo</span><span class="w"> </span><span class="s2">"[5/5] Create archive and outer TAR checksum"</span>
<span class="nv">download_tmp</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>mktemp<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">BUNDLE_WORK_DIR</span><span class="si">}</span><span class="s2">/.bundle-output.XXXXXX"</span><span class="k">)</span><span class="s2">"</span>
tar<span class="w"> </span>-C<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">work_root</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>-cf<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">download_tmp</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_name</span><span class="si">}</span><span class="s2">"</span>
mv<span class="w"> </span>-T<span class="w"> </span>--<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">download_tmp</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_tar</span><span class="si">}</span><span class="s2">"</span>
<span class="nv">download_tmp</span><span class="o">=</span><span class="s2">""</span>
<span class="o">(</span>
<span class="w">  </span><span class="nb">cd</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">BUNDLE_WORK_DIR</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span>sha256sum<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">manifest_id</span><span class="si">}</span><span class="s2">.tar"</span><span class="w"> </span>&gt;<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">manifest_id</span><span class="si">}</span><span class="s2">.tar.sha256"</span>
<span class="o">)</span>

chown<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">RUNNER_USER</span><span class="si">}</span><span class="s2">:</span><span class="si">${</span><span class="nv">RUNNER_GROUP</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_tar</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">checksum_file</span><span class="si">}</span><span class="s2">"</span>

rm<span class="w"> </span>-rf<span class="w"> </span>--<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">work_root</span><span class="si">}</span><span class="s2">"</span>
<span class="nv">work_root</span><span class="o">=</span><span class="s2">""</span>

<span class="nb">echo</span>
<span class="nb">echo</span><span class="w"> </span><span class="s2">"Bundle : </span><span class="si">${</span><span class="nv">bundle_tar</span><span class="si">}</span><span class="s2">"</span>
<span class="nb">echo</span><span class="w"> </span><span class="s2">"SHA256: </span><span class="si">${</span><span class="nv">checksum_file</span><span class="si">}</span><span class="s2">"</span>
du<span class="w"> </span>-sh<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_tar</span><span class="si">}</span><span class="s2">"</span>
</code></pre></div>

</details>

<details class="analysis-toggle" markdown="1">
<summary>/opt/gitea/bundle-builder/publish-bundle.sh — 전체 내용</summary>

<div class="highlight" data-source-path="host/opt/gitea/bundle-builder/publish-bundle.sh"><pre><code><span class="ch">#!/bin/bash</span>
<span class="nb">set</span><span class="w"> </span>-euo<span class="w"> </span>pipefail

<span class="nv">release_info</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">1</span><span class="k">:-</span><span class="nv">release</span><span class="p">-info.yaml</span><span class="si">}</span><span class="s2">"</span>
<span class="nb">source</span><span class="w"> </span><span class="s2">"</span><span class="k">$(</span>dirname<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">BASH_SOURCE</span><span class="p">[0]</span><span class="si">}</span><span class="s2">"</span><span class="k">)</span><span class="s2">/common.sh"</span>
:<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_PASSWORD</span><span class="p">:?Set NEXUS_RUNNER_PASSWORD in Gitea Actions Secrets</span><span class="si">}</span><span class="s2">"</span>
<span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">RELEASE_KEEP_COUNT</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">=</span>~<span class="w"> </span>^<span class="o">[</span><span class="m">1</span>-9<span class="o">][</span><span class="m">0</span>-9<span class="o">]</span>*$<span class="w"> </span><span class="o">]]</span>

require_commands<span class="w"> </span>awk<span class="w"> </span>cmp<span class="w"> </span>curl<span class="w"> </span>grep<span class="w"> </span>jq<span class="w"> </span>mktemp<span class="w"> </span>paste<span class="w"> </span>sha256sum<span class="w"> </span>sort<span class="w"> </span>stat<span class="w"> </span>sudo

<span class="o">[[</span><span class="w"> </span>-s<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">release_info</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">  </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Release information was not found: </span><span class="si">${</span><span class="nv">release_info</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">  </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="o">}</span>

<span class="nv">manifest_id</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>yaml_value<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">release_info</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>manifest_id<span class="k">)</span><span class="s2">"</span>
<span class="nv">release</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>yaml_value<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">release_info</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>release<span class="k">)</span><span class="s2">"</span>
<span class="nv">release_line</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>yaml_value<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">release_info</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>release_line<span class="k">)</span><span class="s2">"</span>
<span class="nv">release_tag</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>yaml_value<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">release_info</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>release_tag<span class="k">)</span><span class="s2">"</span>
<span class="nv">git_commit</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>yaml_value<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">release_info</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>git_commit<span class="k">)</span><span class="s2">"</span>
<span class="nv">git_ref</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>yaml_value<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">release_info</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>git_ref<span class="k">)</span><span class="s2">"</span>

<span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">manifest_id</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">=</span>~<span class="w"> </span>^<span class="o">[</span>A-Za-z0-9<span class="o">][</span>A-Za-z0-9._-<span class="o">]</span>*$<span class="w"> </span><span class="o">]]</span>
<span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">release</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">=</span>~<span class="w"> </span>^<span class="o">[</span><span class="m">0</span>-9<span class="o">]</span>+<span class="se">\.</span><span class="o">[</span><span class="m">0</span>-9<span class="o">]</span>+<span class="se">\.</span><span class="o">[</span><span class="m">0</span>-9<span class="o">]</span>+$<span class="w"> </span><span class="o">]]</span>
<span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">release_line</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">release</span><span class="p">%.*</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span>
<span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">release_tag</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"v</span><span class="si">${</span><span class="nv">release</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span>
<span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">git_commit</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">=</span>~<span class="w"> </span>^<span class="o">[</span><span class="m">0</span>-9a-f<span class="o">]{</span><span class="m">40</span><span class="o">}</span>$<span class="w"> </span><span class="o">]]</span>
<span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">git_ref</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">release_tag</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span>

<span class="nv">bundle_name</span><span class="o">=</span><span class="s2">"contrabass-engine-deploy.tar"</span>
<span class="nv">bundle_file</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">BUNDLE_WORK_DIR</span><span class="si">}</span><span class="s2">/</span><span class="si">${</span><span class="nv">manifest_id</span><span class="si">}</span><span class="s2">.tar"</span>
<span class="nv">checksum_file</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_file</span><span class="si">}</span><span class="s2">.sha256"</span>
<span class="nv">version_path</span><span class="o">=</span><span class="s2">"releases/</span><span class="si">${</span><span class="nv">release_line</span><span class="si">}</span><span class="s2">/</span><span class="si">${</span><span class="nv">release_tag</span><span class="si">}</span><span class="s2">"</span>
<span class="nv">bundle_path</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">version_path</span><span class="si">}</span><span class="s2">/</span><span class="si">${</span><span class="nv">bundle_name</span><span class="si">}</span><span class="s2">"</span>

<span class="nv">local_bundle_ready</span><span class="o">=</span><span class="nb">false</span>
<span class="k">if</span><span class="w"> </span><span class="o">[[</span><span class="w"> </span>-s<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_file</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">&amp;&amp;</span><span class="w"> </span>-s<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">checksum_file</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">  </span><span class="nv">local_bundle_ready</span><span class="o">=</span><span class="nb">true</span>
<span class="w">  </span><span class="nv">bundle_sha256</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>sha256sum<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_file</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="p">|</span><span class="w"> </span>awk<span class="w"> </span><span class="s1">'{print $1}'</span><span class="k">)</span><span class="s2">"</span>
<span class="w">  </span><span class="nv">expected_sha256</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>awk<span class="w"> </span><span class="s1">'{print $1; exit}'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">checksum_file</span><span class="si">}</span><span class="s2">"</span><span class="k">)</span><span class="s2">"</span>
<span class="w">  </span><span class="nv">bundle_size_bytes</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>stat<span class="w"> </span>-c<span class="w"> </span><span class="s1">'%s'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_file</span><span class="si">}</span><span class="s2">"</span><span class="k">)</span><span class="s2">"</span>
<span class="w">  </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_sha256</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">expected_sha256</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">    </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Local bundle checksum mismatch."</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">    </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="w">  </span><span class="o">}</span>
<span class="k">elif</span><span class="w"> </span><span class="o">[[</span><span class="w"> </span>-e<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_file</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">||</span><span class="w"> </span>-e<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">checksum_file</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">  </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Incomplete local bundle: </span><span class="si">${</span><span class="nv">bundle_file</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">  </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="k">fi</span>

<span class="nv">repository_url</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_URL</span><span class="p">%/</span><span class="si">}</span><span class="s2">/repository/</span><span class="si">${</span><span class="nv">BUNDLE_REPOSITORY</span><span class="si">}</span><span class="s2">"</span>
<span class="nv">bundle_url</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">repository_url</span><span class="si">}</span><span class="s2">/</span><span class="si">${</span><span class="nv">bundle_path</span><span class="si">}</span><span class="s2">"</span>
<span class="nv">existing_checksum_file</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>mktemp<span class="k">)</span><span class="s2">"</span>
<span class="nb">trap</span><span class="w"> </span><span class="s1">'rm -f -- "${existing_checksum_file}"'</span><span class="w"> </span>EXIT
<span class="nv">remote_checksum</span><span class="o">=</span><span class="s2">""</span>
<span class="k">if</span><span class="w"> </span>nexus_get_optional<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_url</span><span class="si">}</span><span class="s2">.sha256"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">existing_checksum_file</span><span class="si">}</span><span class="s2">"</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">  </span><span class="nv">remote_checksum</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>awk<span class="w"> </span><span class="s1">'{print $1; exit}'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">existing_checksum_file</span><span class="si">}</span><span class="s2">"</span><span class="k">)</span><span class="s2">"</span>
<span class="k">fi</span>

<span class="k">if</span><span class="w"> </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">local_bundle_ready</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="nb">true</span><span class="w"> </span><span class="o">]]</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">  </span><span class="k">if</span><span class="w"> </span><span class="o">[[</span><span class="w"> </span>-n<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">remote_checksum</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">    </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">remote_checksum</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_sha256</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">      </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"An immutable bundle already exists with different content: </span><span class="si">${</span><span class="nv">bundle_path</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">      </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="w">    </span><span class="o">}</span>
<span class="w">    </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Reuse existing Nexus bundle: </span><span class="si">${</span><span class="nv">bundle_path</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span><span class="k">else</span>
<span class="w">    </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Upload bundle: </span><span class="si">${</span><span class="nv">bundle_path</span><span class="si">}</span><span class="s2">"</span>
<span class="w">    </span>nexus_curl<span class="w"> </span>-fsS<span class="w"> </span>--retry<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">HTTP_RETRY_COUNT</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>--upload-file<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_file</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_url</span><span class="si">}</span><span class="s2">"</span>
<span class="w">    </span><span class="nb">printf</span><span class="w"> </span><span class="s1">'%s  %s\n'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_sha256</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_name</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">existing_checksum_file</span><span class="si">}</span><span class="s2">"</span>
<span class="w">    </span>nexus_curl<span class="w"> </span>-fsS<span class="w"> </span>--retry<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">HTTP_RETRY_COUNT</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>--upload-file<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">existing_checksum_file</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_url</span><span class="si">}</span><span class="s2">.sha256"</span>
<span class="w">  </span><span class="k">fi</span>
<span class="k">else</span>
<span class="w">  </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">remote_checksum</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">=</span>~<span class="w"> </span>^<span class="o">[</span><span class="m">0</span>-9a-f<span class="o">]{</span><span class="m">64</span><span class="o">}</span>$<span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">    </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"No complete local or remote bundle exists: </span><span class="si">${</span><span class="nv">bundle_path</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">    </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="w">  </span><span class="o">}</span>
<span class="w">  </span><span class="nv">bundle_sha256</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">remote_checksum</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Finalize existing Nexus bundle without rebuilding: </span><span class="si">${</span><span class="nv">bundle_path</span><span class="si">}</span><span class="s2">"</span>
<span class="k">fi</span>

<span class="nv">remote_size</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>nexus_curl<span class="w"> </span>-fsSI<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_url</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="p">|</span><span class="w"> </span>awk<span class="w"> </span><span class="s1">'BEGIN {IGNORECASE=1} /^Content-Length:/ {gsub("\r", "", $2); print $2; exit}'</span><span class="k">)</span><span class="s2">"</span>
<span class="nv">remote_sha256</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>nexus_curl<span class="w"> </span>-fsS<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_url</span><span class="si">}</span><span class="s2">.sha256"</span><span class="w"> </span><span class="p">|</span><span class="w"> </span>awk<span class="w"> </span><span class="s1">'{print $1; exit}'</span><span class="k">)</span><span class="s2">"</span>
<span class="k">if</span><span class="w"> </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">local_bundle_ready</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="nb">false</span><span class="w"> </span><span class="o">]]</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">  </span><span class="nv">bundle_size_bytes</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">remote_size</span><span class="si">}</span><span class="s2">"</span>
<span class="k">fi</span>
<span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_size_bytes</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">=</span>~<span class="w"> </span>^<span class="o">[</span><span class="m">1</span>-9<span class="o">][</span><span class="m">0</span>-9<span class="o">]</span>*$<span class="w"> </span><span class="o">]]</span>
<span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">remote_size</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_size_bytes</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span>
<span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">remote_sha256</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_sha256</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span>

<span class="nv">bundle_release_info</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>mktemp<span class="k">)</span><span class="s2">"</span>
<span class="nv">assets_file</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>mktemp<span class="k">)</span><span class="s2">"</span>
<span class="nv">response_file</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>mktemp<span class="k">)</span><span class="s2">"</span>
<span class="nv">line_index</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>mktemp<span class="k">)</span><span class="s2">"</span>
<span class="nv">all_index</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>mktemp<span class="k">)</span><span class="s2">"</span>
<span class="nv">keep_file</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>mktemp<span class="k">)</span><span class="s2">"</span>
cleanup<span class="o">()</span><span class="w"> </span><span class="o">{</span>
<span class="w">  </span>rm<span class="w"> </span>-f<span class="w"> </span>--<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">existing_checksum_file</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_release_info</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">assets_file</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">response_file</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">    </span><span class="s2">"</span><span class="si">${</span><span class="nv">line_index</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">all_index</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">keep_file</span><span class="si">}</span><span class="s2">"</span>
<span class="o">}</span>
<span class="nb">trap</span><span class="w"> </span>cleanup<span class="w"> </span>EXIT

<span class="nb">printf</span><span class="w"> </span><span class="s1">'%s\n'</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s1">'schema_version: 2'</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s2">"manifest_id: </span><span class="si">${</span><span class="nv">manifest_id</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s2">"release: \"</span><span class="si">${</span><span class="nv">release</span><span class="si">}</span><span class="s2">\""</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s2">"release_line: \"</span><span class="si">${</span><span class="nv">release_line</span><span class="si">}</span><span class="s2">\""</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s2">"release_tag: </span><span class="si">${</span><span class="nv">release_tag</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s2">"git_commit: </span><span class="si">${</span><span class="nv">git_commit</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s2">"git_ref: </span><span class="si">${</span><span class="nv">git_ref</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s1">'git_ref_type: tag'</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s2">"bundle_repository: </span><span class="si">${</span><span class="nv">BUNDLE_REPOSITORY</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s2">"bundle_path: </span><span class="si">${</span><span class="nv">bundle_path</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s2">"bundle_sha256: </span><span class="si">${</span><span class="nv">bundle_sha256</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s2">"bundle_size_bytes: </span><span class="si">${</span><span class="nv">bundle_size_bytes</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span>&gt;<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_release_info</span><span class="si">}</span><span class="s2">"</span>

<span class="k">if</span><span class="w"> </span>nexus_get_optional<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">repository_url</span><span class="si">}</span><span class="s2">/</span><span class="si">${</span><span class="nv">version_path</span><span class="si">}</span><span class="s2">/release-info.yaml"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">response_file</span><span class="si">}</span><span class="s2">"</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">  </span>cmp<span class="w"> </span>-s<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">response_file</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_release_info</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">    </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"An immutable release-info.yaml already exists with different content."</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">    </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="w">  </span><span class="o">}</span>
<span class="k">else</span>
<span class="w">  </span>nexus_curl<span class="w"> </span>-fsS<span class="w"> </span>--upload-file<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_release_info</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">    </span><span class="s2">"</span><span class="si">${</span><span class="nv">repository_url</span><span class="si">}</span><span class="s2">/</span><span class="si">${</span><span class="nv">version_path</span><span class="si">}</span><span class="s2">/release-info.yaml"</span>
<span class="k">fi</span>

:<span class="w"> </span>&gt;<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">assets_file</span><span class="si">}</span><span class="s2">"</span>
<span class="nv">continuation_token</span><span class="o">=</span><span class="s2">""</span>
<span class="k">while</span><span class="w"> </span>true<span class="p">;</span><span class="w"> </span><span class="k">do</span>
<span class="w">  </span><span class="nv">request</span><span class="o">=(</span>-fsS<span class="w"> </span>--get<span class="w"> </span>--data-urlencode<span class="w"> </span><span class="s2">"repository=</span><span class="si">${</span><span class="nv">BUNDLE_REPOSITORY</span><span class="si">}</span><span class="s2">"</span><span class="o">)</span>
<span class="w">  </span><span class="k">if</span><span class="w"> </span><span class="o">[[</span><span class="w"> </span>-n<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">continuation_token</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">    </span><span class="nv">request</span><span class="o">+=(</span>--data-urlencode<span class="w"> </span><span class="s2">"continuationToken=</span><span class="si">${</span><span class="nv">continuation_token</span><span class="si">}</span><span class="s2">"</span><span class="o">)</span>
<span class="w">  </span><span class="k">fi</span>
<span class="w">  </span>nexus_curl<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">request</span><span class="p">[@]</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_URL</span><span class="p">%/</span><span class="si">}</span><span class="s2">/service/rest/v1/search/assets"</span><span class="w"> </span>-o<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">response_file</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span>jq<span class="w"> </span>-r<span class="w"> </span><span class="s1">'.items[] | [.id, .path] | @tsv'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">response_file</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;&gt;<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">assets_file</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span><span class="nv">continuation_token</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>jq<span class="w"> </span>-r<span class="w"> </span><span class="s1">'.continuationToken // empty'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">response_file</span><span class="si">}</span><span class="s2">"</span><span class="k">)</span><span class="s2">"</span>
<span class="w">  </span><span class="o">[[</span><span class="w"> </span>-n<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">continuation_token</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="k">break</span>
<span class="k">done</span>

awk<span class="w"> </span>-F<span class="w"> </span><span class="s1">'\t'</span><span class="w"> </span>-v<span class="w"> </span><span class="nv">line</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">release_line</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s1">'</span>
<span class="s1">  {</span>
<span class="s1">    path=$2</span>
<span class="s1">    sub(/^\/+/, "", path)</span>
<span class="s1">    split(path, item, "/")</span>
<span class="s1">    if (item[1] == "releases" &amp;&amp; item[2] == line &amp;&amp; item[3] ~ /^v[0-9]+\.[0-9]+\.[0-9]+$/) {</span>
<span class="s1">      print substr(item[3], 2)</span>
<span class="s1">    }</span>
<span class="s1">  }</span>
<span class="s1">'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">assets_file</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="p">|</span><span class="w"> </span>sort<span class="w"> </span>-Vu<span class="w"> </span>-r<span class="w"> </span>&gt;<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">line_index</span><span class="si">}</span><span class="s2">"</span>

<span class="c1"># Nexus search indexing is eventually consistent. Always include the release</span>
<span class="c1"># uploaded by this run so channel/retention calculation does not depend on the</span>
<span class="c1"># search index becoming current immediately.</span>
<span class="nb">printf</span><span class="w"> </span><span class="s1">'%s\n'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">release</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;&gt;<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">line_index</span><span class="si">}</span><span class="s2">"</span>
sort<span class="w"> </span>-Vu<span class="w"> </span>-r<span class="w"> </span>-o<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">line_index</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">line_index</span><span class="si">}</span><span class="s2">"</span>

awk<span class="w"> </span>-F<span class="w"> </span><span class="s1">'\t'</span><span class="w"> </span><span class="s1">'</span>
<span class="s1">  {</span>
<span class="s1">    path=$2</span>
<span class="s1">    sub(/^\/+/, "", path)</span>
<span class="s1">    split(path, item, "/")</span>
<span class="s1">    if (item[1] == "releases" &amp;&amp; item[2] ~ /^[0-9]+\.[0-9]+$/ &amp;&amp; item[3] ~ /^v[0-9]+\.[0-9]+\.[0-9]+$/) {</span>
<span class="s1">      print substr(item[3], 2)</span>
<span class="s1">    }</span>
<span class="s1">  }</span>
<span class="s1">'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">assets_file</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="p">|</span><span class="w"> </span>sort<span class="w"> </span>-Vu<span class="w"> </span>-r<span class="w"> </span>&gt;<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">all_index</span><span class="si">}</span><span class="s2">"</span>

<span class="nb">printf</span><span class="w"> </span><span class="s1">'%s\n'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">release</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;&gt;<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">all_index</span><span class="si">}</span><span class="s2">"</span>
sort<span class="w"> </span>-Vu<span class="w"> </span>-r<span class="w"> </span>-o<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">all_index</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">all_index</span><span class="si">}</span><span class="s2">"</span>

awk<span class="w"> </span>-v<span class="w"> </span><span class="nv">limit</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">RELEASE_KEEP_COUNT</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s1">'NR &lt;= limit {print "v" $0}'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">line_index</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">keep_file</span><span class="si">}</span><span class="s2">"</span>
<span class="nv">latest_line_release</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>awk<span class="w"> </span><span class="s1">'NR == 1 {print; exit}'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">line_index</span><span class="si">}</span><span class="s2">"</span><span class="k">)</span><span class="s2">"</span>
<span class="nv">current_release</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>awk<span class="w"> </span><span class="s1">'NR == 1 {print; exit}'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">all_index</span><span class="si">}</span><span class="s2">"</span><span class="k">)</span><span class="s2">"</span>

update_manifest_pointer<span class="o">()</span><span class="w"> </span><span class="o">{</span>
<span class="w">  </span><span class="nb">local</span><span class="w"> </span><span class="nv">channel</span><span class="o">=</span><span class="s2">"</span><span class="nv">$1</span><span class="s2">"</span><span class="w"> </span>manifest_copy
<span class="w">  </span><span class="nv">manifest_copy</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">response_file</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span><span class="nb">local</span><span class="w"> </span><span class="nv">manifest_url</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_URL</span><span class="p">%/</span><span class="si">}</span><span class="s2">/repository/</span><span class="si">${</span><span class="nv">MANIFEST_REPOSITORY</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span>nexus_curl<span class="w"> </span>-fsS<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">manifest_url</span><span class="si">}</span><span class="s2">/</span><span class="si">${</span><span class="nv">version_path</span><span class="si">}</span><span class="s2">/manifest.yaml"</span><span class="w"> </span>-o<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">manifest_copy</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="k">$(</span>file_sha256<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">manifest_copy</span><span class="si">}</span><span class="s2">"</span><span class="k">)</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"</span><span class="k">$(</span>yaml_value<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">release_info</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>manifest_sha256<span class="k">)</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span>
<span class="w">  </span>nexus_curl<span class="w"> </span>-fsS<span class="w"> </span>--upload-file<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">manifest_copy</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">manifest_url</span><span class="si">}</span><span class="s2">/channels/</span><span class="si">${</span><span class="nv">channel</span><span class="si">}</span><span class="s2">/manifest.yaml"</span>
<span class="w">  </span>nexus_curl<span class="w"> </span>-fsS<span class="w"> </span>--upload-file<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">release_info</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">manifest_url</span><span class="si">}</span><span class="s2">/channels/</span><span class="si">${</span><span class="nv">channel</span><span class="si">}</span><span class="s2">/release-info.yaml"</span>
<span class="o">}</span>

<span class="k">if</span><span class="w"> </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">release</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">latest_line_release</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">  </span><span class="nb">printf</span><span class="w"> </span><span class="s1">'%s\n'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_PASSWORD</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="p">|</span>
<span class="w">  </span>sudo<span class="w"> </span>-n<span class="w"> </span>/usr/local/sbin/update-release-alias<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">release_line</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">release_tag</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span>update_manifest_pointer<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">release_line</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span>nexus_curl<span class="w"> </span>-fsS<span class="w"> </span>--upload-file<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_release_info</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">    </span><span class="s2">"</span><span class="si">${</span><span class="nv">repository_url</span><span class="si">}</span><span class="s2">/channels/</span><span class="si">${</span><span class="nv">release_line</span><span class="si">}</span><span class="s2">/release-info.yaml"</span>
<span class="w">  </span>nexus_curl<span class="w"> </span>-fsS<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">repository_url</span><span class="si">}</span><span class="s2">/channels/</span><span class="si">${</span><span class="nv">release_line</span><span class="si">}</span><span class="s2">/release-info.yaml"</span><span class="w"> </span><span class="se">\</span>
<span class="w">    </span><span class="p">|</span><span class="w"> </span>cmp<span class="w"> </span>-s<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_release_info</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>-
<span class="k">fi</span>

<span class="k">if</span><span class="w"> </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">release</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">current_release</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">  </span><span class="nb">printf</span><span class="w"> </span><span class="s1">'%s\n'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_PASSWORD</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="p">|</span>
<span class="w">  </span>sudo<span class="w"> </span>-n<span class="w"> </span>/usr/local/sbin/update-release-alias<span class="w"> </span>current<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">release_tag</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span>update_manifest_pointer<span class="w"> </span>current
<span class="w">  </span>nexus_curl<span class="w"> </span>-fsS<span class="w"> </span>--upload-file<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_release_info</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">    </span><span class="s2">"</span><span class="si">${</span><span class="nv">repository_url</span><span class="si">}</span><span class="s2">/channels/current/release-info.yaml"</span>
<span class="w">  </span>nexus_curl<span class="w"> </span>-fsS<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">repository_url</span><span class="si">}</span><span class="s2">/channels/current/release-info.yaml"</span><span class="w"> </span><span class="se">\</span>
<span class="w">    </span><span class="p">|</span><span class="w"> </span>cmp<span class="w"> </span>-s<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_release_info</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>-
<span class="k">fi</span>

<span class="k">while</span><span class="w"> </span><span class="nv">IFS</span><span class="o">=</span><span class="w"> </span><span class="nb">read</span><span class="w"> </span>-r<span class="w"> </span>indexed_release<span class="p">;</span><span class="w"> </span><span class="k">do</span>
<span class="w">  </span><span class="o">[[</span><span class="w"> </span>-n<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">indexed_release</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="k">continue</span>
<span class="w">  </span><span class="nv">indexed_tag</span><span class="o">=</span><span class="s2">"v</span><span class="si">${</span><span class="nv">indexed_release</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span>grep<span class="w"> </span>-Fxq<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">indexed_tag</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">keep_file</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">&amp;&amp;</span><span class="w"> </span><span class="k">continue</span>

<span class="w">  </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Delete old </span><span class="si">${</span><span class="nv">release_line</span><span class="si">}</span><span class="s2"> release: </span><span class="si">${</span><span class="nv">indexed_tag</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span><span class="k">while</span><span class="w"> </span><span class="nv">IFS</span><span class="o">=</span><span class="s1">$'\t'</span><span class="w"> </span><span class="nb">read</span><span class="w"> </span>-r<span class="w"> </span>asset_id<span class="w"> </span>asset_path<span class="p">;</span><span class="w"> </span><span class="k">do</span>
<span class="w">    </span><span class="nv">normalized_path</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">asset_path</span><span class="p">#/</span><span class="si">}</span><span class="s2">"</span>
<span class="w">    </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">normalized_path</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"releases/</span><span class="si">${</span><span class="nv">release_line</span><span class="si">}</span><span class="s2">/</span><span class="si">${</span><span class="nv">indexed_tag</span><span class="si">}</span><span class="s2">/"</span>*<span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="k">continue</span>
<span class="w">    </span><span class="nv">encoded_asset_id</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>jq<span class="w"> </span>-rn<span class="w"> </span>--arg<span class="w"> </span>value<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">asset_id</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s1">'$value | @uri'</span><span class="k">)</span><span class="s2">"</span>
<span class="w">    </span>nexus_curl<span class="w"> </span>-fsS<span class="w"> </span>-X<span class="w"> </span>DELETE<span class="w"> </span><span class="se">\</span>
<span class="w">      </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_URL</span><span class="p">%/</span><span class="si">}</span><span class="s2">/service/rest/v1/assets/</span><span class="si">${</span><span class="nv">encoded_asset_id</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span><span class="k">done</span><span class="w"> </span>&lt;<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">assets_file</span><span class="si">}</span><span class="s2">"</span>
<span class="k">done</span><span class="w"> </span>&lt;<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">line_index</span><span class="si">}</span><span class="s2">"</span>

nexus_curl<span class="w"> </span>-fsS<span class="w"> </span>--upload-file<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">keep_file</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s2">"</span><span class="si">${</span><span class="nv">repository_url</span><span class="si">}</span><span class="s2">/channels/</span><span class="si">${</span><span class="nv">release_line</span><span class="si">}</span><span class="s2">/retained-releases.txt"</span>
nexus_curl<span class="w"> </span>-fsS<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">repository_url</span><span class="si">}</span><span class="s2">/channels/</span><span class="si">${</span><span class="nv">release_line</span><span class="si">}</span><span class="s2">/retained-releases.txt"</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="p">|</span><span class="w"> </span>cmp<span class="w"> </span>-s<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">keep_file</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>-

<span class="nv">downloaded_info</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>nexus_curl<span class="w"> </span>-fsS<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">repository_url</span><span class="si">}</span><span class="s2">/</span><span class="si">${</span><span class="nv">version_path</span><span class="si">}</span><span class="s2">/release-info.yaml"</span><span class="k">)</span><span class="s2">"</span>
cmp<span class="w"> </span>-s<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_release_info</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&lt;<span class="o">(</span><span class="nb">printf</span><span class="w"> </span><span class="s1">'%s\n'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">downloaded_info</span><span class="si">}</span><span class="s2">"</span><span class="o">)</span>

<span class="k">if</span><span class="w"> </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">local_bundle_ready</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="nb">true</span><span class="w"> </span><span class="o">]]</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">  </span>rm<span class="w"> </span>-f<span class="w"> </span>--<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_file</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">checksum_file</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Removed verified local bundle after Nexus upload."</span>
<span class="k">fi</span>

<span class="nb">echo</span><span class="w"> </span><span class="s2">"Bundle  : </span><span class="si">${</span><span class="nv">bundle_url</span><span class="si">}</span><span class="s2">"</span>
<span class="nb">echo</span><span class="w"> </span><span class="s2">"Channel : </span><span class="si">${</span><span class="nv">repository_url</span><span class="si">}</span><span class="s2">/channels/</span><span class="si">${</span><span class="nv">release_line</span><span class="si">}</span><span class="s2">/release-info.yaml"</span>
<span class="nb">echo</span><span class="w"> </span><span class="s2">"Current : </span><span class="si">${</span><span class="nv">repository_url</span><span class="si">}</span><span class="s2">/channels/current/release-info.yaml"</span>
<span class="nb">echo</span><span class="w"> </span><span class="s2">"Retained: </span><span class="k">$(</span>paste<span class="w"> </span>-sd<span class="w"> </span><span class="s1">', '</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">keep_file</span><span class="si">}</span><span class="s2">"</span><span class="k">)</span><span class="s2">"</span>
</code></pre></div>

</details>

<details class="analysis-toggle" markdown="1">
<summary>/usr/local/sbin/build-private-release — 전체 내용</summary>

<div class="highlight" data-source-path="host/usr/local/sbin/build-private-release"><pre><code><span class="ch">#!/bin/bash</span>
<span class="nb">set</span><span class="w"> </span>-euo<span class="w"> </span>pipefail

<span class="k">if</span><span class="w"> </span><span class="o">[[</span><span class="w"> </span><span class="nv">$#</span><span class="w"> </span>-ne<span class="w"> </span><span class="m">2</span><span class="w"> </span><span class="o">||</span><span class="w"> </span>!<span class="w"> </span><span class="s2">"</span><span class="nv">$1</span><span class="s2">"</span><span class="w"> </span><span class="o">=</span>~<span class="w"> </span>^v<span class="o">[</span><span class="m">0</span>-9<span class="o">]</span>+<span class="se">\.</span><span class="o">[</span><span class="m">0</span>-9<span class="o">]</span>+<span class="se">\.</span><span class="o">[</span><span class="m">0</span>-9<span class="o">]</span>+$<span class="w"> </span><span class="o">]]</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">  </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Usage: build-private-release vMAJOR.MINOR.PATCH SOURCE_DIRECTORY"</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">  </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="k">fi</span>

<span class="c1"># Clear inherited variables before reading the password. Never place it in argv.</span>
<span class="nb">source</span><span class="w"> </span>/etc/gitea-runner-env/bundle-pipeline.env
:<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">BUNDLE_BUILDER_DIR</span><span class="p">:?Set BUNDLE_BUILDER_DIR in bundle-pipeline.env</span><span class="si">}</span><span class="s2">"</span>
<span class="nb">exec</span><span class="w"> </span>env<span class="w"> </span>-i<span class="w"> </span><span class="nv">PATH</span><span class="o">=</span>/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin<span class="w"> </span><span class="nv">HOME</span><span class="o">=</span>/root<span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="nv">BUNDLE_BUILDER_DIR</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">BUNDLE_BUILDER_DIR</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span>flock<span class="w"> </span>-n<span class="w"> </span>/run/lock/private-release-builder.lock<span class="w"> </span>/bin/bash<span class="w"> </span>-c<span class="w"> </span><span class="s1">'</span>
<span class="s1">    set -euo pipefail</span>
<span class="s1">    IFS= read -r NEXUS_PASSWORD || { echo "Nexus password was not provided on stdin." &gt;&amp;2; exit 1; }</span>
<span class="s1">    [[ -n "${NEXUS_PASSWORD}" ]] || { echo "Nexus password is empty." &gt;&amp;2; exit 1; }</span>
<span class="s1">    export NEXUS_PASSWORD</span>
<span class="s1">    exec /bin/bash "${BUNDLE_BUILDER_DIR}/build-bundle.sh" "$@"</span>
<span class="s1">  '</span><span class="w"> </span>build-private-release<span class="w"> </span><span class="s2">"</span><span class="nv">$1</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="nv">$2</span><span class="s2">"</span>
</code></pre></div>

</details>

<details class="analysis-toggle" markdown="1">
<summary>/usr/local/sbin/update-release-alias — 전체 내용</summary>

<div class="highlight" data-source-path="host/usr/local/sbin/update-release-alias"><pre><code><span class="ch">#!/bin/bash</span>
<span class="nb">set</span><span class="w"> </span>-euo<span class="w"> </span>pipefail

<span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="k">$(</span>id<span class="w"> </span>-u<span class="k">)</span><span class="s2">"</span><span class="w"> </span>-eq<span class="w"> </span><span class="m">0</span><span class="w"> </span><span class="o">&amp;&amp;</span><span class="w"> </span><span class="nv">$#</span><span class="w"> </span>-eq<span class="w"> </span><span class="m">2</span><span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">  </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Usage: update-release-alias &lt;current|MAJOR.MINOR&gt; &lt;vMAJOR.MINOR.PATCH&gt;"</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">  </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="o">}</span>
<span class="nb">source</span><span class="w"> </span>/etc/gitea-runner-env/bundle-pipeline.env
<span class="nb">source</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">BUNDLE_BUILDER_DIR</span><span class="si">}</span><span class="s2">/common.sh"</span>
<span class="nv">IFS</span><span class="o">=</span><span class="w"> </span><span class="nb">read</span><span class="w"> </span>-r<span class="w"> </span>NEXUS_PASSWORD

<span class="nv">channel</span><span class="o">=</span><span class="s2">"</span><span class="nv">$1</span><span class="s2">"</span>
<span class="nv">release_tag</span><span class="o">=</span><span class="s2">"</span><span class="nv">$2</span><span class="s2">"</span>
<span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">release_tag</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">=</span>~<span class="w"> </span>^v<span class="o">[</span><span class="m">0</span>-9<span class="o">]</span>+<span class="se">\.</span><span class="o">[</span><span class="m">0</span>-9<span class="o">]</span>+<span class="se">\.</span><span class="o">[</span><span class="m">0</span>-9<span class="o">]</span>+$<span class="w"> </span><span class="o">]]</span>
<span class="nv">release_line</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">release_tag</span><span class="p">#v</span><span class="si">}</span><span class="s2">"</span>
<span class="nv">release_line</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">release_line</span><span class="p">%.*</span><span class="si">}</span><span class="s2">"</span>
<span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">channel</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span>current<span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">channel</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">release_line</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">  </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Channel does not match release: </span><span class="si">${</span><span class="nv">channel</span><span class="si">}</span><span class="s2">, </span><span class="si">${</span><span class="nv">release_tag</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">  </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="o">}</span>

:<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">PUBLIC_RELEASE_URL</span><span class="p">:?</span><span class="si">}</span><span class="s2">"</span>
:<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_URL</span><span class="p">:?</span><span class="si">}</span><span class="s2">"</span>
:<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">MANIFEST_REPOSITORY</span><span class="p">:?</span><span class="si">}</span><span class="s2">"</span>
:<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">BUNDLE_REPOSITORY</span><span class="p">:?</span><span class="si">}</span><span class="s2">"</span>
:<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">HAPROXY_MAP_FILE</span><span class="p">:?</span><span class="si">}</span><span class="s2">"</span>
:<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">HAPROXY_SOCKET</span><span class="p">:?</span><span class="si">}</span><span class="s2">"</span>
<span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">PUBLIC_RELEASE_URL</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span>https://*<span class="w"> </span><span class="o">]]</span>
<span class="o">[[</span><span class="w"> </span>-S<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">HAPROXY_SOCKET</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">&amp;&amp;</span><span class="w"> </span>-f<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">HAPROXY_MAP_FILE</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span>

<span class="nv">alias_path</span><span class="o">=</span><span class="s2">"/repository/</span><span class="si">${</span><span class="nv">MANIFEST_REPOSITORY</span><span class="si">}</span><span class="s2">/channels/</span><span class="si">${</span><span class="nv">channel</span><span class="si">}</span><span class="s2">/contrabass-engine-deploy.tar"</span>
<span class="nv">release_path</span><span class="o">=</span><span class="s2">"/repository/</span><span class="si">${</span><span class="nv">BUNDLE_REPOSITORY</span><span class="si">}</span><span class="s2">/releases/</span><span class="si">${</span><span class="nv">release_line</span><span class="si">}</span><span class="s2">/</span><span class="si">${</span><span class="nv">release_tag</span><span class="si">}</span><span class="s2">/contrabass-engine-deploy.tar"</span>
<span class="nv">target_url</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">PUBLIC_RELEASE_URL</span><span class="p">%/</span><span class="si">}${</span><span class="nv">release_path</span><span class="si">}</span><span class="s2">"</span>
nexus_curl<span class="w"> </span>-fsSI<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_URL</span><span class="p">%/</span><span class="si">}${</span><span class="nv">release_path</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;/dev/null

<span class="nb">exec</span><span class="w"> </span><span class="m">9</span>&gt;/run/lock/release-alias.lock
flock<span class="w"> </span><span class="m">9</span>

<span class="nv">map_temp</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>mktemp<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">HAPROXY_MAP_FILE</span><span class="si">}</span><span class="s2">.XXXXXX"</span><span class="k">)</span><span class="s2">"</span>
<span class="nb">trap</span><span class="w"> </span><span class="s1">'rm -f -- "${map_temp}"'</span><span class="w"> </span>EXIT
<span class="nv">map_action</span><span class="o">=</span>add
<span class="k">if</span><span class="w"> </span>awk<span class="w"> </span>-v<span class="w"> </span><span class="nv">alias_path</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">alias_path</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s1">'$1 == alias_path {found=1} END {exit !found}'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">HAPROXY_MAP_FILE</span><span class="si">}</span><span class="s2">"</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">  </span><span class="nv">map_action</span><span class="o">=</span><span class="nb">set</span>
<span class="k">fi</span>
awk<span class="w"> </span>-v<span class="w"> </span><span class="nv">alias_path</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">alias_path</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s1">'$1 != alias_path'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">HAPROXY_MAP_FILE</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">map_temp</span><span class="si">}</span><span class="s2">"</span>
<span class="nb">printf</span><span class="w"> </span><span class="s1">'%s %s\n'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">alias_path</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">target_url</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;&gt;<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">map_temp</span><span class="si">}</span><span class="s2">"</span>
chmod<span class="w"> </span><span class="m">0644</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">map_temp</span><span class="si">}</span><span class="s2">"</span>
mv<span class="w"> </span>-f<span class="w"> </span>--<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">map_temp</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">HAPROXY_MAP_FILE</span><span class="si">}</span><span class="s2">"</span>

<span class="c1"># Runtime update avoids interrupting an in-progress multi-GiB download.</span>
<span class="nv">response</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span><span class="nb">printf</span><span class="w"> </span><span class="s1">'%s map %s %s %s\n'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">map_action</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">HAPROXY_MAP_FILE</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">alias_path</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">target_url</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="p">|</span><span class="w"> </span>socat<span class="w"> </span>-t<span class="w"> </span><span class="m">5</span><span class="w"> </span>-<span class="w"> </span><span class="s2">"UNIX-CONNECT:</span><span class="si">${</span><span class="nv">HAPROXY_SOCKET</span><span class="si">}</span><span class="s2">"</span><span class="k">)</span><span class="s2">"</span>
<span class="o">[[</span><span class="w"> </span>-z<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">response</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">response</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span>*<span class="s2">"New entry added"</span>*<span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">  </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"HAProxy map update failed: </span><span class="si">${</span><span class="nv">response</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">  </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="o">}</span>

nexus_curl<span class="w"> </span>-fsSIL<span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s2">"</span><span class="si">${</span><span class="nv">PUBLIC_RELEASE_URL</span><span class="p">%/</span><span class="si">}${</span><span class="nv">alias_path</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>-o<span class="w"> </span>/dev/null
<span class="nb">echo</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">alias_path</span><span class="si">}</span><span class="s2"> -&gt; </span><span class="si">${</span><span class="nv">target_url</span><span class="si">}</span><span class="s2">"</span>
</code></pre></div>

</details>

<details class="analysis-toggle" markdown="1">
<summary>/etc/sudoers.d/contrabass-engine-runner — 전체 내용</summary>

<div class="highlight" data-source-path="host/etc/sudoers.d/contrabass-engine-runner"><pre><code><span class="na">gitea-runner ALL</span><span class="o">=</span><span class="s">(root) NOPASSWD: /usr/local/sbin/build-private-release *</span>
<span class="na">gitea-runner ALL</span><span class="o">=</span><span class="s">(root) NOPASSWD: /usr/local/sbin/update-release-alias *</span>
</code></pre></div>

</details>

<details class="analysis-toggle" markdown="1">
<summary>/opt/gitea/bundle-builder/templates/deploy.sh — 전체 내용</summary>

<div class="highlight" data-source-path="host/opt/gitea/bundle-builder/templates/deploy.sh"><pre><code><span class="ch">#!/bin/bash</span>
<span class="nb">set</span><span class="w"> </span>-euo<span class="w"> </span>pipefail

<span class="k">if</span><span class="w"> </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="k">$(</span>id<span class="w"> </span>-u<span class="k">)</span><span class="s2">"</span><span class="w"> </span>-ne<span class="w"> </span><span class="m">0</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="nv">$#</span><span class="w"> </span>-ne<span class="w"> </span><span class="m">2</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="s2">"</span><span class="nv">$2</span><span class="s2">"</span><span class="w"> </span>!<span class="o">=</span><span class="w"> </span><span class="s2">"--accept-eula"</span><span class="w"> </span><span class="o">]]</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">  </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Usage: sudo ./deploy.sh &lt;PRIVATE_NEXUS_IP_OR_DNS&gt; --accept-eula"</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">  </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="k">fi</span>

<span class="nv">nexus_host</span><span class="o">=</span><span class="s2">"</span><span class="nv">$1</span><span class="s2">"</span>
<span class="nb">export</span><span class="w"> </span><span class="nv">NEXUS_PORT</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_PORT</span><span class="k">:-</span><span class="nv">55555</span><span class="si">}</span><span class="s2">"</span>
<span class="nb">export</span><span class="w"> </span><span class="nv">NEXUS_HOME</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_HOME</span><span class="k">:-</span><span class="p">/opt/nexus</span><span class="si">}</span><span class="s2">"</span>
<span class="nb">export</span><span class="w"> </span><span class="nv">NEXUS_DATA</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_DATA</span><span class="k">:-</span><span class="si">${</span><span class="nv">NEXUS_HOME</span><span class="si">}</span><span class="p">/nexus-data</span><span class="si">}</span><span class="s2">"</span>
<span class="nb">export</span><span class="w"> </span><span class="nv">DEPLOY_CONTAINER_NAME</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">DEPLOY_CONTAINER_NAME</span><span class="k">:-</span><span class="nv">okestro</span><span class="p">-os-ansible</span><span class="si">}</span><span class="s2">"</span>
<span class="nv">bundle_dir</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span><span class="nb">cd</span><span class="w"> </span><span class="s2">"</span><span class="k">$(</span>dirname<span class="w"> </span><span class="s2">"</span><span class="nv">$0</span><span class="s2">"</span><span class="k">)</span><span class="s2">"</span><span class="w"> </span><span class="o">&amp;&amp;</span><span class="w"> </span><span class="nb">pwd</span><span class="k">)</span><span class="s2">"</span>

<span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">nexus_host</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">=</span>~<span class="w"> </span>^<span class="o">[</span>A-Za-z0-9<span class="o">][</span>A-Za-z0-9.-<span class="o">]</span>*$<span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">  </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Enter an IP address or DNS name without a scheme or port."</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">  </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="o">}</span>
<span class="c1"># Verify the outer TAR with its .sha256 file before extraction.</span>
<span class="c1"># Deployment checks required files, not every file in the extracted Git tree.</span>

<span class="nb">echo</span><span class="w"> </span><span class="s2">"[1/3] Prepare private Nexus and import release artifacts"</span>
bash<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_dir</span><span class="si">}</span><span class="s2">/setup-private-environment.sh"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">nexus_host</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>--accept-eula

<span class="nb">echo</span><span class="w"> </span><span class="s2">"[2/3] Start Ansible deploy container"</span>
bash<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">bundle_dir</span><span class="si">}</span><span class="s2">/git/init-container/contrabass-engine/install.sh"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">nexus_host</span><span class="si">}</span><span class="s2">:</span><span class="si">${</span><span class="nv">NEXUS_PORT</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>--anonymous

<span class="nb">echo</span><span class="w"> </span><span class="s2">"[3/3] Verify services"</span>
curl<span class="w"> </span>-kfsS<span class="w"> </span>--connect-timeout<span class="w"> </span><span class="m">10</span><span class="w"> </span><span class="s2">"https://</span><span class="si">${</span><span class="nv">nexus_host</span><span class="si">}</span><span class="s2">:</span><span class="si">${</span><span class="nv">NEXUS_PORT</span><span class="si">}</span><span class="s2">/service/rest/v1/status"</span><span class="w"> </span>&gt;/dev/null
<span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="k">$(</span>nerdctl<span class="w"> </span>container<span class="w"> </span>inspect<span class="w"> </span>-f<span class="w"> </span><span class="s1">'&#123;&#123;.State.Status&#125;&#125;'</span><span class="w"> </span>nexus<span class="k">)</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span>running<span class="w"> </span><span class="o">]]</span>
<span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="k">$(</span>nerdctl<span class="w"> </span>container<span class="w"> </span>inspect<span class="w"> </span>-f<span class="w"> </span><span class="s1">'&#123;&#123;.State.Status&#125;&#125;'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">DEPLOY_CONTAINER_NAME</span><span class="si">}</span><span class="s2">"</span><span class="k">)</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span>running<span class="w"> </span><span class="o">]]</span>
<span class="nb">echo</span><span class="w"> </span><span class="s2">"Private Nexus and </span><span class="si">${</span><span class="nv">DEPLOY_CONTAINER_NAME</span><span class="si">}</span><span class="s2"> are running."</span>
</code></pre></div>

</details>

<details class="analysis-toggle" markdown="1">
<summary>/opt/gitea/bundle-builder/templates/setup-private-environment.sh — 전체 내용</summary>

<div class="highlight" data-source-path="host/opt/gitea/bundle-builder/templates/setup-private-environment.sh"><pre><code><span class="ch">#!/bin/bash</span>
<span class="nb">set</span><span class="w"> </span>-euo<span class="w"> </span>pipefail

<span class="k">if</span><span class="w"> </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="k">$(</span>id<span class="w"> </span>-u<span class="k">)</span><span class="s2">"</span><span class="w"> </span>-ne<span class="w"> </span><span class="m">0</span><span class="w"> </span><span class="o">]]</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">  </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Run as root."</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">  </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="k">fi</span>

<span class="k">if</span><span class="w"> </span><span class="o">[[</span><span class="w"> </span><span class="nv">$#</span><span class="w"> </span>-ne<span class="w"> </span><span class="m">2</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="s2">"</span><span class="nv">$2</span><span class="s2">"</span><span class="w"> </span>!<span class="o">=</span><span class="w"> </span><span class="s2">"--accept-eula"</span><span class="w"> </span><span class="o">]]</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">  </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Usage: </span><span class="nv">$0</span><span class="s2"> &lt;PRIVATE_NEXUS_IP_OR_DNS&gt; --accept-eula"</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">  </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="k">fi</span>

<span class="nv">NEXUS_HOST</span><span class="o">=</span><span class="s2">"</span><span class="nv">$1</span><span class="s2">"</span>
<span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_HOST</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>!<span class="o">=</span><span class="w"> </span>*<span class="s2">"://"</span>*<span class="w"> </span><span class="o">&amp;&amp;</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_HOST</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>!<span class="o">=</span><span class="w"> </span>*<span class="s2">":"</span>*<span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">  </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Enter only an IP address or DNS name without a scheme or port."</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">  </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="o">}</span>

<span class="nv">SCRIPT_DIR</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span><span class="nb">cd</span><span class="w"> </span><span class="s2">"</span><span class="k">$(</span>dirname<span class="w"> </span><span class="s2">"</span><span class="nv">$0</span><span class="s2">"</span><span class="k">)</span><span class="s2">"</span><span class="w"> </span><span class="o">&amp;&amp;</span><span class="w"> </span><span class="nb">pwd</span><span class="k">)</span><span class="s2">"</span>
<span class="nv">BUNDLE_DIR</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">SCRIPT_DIR</span><span class="si">}</span><span class="s2">"</span>
<span class="nv">NEXUS_HOME</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_HOME</span><span class="k">:-</span><span class="p">/opt/nexus</span><span class="si">}</span><span class="s2">"</span>
<span class="nv">NEXUS_DATA</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_DATA</span><span class="k">:-</span><span class="si">${</span><span class="nv">NEXUS_HOME</span><span class="si">}</span><span class="p">/nexus-data</span><span class="si">}</span><span class="s2">"</span>
<span class="nv">NEXUS_PORT</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_PORT</span><span class="k">:-</span><span class="nv">55555</span><span class="si">}</span><span class="s2">"</span>
<span class="nv">NEXUS_HEAP</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_HEAP</span><span class="k">:-</span><span class="nv">2703m</span><span class="si">}</span><span class="s2">"</span>
<span class="nv">NEXUS_DIRECT_MEMORY</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_DIRECT_MEMORY</span><span class="k">:-</span><span class="nv">2703m</span><span class="si">}</span><span class="s2">"</span>
<span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_PORT</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">=</span>~<span class="w"> </span>^<span class="o">[</span><span class="m">0</span>-9<span class="o">]</span>+$<span class="w"> </span><span class="o">&amp;&amp;</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_PORT</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>-ge<span class="w"> </span><span class="m">1</span><span class="w"> </span><span class="o">&amp;&amp;</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_PORT</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>-le<span class="w"> </span><span class="m">65535</span><span class="w"> </span><span class="o">]]</span>
<span class="nv">NEXUS_REGISTRY</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_HOST</span><span class="si">}</span><span class="s2">:</span><span class="si">${</span><span class="nv">NEXUS_PORT</span><span class="si">}</span><span class="s2">"</span>
<span class="nv">NEXUS_ENDPOINT</span><span class="o">=</span><span class="s2">"https://</span><span class="si">${</span><span class="nv">NEXUS_REGISTRY</span><span class="si">}</span><span class="s2">"</span>
<span class="nv">API</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_ENDPOINT</span><span class="si">}</span><span class="s2">/service/rest/v1"</span>

<span class="nv">MANIFEST</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">BUNDLE_DIR</span><span class="si">}</span><span class="s2">/manifest.yaml"</span>
<span class="nv">RELEASE_INFO</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">BUNDLE_DIR</span><span class="si">}</span><span class="s2">/release-info.yaml"</span>
<span class="nv">IMAGE_MAP</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">BUNDLE_DIR</span><span class="si">}</span><span class="s2">/images/image-map.txt"</span>
<span class="nv">IMAGE_ARCHIVE</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">BUNDLE_DIR</span><span class="si">}</span><span class="s2">/images/release-images.tar"</span>
<span class="nv">NEXUS_IMAGE_ARCHIVE</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">BUNDLE_DIR</span><span class="si">}</span><span class="s2">/nexus/nexus-image.tar"</span>

<span class="k">for</span><span class="w"> </span>required_file<span class="w"> </span><span class="k">in</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s2">"</span><span class="si">${</span><span class="nv">MANIFEST</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s2">"</span><span class="si">${</span><span class="nv">RELEASE_INFO</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s2">"</span><span class="si">${</span><span class="nv">IMAGE_MAP</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s2">"</span><span class="si">${</span><span class="nv">IMAGE_ARCHIVE</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_IMAGE_ARCHIVE</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s2">"</span><span class="si">${</span><span class="nv">BUNDLE_DIR</span><span class="si">}</span><span class="s2">/nexus/compose.yaml"</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s2">"</span><span class="si">${</span><span class="nv">BUNDLE_DIR</span><span class="si">}</span><span class="s2">/nexus/nexus.properties"</span><span class="p">;</span><span class="w"> </span><span class="k">do</span>
<span class="w">  </span><span class="o">[[</span><span class="w"> </span>-f<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">required_file</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">    </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"File not found: </span><span class="si">${</span><span class="nv">required_file</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">    </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="w">  </span><span class="o">}</span>
<span class="k">done</span>

<span class="nv">NEXUS_IMAGE</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>awk<span class="w"> </span>-F<span class="s1">'"'</span><span class="w"> </span><span class="s1">'/^  image: / {print $2; exit}'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">MANIFEST</span><span class="si">}</span><span class="s2">"</span><span class="k">)</span><span class="s2">"</span>
<span class="nv">expected_nexus_sha</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>awk<span class="w"> </span>-F<span class="s1">'"'</span><span class="w"> </span><span class="s1">'/^  archive_sha256: / {print $2; exit}'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">MANIFEST</span><span class="si">}</span><span class="s2">"</span><span class="k">)</span><span class="s2">"</span>
<span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_IMAGE</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span>*/*:*<span class="w"> </span><span class="o">&amp;&amp;</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">expected_nexus_sha</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">=</span>~<span class="w"> </span>^<span class="o">[</span><span class="m">0</span>-9a-f<span class="o">]{</span><span class="m">64</span><span class="o">}</span>$<span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">  </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Nexus image or archive checksum is missing from manifest.yaml."</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">  </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="o">}</span>
<span class="nb">export</span><span class="w"> </span>NEXUS_IMAGE<span class="w"> </span>NEXUS_PORT<span class="w"> </span>NEXUS_DATA<span class="w"> </span>NEXUS_HEAP<span class="w"> </span>NEXUS_DIRECT_MEMORY

<span class="nb">echo</span><span class="w"> </span><span class="s2">"[1/9] Check release artifacts (outer TAR must be verified before extraction)"</span>
<span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="k">$(</span>sha256sum<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_IMAGE_ARCHIVE</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="p">|</span><span class="w"> </span>awk<span class="w"> </span><span class="s1">'{print $1}'</span><span class="k">)</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">expected_nexus_sha</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">  </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Nexus image archive does not match manifest.yaml."</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">  </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="o">}</span>

<span class="nv">runtime_ready</span><span class="o">=</span><span class="nb">false</span>
<span class="k">if</span><span class="w"> </span><span class="nb">command</span><span class="w"> </span>-v<span class="w"> </span>containerd<span class="w"> </span>&gt;/dev/null<span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="o">&amp;&amp;</span><span class="w"> </span><span class="nb">command</span><span class="w"> </span>-v<span class="w"> </span>nerdctl<span class="w"> </span>&gt;/dev/null<span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="o">&amp;&amp;</span><span class="w"> </span><span class="nb">command</span><span class="w"> </span>-v<span class="w"> </span>runc<span class="w"> </span>&gt;/dev/null<span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="o">&amp;&amp;</span><span class="w"> </span>systemctl<span class="w"> </span>is-active<span class="w"> </span>--quiet<span class="w"> </span>containerd<span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="o">&amp;&amp;</span><span class="w"> </span>nerdctl<span class="w"> </span>info<span class="w"> </span>&gt;/dev/null<span class="w"> </span><span class="m">2</span>&gt;<span class="p">&amp;</span><span class="m">1</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">  </span><span class="nv">runtime_ready</span><span class="o">=</span><span class="nb">true</span>
<span class="k">fi</span>

<span class="nb">echo</span><span class="w"> </span><span class="s2">"[2/9] Prepare container runtime"</span>
modprobe<span class="w"> </span>overlay
modprobe<span class="w"> </span>br_netfilter
<span class="nb">printf</span><span class="w"> </span><span class="s1">'%s\n'</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s1">'net.ipv4.ip_forward = 1'</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s1">'net.bridge.bridge-nf-call-iptables = 1'</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="p">|</span><span class="w"> </span>install<span class="w"> </span>-m<span class="w"> </span><span class="m">0644</span><span class="w"> </span>/dev/stdin<span class="w"> </span>/etc/sysctl.d/99-private-nexus.conf
sysctl<span class="w"> </span>--system<span class="w"> </span>&gt;/dev/null

<span class="k">if</span><span class="w"> </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">runtime_ready</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"true"</span><span class="w"> </span><span class="o">]]</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">  </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Container runtime is already ready."</span>
<span class="k">else</span>
<span class="w">  </span>runtime_file<span class="o">()</span><span class="w"> </span><span class="o">{</span>
<span class="w">    </span><span class="nb">local</span><span class="w"> </span>path
<span class="w">    </span><span class="nv">path</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>awk<span class="w"> </span>-F<span class="s1">'"'</span><span class="w"> </span>-v<span class="w"> </span><span class="nv">prefix</span><span class="o">=</span><span class="s2">"ansible-runtime/</span><span class="nv">$1</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">      </span><span class="s1">'/^  - path:/ &amp;&amp; index($2, prefix) == 1 {print $2; exit}'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">MANIFEST</span><span class="si">}</span><span class="s2">"</span><span class="k">)</span><span class="s2">"</span>
<span class="w">    </span><span class="o">[[</span><span class="w"> </span>-n<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">path</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">&amp;&amp;</span><span class="w"> </span>-f<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">BUNDLE_DIR</span><span class="si">}</span><span class="s2">/raw/</span><span class="si">${</span><span class="nv">path</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">      </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Runtime artifact not found in bundle: </span><span class="si">${</span><span class="nv">prefix</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">      </span><span class="k">return</span><span class="w"> </span><span class="m">1</span>
<span class="w">    </span><span class="o">}</span>
<span class="w">    </span><span class="nb">printf</span><span class="w"> </span><span class="s1">'%s\n'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">BUNDLE_DIR</span><span class="si">}</span><span class="s2">/raw/</span><span class="si">${</span><span class="nv">path</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span><span class="o">}</span>

<span class="w">  </span>tar<span class="w"> </span>-zxf<span class="w"> </span><span class="s2">"</span><span class="k">$(</span>runtime_file<span class="w"> </span>containerd-<span class="k">)</span><span class="s2">"</span><span class="w"> </span>-C<span class="w"> </span>/usr/local
<span class="w">  </span>install<span class="w"> </span>-m<span class="w"> </span><span class="m">0755</span><span class="w"> </span><span class="s2">"</span><span class="k">$(</span>runtime_file<span class="w"> </span>runc.amd64<span class="k">)</span><span class="s2">"</span><span class="w"> </span>/usr/local/bin/runc
<span class="w">  </span>tar<span class="w"> </span>-zxf<span class="w"> </span><span class="s2">"</span><span class="k">$(</span>runtime_file<span class="w"> </span>nerdctl-<span class="k">)</span><span class="s2">"</span><span class="w"> </span>-C<span class="w"> </span>/usr/local/bin
<span class="w">  </span>install<span class="w"> </span>-d<span class="w"> </span>-m<span class="w"> </span><span class="m">0755</span><span class="w"> </span>/opt/cni/bin<span class="w"> </span>/etc/cni/net.d<span class="w"> </span>/etc/containerd<span class="w"> </span>/etc/nerdctl
<span class="w">  </span>tar<span class="w"> </span>-zxf<span class="w"> </span><span class="s2">"</span><span class="k">$(</span>runtime_file<span class="w"> </span>cni-plugins-<span class="k">)</span><span class="s2">"</span><span class="w"> </span>-C<span class="w"> </span>/opt/cni/bin

<span class="w">  </span>install<span class="w"> </span>-m<span class="w"> </span><span class="m">0644</span><span class="w"> </span><span class="se">\</span>
<span class="w">    </span><span class="s2">"</span><span class="si">${</span><span class="nv">BUNDLE_DIR</span><span class="si">}</span><span class="s2">/git/init-container/contrabass-engine/containerd.service"</span><span class="w"> </span><span class="se">\</span>
<span class="w">    </span>/etc/systemd/system/containerd.service
<span class="w">  </span>install<span class="w"> </span>-m<span class="w"> </span><span class="m">0644</span><span class="w"> </span><span class="se">\</span>
<span class="w">    </span><span class="s2">"</span><span class="si">${</span><span class="nv">BUNDLE_DIR</span><span class="si">}</span><span class="s2">/git/init-container/contrabass-engine/nerdctl.toml"</span><span class="w"> </span><span class="se">\</span>
<span class="w">    </span>/etc/nerdctl/nerdctl.toml

<span class="w">  </span>containerd<span class="w"> </span>config<span class="w"> </span>default<span class="w"> </span>&gt;<span class="w"> </span>/etc/containerd/config.toml
<span class="w">  </span>sed<span class="w"> </span>-i<span class="w"> </span><span class="s1">'s/SystemdCgroup = false/SystemdCgroup = true/g'</span><span class="w"> </span>/etc/containerd/config.toml
<span class="w">  </span>systemctl<span class="w"> </span>daemon-reload
<span class="w">  </span>systemctl<span class="w"> </span><span class="nb">enable</span><span class="w"> </span>--now<span class="w"> </span>containerd
<span class="k">fi</span>

systemctl<span class="w"> </span>is-active<span class="w"> </span>--quiet<span class="w"> </span>containerd
nerdctl<span class="w"> </span>info<span class="w"> </span>&gt;/dev/null

<span class="nb">echo</span><span class="w"> </span><span class="s2">"[3/9] Configure private registry TLS"</span>
install<span class="w"> </span>-d<span class="w"> </span>-m<span class="w"> </span><span class="m">0755</span><span class="w"> </span><span class="s2">"/etc/containerd/certs.d/</span><span class="si">${</span><span class="nv">NEXUS_REGISTRY</span><span class="si">}</span><span class="s2">"</span>
<span class="nb">printf</span><span class="w"> </span><span class="s1">'server = "%s"\n\n[host."%s"]\n  capabilities = ["pull", "resolve", "push"]\n  skip_verify = true\n'</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_ENDPOINT</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_ENDPOINT</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span>&gt;<span class="w"> </span><span class="s2">"/etc/containerd/certs.d/</span><span class="si">${</span><span class="nv">NEXUS_REGISTRY</span><span class="si">}</span><span class="s2">/hosts.toml"</span>

<span class="nb">echo</span><span class="w"> </span><span class="s2">"[4/9] Load and start Nexus"</span>
install<span class="w"> </span>-d<span class="w"> </span>-m<span class="w"> </span><span class="m">0755</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_HOME</span><span class="si">}</span><span class="s2">"</span>
install<span class="w"> </span>-d<span class="w"> </span>-m<span class="w"> </span><span class="m">0755</span><span class="w"> </span>-o<span class="w"> </span><span class="m">200</span><span class="w"> </span>-g<span class="w"> </span><span class="m">200</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_DATA</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_DATA</span><span class="si">}</span><span class="s2">/etc"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_DATA</span><span class="si">}</span><span class="s2">/etc/ssl"</span>
install<span class="w"> </span>-m<span class="w"> </span><span class="m">0644</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">BUNDLE_DIR</span><span class="si">}</span><span class="s2">/nexus/compose.yaml"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_HOME</span><span class="si">}</span><span class="s2">/compose.yaml"</span>
install<span class="w"> </span>-m<span class="w"> </span><span class="m">0644</span><span class="w"> </span>-o<span class="w"> </span><span class="m">200</span><span class="w"> </span>-g<span class="w"> </span><span class="m">200</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">BUNDLE_DIR</span><span class="si">}</span><span class="s2">/nexus/nexus.properties"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_DATA</span><span class="si">}</span><span class="s2">/etc/nexus.properties"</span>
sed<span class="w"> </span>-i<span class="w"> </span><span class="s2">"s/^application-port-ssl=.*/application-port-ssl=</span><span class="si">${</span><span class="nv">NEXUS_PORT</span><span class="si">}</span><span class="s2">/"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_DATA</span><span class="si">}</span><span class="s2">/etc/nexus.properties"</span>
<span class="c1"># Non-secret runtime settings keep a later plain compose up consistent.</span>
<span class="nb">printf</span><span class="w"> </span><span class="s1">'NEXUS_IMAGE=%s\nNEXUS_PORT=%s\nNEXUS_DATA=%s\nNEXUS_HEAP=%s\nNEXUS_DIRECT_MEMORY=%s\n'</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_IMAGE</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_PORT</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_DATA</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_HEAP</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_DIRECT_MEMORY</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_HOME</span><span class="si">}</span><span class="s2">/.env"</span>
chmod<span class="w"> </span><span class="m">0644</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_HOME</span><span class="si">}</span><span class="s2">/.env"</span>

nerdctl<span class="w"> </span>image<span class="w"> </span>inspect<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_IMAGE</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;/dev/null<span class="w"> </span><span class="m">2</span>&gt;<span class="p">&amp;</span><span class="m">1</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="o">||</span><span class="w"> </span>nerdctl<span class="w"> </span>load<span class="w"> </span>-i<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_IMAGE_ARCHIVE</span><span class="si">}</span><span class="s2">"</span>

<span class="k">if</span><span class="w"> </span><span class="o">[[</span><span class="w"> </span>!<span class="w"> </span>-f<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_DATA</span><span class="si">}</span><span class="s2">/etc/ssl/keystore.jks"</span><span class="w"> </span><span class="o">]]</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">  </span><span class="nv">short_hostname</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>hostname<span class="w"> </span>-s<span class="k">)</span><span class="s2">"</span>
<span class="w">  </span><span class="k">if</span><span class="w"> </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_HOST</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">=</span>~<span class="w"> </span>^<span class="o">[</span><span class="m">0</span>-9<span class="o">]</span>+<span class="se">\.</span><span class="o">[</span><span class="m">0</span>-9<span class="o">]</span>+<span class="se">\.</span><span class="o">[</span><span class="m">0</span>-9<span class="o">]</span>+<span class="se">\.</span><span class="o">[</span><span class="m">0</span>-9<span class="o">]</span>+$<span class="w"> </span><span class="o">]]</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">    </span><span class="nv">certificate_san</span><span class="o">=</span><span class="s2">"IP:</span><span class="si">${</span><span class="nv">NEXUS_HOST</span><span class="si">}</span><span class="s2">,DNS:</span><span class="si">${</span><span class="nv">short_hostname</span><span class="si">}</span><span class="s2">,DNS:nexus"</span>
<span class="w">  </span><span class="k">else</span>
<span class="w">    </span><span class="nv">certificate_san</span><span class="o">=</span><span class="s2">"DNS:</span><span class="si">${</span><span class="nv">NEXUS_HOST</span><span class="si">}</span><span class="s2">,DNS:</span><span class="si">${</span><span class="nv">short_hostname</span><span class="si">}</span><span class="s2">,DNS:nexus"</span>
<span class="w">  </span><span class="k">fi</span>
<span class="w">  </span>nerdctl<span class="w"> </span>run<span class="w"> </span>--rm<span class="w"> </span><span class="se">\</span>
<span class="w">    </span>--entrypoint<span class="w"> </span>/usr/bin/keytool<span class="w"> </span><span class="se">\</span>
<span class="w">    </span>-v<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_DATA</span><span class="si">}</span><span class="s2">:/nexus-data"</span><span class="w"> </span><span class="se">\</span>
<span class="w">    </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_IMAGE</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">    </span>-genkeypair<span class="w"> </span><span class="se">\</span>
<span class="w">    </span>-alias<span class="w"> </span>nexus<span class="w"> </span><span class="se">\</span>
<span class="w">    </span>-keyalg<span class="w"> </span>RSA<span class="w"> </span><span class="se">\</span>
<span class="w">    </span>-keysize<span class="w"> </span><span class="m">4096</span><span class="w"> </span><span class="se">\</span>
<span class="w">    </span>-validity<span class="w"> </span><span class="m">3650</span><span class="w"> </span><span class="se">\</span>
<span class="w">    </span>-keystore<span class="w"> </span>/nexus-data/etc/ssl/keystore.jks<span class="w"> </span><span class="se">\</span>
<span class="w">    </span>-storepass<span class="w"> </span>password<span class="w"> </span><span class="se">\</span>
<span class="w">    </span>-keypass<span class="w"> </span>password<span class="w"> </span><span class="se">\</span>
<span class="w">    </span>-dname<span class="w"> </span><span class="s2">"CN=</span><span class="si">${</span><span class="nv">NEXUS_HOST</span><span class="si">}</span><span class="s2">,OU=Infrastructure,O=Okestro,C=KR"</span><span class="w"> </span><span class="se">\</span>
<span class="w">    </span>-ext<span class="w"> </span><span class="s2">"SAN=</span><span class="si">${</span><span class="nv">certificate_san</span><span class="si">}</span><span class="s2">"</span>
<span class="k">fi</span>

chown<span class="w"> </span>-R<span class="w"> </span><span class="m">200</span>:200<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_DATA</span><span class="si">}</span><span class="s2">/etc"</span>
<span class="k">if</span><span class="w"> </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="k">$(</span>nerdctl<span class="w"> </span>container<span class="w"> </span>inspect<span class="w"> </span>-f<span class="w"> </span><span class="s1">'&#123;&#123;.State.Status&#125;&#125;'</span><span class="w"> </span>nexus<span class="w"> </span><span class="m">2</span>&gt;/dev/null<span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="nb">true</span><span class="k">)</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"running"</span><span class="w"> </span><span class="o">]]</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">  </span><span class="nv">existing_nexus_image</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>nerdctl<span class="w"> </span>container<span class="w"> </span>inspect<span class="w"> </span>-f<span class="w"> </span><span class="s1">'&#123;&#123;.Config.Image&#125;&#125;'</span><span class="w"> </span>nexus<span class="k">)</span><span class="s2">"</span>
<span class="w">  </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">existing_nexus_image</span><span class="p">#docker.io/</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_IMAGE</span><span class="p">#docker.io/</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">    </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Running Nexus image differs from this release: </span><span class="si">${</span><span class="nv">existing_nexus_image</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">    </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="w">  </span><span class="o">}</span>
<span class="w">  </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Nexus is already running."</span>
<span class="k">else</span>
<span class="w">  </span>nerdctl<span class="w"> </span>compose<span class="w"> </span>-f<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_HOME</span><span class="si">}</span><span class="s2">/compose.yaml"</span><span class="w"> </span>up<span class="w"> </span>-d
<span class="k">fi</span>

<span class="nb">echo</span><span class="w"> </span><span class="s2">"[5/9] Wait for Nexus HTTPS"</span>
<span class="k">for</span><span class="w"> </span>attempt<span class="w"> </span><span class="k">in</span><span class="w"> </span><span class="k">$(</span>seq<span class="w"> </span><span class="m">1</span><span class="w"> </span><span class="m">120</span><span class="k">)</span><span class="p">;</span><span class="w"> </span><span class="k">do</span>
<span class="w">  </span><span class="k">if</span><span class="w"> </span>curl<span class="w"> </span>-kfsS<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">API</span><span class="si">}</span><span class="s2">/status"</span><span class="w"> </span>&gt;/dev/null<span class="w"> </span><span class="m">2</span>&gt;<span class="p">&amp;</span><span class="m">1</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">    </span><span class="k">break</span>
<span class="w">  </span><span class="k">fi</span>
<span class="w">  </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">attempt</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>-lt<span class="w"> </span><span class="m">120</span><span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">    </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Nexus startup timeout."</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">    </span>nerdctl<span class="w"> </span>logs<span class="w"> </span>nexus<span class="w"> </span><span class="p">|</span><span class="w"> </span>tail<span class="w"> </span>-100<span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">    </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="w">  </span><span class="o">}</span>
<span class="w">  </span>sleep<span class="w"> </span><span class="m">5</span>
<span class="k">done</span>

<span class="nv">ADMIN_SECRET</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_HOME</span><span class="si">}</span><span class="s2">/.admin-password"</span>
<span class="k">if</span><span class="w"> </span><span class="o">[[</span><span class="w"> </span>-r<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_DATA</span><span class="si">}</span><span class="s2">/admin.password"</span><span class="w"> </span><span class="o">&amp;&amp;</span><span class="w"> </span>!<span class="w"> </span>-e<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">ADMIN_SECRET</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">  </span>install<span class="w"> </span>-m<span class="w"> </span><span class="m">0600</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_DATA</span><span class="si">}</span><span class="s2">/admin.password"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">ADMIN_SECRET</span><span class="si">}</span><span class="s2">"</span>
<span class="k">fi</span>
<span class="k">if</span><span class="w"> </span><span class="o">[[</span><span class="w"> </span>-z<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_ADMIN_PASSWORD</span><span class="k">:-</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">&amp;&amp;</span><span class="w"> </span>-r<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">ADMIN_SECRET</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">  </span><span class="nv">NEXUS_ADMIN_PASSWORD</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>&lt;<span class="s2">"</span><span class="si">${</span><span class="nv">ADMIN_SECRET</span><span class="si">}</span><span class="s2">"</span><span class="k">)</span><span class="s2">"</span>
<span class="k">fi</span>
<span class="o">[[</span><span class="w"> </span>-n<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_ADMIN_PASSWORD</span><span class="k">:-</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">  </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Nexus admin password is unavailable; set NEXUS_ADMIN_PASSWORD or restore </span><span class="si">${</span><span class="nv">ADMIN_SECRET</span><span class="si">}</span><span class="s2">."</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">  </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="o">}</span>
<span class="nv">AUTH</span><span class="o">=</span><span class="s2">"admin:</span><span class="si">${</span><span class="nv">NEXUS_ADMIN_PASSWORD</span><span class="si">}</span><span class="s2">"</span>

curl<span class="w"> </span>-kfsS<span class="w"> </span>-u<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">AUTH</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">API</span><span class="si">}</span><span class="s2">/security/anonymous"</span><span class="w"> </span>&gt;/dev/null

<span class="nv">eula</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>curl<span class="w"> </span>-kfsS<span class="w"> </span>-u<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">AUTH</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">API</span><span class="si">}</span><span class="s2">/system/eula"</span><span class="k">)</span><span class="s2">"</span>
<span class="k">if</span><span class="w"> </span>grep<span class="w"> </span>-q<span class="w"> </span><span class="s1">'"accepted"[[:space:]]*:[[:space:]]*false'</span><span class="w"> </span><span class="o">&lt;&lt;&lt;</span><span class="s2">"</span><span class="si">${</span><span class="nv">eula</span><span class="si">}</span><span class="s2">"</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">  </span><span class="nv">eula</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>sed<span class="w"> </span>-E<span class="w"> </span><span class="s1">'s/"accepted"[[:space:]]*:[[:space:]]*false/"accepted": true/'</span><span class="w"> </span><span class="o">&lt;&lt;&lt;</span><span class="s2">"</span><span class="si">${</span><span class="nv">eula</span><span class="si">}</span><span class="s2">"</span><span class="k">)</span><span class="s2">"</span>
<span class="w">  </span>curl<span class="w"> </span>-kfsS<span class="w"> </span>-u<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">AUTH</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">    </span>-H<span class="w"> </span><span class="s1">'Content-Type: application/json'</span><span class="w"> </span><span class="se">\</span>
<span class="w">    </span>-X<span class="w"> </span>POST<span class="w"> </span>--data<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">eula</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">API</span><span class="si">}</span><span class="s2">/system/eula"</span><span class="w"> </span>&gt;/dev/null
<span class="k">fi</span>

api_status<span class="o">()</span><span class="w"> </span><span class="o">{</span>
<span class="w">  </span>curl<span class="w"> </span>-ksS<span class="w"> </span>-u<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">AUTH</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>-o<span class="w"> </span>/dev/null<span class="w"> </span>-w<span class="w"> </span><span class="s1">'%{http_code}'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">API</span><span class="si">}</span><span class="s2">/</span><span class="nv">$1</span><span class="s2">"</span>
<span class="o">}</span>

<span class="nb">echo</span><span class="w"> </span><span class="s2">"[6/9] Create blob store and repositories"</span>
<span class="k">if</span><span class="w"> </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="k">$(</span>api_status<span class="w"> </span><span class="s1">'blobstores/file/contrabass-engine'</span><span class="k">)</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"404"</span><span class="w"> </span><span class="o">]]</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">  </span>curl<span class="w"> </span>-kfsS<span class="w"> </span>-u<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">AUTH</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">    </span>-H<span class="w"> </span><span class="s1">'Content-Type: application/json'</span><span class="w"> </span><span class="se">\</span>
<span class="w">    </span>-X<span class="w"> </span>POST<span class="w"> </span><span class="se">\</span>
<span class="w">    </span>--data<span class="w"> </span><span class="s1">'{"name":"contrabass-engine","path":"contrabass-engine"}'</span><span class="w"> </span><span class="se">\</span>
<span class="w">    </span><span class="s2">"</span><span class="si">${</span><span class="nv">API</span><span class="si">}</span><span class="s2">/blobstores/file"</span><span class="w"> </span>&gt;/dev/null
<span class="k">fi</span>

<span class="k">if</span><span class="w"> </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="k">$(</span>api_status<span class="w"> </span><span class="s1">'repositories/raw/hosted/raw-hosted'</span><span class="k">)</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"404"</span><span class="w"> </span><span class="o">]]</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">  </span>curl<span class="w"> </span>-kfsS<span class="w"> </span>-u<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">AUTH</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">    </span>-H<span class="w"> </span><span class="s1">'Content-Type: application/json'</span><span class="w"> </span><span class="se">\</span>
<span class="w">    </span>-X<span class="w"> </span>POST<span class="w"> </span><span class="se">\</span>
<span class="w">    </span>--data<span class="w"> </span><span class="s1">'{"name":"raw-hosted","online":true,"storage":{"blobStoreName":"contrabass-engine","strictContentTypeValidation":false,"writePolicy":"ALLOW_ONCE"},"cleanup":{"policyNames":[]},"raw":{"contentDisposition":"ATTACHMENT"},"component":{"proprietaryComponents":true&#125;&#125;'</span><span class="w"> </span><span class="se">\</span>
<span class="w">    </span><span class="s2">"</span><span class="si">${</span><span class="nv">API</span><span class="si">}</span><span class="s2">/repositories/raw/hosted"</span><span class="w"> </span>&gt;/dev/null
<span class="k">fi</span>

<span class="k">if</span><span class="w"> </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="k">$(</span>api_status<span class="w"> </span><span class="s1">'repositories/docker/hosted/docker-hosted'</span><span class="k">)</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"404"</span><span class="w"> </span><span class="o">]]</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">  </span>curl<span class="w"> </span>-kfsS<span class="w"> </span>-u<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">AUTH</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">    </span>-H<span class="w"> </span><span class="s1">'Content-Type: application/json'</span><span class="w"> </span><span class="se">\</span>
<span class="w">    </span>-X<span class="w"> </span>POST<span class="w"> </span><span class="se">\</span>
<span class="w">    </span>--data<span class="w"> </span><span class="s1">'{"name":"docker-hosted","online":true,"storage":{"blobStoreName":"contrabass-engine","strictContentTypeValidation":true,"writePolicy":"ALLOW_ONCE","latestPolicy":false},"cleanup":{"policyNames":[]},"docker":{"v1Enabled":false,"forceBasicAuth":false,"pathEnabled":true},"component":{"proprietaryComponents":true&#125;&#125;'</span><span class="w"> </span><span class="se">\</span>
<span class="w">    </span><span class="s2">"</span><span class="si">${</span><span class="nv">API</span><span class="si">}</span><span class="s2">/repositories/docker/hosted"</span><span class="w"> </span>&gt;/dev/null
<span class="k">fi</span>

<span class="k">if</span><span class="w"> </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="k">$(</span>api_status<span class="w"> </span><span class="s1">'security/roles/private-anonymous-reader'</span><span class="k">)</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"404"</span><span class="w"> </span><span class="o">]]</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">  </span>curl<span class="w"> </span>-kfsS<span class="w"> </span>-u<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">AUTH</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">    </span>-H<span class="w"> </span><span class="s1">'Content-Type: application/json'</span><span class="w"> </span><span class="se">\</span>
<span class="w">    </span>-X<span class="w"> </span>POST<span class="w"> </span><span class="se">\</span>
<span class="w">    </span>--data<span class="w"> </span><span class="s1">'{"id":"private-anonymous-reader","name":"Private Repository Anonymous Reader","description":"Anonymous pull and download","privileges":["nx-repository-view-raw-raw-hosted-read","nx-repository-view-raw-raw-hosted-browse","nx-repository-view-docker-docker-hosted-read","nx-repository-view-docker-docker-hosted-browse"],"roles":[]}'</span><span class="w"> </span><span class="se">\</span>
<span class="w">    </span><span class="s2">"</span><span class="si">${</span><span class="nv">API</span><span class="si">}</span><span class="s2">/security/roles"</span><span class="w"> </span>&gt;/dev/null
<span class="k">fi</span>

curl<span class="w"> </span>-kfsS<span class="w"> </span>-u<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">AUTH</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span>-H<span class="w"> </span><span class="s1">'Content-Type: application/json'</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span>-X<span class="w"> </span>PUT<span class="w"> </span><span class="se">\</span>
<span class="w">  </span>--data<span class="w"> </span><span class="s1">'["NexusAuthenticatingRealm","DockerToken"]'</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s2">"</span><span class="si">${</span><span class="nv">API</span><span class="si">}</span><span class="s2">/security/realms/active"</span><span class="w"> </span>&gt;/dev/null

curl<span class="w"> </span>-kfsS<span class="w"> </span>-u<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">AUTH</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span>-H<span class="w"> </span><span class="s1">'Content-Type: application/json'</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span>-X<span class="w"> </span>PUT<span class="w"> </span><span class="se">\</span>
<span class="w">  </span>--data<span class="w"> </span><span class="s1">'{"userId":"anonymous","firstName":"Anonymous","lastName":"User","emailAddress":"anonymous@example.org","source":"default","status":"active","roles":["nx-anonymous","private-anonymous-reader"]}'</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s2">"</span><span class="si">${</span><span class="nv">API</span><span class="si">}</span><span class="s2">/security/users/anonymous"</span><span class="w"> </span>&gt;/dev/null

curl<span class="w"> </span>-kfsS<span class="w"> </span>-u<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">AUTH</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span>-H<span class="w"> </span><span class="s1">'Content-Type: application/json'</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span>-X<span class="w"> </span>PUT<span class="w"> </span><span class="se">\</span>
<span class="w">  </span>--data<span class="w"> </span><span class="s1">'{"enabled":true,"userId":"anonymous","realmName":"NexusAuthorizingRealm"}'</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span><span class="s2">"</span><span class="si">${</span><span class="nv">API</span><span class="si">}</span><span class="s2">/security/anonymous"</span><span class="w"> </span>&gt;/dev/null

<span class="nb">echo</span><span class="w"> </span><span class="s2">"[7/9] Import Raw artifacts"</span>
awk<span class="w"> </span>-F<span class="s1">'"'</span><span class="w"> </span><span class="s1">'</span>
<span class="s1">  /^  - path:/ {path=$2}</span>
<span class="s1">  /^    sha256:/ &amp;&amp; path != "" {print path "|" $2; path=""}</span>
<span class="s1">'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">MANIFEST</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="p">|</span>
<span class="k">while</span><span class="w"> </span><span class="nv">IFS</span><span class="o">=</span><span class="s1">'|'</span><span class="w"> </span><span class="nb">read</span><span class="w"> </span>-r<span class="w"> </span>artifact_path<span class="w"> </span>expected_sha<span class="p">;</span><span class="w"> </span><span class="k">do</span>
<span class="w">  </span><span class="nv">source_file</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">BUNDLE_DIR</span><span class="si">}</span><span class="s2">/raw/</span><span class="si">${</span><span class="nv">artifact_path</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span><span class="nv">actual_sha</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>sha256sum<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">source_file</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="p">|</span><span class="w"> </span>awk<span class="w"> </span><span class="s1">'{print $1}'</span><span class="k">)</span><span class="s2">"</span>
<span class="w">  </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">actual_sha</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">expected_sha</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">    </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Checksum mismatch: </span><span class="si">${</span><span class="nv">artifact_path</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">    </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="w">  </span><span class="o">}</span>

<span class="w">  </span><span class="nv">status</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>curl<span class="w"> </span>-ksSI<span class="w"> </span>-u<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">AUTH</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>-o<span class="w"> </span>/dev/null<span class="w"> </span>-w<span class="w"> </span><span class="s1">'%{http_code}'</span><span class="w"> </span><span class="se">\</span>
<span class="w">    </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_ENDPOINT</span><span class="si">}</span><span class="s2">/repository/raw-hosted/</span><span class="si">${</span><span class="nv">artifact_path</span><span class="si">}</span><span class="s2">"</span><span class="k">)</span><span class="s2">"</span>
<span class="w">  </span><span class="k">if</span><span class="w"> </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">status</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"404"</span><span class="w"> </span><span class="o">]]</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">    </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"  </span><span class="si">${</span><span class="nv">artifact_path</span><span class="si">}</span><span class="s2">"</span>
<span class="w">    </span>curl<span class="w"> </span>-kfsS<span class="w"> </span>-u<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">AUTH</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">      </span>--upload-file<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">source_file</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">      </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_ENDPOINT</span><span class="si">}</span><span class="s2">/repository/raw-hosted/</span><span class="si">${</span><span class="nv">artifact_path</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span><span class="k">elif</span><span class="w"> </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">status</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>!<span class="o">=</span><span class="w"> </span><span class="s2">"200"</span><span class="w"> </span><span class="o">]]</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">    </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Raw repository check failed: </span><span class="si">${</span><span class="nv">artifact_path</span><span class="si">}</span><span class="s2">, HTTP </span><span class="si">${</span><span class="nv">status</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">    </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="w">  </span><span class="k">else</span>
<span class="w">    </span><span class="nv">remote_sha</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>curl<span class="w"> </span>-kfsS<span class="w"> </span>-u<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">AUTH</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">      </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_ENDPOINT</span><span class="si">}</span><span class="s2">/repository/raw-hosted/</span><span class="si">${</span><span class="nv">artifact_path</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="p">|</span><span class="w"> </span>sha256sum<span class="w"> </span><span class="p">|</span><span class="w"> </span>awk<span class="w"> </span><span class="s1">'{print $1}'</span><span class="k">)</span><span class="s2">"</span>
<span class="w">    </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">remote_sha</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">expected_sha</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">      </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Existing Raw artifact checksum differs: </span><span class="si">${</span><span class="nv">artifact_path</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">      </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="w">    </span><span class="o">}</span>
<span class="w">  </span><span class="k">fi</span>
<span class="k">done</span>

upload_raw_once<span class="o">()</span><span class="w"> </span><span class="o">{</span>
<span class="w">  </span><span class="nb">local</span><span class="w"> </span><span class="nv">source_file</span><span class="o">=</span><span class="s2">"</span><span class="nv">$1</span><span class="s2">"</span>
<span class="w">  </span><span class="nb">local</span><span class="w"> </span><span class="nv">target_path</span><span class="o">=</span><span class="s2">"</span><span class="nv">$2</span><span class="s2">"</span>
<span class="w">  </span><span class="nb">local</span><span class="w"> </span>status

<span class="w">  </span><span class="nv">status</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>curl<span class="w"> </span>-ksSI<span class="w"> </span>-u<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">AUTH</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>-o<span class="w"> </span>/dev/null<span class="w"> </span>-w<span class="w"> </span><span class="s1">'%{http_code}'</span><span class="w"> </span><span class="se">\</span>
<span class="w">    </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_ENDPOINT</span><span class="si">}</span><span class="s2">/repository/raw-hosted/</span><span class="si">${</span><span class="nv">target_path</span><span class="si">}</span><span class="s2">"</span><span class="k">)</span><span class="s2">"</span>
<span class="w">  </span><span class="k">if</span><span class="w"> </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">status</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"404"</span><span class="w"> </span><span class="o">]]</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">    </span>curl<span class="w"> </span>-kfsS<span class="w"> </span>-u<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">AUTH</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>--upload-file<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">source_file</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">      </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_ENDPOINT</span><span class="si">}</span><span class="s2">/repository/raw-hosted/</span><span class="si">${</span><span class="nv">target_path</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;/dev/null
<span class="w">  </span><span class="k">elif</span><span class="w"> </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">status</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>!<span class="o">=</span><span class="w"> </span><span class="s2">"200"</span><span class="w"> </span><span class="o">]]</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">    </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Raw repository check failed: </span><span class="si">${</span><span class="nv">target_path</span><span class="si">}</span><span class="s2">, HTTP </span><span class="si">${</span><span class="nv">status</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">    </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="w">  </span><span class="k">else</span>
<span class="w">    </span>curl<span class="w"> </span>-kfsS<span class="w"> </span>-u<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">AUTH</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">      </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_ENDPOINT</span><span class="si">}</span><span class="s2">/repository/raw-hosted/</span><span class="si">${</span><span class="nv">target_path</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">      </span><span class="p">|</span><span class="w"> </span>cmp<span class="w"> </span>-s<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">source_file</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>-<span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">      </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Existing Raw metadata differs: </span><span class="si">${</span><span class="nv">target_path</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">      </span><span class="k">return</span><span class="w"> </span><span class="m">1</span>
<span class="w">    </span><span class="o">}</span>
<span class="w">  </span><span class="k">fi</span>
<span class="o">}</span>

<span class="nv">release_tag</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>awk<span class="w"> </span>-F<span class="s1">': *'</span><span class="w"> </span><span class="s1">'$1 == "release_tag" {print $2; exit}'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">RELEASE_INFO</span><span class="si">}</span><span class="s2">"</span><span class="k">)</span><span class="s2">"</span>
<span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">release_tag</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">=</span>~<span class="w"> </span>^v<span class="o">[</span><span class="m">0</span>-9<span class="o">]</span>+<span class="se">\.</span><span class="o">[</span><span class="m">0</span>-9<span class="o">]</span>+<span class="se">\.</span><span class="o">[</span><span class="m">0</span>-9<span class="o">]</span>+$<span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">  </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Invalid release tag in release-info.yaml: </span><span class="si">${</span><span class="nv">release_tag</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">  </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="o">}</span>
upload_raw_once<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">MANIFEST</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"release/</span><span class="si">${</span><span class="nv">release_tag</span><span class="si">}</span><span class="s2">/manifest.yaml"</span>
upload_raw_once<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">RELEASE_INFO</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"release/</span><span class="si">${</span><span class="nv">release_tag</span><span class="si">}</span><span class="s2">/release-info.yaml"</span>

<span class="nb">echo</span><span class="w"> </span><span class="s2">"[8/9] Import Docker images"</span>

read_registry_manifest<span class="o">()</span><span class="w"> </span><span class="o">{</span>
<span class="w">  </span><span class="nb">local</span><span class="w"> </span><span class="nv">image_name</span><span class="o">=</span><span class="s2">"</span><span class="nv">$1</span><span class="s2">"</span>
<span class="w">  </span><span class="nb">local</span><span class="w"> </span><span class="nv">image_tag</span><span class="o">=</span><span class="s2">"</span><span class="nv">$2</span><span class="s2">"</span>
<span class="w">  </span><span class="nb">local</span><span class="w"> </span>header_file
<span class="w">  </span><span class="nb">local</span><span class="w"> </span>manifest_url

<span class="w">  </span><span class="nv">manifest_url</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_ENDPOINT</span><span class="si">}</span><span class="s2">/v2/docker-hosted/</span><span class="si">${</span><span class="nv">image_name</span><span class="si">}</span><span class="s2">/manifests/</span><span class="si">${</span><span class="nv">image_tag</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span><span class="nv">header_file</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>mktemp<span class="k">)</span><span class="s2">"</span>
<span class="w">  </span><span class="nv">REGISTRY_HTTP_STATUS</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>curl<span class="w"> </span>-ksS<span class="w"> </span>-u<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">AUTH</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>-D<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">header_file</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>-o<span class="w"> </span>/dev/null<span class="w"> </span>-w<span class="w"> </span><span class="s1">'%{http_code}'</span><span class="w"> </span><span class="se">\</span>
<span class="w">    </span>-H<span class="w"> </span><span class="s1">'Accept: application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.index.v1+json'</span><span class="w"> </span><span class="se">\</span>
<span class="w">    </span><span class="s2">"</span><span class="si">${</span><span class="nv">manifest_url</span><span class="si">}</span><span class="s2">"</span><span class="k">)</span><span class="s2">"</span>
<span class="w">  </span><span class="nv">REGISTRY_DIGEST</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>awk<span class="w"> </span><span class="s1">'BEGIN{IGNORECASE=1} /^Docker-Content-Digest:/{gsub("\\r", "", $2); print $2; exit}'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">header_file</span><span class="si">}</span><span class="s2">"</span><span class="k">)</span><span class="s2">"</span>
<span class="w">  </span>rm<span class="w"> </span>-f<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">header_file</span><span class="si">}</span><span class="s2">"</span>
<span class="o">}</span>

<span class="nv">missing_image_count</span><span class="o">=</span><span class="m">0</span>
<span class="k">while</span><span class="w"> </span><span class="nv">IFS</span><span class="o">=</span><span class="s1">'|'</span><span class="w"> </span><span class="nb">read</span><span class="w"> </span>-r<span class="w"> </span>source_ref<span class="w"> </span>image_name<span class="w"> </span>image_tag<span class="w"> </span>expected_digest<span class="p">;</span><span class="w"> </span><span class="k">do</span>
<span class="w">  </span>read_registry_manifest<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">image_name</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">image_tag</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span><span class="k">if</span><span class="w"> </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">REGISTRY_HTTP_STATUS</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"200"</span><span class="w"> </span><span class="o">]]</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">    </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">REGISTRY_DIGEST</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">expected_digest</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">      </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Existing image digest differs: </span><span class="si">${</span><span class="nv">image_name</span><span class="si">}</span><span class="s2">:</span><span class="si">${</span><span class="nv">image_tag</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">      </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="w">    </span><span class="o">}</span>
<span class="w">  </span><span class="k">elif</span><span class="w"> </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">REGISTRY_HTTP_STATUS</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"404"</span><span class="w"> </span><span class="o">]]</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">    </span><span class="nv">missing_image_count</span><span class="o">=</span><span class="k">$((</span><span class="nv">missing_image_count</span><span class="w"> </span><span class="o">+</span><span class="w"> </span><span class="m">1</span><span class="k">))</span>
<span class="w">  </span><span class="k">else</span>
<span class="w">    </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Docker repository check failed: </span><span class="si">${</span><span class="nv">image_name</span><span class="si">}</span><span class="s2">:</span><span class="si">${</span><span class="nv">image_tag</span><span class="si">}</span><span class="s2">, HTTP </span><span class="si">${</span><span class="nv">REGISTRY_HTTP_STATUS</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">    </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="w">  </span><span class="k">fi</span>
<span class="k">done</span><span class="w"> </span>&lt;<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">IMAGE_MAP</span><span class="si">}</span><span class="s2">"</span>

<span class="k">if</span><span class="w"> </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">missing_image_count</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>-eq<span class="w"> </span><span class="m">0</span><span class="w"> </span><span class="o">]]</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">  </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"All Docker images are already imported."</span>
<span class="k">else</span>
<span class="w">  </span>nerdctl<span class="w"> </span>load<span class="w"> </span>-i<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">IMAGE_ARCHIVE</span><span class="si">}</span><span class="s2">"</span>
<span class="w">  </span><span class="nb">printf</span><span class="w"> </span><span class="s1">'%s'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_ADMIN_PASSWORD</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">    </span><span class="p">|</span><span class="w"> </span>nerdctl<span class="w"> </span>login<span class="w"> </span>--username<span class="w"> </span>admin<span class="w"> </span>--password-stdin<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_REGISTRY</span><span class="si">}</span><span class="s2">"</span>

<span class="w">  </span><span class="k">while</span><span class="w"> </span><span class="nv">IFS</span><span class="o">=</span><span class="s1">'|'</span><span class="w"> </span><span class="nb">read</span><span class="w"> </span>-r<span class="w"> </span>source_ref<span class="w"> </span>image_name<span class="w"> </span>image_tag<span class="w"> </span>expected_digest<span class="p">;</span><span class="w"> </span><span class="k">do</span>
<span class="w">    </span><span class="nv">target_ref</span><span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_REGISTRY</span><span class="si">}</span><span class="s2">/docker-hosted/</span><span class="si">${</span><span class="nv">image_name</span><span class="si">}</span><span class="s2">:</span><span class="si">${</span><span class="nv">image_tag</span><span class="si">}</span><span class="s2">"</span>
<span class="w">    </span>read_registry_manifest<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">image_name</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">image_tag</span><span class="si">}</span><span class="s2">"</span>
<span class="w">    </span><span class="k">if</span><span class="w"> </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">REGISTRY_HTTP_STATUS</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"200"</span><span class="w"> </span><span class="o">]]</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">      </span><span class="k">continue</span>
<span class="w">    </span><span class="k">fi</span>

<span class="w">    </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"  </span><span class="si">${</span><span class="nv">target_ref</span><span class="si">}</span><span class="s2">"</span>
<span class="w">    </span>nerdctl<span class="w"> </span>tag<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">source_ref</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">target_ref</span><span class="si">}</span><span class="s2">"</span>
<span class="w">    </span>nerdctl<span class="w"> </span>push<span class="w"> </span>--quiet<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">target_ref</span><span class="si">}</span><span class="s2">"</span>

<span class="w">    </span>read_registry_manifest<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">image_name</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">image_tag</span><span class="si">}</span><span class="s2">"</span>
<span class="w">    </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">REGISTRY_HTTP_STATUS</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"200"</span><span class="w"> </span><span class="o">&amp;&amp;</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">REGISTRY_DIGEST</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">expected_digest</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span>
<span class="w">      </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Digest mismatch after push: </span><span class="si">${</span><span class="nv">image_name</span><span class="si">}</span><span class="s2">:</span><span class="si">${</span><span class="nv">image_tag</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">      </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
<span class="w">    </span><span class="o">}</span>
<span class="w">  </span><span class="k">done</span><span class="w"> </span>&lt;<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">IMAGE_MAP</span><span class="si">}</span><span class="s2">"</span>

<span class="w">  </span>nerdctl<span class="w"> </span><span class="nb">logout</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_REGISTRY</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;/dev/null<span class="w"> </span><span class="m">2</span>&gt;<span class="p">&amp;</span><span class="m">1</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="nb">true</span>
<span class="k">fi</span>

<span class="nb">echo</span><span class="w"> </span><span class="s2">"[9/9] Final verification"</span>
<span class="nv">raw_count</span><span class="o">=</span><span class="m">0</span>
<span class="k">while</span><span class="w"> </span><span class="nv">IFS</span><span class="o">=</span><span class="w"> </span><span class="nb">read</span><span class="w"> </span>-r<span class="w"> </span>artifact_path<span class="p">;</span><span class="w"> </span><span class="k">do</span>
<span class="w">  </span>curl<span class="w"> </span>-kfsSI<span class="w"> </span><span class="se">\</span>
<span class="w">    </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_ENDPOINT</span><span class="si">}</span><span class="s2">/repository/raw-hosted/</span><span class="si">${</span><span class="nv">artifact_path</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">    </span>&gt;/dev/null
<span class="w">  </span><span class="nv">raw_count</span><span class="o">=</span><span class="k">$((</span><span class="nv">raw_count</span><span class="w"> </span><span class="o">+</span><span class="w"> </span><span class="m">1</span><span class="k">))</span>
<span class="k">done</span><span class="w"> </span>&lt;<span class="w"> </span>&lt;<span class="o">(</span>awk<span class="w"> </span>-F<span class="s1">'"'</span><span class="w"> </span><span class="s1">'/^  - path:/{print $2}'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">MANIFEST</span><span class="si">}</span><span class="s2">"</span><span class="o">)</span>

<span class="nv">image_count</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>wc<span class="w"> </span>-l<span class="w"> </span>&lt;<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">IMAGE_MAP</span><span class="si">}</span><span class="s2">"</span><span class="k">)</span><span class="s2">"</span>
curl<span class="w"> </span>-kfsSI<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_ENDPOINT</span><span class="si">}</span><span class="s2">/repository/raw-hosted/release/</span><span class="si">${</span><span class="nv">release_tag</span><span class="si">}</span><span class="s2">/manifest.yaml"</span><span class="w"> </span>&gt;/dev/null

<span class="k">if</span><span class="w"> </span>systemctl<span class="w"> </span>is-active<span class="w"> </span>--quiet<span class="w"> </span>firewalld<span class="w"> </span><span class="o">&amp;&amp;</span><span class="w"> </span><span class="nb">command</span><span class="w"> </span>-v<span class="w"> </span>firewall-cmd<span class="w"> </span>&gt;/dev/null<span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">  </span>firewall-cmd<span class="w"> </span>--quiet<span class="w"> </span>--query-port<span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_PORT</span><span class="si">}</span><span class="s2">/tcp"</span><span class="w"> </span><span class="se">\</span>
<span class="w">    </span><span class="o">||</span><span class="w"> </span>firewall-cmd<span class="w"> </span>--quiet<span class="w"> </span>--add-port<span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_PORT</span><span class="si">}</span><span class="s2">/tcp"</span>
<span class="w">  </span>firewall-cmd<span class="w"> </span>--quiet<span class="w"> </span>--permanent<span class="w"> </span>--query-port<span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_PORT</span><span class="si">}</span><span class="s2">/tcp"</span><span class="w"> </span><span class="se">\</span>
<span class="w">    </span><span class="o">||</span><span class="w"> </span>firewall-cmd<span class="w"> </span>--quiet<span class="w"> </span>--permanent<span class="w"> </span>--add-port<span class="o">=</span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_PORT</span><span class="si">}</span><span class="s2">/tcp"</span>
<span class="k">fi</span>

<span class="nb">echo</span>
<span class="nb">echo</span><span class="w"> </span><span class="s2">"Private Nexus : </span><span class="si">${</span><span class="nv">NEXUS_ENDPOINT</span><span class="si">}</span><span class="s2">"</span>
<span class="nb">echo</span><span class="w"> </span><span class="s2">"Raw artifacts : </span><span class="si">${</span><span class="nv">raw_count</span><span class="si">}</span><span class="s2">"</span>
<span class="nb">echo</span><span class="w"> </span><span class="s2">"Docker images : </span><span class="si">${</span><span class="nv">image_count</span><span class="si">}</span><span class="s2">"</span>
<span class="nv">git_ref</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>awk<span class="w"> </span>-F<span class="s1">': *'</span><span class="w"> </span><span class="s1">'$1 == "git_ref" {print $2; exit}'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">RELEASE_INFO</span><span class="si">}</span><span class="s2">"</span><span class="k">)</span><span class="s2">"</span>
<span class="k">if</span><span class="w"> </span><span class="o">[[</span><span class="w"> </span>-z<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">git_ref</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">  </span><span class="nv">git_ref</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>awk<span class="w"> </span>-F<span class="s1">': *'</span><span class="w"> </span><span class="s1">'$1 == "git_tag" {print $2; exit}'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">RELEASE_INFO</span><span class="si">}</span><span class="s2">"</span><span class="k">)</span><span class="s2">"</span>
<span class="k">fi</span>
<span class="nb">echo</span><span class="w"> </span><span class="s2">"Git ref       : </span><span class="si">${</span><span class="nv">git_ref</span><span class="si">}</span><span class="s2">"</span>
<span class="nb">echo</span><span class="w"> </span><span class="s2">"Admin password: </span><span class="si">${</span><span class="nv">NEXUS_DATA</span><span class="si">}</span><span class="s2">/admin.password"</span>
</code></pre></div>

</details>

<details class="analysis-toggle" markdown="1">
<summary>/opt/gitea/bundle-builder/templates/compose.yaml — 전체 내용</summary>

<div class="highlight" data-source-path="host/opt/gitea/bundle-builder/templates/compose.yaml"><pre><code><span class="nt">services</span><span class="p">:</span>
<span class="w">  </span><span class="nt">nexus</span><span class="p">:</span>
<span class="w">    </span><span class="nt">image</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">${NEXUS_IMAGE:?Set NEXUS_IMAGE from manifest.yaml}</span>
<span class="w">    </span><span class="nt">container_name</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">nexus</span>
<span class="w">    </span><span class="nt">hostname</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">nexus</span>
<span class="w">    </span><span class="nt">restart</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">unless-stopped</span>
<span class="w">    </span><span class="nt">ports</span><span class="p">:</span>
<span class="w">      </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="s">"${NEXUS_PORT:-55555}:${NEXUS_PORT:-55555}"</span>
<span class="w">    </span><span class="nt">environment</span><span class="p">:</span>
<span class="w">      </span><span class="nt">INSTALL4J_ADD_VM_PARAMS</span><span class="p">:</span><span class="w"> </span><span class="p p-Indicator">&gt;-</span>
<span class="w">        </span><span class="no">-Xms${NEXUS_HEAP:-2703m}</span>
<span class="w">        </span><span class="no">-Xmx${NEXUS_HEAP:-2703m}</span>
<span class="w">        </span><span class="no">-XX:MaxDirectMemorySize=${NEXUS_DIRECT_MEMORY:-2703m}</span>
<span class="w">        </span><span class="no">-Djava.util.prefs.userRoot=/nexus-data/javaprefs</span>
<span class="w">        </span><span class="no">-Duser.timezone=Asia/Seoul</span>
<span class="w">    </span><span class="nt">volumes</span><span class="p">:</span>
<span class="w">      </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">${NEXUS_DATA:-/opt/nexus/nexus-data}:/nexus-data</span>
<span class="w">    </span><span class="nt">ulimits</span><span class="p">:</span>
<span class="w">      </span><span class="nt">nofile</span><span class="p">:</span>
<span class="w">        </span><span class="nt">soft</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">65536</span>
<span class="w">        </span><span class="nt">hard</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">65536</span>
<span class="w">    </span><span class="nt">logging</span><span class="p">:</span>
<span class="w">      </span><span class="nt">driver</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">json-file</span>
<span class="w">      </span><span class="nt">options</span><span class="p">:</span>
<span class="w">        </span><span class="nt">max-size</span><span class="p">:</span><span class="w"> </span><span class="s">"20m"</span>
<span class="w">        </span><span class="nt">max-file</span><span class="p">:</span><span class="w"> </span><span class="s">"5"</span>
<span class="w">    </span><span class="nt">networks</span><span class="p">:</span>
<span class="w">      </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">nexus-net</span>

<span class="nt">networks</span><span class="p">:</span>
<span class="w">  </span><span class="nt">nexus-net</span><span class="p">:</span>
<span class="w">    </span><span class="nt">driver</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">bridge</span>
</code></pre></div>

</details>

<details class="analysis-toggle" markdown="1">
<summary>/opt/gitea/bundle-builder/templates/nexus.properties — 전체 내용</summary>

<div class="highlight" data-source-path="host/opt/gitea/bundle-builder/templates/nexus.properties"><pre><code><span class="na">application-host</span><span class="o">=</span><span class="s">0.0.0.0</span>
<span class="na">application-port-ssl</span><span class="o">=</span><span class="s">55555</span>

<span class="na">nexus-args</span><span class="o">=</span><span class="s">${jetty.etc}/jetty.xml,${jetty.etc}/jetty-https.xml,${jetty.etc}/jetty-requestlog.xml</span>

<span class="na">ssl.etc</span><span class="o">=</span><span class="s">${karaf.data}/etc/ssl</span>
<span class="na">nexus-context-path</span><span class="o">=</span><span class="s">/</span>
</code></pre></div>

</details>

| 파일 | 호출하는 쪽 → 결과 |
| --- | --- |
| common.sh | 각 스크립트 → 설정·HTTP·시험 정책 공통 처리 |
| publish-manifest.sh | Workflow → manifest·매니페스트용 release-info |
| build-private-release | Workflow의 sudo → root 소유 build-bundle.sh |
| build-bundle.sh | wrapper → 재료 수집, 고객사 TAR·외부 체크섬 |
| publish-bundle.sh | 시험 또는 skip 이후 → 최종 TAR·channel·보관 목록 |
| update-release-alias | 게시 스크립트의 sudo → HAProxy map |
| templates/deploy.sh | 고객사 실행 → Nexus 준비 뒤 제품 install.sh |
| templates/setup-private-environment.sh | deploy.sh → 런타임·Private Nexus·재료 반입 |

모두 root 소유로 둔다. Runner가 빌더를 직접 수정할 수 있다면 sudo wrapper의 제한이 의미가 없어진다.

Nexus 비밀번호는 Workflow에서 표준입력으로 전달한다. 표준입력은 명령줄 인자가 아니라 파이프로 데이터를 보내는 통로다. `build-private-release`는 `env -i`로 상속 환경을 비운 뒤, `flock` 안의 셸에서 비밀번호를 읽고 환경변수로 설정해 `build-bundle.sh`에 넘긴다. `env NEXUS_PASSWORD="..."`처럼 비밀번호를 명령줄에 넣지 않아 실행 중인 프로세스의 명령줄 조회에 값이 나타나지 않게 한다. Actions Secret과 기존 빌드 호출 방식은 그대로 유지한다.

```bash title="빌더와 wrapper 설치"
source /etc/gitea-runner-env/bundle-pipeline.env
install -d -m 0755 -o root -g root "${BUNDLE_BUILDER_DIR}/templates"
install -m 0755 -o root -g root "${CONFIG_SRC}"/host/opt/gitea/bundle-builder/*.sh "${BUNDLE_BUILDER_DIR}/"
install -m 0755 -o root -g root "${CONFIG_SRC}"/host/opt/gitea/bundle-builder/templates/*.sh "${TEMPLATE_DIR}/"
install -m 0644 -o root -g root "${CONFIG_SRC}"/host/opt/gitea/bundle-builder/templates/compose.yaml "${TEMPLATE_DIR}/compose.yaml"
install -m 0644 -o root -g root "${CONFIG_SRC}"/host/opt/gitea/bundle-builder/templates/nexus.properties "${TEMPLATE_DIR}/nexus.properties"
install -m 0755 -o root -g root "${CONFIG_SRC}/host/usr/local/sbin/build-private-release" /usr/local/sbin/build-private-release
install -m 0755 -o root -g root "${CONFIG_SRC}/host/usr/local/sbin/update-release-alias" /usr/local/sbin/update-release-alias
install -m 0440 -o root -g root "${CONFIG_SRC}/host/etc/sudoers.d/contrabass-engine-runner" /etc/sudoers.d/contrabass-engine-runner
visudo -cf /etc/sudoers.d/contrabass-engine-runner
```

빌더는 Runner workspace의 소스를 재사용한다. 두 번째 clone이나 호스트 `.secret`은 필요 없다. 호스트의 컨테이너 관리 socket 전체도 Runner에 개방하지 않는다.

고객사 TAR에는 shallow Git이 들어가지만 인증 헤더·Git hook은 제거한다. 이미지와 Raw는 지정한 내용인지 확인해 모은다. 고객사는 TAR 전체를 검증한 뒤 deploy.sh를 실행하며, 소스 파일 전체의 SHA256SUMS를 다시 관리하지 않는다.

---

## 10. HAProxy의 고정 다운로드 URL 구성

<details class="analysis-toggle" markdown="1">
<summary>/etc/haproxy/haproxy.cfg — 전체 내용</summary>

<div class="highlight" data-source-path="host/etc/haproxy/haproxy.cfg"><pre><code><span class="na">global</span>
<span class="w">    </span><span class="na">log /dev/log local0</span>
<span class="w">    </span><span class="na">user haproxy</span>
<span class="w">    </span><span class="na">group haproxy</span>
<span class="w">    </span><span class="na">daemon</span>
<span class="w">    </span><span class="na">stats socket "${RELEASE_SOCKET}" mode 660 level admin</span>
<span class="w">    </span><span class="na">stats timeout 30s</span>
<span class="w">    </span><span class="na">ssl-default-bind-options ssl-min-ver TLSv1.2 no-tls-tickets</span>

<span class="na">defaults</span>
<span class="w">    </span><span class="na">log global</span>
<span class="w">    </span><span class="na">mode http</span>
<span class="w">    </span><span class="na">option httplog</span>
<span class="w">    </span><span class="na">option dontlognull</span>
<span class="w">    </span><span class="na">timeout connect 5s</span>
<span class="w">    </span><span class="na">timeout client 30m</span>
<span class="w">    </span><span class="na">timeout server 30m</span>
<span class="w">    </span><span class="na">timeout http-request 15s</span>
<span class="w">    </span><span class="na">timeout http-keep-alive 10s</span>

<span class="na">frontend release_https</span>
<span class="w">    </span><span class="na">bind "</span><span class="o">:</span><span class="s">${RELEASE_HTTPS_PORT}" ssl crt "${GITEA_CERT_DIR}/gitea.pem"</span>
<span class="w">    </span><span class="na">http-after-response set-header X-Content-Type-Options nosniff</span>
<span class="w">    </span><span class="na">http-after-response set-header Referrer-Policy no-referrer</span>
<span class="w">    </span><span class="na">http-request redirect code 302 location "%[path,map_str(${RELEASE_MAP_FILE})]" ignore-empty</span>
<span class="w">    </span><span class="na">http-request return status 404 if { path_beg "/repository/${MANIFEST_REPOSITORY}/channels/" } { path_end /contrabass-engine-deploy.tar }</span>
<span class="w">    </span><span class="na">default_backend nexus_https</span>

<span class="na">backend nexus_https</span>
<span class="w">    </span><span class="na">option httpchk GET /service/rest/v1/status</span>
<span class="w">    </span><span class="na">http-check expect status 200</span>
<span class="w">    </span><span class="na">server nexus "127.0.0.1</span><span class="o">:</span><span class="s">${NEXUS_HTTPS_PORT}" ssl verify none check</span>
</code></pre></div>

</details>

<details class="analysis-toggle" markdown="1">
<summary>/etc/haproxy/bundle-channels.map — 전체 내용</summary>

<div class="highlight" data-source-path="host/etc/haproxy/bundle-channels.map"><pre><code><span class="c1"># 최초에는 비워 둔다. 정상 게시 후 update-release-alias가 경로를 추가한다.</span>
</code></pre></div>

</details>

<details class="analysis-toggle" markdown="1">
<summary>/etc/systemd/system/haproxy.service.d/environment.conf — 전체 내용</summary>

<div class="highlight" data-source-path="host/etc/systemd/system/haproxy.service.d/environment.conf"><pre><code><span class="k">[Service]</span>
<span class="na">EnvironmentFile</span><span class="o">=</span><span class="s">/etc/gitea-runner-env/services.env</span>
</code></pre></div>

</details>

최초 map은 주석만 있다. 아직 없는 TAR로 임의의 연결을 만들지 않는다. 게시가 성공하면 update-release-alias가 디스크 파일과 Runtime map을 함께 갱신한다.

```bash title="HAProxy 배치·설정 검사·기동"
source /etc/gitea-runner-env/services.env
install -d -m 0755 /etc/haproxy /etc/systemd/system/haproxy.service.d
install -m 0644 "${CONFIG_SRC}/host/etc/haproxy/haproxy.cfg" /etc/haproxy/haproxy.cfg
install -m 0644 "${CONFIG_SRC}/host/etc/haproxy/bundle-channels.map" "${RELEASE_MAP_FILE}"
install -m 0644 "${CONFIG_SRC}/host/etc/systemd/system/haproxy.service.d/environment.conf" /etc/systemd/system/haproxy.service.d/environment.conf
set -a
source /etc/gitea-runner-env/services.env
set +a
haproxy -c -f /etc/haproxy/haproxy.cfg
systemctl daemon-reload
systemctl enable --now haproxy
systemctl restart haproxy
test -S "${RELEASE_SOCKET}"
```

단독 `haproxy -c`에도 환경을 전달해야 한다. systemd는 drop-in의 EnvironmentFile을 읽는다. 위 재기동은 최초 설정 작업이며 평소 릴리스마다 재기동하지 않는다.

```text title="구성 완료 뒤 다운로드 경로 예시"
/repository/raw-manifest/channels/current/contrabass-engine-deploy.tar
    → 302 → /repository/raw-release-bundle/releases/4.2/v4.2.1/contrabass-engine-deploy.tar

/repository/raw-manifest/channels/4.1/contrabass-engine-deploy.tar
    → 302 → /repository/raw-release-bundle/releases/4.1/v4.1.3/contrabass-engine-deploy.tar
```

map에 없는 TAR alias는 404, 일반 경로는 Nexus로 전달한다. current와 계열별 경로에 큰 TAR를 중복 저장하는 구조가 아니다.

---

## 11. VMware·OpenStack 시험 환경 준비

<p class="subsection-title"><strong>11-1. vCenter 계정·Role·적용 대상</strong></p>

<div class="section-body" markdown="1">

vSphere Client의 **메뉴 → 관리 → Single Sign On → 사용자 및 그룹 → 사용자**에서 API 계정을 만든다. SSO domain은 실제 vCenter의 것을 선택한다. 게스트 hostname에 쓰는 domain 변수와는 다르다.

**관리 → 액세스 제어 → 역할 → 새 역할**에서 사용자 정의 Role 하나를 만든다. 기존 템플릿 복제·설정·기동·삭제를 위한 항목이다. UI 표기가 다르면 privilege ID와 대조한다.

| 범주 | 선택할 항목·ID | 이유 |
| --- | --- | --- |
| Virtual machine → Change Configuration | Change CPU count, Change Memory, Change Settings, Change resource, Advanced configuration | 템플릿 사양과 nested HV 등 복제 뒤 설정 적용 |
| 같은 범주 | Add existing disk, Add new disk, Remove disk, Add or remove device, Modify device settings, Set annotation | 디스크·NIC 재설정과 VM 설명 처리 |
| 같은 범주 | Change Swapfile Placement / VirtualMachine.Config.SwapPlacement | provider가 기본 배치 정책을 설정 |
| Virtual machine → Edit Inventory | Create from existing, Remove | 복제 VM 생성·삭제 |
| Virtual machine → Provisioning | Deploy template, Customize guest, Read customization specifications | 템플릿 배포·IP·hostname 설정 |
| Virtual machine → Interaction | Power on, Power off | 기동과 destroy 시 전원 종료 |
| Datastore | Allocate space, Browse datastore | 디스크 배치·조회 |
| Network | Assign network | 템플릿의 모든 NIC를 Port group에 연결 |
| Resource | Assign virtual machine to resource pool | ESXi 기본 pool에 배치 |
| Profile-driven Storage / VM storage policies | View / StorageProfile.View | provider의 스토리지 정책 조회 |

`VirtualMachine.Config.Resource`가 빠지면 clone이 거의 끝난 뒤 reconfigure에서 실패할 수 있다. SwapPlacement는 OS swap 디스크를 새로 만드는 작업과 다르다. provider는 Tag와 Event도 조회하므로 자원 조회를 차단한 계정은 이 접근도 확인한다. [provider 2.17.1 권한 설명](https://github.com/vmware/terraform-provider-vsphere/blob/v2.17.1/docs/index.md#notes-on-required-privileges)

Role 생성만으로는 계정에 적용되지 않는다. 각 자원의 **권한 → 권한 추가 → 사용자·Role 선택 → 하위 전파**로 연결한다.

| 대상 | 위치·적용 범위 |
| --- | --- |
| 템플릿·시험 VM 부모 폴더 | VM 및 템플릿 보기 → 대상 폴더 → 권한, 하위 전파 |
| ESXi와 기본 resource pool | 호스트 및 클러스터 보기 → 대상 ESXi·pool, 조회·배치 가능 여부 확인 |
| Datastore | 스토리지 보기 → 대상 Datastore → 권한 |
| 템플릿의 모든 Port group | 네트워킹 보기 → 대상 네트워크 → 권한 |
| Distributed Switch 사용 시 | switch 자체에도 System.Read가 적용되는 조회 권한. Port group만으로 부족할 수 있음 |
| vCenter 최상위 | StorageProfile.View 조회용. 전체 하위 VM에 작업 권한이 퍼지지 않도록 전파하지 않음 |

VM 폴더 권한이 Datastore·Network 권한까지 대신하지 않는다. Role을 여러 개 추가하는 것보다 적용할 자원과 범위를 맞춘다.

</div>

<p class="subsection-title"><strong>11-2. Rocky 9.6 템플릿</strong></p>

<div class="section-body" markdown="1">

원본 VM 설정을 마친 뒤 템플릿으로 바꾼다. CPU·메모리·디스크·Port group을 템플릿에서 재사용한다. 중첩 가상화를 사용하므로 ESXi의 nested virtualization 설정과 시험 VM 메모리 합계에 맞는 자원을 확보한다.

```bash title="템플릿 원본 Rocky VM 콘솔에서 실행"
dnf install -y open-vm-tools perl openssh-server
systemctl enable --now vmtoolsd sshd
vmware-toolbox-cmd config set deployPkg enable-custom-scripts true
vmware-toolbox-cmd config get deployPkg enable-custom-scripts
rpm -q open-vm-tools perl
```

NIC는 **고정 IP 4개 + provider uplink 1개**다. 순서·인터페이스 이름·Port group을 확인한다. uplink는 예시에서 ens38이다. 템플릿 원본에 시험 IP를 고정해 들고 가지 않는다. 복제할 때 VMware Tools customization이 IP를 설정한다.

마지막 `network_interface {}`는 본래 DHCP 지정이다. guest-init.sh.tftpl이 후처리로 ens38의 IPv4·IPv6를 끄고 연결을 UP한다. 빈 블록만으로 IP 없는 포트가 되는 것은 아니다. 아래는 원본 VM의 콘솔에서 profile을 확인하는 명령이다. 출력된 해당 profile의 UUID를 선택한다.

```bash title="provider NIC와 NetworkManager profile 연결 확인"
ip -br link
nmcli -f NAME,UUID,DEVICE connection show
read -r -p 'ens38 profile UUID: ' profile_uuid
nmcli connection modify uuid "${profile_uuid}" connection.interface-name ens38
nmcli -g connection.interface-name connection show uuid "${profile_uuid}"
```

root SSH 접속이 가능한 템플릿이어야 한다. Runner는 공개키, 제품 Ansible은 제품 설정에 정의한 인증을 사용한다. VM의 root 비밀번호와 제품 `server_password`를 맞추고 SSH 정책도 확인한다. 암호를 공개 manifest·Git에 기록하지 않는다.

공개키는 복제 후 스크립트가 넣으므로 콘솔에서 긴 키를 직접 입력할 필요가 없다. Runner 키가 바뀌어도 다음 복제에는 새로운 공개키를 전달한다.

템플릿 변환 직전에는 machine-id·SSH 호스트 키의 복제 여부도 점검한다. 같은 키가 여러 VM에서 보이면 새 키를 생성하는 일반화 절차가 필요하다. [RHEL 계열 템플릿 준비](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/configuring_and_managing_virtualization/cloning-virtual-machines_configuring-and-managing-virtualization)

vSphere에서 원본 VM **설정 편집 → CD/DVD 드라이브 → 연결됨·전원을 켤 때 연결 해제**로 ISO를 분리한다. 전원을 끄고 **우클릭 → 템플릿 → 템플릿으로 변환**한다. 데이터 디스크 수와 SCSI 배치는 Ansible by-path 설정과 맞춘다.

</div>

<p class="subsection-title"><strong>11-3. OpenTofu 파일과 초기화</strong></p>

<div class="section-body" markdown="1">

OpenTofu를 공식 패키지 절차로 설치한다. 아래는 공식 installer를 저장·검토한 뒤 실행하는 예시다. [OpenTofu Ubuntu 설치](https://opentofu.org/docs/intro/install/deb/)

```bash title="물리서버 OpenTofu 설치"
cd /root/downloads
curl --proto '=https' --tlsv1.2 -fsSL https://get.opentofu.org/install-opentofu.sh -o install-opentofu.sh
less install-opentofu.sh
bash install-opentofu.sh --install-method deb
tofu version
```

<details class="analysis-toggle" markdown="1">
<summary>/var/lib/gitea-runner/opentofu/contrabass-packaging/provider.tf — 전체 내용</summary>

<div class="highlight" data-source-path="host/var/lib/gitea-runner/opentofu/contrabass-packaging/provider.tf"><pre><code><span class="nb">terraform</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">required_version</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="s2">"&gt;= 1.6.0"</span>

<span class="w">  </span><span class="nb">required_providers</span><span class="w"> </span><span class="p">{</span>
<span class="w">    </span><span class="nb">vsphere</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="p">{</span>
<span class="w">      </span><span class="na">source</span><span class="w">  </span><span class="o">=</span><span class="w"> </span><span class="s2">"vmware/vsphere"</span>
<span class="w">      </span><span class="na">version</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="s2">"= 2.17.1"</span>
<span class="w">    </span><span class="p">}</span>
<span class="w">  </span><span class="p">}</span>
<span class="p">}</span>

<span class="kr">provider</span><span class="w"> </span><span class="nv">"vsphere"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">vsphere_server</span><span class="w">       </span><span class="o">=</span><span class="w"> </span><span class="nv">var.vcenter_server</span>
<span class="w">  </span><span class="na">allow_unverified_ssl</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="nv">var.allow_unverified_ssl</span>
<span class="p">}</span>
</code></pre></div>

</details>

<details class="analysis-toggle" markdown="1">
<summary>/var/lib/gitea-runner/opentofu/contrabass-packaging/main.tf — 전체 내용</summary>

<div class="highlight" data-source-path="host/var/lib/gitea-runner/opentofu/contrabass-packaging/main.tf"><pre><code><span class="kr">data</span><span class="w"> </span><span class="nc">"vsphere_datacenter"</span><span class="w"> </span><span class="nv">"dc"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">name</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="nv">var.datacenter_name</span>
<span class="p">}</span>

<span class="kr">data</span><span class="w"> </span><span class="nc">"vsphere_host"</span><span class="w"> </span><span class="nv">"host"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">name</span><span class="w">          </span><span class="o">=</span><span class="w"> </span><span class="nv">var.host_name</span>
<span class="w">  </span><span class="na">datacenter_id</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="nv">data.vsphere_datacenter.dc.id</span>
<span class="p">}</span>

<span class="kr">data</span><span class="w"> </span><span class="nc">"vsphere_datastore"</span><span class="w"> </span><span class="nv">"storage"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">name</span><span class="w">          </span><span class="o">=</span><span class="w"> </span><span class="nv">var.datastore_name</span>
<span class="w">  </span><span class="na">datacenter_id</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="nv">data.vsphere_datacenter.dc.id</span>
<span class="p">}</span>

<span class="kr">data</span><span class="w"> </span><span class="nc">"vsphere_virtual_machine"</span><span class="w"> </span><span class="nv">"template"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">name</span><span class="w">          </span><span class="o">=</span><span class="w"> </span><span class="nv">var.template_path</span>
<span class="w">  </span><span class="na">datacenter_id</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="nv">data.vsphere_datacenter.dc.id</span>
<span class="p">}</span>

<span class="kr">resource</span><span class="w"> </span><span class="nc">"vsphere_virtual_machine"</span><span class="w"> </span><span class="nv">"vm"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">for_each</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="nv">var.vms</span>

<span class="w">  </span><span class="na">name</span><span class="w">             </span><span class="o">=</span><span class="w"> </span><span class="nv">each.key</span>
<span class="w">  </span><span class="na">folder</span><span class="w">           </span><span class="o">=</span><span class="w"> </span><span class="nv">var.vm_folder</span>
<span class="w">  </span><span class="na">resource_pool_id</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="nv">data.vsphere_host.host.resource_pool_id</span>
<span class="w">  </span><span class="na">host_system_id</span><span class="w">   </span><span class="o">=</span><span class="w"> </span><span class="nv">data.vsphere_host.host.id</span>
<span class="w">  </span><span class="na">datastore_id</span><span class="w">     </span><span class="o">=</span><span class="w"> </span><span class="nv">data.vsphere_datastore.storage.id</span>

<span class="w">  </span><span class="na">num_cpus</span><span class="w">             </span><span class="o">=</span><span class="w"> </span><span class="nv">data.vsphere_virtual_machine.template.num_cpus</span>
<span class="w">  </span><span class="na">num_cores_per_socket</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="nv">data.vsphere_virtual_machine.template.num_cores_per_socket</span>
<span class="w">  </span><span class="na">memory</span><span class="w">               </span><span class="o">=</span><span class="w"> </span><span class="nv">data.vsphere_virtual_machine.template.memory</span>
<span class="w">  </span><span class="na">guest_id</span><span class="w">             </span><span class="o">=</span><span class="w"> </span><span class="nv">data.vsphere_virtual_machine.template.guest_id</span>
<span class="w">  </span><span class="na">firmware</span><span class="w">             </span><span class="o">=</span><span class="w"> </span><span class="nv">data.vsphere_virtual_machine.template.firmware</span>
<span class="w">  </span><span class="na">scsi_type</span><span class="w">            </span><span class="o">=</span><span class="w"> </span><span class="nv">data.vsphere_virtual_machine.template.scsi_type</span>
<span class="w">  </span><span class="na">nested_hv_enabled</span><span class="w">    </span><span class="o">=</span><span class="w"> </span><span class="nv">var.nested_hv</span>

<span class="w">  </span><span class="err">dynamic</span><span class="w"> </span><span class="s2">"network_interface"</span><span class="w"> </span><span class="p">{</span>
<span class="w">    </span><span class="na">for_each</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="nv">data.vsphere_virtual_machine.template.network_interfaces</span>

<span class="w">    </span><span class="nb">content</span><span class="w"> </span><span class="p">{</span>
<span class="w">      </span><span class="na">network_id</span><span class="w">   </span><span class="o">=</span><span class="w"> </span><span class="nv">network_interface.value.network_id</span>
<span class="w">      </span><span class="na">adapter_type</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="nv">network_interface.value.adapter_type</span>
<span class="w">    </span><span class="p">}</span>
<span class="w">  </span><span class="p">}</span>

<span class="w">  </span><span class="err">dynamic</span><span class="w"> </span><span class="s2">"disk"</span><span class="w"> </span><span class="p">{</span>
<span class="w">    </span><span class="na">for_each</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="nv">data.vsphere_virtual_machine.template.disks</span>

<span class="w">    </span><span class="nb">content</span><span class="w"> </span><span class="p">{</span>
<span class="w">      </span><span class="na">label</span><span class="w">            </span><span class="o">=</span><span class="w"> </span><span class="s2">"disk${disk.key}"</span>
<span class="w">      </span><span class="na">unit_number</span><span class="w">      </span><span class="o">=</span><span class="w"> </span><span class="nv">disk.value.unit_number</span>
<span class="w">      </span><span class="na">size</span><span class="w">             </span><span class="o">=</span><span class="w"> </span><span class="nv">disk.value.size</span>
<span class="w">      </span><span class="na">thin_provisioned</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="nv">disk.value.thin_provisioned</span>
<span class="w">      </span><span class="na">eagerly_scrub</span><span class="w">    </span><span class="o">=</span><span class="w"> </span><span class="nv">disk.value.eagerly_scrub</span>
<span class="w">    </span><span class="p">}</span>
<span class="w">  </span><span class="p">}</span>

<span class="w">  </span><span class="nb">clone</span><span class="w"> </span><span class="p">{</span>
<span class="w">    </span><span class="na">template_uuid</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="nv">data.vsphere_virtual_machine.template.id</span>
<span class="w">    </span><span class="na">linked_clone</span><span class="w">  </span><span class="o">=</span><span class="w"> </span><span class="no">false</span>
<span class="w">    </span><span class="na">timeout</span><span class="w">       </span><span class="o">=</span><span class="w"> </span><span class="m">30</span>

<span class="w">    </span><span class="nb">customize</span><span class="w"> </span><span class="p">{</span>
<span class="w">      </span><span class="na">timeout</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="m">15</span>

<span class="w">      </span><span class="nb">linux_options</span><span class="w"> </span><span class="p">{</span>
<span class="w">        </span><span class="na">host_name</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="nv">each.key</span>
<span class="w">        </span><span class="na">domain</span><span class="w">    </span><span class="o">=</span><span class="w"> </span><span class="nv">var.domain</span>

<span class="w">        </span><span class="na">script_text</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="nf">templatefile</span><span class="p">(</span><span class="s2">"${path.module}/guest-init.sh.tftpl"</span><span class="p">,</span><span class="w"> </span><span class="p">{</span>
<span class="w">          </span><span class="na">ssh_public_key</span><span class="w">            </span><span class="o">=</span><span class="w"> </span><span class="nv">var.ssh_public_key</span>
<span class="w">          </span><span class="na">provider_uplink_interface</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="nv">var.provider_uplink_interface</span>
<span class="w">        </span><span class="p">})</span>
<span class="w">      </span><span class="p">}</span>

<span class="w">      </span><span class="err">dynamic</span><span class="w"> </span><span class="s2">"network_interface"</span><span class="w"> </span><span class="p">{</span>
<span class="w">        </span><span class="na">for_each</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="nv">each.value.ipv4_addresses</span>

<span class="w">        </span><span class="nb">content</span><span class="w"> </span><span class="p">{</span>
<span class="w">          </span><span class="na">ipv4_address</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="nv">network_interface.value</span>
<span class="w">          </span><span class="na">ipv4_netmask</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="nv">var.ipv4_prefixes[network_interface.key</span><span class="p">]</span>
<span class="w">        </span><span class="p">}</span>
<span class="w">      </span><span class="p">}</span>

<span class="w">      </span><span class="nb">network_interface</span><span class="w"> </span><span class="p">{}</span>

<span class="w">      </span><span class="na">ipv4_gateway</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="nv">var.ipv4_gateway</span>
<span class="w">    </span><span class="p">}</span>
<span class="w">  </span><span class="p">}</span>

<span class="w">  </span><span class="na">wait_for_guest_net_timeout</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="m">10</span>

<span class="w">  </span><span class="nb">lifecycle</span><span class="w"> </span><span class="p">{</span>
<span class="w">    </span><span class="nb">precondition</span><span class="w"> </span><span class="p">{</span>
<span class="w">      </span><span class="na">condition</span><span class="w">     </span><span class="o">=</span><span class="w"> </span><span class="nf">length</span><span class="p">(</span><span class="nv">data.vsphere_virtual_machine.template.network_interfaces</span><span class="p">)</span><span class="w"> </span><span class="p">==</span><span class="w"> </span><span class="m">5</span>
<span class="w">      </span><span class="na">error_message</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="s2">"고정 IP용 NIC 4개와 provider uplink 1개가 있는 템플릿을 사용한다."</span>
<span class="w">    </span><span class="p">}</span>
<span class="w">  </span><span class="p">}</span>
<span class="p">}</span>
</code></pre></div>

</details>

<details class="analysis-toggle" markdown="1">
<summary>/var/lib/gitea-runner/opentofu/contrabass-packaging/variables.tf — 전체 내용</summary>

<div class="highlight" data-source-path="host/var/lib/gitea-runner/opentofu/contrabass-packaging/variables.tf"><pre><code><span class="kr">variable</span><span class="w"> </span><span class="nv">"vcenter_server"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">type</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="kt">string</span>
<span class="p">}</span>

<span class="kr">variable</span><span class="w"> </span><span class="nv">"allow_unverified_ssl"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">type</span><span class="w">    </span><span class="o">=</span><span class="w"> </span><span class="kt">bool</span>
<span class="w">  </span><span class="na">default</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="no">true</span>
<span class="p">}</span>

<span class="kr">variable</span><span class="w"> </span><span class="nv">"datacenter_name"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">type</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="kt">string</span>
<span class="p">}</span>

<span class="kr">variable</span><span class="w"> </span><span class="nv">"host_name"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">type</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="kt">string</span>
<span class="p">}</span>

<span class="kr">variable</span><span class="w"> </span><span class="nv">"datastore_name"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">type</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="kt">string</span>
<span class="p">}</span>

<span class="kr">variable</span><span class="w"> </span><span class="nv">"template_path"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">type</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="kt">string</span>
<span class="p">}</span>

<span class="kr">variable</span><span class="w"> </span><span class="nv">"vm_folder"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">type</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="kt">string</span>
<span class="p">}</span>

<span class="kr">variable</span><span class="w"> </span><span class="nv">"domain"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">type</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="kt">string</span>
<span class="p">}</span>

<span class="kr">variable</span><span class="w"> </span><span class="nv">"ipv4_gateway"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">type</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="kt">string</span>
<span class="p">}</span>

<span class="kr">variable</span><span class="w"> </span><span class="nv">"ipv4_prefixes"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">type</span><span class="w">    </span><span class="o">=</span><span class="w"> </span><span class="nf">list</span><span class="p">(</span><span class="kt">number</span><span class="p">)</span>
<span class="w">  </span><span class="na">default</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="p">[</span><span class="m">24</span><span class="p">,</span><span class="w"> </span><span class="m">26</span><span class="p">,</span><span class="w"> </span><span class="m">26</span><span class="p">,</span><span class="w"> </span><span class="m">26</span><span class="p">]</span>

<span class="w">  </span><span class="nb">validation</span><span class="w"> </span><span class="p">{</span>
<span class="w">    </span><span class="na">condition</span><span class="w">     </span><span class="o">=</span><span class="w"> </span><span class="nf">length</span><span class="p">(</span><span class="nv">var.ipv4_prefixes</span><span class="p">)</span><span class="w"> </span><span class="p">==</span><span class="w"> </span><span class="m">4</span><span class="w"> </span><span class="err">&amp;&amp;</span><span class="w"> </span><span class="nf">alltrue</span><span class="p">([</span><span class="err">for</span><span class="w"> </span><span class="err">prefix</span><span class="w"> </span><span class="err">in</span><span class="w"> </span><span class="nv">var.ipv4_prefixes</span><span class="w"> </span><span class="p">:</span><span class="w"> </span><span class="err">prefix</span><span class="w"> </span><span class="err">&gt;</span><span class="p">=</span><span class="w"> </span><span class="m">1</span><span class="w"> </span><span class="err">&amp;&amp;</span><span class="w"> </span><span class="err">prefix</span><span class="w"> </span><span class="err">&lt;</span><span class="p">=</span><span class="w"> </span><span class="m">32</span><span class="p">])</span>
<span class="w">    </span><span class="na">error_message</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="s2">"NIC 순서에 맞는 IPv4 prefix 네 개를 지정한다."</span>
<span class="w">  </span><span class="p">}</span>
<span class="p">}</span>

<span class="kr">variable</span><span class="w"> </span><span class="nv">"nested_hv"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">type</span><span class="w">    </span><span class="o">=</span><span class="w"> </span><span class="kt">bool</span>
<span class="w">  </span><span class="na">default</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="no">true</span>
<span class="p">}</span>

<span class="kr">variable</span><span class="w"> </span><span class="nv">"provider_uplink_interface"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">type</span><span class="w">    </span><span class="o">=</span><span class="w"> </span><span class="kt">string</span>
<span class="w">  </span><span class="na">default</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="s2">"ens38"</span>

<span class="w">  </span><span class="nb">validation</span><span class="w"> </span><span class="p">{</span>
<span class="w">    </span><span class="na">condition</span><span class="w">     </span><span class="o">=</span><span class="w"> </span><span class="nf">can</span><span class="p">(</span><span class="nf">regex</span><span class="p">(</span><span class="s2">"^[A-Za-z][A-Za-z0-9_.:-]*$"</span><span class="p">,</span><span class="w"> </span><span class="nv">var.provider_uplink_interface</span><span class="p">))</span>
<span class="w">    </span><span class="na">error_message</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="s2">"provider uplink에는 인터페이스 이름만 지정한다."</span>
<span class="w">  </span><span class="p">}</span>
<span class="p">}</span>

<span class="kr">variable</span><span class="w"> </span><span class="nv">"ssh_public_key"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">type</span><span class="w">        </span><span class="o">=</span><span class="w"> </span><span class="kt">string</span>
<span class="w">  </span><span class="na">description</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="s2">"Runner 공개키 내용. Workflow가 TOFU_SSH_PUBLIC_KEY 파일에서 읽는다."</span>
<span class="w">  </span><span class="na">default</span><span class="w">     </span><span class="o">=</span><span class="w"> </span><span class="s2">""</span>
<span class="p">}</span>

<span class="kr">variable</span><span class="w"> </span><span class="nv">"vms"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">type</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="nf">map</span><span class="p">(</span><span class="kt">object</span><span class="p">({</span>
<span class="w">    </span><span class="na">ipv4_addresses</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="nf">list</span><span class="p">(</span><span class="kt">string</span><span class="p">)</span>
<span class="w">  </span><span class="p">}))</span>

<span class="w">  </span><span class="nb">validation</span><span class="w"> </span><span class="p">{</span>
<span class="w">    </span><span class="na">condition</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="p">(</span>
<span class="w">      </span><span class="nf">length</span><span class="p">(</span><span class="nv">var.vms</span><span class="p">)</span><span class="w"> </span><span class="err">&gt;</span><span class="w"> </span><span class="m">0</span><span class="w"> </span><span class="err">&amp;&amp;</span>
<span class="w">      </span><span class="nf">alltrue</span><span class="p">([</span><span class="err">for</span><span class="w"> </span><span class="err">vm</span><span class="w"> </span><span class="err">in</span><span class="w"> </span><span class="nf">values</span><span class="p">(</span><span class="nv">var.vms</span><span class="p">)</span><span class="w"> </span><span class="p">:</span><span class="w"> </span><span class="nf">length</span><span class="p">(</span><span class="nv">vm.ipv4_addresses</span><span class="p">)</span><span class="w"> </span><span class="p">==</span><span class="w"> </span><span class="m">4</span><span class="p">])</span><span class="w"> </span><span class="err">&amp;&amp;</span>
<span class="w">      </span><span class="nf">alltrue</span><span class="p">([</span>
<span class="w">        </span><span class="err">for</span><span class="w"> </span><span class="err">ip</span><span class="w"> </span><span class="err">in</span><span class="w"> </span><span class="nf">flatten</span><span class="p">([</span><span class="err">for</span><span class="w"> </span><span class="err">vm</span><span class="w"> </span><span class="err">in</span><span class="w"> </span><span class="nf">values</span><span class="p">(</span><span class="nv">var.vms</span><span class="p">)</span><span class="w"> </span><span class="p">:</span><span class="w"> </span><span class="nv">vm.ipv4_addresses</span><span class="p">])</span><span class="w"> </span><span class="p">:</span>
<span class="w">        </span><span class="nf">can</span><span class="p">(</span><span class="nf">cidrnetmask</span><span class="p">(</span><span class="s2">"${ip}/32"</span><span class="p">))</span>
<span class="w">      </span><span class="p">])</span><span class="w"> </span><span class="err">&amp;&amp;</span>
<span class="w">      </span><span class="nf">length</span><span class="p">(</span><span class="nf">distinct</span><span class="p">(</span><span class="nf">flatten</span><span class="p">([</span><span class="err">for</span><span class="w"> </span><span class="err">vm</span><span class="w"> </span><span class="err">in</span><span class="w"> </span><span class="nf">values</span><span class="p">(</span><span class="nv">var.vms</span><span class="p">)</span><span class="w"> </span><span class="p">:</span><span class="w"> </span><span class="nv">vm.ipv4_addresses</span><span class="p">])))</span><span class="w"> </span><span class="p">==</span>
<span class="w">      </span><span class="nf">length</span><span class="p">(</span><span class="nf">flatten</span><span class="p">([</span><span class="err">for</span><span class="w"> </span><span class="err">vm</span><span class="w"> </span><span class="err">in</span><span class="w"> </span><span class="nf">values</span><span class="p">(</span><span class="nv">var.vms</span><span class="p">)</span><span class="w"> </span><span class="p">:</span><span class="w"> </span><span class="nv">vm.ipv4_addresses</span><span class="p">]))</span>
<span class="w">    </span><span class="p">)</span>
<span class="w">    </span><span class="na">error_message</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="s2">"VM마다 중복되지 않는 유효한 IPv4 주소 4개를 NIC 순서대로 지정한다."</span>
<span class="w">  </span><span class="p">}</span>
<span class="p">}</span>

<span class="kr">variable</span><span class="w"> </span><span class="nv">"bundle_url"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">type</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="kt">string</span>

<span class="w">  </span><span class="nb">validation</span><span class="w"> </span><span class="p">{</span>
<span class="w">    </span><span class="na">condition</span><span class="w">     </span><span class="o">=</span><span class="w"> </span><span class="err">startswith</span><span class="p">(</span><span class="nv">var.bundle_url</span><span class="p">,</span><span class="w"> </span><span class="s2">"https://"</span><span class="p">)</span>
<span class="w">    </span><span class="na">error_message</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="s2">"bundle_url은 HTTPS 주소여야 한다."</span>
<span class="w">  </span><span class="p">}</span>
<span class="p">}</span>

<span class="kr">variable</span><span class="w"> </span><span class="nv">"ssh_private_key_path"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">type</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="kt">string</span>
<span class="p">}</span>

<span class="kr">variable</span><span class="w"> </span><span class="nv">"nexus_user"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">type</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="kt">string</span>
<span class="p">}</span>

<span class="kr">variable</span><span class="w"> </span><span class="nv">"nexus_password"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">type</span><span class="w">      </span><span class="o">=</span><span class="w"> </span><span class="kt">string</span>
<span class="w">  </span><span class="na">sensitive</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="no">true</span>
<span class="p">}</span>

<span class="kr">variable</span><span class="w"> </span><span class="nv">"bundle_sha256"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">type</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="kt">string</span>

<span class="w">  </span><span class="nb">validation</span><span class="w"> </span><span class="p">{</span>
<span class="w">    </span><span class="na">condition</span><span class="w">     </span><span class="o">=</span><span class="w"> </span><span class="nf">can</span><span class="p">(</span><span class="nf">regex</span><span class="p">(</span><span class="s2">"^[0-9a-f]{64}$"</span><span class="p">,</span><span class="w"> </span><span class="nv">var.bundle_sha256</span><span class="p">))</span>
<span class="w">    </span><span class="na">error_message</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="s2">"bundle_sha256에는 64자리 SHA256 값을 지정한다."</span>
<span class="w">  </span><span class="p">}</span>
<span class="p">}</span>

<span class="kr">variable</span><span class="w"> </span><span class="nv">"nexus_skip_verify"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">type</span><span class="w">    </span><span class="o">=</span><span class="w"> </span><span class="kt">bool</span>
<span class="w">  </span><span class="na">default</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="no">true</span>
<span class="p">}</span>

<span class="kr">variable</span><span class="w"> </span><span class="nv">"deploy_vm_name"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">type</span><span class="w">    </span><span class="o">=</span><span class="w"> </span><span class="kt">string</span>
<span class="w">  </span><span class="na">default</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="s2">"runner01"</span>
<span class="p">}</span>

<span class="kr">variable</span><span class="w"> </span><span class="nv">"deploy_directory"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">type</span><span class="w">    </span><span class="o">=</span><span class="w"> </span><span class="kt">string</span>
<span class="w">  </span><span class="na">default</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="s2">"/opt/contrabass-test"</span>

<span class="w">  </span><span class="nb">validation</span><span class="w"> </span><span class="p">{</span>
<span class="w">    </span><span class="na">condition</span><span class="w">     </span><span class="o">=</span><span class="w"> </span><span class="nf">can</span><span class="p">(</span><span class="nf">regex</span><span class="p">(</span><span class="s2">"^/[A-Za-z0-9._/-]+$"</span><span class="p">,</span><span class="w"> </span><span class="nv">var.deploy_directory</span><span class="p">))</span>
<span class="w">    </span><span class="na">error_message</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="s2">"deploy_directory에는 공백 없는 절대 경로를 지정한다."</span>
<span class="w">  </span><span class="p">}</span>
<span class="p">}</span>
</code></pre></div>

</details>

<details class="analysis-toggle" markdown="1">
<summary>/var/lib/gitea-runner/opentofu/contrabass-packaging/outputs.tf — 전체 내용</summary>

<div class="highlight" data-source-path="host/var/lib/gitea-runner/opentofu/contrabass-packaging/outputs.tf"><pre><code><span class="kr">output</span><span class="w"> </span><span class="nv">"vm_info"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="nb">value</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="p">{</span>
<span class="w">    </span><span class="err">for</span><span class="w"> </span><span class="err">name</span><span class="p">,</span><span class="w"> </span><span class="err">vm</span><span class="w"> </span><span class="err">in</span><span class="w"> </span><span class="nv">vsphere_virtual_machine.vm</span><span class="w"> </span><span class="p">:</span><span class="w"> </span><span class="na">name</span><span class="w"> </span><span class="o">=</span><span class="err">&gt;</span><span class="w"> </span><span class="p">{</span>
<span class="w">      </span><span class="na">name</span><span class="w">          </span><span class="o">=</span><span class="w"> </span><span class="nv">vm.name</span>
<span class="w">      </span><span class="na">management_ip</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="nv">var.vms[name].ipv4_addresses[0</span><span class="p">]</span>
<span class="w">    </span><span class="p">}</span>
<span class="w">  </span><span class="p">}</span>
<span class="p">}</span>
</code></pre></div>

</details>

<details class="analysis-toggle" markdown="1">
<summary>/var/lib/gitea-runner/opentofu/contrabass-packaging/deployment.tf — 전체 내용</summary>

<div class="highlight" data-source-path="host/var/lib/gitea-runner/opentofu/contrabass-packaging/deployment.tf"><pre><code><span class="nb">locals</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">deploy_ip</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="nv">var.vms[var.deploy_vm_name].ipv4_addresses[0</span><span class="p">]</span>
<span class="p">}</span>

<span class="kr">resource</span><span class="w"> </span><span class="nc">"terraform_data"</span><span class="w"> </span><span class="nv">"ssh_ready"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">for_each</span><span class="w">         </span><span class="o">=</span><span class="w"> </span><span class="nv">var.vms</span>
<span class="w">  </span><span class="na">triggers_replace</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="nv">vsphere_virtual_machine.vm[each.key].id</span>

<span class="w">  </span><span class="nb">connection</span><span class="w"> </span><span class="p">{</span>
<span class="w">    </span><span class="na">type</span><span class="w">        </span><span class="o">=</span><span class="w"> </span><span class="s2">"ssh"</span>
<span class="w">    </span><span class="na">host</span><span class="w">        </span><span class="o">=</span><span class="w"> </span><span class="nv">each.value.ipv4_addresses[0</span><span class="p">]</span>
<span class="w">    </span><span class="na">user</span><span class="w">        </span><span class="o">=</span><span class="w"> </span><span class="s2">"root"</span>
<span class="w">    </span><span class="na">private_key</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="nf">file</span><span class="p">(</span><span class="nv">var.ssh_private_key_path</span><span class="p">)</span>
<span class="w">    </span><span class="na">timeout</span><span class="w">     </span><span class="o">=</span><span class="w"> </span><span class="s2">"15m"</span>
<span class="w">  </span><span class="p">}</span>

<span class="w">  </span><span class="kr">provisioner</span><span class="w"> </span><span class="nv">"remote-exec"</span><span class="w"> </span><span class="p">{</span>
<span class="w">    </span><span class="na">inline</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="p">[</span>
<span class="w">      </span><span class="s2">"#!/bin/bash"</span><span class="p">,</span>
<span class="w">      </span><span class="s2">"set -euo pipefail"</span><span class="p">,</span>
<span class="w">      </span><span class="s2">"timeout 10m bash -c 'until grep -qx \"guest-init complete\" /var/log/opentofu-guest-init.log 2&gt;/dev/null; do sleep 5; done'"</span><span class="p">,</span>
<span class="w">    </span><span class="p">]</span>
<span class="w">  </span><span class="p">}</span>
<span class="p">}</span>

<span class="kr">resource</span><span class="w"> </span><span class="nc">"terraform_data"</span><span class="w"> </span><span class="nv">"deploy"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">depends_on</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="p">[</span><span class="nv">terraform_data.ssh_ready</span><span class="p">]</span>

<span class="w">  </span><span class="nb">triggers_replace</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="p">{</span>
<span class="w">    </span><span class="na">vm_ids</span><span class="w">        </span><span class="o">=</span><span class="w"> </span><span class="p">[</span><span class="err">for</span><span class="w"> </span><span class="err">name</span><span class="w"> </span><span class="err">in</span><span class="w"> </span><span class="nf">sort</span><span class="p">(</span><span class="nf">keys</span><span class="p">(</span><span class="nv">var.vms</span><span class="p">))</span><span class="w"> </span><span class="p">:</span><span class="w"> </span><span class="nv">vsphere_virtual_machine.vm[name].id</span><span class="p">]</span>
<span class="w">    </span><span class="na">bundle_url</span><span class="w">    </span><span class="o">=</span><span class="w"> </span><span class="nv">var.bundle_url</span>
<span class="w">    </span><span class="na">bundle_sha256</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="nv">var.bundle_sha256</span>
<span class="w">  </span><span class="p">}</span>

<span class="w">  </span><span class="nb">connection</span><span class="w"> </span><span class="p">{</span>
<span class="w">    </span><span class="na">type</span><span class="w">        </span><span class="o">=</span><span class="w"> </span><span class="s2">"ssh"</span>
<span class="w">    </span><span class="na">host</span><span class="w">        </span><span class="o">=</span><span class="w"> </span><span class="nv">local.deploy_ip</span>
<span class="w">    </span><span class="na">user</span><span class="w">        </span><span class="o">=</span><span class="w"> </span><span class="s2">"root"</span>
<span class="w">    </span><span class="na">private_key</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="nf">file</span><span class="p">(</span><span class="nv">var.ssh_private_key_path</span><span class="p">)</span>
<span class="w">    </span><span class="na">timeout</span><span class="w">     </span><span class="o">=</span><span class="w"> </span><span class="s2">"15m"</span>
<span class="w">  </span><span class="p">}</span>

<span class="w">  </span><span class="kr">provisioner</span><span class="w"> </span><span class="nv">"remote-exec"</span><span class="w"> </span><span class="p">{</span>
<span class="w">    </span><span class="na">inline</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="p">[</span>
<span class="w">      </span><span class="s2">"#!/bin/bash"</span><span class="p">,</span>
<span class="w">      </span><span class="s2">"set -euo pipefail"</span><span class="p">,</span>
<span class="w">      </span><span class="s2">"umask 077"</span><span class="p">,</span>
<span class="w">      </span><span class="s2">"mkdir -p '${var.deploy_directory}'"</span><span class="p">,</span>
<span class="w">      </span><span class="s2">"cd '${var.deploy_directory}'"</span><span class="p">,</span>
<span class="w">      </span><span class="s2">"nexus_auth=$(printf '%s' '${base64encode("${var.nexus_user}:${var.nexus_password}")}' | base64 -d)"</span><span class="p">,</span>
<span class="w">      </span><span class="s2">"bundle_url=$(printf '%s' '${base64encode(var.bundle_url)}' | base64 -d)"</span><span class="p">,</span>
<span class="w">      </span><span class="s2">"nexus_auth=\"$${nexus_auth//\\\\/\\\\\\\\}\""</span><span class="p">,</span>
<span class="w">      </span><span class="s2">"nexus_auth=\"$${nexus_auth//\\\"/\\\\\\\"}\""</span><span class="p">,</span>
<span class="w">      </span><span class="s2">"printf 'user = \"%s\"\\n' \"$nexus_auth\" | curl -fsSL --connect-timeout 10 --retry 3 ${var.nexus_skip_verify ? "--insecure" : ""} --config /dev/stdin \"$bundle_url\" -o contrabass-engine-deploy.tar"</span><span class="p">,</span>
<span class="w">      </span><span class="s2">"unset nexus_auth"</span><span class="p">,</span>
<span class="w">      </span><span class="s2">"printf '%s  %s\\n' '${var.bundle_sha256}' contrabass-engine-deploy.tar | sha256sum -c -"</span><span class="p">,</span>
<span class="w">      </span><span class="s2">"tar -xf contrabass-engine-deploy.tar"</span><span class="p">,</span>
<span class="w">      </span><span class="s2">"cd contrabass-engine-deploy"</span><span class="p">,</span>
<span class="w">      </span><span class="s2">"bash ./deploy.sh '${local.deploy_ip}' --accept-eula"</span><span class="p">,</span>
<span class="w">    </span><span class="p">]</span>
<span class="w">  </span><span class="p">}</span>

<span class="w">  </span><span class="kr">provisioner</span><span class="w"> </span><span class="nv">"remote-exec"</span><span class="w"> </span><span class="p">{</span>
<span class="w">    </span><span class="na">inline</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="p">[</span>
<span class="w">      </span><span class="s2">"#!/bin/bash"</span><span class="p">,</span>
<span class="w">      </span><span class="s2">"set -euo pipefail"</span><span class="p">,</span>
<span class="w">      </span><span class="s2">"nerdctl exec nexus true"</span><span class="p">,</span>
<span class="w">      </span><span class="s2">"nerdctl exec okestro-os-ansible true"</span><span class="p">,</span>
<span class="w">    </span><span class="p">]</span>
<span class="w">  </span><span class="p">}</span>

<span class="w">  </span><span class="kr">provisioner</span><span class="w"> </span><span class="nv">"remote-exec"</span><span class="w"> </span><span class="p">{</span>
<span class="w">    </span><span class="na">inline</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="p">[</span>
<span class="w">      </span><span class="s2">"#!/bin/bash"</span><span class="p">,</span>
<span class="w">      </span><span class="s2">"set -euo pipefail"</span><span class="p">,</span>
<span class="w">      </span><span class="s2">"nerdctl exec okestro-os-ansible sh -lc 'cd /root/okestro/okestro-openstack &amp;&amp; ansible-playbook -i inventory/inventory.ini main.yml' 2&gt;&amp;1 | tee /var/log/contrabass-ansible.log"</span><span class="p">,</span>
<span class="w">    </span><span class="p">]</span>
<span class="w">  </span><span class="p">}</span>

<span class="p">}</span>
</code></pre></div>

</details>

<details class="analysis-toggle" markdown="1">
<summary>/var/lib/gitea-runner/opentofu/contrabass-packaging/guest-init.sh.tftpl — 전체 내용</summary>

<div class="highlight" data-source-path="host/var/lib/gitea-runner/opentofu/contrabass-packaging/guest-init.sh.tftpl"><pre><code><span class="ch">#!/bin/bash</span>
<span class="nb">set</span><span class="w"> </span>-eu
<span class="o">[</span><span class="w"> </span><span class="s2">"</span><span class="nv">$1</span><span class="s2">"</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="s2">"postcustomization"</span><span class="w"> </span><span class="o">]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="nb">exit</span><span class="w"> </span><span class="m">0</span>
<span class="nb">exec</span><span class="w"> </span>&gt;&gt;<span class="w"> </span>/var/log/opentofu-guest-init.log<span class="w"> </span><span class="m">2</span>&gt;<span class="p">&amp;</span><span class="m">1</span>

<span class="nv">key</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span><span class="nb">printf</span><span class="w"> </span><span class="s1">'%s'</span><span class="w"> </span><span class="s1">'${base64encode(ssh_public_key)}'</span><span class="w"> </span><span class="p">|</span><span class="w"> </span>base64<span class="w"> </span>-d<span class="k">)</span><span class="s2">"</span>
<span class="nv">uplink</span><span class="o">=</span><span class="s1">'${provider_uplink_interface}'</span>

<span class="k">if</span><span class="w"> </span><span class="o">[</span><span class="w"> </span>-n<span class="w"> </span><span class="s2">"</span><span class="nv">$key</span><span class="s2">"</span><span class="w"> </span><span class="o">]</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">  </span>install<span class="w"> </span>-d<span class="w"> </span>-m<span class="w"> </span><span class="m">700</span><span class="w"> </span>/root/.ssh
<span class="w">  </span>touch<span class="w"> </span>/root/.ssh/authorized_keys
<span class="w">  </span>grep<span class="w"> </span>-qxF<span class="w"> </span>--<span class="w"> </span><span class="s2">"</span><span class="nv">$key</span><span class="s2">"</span><span class="w"> </span>/root/.ssh/authorized_keys<span class="w"> </span><span class="o">||</span>
<span class="w">    </span><span class="nb">printf</span><span class="w"> </span><span class="s1">'%s\n'</span><span class="w"> </span><span class="s2">"</span><span class="nv">$key</span><span class="s2">"</span><span class="w"> </span>&gt;&gt;<span class="w"> </span>/root/.ssh/authorized_keys
<span class="w">  </span>chmod<span class="w"> </span><span class="m">600</span><span class="w"> </span>/root/.ssh/authorized_keys
<span class="w">  </span>restorecon<span class="w"> </span>-R<span class="w"> </span>/root/.ssh
<span class="k">fi</span>

<span class="k">for</span><span class="w"> </span>profile<span class="w"> </span><span class="k">in</span><span class="w"> </span><span class="k">$(</span>nmcli<span class="w"> </span>-g<span class="w"> </span>UUID<span class="w"> </span>connection<span class="w"> </span>show<span class="k">)</span><span class="p">;</span><span class="w"> </span><span class="k">do</span>
<span class="w">  </span><span class="nv">device</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>nmcli<span class="w"> </span>-g<span class="w"> </span>connection.interface-name<span class="w"> </span>connection<span class="w"> </span>show<span class="w"> </span>uuid<span class="w"> </span><span class="s2">"</span><span class="nv">$profile</span><span class="s2">"</span><span class="k">)</span><span class="s2">"</span>
<span class="w">  </span><span class="k">if</span><span class="w"> </span><span class="o">[</span><span class="w"> </span><span class="s2">"</span><span class="nv">$device</span><span class="s2">"</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="s2">"</span><span class="nv">$uplink</span><span class="s2">"</span><span class="w"> </span><span class="o">]</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">    </span>nmcli<span class="w"> </span>connection<span class="w"> </span>modify<span class="w"> </span>uuid<span class="w"> </span><span class="s2">"</span><span class="nv">$profile</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">      </span>ipv4.method<span class="w"> </span>disabled<span class="w"> </span>ipv6.method<span class="w"> </span>disabled<span class="w"> </span>connection.autoconnect<span class="w"> </span>yes
<span class="w">    </span>nmcli<span class="w"> </span>connection<span class="w"> </span>up<span class="w"> </span>uuid<span class="w"> </span><span class="s2">"</span><span class="nv">$profile</span><span class="s2">"</span><span class="w"> </span>ifname<span class="w"> </span><span class="s2">"</span><span class="nv">$uplink</span><span class="s2">"</span>
<span class="w">    </span><span class="nb">echo</span><span class="w"> </span><span class="s1">'guest-init complete'</span>
<span class="w">    </span><span class="nb">exit</span><span class="w"> </span><span class="m">0</span>
<span class="w">  </span><span class="k">fi</span>
<span class="k">done</span>

<span class="nb">echo</span><span class="w"> </span><span class="s2">"No connection profile bound to </span><span class="nv">$uplink</span><span class="s2">"</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="nb">exit</span><span class="w"> </span><span class="m">1</span>
</code></pre></div>

</details>

<details class="analysis-toggle" markdown="1">
<summary>/var/lib/gitea-runner/opentofu/contrabass-packaging/lab.auto.tfvars — 전체 내용</summary>

<div class="highlight" data-source-path="host/var/lib/gitea-runner/opentofu/contrabass-packaging/lab.auto.tfvars"><pre><code><span class="c1"># Site-specific VMware values live here, not in variables.tf.</span>
<span class="na">vcenter_server</span><span class="w">  </span><span class="o">=</span><span class="w"> </span><span class="s2">"203.0.113.10"</span>
<span class="na">datacenter_name</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="s2">"Datacenter"</span>
<span class="na">host_name</span><span class="w">       </span><span class="o">=</span><span class="w"> </span><span class="s2">"203.0.113.11"</span>
<span class="na">datastore_name</span><span class="w">  </span><span class="o">=</span><span class="w"> </span><span class="s2">"ESXi-Local-SSD"</span>
<span class="na">template_path</span><span class="w">   </span><span class="o">=</span><span class="w"> </span><span class="s2">"release-test/template/rocky9.6-template"</span>
<span class="na">vm_folder</span><span class="w">       </span><span class="o">=</span><span class="w"> </span><span class="s2">"release-test"</span>
<span class="na">domain</span><span class="w">          </span><span class="o">=</span><span class="w"> </span><span class="s2">"lab.example.com"</span>
<span class="na">ipv4_gateway</span><span class="w">    </span><span class="o">=</span><span class="w"> </span><span class="s2">"192.0.2.1"</span>
<span class="na">deploy_vm_name</span><span class="w">  </span><span class="o">=</span><span class="w"> </span><span class="s2">"runner01"</span>
<span class="na">ipv4_prefixes</span><span class="w">   </span><span class="o">=</span><span class="w"> </span><span class="p">[</span><span class="m">24</span><span class="p">,</span><span class="w"> </span><span class="m">26</span><span class="p">,</span><span class="w"> </span><span class="m">26</span><span class="p">,</span><span class="w"> </span><span class="m">26</span><span class="p">]</span>

<span class="nb">vms</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="nb">runner01</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="p">{</span>
<span class="w">    </span><span class="na">ipv4_addresses</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="p">[</span><span class="s2">"192.0.2.101", "198.51.100.11", "198.51.100.75", "198.51.100.139"</span><span class="p">]</span>
<span class="w">  </span><span class="p">}</span>
<span class="w">  </span><span class="nb">runner02</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="p">{</span>
<span class="w">    </span><span class="na">ipv4_addresses</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="p">[</span><span class="s2">"192.0.2.102", "198.51.100.12", "198.51.100.76", "198.51.100.140"</span><span class="p">]</span>
<span class="w">  </span><span class="p">}</span>
<span class="w">  </span><span class="nb">runner03</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="p">{</span>
<span class="w">    </span><span class="na">ipv4_addresses</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="p">[</span><span class="s2">"192.0.2.103", "198.51.100.13", "198.51.100.77", "198.51.100.141"</span><span class="p">]</span>
<span class="w">  </span><span class="p">}</span>
<span class="w">  </span><span class="nb">runner04</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="p">{</span>
<span class="w">    </span><span class="na">ipv4_addresses</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="p">[</span><span class="s2">"192.0.2.104", "198.51.100.14", "198.51.100.78", "198.51.100.142"</span><span class="p">]</span>
<span class="w">  </span><span class="p">}</span>
<span class="p">}</span>
</code></pre></div>

</details>

<details class="analysis-toggle" markdown="1">
<summary>/var/lib/gitea-runner/opentofu/contrabass-packaging/.terraform.lock.hcl — 전체 내용</summary>

<div class="highlight" data-source-path="host/var/lib/gitea-runner/opentofu/contrabass-packaging/.terraform.lock.hcl"><pre><code><span class="c1"># This file is maintained automatically by "tofu init".</span>
<span class="c1"># Manual edits may be lost in future updates.</span>

<span class="err">provider</span><span class="w"> </span><span class="s2">"registry.opentofu.org/vmware/vsphere"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">version</span><span class="w">     </span><span class="o">=</span><span class="w"> </span><span class="s2">"2.17.1"</span>
<span class="w">  </span><span class="na">constraints</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="s2">"2.17.1"</span>
<span class="w">  </span><span class="na">hashes</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="p">[</span>
<span class="w">    </span><span class="s2">"h1:hA09gZI8JhXsN+flJic3rnzEgsZSW+YR9EN7Llr+S0k="</span><span class="p">,</span>
<span class="w">    </span><span class="s2">"zh:0617e9e7ee68e7fa9a91a0a8616e5f33e766568c14f71e963716b1ac6c0af21e"</span><span class="p">,</span>
<span class="w">    </span><span class="s2">"zh:07cb27318ef6eb9bcf71a29e85e715d165f43c87c5121cacf940c5a34e882d2c"</span><span class="p">,</span>
<span class="w">    </span><span class="s2">"zh:1124e667e1f74f6eb3bde97b249fbf70903f5780b9b9d4f4379c9dab953adf67"</span><span class="p">,</span>
<span class="w">    </span><span class="s2">"zh:555443b94917e362f00b3daca6952693b73726e8582b71bb416e86872d34ca8c"</span><span class="p">,</span>
<span class="w">    </span><span class="s2">"zh:699b886108cf7d14b5acd19cb083d2a38522f05ffd8820afc7e124e47a61b958"</span><span class="p">,</span>
<span class="w">    </span><span class="s2">"zh:87a9d25d4a413fc52a01328ff34aea3865b2e22504a35b85b77a86712b3792ce"</span><span class="p">,</span>
<span class="w">    </span><span class="s2">"zh:8d779c7d565712ff6f2fec9c464ddf29b5b7be226b3dc377ba942dbfb33321fd"</span><span class="p">,</span>
<span class="w">    </span><span class="s2">"zh:942c79f6790cdf8784159154490db823072b6cf790ae19f31a42df690120c280"</span><span class="p">,</span>
<span class="w">    </span><span class="s2">"zh:95feee6e3325c21144b56e33d54f14e1c72ca10f8b7f2aa91c232eb223fef273"</span><span class="p">,</span>
<span class="w">    </span><span class="s2">"zh:9b12af85486a96aedd8d7984b0ff811a4b42e3d88dad1a3fb4c0b580d04fa425"</span><span class="p">,</span>
<span class="w">    </span><span class="s2">"zh:a5c1855521b0f2bd600ca81927fb046ebd0c6ac48a205bb4d50a512b681a3ed0"</span><span class="p">,</span>
<span class="w">    </span><span class="s2">"zh:a5d4ffaa31f35ec6aabdecf0252fd99aa79d2a5dfcc9f027e6a83cfd606b10d1"</span><span class="p">,</span>
<span class="w">    </span><span class="s2">"zh:b19599b00cbfb39a361f4eaceb6a7820b145fc0c03c45d4567a9b56fb2eac1d6"</span><span class="p">,</span>
<span class="w">    </span><span class="s2">"zh:dcc4882102bd538ced9da0a00c29dd191525ce738430577fab571173c72aeade"</span><span class="p">,</span>
<span class="w">  </span><span class="p">]</span>
<span class="p">}</span>
</code></pre></div>

</details>

<details class="analysis-toggle" markdown="1">
<summary>/var/lib/gitea-runner/opentofu/openstack-smoke/provider.tf — 전체 내용</summary>

<div class="highlight" data-source-path="host/var/lib/gitea-runner/opentofu/openstack-smoke/provider.tf"><pre><code><span class="nb">terraform</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">required_version</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="s2">"&gt;= 1.6.0"</span>

<span class="w">  </span><span class="nb">required_providers</span><span class="w"> </span><span class="p">{</span>
<span class="w">    </span><span class="nb">openstack</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="p">{</span>
<span class="w">      </span><span class="na">source</span><span class="w">  </span><span class="o">=</span><span class="w"> </span><span class="s2">"terraform-provider-openstack/openstack"</span>
<span class="w">      </span><span class="na">version</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="s2">"= 1.53.0"</span>
<span class="w">    </span><span class="p">}</span>
<span class="w">  </span><span class="p">}</span>
<span class="p">}</span>

<span class="kr">provider</span><span class="w"> </span><span class="nv">"openstack"</span><span class="w"> </span><span class="p">{}</span>
</code></pre></div>

</details>

<details class="analysis-toggle" markdown="1">
<summary>/var/lib/gitea-runner/opentofu/openstack-smoke/main.tf — 전체 내용</summary>

<div class="highlight" data-source-path="host/var/lib/gitea-runner/opentofu/openstack-smoke/main.tf"><pre><code><span class="kr">variable</span><span class="w"> </span><span class="nv">"overlay_network_type"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">type</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="kt">string</span>

<span class="w">  </span><span class="nb">validation</span><span class="w"> </span><span class="p">{</span>
<span class="w">    </span><span class="na">condition</span><span class="w">     </span><span class="o">=</span><span class="w"> </span><span class="nf">contains</span><span class="p">([</span><span class="s2">"vxlan", "geneve"</span><span class="p">],</span><span class="w"> </span><span class="nv">var.overlay_network_type</span><span class="p">)</span>
<span class="w">    </span><span class="na">error_message</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="s2">"overlay_network_type must be vxlan or geneve."</span>
<span class="w">  </span><span class="p">}</span>
<span class="p">}</span>

<span class="kr">variable</span><span class="w"> </span><span class="nv">"provider_physical_network"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">type</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="kt">string</span>
<span class="p">}</span>

<span class="kr">variable</span><span class="w"> </span><span class="nv">"provider_cidr"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">type</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="kt">string</span>

<span class="w">  </span><span class="nb">validation</span><span class="w"> </span><span class="p">{</span>
<span class="w">    </span><span class="na">condition</span><span class="w">     </span><span class="o">=</span><span class="w"> </span><span class="nf">can</span><span class="p">(</span><span class="nf">cidrnetmask</span><span class="p">(</span><span class="nv">var.provider_cidr</span><span class="p">))</span>
<span class="w">    </span><span class="na">error_message</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="s2">"provider_cidr에는 올바른 IPv4 CIDR을 지정한다."</span>
<span class="w">  </span><span class="p">}</span>
<span class="p">}</span>

<span class="kr">variable</span><span class="w"> </span><span class="nv">"test_name_prefix"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">type</span><span class="w">    </span><span class="o">=</span><span class="w"> </span><span class="kt">string</span>
<span class="w">  </span><span class="na">default</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="s2">"release-smoke"</span>
<span class="p">}</span>

<span class="kr">variable</span><span class="w"> </span><span class="nv">"image_file"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">type</span><span class="w">    </span><span class="o">=</span><span class="w"> </span><span class="kt">string</span>
<span class="w">  </span><span class="na">default</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="s2">"noble-qemu-okestro2018.qcow2"</span>
<span class="p">}</span>

<span class="kr">variable</span><span class="w"> </span><span class="nv">"overlay_cidr"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">type</span><span class="w">    </span><span class="o">=</span><span class="w"> </span><span class="kt">string</span>
<span class="w">  </span><span class="na">default</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="s2">"203.0.113.64/26"</span>

<span class="w">  </span><span class="nb">validation</span><span class="w"> </span><span class="p">{</span>
<span class="w">    </span><span class="na">condition</span><span class="w">     </span><span class="o">=</span><span class="w"> </span><span class="nf">can</span><span class="p">(</span><span class="nf">cidrnetmask</span><span class="p">(</span><span class="nv">var.overlay_cidr</span><span class="p">))</span>
<span class="w">    </span><span class="na">error_message</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="s2">"overlay_cidr에는 올바른 IPv4 CIDR을 지정한다."</span>
<span class="w">  </span><span class="p">}</span>
<span class="p">}</span>

<span class="kr">variable</span><span class="w"> </span><span class="nv">"provider_allocation_pool"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">type</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="kt">object</span><span class="p">({</span>
<span class="w">    </span><span class="na">start</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="kt">string</span>
<span class="w">    </span><span class="na">end</span><span class="w">   </span><span class="o">=</span><span class="w"> </span><span class="kt">string</span>
<span class="w">  </span><span class="p">})</span>
<span class="p">}</span>

<span class="kr">resource</span><span class="w"> </span><span class="nc">"openstack_images_image_v2"</span><span class="w"> </span><span class="nv">"test"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">name</span><span class="w">             </span><span class="o">=</span><span class="w"> </span><span class="s2">"${var.test_name_prefix}-noble"</span>
<span class="w">  </span><span class="na">local_file_path</span><span class="w">  </span><span class="o">=</span><span class="w"> </span><span class="s2">"${path.module}/${var.image_file}"</span>
<span class="w">  </span><span class="na">container_format</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="s2">"bare"</span>
<span class="w">  </span><span class="na">disk_format</span><span class="w">      </span><span class="o">=</span><span class="w"> </span><span class="s2">"qcow2"</span>

<span class="w">  </span><span class="nb">properties</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="p">{</span>
<span class="w">    </span><span class="na">hw_qemu_guest_agent</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="s2">"yes"</span>
<span class="w">    </span><span class="na">hw_require_fsfreeze</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="s2">"yes"</span>
<span class="w">  </span><span class="p">}</span>
<span class="p">}</span>

<span class="kr">resource</span><span class="w"> </span><span class="nc">"openstack_compute_flavor_v2"</span><span class="w"> </span><span class="nv">"test"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">name</span><span class="w">  </span><span class="o">=</span><span class="w"> </span><span class="s2">"${var.test_name_prefix}-2c2g"</span>
<span class="w">  </span><span class="na">ram</span><span class="w">   </span><span class="o">=</span><span class="w"> </span><span class="m">2048</span>
<span class="w">  </span><span class="na">vcpus</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="m">2</span>
<span class="w">  </span><span class="na">disk</span><span class="w">  </span><span class="o">=</span><span class="w"> </span><span class="m">0</span>
<span class="p">}</span>

<span class="kr">resource</span><span class="w"> </span><span class="nc">"openstack_networking_network_v2"</span><span class="w"> </span><span class="nv">"overlay"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">name</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="s2">"${var.test_name_prefix}-overlay"</span>

<span class="w">  </span><span class="nb">value_specs</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="p">{</span>
<span class="w">    </span><span class="s2">"provider:network_type"</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="nv">var.overlay_network_type</span>
<span class="w">  </span><span class="p">}</span>
<span class="p">}</span>

<span class="kr">resource</span><span class="w"> </span><span class="nc">"openstack_networking_subnet_v2"</span><span class="w"> </span><span class="nv">"overlay"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">name</span><span class="w">        </span><span class="o">=</span><span class="w"> </span><span class="s2">"${var.test_name_prefix}-overlay-subnet"</span>
<span class="w">  </span><span class="na">network_id</span><span class="w">  </span><span class="o">=</span><span class="w"> </span><span class="nv">openstack_networking_network_v2.overlay.id</span>
<span class="w">  </span><span class="na">cidr</span><span class="w">        </span><span class="o">=</span><span class="w"> </span><span class="nv">var.overlay_cidr</span>
<span class="w">  </span><span class="na">ip_version</span><span class="w">  </span><span class="o">=</span><span class="w"> </span><span class="m">4</span>
<span class="w">  </span><span class="na">enable_dhcp</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="no">true</span>
<span class="w">  </span><span class="na">no_gateway</span><span class="w">  </span><span class="o">=</span><span class="w"> </span><span class="no">true</span>
<span class="p">}</span>

<span class="kr">resource</span><span class="w"> </span><span class="nc">"openstack_networking_network_v2"</span><span class="w"> </span><span class="nv">"provider"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">name</span><span class="w">     </span><span class="o">=</span><span class="w"> </span><span class="s2">"${var.test_name_prefix}-provider"</span>
<span class="w">  </span><span class="na">external</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="no">true</span>

<span class="w">  </span><span class="nb">value_specs</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="p">{</span>
<span class="w">    </span><span class="s2">"provider:network_type"</span><span class="w">     </span><span class="o">=</span><span class="w"> </span><span class="s2">"flat"</span>
<span class="w">    </span><span class="s2">"provider:physical_network"</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="nv">var.provider_physical_network</span>
<span class="w">  </span><span class="p">}</span>
<span class="p">}</span>

<span class="kr">resource</span><span class="w"> </span><span class="nc">"openstack_networking_subnet_v2"</span><span class="w"> </span><span class="nv">"provider"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">name</span><span class="w">        </span><span class="o">=</span><span class="w"> </span><span class="s2">"${var.test_name_prefix}-provider-subnet"</span>
<span class="w">  </span><span class="na">network_id</span><span class="w">  </span><span class="o">=</span><span class="w"> </span><span class="nv">openstack_networking_network_v2.provider.id</span>
<span class="w">  </span><span class="na">cidr</span><span class="w">        </span><span class="o">=</span><span class="w"> </span><span class="nv">var.provider_cidr</span>
<span class="w">  </span><span class="na">ip_version</span><span class="w">  </span><span class="o">=</span><span class="w"> </span><span class="m">4</span>
<span class="w">  </span><span class="na">enable_dhcp</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="no">true</span>
<span class="w">  </span><span class="na">no_gateway</span><span class="w">  </span><span class="o">=</span><span class="w"> </span><span class="no">true</span>

<span class="w">  </span><span class="nb">allocation_pool</span><span class="w"> </span><span class="p">{</span>
<span class="w">    </span><span class="na">start</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="nv">var.provider_allocation_pool.start</span>
<span class="w">    </span><span class="na">end</span><span class="w">   </span><span class="o">=</span><span class="w"> </span><span class="nv">var.provider_allocation_pool.end</span>
<span class="w">  </span><span class="p">}</span>
<span class="p">}</span>

<span class="kr">resource</span><span class="w"> </span><span class="nc">"openstack_compute_instance_v2"</span><span class="w"> </span><span class="nv">"test"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">name</span><span class="w">      </span><span class="o">=</span><span class="w"> </span><span class="s2">"${var.test_name_prefix}-vm"</span>
<span class="w">  </span><span class="na">flavor_id</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="nv">openstack_compute_flavor_v2.test.id</span>

<span class="w">  </span><span class="nb">block_device</span><span class="w"> </span><span class="p">{</span>
<span class="w">    </span><span class="na">uuid</span><span class="w">                  </span><span class="o">=</span><span class="w"> </span><span class="nv">openstack_images_image_v2.test.id</span>
<span class="w">    </span><span class="na">source_type</span><span class="w">           </span><span class="o">=</span><span class="w"> </span><span class="s2">"image"</span>
<span class="w">    </span><span class="na">destination_type</span><span class="w">      </span><span class="o">=</span><span class="w"> </span><span class="s2">"volume"</span>
<span class="w">    </span><span class="na">volume_size</span><span class="w">           </span><span class="o">=</span><span class="w"> </span><span class="m">20</span>
<span class="w">    </span><span class="na">boot_index</span><span class="w">            </span><span class="o">=</span><span class="w"> </span><span class="m">0</span>
<span class="w">    </span><span class="na">delete_on_termination</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="no">true</span>
<span class="w">  </span><span class="p">}</span>

<span class="w">  </span><span class="nb">network</span><span class="w"> </span><span class="p">{</span>
<span class="w">    </span><span class="na">uuid</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="nv">openstack_networking_network_v2.overlay.id</span>
<span class="w">  </span><span class="p">}</span>

<span class="w">  </span><span class="nb">network</span><span class="w"> </span><span class="p">{</span>
<span class="w">    </span><span class="na">uuid</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="nv">openstack_networking_network_v2.provider.id</span>
<span class="w">  </span><span class="p">}</span>

<span class="w">  </span><span class="na">depends_on</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="p">[</span>
<span class="w">    </span><span class="nv">openstack_networking_subnet_v2.overlay</span><span class="p">,</span>
<span class="w">    </span><span class="nv">openstack_networking_subnet_v2.provider</span><span class="p">,</span>
<span class="w">  </span><span class="p">]</span>
<span class="p">}</span>

<span class="kr">resource</span><span class="w"> </span><span class="nc">"openstack_blockstorage_volume_v3"</span><span class="w"> </span><span class="nv">"test"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">name</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="s2">"${var.test_name_prefix}-data"</span>
<span class="w">  </span><span class="na">size</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="m">1</span>
<span class="p">}</span>

<span class="kr">resource</span><span class="w"> </span><span class="nc">"openstack_compute_volume_attach_v2"</span><span class="w"> </span><span class="nv">"test"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">instance_id</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="nv">openstack_compute_instance_v2.test.id</span>
<span class="w">  </span><span class="na">volume_id</span><span class="w">   </span><span class="o">=</span><span class="w"> </span><span class="nv">openstack_blockstorage_volume_v3.test.id</span>
<span class="p">}</span>

<span class="kr">output</span><span class="w"> </span><span class="nv">"smoke_result"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="nb">value</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="p">{</span>
<span class="w">    </span><span class="na">instance_id</span><span class="w">        </span><span class="o">=</span><span class="w"> </span><span class="nv">openstack_compute_instance_v2.test.id</span>
<span class="w">    </span><span class="na">image_status</span><span class="w">       </span><span class="o">=</span><span class="w"> </span><span class="nv">openstack_images_image_v2.test.status</span>
<span class="w">    </span><span class="na">power_state</span><span class="w">        </span><span class="o">=</span><span class="w"> </span><span class="nv">openstack_compute_instance_v2.test.power_state</span>
<span class="w">    </span><span class="na">network_ids</span><span class="w">        </span><span class="o">=</span><span class="w"> </span><span class="p">[</span><span class="err">for</span><span class="w"> </span><span class="err">nic</span><span class="w"> </span><span class="err">in</span><span class="w"> </span><span class="nv">openstack_compute_instance_v2.test.network</span><span class="w"> </span><span class="p">:</span><span class="w"> </span><span class="nv">nic.uuid</span><span class="p">]</span>
<span class="w">    </span><span class="na">volume_id</span><span class="w">          </span><span class="o">=</span><span class="w"> </span><span class="nv">openstack_blockstorage_volume_v3.test.id</span>
<span class="w">    </span><span class="na">attached_volume_id</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="nv">openstack_compute_volume_attach_v2.test.volume_id</span>
<span class="w">  </span><span class="p">}</span>
<span class="p">}</span>
</code></pre></div>

</details>

<details class="analysis-toggle" markdown="1">
<summary>/var/lib/gitea-runner/opentofu/openstack-smoke/lab.auto.tfvars — 전체 내용</summary>

<div class="highlight" data-source-path="host/var/lib/gitea-runner/opentofu/openstack-smoke/lab.auto.tfvars"><pre><code><span class="na">overlay_network_type</span><span class="w">      </span><span class="o">=</span><span class="w"> </span><span class="s2">"vxlan"</span>
<span class="na">provider_physical_network</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="s2">"external"</span>
<span class="na">provider_cidr</span><span class="w">             </span><span class="o">=</span><span class="w"> </span><span class="s2">"203.0.113.128/26"</span>
<span class="nb">provider_allocation_pool</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">start</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="s2">"203.0.113.151"</span>
<span class="w">  </span><span class="na">end</span><span class="w">   </span><span class="o">=</span><span class="w"> </span><span class="s2">"203.0.113.160"</span>
<span class="p">}</span>
</code></pre></div>

</details>

<details class="analysis-toggle" markdown="1">
<summary>/var/lib/gitea-runner/opentofu/openstack-smoke/.terraform.lock.hcl — 전체 내용</summary>

<div class="highlight" data-source-path="host/var/lib/gitea-runner/opentofu/openstack-smoke/.terraform.lock.hcl"><pre><code><span class="c1"># This file is maintained automatically by "tofu init".</span>
<span class="c1"># Manual edits may be lost in future updates.</span>

<span class="err">provider</span><span class="w"> </span><span class="s2">"registry.opentofu.org/terraform-provider-openstack/openstack"</span><span class="w"> </span><span class="p">{</span>
<span class="w">  </span><span class="na">version</span><span class="w">     </span><span class="o">=</span><span class="w"> </span><span class="s2">"1.53.0"</span>
<span class="w">  </span><span class="na">constraints</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="s2">"1.53.0"</span>
<span class="w">  </span><span class="na">hashes</span><span class="w"> </span><span class="o">=</span><span class="w"> </span><span class="p">[</span>
<span class="w">    </span><span class="s2">"h1:YLGvYkSuagyP5orUTyKNK+JhzS17EFTUDpZ5R5/fFv4="</span><span class="p">,</span>
<span class="w">    </span><span class="s2">"zh:09da7ca98ffd3de7b9ce36c4c13446212a6e763ba1162be71b50f95d453cb68e"</span><span class="p">,</span>
<span class="w">    </span><span class="s2">"zh:14041bcbb87312411d88612056ed185650bfd01284b8ea0761ce8105a331708e"</span><span class="p">,</span>
<span class="w">    </span><span class="s2">"zh:35bf4c788fdbc17c8e40ebc7b33c7de4b45a2fa2efaa657b10f0e3bd37c9627f"</span><span class="p">,</span>
<span class="w">    </span><span class="s2">"zh:46ede8ef4cfa12d654c538afc1e1ec34a1f3e8eb4e986ee23dceae398b7176a6"</span><span class="p">,</span>
<span class="w">    </span><span class="s2">"zh:59675734990dab1e8d87997853ea75e8104bba730b3f5a7146ac735540c9d6bf"</span><span class="p">,</span>
<span class="w">    </span><span class="s2">"zh:6de52428849806498670e827b54810be7510a2a79449602c1aede4235a0ec036"</span><span class="p">,</span>
<span class="w">    </span><span class="s2">"zh:78b2a20601272afceffac8f8ca78a6b647b84196c0dd8dc710fae297f6be15a4"</span><span class="p">,</span>
<span class="w">    </span><span class="s2">"zh:7c41ed3a4fac09677e676ecf9f9edd1e38eef449e656cb01a848d2c799c6de8f"</span><span class="p">,</span>
<span class="w">    </span><span class="s2">"zh:852800228f4118a4aa6cfaa4468b851247cbed6f037fd204f08de69eb1edc149"</span><span class="p">,</span>
<span class="w">    </span><span class="s2">"zh:86d618e7f9a07d978b8bc4b190be350a00de64ec535f9c8f5dfe133542a55483"</span><span class="p">,</span>
<span class="w">    </span><span class="s2">"zh:963a9e72b66d8bcf43de9b14a674ae3ca3719ce2f829217f7a65b66fc3773397"</span><span class="p">,</span>
<span class="w">    </span><span class="s2">"zh:a8e72ab67795071bda61f99a6de3d2d40122fb51971768fd75e1324abe874ced"</span><span class="p">,</span>
<span class="w">    </span><span class="s2">"zh:ce1890cf3af17d569af3bc7673cec0a8f78e6f5d701767593f3d29c551f44848"</span><span class="p">,</span>
<span class="w">    </span><span class="s2">"zh:e6f1b96eb684f527a47f71923f268c86a36d7894751b31ee9e726d7502a639cd"</span><span class="p">,</span>
<span class="w">  </span><span class="p">]</span>
<span class="p">}</span>
</code></pre></div>

</details>

```bash title="시험 프로젝트 배치"
install -d -m 0750 -o gitea-runner -g gitea-runner /var/lib/gitea-runner/opentofu
cp -a "${CONFIG_SRC}/host/var/lib/gitea-runner/opentofu/." /var/lib/gitea-runner/opentofu/
chown -R gitea-runner:gitea-runner /var/lib/gitea-runner/opentofu
chmod -R go-rwx /var/lib/gitea-runner/opentofu
vi /var/lib/gitea-runner/opentofu/contrabass-packaging/lab.auto.tfvars
vi /var/lib/gitea-runner/opentofu/openstack-smoke/lab.auto.tfvars
```

주소 예시를 실제 예약한 네트워크로 모두 바꾼다. NIC별 IP·prefix·Port group 순서와 Ansible 설정을 맞춘다. Cluster가 아닌 ESXi host의 resource_pool_id·host_system_id를 사용한다.

OpenStack 시험의 QCOW2는 **미리 로컬에 둔다.** VM의 Private Nexus에서 추가 다운로드하는 코드는 없다. 네트워크는 vxlan과 provider 두 개이며, OVN으로 바꾸면 overlay_network_type을 geneve로 지정한다.

```bash title="로컬 OpenStack 시험 이미지 준비"
source /etc/gitea-runner-env/bundle-pipeline.env
install -m 0600 -o gitea-runner -g gitea-runner \
  "${SEED_DIR}/raw/vm-image/noble-qemu-okestro2018.qcow2" \
  "${OPENSTACK_TEST_DIR}/${OPENSTACK_IMAGE_FILE}"
```

provider 최초 설치는 외부 Registry 통신이 필요하다. 폐쇄된 Runner라면 provider mirror를 별도로 준비한다. `.terraform.lock.hcl`은 provider 버전·해시를 고정하므로 유지하고, State·plan·인증정보는 Git에 넣지 않는다.

이 단계에서 apply하지 않는다. VM 생성과 Ansible 실행은 Tag Workflow에서 시작한다.

</div>

---

## 12. 최종 Workflow 반영과 Runner 기동

<details class="analysis-toggle" markdown="1">
<summary>.gitea/workflows/publish-manifest.yaml — 전체 내용</summary>

<div class="highlight" data-source-path="repository/workflows/publish-manifest.yaml"><pre><code><span class="nt">name</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">Publish Contrabass Engine Release</span>

<span class="s">"on"</span><span class="p p-Indicator">:</span>
<span class="w">  </span><span class="nt">push</span><span class="p">:</span>
<span class="w">    </span><span class="nt">tags</span><span class="p">:</span>
<span class="w">      </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="s">"v*"</span>
<span class="w">  </span><span class="nt">workflow_dispatch</span><span class="p">:</span>
<span class="w">    </span><span class="nt">inputs</span><span class="p">:</span>
<span class="w">      </span><span class="nt">release_tag</span><span class="p">:</span>
<span class="w">        </span><span class="nt">description</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">Existing release tag (for example, v4.2.5)</span>
<span class="w">        </span><span class="nt">required</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">true</span>

<span class="nt">jobs</span><span class="p">:</span>
<span class="w">  </span><span class="nt">release</span><span class="p">:</span>
<span class="w">    </span><span class="nt">runs-on</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">contrabass-engine-release</span>
<span class="w">    </span><span class="nt">env</span><span class="p">:</span>
<span class="w">      </span><span class="nt">EVENT_REF_NAME</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">$&#123;&#123; gitea.ref_name &#125;&#125;</span>
<span class="w">      </span><span class="nt">EVENT_COMMIT</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">$&#123;&#123; gitea.sha &#125;&#125;</span>
<span class="w">      </span><span class="nt">MANUAL_RELEASE_TAG</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">$&#123;&#123; inputs.release_tag &#125;&#125;</span>
<span class="w">      </span><span class="nt">REPO_READ_TOKEN</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">$&#123;&#123; secrets.REPO_READ_TOKEN &#125;&#125;</span>
<span class="w">      </span><span class="nt">NEXUS_PASSWORD</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">$&#123;&#123; secrets.NEXUS_RUNNER_PASSWORD &#125;&#125;</span>
<span class="w">      </span><span class="nt">VSPHERE_USER</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">$&#123;&#123; secrets.VSPHERE_USER &#125;&#125;</span>
<span class="w">      </span><span class="nt">VSPHERE_PASSWORD</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">$&#123;&#123; secrets.VSPHERE_PASSWORD &#125;&#125;</span>

<span class="w">    </span><span class="nt">steps</span><span class="p">:</span>
<span class="w">      </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">name</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">Shallow clone release tag</span>
<span class="w">        </span><span class="nt">shell</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">bash</span>
<span class="w">        </span><span class="nt">run</span><span class="p">:</span><span class="w"> </span><span class="p p-Indicator">|</span>
<span class="w">          </span><span class="no">set -euo pipefail</span>
<span class="w">          </span><span class="no">umask 077</span>
<span class="w">          </span><span class="no">rm -f -- vm-cleanup.enabled test-passed.sha256 staging-upload.enabled release-policy.yaml staging-info.yaml bundle-published.enabled</span>
<span class="w">          </span><span class="no">source /etc/gitea-runner-env/bundle-pipeline.env</span>
<span class="w">          </span><span class="no">release_tag="${MANUAL_RELEASE_TAG:-${EVENT_REF_NAME&#125;&#125;"</span>
<span class="w">          </span><span class="no">[[ "${release_tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]</span>
<span class="w">          </span><span class="no">[[ -n "${REPO_READ_TOKEN}" ]]</span>
<span class="w">          </span><span class="no">GIT_CONFIG_COUNT=2 \</span>
<span class="w">          </span><span class="no">GIT_CONFIG_KEY_0=http.sslVerify GIT_CONFIG_VALUE_0="$([[ "${TLS_SKIP_VERIFY}" == true ]] &amp;&amp; echo false || echo true)" \</span>
<span class="w">          </span><span class="no">GIT_CONFIG_KEY_1=http.extraHeader \</span>
<span class="w">          </span><span class="no">GIT_CONFIG_VALUE_1="Authorization: token ${REPO_READ_TOKEN}" \</span>
<span class="w">          </span><span class="no">git clone \</span>
<span class="w">            </span><span class="no">--depth=1 --single-branch --branch "${release_tag}" \</span>
<span class="w">            </span><span class="no">"${GITEA_REPO_URL}" \</span>
<span class="w">            </span><span class="no">source</span>
<span class="w">          </span><span class="no">if [[ -z "${MANUAL_RELEASE_TAG}" ]]; then</span>
<span class="w">            </span><span class="no"># Accept annotated tags too, while pinning this push event's commit.</span>
<span class="w">            </span><span class="no">test "$(git -C source rev-parse HEAD)" = "$(git -C source rev-parse "${EVENT_COMMIT}^{commit}")"</span>
<span class="w">          </span><span class="no">fi</span>

<span class="w">      </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">name</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">Select tests from PR label or patch tag</span>
<span class="w">        </span><span class="nt">shell</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">bash</span>
<span class="w">        </span><span class="nt">run</span><span class="p">:</span><span class="w"> </span><span class="p p-Indicator">|</span>
<span class="w">          </span><span class="no">set -euo pipefail</span>
<span class="w">          </span><span class="no">source /etc/gitea-runner-env/bundle-pipeline.env</span>
<span class="w">          </span><span class="no">source "${BUNDLE_BUILDER_DIR}/common.sh"</span>
<span class="w">          </span><span class="no">select_test_mode source "${MANUAL_RELEASE_TAG:-${EVENT_REF_NAME&#125;&#125;" release-policy.yaml</span>
<span class="w">          </span><span class="no">mode="$(yaml_value release-policy.yaml test_mode)"</span>
<span class="w">          </span><span class="no">[[ "${mode}" == full || "${mode}" == skip ]]</span>
<span class="w">          </span><span class="no">printf 'TEST_MODE=%s\n' "${mode}" &gt;&gt; "${GITHUB_ENV}"</span>

<span class="w">      </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">name</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">Publish manifest, build bundle</span>
<span class="w">        </span><span class="nt">shell</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">bash</span>
<span class="w">        </span><span class="nt">run</span><span class="p">:</span><span class="w"> </span><span class="p p-Indicator">|</span>
<span class="w">          </span><span class="no">set -euo pipefail</span>
<span class="w">          </span><span class="no">source /etc/gitea-runner-env/bundle-pipeline.env</span>
<span class="w">          </span><span class="no">export GITEA_REF_NAME="${MANUAL_RELEASE_TAG:-${EVENT_REF_NAME&#125;&#125;"</span>
<span class="w">          </span><span class="no">export GITEA_COMMIT="$(git -C source rev-parse HEAD)"</span>
<span class="w">          </span><span class="no">bash "${BUNDLE_BUILDER_DIR}/publish-manifest.sh" source/release/manifest.yaml release-info.yaml</span>
<span class="w">          </span><span class="no">printf '%s\n' "${NEXUS_PASSWORD}" \</span>
<span class="w">            </span><span class="no">| sudo -n /usr/local/sbin/build-private-release "${GITEA_REF_NAME}" "$(realpath source)"</span>

<span class="w">      </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">name</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">Fingerprint bundle and stage full-test candidate</span>
<span class="w">        </span><span class="nt">shell</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">bash</span>
<span class="w">        </span><span class="nt">run</span><span class="p">:</span><span class="w"> </span><span class="p p-Indicator">|</span>
<span class="w">          </span><span class="no">set -euo pipefail</span>
<span class="w">          </span><span class="no">umask 077</span>
<span class="w">          </span><span class="no">source /etc/gitea-runner-env/bundle-pipeline.env</span>
<span class="w">          </span><span class="no">source "${BUNDLE_BUILDER_DIR}/common.sh"</span>
<span class="w">          </span><span class="no">: "${NEXUS_PASSWORD:?Missing CI publishing password}"</span>
<span class="w">          </span><span class="no">: "${STAGING_REPOSITORY:?Set STAGING_REPOSITORY}"</span>
<span class="w">          </span><span class="no">[[ "${STAGING_REPOSITORY}" != "${BUNDLE_REPOSITORY}" ]]</span>

<span class="w">          </span><span class="no">manifest_id="$(yaml_value release-info.yaml manifest_id)"</span>
<span class="w">          </span><span class="no">[[ "${manifest_id}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]</span>
<span class="w">          </span><span class="no">bundle="${BUNDLE_WORK_DIR}/${manifest_id}.tar"</span>
<span class="w">          </span><span class="no">test -s "${bundle}"</span>
<span class="w">          </span><span class="no">sha="$(file_sha256 "${bundle}")"</span>
<span class="w">          </span><span class="no">[[ "${sha}" == "$(awk '{print $1; exit}' "${bundle}.sha256")" ]]</span>

<span class="w">          </span><span class="no">path="candidates/${manifest_id}/${sha}/contrabass-engine-deploy.tar"</span>
<span class="w">          </span><span class="no">url="${NEXUS_URL%/}/repository/${STAGING_REPOSITORY}/${path}"</span>
<span class="w">          </span><span class="no">printf '%s\n' "bundle_path: ${path}" "bundle_sha256: ${sha}" &gt; staging-info.yaml</span>
<span class="w">          </span><span class="no">printf '%s  %s\n' "${sha}" contrabass-engine-deploy.tar &gt; staging.sha256</span>
<span class="w">          </span><span class="no">if [[ "${TEST_MODE:?Missing release policy}" == skip ]]; then</span>
<span class="w">            </span><span class="no">echo 'Deployment tests intentionally skipped; no VM or staging upload.'</span>
<span class="w">            </span><span class="no">exit 0</span>
<span class="w">          </span><span class="no">fi</span>
<span class="w">          </span><span class="no">touch staging-upload.enabled</span>

<span class="w">          </span><span class="no">if nexus_get_optional "${url}.sha256" staging.remote.sha256; then</span>
<span class="w">            </span><span class="no">[[ "$(awk '{print $1; exit}' staging.remote.sha256)" == "${sha}" ]]</span>
<span class="w">          </span><span class="no">else</span>
<span class="w">            </span><span class="no">nexus_curl -fsS --retry "${HTTP_RETRY_COUNT}" \</span>
<span class="w">              </span><span class="no">--upload-file "${bundle}" "${url}"</span>
<span class="w">            </span><span class="no">nexus_curl -fsS --retry "${HTTP_RETRY_COUNT}" \</span>
<span class="w">              </span><span class="no">--upload-file staging.sha256 "${url}.sha256"</span>
<span class="w">          </span><span class="no">fi</span>

<span class="w">      </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">name</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">Test release with OpenTofu</span>
<span class="w">        </span><span class="nt">if</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">env.TEST_MODE == 'full'</span>
<span class="w">        </span><span class="nt">shell</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">bash</span>
<span class="w">        </span><span class="nt">run</span><span class="p">:</span><span class="w"> </span><span class="p p-Indicator">|</span>
<span class="w">          </span><span class="no">set -euo pipefail</span>
<span class="w">          </span><span class="no">umask 077</span>
<span class="w">          </span><span class="no">source /etc/gitea-runner-env/bundle-pipeline.env</span>
<span class="w">          </span><span class="no">job_dir="${PWD}"</span>
<span class="w">          </span><span class="no">rm -f -- "${job_dir}/vm-cleanup.enabled" "${job_dir}/test-passed.sha256"</span>
<span class="w">          </span><span class="no">source "${BUNDLE_BUILDER_DIR}/common.sh"</span>
<span class="w">          </span><span class="no">export_test_inputs staging-info.yaml</span>

<span class="w">          </span><span class="no">: "${TOFU_PROJECT_DIR:?Set TOFU_PROJECT_DIR}"</span>
<span class="w">          </span><span class="no">: "${TOFU_SSH_PRIVATE_KEY:?Set TOFU_SSH_PRIVATE_KEY}"</span>
<span class="w">          </span><span class="no">: "${NEXUS_URL:?Set NEXUS_URL}"</span>
<span class="w">          </span><span class="no">: "${BUNDLE_REPOSITORY:?Set BUNDLE_REPOSITORY}"</span>
<span class="w">          </span><span class="no">: "${VSPHERE_USER:?Set VSPHERE_USER secret}"</span>
<span class="w">          </span><span class="no">: "${VSPHERE_PASSWORD:?Set VSPHERE_PASSWORD secret}"</span>
<span class="w">          </span><span class="no">: "${TF_VAR_nexus_user:?Set NEXUS_USER}"</span>
<span class="w">          </span><span class="no">: "${TF_VAR_nexus_password:?Set NEXUS_RUNNER_PASSWORD secret}"</span>
<span class="w">          </span><span class="no">test -r "${TOFU_SSH_PRIVATE_KEY}"</span>
<span class="w">          </span><span class="no">test -s "${TOFU_PROJECT_DIR}/deployment.tf"</span>

<span class="w">          </span><span class="no">tag="$(yaml_value release-info.yaml release_tag)"</span>
<span class="w">          </span><span class="no">[[ "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]</span>
<span class="w">          </span><span class="no">cd "${TOFU_PROJECT_DIR}"</span>
<span class="w">          </span><span class="no">exec 9&gt;.ci.lock</span>
<span class="w">          </span><span class="no">flock -n 9 || { echo 'OpenTofu project is already in use.' &gt;&amp;2; exit 1; }</span>

<span class="w">          </span><span class="no">tofu init -input=false -no-color</span>
<span class="w">          </span><span class="no">tofu fmt -check</span>
<span class="w">          </span><span class="no">tofu validate -no-color</span>

<span class="w">          </span><span class="no">if [[ -f terraform.tfstate ]]; then</span>
<span class="w">            </span><span class="no">managed="$(tofu state list)"</span>
<span class="w">            </span><span class="no">if grep -q '^vsphere_virtual_machine\.vm\[' &lt;&lt;&lt; "${managed}"; then</span>
<span class="w">              </span><span class="no">echo 'Previous test VMs remain. Review and clean them manually before the next test.' &gt;&amp;2</span>
<span class="w">              </span><span class="no">exit 1</span>
<span class="w">            </span><span class="no">fi</span>
<span class="w">          </span><span class="no">fi</span>

<span class="w">          </span><span class="no">echo "Test release: ${tag}"</span>
<span class="w">          </span><span class="no">touch "${job_dir}/vm-cleanup.enabled"</span>
<span class="w">          </span><span class="no">tofu plan -input=false -no-color -out=deploy.tfplan</span>
<span class="w">          </span><span class="no">tofu apply -input=false -no-color deploy.tfplan</span>

<span class="w">      </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">name</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">Test OpenStack functions</span>
<span class="w">        </span><span class="nt">if</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">env.TEST_MODE == 'full'</span>
<span class="w">        </span><span class="nt">shell</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">bash</span>
<span class="w">        </span><span class="nt">env</span><span class="p">:</span>
<span class="w">          </span><span class="nt">OS_PASSWORD</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">$&#123;&#123; secrets.OPENSTACK_PASSWORD &#125;&#125;</span>
<span class="w">        </span><span class="nt">run</span><span class="p">:</span><span class="w"> </span><span class="p p-Indicator">|</span>
<span class="w">          </span><span class="no">set -euo pipefail</span>
<span class="w">          </span><span class="no">umask 077</span>
<span class="w">          </span><span class="no">job_dir="${PWD}"</span>
<span class="w">          </span><span class="no">source /etc/gitea-runner-env/bundle-pipeline.env</span>
<span class="w">          </span><span class="no">source "${BUNDLE_BUILDER_DIR}/common.sh"</span>
<span class="w">          </span><span class="no">: "${OPENSTACK_TEST_DIR:?Set OPENSTACK_TEST_DIR}"</span>
<span class="w">          </span><span class="no">: "${OS_PASSWORD:?Set OPENSTACK_PASSWORD secret}"</span>
<span class="w">          </span><span class="no">test -f "${job_dir}/vm-cleanup.enabled"</span>

<span class="w">          </span><span class="no">export OS_AUTH_URL="${OPENSTACK_AUTH_URL:?Set OPENSTACK_AUTH_URL}"</span>
<span class="w">          </span><span class="no">export OS_USERNAME="${OPENSTACK_USERNAME:?Set OPENSTACK_USERNAME}"</span>
<span class="w">          </span><span class="no">export OS_PROJECT_NAME="${OPENSTACK_PROJECT_NAME:?Set OPENSTACK_PROJECT_NAME}"</span>
<span class="w">          </span><span class="no">export OS_USER_DOMAIN_NAME="${OPENSTACK_USER_DOMAIN_NAME}"</span>
<span class="w">          </span><span class="no">export OS_PROJECT_DOMAIN_NAME="${OPENSTACK_PROJECT_DOMAIN_NAME}"</span>
<span class="w">          </span><span class="no">export TF_VAR_image_file="${OPENSTACK_IMAGE_FILE}"</span>
<span class="w">          </span><span class="no">unset OS_CLOUD OS_TOKEN OS_AUTH_TOKEN</span>
<span class="w">          </span><span class="no">export TF_IN_AUTOMATION=1 TF_INPUT=0</span>

<span class="w">          </span><span class="no">cd "${OPENSTACK_TEST_DIR}"</span>
<span class="w">          </span><span class="no">exec 8&gt;.ci.lock</span>
<span class="w">          </span><span class="no">flock -n 8</span>
<span class="w">          </span><span class="no">[[ -r "${OPENSTACK_IMAGE_FILE}" &amp;&amp; -s "${OPENSTACK_IMAGE_FILE}" ]] || {</span>
<span class="w">            </span><span class="no">echo "Prepare a readable, non-empty ${OPENSTACK_IMAGE_FILE} in OPENSTACK_TEST_DIR." &gt;&amp;2</span>
<span class="w">            </span><span class="no">exit 1</span>
<span class="w">          </span><span class="no">}</span>
<span class="w">          </span><span class="no">tofu init -input=false -no-color</span>
<span class="w">          </span><span class="no">tofu fmt -check</span>
<span class="w">          </span><span class="no">tofu validate -no-color</span>

<span class="w">          </span><span class="no">if [[ -f terraform.tfstate ]]; then</span>
<span class="w">            </span><span class="no">managed="$(tofu state list)"</span>
<span class="w">            </span><span class="no">if grep -qv '^data\.' &lt;&lt;&lt; "${managed}" &amp;&amp; [[ -n "${managed}" ]]; then</span>
<span class="w">              </span><span class="no">echo 'Previous OpenStack test resources remain; inspect their State first.' &gt;&amp;2</span>
<span class="w">              </span><span class="no">exit 1</span>
<span class="w">            </span><span class="no">fi</span>
<span class="w">          </span><span class="no">fi</span>

<span class="w">          </span><span class="no">cleanup() {</span>
<span class="w">            </span><span class="no">result=$?</span>
<span class="w">            </span><span class="no">trap - EXIT</span>
<span class="w">            </span><span class="no">set +e</span>
<span class="w">            </span><span class="no">echo 'Clean OpenStack test resources'</span>
<span class="w">            </span><span class="no">tofu destroy -auto-approve -input=false -no-color</span>
<span class="w">            </span><span class="no">cleanup_result=$?</span>
<span class="w">            </span><span class="no">rm -f -- smoke.tfplan</span>
<span class="w">            </span><span class="no">if (( cleanup_result != 0 )); then</span>
<span class="w">              </span><span class="no">echo 'OpenStack cleanup failed; keep State for investigation.' &gt;&amp;2</span>
<span class="w">              </span><span class="no">if (( result == 0 )); then result=1; fi</span>
<span class="w">            </span><span class="no">fi</span>
<span class="w">            </span><span class="no">if (( result != 0 )); then rm -f -- "${job_dir}/test-passed.sha256"; fi</span>
<span class="w">            </span><span class="no">exit "${result}"</span>
<span class="w">          </span><span class="no">}</span>
<span class="w">          </span><span class="no">trap cleanup EXIT</span>
<span class="w">          </span><span class="no">trap 'exit 130' INT</span>
<span class="w">          </span><span class="no">trap 'exit 143' TERM</span>

<span class="w">          </span><span class="no">tofu plan -input=false -no-color -out=smoke.tfplan</span>
<span class="w">          </span><span class="no">tofu apply -input=false -no-color smoke.tfplan</span>
<span class="w">          </span><span class="no">tofu output -json smoke_result | jq -e \</span>
<span class="w">            </span><span class="no">'.image_status == "active" and .power_state == "active"</span>
<span class="w">             </span><span class="no">and (.network_ids | length) == 2</span>
<span class="w">             </span><span class="no">and (.volume_id == .attached_volume_id)'</span>

<span class="w">          </span><span class="no">sha="$(yaml_value "${job_dir}/staging-info.yaml" bundle_sha256)"</span>
<span class="w">          </span><span class="no">[[ "${sha}" =~ ^[0-9a-f]{64}$ ]]</span>
<span class="w">          </span><span class="no">printf '%s\n' "${sha}" &gt; "${job_dir}/test-passed.sha256"</span>

<span class="w">      </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">name</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">Publish tested or explicitly skipped bundle</span>
<span class="w">        </span><span class="nt">shell</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">bash</span>
<span class="w">        </span><span class="nt">run</span><span class="p">:</span><span class="w"> </span><span class="p p-Indicator">|</span>
<span class="w">          </span><span class="no">set -euo pipefail</span>
<span class="w">          </span><span class="no">source /etc/gitea-runner-env/bundle-pipeline.env</span>
<span class="w">          </span><span class="no">source "${BUNDLE_BUILDER_DIR}/common.sh"</span>
<span class="w">          </span><span class="no">manifest_id="$(yaml_value release-info.yaml manifest_id)"</span>
<span class="w">          </span><span class="no">[[ "${manifest_id}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]</span>
<span class="w">          </span><span class="no">expected="$(yaml_value staging-info.yaml bundle_sha256)"</span>
<span class="w">          </span><span class="no">[[ "${expected}" =~ ^[0-9a-f]{64}$ ]]</span>
<span class="w">          </span><span class="no">case "${TEST_MODE:?Missing release policy}" in</span>
<span class="w">            </span><span class="no">full) [[ "$(&lt;test-passed.sha256)" == "${expected}" ]] ;;</span>
<span class="w">            </span><span class="no">skip) echo 'Publish without deployment tests, as explicitly selected.' ;;</span>
<span class="w">            </span><span class="no">*) exit 1 ;;</span>
<span class="w">          </span><span class="no">esac</span>
<span class="w">          </span><span class="no">[[ "$(file_sha256 "${BUNDLE_WORK_DIR}/${manifest_id}.tar")" == "${expected}" ]]</span>
<span class="w">          </span><span class="no">bash "${BUNDLE_BUILDER_DIR}/publish-bundle.sh" release-info.yaml</span>
<span class="w">          </span><span class="no">touch bundle-published.enabled</span>

<span class="w">      </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">name</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">Clean test VMs</span>
<span class="w">        </span><span class="nt">if</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">always()</span>
<span class="w">        </span><span class="nt">shell</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">bash</span>
<span class="w">        </span><span class="nt">run</span><span class="p">:</span><span class="w"> </span><span class="p p-Indicator">|</span>
<span class="w">          </span><span class="no">set -euo pipefail</span>
<span class="w">          </span><span class="no">umask 077</span>
<span class="w">          </span><span class="no">[[ -f vm-cleanup.enabled ]] || exit 0</span>
<span class="w">          </span><span class="no">source /etc/gitea-runner-env/bundle-pipeline.env</span>
<span class="w">          </span><span class="no">source "${BUNDLE_BUILDER_DIR}/common.sh"</span>
<span class="w">          </span><span class="no">: "${TOFU_PROJECT_DIR:?Set TOFU_PROJECT_DIR}"</span>
<span class="w">          </span><span class="no">: "${TOFU_SSH_PRIVATE_KEY:?Set TOFU_SSH_PRIVATE_KEY}"</span>

<span class="w">          </span><span class="no">export_test_inputs staging-info.yaml</span>

<span class="w">          </span><span class="no">cd "${TOFU_PROJECT_DIR}"</span>
<span class="w">          </span><span class="no">exec 9&gt;.ci.lock</span>
<span class="w">          </span><span class="no">flock -n 9</span>
<span class="w">          </span><span class="no">trap 'rm -f -- deploy.tfplan vm-info.json' EXIT</span>
<span class="w">          </span><span class="no">tofu destroy -auto-approve -input=false -no-color</span>

<span class="w">      </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">name</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">Clean staging candidate</span>
<span class="w">        </span><span class="nt">if</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">always()</span>
<span class="w">        </span><span class="nt">shell</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">bash</span>
<span class="w">        </span><span class="nt">run</span><span class="p">:</span><span class="w"> </span><span class="p p-Indicator">|</span>
<span class="w">          </span><span class="no">set -euo pipefail</span>
<span class="w">          </span><span class="no">[[ -s staging-info.yaml &amp;&amp; -f staging-upload.enabled ]] || exit 0</span>
<span class="w">          </span><span class="no">source /etc/gitea-runner-env/bundle-pipeline.env</span>
<span class="w">          </span><span class="no">source "${BUNDLE_BUILDER_DIR}/common.sh"</span>
<span class="w">          </span><span class="no">[[ "${STAGING_REPOSITORY}" != "${BUNDLE_REPOSITORY}" ]]</span>
<span class="w">          </span><span class="no">path="$(yaml_value staging-info.yaml bundle_path)"</span>
<span class="w">          </span><span class="no">sha="$(yaml_value staging-info.yaml bundle_sha256)"</span>
<span class="w">          </span><span class="no">manifest_id="$(yaml_value release-info.yaml manifest_id)"</span>
<span class="w">          </span><span class="no">[[ "${manifest_id}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]</span>
<span class="w">          </span><span class="no">[[ "${sha}" =~ ^[0-9a-f]{64}$ ]]</span>
<span class="w">          </span><span class="no">[[ "${path}" == "candidates/${manifest_id}/${sha}/contrabass-engine-deploy.tar" ]]</span>

<span class="w">          </span><span class="no">ids="$(mktemp)"</span>
<span class="w">          </span><span class="no">trap 'rm -f -- "${ids}"' EXIT</span>
<span class="w">          </span><span class="no">next_page=""</span>
<span class="w">          </span><span class="no">while true; do</span>
<span class="w">            </span><span class="no">request=(-fsS --get \</span>
<span class="w">              </span><span class="no">--data-urlencode "repository=${STAGING_REPOSITORY}")</span>
<span class="w">            </span><span class="no">if [[ -n "${next_page}" ]]; then</span>
<span class="w">              </span><span class="no">request+=(--data-urlencode "continuationToken=${next_page}")</span>
<span class="w">            </span><span class="no">fi</span>
<span class="w">            </span><span class="no">page="$(nexus_curl "${request[@]}" "${NEXUS_URL%/}/service/rest/v1/assets")"</span>
<span class="w">            </span><span class="no">jq -r --arg path "${path}" \</span>
<span class="w">              </span><span class="no">'.items[] | (.path | ltrimstr("/")) as $p | select($p == $path or $p == ($path + ".sha256")) | .id' \</span>
<span class="w">              </span><span class="no">&lt;&lt;&lt; "${page}" &gt;&gt; "${ids}"</span>
<span class="w">            </span><span class="no">next_page="$(jq -r '.continuationToken // empty' &lt;&lt;&lt; "${page}")"</span>
<span class="w">            </span><span class="no">[[ -n "${next_page}" ]] || break</span>
<span class="w">          </span><span class="no">done</span>

<span class="w">          </span><span class="no">while IFS= read -r id; do</span>
<span class="w">            </span><span class="no">encoded="$(jq -rn --arg id "${id}" '$id | @uri')"</span>
<span class="w">            </span><span class="no">nexus_curl -fsS -X DELETE \</span>
<span class="w">              </span><span class="no">"${NEXUS_URL%/}/service/rest/v1/assets/${encoded}"</span>
<span class="w">          </span><span class="no">done &lt; "${ids}"</span>

<span class="w">      </span><span class="p p-Indicator">-</span><span class="w"> </span><span class="nt">name</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">Record release execution</span>
<span class="w">        </span><span class="nt">if</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">always()</span>
<span class="w">        </span><span class="nt">shell</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">bash</span>
<span class="w">        </span><span class="nt">env</span><span class="p">:</span>
<span class="w">          </span><span class="nt">RUN_RESULT</span><span class="p">:</span><span class="w"> </span><span class="l l-Scalar l-Scalar-Plain">$&#123;&#123; job.status &#125;&#125;</span>
<span class="w">        </span><span class="nt">run</span><span class="p">:</span><span class="w"> </span><span class="p p-Indicator">|</span>
<span class="w">          </span><span class="no">set -euo pipefail</span>
<span class="w">          </span><span class="no">[[ -s release-policy.yaml ]] || exit 0</span>
<span class="w">          </span><span class="no">source /etc/gitea-runner-env/bundle-pipeline.env</span>
<span class="w">          </span><span class="no">source "${BUNDLE_BUILDER_DIR}/common.sh"</span>
<span class="w">          </span><span class="no">tag="$(yaml_value release-policy.yaml release_tag)"</span>
<span class="w">          </span><span class="no">[[ "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]</span>
<span class="w">          </span><span class="no">record="$(mktemp)"</span>
<span class="w">          </span><span class="no">trap 'rm -f -- "${record}"' EXIT</span>
<span class="w">          </span><span class="no">cp release-policy.yaml "${record}"</span>
<span class="w">          </span><span class="no">printf '%s\n' "job_status: ${RUN_RESULT}" \</span>
<span class="w">            </span><span class="no">"run_id: ${GITHUB_RUN_ID:-unknown}" \</span>
<span class="w">            </span><span class="no">"run_attempt: ${GITHUB_RUN_ATTEMPT:-0}" &gt;&gt; "${record}"</span>
<span class="w">          </span><span class="no">if [[ -s staging-info.yaml ]]; then</span>
<span class="w">            </span><span class="no">printf 'bundle_sha256: %s\n' "$(yaml_value staging-info.yaml bundle_sha256)" &gt;&gt; "${record}"</span>
<span class="w">          </span><span class="no">fi</span>
<span class="w">          </span><span class="no">if [[ -f bundle-published.enabled ]]; then</span>
<span class="w">            </span><span class="no">echo 'published: true' &gt;&gt; "${record}"</span>
<span class="w">          </span><span class="no">else</span>
<span class="w">            </span><span class="no">echo 'published: false' &gt;&gt; "${record}"</span>
<span class="w">          </span><span class="no">fi</span>
<span class="w">          </span><span class="no">if [[ -f test-passed.sha256 ]]; then</span>
<span class="w">            </span><span class="no">echo 'verification: passed' &gt;&gt; "${record}"</span>
<span class="w">          </span><span class="no">elif [[ "$(yaml_value release-policy.yaml test_mode)" == skip ]]; then</span>
<span class="w">            </span><span class="no">echo 'verification: skipped' &gt;&gt; "${record}"</span>
<span class="w">          </span><span class="no">else</span>
<span class="w">            </span><span class="no">echo 'verification: not-passed' &gt;&gt; "${record}"</span>
<span class="w">          </span><span class="no">fi</span>
<span class="w">          </span><span class="no">path="executions/${tag}/${GITHUB_RUN_ID:-manual}-${GITHUB_RUN_ATTEMPT:-0}-$(date -u +%Y%m%dT%H%M%S).yaml"</span>
<span class="w">          </span><span class="no">nexus_curl -fsS --retry "${HTTP_RETRY_COUNT}" \</span>
<span class="w">            </span><span class="no">--upload-file "${record}" "${NEXUS_URL%/}/repository/${MANIFEST_REPOSITORY}/${path}"</span>
<span class="w">          </span><span class="no">echo "Release execution recorded: ${path}"</span>
</code></pre></div>

</details>

Workflow는 하나다. 별도의 retry·verify Workflow를 함께 돌리지 않는다. Tag의 소스를 한 번 shallow clone하고 같은 소스로 manifest·TAR를 만든다.

```text title="시험 선택과 처리 흐름"
Tag → 승인 PR 또는 과거 계열 패치 확인 → full / skip
  full: TAR → staging → VMware VM → deploy.sh → Ansible → OpenStack 시험
                                     → 동일 SHA256의 TAR 최종 게시
  skip: TAR → 재료·TAR 검증 → 최종 게시
  공통: channel 갱신, 계열별 3개 유지, 자원·후보 정리, 실행 기록
```

초기 코드에 반영한 Workflow와 host 설정·Secret 이름이 맞는지 마지막으로 확인한다. 원본에 다른 Workflow가 있으면 이 파일 하나로 정리해 commit한다.

```bash title="Runner 최초 기동"
systemd-analyze verify /etc/systemd/system/gitea-runner.service \
  /etc/systemd/system/gitea-stack.service /etc/systemd/system/nexus-stack.service
systemctl daemon-reload
systemctl enable --now gitea-runner
systemctl is-active gitea-runner
journalctl -u gitea-runner -n 30 --no-pager
```

Gitea Runners 화면에서 Online과 label을 확인한다. full 시험의 OSD·SeaweedFS 작업은 디스크 내용을 바꿀 수 있으므로 **시험 VM과 비어 있는 데이터 디스크만 대상**으로 삼는다.

---

## 13. skip·full·고객사 반입 순서로 확인

<p class="subsection-title"><strong>13-1. 처음에는 skip으로 정식 발행</strong></p>

<div class="section-body" markdown="1">

초기 master에 바로 Tag를 붙이지 않는다. develop에서 manifest release를 다음 번호로 수정하고 commit·push한다. develop → master PR을 만들고 다른 검토자가 `release:skip-test`를 붙여 승인한 뒤 담당자가 merge commit으로 합친다.

아래는 manifest를 4.1.3으로 수정한 예다. Gitea PR 화면에서 발행할 정확한 merge commit을 확인해 입력한다.

```bash title="승인·merge한 commit에 Tag 발행"
cd /root/private-cloud-v4
git -c http.sslVerify=false fetch origin master
read -r -p 'Release merge commit: ' release_commit
git show "${release_commit}:release/manifest.yaml"
git tag -a v4.1.3 "${release_commit}" -m 'Release v4.1.3'
git -c http.sslVerify=false push origin v4.1.3
```

Actions에서 policy가 skip이고 VM 시험 없이 최종 게시·channel 갱신이 성공하는지 확인한다. raw-manifest의 executions 기록은 skipped이며 passed가 아니다.

Gitea Repository의 **Releases → New Release**에서는 이미 발행한 `v4.1.3`을 선택해 설명을 작성한다. 제목은 `Contrabass 4.1.3`, 내용은 변경점·설치 주의·알려진 문제·시험 결과·고정 버전 다운로드 링크를 적는다. 새 Tag를 다시 만들거나 기존 Tag를 이동하지 않는다. 이 구성에서 Gitea Release 설명은 담당자가 작성하며, Workflow가 자동 생성하는 것은 Nexus의 실행 기록이다.

</div>

<p class="subsection-title"><strong>13-2. 같은 TAR로 full 확인</strong></p>

<div class="section-body" markdown="1">

같은 PR에서 생략 라벨을 제거하고 Actions 수동 실행에 기존 Tag v4.1.3을 넣는다. **Tag와 공개 TAR를 다시 만들지 않는다.** 기존 TAR를 받아 같은 SHA256으로 시험한다.

- VMware VM 4대 생성과 모든 VM의 SSH 준비 완료.
- 첫 VM이 이번 staging TAR를 받아 전체 해시 대조.
- Private Nexus·Ansible 컨테이너 기동.
- 컨테이너의 `ansible-playbook -i inventory/inventory.ini main.yml` 완료.
- OpenStack 이미지·vxlan/provider NIC 2개·VM·volume attach 확인.
- 성공·실패 모두 시험 자원·VM·이번 staging 정리.
- State 보존, 일시적인 tfplan 파일 정리.

이것은 먼저 skip으로 공개한 파일을 나중에 시험하는 절차다. 뒤늦은 시험 실패가 공개물을 자동 회수하지는 않는다. 평소에는 처음 PR 검토 때 시험 정책을 정한다.

</div>

<p class="subsection-title"><strong>13-3. 사업수행팀 다운로드와 별도 서버 시험</strong></p>

<div class="section-body" markdown="1">

사내 접근이 가능한 작업 단말에서 사업수행팀의 읽기 계정으로 실행한다. 아래 SERVER_HOST·RELEASE_HTTPS_PORT는 사내 서버 값으로 지정한다. CHANNEL=4.1이면 해당 계열 최신 버전을 선택한다.

```bash title="TAR는 한 번, 체크섬은 그 버전에서 받기"
set -euo pipefail
SERVER_HOST=192.0.2.10
RELEASE_HTTPS_PORT=8443
CHANNEL=current
read -r -p 'Nexus download user: ' download_user
tar_url="$(curl -kfL --user "${download_user}" \
  "https://${SERVER_HOST}:${RELEASE_HTTPS_PORT}/repository/raw-manifest/channels/${CHANNEL}/contrabass-engine-deploy.tar" \
  -o contrabass-engine-deploy.tar --write-out '%{url_effective}')"
curl -kfL --user "${download_user}" "${tar_url}.sha256" -o contrabass-engine-deploy.tar.sha256
sha256sum -c contrabass-engine-deploy.tar.sha256
```

HAProxy의 302를 따라 실제 TAR를 받는다. 도중에 channel이 바뀌어도 체크섬은 실제 받은 고정 버전 URL에서 가져온다.

확인한 TAR와 체크섬을 새 고객사 시험 서버에 옮긴 뒤 root로 실행한다. 예시 IP는 그 서버의 API IP로 바꾼다. EULA를 검토하고 동의할 권한이 있는 사람이 플래그를 사용한다.

```bash title="고객사 시험 서버 — 로컬 재료로 배포 환경 준비"
sha256sum -c contrabass-engine-deploy.tar.sha256
tar -xf contrabass-engine-deploy.tar
cd contrabass-engine-deploy
sudo ./deploy.sh 192.0.2.101 --accept-eula
sudo nerdctl exec nexus true
sudo nerdctl exec okestro-os-ansible true
```

고객사는 Raw·Docker 저장소만 있는 Private Nexus를 띄우고 반입 재료의 읽기를 익명으로 제공한다. 사내 CI 계정·비밀번호·DB 전체를 가져가지 않는다. 재실행 시 같은 재료를 확인해 재사용하며 불일치를 무조건 덮어쓰지 않는다.

사내 팀의 경로도 별도 새 시험 서버에서 `git clone --depth=1` → 제품 install.sh로 확인한다. 이 경로는 사내 Nexus에 인증해 재료를 받는다. 고객사의 익명 경로와 모두 확인한다.

</div>

<details class="analysis-toggle" markdown="1">
<summary>실패했을 때 먼저 확인할 곳</summary>

| 증상 | 먼저 볼 것 |
| --- | --- |
| Runner가 job을 받지 않음 | UI label, 실제 config 경로, 등록 범위, 여유 공간 임계값 |
| exit code 3과 tf 파일명만 출력 | tofu fmt -check -diff로 정렬 차이 확인 |
| Git/API 401·403 | CI 토큰의 사용자·scope·저장소 권한 |
| Nexus 401·403 | CI role과 Repository 이름 |
| VM 복제 뒤 reconfigure 실패 | vCenter 작업·이벤트의 부족 privilege ID |
| uplink 초기화 대기 | guest-init 로그와 ens38 NM profile |
| Nexus HTTPS 대기 | 컨테이너 로그, keystore·소유권·포트 |
| 컨테이너 bash 실행 실패 | Alpine 계열이면 sh 사용. 제공 코드는 sh 지정 |
| hash·digest 불일치 | 덮어쓰지 않고 manifest와 실물 대조 |
| 이전 시험 자원·State 잔존 | 이전 정리 로그와 State. State 삭제로 회피하지 않음 |
| staging 잔존 | API path 선행 / 정규화, 모든 페이지 조회, 삭제 권한 |
| TAR·체크섬 일부만 존재 | 미발행 실패 경로인지 확인하고 그 대상만 복구·정리 |

</details>

---

## 14. 보관·백업·재기동까지 확인하고 운영 시작

Nexus Cleanup Policies에 raw, Component Age 3일의 staging 전용 정책을 만들어 raw-release-staging에만 연결한다. Cleanup task·compact 시간을 확인하고 백업 창과 겹치지 않게 한다. 가장 긴 시험보다 짧은 TTL을 쓰지 않는다.

계열별 최종 Bundle 3개는 게시 스크립트와 RELEASE_KEEP_COUNT=3이 관리한다. Raw·Docker 원본에 같은 기간 삭제를 적용하지 않는다. 삭제 표시한 파일의 물리 공간 반환은 compact가 담당한다.

백업 설정·실행 명령·timer도 묶음에 포함했다. 별도 물리서버와 첫 수동 백업이 준비되기 전에는 timer를 켜지 않는다.

<details class="analysis-toggle" markdown="1">
<summary>/etc/gitea-runner-env/backup.env — 전체 내용</summary>

<div class="highlight" data-source-path="host/etc/gitea-runner-env/backup.env"><pre><code><span class="nb">source</span><span class="w"> </span>/etc/gitea-runner-env/services.env
<span class="nv">BACKUP_HOST</span><span class="o">=</span>release-services
<span class="nv">STAGING_DIR</span><span class="o">=</span>/data/release-service-backup/staging
<span class="nb">export</span><span class="w"> </span><span class="nv">RESTIC_REPOSITORY</span><span class="o">=</span>sftp:backup-store:/srv/backup/release-services
<span class="nb">export</span><span class="w"> </span><span class="nv">RESTIC_PASSWORD_FILE</span><span class="o">=</span>/etc/release-backup/restic-password
<span class="nv">BUNDLE_BUILDER_DIR</span><span class="o">=</span>/opt/gitea/bundle-builder
<span class="nv">RUNNER_HOME</span><span class="o">=</span>/var/lib/gitea-runner
<span class="nv">TOFU_ROOT</span><span class="o">=</span>/var/lib/gitea-runner/opentofu
<span class="nv">SERVICE_IMAGES_DIR</span><span class="o">=</span>/opt/gitea/service-images
<span class="nv">GITEA_HEALTH_URL</span><span class="o">=</span><span class="s2">"https://127.0.0.1:</span><span class="si">${</span><span class="nv">GITEA_HTTPS_PORT</span><span class="si">}</span><span class="s2">/api/healthz"</span>
<span class="nv">NEXUS_HEALTH_URL</span><span class="o">=</span><span class="s2">"https://127.0.0.1:</span><span class="si">${</span><span class="nv">NEXUS_HTTPS_PORT</span><span class="si">}</span><span class="s2">/service/rest/v1/status"</span>
<span class="nv">CONFIG_PATHS</span><span class="o">=(</span>
<span class="w">  </span>root/compose
<span class="w">  </span>data/gitea/certs
<span class="w">  </span>etc/gitea-runner
<span class="w">  </span>etc/gitea-runner-env
<span class="w">  </span>etc/systemd/system/gitea-runner.service
<span class="w">  </span>etc/systemd/system/gitea-stack.service
<span class="w">  </span>etc/systemd/system/nexus-stack.service
<span class="w">  </span>etc/systemd/system/release-services-backup.service
<span class="w">  </span>etc/systemd/system/release-services-backup.timer
<span class="w">  </span>etc/systemd/system/haproxy.service.d
<span class="w">  </span>etc/haproxy
<span class="w">  </span>etc/sudoers.d/contrabass-engine-runner
<span class="w">  </span>usr/local/sbin/build-private-release
<span class="w">  </span>usr/local/sbin/update-release-alias
<span class="o">)</span>
</code></pre></div>

</details>

<details class="analysis-toggle" markdown="1">
<summary>/usr/local/sbin/backup-release-services — 전체 내용</summary>

<div class="highlight" data-source-path="host/usr/local/sbin/backup-release-services"><pre><code><span class="ch">#!/bin/bash</span>
<span class="nb">set</span><span class="w"> </span>-euo<span class="w"> </span>pipefail
<span class="nb">umask</span><span class="w"> </span><span class="m">077</span>

<span class="c1"># root 전용 설정. 이 스크립트는 CI job에서 호출하지 않는다.</span>
<span class="nb">source</span><span class="w"> </span>/etc/gitea-runner-env/backup.env

<span class="nb">exec</span><span class="w"> </span><span class="m">9</span>&gt;/run/lock/release-services-backup.lock
flock<span class="w"> </span>-n<span class="w"> </span><span class="m">9</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="o">{</span><span class="w"> </span><span class="nb">echo</span><span class="w"> </span><span class="s1">'Another backup or repository maintenance is running.'</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span><span class="p">;</span><span class="w"> </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span><span class="p">;</span><span class="w"> </span><span class="o">}</span>

<span class="k">for</span><span class="w"> </span><span class="nb">command</span><span class="w"> </span><span class="k">in</span><span class="w"> </span>nerdctl<span class="w"> </span>rsync<span class="w"> </span>restic<span class="w"> </span>tar<span class="w"> </span>systemctl<span class="w"> </span>curl<span class="w"> </span>flock<span class="w"> </span>realpath<span class="w"> </span>install<span class="w"> </span>getent<span class="p">;</span><span class="w"> </span><span class="k">do</span>
<span class="w">  </span><span class="nb">command</span><span class="w"> </span>-v<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">command</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;/dev/null
<span class="k">done</span>

:<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">BACKUP_HOST</span><span class="p">:?</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">STAGING_DIR</span><span class="p">:?</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">RESTIC_REPOSITORY</span><span class="p">:?</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">RESTIC_PASSWORD_FILE</span><span class="p">:?</span><span class="si">}</span><span class="s2">"</span>
:<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">GITEA_DATA_DIR</span><span class="p">:?</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_DATA_DIR</span><span class="p">:?</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">BUNDLE_BUILDER_DIR</span><span class="p">:?</span><span class="si">}</span><span class="s2">"</span>
:<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">RUNNER_HOME</span><span class="p">:?</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">TOFU_ROOT</span><span class="p">:?</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">SERVICE_IMAGES_DIR</span><span class="p">:?</span><span class="si">}</span><span class="s2">"</span>
:<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">GITEA_HEALTH_URL</span><span class="p">:?</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_HEALTH_URL</span><span class="p">:?</span><span class="si">}</span><span class="s2">"</span>
:<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">GITEA_DB_USER</span><span class="p">:?</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">GITEA_DB_NAME</span><span class="p">:?</span><span class="si">}</span><span class="s2">"</span>

<span class="c1"># --delete는 운영 데이터가 아니라 준비한 staging 하위 복사본에만 적용한다.</span>
<span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">STAGING_DIR</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span>/*<span class="w"> </span><span class="o">&amp;&amp;</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">STAGING_DIR</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>!<span class="o">=</span><span class="w"> </span>/<span class="w"> </span><span class="o">]]</span>
<span class="o">[[</span><span class="w"> </span>-d<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">STAGING_DIR</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">&amp;&amp;</span><span class="w"> </span>!<span class="w"> </span>-L<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">STAGING_DIR</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span>
<span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="k">$(</span>realpath<span class="w"> </span>-e<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">STAGING_DIR</span><span class="si">}</span><span class="s2">"</span><span class="k">)</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">STAGING_DIR</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span>
<span class="o">[[</span><span class="w"> </span>-f<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">STAGING_DIR</span><span class="si">}</span><span class="s2">/.release-backup-staging"</span><span class="w"> </span><span class="o">]]</span>
<span class="k">for</span><span class="w"> </span>source_dir<span class="w"> </span><span class="k">in</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">GITEA_DATA_DIR</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_DATA_DIR</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">BUNDLE_BUILDER_DIR</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="se">\</span>
<span class="w">                  </span><span class="s2">"</span><span class="si">${</span><span class="nv">RUNNER_HOME</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">TOFU_ROOT</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">SERVICE_IMAGES_DIR</span><span class="si">}</span><span class="s2">"</span><span class="p">;</span><span class="w"> </span><span class="k">do</span>
<span class="w">  </span><span class="o">[[</span><span class="w"> </span>-d<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">source_dir</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span>
<span class="w">  </span><span class="nv">source_dir</span><span class="o">=</span><span class="s2">"</span><span class="k">$(</span>realpath<span class="w"> </span>-e<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">source_dir</span><span class="si">}</span><span class="s2">"</span><span class="k">)</span><span class="s2">"</span>
<span class="w">  </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">source_dir</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>!<span class="o">=</span><span class="w"> </span>/<span class="w"> </span><span class="o">&amp;&amp;</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">source_dir</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>!<span class="o">=</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">STAGING_DIR</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span>
<span class="w">  </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">STAGING_DIR</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>!<span class="o">=</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">source_dir</span><span class="si">}</span><span class="s2">/"</span>*<span class="w"> </span><span class="o">&amp;&amp;</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">source_dir</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>!<span class="o">=</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">STAGING_DIR</span><span class="si">}</span><span class="s2">/"</span>*<span class="w"> </span><span class="o">]]</span>
<span class="k">done</span>
<span class="nb">test</span><span class="w"> </span>-r<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">RESTIC_PASSWORD_FILE</span><span class="si">}</span><span class="s2">"</span>
<span class="nb">test</span><span class="w"> </span>-r<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">RUNNER_HOME</span><span class="si">}</span><span class="s2">/.runner"</span>
<span class="nb">test</span><span class="w"> </span>-d<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">RUNNER_HOME</span><span class="si">}</span><span class="s2">/.ssh"</span>
<span class="o">((</span><span class="w"> </span><span class="si">${#</span><span class="nv">CONFIG_PATHS</span><span class="p">[@]</span><span class="si">}</span><span class="w"> </span>&gt;<span class="w"> </span><span class="m">0</span><span class="w"> </span><span class="o">))</span>
<span class="k">for</span><span class="w"> </span>config_path<span class="w"> </span><span class="k">in</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">CONFIG_PATHS</span><span class="p">[@]</span><span class="si">}</span><span class="s2">"</span><span class="p">;</span><span class="w"> </span><span class="k">do</span>
<span class="w">  </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">config_path</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>!<span class="o">=</span><span class="w"> </span>/*<span class="w"> </span><span class="o">&amp;&amp;</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">config_path</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>!<span class="o">=</span><span class="w"> </span>*..*<span class="w"> </span><span class="o">]]</span>
<span class="w">  </span><span class="o">[[</span><span class="w"> </span>-e<span class="w"> </span><span class="s2">"/</span><span class="si">${</span><span class="nv">config_path</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">||</span><span class="w"> </span>-L<span class="w"> </span><span class="s2">"/</span><span class="si">${</span><span class="nv">config_path</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span>
<span class="k">done</span>
systemctl<span class="w"> </span>is-active<span class="w"> </span>--quiet<span class="w"> </span>gitea-runner
<span class="k">for</span><span class="w"> </span>container<span class="w"> </span><span class="k">in</span><span class="w"> </span>gitea<span class="w"> </span>gitea-db<span class="w"> </span>nexus<span class="p">;</span><span class="w"> </span><span class="k">do</span>
<span class="w">  </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="k">$(</span>nerdctl<span class="w"> </span>inspect<span class="w"> </span>-f<span class="w"> </span><span class="s1">'&#123;&#123;.State.Running&#125;&#125;'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">container</span><span class="si">}</span><span class="s2">"</span><span class="k">)</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="nb">true</span><span class="w"> </span><span class="o">]]</span>
<span class="k">done</span>

copy_tree<span class="o">()</span><span class="w"> </span><span class="o">{</span>
<span class="w">  </span><span class="nb">local</span><span class="w"> </span><span class="nv">source_dir</span><span class="o">=</span><span class="s2">"</span><span class="nv">$1</span><span class="s2">"</span><span class="w"> </span><span class="nv">destination</span><span class="o">=</span><span class="s2">"</span><span class="nv">$2</span><span class="s2">"</span>
<span class="w">  </span><span class="nb">shift</span><span class="w"> </span><span class="m">2</span>
<span class="w">  </span><span class="o">[[</span><span class="w"> </span>!<span class="w"> </span>-L<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">STAGING_DIR</span><span class="si">}</span><span class="s2">/</span><span class="si">${</span><span class="nv">destination</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">]]</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="k">return</span><span class="w"> </span><span class="m">1</span>
<span class="w">  </span>install<span class="w"> </span>-d<span class="w"> </span>-m<span class="w"> </span><span class="m">0700</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">STAGING_DIR</span><span class="si">}</span><span class="s2">/</span><span class="si">${</span><span class="nv">destination</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="k">return</span><span class="w"> </span><span class="m">1</span>
<span class="w">  </span>rsync<span class="w"> </span>-aHAX<span class="w"> </span>--numeric-ids<span class="w"> </span>--delete<span class="w"> </span><span class="s2">"</span><span class="nv">$@</span><span class="s2">"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">source_dir</span><span class="si">}</span><span class="s2">/"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">STAGING_DIR</span><span class="si">}</span><span class="s2">/</span><span class="si">${</span><span class="nv">destination</span><span class="si">}</span><span class="s2">/"</span>
<span class="o">}</span>

precopy<span class="o">()</span><span class="w"> </span><span class="o">{</span>
<span class="w">  </span><span class="nb">local</span><span class="w"> </span><span class="nv">rc</span><span class="o">=</span><span class="m">0</span>
<span class="w">  </span>copy_tree<span class="w"> </span><span class="s2">"</span><span class="nv">$@</span><span class="s2">"</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="nv">rc</span><span class="o">=</span><span class="nv">$?</span>
<span class="w">  </span><span class="c1"># 가동 중 임시 파일이 사라진 경우의 24만 허용한다. 최종 동기화에서는 허용하지 않는다.</span>
<span class="w">  </span><span class="o">[[</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">rc</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="m">0</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">rc</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">==</span><span class="w"> </span><span class="m">24</span><span class="w"> </span><span class="o">]]</span>
<span class="o">}</span>

wait_http<span class="o">()</span><span class="w"> </span><span class="o">{</span>
<span class="w">  </span><span class="nb">local</span><span class="w"> </span><span class="nv">url</span><span class="o">=</span><span class="s2">"</span><span class="nv">$1</span><span class="s2">"</span>
<span class="w">  </span><span class="k">for</span><span class="w"> </span><span class="o">((</span><span class="nv">attempt</span><span class="o">=</span><span class="m">0</span><span class="p">;</span><span class="w"> </span>attempt&lt;<span class="m">120</span><span class="p">;</span><span class="w"> </span>attempt++<span class="o">))</span><span class="p">;</span><span class="w"> </span><span class="k">do</span>
<span class="w">    </span><span class="c1"># 자체 서명 인증서를 쓰는 내부 healthcheck다. 외부 통신에는 검증 생략을 적용하지 않는다.</span>
<span class="w">    </span><span class="k">if</span><span class="w"> </span>curl<span class="w"> </span>-kfsS<span class="w"> </span>--connect-timeout<span class="w"> </span><span class="m">5</span><span class="w"> </span>--max-time<span class="w"> </span><span class="m">10</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">url</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;/dev/null<span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">      </span><span class="k">return</span><span class="w"> </span><span class="m">0</span>
<span class="w">    </span><span class="k">fi</span>
<span class="w">    </span>sleep<span class="w"> </span><span class="m">5</span>
<span class="w">  </span><span class="k">done</span>
<span class="w">  </span><span class="k">return</span><span class="w"> </span><span class="m">1</span>
<span class="o">}</span>

<span class="nv">runner_stopped</span><span class="o">=</span><span class="m">0</span>
<span class="nv">gitea_stopped</span><span class="o">=</span><span class="m">0</span>
<span class="nv">nexus_stopped</span><span class="o">=</span><span class="m">0</span>
resume_services<span class="o">()</span><span class="w"> </span><span class="o">{</span>
<span class="w">  </span><span class="k">if</span><span class="w"> </span><span class="o">((</span>nexus_stopped<span class="o">))</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">    </span>nerdctl<span class="w"> </span>start<span class="w"> </span>nexus<span class="w"> </span>&gt;/dev/null<span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="k">return</span><span class="w"> </span><span class="m">1</span>
<span class="w">    </span><span class="nv">nexus_stopped</span><span class="o">=</span><span class="m">0</span>
<span class="w">  </span><span class="k">fi</span>
<span class="w">  </span><span class="k">if</span><span class="w"> </span><span class="o">((</span>gitea_stopped<span class="o">))</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">    </span>nerdctl<span class="w"> </span>start<span class="w"> </span>gitea<span class="w"> </span>&gt;/dev/null<span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="k">return</span><span class="w"> </span><span class="m">1</span>
<span class="w">    </span><span class="nv">gitea_stopped</span><span class="o">=</span><span class="m">0</span>
<span class="w">  </span><span class="k">fi</span>
<span class="w">  </span><span class="k">if</span><span class="w"> </span><span class="o">((</span>runner_stopped<span class="o">))</span><span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">    </span>wait_http<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_HEALTH_URL</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="k">return</span><span class="w"> </span><span class="m">1</span>
<span class="w">    </span>wait_http<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">GITEA_HEALTH_URL</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="k">return</span><span class="w"> </span><span class="m">1</span>
<span class="w">    </span>systemctl<span class="w"> </span>start<span class="w"> </span>gitea-runner<span class="w"> </span><span class="o">||</span><span class="w"> </span><span class="k">return</span><span class="w"> </span><span class="m">1</span>
<span class="w">    </span><span class="nv">runner_stopped</span><span class="o">=</span><span class="m">0</span>
<span class="w">  </span><span class="k">fi</span>
<span class="o">}</span>
on_exit<span class="o">()</span><span class="w"> </span><span class="o">{</span>
<span class="w">  </span><span class="nb">local</span><span class="w"> </span><span class="nv">rc</span><span class="o">=</span><span class="nv">$?</span>
<span class="w">  </span><span class="nb">trap</span><span class="w"> </span>-<span class="w"> </span>EXIT
<span class="w">  </span><span class="k">if</span><span class="w"> </span>!<span class="w"> </span>resume_services<span class="p">;</span><span class="w"> </span><span class="k">then</span>
<span class="w">    </span><span class="nb">echo</span><span class="w"> </span><span class="s1">'Service restart/readiness failed. Keep Runner stopped and inspect the services.'</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span>
<span class="w">    </span><span class="nv">rc</span><span class="o">=</span><span class="m">1</span>
<span class="w">  </span><span class="k">fi</span>
<span class="w">  </span><span class="nb">exit</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">rc</span><span class="si">}</span><span class="s2">"</span>
<span class="o">}</span>
<span class="nb">trap</span><span class="w"> </span>on_exit<span class="w"> </span>EXIT
<span class="nb">trap</span><span class="w"> </span><span class="s1">'exit 130'</span><span class="w"> </span>INT
<span class="nb">trap</span><span class="w"> </span><span class="s1">'exit 143'</span><span class="w"> </span>TERM

<span class="nb">echo</span><span class="w"> </span><span class="s1">'[1/5] Pre-copy live data; this copy is not yet a valid backup.'</span>
precopy<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">GITEA_DATA_DIR</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>gitea-data
precopy<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_DATA_DIR</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>nexus-data<span class="w"> </span>--exclude<span class="o">=</span>/db/
precopy<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">BUNDLE_BUILDER_DIR</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>bundle-builder
precopy<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">SERVICE_IMAGES_DIR</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>service-images
precopy<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">TOFU_ROOT</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>opentofu<span class="w"> </span>--exclude<span class="o">=</span>.terraform/<span class="w"> </span>--exclude<span class="o">=</span><span class="s1">'*.tfplan'</span><span class="w"> </span>--exclude<span class="o">=</span><span class="s1">'*.plan'</span><span class="w"> </span>--exclude<span class="o">=</span><span class="s1">'.ci.lock'</span>

<span class="nb">echo</span><span class="w"> </span><span class="s1">'[2/5] Stop Runner gracefully, then quiesce Gitea and Nexus.'</span>
<span class="c1"># Runner의 shutdown_timeout보다 systemd TimeoutStopSec를 길게 설정한다.</span>
<span class="nv">runner_stopped</span><span class="o">=</span><span class="m">1</span>
systemctl<span class="w"> </span>stop<span class="w"> </span>gitea-runner
<span class="nv">gitea_stopped</span><span class="o">=</span><span class="m">1</span>
nerdctl<span class="w"> </span>stop<span class="w"> </span>--time<span class="w"> </span><span class="m">120</span><span class="w"> </span>gitea<span class="w"> </span>&gt;/dev/null
<span class="nv">nexus_stopped</span><span class="o">=</span><span class="m">1</span>
nerdctl<span class="w"> </span>stop<span class="w"> </span>--time<span class="w"> </span><span class="m">120</span><span class="w"> </span>nexus<span class="w"> </span>&gt;/dev/null
<span class="c1"># SIGKILL 종료를 정상 정지로 간주하지 않는다. 143은 SIGTERM 종료 코드다.</span>
<span class="k">for</span><span class="w"> </span>container<span class="w"> </span><span class="k">in</span><span class="w"> </span>gitea<span class="w"> </span>nexus<span class="p">;</span><span class="w"> </span><span class="k">do</span>
<span class="w">  </span><span class="k">case</span><span class="w"> </span><span class="s2">"</span><span class="k">$(</span>nerdctl<span class="w"> </span>inspect<span class="w"> </span>-f<span class="w"> </span><span class="s1">'&#123;&#123;.State.ExitCode&#125;&#125;'</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">container</span><span class="si">}</span><span class="s2">"</span><span class="k">)</span><span class="s2">"</span><span class="w"> </span><span class="k">in</span>
<span class="w">    </span><span class="m">0</span><span class="p">|</span><span class="m">143</span><span class="o">)</span><span class="w"> </span><span class="p">;;</span>
<span class="w">    </span>*<span class="o">)</span><span class="w"> </span><span class="nb">echo</span><span class="w"> </span><span class="s2">"Unexpected shutdown result: </span><span class="si">${</span><span class="nv">container</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>&gt;<span class="p">&amp;</span><span class="m">2</span><span class="p">;</span><span class="w"> </span><span class="nb">exit</span><span class="w"> </span><span class="m">1</span><span class="w"> </span><span class="p">;;</span>
<span class="w">  </span><span class="k">esac</span>
<span class="k">done</span>

<span class="nb">echo</span><span class="w"> </span><span class="s1">'[3/5] Final sync, PostgreSQL dump, and configuration snapshot.'</span>
copy_tree<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">GITEA_DATA_DIR</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>gitea-data
copy_tree<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">NEXUS_DATA_DIR</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>nexus-data
nerdctl<span class="w"> </span><span class="nb">exec</span><span class="w"> </span>gitea-db<span class="w"> </span>pg_dump<span class="w"> </span>-U<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">GITEA_DB_USER</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>-d<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">GITEA_DB_NAME</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>-Fc<span class="w"> </span><span class="se">\</span>
<span class="w">  </span>&gt;<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">STAGING_DIR</span><span class="si">}</span><span class="s2">/gitea.dump"</span>
nerdctl<span class="w"> </span><span class="nb">exec</span><span class="w"> </span>-i<span class="w"> </span>gitea-db<span class="w"> </span>pg_restore<span class="w"> </span>--list<span class="w"> </span>&lt;<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">STAGING_DIR</span><span class="si">}</span><span class="s2">/gitea.dump"</span><span class="w"> </span>&gt;/dev/null
copy_tree<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">BUNDLE_BUILDER_DIR</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>bundle-builder
copy_tree<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">SERVICE_IMAGES_DIR</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>service-images
copy_tree<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">TOFU_ROOT</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>opentofu<span class="w"> </span>--exclude<span class="o">=</span>.terraform/<span class="w"> </span>--exclude<span class="o">=</span><span class="s1">'*.tfplan'</span><span class="w"> </span>--exclude<span class="o">=</span><span class="s1">'*.plan'</span><span class="w"> </span>--exclude<span class="o">=</span><span class="s1">'.ci.lock'</span>
copy_tree<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">RUNNER_HOME</span><span class="si">}</span><span class="s2">/.ssh"</span><span class="w"> </span>runner-ssh
install<span class="w"> </span>-m<span class="w"> </span><span class="m">0600</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">RUNNER_HOME</span><span class="si">}</span><span class="s2">/.runner"</span><span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">STAGING_DIR</span><span class="si">}</span><span class="s2">/runner-registration"</span>
getent<span class="w"> </span>passwd<span class="w"> </span>gitea-runner<span class="w"> </span>&gt;<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">STAGING_DIR</span><span class="si">}</span><span class="s2">/runner-user.txt"</span>
getent<span class="w"> </span>group<span class="w"> </span>gitea-runner<span class="w"> </span>&gt;<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">STAGING_DIR</span><span class="si">}</span><span class="s2">/runner-group.txt"</span>
tar<span class="w"> </span>--acls<span class="w"> </span>--xattrs<span class="w"> </span>--numeric-owner<span class="w"> </span>-cpf<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">STAGING_DIR</span><span class="si">}</span><span class="s2">/configuration.tar"</span><span class="w"> </span><span class="se">\</span>
<span class="w">  </span>-C<span class="w"> </span>/<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">CONFIG_PATHS</span><span class="p">[@]</span><span class="si">}</span><span class="s2">"</span>
nerdctl<span class="w"> </span>images<span class="w"> </span>--digests<span class="w"> </span>&gt;<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">STAGING_DIR</span><span class="si">}</span><span class="s2">/container-images.txt"</span>
date<span class="w"> </span>--iso-8601<span class="o">=</span>seconds<span class="w"> </span>&gt;<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">STAGING_DIR</span><span class="si">}</span><span class="s2">/captured-at.txt"</span>

<span class="nb">echo</span><span class="w"> </span><span class="s1">'[4/5] Resume services before the remote transfer.'</span>
resume_services
<span class="nb">trap</span><span class="w"> </span>-<span class="w"> </span>EXIT

<span class="nb">echo</span><span class="w"> </span><span class="s1">'[5/5] Create an encrypted remote backup snapshot.'</span>
restic<span class="w"> </span>backup<span class="w"> </span>--host<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">BACKUP_HOST</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>--tag<span class="w"> </span>release-services<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">STAGING_DIR</span><span class="si">}</span><span class="s2">"</span>
restic<span class="w"> </span>snapshots<span class="w"> </span>--host<span class="w"> </span><span class="s2">"</span><span class="si">${</span><span class="nv">BACKUP_HOST</span><span class="si">}</span><span class="s2">"</span><span class="w"> </span>--tag<span class="w"> </span>release-services
<span class="nb">echo</span><span class="w"> </span><span class="s1">'Remote backup completed. Retention/prune are separate operations.'</span>
</code></pre></div>

</details>

<details class="analysis-toggle" markdown="1">
<summary>/etc/systemd/system/release-services-backup.service — 전체 내용</summary>

<div class="highlight" data-source-path="host/etc/systemd/system/release-services-backup.service"><pre><code><span class="k">[Unit]</span>
<span class="na">Description</span><span class="o">=</span><span class="s">Consistent backup of release services</span>
<span class="na">Wants</span><span class="o">=</span><span class="s">network-online.target</span>
<span class="na">After</span><span class="o">=</span><span class="s">network-online.target</span>

<span class="k">[Service]</span>
<span class="na">Type</span><span class="o">=</span><span class="s">oneshot</span>
<span class="na">User</span><span class="o">=</span><span class="s">root</span>
<span class="na">UMask</span><span class="o">=</span><span class="s">0077</span>
<span class="na">ExecStart</span><span class="o">=</span><span class="s">/usr/local/sbin/backup-release-services</span>
<span class="na">ExecStartPost</span><span class="o">=</span><span class="s">/bin/bash -c 'set -euo pipefail</span><span class="c1">; source /etc/gitea-runner-env/backup.env; exec /usr/bin/flock -n /run/lock/release-services-backup.lock /usr/bin/restic forget --host "$${BACKUP_HOST}" --tag release-services --keep-daily 7 --keep-weekly 4 --keep-monthly 3'</span>
<span class="na">TimeoutStartSec</span><span class="o">=</span><span class="s">12h</span>
<span class="na">Nice</span><span class="o">=</span><span class="s">10</span>
<span class="na">IOSchedulingClass</span><span class="o">=</span><span class="s">best-effort</span>
<span class="na">IOSchedulingPriority</span><span class="o">=</span><span class="s">7</span>
</code></pre></div>

</details>

<details class="analysis-toggle" markdown="1">
<summary>/etc/systemd/system/release-services-backup.timer — 전체 내용</summary>

<div class="highlight" data-source-path="host/etc/systemd/system/release-services-backup.timer"><pre><code><span class="k">[Unit]</span>
<span class="na">Description</span><span class="o">=</span><span class="s">Daily release-services backup window</span>

<span class="k">[Timer]</span>
<span class="na">OnCalendar</span><span class="o">=</span><span class="s">*-*-* 01:00:00</span>
<span class="na">Persistent</span><span class="o">=</span><span class="s">false</span>
<span class="na">Unit</span><span class="o">=</span><span class="s">release-services-backup.service</span>

<span class="k">[Install]</span>
<span class="na">WantedBy</span><span class="o">=</span><span class="s">timers.target</span>
</code></pre></div>

</details>

<details class="analysis-toggle" markdown="1">
<summary>다른 물리서버로 백업을 활성화하는 순서</summary>

백업 서버에 sudo 권한이 없는 backup 사용자와 그 소유의 `/srv/backup/release-services`를 만든다. 운영 서버의 백업 전용 공개키를 등록하고 호스트 키 지문을 확인한다.

```bash title="백업 서버에서 최초 한 번 실행"
sudo useradd -m -s /bin/bash backup
sudo install -d -o backup -g backup -m 0700 /srv/backup/release-services
```

운영 서버 root의 SSH config에 별칭을 추가한다.

```sshconfig title="운영 서버의 ~/.ssh/config"
Host backup-store
    HostName backup.example.com
    User backup
    IdentityFile /root/.ssh/id_ed25519_backup
    IdentitiesOnly yes
    StrictHostKeyChecking yes
    BatchMode yes
```

```bash title="운영 서버 백업 준비"
ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519_backup -N ''
ssh-copy-id -i /root/.ssh/id_ed25519_backup.pub backup@backup.example.com
install -d -m 0700 /etc/release-backup /data/release-service-backup/staging /opt/gitea/service-images
touch /data/release-service-backup/staging/.release-backup-staging
(set -o noclobber; umask 077; openssl rand -base64 48 > /etc/release-backup/restic-password)
install -m 0600 "${CONFIG_SRC}/host/etc/gitea-runner-env/backup.env" /etc/gitea-runner-env/backup.env
install -m 0750 "${CONFIG_SRC}/host/usr/local/sbin/backup-release-services" /usr/local/sbin/backup-release-services
install -m 0644 "${CONFIG_SRC}"/host/etc/systemd/system/release-services-backup.* /etc/systemd/system/
source /etc/gitea-runner-env/services.env
nerdctl save -o /opt/gitea/service-images/bootstrap-images.tar "${GITEA_IMAGE}" "${POSTGRES_IMAGE}" "${NEXUS_IMAGE}"
install -m 0755 /usr/local/bin/gitea-runner /opt/gitea/service-images/gitea-runner
source /etc/gitea-runner-env/backup.env
restic init
```

암호화 비밀번호·SSH 복구 수단은 운영 서버 밖의 안전한 곳에도 보관한다. 유지보수 시간을 공지하고 수동 백업이 성공한 뒤 일정을 켠다.

```bash title="유지보수 시간에 실행 — Gitea·Nexus 일시 중단"
/usr/local/sbin/backup-release-services
systemctl daemon-reload
systemctl enable --now release-services-backup.timer
systemctl list-timers release-services-backup.timer
```

매일 01:00, 일간 7개·주간 4개·월간 3개 보관이다. 전송 전에 서비스를 재개한다. 주간 prune·check, 월간 데이터 읽기 검사와 별도 서버 복구 연습도 수행한다. 복구 절차는 [9편](2026-10-22-gitea-lightweight-9.md)에서 이어 볼 수 있다.

</details>

| 최종 확인 | 완료 기준 |
| --- | --- |
| Gitea | 로그인·clone·PR 승인·merge·Tag 발행 |
| Nexus | 관리자·CI·다운로드 권한 구분, 초기 재료 준비 |
| Runner | label 일치, 동시 작업 1개, UI 로그 표시 |
| skip / full | 선택과 결과가 각각 기록됨 |
| 공개물 | 동일 TAR 검증, 올바른 channel, 계열별 3개 |
| 고객사 / 사내 | deploy.sh와 clone 후 install.sh 양쪽 경로 동작 |
| 재부팅 | 유지보수 창에서 OS 재기동 후 서비스·URL 재확인 |
| 백업 | 원격 snapshot과 복원 수단 확인 |

이제 물리서버는 Git·파일 저장소를 넘어, 승인한 코드에서 배포물을 만드는 기반이 된다. 일상 변경은 코드와 재료 목록에 반영하고 호스트의 빌더를 릴리스마다 편집하는 운영으로 돌아가지 않는다.

[← 9편: 백업과 복구](2026-10-22-gitea-lightweight-9.md) · [1편: 경량화를 시작한 이유](2026-10-15-gitea-lightweight-1.md)
