---
title: "OpenTofu 입문 가이드 - 3"
summary: "3편: VM 4대를 만들고, 첫 VM이 Nexus에서 TAR를 받아 deploy.sh와 Ansible을 실행한다. TAR에 준비된 inventory와 변수를 그대로 사용한다."
summary_style: editorial
date: 2026-10-12
category: 개념
tags:
  - 가이드
  - Automation
  - OpenStack
---

<section class="editorial-summary editorial-summary--text-only" aria-labelledby="editorial-summary-title">
  <div class="editorial-summary-layout">
    <div class="editorial-summary-copy">
      <span class="editorial-summary-label">이 가이드의 흐름</span>
      <h2 id="editorial-summary-title" class="editorial-summary-title">첫 VM이 TAR를 받고, 그 안의 설정으로 Ansible을 실행한다.</h2>
      <p>Runner에서 OpenTofu로 VM 4대를 만든다. 모두 SSH 준비가 끝나면 첫 VM이 Nexus의 TAR를 다운로드한다. 압축을 풀고 deploy.sh로 Private Nexus와 배포 컨테이너를 띄운 다음, 컨테이너 안에서 Ansible을 실행한다.</p>
    </div>
  </div>
  <p class="editorial-summary-result"><span><strong>VM 4대 → SSH 확인 → 첫 VM에서 다운로드·해제 → deploy.sh → Ansible</strong>. 설정 파일은 TAR에 준비해 두므로 Runner가 따로 전달하지 않는다.</span></p>
</section>

[2편](../design/2026-10-08-opentofu-vsphere-rocky.md)의 템플릿·NIC 5개·고정 IP 구성을 이어서 사용한다. 지금은 **기존 Nexus의 current TAR로 배포를 시험**한다. staging 저장소와 자동 기능 테스트는 이후에 연결한다.

---

## 1. 실행 위치와 순서

[![Runner가 VM 4대의 SSH 준비를 확인하고 첫 VM이 TAR를 받아 Ansible을 실행하는 흐름](../assets/opentofu-ansible/deploy-flow.svg){ .architecture-diagram }](../assets/opentofu-ansible/deploy-flow.svg)

| 위치 | 하는 일 |
| --- | --- |
| Runner | OpenTofu 실행, vCenter에 VM 생성 요청, VM에 SSH로 명령 실행 |
| 사내 Nexus | 배포 시험에 사용할 TAR 제공 |
| 첫 VM `runner01` | TAR 다운로드·해제, `deploy.sh`, Private Nexus·배포 컨테이너 기동 |
| `okestro-os-ansible` 컨테이너 | 준비된 inventory와 main.yml로 Ansible 실행 |
| `runner01`~`runner04` | OpenStack·Ceph 등의 설치 대상 |

`runner01`도 클러스터의 일부다. 앞 3대는 Controller+Compute+Ceph, 마지막 1대는 Compute+Ceph OSD로 구성한다. 노드 역할은 TAR 안의 inventory가 결정한다.

**TAR는 첫 VM이 직접 받는다.** Runner에 먼저 다운로드하거나 VM에 미리 넣어 둘 필요가 없다. Runner에서는 inventory와 main.yml도 준비하지 않는다.

---

## 2. 실행 전에 맞춰 둘 것

- VM 이름은 `runner01`~`runner04`로 고정한다. IP는 팀에서 예약한 고정 IP를 사용한다.
- TAR 안의 `inventory/inventory.ini`와 `inventory/group_vars/all/main.yml`은 이 VM 구성에 맞춰 둔다.
- 컨테이너에서 각 노드로 접속하는 Ansible 인증도 TAR의 배포 구성에 준비한다. Runner의 SSH 키와는 별개다.
- 2편의 `guest-init.sh.tftpl`이 Runner 공개키를 등록하고 `guest-init complete` 로그를 남기는 구성을 사용한다.
- Runner에서 VM으로 SSH 접속이 되고, 첫 VM에서 사내 Nexus에 접근할 수 있어야 한다.
- TAR 해제·Nexus 데이터·컨테이너 이미지가 들어갈 디스크 공간을 확보한다.

