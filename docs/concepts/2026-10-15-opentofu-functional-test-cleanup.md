---
title: "OpenTofu 입문 가이드 - 6"
summary: "6편: 미리 준비한 QCOW2로 시험 인스턴스를 만들고 VXLAN·Provider망과 볼륨을 연결한다. 통과한 TAR만 발행하며 성공·실패 모두 시험 VM과 plan을 정리한다."
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
      <h2 id="editorial-summary-title" class="editorial-summary-title">Ansible 완료 뒤 실제 자원을 만들어 보고, 시험 환경은 결과와 관계없이 정리한다.</h2>
      <p>VMware VM을 만드는 OpenTofu와, 그 안에 배포한 OpenStack을 시험하는 OpenTofu를 분리한다. Runner에 미리 준비한 이미지를 Glance에 올리고 시험 인스턴스 한 대에 VXLAN망·Provider망과 볼륨을 연결한다. Actions에 실행 로그를 남기고 시험 자원과 VM을 순서대로 제거한다.</p>
    </div>
  </div>
  <p class="editorial-summary-result"><span><strong>배포 → OpenStack 기능 시험 → 동일 TAR 발행 → 시험 VM 정리</strong>. plan은 삭제하지만 다음 정리와 재실행에 필요한 State는 보존한다.</span></p>
</section>

[5편](2026-10-15-opentofu-staging-release.md)의 staging·해시 검증·승격 구조를 이어서 사용한다. 이번 편에서 추가하는 것은 **배포 후 기능 시험과 자동 정리**다. Workflow는 계속 `.gitea/workflows/publish-manifest.yaml` 하나만 사용한다.

---

## 1. 배포 전 점검과 배포 후 시험을 구분

<figure class="flow" aria-label="배포 시험과 자동 정리 순서">
  <ol>
    <li>VM·Ansible 배포</li>
    <li>OpenStack 기능 시험</li>
    <li>통과한 TAR 발행</li>
    <li>시험 VM 정리</li>
  </ol>
</figure>

```text
태그 push → TAR 빌드 → staging 게시
  → VMware VM 4대 생성·SSH 준비 확인
  → 첫 VM에서 staging TAR 설치·deploy.sh 실행
  → Nexus·Ansible 컨테이너 실행 확인        ← 배포 전 사전 점검
  → ansible-playbook 실행
  → Runner에 미리 둔 QCOW2 파일 확인
  → Glance 이미지 등록 → VXLAN·Provider망 연결 인스턴스·볼륨 생성
  → OpenStack 시험 자원 정리
      ├─ 시험·정리 성공: 동일 TAR 최종 게시·current 갱신
      └─ 실패: 최종 게시 건너뜀
  → VMware 시험 VM 정리                    ← 성공·실패 모두
  → staging 후보 정리
```

배포 전에는 두 컨테이너에서 명령을 실행할 수 있는지만 확인한다.

```bash title="배포 전 컨테이너 확인"
nerdctl exec nexus true
nerdctl exec okestro-os-ansible true
```

