---
title: "OpenTofu VMware 가이드 — vCenter와 Rocky Linux 9.6 템플릿으로 VM 생성하기"
summary: "vCenter의 접속 주소·인벤토리·권한을 확인하고, Rocky 템플릿을 복제해 고정 IP를 가진 VM을 만드는 절차. 여러 VM 생성, 변경과 삭제까지."
summary_style: editorial
date: 2026-10-08
category: 구축설계
tags:
  - 가이드
  - OpenTofu
  - VMware
  - Linux
---

<section class="editorial-summary editorial-summary--text-only" aria-labelledby="editorial-summary-title">
  <div class="editorial-summary-layout">
    <div class="editorial-summary-copy">
      <span class="editorial-summary-label">이 가이드의 흐름</span>
      <h2 id="editorial-summary-title" class="editorial-summary-title">vCenter에 복제를 요청하고, VMware Tools로 VM 내부 설정을 마무리한다.</h2>
      <p>OpenTofu 실행 서버는 vCenter API에 연결한다. vCenter가 ESXi·datastore·네트워크를 사용해 템플릿을 복제하고, 게스트 커스터마이징이 Rocky의 호스트명과 IP를 설정한다. 접속 경로와 설정 경로를 구분해 VM 한 대부터 시작한다.</p>
    </div>
  </div>
  <p class="editorial-summary-result"><span><strong>환경 확인 → 템플릿 준비 → 코드 작성 → 생성·접속 → 추가·삭제</strong> 순서로 따라간다.</span></p>
</section>

[OpenTofu 입문 가이드](2026-10-08-opentofu-basics.md)를 먼저 읽으면 Provider·State·plan의 역할을 이해하기 쉽다. 이 글은 **vCenter가 관리하는 vSphere 환경, Rocky Linux 9.6 일반 VM 템플릿, 고정 IPv4**를 기준으로 한다. vSphere Client의 메뉴 이름은 버전·언어에 따라 조금 다르다.

## 1. 어떤 서버에 무엇을 요청하는가

[![OpenTofu 실행 서버에서 vCenter, ESXi, Rocky 게스트로 이어지는 요청 관계](../assets/opentofu-vsphere/vcenter-flow.svg)](../assets/opentofu-vsphere/vcenter-flow.svg)

| 구성 요소 | 담당하는 일 | 예제에서 넣는 값 |
| --- | --- | --- |
| OpenTofu 실행 서버 | 설정을 읽고 Provider를 실행 | 관리용 Linux 서버 또는 Runner |
| vCenter | 인벤토리 조회, 복제·전원·커스터마이징 요청 처리 | `vcenter.example.com` |
| ESXi | VM의 CPU·메모리·가상 장치 실행 | Cluster에서 배치되는 호스트 |
| Datastore | VM 디스크와 설정 파일 저장 | `lab-datastore` |
| Port group | VM의 가상 NIC 연결 | `lab-management` |
| VMware Tools | 게스트 정보 보고와 초기 설정 처리 | Rocky의 `vmtoolsd` |