템플릿에 아래 명령이 있어야 한다. SSH 원격 실행에서도 스크립트를 전송하므로 `scp`가 필요하다. [SSH 연결과 SCP](https://opentofu.org/docs/v1.10/language/resources/provisioners/connection/#executing-scripts-using-sshscp)

```bash title="Rocky 템플릿 — 명령 준비"
sudo dnf install -y openssh-clients curl tar gzip coreutils
command -v bash scp curl tar base64 timeout
```

!!! note "공개 예제와 실제 IP"
    아래 예제의 첫 VM 관리 IP는 `192.0.2.101`이다. 실제 환경에서는 예약한 IP로 바꾼다. deploy.sh에는 별도 입력값 대신 **runner01의 첫 번째 NIC IP**를 자동으로 전달한다. TAR 안의 설정도 같은 실제 IP를 사용해야 한다.

---

## 3. 기존 프로젝트에 파일 하나 추가

2편의 프로젝트에 **`deployment.tf` 하나만 추가**한다. 다운로드·설치용 `prepare-deploy.sh`나 설정 복사용 폴더는 만들지 않는다.

```text
vmware-opentofu/
├── versions.tf
├── provider.tf
├── variables.tf
├── main.tf
├── outputs.tf
├── lab.auto.tfvars
├── guest-init.sh.tftpl      # 2편: 공개키 등록·provider NIC 준비
└── deployment.tf          # 3편: SSH 확인·TAR 설치·Ansible
```

기존 `lab.tfvars`는 `lab.auto.tfvars`로 이름을 바꿔 사용한다. `.auto.tfvars`는 자동으로 읽으므로 `-var-file`을 매번 붙이지 않아도 된다. 둘을 함께 두지 말고 하나만 사용한다. [변수 파일 자동 로딩](https://opentofu.org/docs/v1.10/language/values/variables/#variable-definitions-tfvars-files)

VM 수가 3대였으면 `vms`에 `runner04`를 추가한다. 2편의 나머지 변수는 유지한다.

```hcl title="lab.auto.tfvars — vms 항목"
vms = {
  runner01 = {
    ipv4_addresses = ["192.0.2.101", "198.51.100.101", "203.0.113.101", "203.0.113.201"]
  }
  runner02 = {
    ipv4_addresses = ["192.0.2.102", "198.51.100.102", "203.0.113.102", "203.0.113.202"]
  }
  runner03 = {
    ipv4_addresses = ["192.0.2.103", "198.51.100.103", "203.0.113.103", "203.0.113.203"]
  }
  runner04 = {
    ipv4_addresses = ["192.0.2.104", "198.51.100.104", "203.0.113.104", "203.0.113.204"]
  }
}
```

첫 IP가 관리망이다. NIC 순서·서브넷·게이트웨이는 2편 구성을 따른다. 다섯 번째 provider NIC에는 IP를 주지 않는다.

<details class="analysis-toggle" open markdown="1">
<summary>deployment.tf 전체 예제</summary>

```hcl title="deployment.tf"
variable "bundle_url" {
  type    = string
  default = "https://nexus.example.com/repository/raw-manifest/channels/current/contrabass-engine-deploy.tar"
}

variable "ssh_private_key_path" {
  type    = string
  default = "/root/.ssh/id_ed25519"
}

variable "nexus_user" {
  type = string
}

variable "nexus_password" {
  type      = string
  sensitive = true
}

locals {
  deploy_ip = var.vms["runner01"].ipv4_addresses[0]
}

# 모든 VM의 SSH 연결과 게스트 초기화 완료를 기다린다.
resource "terraform_data" "ssh_ready" {
  for_each         = var.vms
  triggers_replace = vsphere_virtual_machine.vm[each.key].id

  connection {
    type        = "ssh"
    host        = each.value.ipv4_addresses[0]
    user        = "root"
    private_key = file(var.ssh_private_key_path)
    timeout     = "15m"
  }

  provisioner "remote-exec" {
    inline = [
      "#!/bin/bash",
      "set -euo pipefail",
      "timeout 10m bash -c 'until grep -qx \"guest-init complete\" /var/log/opentofu-guest-init.log 2>/dev/null; do sleep 5; done'",
    ]
  }
}

# 네 VM 모두 준비되면 runner01에서 설치한다.
resource "terraform_data" "deploy" {
  depends_on = [terraform_data.ssh_ready]

  triggers_replace = {
    vm_ids     = [for name in sort(keys(var.vms)) : vsphere_virtual_machine.vm[name].id]
    bundle_url = var.bundle_url
  }

  connection {
    type        = "ssh"
    host        = local.deploy_ip
    user        = "root"
    private_key = file(var.ssh_private_key_path)
    timeout     = "15m"
  }

  # 1. 첫 VM에서 다운로드·해제·컨테이너 기동
  provisioner "remote-exec" {
    inline = [
      "#!/bin/bash",
      "set -euo pipefail",
      "umask 077",
      "mkdir -p /opt/contrabass-test",
      "cd /opt/contrabass-test",
      "nexus_auth=$(printf '%s' '${base64encode("${var.nexus_user}:${var.nexus_password}")}' | base64 -d)",
      "bundle_url=$(printf '%s' '${base64encode(var.bundle_url)}' | base64 -d)",
      "curl -kfsSL --retry 3 --user \"$nexus_auth\" \"$bundle_url\" -o contrabass-engine-deploy.tar",
      "unset nexus_auth",
      "tar -xf contrabass-engine-deploy.tar",
      "cd contrabass-engine-deploy",
      "bash ./deploy.sh '${local.deploy_ip}' --accept-eula",
    ]
  }

  # 2. 컨테이너에 준비된 설정으로 Ansible 실행
  provisioner "remote-exec" {
    inline = [
      "#!/bin/bash",
      "set -euo pipefail",
      "nerdctl exec okestro-os-ansible bash -lc 'cd /root/okestro/okestro-openstack && ansible-playbook -i inventory/inventory.ini main.yml' 2>&1 | tee /var/log/contrabass-ansible.log",
    ]
  }
}
```

</details>

**실행 순서는 파일명이 아니라 참조 관계로 정해진다.** VM ID 참조로 VM 생성 다음에 SSH 확인을 실행하고, `depends_on`으로 네 VM의 확인이 모두 끝난 뒤 설치를 시작한다.

`terraform_data`는 실행 단계를 담는 OpenTofu 기본 리소스다. `remote-exec`는 SSH로 VM에서 명령을 실행한다. 두 설치 블록은 작성 순서대로 실행되며, 실패하면 다음 블록으로 넘어가지 않는다. [terraform_data](https://opentofu.org/docs/v1.10/language/resources/tf-data/), [remote-exec](https://opentofu.org/docs/v1.10/language/resources/provisioners/remote-exec/), [여러 Provisioner의 실행 순서](https://opentofu.org/docs/v1.10/language/resources/provisioners/syntax/#multiple-provisioners)

예제의 `base64encode`는 계정·비밀번호에 따옴표가 있어도 셸에 안전하게 전달하기 위한 처리다. 암호화는 아니다. `sensitive` 비밀번호를 쓰는 첫 설치 블록은 콘솔 출력이 숨겨질 수 있어, Ansible은 별도 블록에서 실행해 로그를 보게 했다. [민감한 값을 사용하는 Provisioner 로그](https://opentofu.org/docs/v1.10/language/resources/provisioners/syntax/#suppressing-provisioner-logs-in-cli-output)

`curl -f`는 HTTP 오류를 실패로 처리하고, `-L`은 current 주소의 리다이렉트를 따라간다. `-k`는 자체 서명 인증서를 사용하는 시험 환경의 인증서 검증을 생략한다. TAR는 `contrabass-engine-deploy/` 아래에 `deploy.sh`와 설치 재료가 들어 있는 구조를 전제로 한다.

!!! warning "설치 명령과 실행 시간"
    `--accept-eula`는 Nexus 사용 약관 동의 옵션이다. 내용을 확인하고 동의한 뒤 실행한다. `connection.timeout`은 SSH 연결 대기 시간이지 Ansible 실행 제한이 아니다. Runner 작업 제한 시간은 전체 배포가 끝날 만큼 확보한다. 셸 명령의 상세 변경 내용은 tofu plan만으로 확인되지 않으므로 전용 테스트 VM에서 실행한다.

---

## 4. Runner에서 실행

프로젝트 디렉터리에서 실행한다. `bundle_url`은 실제 Nexus URL로 바꿔 `lab.auto.tfvars`에 추가한다. 계정·비밀번호는 파일에 넣지 않고 입력한다.

```bash title="Runner — Nexus 다운로드 인증 입력"
umask 077
read -r -p 'Nexus 다운로드 계정: ' TF_VAR_nexus_user
read -r -s -p 'Nexus 다운로드 비밀번호: ' TF_VAR_nexus_password
printf '\n'
export TF_VAR_nexus_user TF_VAR_nexus_password
```

vCenter의 `VSPHERE_USER`, `VSPHERE_PASSWORD`는 2편과 동일하게 설정한다. Gitea Actions에 연결할 때는 Nexus 인증도 Secrets에서 환경변수로 전달한다. 저장된 plan과 State에도 민감한 값이 포함될 수 있으므로 공개 저장소에 올리지 않는다.

```bash title="Runner — 계획 확인 후 배포"
tofu init
tofu fmt
tofu validate
tofu plan -out=deploy.tfplan
tofu show deploy.tfplan
tofu apply deploy.tfplan
```

실제로 첫 VM에서 실행되는 핵심 명령은 다음과 같다. IP는 `local.deploy_ip`에서 전달된다.

```bash title="첫 VM — TAR 해제 이후"
cd /opt/contrabass-test/contrabass-engine-deploy
bash ./deploy.sh 192.0.2.101 --accept-eula

nerdctl exec okestro-os-ansible bash -lc \
  'cd /root/okestro/okestro-openstack && ansible-playbook -i inventory/inventory.ini main.yml'
```

여기까지가 현재 실습이다. **컨테이너가 뜬 이후에도 inventory·main.yml을 복사하거나 덮어쓰지 않는다.** 이미 TAR 안에 준비된 파일을 그대로 읽는다.

---

## 5. 결과 확인과 VM 정리

첫 VM에 접속해 컨테이너와 Ansible 로그를 확인한다.

```bash title="첫 VM — 설치 결과 확인"
nerdctl ps
nerdctl exec okestro-os-ansible true
curl -kfsS https://127.0.0.1:8443/service/rest/v1/status
tail -n 80 /var/log/contrabass-ansible.log
```

Ansible의 `PLAY RECAP`과 실패 여부를 확인한다. 예제의 `pipefail`은 `tee`로 로그를 저장하더라도 Ansible 실패를 성공으로 숨기지 않도록 한다. 서비스가 켜진 것과 OpenStack 기능이 정상인 것은 별도 결과다. 기능 테스트 항목은 배포를 진행하면서 추가한다.

**결과를 확인하고 필요한 로그를 보관한 다음**, Runner에서 테스트 VM을 삭제한다.

```bash title="Runner — 테스트 VM 삭제 계획 확인"
tofu plan -destroy -out=destroy.tfplan
tofu show destroy.tfplan
tofu apply destroy.tfplan

unset TF_VAR_nexus_user TF_VAR_nexus_password
```

삭제 대상은 이 프로젝트의 State에 등록된 리소스다. VM 안의 Nexus 데이터·다운로드한 TAR·로그도 함께 사라지므로 대상을 확인한다. 새 셸에서 삭제 계획을 만들면 앞의 인증 환경변수도 다시 입력한다.

같은 설정으로 `apply`하면 완료된 설치가 매번 반복되지는 않는다. 다만 **current URL이 같고 그 안의 TAR만 바뀌면 OpenTofu가 알아서 감지하지는 않는다.** 새 배포 시험은 이전 결과를 정리하고 새 테스트 VM으로 진행한다. 설치가 중간에 실패했다면 로그부터 확인하고, 기존 클러스터에 무작정 재실행하지 않는다.

---

## 6. 다음 단계: staging 검증과 승격

현재 URL은 배포 시험에 쓰는 기존 릴리스 주소다. **staging 저장소는 아직 준비 전**이므로 지금 예제에는 staging 업로드·승격 명령을 넣지 않는다.

```text
태그 push → TAR 빌드 → staging 게시
                         ↓
             VM 4대 생성 → 첫 VM에서 설치
                         ↓
                 배포 확인·기능 테스트
                         ↓
           통과: 시험한 TAR를 최종 저장소에 게시
                 current 포인터 갱신
           실패: 기존 배포 포인터 유지
                         ↓
               로그 수집·staging 정리·VM 삭제
```

나중에는 Runner가 설치·기능 테스트 결과를 받아 **시험한 동일 TAR만** 최종 저장소에 승격한다. 검증 전에는 current 포인터를 바꾸지 않는다. 첫 VM은 설치를 수행하고, 게시·승격은 Runner의 Workflow가 담당하는 구조로 연결한다.

---

## 7. 참고 자료

- [OpenTofu 입문 가이드 - 2](../design/2026-10-08-opentofu-vsphere-rocky.md)
- [terraform_data](https://opentofu.org/docs/v1.10/language/resources/tf-data/)
- [SSH 연결 설정](https://opentofu.org/docs/v1.10/language/resources/provisioners/connection/)
- [remote-exec](https://opentofu.org/docs/v1.10/language/resources/provisioners/remote-exec/)
- [Provisioner 실행·실패 처리](https://opentofu.org/docs/v1.10/language/resources/provisioners/syntax/)
- [입력 변수와 환경변수](https://opentofu.org/docs/v1.10/language/values/variables/)
