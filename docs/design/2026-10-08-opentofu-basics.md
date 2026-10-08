---
title: "OpenTofu 입문 가이드 - 1"
summary: "1편: OpenTofu의 개념과 동작 원리, 설치, 핵심 용어와 State. init·plan·apply·destroy를 익히고 2편의 VMware 실습으로 이어진다."
summary_style: editorial
date: 2026-10-08
category: 개념
tags:
  - 가이드
  - Automation
  - Linux
---

<section class="editorial-summary editorial-summary--text-only" aria-labelledby="editorial-summary-title">
  <div class="editorial-summary-layout">
    <div class="editorial-summary-copy">
      <span class="editorial-summary-label">학습의 출발점</span>
      <h2 id="editorial-summary-title" class="editorial-summary-title">원하는 인프라를 파일에 적고, 바뀔 내용을 확인한 뒤 실행한다.</h2>
      <p>OpenTofu는 설정 파일과 실제 인프라를 비교해 생성·변경·삭제할 작업을 계산한다. Provider는 대상 시스템과 통신하고, State는 코드와 실제 리소스를 연결한다. 이 관계를 이해하면 VM 생성 코드와 실행 결과를 읽기 쉬워진다.</p>
    </div>
  </div>
  <p class="editorial-summary-result"><span>먼저 <strong>설치·파일 구성·기본 명령·State</strong>를 익힌다. 다음 편에서는 Rocky Linux 템플릿을 vCenter에서 복제한다.</span></p>
</section>

이 가이드는 두 편으로 구성한다.

1. **OpenTofu 입문 가이드 - 1 (현재 글):** 개념·설치·핵심 용어와 State.
2. [OpenTofu 입문 가이드 - 2](2026-10-08-opentofu-vsphere-rocky.md): vCenter와 Rocky Linux 9.6 템플릿으로 VM 생성·변경·삭제.

## 1. OpenTofu가 해결하는 일

VM을 수동으로 만들 때는 이름, CPU, 메모리, 디스크, 네트워크를 화면에서 선택한다. 여러 대를 반복 생성하면 설정이 달라지거나 작업 순서를 빠뜨릴 수 있다.

OpenTofu에서는 원하는 구성을 파일로 작성한다. 파일을 Git으로 관리하면 변경 이유와 이력을 남길 수 있고, 같은 코드를 다른 값으로 다시 사용할 수 있다. 이런 방식을 **IaC(Infrastructure as Code), 인프라를 코드로 관리하는 방식**이라고 부른다.

