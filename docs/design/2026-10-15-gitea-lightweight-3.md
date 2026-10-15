---
title: "사내 Gitea 경량화 (3) — 대용량 파일을 Nexus로 옮기고 Ansible 연결하기"
summary: "컨테이너 이미지와 일반 파일을 Nexus에 분리해 올리고, 로컬 files 디렉터리를 사용하던 Ansible을 다운로드 방식으로 바꿨다. 파일 분류부터 주소 설정, get_url, install.sh와 manifest의 연결까지 실제 구성에 맞춰 정리했다."
summary_style: editorial
date: 2026-10-15
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
      <span class="editorial-summary-label">사내 Gitea 경량화 · 파일 이관 편</span>
      <h2 id="editorial-summary-title" class="editorial-summary-title">설치할 재료는 Nexus에서 받고, 설치하는 방법은 Git에 남긴다.</h2>
      <p>컨테이너 이미지·프로그램 압축 파일·VM 이미지를 Nexus로 옮겼다. Ansible은 대상 노드에서 필요한 파일을 다운로드하고, install.sh는 런타임과 Ansible 컨테이너 이미지를 Nexus에서 준비한다.</p>
    </div>
  </div>
  <p class="editorial-summary-result"><span>바꾼 것은 <strong>설치 재료의 보관 위치와 가져오는 방식</strong>이다. 기존 서비스 설정과 배포 순서까지 함께 바꾸는 작업은 아니다.</span></p>
</section>

[2편](2026-10-15-gitea-lightweight-2.md)에서 Gitea·Nexus·Runner를 구성했다. 저장소를 띄웠다고 Git이 가벼워지지는 않는다. Git에 있던 파일을 옮기고, 그 파일을 사용하던 코드도 바꿔야 한다.

기존에는 Ansible의 `files/`에 바이너리를 넣고 `copy`로 전달했다. 컨테이너 이미지도 TAR로 보관한 뒤 `nerdctl load`로 불러왔다. 이 구조에서 파일만 삭제하면 배포가 끊긴다.

이번에는 **파일 분류 → Nexus 업로드 → 주소 연결 → 설치 코드 변경 → 확인** 순서로 정리한다. 서비스 구축과 자동 릴리스 Workflow는 각각 앞뒤 편으로 나눴다.

## 1. 확장자보다 파일의 용도로 나눈다

처음에는 `.tar`, `.tar.gz`, `.qcow2`를 모두 같은 대용량 파일로 봤다. 하지만 업로드 방식은 다르다. 컨테이너 이미지를 저장한 TAR와 프로그램 소스를 압축한 TAR는 구분해야 한다.

| 기존 파일 | Nexus에서 관리할 형태 | 사용할 때 |
| --- | --- | --- |
| `openstack-ansible.tar`, Ceph 컨테이너 TAR | `docker-hosted`의 컨테이너 이미지 | 이미지 주소로 pull |
| containerd·nerdctl·BuildKit 압축 파일, runc 바이너리 | `raw-hosted/ansible-runtime/` | 다운로드 후 설치 |
| `contrabass-mole.tar.gz` | `raw-hosted/contrabass-mole/<버전>/` | 다운로드 후 기존 설치 스크립트 실행 |
| 모니터링 바이너리 | `raw-hosted/monitoring/` | 다운로드 후 기존 서비스로 실행 |
| `.qcow2`, CirrOS `.img` | `raw-hosted/vm-image/` | 필요한 위치에 다운로드 후 사용 |
| Python wheel·일반 배포 압축 파일 | `raw-hosted`의 용도별 경로 | 파일로 다운로드 |
| Ansible task·설정 템플릿·작은 설치 스크립트 | Git | 기존처럼 실행·렌더링·복사 |

**컨테이너 TAR를 Docker Repository에 파일 업로드하는 것은 아니다.** 먼저 이미지로 불러온 다음, 이름을 붙여 push한다. 일반 파일은 원본 형태 그대로 Raw Repository에 올린다.

<div class="environment-grid" markdown="1">

<div markdown="1">

**일반 파일의 이동**

[![파일을 Raw Repository에 올리고 배포 대상 노드가 다운로드하는 흐름](../assets/gitea-lightweight-3/raw-flow.svg){ .architecture-diagram }](../assets/gitea-lightweight-3/raw-flow.svg)