`ansible.builtin.ping`은 일반 네트워크 ping이 아니라 SSH 인증과 원격 Python 실행이 필요한 모듈이다. SSH 인증을 이후 Ansible 초기 작업에서 준비한다면 사전 점검에 넣지 않는다. 컨테이너 실행 확인만으로 Nexus API나 OpenStack 기능까지 검증되는 것은 아니다. [Ansible ping 모듈](https://docs.ansible.com/ansible/latest/collections/ansible/builtin/ping_module.html)

OpenStack 기능 시험은 별개다. Ansible이 정상 종료한 뒤 실제 OpenStack API로 네트워크·인스턴스·볼륨을 만들어 본다.

---

## 2. OpenTofu 프로젝트는 두 개, 역할도 두 개

| 프로젝트 | 접속 대상 | 생성·삭제 대상 |
| --- | --- | --- |
| `contrabass-packaging` | vCenter | OpenStack을 설치할 VMware VM 4대 |
| `openstack-smoke` | 방금 배포한 OpenStack API | 시험 이미지·네트워크·인스턴스·볼륨 |

**smoke test**는 핵심 기능이 동작하는지 작은 구성으로 빠르게 확인하는 시험이다. 두 프로젝트의 코드·State를 한 디렉터리에 섞지 않는다. 하나는 시험 인프라, 다른 하나는 그 안의 시험 자원을 관리한다.

```text
/var/lib/gitea-runner/opentofu/
├── contrabass-packaging/       # 기존 VMware·Ansible 배포 코드
│   ├── main.tf, deployment.tf, ...
│   ├── terraform.tfstate
│   └── deploy.tfplan           # 매번 생성 후 삭제
└── openstack-smoke/            # 이번에 추가하는 독립 프로젝트
    ├── provider.tf
    ├── main.tf
    ├── lab.auto.tfvars
    ├── .terraform.lock.hcl
    ├── terraform.tfstate
    ├── noble-qemu-okestro2018.qcow2 # 미리 준비한 원본 이미지: 유지
    └── smoke.tfplan            # 매번 생성 후 삭제
```

기존 POC는 이미지 업로드, 이중 네트워크, 여러 인스턴스와 볼륨, Quota 변경을 모듈로 구성했다. 여기서는 이미지 업로드와 이중 네트워크는 유지하고 **VM 한 대·부팅 볼륨·추가 볼륨 한 개**로 줄인다. Quota나 기본 보안그룹을 바꾸지 않으며, 기존 POC의 State도 가져오지 않는다.

**이번 시험이 확인하는 범위**

- Runner에 준비한 QCOW2 파일 확인과 Glance 이미지 등록.
- Nova Flavor·인스턴스 생성, API 기준 `active` 상태.
- Neutron VXLAN망·Provider망과 각 서브넷 생성, 인스턴스 NIC 두 개 연결.
- Cinder 볼륨 부팅과 추가 볼륨 연결·제거.

인스턴스 내부의 SSH·파일 읽기/쓰기, 외부망 통신, 고가용성·장애 복구는 이번 합격 기준에 넣지 않는다. API에서 생성·연결됐다고 그 기능까지 시험한 것은 아니다.

---

## 3. 모듈 없는 OpenStack 시험 코드

Runner의 `openstack-smoke` 디렉터리에 아래 세 파일을 둔다. **기존 VMware 프로젝트 안에 추가하지 않는다.**

프로젝트 디렉터리는 Runner 서비스 계정이 쓰도록 만든다. 서비스 계정명이 다르면 소유자와 그룹을 맞춘다.

```bash title="Runner — 새 시험 프로젝트 디렉터리 준비"
sudo install -d -o gitea-runner -g gitea-runner -m 0750 \
  /var/lib/gitea-runner/opentofu/openstack-smoke
```

<p class="subsection-title"><strong>3-1. Provider와 인증</strong></p>

<div class="section-body" markdown="1">

Provider는 API 요청을 처리하는 플러그인이다. 기존 POC와 같은 OpenStack Provider `1.53.0`을 사용한다. `cloud = "..."`를 고정하지 않고 Workflow의 `OS_*` 환경변수로 이번 시험 클러스터에 접속한다. [Provider 1.53.0 인증 설정](https://github.com/terraform-provider-openstack/terraform-provider-openstack/blob/v1.53.0/docs/index.md)

```hcl title="openstack-smoke/provider.tf"
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "= 1.53.0"
    }
  }
}

provider "openstack" {}
```

Nexus 계정, vCenter 계정, OpenStack 계정은 서로 다르다. Runner에서 Keystone뿐 아니라 서비스 카탈로그가 반환하는 Nova·Neutron·Glance·Cinder 주소에도 접근할 수 있어야 한다.

</div>

<p class="subsection-title"><strong>3-2. 시험 자원 정의</strong></p>

<div class="section-body" markdown="1">

이미지는 Runner의 다음 경로에 **미리 준비해 둔다.** Workflow에서 이미지를 다운로드하지 않는다.

```text
/var/lib/gitea-runner/opentofu/openstack-smoke/noble-qemu-okestro2018.qcow2
```

OpenTofu는 `main.tf`와 같은 디렉터리에 놓인 QCOW2를 `local_file_path`로 읽어 Glance에 업로드한다. Runner 서비스 계정이 파일을 읽을 수 있어야 한다. 아래 예제의 파일명과 일치시켜 두면 Nexus 주소나 이미지 다운로드용 계정 설정은 필요 없다. 프로젝트 경로를 바꿀 때는 QCOW2도 그 프로젝트 디렉터리에 둔다. [Glance 이미지와 local_file_path](https://github.com/terraform-provider-openstack/terraform-provider-openstack/blob/v1.53.0/docs/resources/images_image_v2.md)

네트워크는 **터널망 한 개 + Provider망 한 개**다. `value_specs`의 `provider:network_type`으로 터널망의 종류를 명시하고, 인스턴스의 `network` 블록 두 개로 각각 연결한다. Provider망 예제는 Flat 방식이며 물리망 이름은 실제 Neutron 매핑과 맞춘다. [네트워크 value_specs 설정](https://github.com/terraform-provider-openstack/terraform-provider-openstack/blob/v1.53.0/docs/resources/networking_network_v2.md)

<details class="analysis-toggle" markdown="1">
<summary>main.tf 전체 — 모듈 없이 한 파일로 구성</summary>

```hcl title="openstack-smoke/main.tf"
variable "overlay_network_type" {
  type = string

  validation {
    condition     = contains(["vxlan", "geneve"], var.overlay_network_type)
    error_message = "overlay_network_type must be vxlan or geneve."
  }
}

variable "provider_physical_network" {
  type = string
}

variable "provider_cidr" {
  type = string
}

variable "provider_gateway" {
  type = string
}

variable "provider_allocation_pool" {
  type = object({
    start = string
    end   = string
  })
}

resource "openstack_images_image_v2" "test" {
  name             = "release-smoke-noble"
  local_file_path  = "${path.module}/noble-qemu-okestro2018.qcow2"
  container_format = "bare"
  disk_format      = "qcow2"

  properties = {
    hw_qemu_guest_agent = "yes"
    hw_require_fsfreeze = "yes"
  }
}

resource "openstack_compute_flavor_v2" "test" {
  name  = "release-smoke-2c2g"
  ram   = 2048
  vcpus = 2
  disk  = 0
}

resource "openstack_networking_network_v2" "overlay" {
  name = "release-smoke-overlay"

  value_specs = {
    "provider:network_type" = var.overlay_network_type
  }
}

resource "openstack_networking_subnet_v2" "overlay" {
  name        = "release-smoke-overlay-subnet"
  network_id  = openstack_networking_network_v2.overlay.id
  cidr        = "198.51.100.0/24"
  ip_version  = 4
  enable_dhcp = true
  no_gateway  = true
}

resource "openstack_networking_network_v2" "provider" {
  name     = "release-smoke-provider"
  external = true

  value_specs = {
    "provider:network_type"     = "flat"
    "provider:physical_network" = var.provider_physical_network
  }
}

resource "openstack_networking_subnet_v2" "provider" {
  name        = "release-smoke-provider-subnet"
  network_id  = openstack_networking_network_v2.provider.id
  cidr        = var.provider_cidr
  ip_version  = 4
  enable_dhcp = true
  gateway_ip  = var.provider_gateway

  allocation_pool {
    start = var.provider_allocation_pool.start
    end   = var.provider_allocation_pool.end
  }
}

resource "openstack_compute_instance_v2" "test" {
  name      = "release-smoke-vm"
  flavor_id = openstack_compute_flavor_v2.test.id

  block_device {
    uuid                  = openstack_images_image_v2.test.id
    source_type           = "image"
    destination_type      = "volume"
    volume_size           = 20
    boot_index            = 0
    delete_on_termination = true
  }

  network {
    uuid = openstack_networking_network_v2.overlay.id
  }

  network {
    uuid = openstack_networking_network_v2.provider.id
  }

  depends_on = [
    openstack_networking_subnet_v2.overlay,
    openstack_networking_subnet_v2.provider,
  ]
}

resource "openstack_blockstorage_volume_v3" "test" {
  name = "release-smoke-data"
  size = 1
}

resource "openstack_compute_volume_attach_v2" "test" {
  instance_id = openstack_compute_instance_v2.test.id
  volume_id   = openstack_blockstorage_volume_v3.test.id
}

output "smoke_result" {
  value = {
    instance_id        = openstack_compute_instance_v2.test.id
    image_status       = openstack_images_image_v2.test.status
    power_state        = openstack_compute_instance_v2.test.power_state
    network_ids        = [for nic in openstack_compute_instance_v2.test.network : nic.uuid]
    volume_id          = openstack_blockstorage_volume_v3.test.id
    attached_volume_id = openstack_compute_volume_attach_v2.test.volume_id
  }
}
```

`depends_on`은 두 서브넷이 준비된 뒤 인스턴스를 만들도록 한다. 첫 NIC는 터널망, 두 번째 NIC는 Provider망이다. 부팅 볼륨은 인스턴스 제거 시 삭제하고, 추가 볼륨은 연결 해제 후 별도로 삭제하도록 의존 관계가 구성된다.

</details>

```hcl title="openstack-smoke/lab.auto.tfvars"
overlay_network_type      = "vxlan"
provider_physical_network = "external"
provider_cidr             = "203.0.113.0/24"
provider_gateway          = "203.0.113.1"
provider_allocation_pool = {
  start = "203.0.113.151"
  end   = "203.0.113.160"
}
```

IP와 물리망 이름은 예시다. `external`은 Neutron의 물리망 식별자이며, 네트워크 표시 이름이나 NIC 이름이 아니다. 실제 브리지 매핑·외부망 CIDR·게이트웨이에 맞추고 **시험 전용으로 예약한 IP만 할당 풀에 넣는다.** 예제는 Provider망에서 DHCP를 사용하므로 실제 네트워크의 DHCP 운영과 충돌하지 않는 구간이어야 한다. 부팅 볼륨 20GiB와 Flavor도 QCOW2 이미지의 최소 요구 사양에 맞춘다.

현재는 `overlay_network_type = "vxlan"`을 사용한다. OVN으로 전환한 뒤에는 `geneve`로 바꿀 수 있지만, **이 변수만 바꾼다고 OpenStack이 OVN 구조로 전환되는 것은 아니다.** Neutron 백엔드·터널 종류·할당 범위가 먼저 해당 유형을 지원해야 한다. 터널 ID는 별도로 고정하지 않고 Neutron의 구성된 범위에서 할당받는다. [Neutron ML2 설정](https://docs.openstack.org/neutron/2025.1/configuration/samples/ml2-conf.html)

Provider `1.53.0` 예제에서는 `segments` 대신 위 `value_specs`로 네트워크 유형만 전달한다. 지정하지 않은 터널 ID를 `0`으로 보내는 상황을 피하고 Neutron이 ID를 할당하도록 하기 위한 구성이다. [Provider 요청 구성](https://github.com/terraform-provider-openstack/terraform-provider-openstack/blob/v1.53.0/openstack/types.go)

!!! warning "Provider망 생성 범위"
    예제는 이번 시험용 Provider망도 새로 생성·삭제한다. 같은 물리망에 Flat Provider망이 이미 있으면 새로 만들 수 없는 구성이 있으므로 기존 망을 중복 생성하지 않는다. 기존 망을 재사용할 때는 해당 망을 data source로 조회하고, 시험 State가 기존 망을 삭제 대상으로 소유하지 않도록 별도로 맞춘다.

이번 구성은 관리자 권한이 필요한 Flavor·Provider망 생성까지 포함한다. 시험 클러스터 전용 계정으로 실행하며 운영 OpenStack에 연결하지 않는다.

</div>

---

## 4. 주소·경로는 기존 통합 설정에 추가

기존 `/etc/gitea-runner-env/bundle-pipeline.env`에 아래 항목을 추가한다. 값은 전부 예시이며, `OPENSTACK_AUTH_URL`은 **이번 VMware VM에 배포할 OpenStack의 Keystone 주소**다. 기존 사내 OpenStack 주소가 아니다.

```bash title="bundle-pipeline.env — 추가 항목"
OPENSTACK_TEST_DIR=/var/lib/gitea-runner/opentofu/openstack-smoke
OPENSTACK_AUTH_URL=http://192.0.2.100:5000/v3
OPENSTACK_USERNAME=admin
OPENSTACK_PROJECT_NAME=admin
OPENSTACK_USER_DOMAIN_NAME=Default
OPENSTACK_PROJECT_DOMAIN_NAME=Default
```

비밀번호는 Gitea 저장소의 **설정 → Actions → Secrets**에 `OPENSTACK_PASSWORD`로 등록한다. 시험 배포에서 사용하는 OpenStack 계정 비밀번호이며 서버 root 비밀번호나 Nexus 비밀번호가 아니다.

VM 정리 Step에서도 vCenter·Nexus 입력을 읽어야 한다. 5편에서 시험 Step에만 넣었던 아래 환경변수 네 개를 **`jobs.release.env`로 옮긴다.** 기존 Git·Nexus 게시용 Job 환경변수는 유지한다.

```yaml title="publish-manifest.yaml — 기존 jobs.release에 반영"
jobs:
  release:
    env:
      VSPHERE_USER: ${{ secrets.VSPHERE_USER }}
      VSPHERE_PASSWORD: ${{ secrets.VSPHERE_PASSWORD }}
      TF_VAR_nexus_user: ${{ secrets.NEXUS_DOWNLOAD_USER }}
      TF_VAR_nexus_password: ${{ secrets.NEXUS_DOWNLOAD_PASSWORD }}
```

이 코드는 관련 부분만 보여 준다. 기존 `runs-on`, `timeout-minutes`, 나머지 `env`와 `steps`를 지우고 덮어쓰는 예제가 아니다. VMware Provider는 `VSPHERE_*`, OpenStack Provider는 `OS_*`를 사용한다.

---

## 5. 기능 시험이 통과해야 발행하도록 연결

추가되는 Step은 두 개뿐이다. 기존 VMware 시험 Step에는 정리 대상 표시를 추가하고, 합격 파일을 만드는 위치만 기능 시험 뒤로 옮긴다.

```text
기존 VM·Ansible 시험 Step
  → [추가] Test OpenStack functions
  → 기존 Promote tested bundle
  → [추가] Clean test VMs        # always()
  → 기존 Clean staging candidate # always()
```

<p class="subsection-title"><strong>5-1. VMware 시험 Step에서 바꿀 부분</strong></p>

<div class="section-body" markdown="1">

`job_dir`을 정한 직후 이전 표시를 지운다. 같은 이름의 파일이 남아 이번 시험의 성공으로 오인되지 않게 한다.

```bash title="기존 Test release with OpenTofu — 앞부분에 추가"
rm -f -- "${job_dir}/vm-cleanup.enabled" "${job_dir}/test-passed.sha256"
```

기존의 초기화·검증·이전 VM 확인은 유지한다. **이전 VM이 없음을 확인한 다음, plan 직전에** 아래 표시를 만든다.

```bash title="기존 이전 VM 확인 통과 후 — plan·apply 부분"
touch "${job_dir}/vm-cleanup.enabled"
tofu plan -input=false -no-color -out=deploy.tfplan
tofu apply -input=false -no-color deploy.tfplan
```

5편의 apply 바로 다음에 있던 `test-passed.sha256` 생성 명령은 제거한다. 이제 VMware·Ansible 성공만으로 합격 처리하지 않는다. **기능 시험 Step만 합격 파일을 만든다.**

시험할 `TF_VAR_bundle_url`은 계속 staging 후보 주소를 사용한다. 기존 코드가 아래쪽에서 최종 release 주소로 다시 덮어쓰지 않는지도 확인한다. HCL 수정 후에는 두 프로젝트에서 `tofu fmt`로 서식을 맞춰 `fmt -check` 실패를 방지한다.

`vm-cleanup.enabled`는 삭제 명령이 아니다. 이번 Job이 VM 생성을 시도했다는 표시다. 이전 시험 VM 때문에 시작을 거절했을 때는 표시를 만들지 않으므로, 마지막 정리 Step이 남의 시험 환경을 삭제하지 않는다. apply 도중 일부 VM만 만들어진 경우에는 표시가 있으므로 정리 대상이 된다.

</div>

<p class="subsection-title"><strong>5-2. Ansible 다음에 OpenStack 기능 시험 추가</strong></p>

<div class="section-body" markdown="1">

아래 Step을 **기존 VM·Ansible 시험 다음, 승격 이전**에 추가한다. 전용 프로젝트의 로컬 Backend·기본 workspace를 사용하고, Runner 동시 Job 수 1개를 유지한다. 수동 실행도 `.ci.lock`을 함께 사용하며 CI와 동시에 실행하지 않는다. 이미 이전 버전의 Step을 추가했다면 새로 중복 추가하지 않고 해당 Step을 아래 내용으로 교체한다.

<details class="analysis-toggle" markdown="1">
<summary>Test OpenStack functions — 시험과 OpenStack 자원 정리</summary>

```yaml title="publish-manifest.yaml — 새 Step"
      - name: Test OpenStack functions
        shell: bash
        env:
          OS_PASSWORD: ${{ secrets.OPENSTACK_PASSWORD }}
        run: |
          set -euo pipefail
          umask 077
          job_dir="${PWD}"
          source /etc/gitea-runner-env/bundle-pipeline.env
          source "${BUNDLE_BUILDER_DIR}/common.sh"
          : "${OPENSTACK_TEST_DIR:?Set OPENSTACK_TEST_DIR}"
          : "${OS_PASSWORD:?Set OPENSTACK_PASSWORD secret}"
          test -f "${job_dir}/vm-cleanup.enabled"

          export OS_AUTH_URL="${OPENSTACK_AUTH_URL:?Set OPENSTACK_AUTH_URL}"
          export OS_USERNAME="${OPENSTACK_USERNAME:?Set OPENSTACK_USERNAME}"
          export OS_PROJECT_NAME="${OPENSTACK_PROJECT_NAME:?Set OPENSTACK_PROJECT_NAME}"
          export OS_USER_DOMAIN_NAME="${OPENSTACK_USER_DOMAIN_NAME}"
          export OS_PROJECT_DOMAIN_NAME="${OPENSTACK_PROJECT_DOMAIN_NAME}"
          unset OS_CLOUD OS_TOKEN OS_AUTH_TOKEN
          export TF_IN_AUTOMATION=1 TF_INPUT=0

          cd "${OPENSTACK_TEST_DIR}"
          exec 8>.ci.lock
          flock -n 8
          [[ -r noble-qemu-okestro2018.qcow2 && -s noble-qemu-okestro2018.qcow2 ]] || {
            echo 'Prepare a readable, non-empty noble-qemu-okestro2018.qcow2 in OPENSTACK_TEST_DIR.' >&2
            exit 1
          }
          tofu init -input=false -no-color
          tofu fmt -check
          tofu validate -no-color

          if [[ -f terraform.tfstate ]]; then
            managed="$(tofu state list)"
            if grep -qv '^data\.' <<< "${managed}" && [[ -n "${managed}" ]]; then
              echo 'Previous OpenStack test resources remain; inspect their State first.' >&2
              exit 1
            fi
          fi

          cleanup() {
            result=$?
            trap - EXIT
            set +e
            echo 'Clean OpenStack test resources'
            tofu destroy -auto-approve -input=false -no-color
            cleanup_result=$?
            rm -f -- smoke.tfplan
            if (( cleanup_result != 0 )); then
              echo 'OpenStack cleanup failed; keep State for investigation.' >&2
              if (( result == 0 )); then result=1; fi
            fi
            if (( result != 0 )); then rm -f -- "${job_dir}/test-passed.sha256"; fi
            exit "${result}"
          }
          trap cleanup EXIT
          trap 'exit 130' INT
          trap 'exit 143' TERM

          tofu plan -input=false -no-color -out=smoke.tfplan
          tofu apply -input=false -no-color smoke.tfplan
          tofu output -json smoke_result | jq -e \
            '.image_status == "active" and .power_state == "active"
             and (.network_ids | length) == 2
             and (.volume_id == .attached_volume_id)'

          sha="$(yaml_value "${job_dir}/staging-info.yaml" bundle_sha256)"
          [[ "${sha}" =~ ^[0-9a-f]{64}$ ]]
          printf '%s\n' "${sha}" > "${job_dir}/test-passed.sha256"
```

`trap ... EXIT`는 이 셸이 끝날 때 정리 함수를 실행하도록 등록하는 문법이다. plan·apply·결과 확인이 실패해도 OpenStack 시험 자원 삭제를 시도한다. 정리가 성공했다고 원래 시험 실패를 성공으로 바꾸지 않는다.

미리 준비한 QCOW2가 없거나 Runner 계정이 읽을 수 없으면 자원 생성 전에 중단한다. 정리할 때 Glance에 등록한 시험 이미지는 destroy 대상에 포함하지만, **Runner에 준비한 원본 QCOW2는 삭제하지 않는다.** 다음 시험에서도 같은 파일을 재사용한다.

반대로 시험 성공 후 정리가 실패해도 Step을 실패시키고 합격 파일을 지운다. **이 Step 전체가 성공하지 않으면 다음 승격 Step은 실행되지 않는다.** 승격에 `if: always()`나 `continue-on-error`를 추가하지 않는다.

이전 State의 자원이 남아 있으면 새 시험을 시작하기 전에 중단한다. 이 확인보다 먼저 destroy용 trap을 등록하면 이전 시험 자원까지 지울 수 있으므로 위치를 유지한다.

</details>

기존 `Promote tested bundle`의 해시 비교와 `publish-bundle.sh` 호출은 그대로 둔다. 바뀐 것은 `test-passed.sha256`이 **Ansible 완료가 아니라 OpenStack 시험 성공을 의미한다는 점**이다.

</div>

---

## 6. 성공·실패 모두 VMware 시험 VM 삭제

OpenStack 시험 자원은 클러스터가 살아 있을 때 먼저 정리한다. 그 뒤 승격 성공·실패와 관계없이 VMware VM을 제거한다. OpenTofu의 `destroy`는 해당 프로젝트의 State에 연결된 자원을 대상으로 하므로 전용 State를 유지해야 한다. [destroy 명령](https://opentofu.org/docs/v1.10/cli/commands/destroy/)

!!! warning "삭제 범위"
    아래 Step은 이번 시험 VM 내부의 OpenStack·Private Nexus·TAR·로컬 로그까지 제거한다. 운영 VM이나 수동 시험 자원이 같은 State에 있으면 안 된다. Actions 로그를 남긴 뒤 삭제하며, VM 안에만 저장한 파일은 삭제 후 볼 수 없다.

기존 승격 Step 뒤, staging 정리 Step 앞에 아래 Step을 추가한다.

<details class="analysis-toggle" markdown="1">
<summary>Clean test VMs — 기존 시험 입력을 다시 읽어 destroy</summary>

```yaml title="publish-manifest.yaml — 새 정리 Step"
      - name: Clean test VMs
        if: always()
        shell: bash
        run: |
          set -euo pipefail
          umask 077
          [[ -f vm-cleanup.enabled ]] || exit 0
          source /etc/gitea-runner-env/bundle-pipeline.env
          source "${BUNDLE_BUILDER_DIR}/common.sh"
          : "${TOFU_PROJECT_DIR:?Set TOFU_PROJECT_DIR}"
          : "${TOFU_SSH_PRIVATE_KEY:?Set TOFU_SSH_PRIVATE_KEY}"

          path="$(yaml_value staging-info.yaml bundle_path)"
          sha="$(yaml_value staging-info.yaml bundle_sha256)"
          [[ "${sha}" =~ ^[0-9a-f]{64}$ ]]
          export TF_VAR_bundle_url="${NEXUS_URL%/}/repository/${STAGING_REPOSITORY}/${path}"
          export TF_VAR_bundle_sha256="${sha}"
          export TF_VAR_ssh_private_key_path="${TOFU_SSH_PRIVATE_KEY}"
          export TF_IN_AUTOMATION=1 TF_INPUT=0

          cd "${TOFU_PROJECT_DIR}"
          exec 9>.ci.lock
          flock -n 9
          trap 'rm -f -- deploy.tfplan vm-info.json' EXIT
          tofu destroy -auto-approve -input=false -no-color
```

`VSPHERE_*`와 `TF_VAR_nexus_*`는 4절에서 Job 환경변수로 옮겼으므로 이 Step에서도 사용할 수 있다. `bundle_url`·해시·SSH 키 경로는 같은 후보의 값을 다시 전달한다. destroy도 설정을 읽으므로 입력 변수 선언이 사라지는 것은 아니다.

destroy 과정에서 생성용 `remote-exec`가 다시 실행되지는 않는다. 별도의 destroy-time Provisioner를 추가한 경우는 구분해야 한다. [Provisioner 실행 시점](https://opentofu.org/docs/v1.10/language/resources/provisioners/syntax/)

</details>

마지막의 기존 `Clean staging candidate`도 `if: always()`를 유지한다. VM 정리 실패 때문에 staging 정리까지 생략되지 않게 한다.

| 상황 | 최종 게시 | 정리 동작 |
| --- | --- | --- |
| VM 생성·Ansible 실패 | 실행 안 함 | 이번 State에 기록된 VMware VM 삭제 시도 |
| OpenStack 자원 생성·결과 확인 실패 | 실행 안 함 | OpenStack 자원 삭제 후 VMware VM 삭제 시도 |
| OpenStack 정리 실패 | 실행 안 함 | 오류를 남기고 VMware VM 삭제는 계속 시도. 두 State 보존 |
| 기능 시험·정리 성공 | 동일 TAR 발행 | 이후 VMware VM·staging 정리 |
| 최종 게시 도중 실패 | 일부 반영 가능 | VMware VM·staging 정리. 기존 게시 스크립트의 실패 지점 확인 |
| 최종 게시 성공, VM 삭제 실패 | 발행 유지 | Job 실패와 삭제 오류 확인. State를 보존하고 정리 재시도 |

자동 정리는 **실패 시에도 삭제를 시도하는 정책**이다. vCenter 장애·Runner 강제 종료·Job 강제 취소까지 삭제 완료를 보장하지는 않는다. timeout에는 설치·기능 시험뿐 아니라 두 프로젝트의 destroy 시간도 포함한다. 실패한 destroy를 `|| true`로 숨기거나 State를 지워 성공처럼 처리하지 않는다.

---

## 7. plan은 지우고 State·Provider 캐시는 유지

plan은 이번 실행의 변경 계획 파일이다. State는 생성한 자원의 관리 기록이고, `.terraform.lock.hcl`은 Provider 버전·체크섬을 고정하는 파일이다. 서로 역할이 다르다. 저장된 plan에는 민감한 입력도 포함될 수 있으므로 재사용하지 않는 파일은 실행 후 정리한다. [저장된 plan의 내용](https://opentofu.org/docs/v1.10/cli/commands/plan/), [State의 역할](https://opentofu.org/docs/v1.10/language/state/)

| 파일·디렉터리 | 처리 |
| --- | --- |
| `deploy.tfplan`, `smoke.tfplan`, 과거 `*.plan` | 작업 완료 후 삭제. 위 Step은 이번 plan을 자동 정리 |
| `vm-info.json` | 필요 없다면 삭제. 위 VM 정리 Step에 포함 |
| Runner의 `noble-qemu-okestro2018.qcow2` | 미리 준비한 원본이므로 유지. 다음 시험에 재사용 |
| `terraform.tfstate`, `.backup` | 자동 삭제하지 않음. destroy 실패 시 반드시 보존 |
| `.terraform/` | Provider 캐시·초기화 정보 유지. 매번 재다운로드하지 않음 |
| `.terraform.lock.hcl` | 유지·버전 관리 |
| `*.tf`, `*.tfvars`, `*.tftpl`, `.ci.lock` | 유지. 잠금 파일도 사용 중에 삭제하지 않음 |

destroy 성공 후 빈 State가 남는 것은 정상이다. 폴더를 비워야 정리가 끝난 것이 아니다. `.terraform.tfstate.lock.info`도 이름에 lock이 있다는 이유로 삭제하지 않는다. 실행 중인 작업과 실제 잠금 상태부터 확인한다.

과거 수동 시험의 `.plan`이 남아 있다면 **실행 중인 Job·수동 OpenTofu 작업이 없는 때** 다음처럼 정리한다. 두 프로젝트의 최상위 파일만 대상으로 하며 하위 디렉터리를 재귀 삭제하지 않는다.

<details class="analysis-toggle" markdown="1">
<summary>예전 plan 파일 목록 확인 후 정리</summary>

Runner 계정으로 실행한다. 통합 설정의 두 경로가 의도한 시험 프로젝트인지 먼저 확인한다.

```bash title="Runner — 삭제 대상 조회"
source /etc/gitea-runner-env/bundle-pipeline.env
printf '%s\n' "${TOFU_PROJECT_DIR:?}" "${OPENSTACK_TEST_DIR:?}"
for dir in "${TOFU_PROJECT_DIR}" "${OPENSTACK_TEST_DIR}"; do
  find "${dir}" -maxdepth 1 -type f \
    \( -name '*.plan' -o -name '*.tfplan' \) -print
done
```

위 목록이 모두 불필요한 과거 plan인지 확인한 뒤 삭제한다. CI와 같은 잠금을 잡아 실행 중인 프로젝트를 건드리지 않는다.

```bash title="Runner — 확인한 과거 plan 삭제"
(
  set -euo pipefail
  exec 9>"${TOFU_PROJECT_DIR}/.ci.lock"
  flock -n 9
  exec 8>"${OPENSTACK_TEST_DIR}/.ci.lock"
  flock -n 8
  for dir in "${TOFU_PROJECT_DIR}" "${OPENSTACK_TEST_DIR}"; do
    find "${dir}" -maxdepth 1 -type f \
      \( -name '*.plan' -o -name '*.tfplan' \) -print -delete
  done
)
```

과거 plan만 지우는 명령이며 실제 클라우드 자원을 제거하지 않는다. VM·인스턴스가 남아 있다면 파일 삭제 대신 해당 프로젝트의 `tofu destroy`로 관리한다.

</details>

---

## 8. Actions에서 확인할 완료 기준

| 확인 위치 | 읽을 내용 |
| --- | --- |
| 기존 VM·Ansible Step | VM 4대 생성, 사전 점검, `ansible-playbook` 정상 종료 |
| `Test OpenStack functions` | 로컬 QCOW2 확인·Glance 등록, NIC 두 개·볼륨 생성, 결과 조건 `true`, OpenStack destroy 정상 종료 |
| `Promote tested bundle` | 시험한 SHA256과 같은 TAR 게시, release·current 처리 |
| `Clean test VMs` | VMware destroy 정상 종료. 일부 생성 실패도 정리 대상 |
| 마지막 staging 정리 | 이번 후보 TAR와 체크섬만 삭제 |

처음 연결할 때는 다음 세 경우를 구분해 확인한다.

1. **정상 실행:** 기능 시험 통과 후 최종 게시, OpenStack 자원·VM 삭제, 이번 plan 파일 없음.
2. **의도적인 시험 실패:** 없는 물리망 이름 등 잘못된 시험 설정으로 기능 시험을 실패시켰을 때 승격이 생략되고, VMware VM은 정리되는지 확인. 로컬 QCOW2가 없어 시작하지 못한 경우도 승격하지 않음.
3. **정리 실패:** 권한·API 오류가 Job 실패로 보이고 State가 보존되는지 확인. 이 경우 다음 실행을 강행하지 않고 남은 자원부터 처리.

Actions에서 보이는 stdout·stderr를 기본 조사 자료로 사용한다. `TF_LOG=DEBUG`, 인증 환경변수 전체 출력, State·plan 전체 덤프는 기본 로그에 추가하지 않는다. VM 안의 상세 로그가 필요하면 **destroy 이전**에 필요한 비밀 제거된 부분을 별도로 수집한다.

OpenStack 시험 자원 정리에 실패한 채 VMware VM을 삭제하면 해당 OpenStack API도 사라진다. 보존된 OpenStack State는 실패 기록으로 남지만, 없어진 API에 destroy를 다시 호출해 정리할 수는 없다. 다음 새 클러스터에 옛 State를 그대로 적용하지 않고 실패 기록과 새 시험의 State를 분리한다.

---

## 9. 참고 자료

- [다음: OpenTofu 입문 가이드 - 7 — PR 승인·시험 생략·릴리스 운영](2026-10-21-opentofu-release-operation.md)
- [이전: OpenTofu 입문 가이드 - 5 — staging 시험 후 release 승격](2026-10-15-opentofu-staging-release.md)
- [OpenTofu 입문 가이드 - 4 — Runner와 인증·State 경로](2026-10-14-opentofu-gitea-runner.md)
- [OpenStack Provider 1.53.0 — 환경변수 인증](https://github.com/terraform-provider-openstack/terraform-provider-openstack/blob/v1.53.0/docs/index.md)
- [Glance 이미지 — local_file_path](https://github.com/terraform-provider-openstack/terraform-provider-openstack/blob/v1.53.0/docs/resources/images_image_v2.md)
- [Neutron 네트워크 — value_specs](https://github.com/terraform-provider-openstack/terraform-provider-openstack/blob/v1.53.0/docs/resources/networking_network_v2.md)
- [OpenStack 인스턴스·볼륨 부팅](https://github.com/terraform-provider-openstack/terraform-provider-openstack/blob/v1.53.0/docs/resources/compute_instance_v2.md)
- [OpenStack 볼륨 연결](https://github.com/terraform-provider-openstack/terraform-provider-openstack/blob/v1.53.0/docs/resources/compute_volume_attach_v2.md)
- [OpenTofu destroy](https://opentofu.org/docs/v1.10/cli/commands/destroy/) · [State](https://opentofu.org/docs/v1.10/language/state/)
- [Gitea Actions 호환 범위](https://docs.gitea.com/usage/actions/comparison/)