핵심은 명령 순서보다 **최종 상태**다. “VM을 생성하고 메모리를 추가한다”가 아니라 “이 VM의 메모리는 8GiB다”라고 정의한다. OpenTofu가 현재 상태와의 차이를 계산한다. 대상 시스템의 API와 통신하는 부분은 Provider가 맡는다. [OpenTofu 개요](https://opentofu.org/docs/intro/)

| 도구 | 주로 맡는 작업 | VMware 예시 |
| --- | --- | --- |
| OpenTofu | 인프라 리소스의 생성·변경·삭제 | 템플릿 복제, VM 사양과 네트워크 정의 |
| Ansible | OS·프로그램 설정과 배포 | 패키지 설치, 설정 배치, OpenStack 구축 |
| Workflow·Runner | 작업 시작 조건과 실행 순서 | 태그 → VM 생성 → Ansible → 기능 검증 → 정리 |

이 구분은 역할을 나누는 기준이다. Provider와 모듈에 따라 다루는 범위는 달라진다.

## 2. 코드에서 실제 인프라까지

<figure class="flow" aria-label="OpenTofu의 기본 실행 흐름">
  <ol><li>설정 파일 작성</li><li>plan으로 차이 계산</li><li>apply로 API 호출</li><li>State에 결과 기록</li></ol>
</figure>

세 종류의 정보가 함께 필요하다.

| 정보 | 질문에 답하는 내용 |
| --- | --- |
| 설정 파일 | 무엇을 어떤 값으로 만들 것인가? |
| 실제 시스템 | 지금 어떤 리소스가 존재하는가? |
| State | 코드의 어떤 리소스가 실제 시스템의 어느 객체인가? |

예를 들어 코드의 `vsphere_virtual_machine.vm["deploy-01"]`과 vCenter VM의 UUID는 다른 식별자다. State가 둘을 연결한다. VM 이름만 같다고 기존 VM을 자동으로 가져와 관리하는 것은 아니다.

Provider는 OpenTofu와 대상 API 사이에서 요청을 변환하는 플러그인이다. VMware에는 vSphere Provider, OpenStack에는 OpenStack Provider처럼 대상에 맞는 Provider를 선택한다.

**OpenTofu 자체를 각 VM에 설치할 필요는 없다.** 명령을 실행하는 관리 서버나 Runner에 설치한다. VMware 예제에서는 이 실행 서버가 vCenter에 접속하고, vCenter가 VM 생성 작업을 처리한다.

## 3. 처음 만나는 용어

| 용어 | 의미 | 예시 |
| --- | --- | --- |
| HCL | OpenTofu 설정을 작성하는 언어 | `resource`, `variable` 블록 |
| Provider | 대상 시스템 API를 다루는 플러그인 | `vmware/vsphere` |
| Resource | OpenTofu가 생명주기를 관리할 대상 | 새로 만들 VM |
| Data source | 기존 정보를 조회하는 블록 | 기존 datastore·템플릿 조회 |
| Variable | 외부에서 받을 입력값 | VM 이름, CPU, IP |
| Local | 코드 안에서 계산·재사용하는 값 | 이름 접두어 조합 |
| Output | 작업 결과로 내보낼 값 | VM IP 목록 |
| Module | 함께 재사용할 설정 묶음 | VM 생성 모듈 |
| Root module | 명령을 실행하는 현재 설정 디렉터리 | `vmware-lab/` |
| State | 코드와 실제 객체의 연결 기록 | `terraform.tfstate` |
| Backend | State를 저장하는 방식·장소 | 로컬 파일, 원격 저장소 |
| Plan | 앞으로 수행할 변경 계획 | VM 1대 생성 또는 교체 |
| Lock file | 선택한 Provider 버전과 체크섬 기록 | `.terraform.lock.hcl` |

`data`는 기존 객체를 찾아 쓰고, `resource`는 관리할 객체를 선언한다. 기존 템플릿을 `data`로 읽어 복제하면 원본 템플릿을 삭제 대상으로 삼지 않는다. [Data source](https://opentofu.org/docs/language/data-sources/), [Provider 요구사항](https://opentofu.org/docs/language/providers/requirements/)

## 4. Linux에 설치

설치 장소는 **OpenTofu 명령을 실행할 서버**다. 복제될 VM의 OS와 같을 필요는 없다. 실행 서버가 Ubuntu이고 템플릿이 Rocky여도 괜찮다.

먼저 기존 설치와 OS를 확인한다.

```bash
cat /etc/os-release
command -v tofu
```

OpenTofu 공식 설치 스크립트를 파일로 내려받아 내용을 읽은 뒤 실행한다.

```bash
curl --proto '=https' --tlsv1.2 -fsSL \
  https://get.opentofu.org/install-opentofu.sh \
  -o install-opentofu.sh

less install-opentofu.sh
```

아래 중 **실행 서버의 OS에 맞는 명령 하나**를 선택한다. 설치 스크립트가 공식 패키지 저장소와 패키지 설치를 처리하며, 권한이 필요할 때 관리자 권한을 사용한다.

```bash title="Rocky Linux·RHEL 계열"
bash install-opentofu.sh --install-method rpm
```

```bash title="Ubuntu·Debian 계열"
bash install-opentofu.sh --install-method deb
```

설치 확인:

```bash
tofu version
tofu -help
```

`tofu version`은 OpenTofu 실행 파일의 버전을 보여 준다. Provider는 이후 프로젝트에서 `tofu init`으로 설치한다. 설치 명령의 기준은 [공식 RPM 가이드](https://opentofu.org/docs/intro/install/rpm/)와 [Debian 가이드](https://opentofu.org/docs/intro/install/deb/)다.

## 5. 설정 파일과 작업 디렉터리

한 디렉터리의 `.tf` 파일은 함께 읽힌다. `main.tf`라는 이름부터 실행하는 방식이 아니다. 파일을 나누는 이유는 사람이 역할별로 읽기 쉽게 하기 위해서다.

```text
vmware-lab/
├── versions.tf           # OpenTofu·Provider 버전 조건
├── providers.tf          # vCenter 연결 설정
├── variables.tf          # 입력값의 이름·타입·기본값
├── main.tf               # 기존 객체 조회와 VM 정의
├── outputs.tf            # VM 이름·IP 등 출력
├── lab.tfvars            # 실습 환경에서 사용할 입력값
├── .terraform.lock.hcl   # init이 만든 Provider 버전 기록
└── .gitignore
```

`variable "vm_name"`은 입력값의 정의이고, `vm_name = "lab-01"`은 실제 값이다. 정의만 있고 기본값도 없으면 실행 시 값이 필요하다. `lab.tfvars`처럼 이름을 정한 파일은 `-var-file=lab.tfvars`로 지정한다. `terraform.tfvars`와 `*.auto.tfvars`는 자동으로 읽히므로, 여러 환경의 값을 한 디렉터리에 자동 로딩 파일로 섞어 두지 않는다. [입력 변수](https://opentofu.org/docs/language/values/variables/)

## 6. 외부 시스템 없이 기본 흐름 익히기

이 예제는 내장 `terraform_data` 리소스로 입력과 State의 관계를 익힌다. VM이나 파일을 만드는 리소스가 아니며, 외부 Provider 다운로드도 필요 없다. [내장 리소스 설명](https://opentofu.org/docs/language/resources/tf-data/)

```bash
mkdir -p ~/opentofu-learning/basics
cd ~/opentofu-learning/basics
```

현재 디렉터리에 다음 파일을 작성한다.

```hcl title="main.tf"
terraform {
  required_version = ">= 1.10.0, < 2.0.0"
}

variable "lab_name" {
  type        = string
  description = "학습용 이름"
  default     = "first-lab"
}

resource "terraform_data" "lab" {
  input = var.lab_name
}

output "lab_name" {
  value = terraform_data.lab.output
}
```

**초기화와 코드 검사**

```bash
tofu init
tofu fmt
tofu validate
```

- `init`: Backend·Module·Provider를 준비한다. 코드가 들어 있는 디렉터리에서 실행한다.
- `fmt`: 공백과 들여쓰기를 정리한다.
- `validate`: 설정의 문법·타입·참조를 검사한다. vCenter 권한이나 IP 사용 가능 여부를 검사하는 명령은 아니다.

[init](https://opentofu.org/docs/cli/commands/init/), [validate](https://opentofu.org/docs/cli/commands/validate/)

**계획 확인과 적용**

```bash
tofu plan -out=create.tfplan
tofu show create.tfplan
tofu apply create.tfplan
tofu output
tofu state list
```

`plan`은 변경 계획을 만들고, `apply`는 그 계획을 실행한다. 저장한 plan을 apply하면 추가 확인 질문 없이 실행된다. VMware에서는 VM 생성·삭제로 연결되므로 **show에서 대상과 변경 내용을 읽은 뒤 apply**한다. [plan](https://opentofu.org/docs/cli/commands/plan/), [apply](https://opentofu.org/docs/cli/commands/apply/)

이 예제에서는 입력값과 내장 리소스 식별 정보가 State에 저장된다. 같은 설정으로 `tofu plan`을 다시 실행했을 때 변경이 없다면, 설정과 관리 상태가 일치한다는 의미다.

**입력을 바꿔 보기**

```bash
tofu plan -var='lab_name=second-lab' -out=change.tfplan
tofu show change.tfplan
tofu apply change.tfplan
tofu output -raw lab_name
```

명령줄 `-var`는 그 실행에만 전달된다. 다음 실행에서 옵션을 빼면 기본값 `first-lab`을 다시 사용하므로, 계속 사용할 값은 `.tfvars`에 기록하는 편이 낫다.

**실습 State 정리**

```bash
tofu plan -destroy -out=destroy.tfplan
tofu show destroy.tfplan
tofu apply destroy.tfplan
```

이 예제에서는 내장 리소스의 관리 기록이 제거된다. 다음 편의 VM 예제에 같은 명령을 실행하면 실제 VM이 삭제된다. [destroy](https://opentofu.org/docs/cli/commands/destroy/)

## 7. Plan 출력 읽기

| 표시 | 의미 | 먼저 볼 것 |
| --- | --- | --- |
| `+` | 생성 | 이름과 생성 위치 |
| `~` | 기존 객체 수정 | 바뀌는 속성 |
| `-` | 삭제 | 지워질 객체가 맞는지 |
| `-/+` | 기존 객체 삭제 후 재생성 | 중단·데이터 손실 가능성 |
| `(known after apply)` | 실행 후 알 수 있는 값 | UUID·자동 할당 IP 등 |
| `No changes` | 계획상 변경 없음 | 기대한 환경·State를 읽었는지 |

Provider가 어떤 속성을 수정할 수 있는지에 따라 결과가 달라진다. VM 이름을 바꾼다고 항상 새 VM이 생기는 것도 아니고, OS 초기 설정을 바꾼다고 항상 기존 VM 내부만 수정되는 것도 아니다. 변경할 때마다 plan의 **update인지 replace인지** 확인한다.

## 8. State와 Lock file은 서로 다른 기록

| 파일·디렉터리 | 역할 | Git 관리 |
| --- | --- | --- |
| `*.tf` | 인프라 정의 | 포함 |
| 민감정보 없는 예제 tfvars | 환경 입력 예시 | 포함 가능 |
| `.terraform.lock.hcl` | Provider 선택 버전·체크섬 | 포함 |
| `.terraform/` | 내려받은 플러그인·작업 정보 | 제외 |
| `terraform.tfstate*` | 실제 객체와 코드의 연결·백업 | 제외·별도 보관 |
| `*.tfplan` | 실행 계획과 관련 데이터 | 제외·접근 제한 |
| 비밀번호가 담긴 tfvars | 인증정보 | 제외 |

State를 잃으면 어떤 VM을 관리하던 작업인지 추적하기 어려워진다. 작업 디렉터리를 복사할 때도 State를 단순 복제해 동시에 실행하면 안 된다. 한 객체는 한 관리 기록에서 다루는 것이 기본이다. [State](https://opentofu.org/docs/language/state/)

Lock file은 State를 대신하지 않는다. 같은 코드라도 Provider 버전이 달라지면 동작이 달라질 수 있으므로 선택 버전을 고정하는 용도다. `tofu init -upgrade`는 버전 조건 안에서 새 Provider를 선택할 수 있어, 평소 init과 구분해서 사용한다. [Dependency lock file](https://opentofu.org/docs/language/files/dependency-lock/)

```gitignore title=".gitignore — 기본 예시"
.terraform/
*.tfstate
*.tfstate.*
*.tfplan
crash.log
crash.*.log
*.tfvars
!*.tfvars.example
```

`sensitive = true`는 기본 출력에서 값을 숨기는 설정이다. State·plan 암호화나 Git 유출 방지를 자동으로 해결하지 않는다. 환경변수로 비밀번호를 전달해도 시스템의 비밀 관리와 State 보호는 별도로 필요하다. [State의 민감정보](https://opentofu.org/docs/language/state/sensitive-data/)

혼자 하는 첫 실습은 로컬 State로 시작할 수 있다. 팀·Runner에서 반복 실행할 때는 원격 Backend와 해당 Backend의 잠금 기능을 검토한다. VM 정리가 끝나기 전까지 실행별 State를 유지해야 한다. [State 잠금](https://opentofu.org/docs/language/state/locking/)

## 9. 다음 편으로 넘어가기

다음 사항을 설명할 수 있으면 VMware 예제를 읽을 준비가 됐다.

- OpenTofu 설치 장소와 생성할 VM은 서로 다르다.
- Provider는 API 연결, data source는 조회, resource는 관리 대상이다.
- plan은 변경 계획이고 apply는 실행이다.
- 같은 코드라도 입력값·State·Provider 버전이 달라지면 결과가 달라질 수 있다.
- 삭제할 때도 생성 때 사용한 설정·인증·State가 필요하다.

[다음: OpenTofu 입문 가이드 - 2 — VMware VM 생성 실습](2026-10-08-opentofu-vsphere-rocky.md)