</div>

<div markdown="1">

**컨테이너 이미지의 이동**

[![이미지를 Docker Repository에 push하고 컨테이너 런타임이 pull하는 흐름](../assets/gitea-lightweight-3/image-flow.svg){ .architecture-diagram }](../assets/gitea-lightweight-3/image-flow.svg)

</div>

</div>

`get_url`은 기본적으로 **Ansible을 실행한 컨테이너가 아니라 배포 대상 노드**에서 URL에 접속한다. 따라서 모든 대상 노드에서 Nexus에 접근할 수 있어야 한다. [Ansible get_url 동작](https://docs.ansible.com/projects/ansible/latest/collections/ansible/builtin/get_url_module.html)

---

## 2. Nexus 경로를 정하고 파일을 올린다

파일 본체를 저장하는 Blob Store는 `contrabass-engine` 하나를 사용하고, Repository는 형식에 따라 나눴다. 아래는 실제 경로 중 대표 항목이다.

```text title="설치 재료를 보관하는 Repository"
Nexus
└── contrabass-engine                  # Blob Store
    ├── docker-hosted                  # Docker Hosted
    │   ├── ansible/
    │   │   └── openstack-ansible:v1.6
    │   └── ceph19.2.3/
    │       ├── ceph:v19.2.3
    │       ├── nvmeof:1.2.5
    │       └── ...
    └── raw-hosted                     # Raw Hosted
        ├── ansible-runtime/
        │   ├── containerd-2.1.5-linux-amd64.tar.gz
        │   ├── nerdctl-2.1.6-linux-amd64.tar.gz
        │   ├── buildkit-v0.12.4.linux-amd64.tar.gz
        │   ├── cni-plugins-linux-amd64-v1.8.0.tgz
        │   └── runc.amd64
        ├── contrabass-mole/3.0.6/contrabass-mole.tar.gz
        ├── monitoring/node-exporter/1.6.1/node_exporter-linux-amd64
        ├── storage/seaweedfs/4.0.5/weed-linux-amd64
        ├── openstack/cinder/24.5.0/cinder-24.5.0.tar.gz
        ├── vm-image/cirros-0.6.2-x86_64-disk.img
        └── python-wheel/...
```

`ceph19.2.3/`에는 cephadm 배포에 쓰는 컨테이너들을 함께 두었다. Grafana·Prometheus 이미지도 여기 포함되며, 호스트에 설치하는 `monitoring/`의 바이너리와는 별개다.

Blob Store 이름은 다운로드 URL에 넣지 않는다. URL에는 **Repository 이름과 그 안의 경로**가 들어간다.

<p class="subsection-title"><strong>2-1. 일반 파일은 원본 그대로 업로드</strong></p>

<div class="section-body" markdown="1">

다음은 **업로드할 파일이 있는 작업용 서버**에서 수행하는 예시다. `release-upload`는 업로드 권한이 있는 전용 계정의 예시이며, 비밀번호는 프롬프트에서 입력한다.

```bash title="Raw 파일 업로드 예시"
NEXUS_URL=https://192.0.2.10:55555
NEXUS_UPLOAD_USER=release-upload
ARTIFACT_PATH=contrabass-mole/3.0.6/contrabass-mole.tar.gz

sha256sum contrabass-mole.tar.gz

curl -kfsS --user "${NEXUS_UPLOAD_USER}" \
  --upload-file contrabass-mole.tar.gz \
  "${NEXUS_URL}/repository/raw-hosted/${ARTIFACT_PATH}"
```

Raw Repository는 HTTP PUT으로 경로를 지정해 업로드할 수 있다. `/repository/raw-hosted/` 뒤의 문자열이 보관 경로가 된다. [Nexus Raw Repository](https://help.sonatype.com/en/raw-repositories.html)

같은 버전의 파일을 다른 내용으로 덮어쓰기보다, 새 버전 경로를 만드는 쪽으로 관리한다. 파일명에 버전이 없어도 상위 경로가 버전을 구분한다.

</div>

<p class="subsection-title"><strong>2-2. 컨테이너 TAR는 load → tag → push</strong></p>

<div class="section-body" markdown="1">

기존 `openstack-ansible.tar`를 옮기는 경우다. `nerdctl load` 출력과 `nerdctl images`에서 원래 이미지 이름을 확인한 다음 tag한다.

```bash title="컨테이너 이미지 이관 예시"
REGISTRY=192.0.2.10:55555

nerdctl load -i openstack-ansible.tar
nerdctl images

nerdctl tag openstack-ansible:v1.6 \
  "${REGISTRY}/docker-hosted/ansible/openstack-ansible:v1.6"

nerdctl --insecure-registry login \
  --username release-upload "${REGISTRY}"

nerdctl --insecure-registry push \
  "${REGISTRY}/docker-hosted/ansible/openstack-ansible:v1.6"
```

이 구성은 Nexus의 **path-based routing**을 사용한다. 이미지 주소에 `/docker-hosted/`는 넣지만 `/repository/`나 `https://`는 넣지 않는다. [Nexus Docker Registry](https://help.sonatype.com/en/docker-registry.html)

예제의 `-k`와 `--insecure-registry`는 자체 서명 인증서를 사용하는 시험 환경에 맞춘 옵션이다. 인증서 검증을 생략하는 것과 사용자 인증을 생략하는 것은 다르다. 신뢰할 수 있는 CA를 배포한 환경은 인증서 검증을 유지한다. [nerdctl Registry 설정](https://github.com/containerd/nerdctl/blob/v2.2.2/docs/registry.md)

</div>

---

## 3. 주소는 main.yml, 파일별 URL은 nexus.yml

Ansible에서 수정할 곳은 다음 두 파일이다. 경로의 기준은 `contrabass-engine/okestro/okestro-openstack/`이다.

```text title="Ansible 변수 파일 위치"
inventory/
├── inventory.ini
└── group_vars/all/
    ├── main.yml
    └── nexus.yml
```

`main.yml`에는 사용자가 접속할 Nexus 주소를 입력한다. **`https://` 없이 `IP:PORT`만 적는다.**

```yaml title="inventory/group_vars/all/main.yml — 주소 설정 부분"
# Controller01 API Network
nexus_url: 192.0.2.101:55555
package_ip: 198.51.100.10/rocky-9.6
```

`package_ip`는 OS 패키지 저장소 설정이다. Nexus 주소와 별도 용도이므로 함께 바꾸는 값이 아니다.

`nexus.yml`은 이 주소에 Repository와 파일 경로를 붙인다. 아래는 실제 설정의 대표 항목만 추린 것이다.

<div class="language-yaml highlight"><span class="filename">inventory/group_vars/all/nexus.yml — 일부</span><pre><code>nexus_validate_certs: false
nexus_raw_repository: "raw-hosted"
nexus_docker_repository: "docker-hosted"

nexus_raw_url: "https://&#123;&#123; nexus_url &#125;&#125;/repository/&#123;&#123; nexus_raw_repository &#125;&#125;"
nexus_registry: "&#123;&#123; nexus_url &#125;&#125;"
nexus_docker_url: "&#123;&#123; nexus_registry &#125;&#125;/&#123;&#123; nexus_docker_repository &#125;&#125;"

nexus_images:
  openstack_ansible: "&#123;&#123; nexus_docker_url &#125;&#125;/ansible/openstack-ansible:v1.6"
  ceph: "&#123;&#123; nexus_docker_url &#125;&#125;/ceph19.2.3/ceph:v19.2.3"

nexus_artifacts:
  contrabass_mole: "&#123;&#123; nexus_raw_url &#125;&#125;/contrabass-mole/3.0.6/contrabass-mole.tar.gz"
  node_exporter: "&#123;&#123; nexus_raw_url &#125;&#125;/monitoring/node-exporter/1.6.1/node_exporter-linux-amd64"
</code></pre></div>

<code>&#123;&#123; 변수명 &#125;&#125;</code> 표현은 변수 값을 끼워 넣는 Ansible의 Jinja 템플릿 문법이다. 예를 들어 위 설정에서 Node Exporter 주소는 다음처럼 완성된다.

```text title="최종 URL과 이미지 주소"
Raw:
https://192.0.2.101:55555/repository/raw-hosted/monitoring/node-exporter/1.6.1/node_exporter-linux-amd64

Container:
192.0.2.101:55555/docker-hosted/ansible/openstack-ansible:v1.6
```

`-i inventory/inventory.ini`로 실행하면 Ansible이 해당 인벤토리 옆의 `group_vars/all/`을 읽는다. 컨테이너의 `NEXUS_URL` 환경변수를 따로 넘기는 구조가 아니다. [Ansible 인벤토리 변수 로딩](https://docs.ansible.com/projects/ansible/latest/inventory_guide/intro_inventory.html)

!!! warning "사내 Nexus와 고객사 Private Nexus의 읽기 정책은 다르다"
    사내 Nexus의 Raw URL은 인증 없이 요청하면 401을 반환하는 것을 확인했다. 반면 고객사에 구성하는 Private Nexus 템플릿은 `raw-hosted`·`docker-hosted`의 익명 읽기를 허용한다. 위 Ansible 코드는 다운로드 계정을 전달하지 않으므로, 사내 Nexus를 직접 바라보는 시험은 읽기 권한과 인증 방식을 별도로 맞춰야 한다. 주소만 바꾸면 모든 환경에서 동작하는 것은 아니다.

---

## 4. Ansible은 복사 대신 다운로드한다

파일이 어디서 오는지만 바꾸고, 목적지·권한·서비스 실행 방식은 유지하는 것이 기준이다. 작은 설정 파일까지 모두 다운로드로 바꾸지는 않았다.

<p class="subsection-title"><strong>4-1. 바이너리: copy → get_url</strong></p>

<div class="section-body" markdown="1">

기존 패턴은 `files/`의 바이너리를 `copy`로 전달하는 방식이었다. 변경 후에는 대상 노드가 Nexus에서 직접 받는다. 아래는 `roles/prometheus/tasks/node-exporter-install.yml`의 다운로드 task다.

<div class="language-yaml highlight"><span class="filename">Node Exporter 다운로드 task</span><pre><code>- name: Download Node-exporter binary from Nexus
  ansible.builtin.get_url:
    url: "&#123;&#123; nexus_artifacts.node_exporter &#125;&#125;"
    dest: "&#123;&#123; exe_path &#125;&#125;/node_exporter"
    validate_certs: "&#123;&#123; nexus_validate_certs &#125;&#125;"
    owner: root
    group: root
    mode: '0755'
</code></pre></div>

실행 파일이므로 `0755`를 유지했다. 이후 서비스 설정 파일을 배치하고 서비스를 시작하는 기존 task는 별도로 남아 있다.

</div>

<p class="subsection-title"><strong>4-2. 프로그램 압축 파일: 설치 스크립트는 Git에 남긴다</strong></p>

<div class="section-body" markdown="1">

Contrabass Mole도 압축 파일만 Nexus로 옮겼다. `roles/contrabass/tasks/install-contrabass-mole.yml`에는 파일 존재 확인, 다운로드, 작은 설치 스크립트 복사, 기존 설치 명령이 이어진다.

<div class="language-yaml highlight"><span class="filename">Mole 패키지 다운로드 부분</span><pre><code>- name: Download mole package from Nexus
  ansible.builtin.get_url:
    url: "&#123;&#123; nexus_artifacts.contrabass_mole &#125;&#125;"
    dest: "&#123;&#123; mole_install_dir &#125;&#125;/&#123;&#123; mole_tar_file &#125;&#125;"
    validate_certs: "&#123;&#123; nexus_validate_certs &#125;&#125;"
    mode: '0644'
    owner: root
    group: root
  when: not mole_tar.stat.exists
</code></pre></div>

여기서 `mole_tar`는 앞선 `stat` task가 확인한 결과다. **목적지 파일이 있으면 다운로드를 건너뛴다.** 이 조건은 유지했다. 따라서 `nexus.yml`의 URL을 새 버전으로 바꾸는 것만으로 이미 설치된 노드가 자동 업그레이드되는 것은 아니다.

설치 스크립트인 `contrabass-mole-install.sh` 등은 Git에 남아 기존 `copy` task로 전달한다. “대용량 파일 이관”과 “설치 정책 변경”을 섞지 않는다.

</div>

<details class="analysis-toggle" markdown="1">
<summary>Ceph 이미지는 무엇이 달라졌나?</summary>

Ceph 이미지는 일반 파일처럼 `get_url`로 받지 않는다. cephadm이 사용하는 이미지 주소를 `nexus_images.ceph` 등으로 연결했다.

`roles/cephadm/tasks/configure-nexus-registry.yml`은 Podman이 사용할 `/etc/containers/registries.conf.d/nexus.conf`를 만든다. 현재 자체 서명 환경에서는 다음 설정을 쓴다.

```toml title="Podman Registry 설정 예시"
[[registry]]
location = "192.0.2.101:55555"
insecure = true
```

이 설정은 `nerdctl`의 `hosts.toml`과 별개다. Ansible 컨테이너를 받는 런타임과 Ceph 노드의 Podman이 각각 Registry에 접근한다.

</details>

---

## 5. install.sh도 Git 안의 TAR를 찾지 않게 바꾼다

Ansible 역할만 수정하면 끝나는 것이 아니다. Ansible 컨테이너를 처음 실행하는 `contrabass-engine/install.sh`도 기존에는 옆 디렉터리의 런타임 압축 파일과 `openstack-ansible.tar`를 사용했다.

변경 후에는 `release/manifest.yaml`에서 파일 경로·SHA256·Ansible 이미지 태그를 찾는다. SHA256은 파일 내용이 같은지 비교하는 해시다.

```text title="install.sh 실행에 필요한 Git 디렉터리 관계"
repository/
├── release/
│   └── manifest.yaml
└── contrabass-engine/
    ├── install.sh
    ├── containerd.service
    ├── nerdctl.toml
    ├── buildkit.service / buildkit.socket / buildkitd.toml
    └── okestro/okestro-openstack/
```

`install.sh`는 자신의 위치를 기준으로 `../release/manifest.yaml`을 읽는다. **`contrabass-engine/`만 따로 복사하면 manifest를 찾지 못한다.** 작은 서비스·설정 파일도 설치에 쓰므로 Git에서 함께 가져와야 한다.

| 준비 대상 | 변경 전 | 변경 후 |
| --- | --- | --- |
| containerd·runc·nerdctl·BuildKit·CNI | 실행 디렉터리의 파일 | manifest 경로로 Raw 다운로드, SHA256 확인 |
| Ansible 컨테이너 | `openstack-ansible.tar`를 load | manifest의 태그로 Nexus 이미지 pull |
| CirrOS 이미지 | Git의 `.img` 파일 | Raw에서 받은 뒤 기존 컨테이너 경로로 복사 |
| 서비스·설정·Ansible 코드 | Git 파일 사용 | Git 파일 사용 유지 |

런타임 파일은 `/var/cache/contrabass-engine/ansible-runtime/`에 저장한다. 파일이 있고 SHA256이 같으면 재사용하고, 없거나 해시가 다르면 다시 받는다. 이 캐시는 뒤에서 다룰 Runner의 패키징용 캐시와 별개다.

<details class="analysis-toggle" markdown="1">
<summary>다운로드와 컨테이너 실행 코드는 어떻게 연결되나?</summary>

아래는 전체 설치 스크립트가 아니라 **연결 관계를 보여주는 발췌**다. `download_artifact` 함수는 manifest에서 해당 경로와 SHA256을 찾아 다운로드·검증한다.

```bash title="install.sh — Nexus 주소와 manifest 위치"
NEXUS_ADDRESS="$1"
NEXUS_URL="https://${NEXUS_ADDRESS}"
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="/var/cache/contrabass-engine/ansible-runtime"
MANIFEST="${BASE_DIR}/../release/manifest.yaml"
```

```bash title="install.sh — 설치 재료를 찾는 부분"
containerd_file="$(download_artifact ansible-runtime/containerd-)"
runc_file="$(download_artifact ansible-runtime/runc.amd64)"
nerdctl_file="$(download_artifact ansible-runtime/nerdctl-)"
buildkit_file="$(download_artifact ansible-runtime/buildkit-)"
cni_file="$(download_artifact ansible-runtime/cni-plugins-)"
cirros_file="$(download_artifact vm-image/cirros-)"
```

컨테이너 이미지는 manifest에서 읽은 `image_tag`로 주소를 만들고 pull한다. Ansible 코드의 bind mount와 컨테이너 내부 경로는 유지했다.

```bash title="install.sh — 기존 실행 방식에 이미지 주소 연결"
IMAGE="${NEXUS_ADDRESS}/docker-hosted/ansible/openstack-ansible:${image_tag}"

nerdctl pull "${IMAGE}"
nerdctl run -dt --name "${CONTAINER_NAME}" \
  --ulimit nofile=65536:65536 \
  -v "${BASE_DIR}/okestro/okestro-openstack:/root/okestro/okestro-openstack" \
  "${IMAGE}"

nerdctl cp "${cirros_file}" "${CONTAINER_NAME}:/root/okestro/"
```

인자로 받은 주소는 설치 재료를 받을 때 사용한다. 컨테이너 안에서 Ansible이 사용할 주소는 앞서 설명한 `inventory/group_vars/all/main.yml`에 별도로 입력한다.

</details>

!!! warning "다운로드 캐시가 있다고 설치 전체가 재실행 안전한 것은 아니다"
    현재 `install.sh`는 기존처럼 런타임 설정을 만들고 서비스를 재시작하며, 고정 이름으로 컨테이너를 실행한다. 이미 서비스 중인 Gitea·Nexus 호스트에서 시험 삼아 실행하는 스크립트가 아니다. 전용 배포 노드에서 기존 설치 여부와 영향을 확인한 뒤 사용한다.

필요한 파일·이미지가 준비되어 있고 익명 읽기가 가능한 Private Nexus를 기준으로, **새 전용 배포 노드**에서 호출하는 형식은 다음과 같다. `main.yml`의 Nexus 주소도 같은 접속점으로 맞춘다.

```bash title="전용 배포 노드에서 install.sh 호출"
cd repository/contrabass-engine
sudo ./install.sh 192.0.2.101:55555
```

`repository`는 가져온 Git 디렉터리 이름으로 바꾼다. 이후 inventory와 배포 변수에 맞춰 Ansible을 실행하는 흐름은 유지된다.

---

## 6. manifest.yaml과 nexus.yml을 함께 맞춘다

파일을 옮기면서 새로 생긴 관리 항목이 있다. **패키징에 넣을 목록과 Ansible이 받을 주소가 일치해야 한다.**

| 파일 | 누가 사용하는가 | 담는 내용 |
| --- | --- | --- |
| `release/manifest.yaml` | 패키징 스크립트, `install.sh` | 수집할 파일 경로·SHA256, 이미지 이름·태그·digest |
| `inventory/group_vars/all/nexus.yml` | Ansible | task에서 사용할 파일별 URL과 이미지 주소 |
| `inventory/group_vars/all/main.yml` | Ansible·사용자 | 배포 환경의 Nexus 주소 등 |

digest는 이미지 내용을 식별하는 값이다. 바뀔 수 있는 이름표인 태그와 달리, 어떤 이미지 내용을 패키징했는지 확인하는 데 사용한다.

다음은 실제 manifest에서 Mole와 Ansible 이미지 항목만 발췌한 예다. 전체 릴리스 `4.1.1`과 Mole 아티팩트 경로의 `3.0.6`은 서로 다른 버전이다.

```yaml title="release/manifest.yaml — 대표 항목 발췌"
schema_version: 2
release: "4.1.1"

artifacts:
  - path: "contrabass-mole/3.0.6/contrabass-mole.tar.gz"
    sha256: "68c14a2c9c6d881ce40c38f6abd0e6acc24c46b8076a00d56b626f443a208fab"

images:
  - name: "ansible/openstack-ansible"
    tag: "v1.6"
    digest: "sha256:c950fff9abb30c0070da407c31f8ed6d3bbc783f7e2f417f8ab97916b8e88409"
```

실제 manifest에는 Nexus 자체의 이미지 정보와 나머지 런타임·배포 파일도 있다. 위 발췌만으로 전체 패키징을 수행하는 것은 아니다.

현재 Ansible이 manifest를 직접 읽어 모든 URL을 만드는 구조는 아니다. 예를 들어 Mole를 새 버전으로 교체하면 다음을 함께 수정한다.

1. 새 파일을 Nexus의 새 버전 경로에 업로드한다.
2. `manifest.yaml`의 경로·SHA256을 바꾼다.
3. `nexus.yml`의 `contrabass_mole` URL 경로도 같은 버전으로 바꾼다.
4. 기존 노드 업그레이드가 목적이면 파일 존재 조건과 설치 정책도 별도로 확인한다.

**파일을 Nexus에 올리는 것만으로 코드가 그 파일을 쓰게 되지는 않는다.** 자동 패키징도 manifest에 선언된 재료를 모으는 방식이지, Nexus에서 가장 최근에 올라온 파일을 임의로 고르는 방식이 아니다.

---

## 7. 파일 삭제 전, 연결이 끊기지 않았는지 확인한다

이관 확인은 “Nexus에 파일이 보인다”에서 끝내지 않는다. 실제 사용할 경로, 내려받은 내용, 코드를 읽는 위치를 함께 확인한다.

| 확인할 것 | 확인 기준 |
| --- | --- |
| Raw 경로 | manifest와 `nexus.yml`이 같은 파일을 가리킨다 |
| 다운로드 결과 | HTTP 오류가 없고 업로드한 파일과 SHA256이 같다 |
| 컨테이너 이미지 | 대상 Registry에 태그·digest가 있고 대상 노드에서 pull 가능하다 |
| Ansible task | 목적지·소유권·실행 권한·서비스 연결이 기존과 같다 |
| 작은 파일 | 설치 스크립트·서비스 unit·설정 템플릿이 Git에 남아 있다 |
| 접속 정책 | 대상 노드가 Nexus에 접근할 수 있고 읽기 권한이 있다 |

<details class="analysis-toggle" markdown="1">
<summary>Raw 파일을 내려받아 확인하는 최소 명령</summary>

업로드 예시와 같은 파일을 **사내 Nexus에서 인증하여** 내려받는다. 원본이 있는 작업 디렉터리에서 실행한다.

```bash title="업로드한 Raw 파일과 원본 비교"
NEXUS_URL=https://192.0.2.10:55555
NEXUS_READ_USER=release-download
ARTIFACT_PATH=contrabass-mole/3.0.6/contrabass-mole.tar.gz

curl -kfsSL --user "${NEXUS_READ_USER}" \
  "${NEXUS_URL}/repository/raw-hosted/${ARTIFACT_PATH}" \
  -o contrabass-mole.downloaded.tar.gz

sha256sum contrabass-mole.tar.gz contrabass-mole.downloaded.tar.gz
cmp contrabass-mole.tar.gz contrabass-mole.downloaded.tar.gz
```

`-f`를 넣어 401·404를 실패로 처리한다. 이 옵션이 없으면 오류 HTML을 정상 파일처럼 저장할 수 있다. 익명 읽기를 허용한 Private Nexus에서는 `--user`를 생략한다.

현재 Ansible의 모든 `get_url` task에 checksum이 설정된 것은 아니다. manifest의 SHA256 검증과 각 역할의 다운로드 검증을 같은 기능으로 보지 않는다.

</details>

<details class="analysis-toggle" markdown="1">
<summary>Git에 큰 파일이 남았는지 확인하기</summary>

저장소 최상위에서 현재 커밋의 파일을 확인한다. 파일명이 공백을 포함해도 크기는 네 번째 필드에 나온다.

```bash title="현재 커밋에서 10MiB 이상인 파일 확인"
git ls-tree -rl HEAD | awk '$4 ~ /^[0-9]+$/ && $4 >= 10485760'
```

확인한 현재 형상에는 10MiB 이상인 추적 파일이 없었다. 일부 OpenSSL RPM처럼 남아 있는 바이너리도 있으므로, “Git에서 바이너리를 모두 없앴다”는 뜻은 아니다.

이 명령은 **현재 커밋의 파일 목록**만 본다. 기존 저장소에서 파일을 삭제해도 과거 커밋의 대용량 blob은 남는다. 기존 이력까지 정리할지, 코드 중심의 새 저장소로 분리할지는 [1편](2026-10-15-gitea-lightweight-1.md)에서 다룬 별도 결정이다.

</details>

여기까지 바꾸면 개발자가 코드를 받을 때 설치 재료의 전체 이력을 함께 받을 이유가 줄어든다. 배포 시 필요한 파일은 Nexus에서 준비하고, 설치 방법과 설정 변경은 Git에서 추적한다.

남은 일은 이 재료들을 사람이 매번 수집하지 않게 만드는 것이다. 다음 편에서는 **릴리스 태그 → Runner의 파일·이미지 수집 → 고객사 반입용 TAR 생성 → Nexus 게시**로 이어지는 자동 패키징 흐름을 정리한다.