**접속 대상은 vCenter다.** Provider의 `vsphere_server`에는 ESXi IP나 게스트 VM IP가 아니라 vCenter의 FQDN 또는 IP를 넣는다. 템플릿 clone은 vCenter가 필요하며, 직접 ESXi 연결에서는 지원하지 않는다. [Provider 연결 설정](https://github.com/vmware/terraform-provider-vsphere/blob/v2.17.1/docs/index.md), [VM clone 조건](https://github.com/vmware/terraform-provider-vsphere/blob/v2.17.1/docs/resources/virtual_machine.md)

처리 순서는 다음과 같다.

1. Provider가 HTTPS로 vCenter에 로그인한다.
2. Datacenter·Cluster·Datastore·Port group·템플릿을 이름으로 조회해 ID를 얻는다.
3. 템플릿 UUID와 배치·사양을 포함한 복제 요청을 보낸다.
4. vCenter가 작업을 실행하고 VM을 부팅한다.
5. 게스트 커스터마이징이 VMware Tools를 통해 호스트명·IP 등을 적용한다.
6. Provider가 완료 상태와 게스트 네트워크 정보를 기다리고 State·output을 기록한다.

Provider가 가상화 관리 API를 호출하는 것과 Ansible이 SSH로 게스트에 접속하는 것은 다른 연결이다. vCenter에 접속할 수 있어도 새 VM의 네트워크에 경로가 없으면 SSH·Ansible은 실패한다.

## 2. vCenter에서 확인할 값

브라우저로 `https://vcenter.example.com/ui/`에 접속한다. 여기서 확인하는 이름을 뒤의 `lab.tfvars`에 넣는다. 예제 이름은 실제 환경의 이름으로 바꿔야 한다.

| 확인 대상 | vSphere Client에서 볼 위치 | 입력값·주의 |
| --- | --- | --- |
| vCenter 주소·버전 | 로그인 주소, vCenter의 Summary·About | FQDN 또는 IP. Provider에는 `/ui/`·`/sdk`를 넣지 않음 |
| Datacenter | Hosts and Clusters의 상위 객체 | `Lab-DC` |
| Cluster | Datacenter 아래 ESXi가 모인 객체 | `Lab-Cluster` |
| Resource Pool | Cluster·Host 아래 자원 할당 계층 | 예제는 Cluster의 기본 pool 사용 |
| Datastore | Storage → 대상 datastore | `lab-datastore`, 여유 공간 확인 |
| Port group | Networking → 대상 네트워크 | `lab-management`, VLAN·연결 가능한 ESXi 확인 |
| 원본 템플릿 | VMs and Templates → Templates 폴더 | `Templates/rocky-9.6-base-v1` |
| 생성할 폴더 | VMs and Templates → Lab 폴더 | Datacenter의 VM 루트 기준 `Lab/opentofu` |

**VM 폴더와 datastore 폴더는 다르다.** 여기서 `Lab/opentofu`는 vCenter 인벤토리의 VM 폴더다. datastore 브라우저의 파일 경로를 입력하는 곳이 아니다. 폴더는 미리 만들고 템플릿과 중복되지 않는 이름을 사용한다.

예제는 Cluster가 있는 환경이다. Datacenter 아래 ESXi 하나만 있고 Cluster가 없다면 `vsphere_compute_cluster` 조회를 그대로 사용할 수 없다. 해당 Host의 Resource Pool을 조회하는 코드로 바꿔야 한다. [Cluster data source](https://github.com/vmware/terraform-provider-vsphere/blob/v2.17.1/docs/data-sources/compute_cluster.md)

<details class="analysis-toggle" markdown="1">
<summary>vCenter 연결과 VM 연결을 따로 확인하는 방법</summary>

OpenTofu 실행 서버에서 vCenter 이름 해석과 HTTPS 연결을 확인한다.

```bash
getent hosts vcenter.example.com
curl --connect-timeout 10 -fsS \
  https://vcenter.example.com/sdk/vimServiceVersions.xml
```

`/sdk`는 vSphere Web Services API 경로다. 위 조회는 API 버전 정보를 읽는 연결 확인이며, 로그인 권한이나 VM 생성 권한을 증명하지 않는다. 브라우저 UI가 열린다는 사실만으로 Provider 인증이 확인된 것도 아니다.

내부 CA를 사용한다면 실행 서버의 신뢰 저장소에 CA 인증서를 넣는다. Rocky 계열의 예:

```bash
sudo install -m 0644 lab-root-ca.crt \
  /etc/pki/ca-trust/source/anchors/lab-root-ca.crt
sudo update-ca-trust
```

CA 파일은 환경 관리자가 제공한 인증서를 사용한다. IP로 접속하면 인증서 SAN에 해당 IP가 포함돼야 이름 검증이 통과한다. 예제의 `allow_unverified_ssl` 기본값은 `false`다. 실습에서 검증을 끄는 경우에는 `true`로 명시하지만, 이는 신뢰 문제를 해결하는 설정이 아니라 검증을 생략하는 설정이다.

VM 생성 이후의 연결은 별도로 확인한다.

```bash
ssh labuser@192.0.2.101
```

HTTPS 443은 실행 서버→vCenter, SSH 22는 실행 서버→게스트 VM의 연결이다. 템플릿 다운로드·Provider 설치에는 별도로 인터넷 또는 패키지 미러 접근이 필요하다. [vSphere API](https://developer.broadcom.com/xapis/vsphere-web-services-api/latest/), [Provider 인증·TLS 옵션](https://github.com/vmware/terraform-provider-vsphere/blob/v2.17.1/docs/index.md)

</details>

## 3. 계정과 권한 준비

vCenter API 계정과 Rocky SSH 계정을 구분한다.

| 계정 | 어디에 사용 | 필요한 작업 |
| --- | --- | --- |
| vCenter API 계정 | vSphere Provider | 객체 조회, VM 복제·설정 변경·전원·삭제 |
| `labuser` | Rocky 게스트 | SSH, 이후 Ansible 실행에 필요한 sudo |

전용 API 계정을 만들고 테스트 폴더·템플릿·자원에 권한을 부여한다. vSphere Client의 **Administration → Access Control → Roles**에서 역할을 만들고, 각 객체의 **Permissions**에서 계정·역할·하위 전파를 지정한다.

필요한 권한 범주는 VM clone·customize, inventory 생성·제거, CPU·메모리·디스크 설정, 전원 조작, Resource Pool 할당, Datastore 공간 할당, Network 할당이다. 원본 템플릿을 읽는 권한과 목적지에 만드는 권한이 모두 필요하다. 이벤트 조회, `StorageProfile.View`, `VirtualMachine.Config.SwapPlacement`도 Provider 문서에서 확인할 항목이다. [공식 권한 안내](https://github.com/vmware/terraform-provider-vsphere/blob/v2.17.1/docs/index.md#notes-on-required-privileges)

권한 오류가 나면 대상 객체와 부족한 privilege를 확인해 범위를 보완한다. 전체 vCenter 관리자 권한을 계속 주는 방식보다 실습 자원의 범위를 분명히 해 두는 것이 좋다.

## 4. Rocky Linux 9.6 템플릿 준비

처음에는 **NIC 1개, SCSI OS 디스크 1개**로 단순한 기본 VM을 준비한다. 아래 코드는 이 구조를 가정한다. 추가 디스크·NIC·vTPM이 있는 템플릿은 장치 정의와 복제 조건을 별도로 맞춰야 한다.

<p class="subsection-title"><strong>4-1. 게스트 안에서 준비할 것</strong></p>

<div class="section-body" markdown="1">

템플릿으로 바꿀 원본 Rocky VM에서 실행한다.

```bash
cat /etc/rocky-release
sudo dnf install -y open-vm-tools perl openssh-server
sudo systemctl enable --now vmtoolsd sshd
rpm -q open-vm-tools perl
systemctl is-active vmtoolsd sshd
```

VMware Tools는 IP 정보와 게스트 상태를 보고하며 커스터마이징을 처리한다. 실행 서버에서 Rocky의 IP를 바꾸는 SSH 스크립트를 따로 보내는 방식과 구분된다. [open-vm-tools 역할](https://github.com/vmware/open-vm-tools/blob/master/README.md)

추가 준비 항목:

- `labuser`와 SSH 공개키, 필요한 sudo 정책 준비. 비밀번호·개인키를 템플릿에 공통으로 복제하지 않음.
- SSH가 사용하는 firewalld zone에서 접속 허용 여부 확인.
- OS 디스크·LVM 구성 확인. 가상 디스크 확장과 OS 파일시스템 확장은 별도 작업.
- NetworkManager 연결 프로필과 cloud-init 사용 여부 확인. IP를 바꾸는 주체를 중복 운영하지 않음.
- Nexus 이미지·대형 캐시·기존 클러스터 설정을 기본 템플릿에 넣지 않고 역할별 설치 과정에서 배치.

```bash
nmcli device status
nmcli connection show
systemctl is-active NetworkManager
rpm -q cloud-init
lsblk -f
sudo firewall-cmd --get-active-zones
```

cloud-init이 설치돼 있으면 VMware 커스터마이징과 어느 방식으로 초기화할지 먼저 정한다. 이 예제는 VMware Tools 기반의 일반 게스트 커스터마이징을 사용한다. cloud-init도 동일한 네트워크를 다시 설정하도록 남겨 두지 않는다.

</div>

<p class="subsection-title"><strong>4-2. Rocky 게스트 커스터마이징</strong></p>

<div class="section-body" markdown="1">

VM이 부팅되는 것과 게스트 커스터마이징 지원 여부는 별개다. vCenter·ESXi·VMware Tools 버전에 맞는 게스트 OS 지원 범위를 확인해야 한다.

Rocky가 커스터마이징 단계에서 미지원 배포판으로 인식되는 경우, Broadcom은 호환 배포판의 커스터마이징 방법을 지정하는 방식을 안내한다. **vCenter 8.0 U3 이상**에 제공되는 방법 중 RHEL 9 계열은 `GOSC_METHOD_8`이다. 아래 설정은 해당 조건에서 호환 방법을 명시할 때 사용하는 내용이다. [Broadcom 공식 안내](https://knowledge.broadcom.com/external/article/313164/configure-a-guest-customization-method-f.html)

원본 VM의 `/etc/vmware-tools/customization.conf`에 기존 설정을 확인하고 다음 섹션을 반영한다.

```ini title="/etc/vmware-tools/customization.conf"
[GOSC]
COMPATIBILITY=GOSC_METHOD_8
```

vCenter 8.0 U3보다 오래된 환경에 이 설정만 넣어 지원되는 것으로 간주하면 안 된다. vCenter 버전별 지원 조건을 먼저 확인한다.

템플릿 확정 전에 수동으로 한 대를 복제해 IP·호스트명 변경과 SSH 접속을 확인하면, 템플릿 문제와 OpenTofu 코드 문제를 분리하기 쉽다.

</div>

<p class="subsection-title"><strong>4-3. vCenter에서 템플릿으로 전환</strong></p>

<div class="section-body" markdown="1">

1. VM 설정에서 OS 종류·BIOS/EFI·SCSI Controller·NIC를 확인한다. 학습 예제는 vTPM 없는 기본 VM을 사용한다.
2. vSphere Client Summary에서 VMware Tools 실행 상태와 게스트 IP를 확인한다.
3. 복제 시 서로 달라야 할 machine-id·SSH 호스트키 등의 초기화 방식을 준비한다. 공통 사용자 공개키와 SSH 호스트키는 다르다.
4. ISO 연결과 불필요한 파일을 정리하고 원본 VM을 정상 종료한다.
5. VM 우클릭 → **Template → Convert to Template**으로 전환한다.
6. VMs and Templates에서 `Templates/rocky-9.6-base-v1` 같은 경로로 보관한다.

machine-id와 SSH 호스트키를 지우기만 하고 복제 후 재생성을 준비하지 않으면 서비스가 정상 기동하지 않을 수 있다. 자동 재생성·초기화는 사용하는 OS 이미지 절차에 맞추고, 복제본 간 값이 달라지는지 확인한다.

템플릿은 덮어쓰기보다 `base-v1`, `base-v2`처럼 변경 내용을 구분해 관리하면 복제 기준을 추적하기 쉽다.

</div>

## 5. 프로젝트 파일 작성

OpenTofu 실행 서버에서 실습 디렉터리를 만든다.

```bash
mkdir -p ~/opentofu-learning/vmware-lab
cd ~/opentofu-learning/vmware-lab
```

아래 여섯 파일을 같은 디렉터리에 작성한다. 예제는 vSphere Provider **2.17.1**로 고정한다. 이 버전의 공식 문서는 vSphere 8.x·9.x 지원을 안내한다. 기존 vCenter가 그보다 오래됐다면 해당 환경을 지원하는 Provider 문서를 기준으로 버전을 선택한다. [Provider 릴리스](https://github.com/vmware/terraform-provider-vsphere/releases/tag/v2.17.1)

**versions.tf — 실행 파일과 Provider의 버전**

```hcl title="versions.tf"
terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    vsphere = {
      source  = "vmware/vsphere"
      version = "= 2.17.1"
    }
  }
}
```

**providers.tf — 접속할 vCenter**

계정과 비밀번호는 뒤에서 `VSPHERE_USER`, `VSPHERE_PASSWORD` 환경변수로 전달한다. HCL 파일에 비밀번호를 넣지 않는다.

```hcl title="providers.tf"
provider "vsphere" {
  vsphere_server       = var.vcenter_server
  allow_unverified_ssl = var.allow_unverified_ssl
}
```

**variables.tf — 사용할 입력값**

VM 목록은 이름을 key로 갖는 map이다. VM을 몇 대 만들지는 이 목록의 항목 수로 결정한다.

```hcl title="variables.tf"
variable "vcenter_server" {
  type = string
}

variable "allow_unverified_ssl" {
  type    = bool
  default = false
}

variable "datacenter_name" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "datastore_name" {
  type = string
}

variable "network_name" {
  type = string
}

variable "template_path" {
  type = string
}

variable "vm_folder" {
  type = string
}

variable "domain" {
  type = string
}

variable "ipv4_gateway" {
  type = string
}

variable "dns_servers" {
  type = list(string)
}

variable "vms" {
  type = map(object({
    cpus         = number
    memory_mb    = number
    disk_gib     = number
    ipv4_address = string
    ipv4_prefix  = number
    nested_hv    = optional(bool, false)
  }))

  validation {
    condition = (
      length(var.vms) > 0 &&
      length(distinct([for vm in values(var.vms) : vm.ipv4_address])) == length(var.vms)
    )
    error_message = "VM 목록은 비어 있으면 안 되며 IP는 중복할 수 없다."
  }
}
```

**main.tf — 기존 인벤토리 조회와 VM 생성**

`data` 블록은 기존 객체를 읽는다. `resource` 블록만 새 VM을 관리한다.

```hcl title="main.tf"
data "vsphere_datacenter" "dc" {
  name = var.datacenter_name
}

data "vsphere_compute_cluster" "cluster" {
  name          = var.cluster_name
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_datastore" "storage" {
  name          = var.datastore_name
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_network" "management" {
  name          = var.network_name
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_virtual_machine" "template" {
  name          = var.template_path
  datacenter_id = data.vsphere_datacenter.dc.id
}

resource "vsphere_virtual_machine" "vm" {
  for_each = var.vms

  name             = each.key
  folder           = var.vm_folder
  resource_pool_id = data.vsphere_compute_cluster.cluster.resource_pool_id
  datastore_id     = data.vsphere_datastore.storage.id

  num_cpus          = each.value.cpus
  memory            = each.value.memory_mb
  guest_id          = data.vsphere_virtual_machine.template.guest_id
  firmware          = data.vsphere_virtual_machine.template.firmware
  scsi_type         = data.vsphere_virtual_machine.template.scsi_type
  nested_hv_enabled = each.value.nested_hv

  network_interface {
    network_id   = data.vsphere_network.management.id
    adapter_type = data.vsphere_virtual_machine.template.network_interface_types[0]
  }

  disk {
    label            = "disk0"
    size             = each.value.disk_gib
    thin_provisioned = data.vsphere_virtual_machine.template.disks[0].thin_provisioned
    eagerly_scrub    = data.vsphere_virtual_machine.template.disks[0].eagerly_scrub
  }

  clone {
    template_uuid = data.vsphere_virtual_machine.template.id
    linked_clone  = false
    timeout       = 30

    customize {
      timeout = 15

      linux_options {
        host_name = each.key
        domain    = var.domain
      }

      network_interface {
        ipv4_address = each.value.ipv4_address
        ipv4_netmask = each.value.ipv4_prefix
      }

      ipv4_gateway    = var.ipv4_gateway
      dns_server_list = var.dns_servers
    }
  }

  wait_for_guest_net_timeout = 10

  lifecycle {
    precondition {
      condition     = each.value.disk_gib >= data.vsphere_virtual_machine.template.disks[0].size
      error_message = "VM 디스크는 원본 템플릿 디스크보다 작게 만들 수 없다."
    }
  }
}
```

학습 예제에서 중요한 연결은 다음과 같다.

- `template.id`는 템플릿 UUID다. 이름으로 조회해 얻은 값을 clone에 전달한다.
- `cluster.resource_pool_id`로 VM이 사용할 자원 pool을 선택한다.
- VM 바깥 `network_interface`는 **가상 NIC를 Port group에 연결**한다.
- `customize` 안의 `network_interface`는 **Rocky 내부 IP를 설정**한다. 여러 NIC를 쓰면 선언 순서를 맞춰야 한다.
- `firmware`, `guest_id`, `scsi_type`는 템플릿 값을 따른다. EFI 템플릿을 BIOS로 만드는 실수를 피한다.
- `linked_clone = false`는 Full Clone이다. 복제 후 디스크가 원본 snapshot에 의존하지 않도록 시작한다.
- clone·customization·guest network timeout은 서로 다른 대기 단계이며 단위는 분이다.

조회할 템플릿 속성은 [VM data source](https://github.com/vmware/terraform-provider-vsphere/blob/v2.17.1/docs/data-sources/virtual_machine.md), 복제와 커스터마이징 옵션은 [VM resource](https://github.com/vmware/terraform-provider-vsphere/blob/v2.17.1/docs/resources/virtual_machine.md)를 참고한다.

**outputs.tf — 다음 단계에서 사용할 정보**

```hcl title="outputs.tf"
output "vm_info" {
  value = {
    for name, vm in vsphere_virtual_machine.vm : name => {
      id            = vm.id
      configured_ip = var.vms[name].ipv4_address
      reported_ip   = vm.default_ip_address
    }
  }
}
```

`configured_ip`는 입력한 값이고 `reported_ip`는 게스트에서 보고된 값이다. 입력값이 출력됐다는 이유만으로 실제 네트워크 설정이 성공했다고 판단하지 않는다.

**lab.tfvars — 먼저 VM 한 대**

예제의 이름·문서용 IP를 실제 테스트 환경의 값으로 바꾼다. prefix는 `24`처럼 넣는다. `255.255.255.0` 문자열을 넣는 자리가 아니다.

```hcl title="lab.tfvars"
vcenter_server = "vcenter.example.com"

datacenter_name = "Lab-DC"
cluster_name    = "Lab-Cluster"
datastore_name  = "lab-datastore"
network_name    = "lab-management"
template_path   = "Templates/rocky-9.6-base-v1"
vm_folder       = "Lab/opentofu"

domain       = "lab.example.com"
ipv4_gateway = "192.0.2.1"
dns_servers  = ["192.0.2.53"]

vms = {
  deploy-01 = {
    cpus         = 2
    memory_mb    = 4096
    disk_gib     = 40
    ipv4_address = "192.0.2.101"
    ipv4_prefix  = 24
  }
}
```

40GiB 디스크는 템플릿의 원본 디스크가 40GiB 이하일 때 사용할 예다. Nexus·OpenStack 검증에 필요한 디스크와 메모리는 별도로 산정한다.

## 6. 인증과 조회부터 시작

실습 디렉터리에서 계정과 비밀번호를 입력받는다. 입력값을 명령줄에 직접 적어 셸 이력에 남기는 방식은 피한다.

```bash
read -r -p 'vCenter 계정: ' VSPHERE_USER
read -r -s -p 'vCenter 비밀번호: ' VSPHERE_PASSWORD
printf '\n'
export VSPHERE_USER VSPHERE_PASSWORD
```

Provider는 이 환경변수 이름을 지원한다. 새 터미널에서는 다시 전달해야 한다. VM에 접속할 SSH 계정은 여기 넣지 않는다.

```bash
tofu init
tofu fmt
tofu validate
tofu plan -var-file=lab.tfvars -out=create.tfplan
tofu show create.tfplan
```

`init`에서 vSphere Provider와 `.terraform.lock.hcl`이 준비된다. `plan`에서는 실제 vCenter 인증과 data source 조회가 진행된다. 템플릿을 찾지 못하거나 권한이 부족하면 이 단계에서 원인을 확인한다.

plan에서는 VM 1대의 생성, 이름, 폴더, datastore, CPU·메모리·디스크, IP를 확인한다. UUID처럼 실행 뒤 정해질 값은 `known after apply`로 표시될 수 있다.

!!! warning "저장한 계획을 적용하면 추가 질문 없이 실행"
    create.tfplan을 읽고 실습 VM만 생성되는지 확인한 뒤 다음 명령을 실행한다. 기존 VM 삭제·교체가 포함돼 있으면 대상과 원인을 먼저 확인한다.

```bash
tofu apply create.tfplan
tofu output vm_info
tofu state list
```

vSphere Client의 **Recent Tasks**에서 Clone virtual machine, Reconfigure, Power on, Customization 관련 작업을 확인한다. 게스트에 들어가 설정 결과를 확인한다.

```bash
ssh labuser@192.0.2.101
hostnamectl
ip -br address
ip route
systemctl is-active vmtoolsd
```

Provider의 완료 대기는 SSH 서버·Nexus·OpenStack 서비스의 준비 완료까지 보장하지 않는다. 다음 설치 단계에서는 해당 서비스의 준비 여부를 따로 확인한다.

## 7. 여러 VM과 역할별 사양

VM 한 대가 정상 복제된 뒤 `lab.tfvars`의 `vms`에 항목을 추가한다. 아래는 기존 deploy를 유지하고 controller와 compute를 추가하는 예시다.

```hcl title="lab.tfvars — vms 부분 교체"
vms = {
  deploy-01 = {
    cpus         = 2
    memory_mb    = 4096
    disk_gib     = 40
    ipv4_address = "192.0.2.101"
    ipv4_prefix  = 24
  }
  controller-01 = {
    cpus         = 4
    memory_mb    = 8192
    disk_gib     = 60
    ipv4_address = "192.0.2.102"
    ipv4_prefix  = 24
  }
  compute-01 = {
    cpus         = 4
    memory_mb    = 8192
    disk_gib     = 80
    ipv4_address = "192.0.2.103"
    ipv4_prefix  = 24
    nested_hv    = true
  }
}
```

これは役割별 입력을 설명하는 사양이다. OpenStack 전체 기능을 시험할 때는 NIC·디스크·메모리 요구사항을 해당 Ansible 구성에 맞춰 늘린다.

```bash
tofu plan -var-file=lab.tfvars -out=expand.tfplan
tofu show expand.tfplan
tofu apply expand.tfplan
```

`for_each`는 이름을 식별 key로 쓴다. `compute-02`를 추가하면 그 항목이 생성 대상이 된다. 기존 key를 삭제하면 해당 VM은 삭제 대상이고, key를 바꾸면 기존 객체 삭제와 새 객체 생성으로 해석될 수 있다. 단순 이름 변경과 코드 식별자 변경을 혼동하지 않는다. [for_each](https://opentofu.org/docs/language/meta-arguments/for_each/)

Compute VM 안에서 다시 KVM 인스턴스를 실행하려면 중첩 가상화가 필요하다. `nested_hv_enabled`는 가상화 기능을 게스트에 노출하는 설정이며, 물리 CPU·ESXi·VM 구성도 이를 지원해야 한다. 게스트에서 확인한다.

```bash
lscpu | grep -E 'Virtualization|Hypervisor'
grep -Eo 'vmx|svm' /proc/cpuinfo | sort -u
```

CPU 플래그가 보이는 것과 실제 OpenStack 인스턴스 실행 성공은 다르다. KVM 모듈과 Nova 설정까지 이어서 확인한다.

**동시 생성과 IP 할당**

독립적인 리소스는 병렬 실행될 수 있다. 작은 실습 환경에서 복제 부하를 제한하려면 `tofu apply -parallelism=2 expand.tfplan`처럼 실행한다. Runner 동시 작업 1개와 OpenTofu 내부 병렬도는 별개다. [apply 옵션](https://opentofu.org/docs/cli/commands/apply/)

OpenTofu가 IP를 지정한다고 DHCP·IPAM에서 그 IP를 예약해 주지는 않는다. 실제 네트워크에서 예약한 미사용 IP를 넣어야 한다.

<details class="analysis-toggle" markdown="1">
<summary>고정 IP 대신 DHCP를 쓰려면?</summary>

`clone.customize`의 NIC 블록을 비우고 `ipv4_gateway`를 제거한다.

```hcl title="DHCP용 customize NIC 부분"
network_interface {}
```

바깥의 Port group 연결 블록은 유지한다. IP가 정해지는 주체만 DHCP로 바뀌는 것이다. 변수에서 고정 IP를 제거하면 `vms` 타입·중복 IP 검증·`configured_ip` output도 함께 변경해야 한다. 뒤의 Ansible에는 VMware Tools에서 보고한 주소나 별도 DHCP 조회 결과를 전달한다.

DHCP 서버가 없는 네트워크에서는 이 방식만으로 주소가 생기지 않는다. [커스터마이징 네트워크 옵션](https://github.com/vmware/terraform-provider-vsphere/blob/v2.17.1/docs/resources/virtual_machine.md#network-interface-settings)

</details>

## 8. 변경·실패·삭제

**같은 설정을 다시 실행**

```bash
tofu plan -var-file=lab.tfvars
```

변경이 없다면 계획에도 추가 작업이 없어야 한다. CPU·메모리·디스크·커스터마이징 값을 바꿨을 때는 재구성인지 VM 교체인지 확인한다. 가상 디스크를 늘려도 Rocky의 partition·LVM·파일시스템 확장은 따로 필요할 수 있다.

**중간에 실패**

실행 실패가 “VM이 하나도 만들어지지 않았다”는 뜻은 아니다. State와 vCenter Recent Tasks를 함께 확인한다.

```bash
tofu state list
tofu plan -var-file=lab.tfvars
```

State에 VM이 연결돼 있으면 오류를 해결하고 새 계획으로 진행한다. vCenter에만 남은 객체는 기존 State 복구·import·실습 VM 정리 중 적절한 방법을 선택한다. 이름이 겹친다고 무작정 State 파일을 지우고 다시 만들지 않는다.

**실습 VM 삭제**

아래 계획은 **현재 State가 관리하는 VM**을 삭제한다. source 템플릿과 data source로 조회한 Cluster·Datastore·Port group은 삭제 대상이 아니다. 삭제된 게스트의 디스크와 데이터는 백업이 없으면 복구할 수 없다.

```bash
tofu state list
tofu plan -destroy -var-file=lab.tfvars -out=destroy.tfplan
tofu show destroy.tfplan
```

지워질 VM을 확인한 뒤 적용한다.

```bash
tofu apply destroy.tfplan
tofu state list
unset VSPHERE_USER VSPHERE_PASSWORD
```

계정·환경값·State는 삭제에도 필요하다. 생성 직후 작업 디렉터리와 State를 지우면 나중에 자동 정리가 어려워진다. [OpenTofu destroy](https://opentofu.org/docs/cli/commands/destroy/)

## 9. 자주 막히는 지점

| 증상 | 먼저 구분할 것 | 확인 위치 |
| --- | --- | --- |
| x509 인증서 오류 | CA 신뢰·SAN·접속 주소 | 실행 서버의 curl, Provider TLS 설정 |
| 로그인 실패 | vCenter API 계정과 SSO 도메인 | 같은 계정의 vSphere Client 로그인 |
| Datacenter·Cluster 조회 실패 | 실제 이름·조회 권한 | Hosts and Clusters |
| 템플릿을 찾지 못함 | Datacenter 기준 상대 폴더·이름 | VMs and Templates |
| Permission denied | 원본·목적지·네트워크·스토리지 권한 | 오류 privilege, 각 객체 Permissions |
| 복제는 됐지만 OS 부팅 실패 | EFI/BIOS·컨트롤러·디스크 | VM 콘솔, 템플릿 설정 |
| Customization timeout | Rocky 지원 조건·Tools·Perl·네트워크 초기화 충돌 | vCenter Events, 게스트 Tools 로그 |
| Guest network timeout | 실제 IP·게이트웨이·Tools 보고 | VM 콘솔, Summary, nmcli |
| 디스크 크기 오류 | 원본보다 작은 디스크 또는 다른 장치 구조 | 템플릿 Edit Settings |
| SSH 접속 실패 | 라우팅·방화벽·sshd·계정 공개키 | VM 콘솔과 SSH 상세 로그 |

Rocky 콘솔에서 확인할 명령:

```bash
systemctl status vmtoolsd --no-pager
journalctl -u vmtoolsd -b --no-pager
sudo ls -l /var/log/vmware-imc/
nmcli device status
nmcli connection show
ip -br address
ip route
systemctl status sshd --no-pager
```

`/var/log/vmware-imc/`에는 게스트 커스터마이징 관련 로그가 생성될 수 있다. 해당 디렉터리나 로그가 없는 경우에는 커스터마이징이 시작됐는지부터 vCenter Events와 Tools 상태를 확인한다.

IP 대기 timeout만 늘려서 해결하려고 하지 않는다. NIC 연결 문제, 잘못된 VLAN, 미지원 커스터마이징은 기다리는 시간을 늘려도 바뀌지 않는다.

## 10. Ansible·릴리스 검증으로 연결

VM 생성 이후 결과를 JSON으로 내보내면 다음 단계가 읽기 쉽다.

```bash
tofu output -json vm_info > vm-info.json
```

다음 단계는 이름별 VM IP를 Ansible inventory의 Deploy·Controller·Compute 그룹으로 연결한다. VMware Tools가 보고한 IP와 실제 SSH 연결을 확인한 뒤 설치를 시작한다.

<figure class="flow" aria-label="VM 생성 이후 배포 검증으로 이어지는 흐름">
  <ol><li>OpenTofu VM 생성</li><li>IP·SSH 준비 확인</li><li>Ansible 설치·기능 시험</li><li>로그 수집·VM 삭제</li></ol>
</figure>

릴리스 검증에서는 실행마다 VM 이름·폴더·State를 분리한다. 생성된 Deploy VM이 staging Bundle을 다운로드하고, Private Nexus와 Ansible 컨테이너를 준비한 뒤 나머지 노드를 설치하는 흐름으로 확장할 수 있다.

여기서 OpenTofu가 판단하는 VM 생성 성공과 Ansible의 설치 성공, OpenStack 기능 시험 성공은 각각 다른 결과다. Workflow는 단계별 결과를 받아 다음 단계로 진행하고, 실패해도 해당 실행에서 만든 VM을 정리할 수 있게 State를 유지한다.

## 11. 참고 자료

- [OpenTofu 입문 가이드](2026-10-08-opentofu-basics.md)
- [VMware vSphere Provider 2.17.1](https://github.com/vmware/terraform-provider-vsphere/tree/v2.17.1)
- [Provider 인증·권한·지원 환경](https://github.com/vmware/terraform-provider-vsphere/blob/v2.17.1/docs/index.md)
- [VM 템플릿 조회](https://github.com/vmware/terraform-provider-vsphere/blob/v2.17.1/docs/data-sources/virtual_machine.md)
- [VM 생성·clone·커스터마이징](https://github.com/vmware/terraform-provider-vsphere/blob/v2.17.1/docs/resources/virtual_machine.md)
- [Rocky 등 호환 배포판 커스터마이징 방법](https://knowledge.broadcom.com/external/article/313164/configure-a-guest-customization-method-f.html)
- [VMware open-vm-tools](https://github.com/vmware/open-vm-tools)
