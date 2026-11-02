---
title: "Watcher Epoxy 3편 — Audit 요청부터 VM 이동까지 소스로 따라가기"
summary: "ONESHOT Audit 한 건을 기준으로 API 검증, 비동기 RPC, 전략 실행, Planner, Applier, Nova 호출과 결과 확인을 연결한다."
summary_style: editorial
date: 2026-11-02
category: 개념
tags:
  - OpenStack
  - Observability
---

<section class="editorial-summary editorial-summary--text-only" aria-labelledby="editorial-summary-title">
  <div class="editorial-summary-layout">
    <div class="editorial-summary-copy">
      <span class="editorial-summary-label">이 흐름의 핵심</span>
      <h2 id="editorial-summary-title" class="editorial-summary-title">분석 요청의 응답, 계획 생성, VM 이동 완료는 서로 다른 시점이다.</h2>
      <p>API는 Audit를 저장하고 비동기 처리를 요청한다. Decision Engine은 모델과 지표로 계획을 만들고, 계획 실행 요청을 받은 Applier가 Nova에 VM 이동을 요청한다. 결과는 각 객체와 실제 VM 상태를 연결해 읽어야 한다.</p>
    </div>
  </div>
  <p class="editorial-summary-result"><span>추적의 출발점은 <strong>Audit UUID → Plan UUID → Action UUID → VM UUID</strong>다. 이 식별자들이 모든 서비스에서 하나의 요청 ID로 자동 통일되는 것은 아니다.</span></p>
</section>

## 1. 이번에 따라갈 요청

[2편](2026-11-02-watcher-epoxy-2-architecture.md)의 객체를 실제 코드 흐름에 연결한다. 조건은 `workload_balancing` 목표, `workload_balance` 전략, ONESHOT Audit, 자동 실행 해제다. 전략이 이동할 VM 한 대를 찾았다고 가정한 대표 경로이며, 실제 실행 로그는 아니다.

```text
클라이언트 → API → Audit 저장 → RPC cast
  → Decision Engine → 모델·지표 → Strategy → Solution
  → Planner → Action Plan·Action 저장

계획 검토 → 실행 요청 → API → RPC cast
  → Applier → TaskFlow → migrate 액션
  → Nova API → Nova의 이동 처리 → 결과 조회·상태 기록
```

두 RPC의 `cast`는 수신 측의 작업 완료를 동기적으로 기다리는 호출이 아니다. 따라서 CLI가 응답했다고 분석이나 migration이 끝났다고 판단하지 않는다. 또한 브로커에는 보통 객체 UUID가 전달되고, 작업의 상세 정보는 Watcher DB에서 다시 읽는다.

## 2. API가 입력을 검증하고 Audit를 저장한다

시작점은 `watcher/api/controllers/v1/audit.py`의 `AuditsController.post()`다. 이 메서드는 요청 권한을 확인하고 입력을 내부 Audit 표현으로 변환한 뒤, 지정 전략의 파라미터 스키마로 값을 검증한다.

스키마는 전략이 받는 입력의 구조다. 예를 들어 `threshold`의 자료형과 기본값, `period` 등의 항목을 정의한다. 파라미터를 전달하면서 어떤 전략을 쓸지 확정할 수 없는 요청에는 검증 제약이 있다. “모든 전략이 동일한 옵션을 받는다”는 가정은 피해야 한다.

입력 검증을 통과하면 `objects.Audit`를 생성해 DB에 저장하고, ONESHOT이면 `DecisionEngineAPI.trigger_audit()`를 호출한다. 이 RPC 어댑터가 `trigger_audit`라는 메서드 이름과 Audit UUID를 비동기로 보낸다.

| 경계 | 이미 처리된 것 | 아직 처리되지 않은 것 |
| --- | --- | --- |
| 입력 검증 완료 | 요청 권한·형식·해당 스키마 검증 | 지표가 실제 존재하는지, 이동 후보가 나오는지 |
| Audit 저장 완료 | 분석 요청의 영속 객체 생성 | 전략 실행·계획 생성 |
| RPC 전송 후 응답 | 비동기 분석 요청 | 수신 서비스의 분석 완료 |

이 차이 때문에 API 응답과 `audit show`로 조회한 상태가 다르게 보일 수 있다. 생성 응답은 반환 시점의 객체 표현이며, 백그라운드 처리는 이후에도 계속된다. [Audit API](https://github.com/openstack/watcher/blob/a5a9464fe7fbff91f723ec1676d7456847879768/watcher/api/controllers/v1/audit.py), [Decision Engine RPC](https://github.com/openstack/watcher/blob/a5a9464fe7fbff91f723ec1676d7456847879768/watcher/decision_engine/rpcapi.py)

## 3. Decision Engine이 Audit를 받아 실행한다

수신 측은 `watcher/decision_engine/messaging/audit_endpoint.py`의 `AuditEndpoint`다. `trigger_audit()`가 실행 작업을 executor에 제출하고, `do_trigger_audit()`가 UUID로 Audit를 다시 읽는다. 종류에 따라 ONESHOT 또는 EVENT handler를 선택한다. CONTINUOUS는 반복 스케줄링 경로가 별도로 있다.

ONESHOT의 기본 실행 뼈대는 `AuditHandler.execute()`다.

| 단계 | 실제 담당 메서드 | 하는 일 |
| --- | --- | --- |
| 사전 처리 | `pre_execute()` | 진행 중 계획 확인, 처리 호스트 기록, Audit를 `ONGOING`으로 변경 |
| 전략 처리 | `do_execute()` | 전략 선택·입력 적용·실행으로 Solution 생성 |
| 사후 처리 | `post_execute()` | Planner 실행, 자동 실행 설정이면 Applier RPC 요청 |
| ONESHOT 완료 | `OneShotAuditHandler.post_execute()` | 정상 경로에서 Audit를 `SUCCEEDED`로 변경 |

기본 사전 처리에는 진행 중인 Action Plan을 확인하는 코드가 있다. `force`가 꺼져 있고 진행 중 계획이 있으면 ONESHOT이 `CANCELLED`로 끝날 수 있다. 이를 곧바로 전략 계산 오류로 분류하면 원인을 잘못 찾을 수 있다.

`force`는 “다른 계획이 진행 중이어도 분석을 강행”하는 설정이다. VM 이동의 모든 제약을 무시하는 옵션이 아니다. 이 글의 예제에는 사용하지 않는다.

소스상 기본 Audit handler는 예외를 잡아 Audit를 `FAILED`로 바꾼다. 따라서 실패 원인은 상태 이름만으로 식별하지 못한다. 같은 Audit UUID를 가진 Decision Engine 로그에서 모델·지표·전략·Planner 중 어디서 예외가 났는지 구분한다. [Audit 수신부](https://github.com/openstack/watcher/blob/a5a9464fe7fbff91f723ec1676d7456847879768/watcher/decision_engine/messaging/audit_endpoint.py), [기본 handler](https://github.com/openstack/watcher/blob/a5a9464fe7fbff91f723ec1676d7456847879768/watcher/decision_engine/audit/base.py), [ONESHOT handler](https://github.com/openstack/watcher/blob/a5a9464fe7fbff91f723ec1676d7456847879768/watcher/decision_engine/audit/oneshot.py)

## 4. 전략을 선택하고 모델·지표로 해법을 만든다

<p class="subsection-title"><strong>4-1. 자동 선택은 전략들의 성능을 평가하는 과정이 아니다</strong></p>

<div class="section-body" markdown="1">

`DefaultStrategyContext`는 Audit의 Goal과 Strategy를 확인하고 선택기를 호출한다. Strategy가 지정돼 있으면 해당 전략을 로드한다. 14.2.0 기본 선택기에서 Strategy를 생략하면 Goal에 연결된 사용 가능한 전략 목록의 첫 항목을 고른다.

모든 후보 전략을 실행해 성능을 비교하거나 클러스터 특성에 가장 알맞은 알고리즘을 학습해 고르는 구현은 아니다. 학습·재현 목적이라면 전략을 명시하고 파라미터도 함께 기록하는 편이 판단을 추적하기 쉽다. [전략 context](https://github.com/openstack/watcher/blob/a5a9464fe7fbff91f723ec1676d7456847879768/watcher/decision_engine/strategy/context/default.py), [기본 선택기](https://github.com/openstack/watcher/blob/a5a9464fe7fbff91f723ec1676d7456847879768/watcher/decision_engine/strategy/selection/default.py)

</div>

<p class="subsection-title"><strong>4-2. 판단에 쓰는 입력과 실제 자원을 구분한다</strong></p>

<div class="section-body" markdown="1">

선택한 전략에는 Audit scope와 입력 파라미터가 적용된다. 전략은 compute 모델에서 노드·VM 상태를 읽고, datasource에서 사용량을 조회한다. `workload_balance`의 CPU 모드는 VM별 CPU 사용률과 vCPU 수로 노드의 workload를 계산한다.

후보를 찾으면 모델 안에서 이동 가능성을 반영하고 `add_action_migrate()`로 Solution에 액션을 추가한다. 이때 `compute_model.migrate_instance()` 같은 이름이 보여도 실제 Nova API 호출로 오해하지 않아야 한다. 모델의 연결 관계를 바꿔 계획 후 상태를 계산하는 단계다.

아래는 Solution에 담길 이동 작업을 설명하는 JSON 예시다. 실제 API 응답이나 완전한 DB 행이 아니다.

```json
{
  "action_type": "migrate",
  "input_parameters": {
    "resource_id": "11111111-1111-4111-8111-111111111111",
    "migration_type": "live",
    "source_node": "compute-a.example.com",
    "destination_node": "compute-b.example.com"
  }
}
```

`resource_id`는 이동할 VM의 UUID다. 출발지와 목적지는 같은 VM의 새·옛 위치를 표현한다. UUID 모양과 호스트 이름은 설명용 값이며 실제 시스템 식별자가 아니다. [전략 본체](https://github.com/openstack/watcher/blob/a5a9464fe7fbff91f723ec1676d7456847879768/watcher/decision_engine/strategy/strategies/workload_balance.py), [액션을 추가하는 공통 메서드](https://github.com/openstack/watcher/blob/a5a9464fe7fbff91f723ec1676d7456847879768/watcher/decision_engine/strategy/strategies/base.py)

</div>

## 5. Planner가 저장할 계획과 액션을 만든다

Audit handler는 Solution의 전략이 지정한 Planner를 로드하고 `schedule()`을 호출한다. 기본 Weight Planner는 다음 순서로 처리한다.

1. Audit와 연결된 Action Plan을 `RECOMMENDED` 상태로 생성한다.
2. Solution의 작업을 Action 객체로 만들고 종류별 weight로 정렬한다.
3. parallelization 설정을 반영해 실행 그래프와 `parents`를 구성한다.
4. 효과 지표와 Action들을 저장한다.

`parents`는 이 액션보다 앞서 처리될 액션 UUID 목록이다. 같은 계획이라고 해서 모든 작업을 동시에 시작하는 것이 아니다.

액션 그래프가 비어 있으면 Weight Planner는 계획을 `SUCCEEDED`로 저장한다. 전략이 “옮길 필요 없음” 또는 “조건을 만족하는 후보 없음”으로 끝난 경우를 판단할 때 중요하다. **빈 계획이 왜 나왔는지는 별도 확인**해야 한다. 데이터 누락 때문에 후보를 찾지 못한 경우까지 정상적인 최적 상태로 해석할 수는 없다. [Planner 구현](https://github.com/openstack/watcher/blob/a5a9464fe7fbff91f723ec1676d7456847879768/watcher/decision_engine/planner/weight.py)

자동 실행이 꺼진 비어 있지 않은 계획이면 여기서 분석 경로가 끝난다. Audit는 성공했고 Plan은 추천 상태일 수 있다. 이것은 서로 모순된 상태가 아니다.

## 6. 실행 요청이 Applier로 넘어간다

계획을 시작하면 API의 Action Plan 처리 경로가 실행 가능 여부를 확인하고 상태를 갱신한 뒤 `ApplierAPI.launch_action_plan()`으로 UUID를 보낸다. 자동 실행을 켜면 Audit handler에서 같은 Applier RPC 진입점을 호출하는 경로가 있다.

수신 측 `TriggerActionPlan`은 executor에 실행 작업을 제출한다. `DefaultActionPlanHandler`가 계획을 DB에서 읽고 `ONGOING`으로 바꾼 뒤 `DefaultApplier`에 전달한다. Applier는 해당 Plan의 Action들을 읽어 Workflow Engine에 넘긴다.

```text
Action Plan 실행 요청
  → ApplierAPI.launch_action_plan()
  → RPC cast
  → TriggerActionPlan.launch_action_plan()
  → DefaultActionPlanHandler.execute()
  → DefaultApplier.execute()
  → DefaultWorkFlowEngine.execute()
```

이 경로의 성공 여부를 API의 빠른 응답시간만으로 판정하지 않는다. 요청 접수와 실행 worker의 작업 완료는 다른 구간이다. [Action Plan API](https://github.com/openstack/watcher/blob/a5a9464fe7fbff91f723ec1676d7456847879768/watcher/api/controllers/v1/action_plan.py), [Applier RPC](https://github.com/openstack/watcher/blob/a5a9464fe7fbff91f723ec1676d7456847879768/watcher/applier/rpcapi.py), [실행 수신부](https://github.com/openstack/watcher/blob/a5a9464fe7fbff91f723ec1676d7456847879768/watcher/applier/messaging/trigger.py), [계획 실행 handler](https://github.com/openstack/watcher/blob/a5a9464fe7fbff91f723ec1676d7456847879768/watcher/applier/action_plan/default.py)

## 7. TaskFlow가 migrate 액션을 실행하고 Nova 결과를 읽는다

Workflow Engine은 저장된 Action의 타입에 맞는 구현을 로드한다. 기본 task 실행 경로에서는 사전 조건 검사와 `execute()`, 사후 조건 검사로 이어진다. `migrate` 액션의 `execute()`는 목적지를 지정해 `migrate()`를 호출하고, live 이동이면 `NovaHelper.live_migrate_instance()`로 이어진다.

Watcher의 역할은 Nova에 요청하고 결과를 확인하는 것이다. 메모리 페이지 전송, 하이퍼바이저 간 migration 등 실제 작업은 Nova와 하위 계층이 담당한다. 목적지를 명시했더라도 Nova 측 검증과 정책은 적용된다.

14.2.0 helper는 Nova 서버 객체의 `live_migrate()`를 호출한 뒤 VM의 호스트·상태 등을 다시 조회한다. 목적지가 명시된 경로에서는 호스트가 목적지로 바뀌었는지와 task 상태를 관찰한다. 호출만 반환됐다고 바로 `True`를 반환하는 구성은 아니다. 다만 이 확인이 애플리케이션 정상성까지 검사하는 것은 아니다.

TaskFlow wrapper는 액션의 `execute()` 결과가 정확히 `True`일 때 성공으로 기록한다. `False`나 `None`은 실패 처리로 이어진다. 따라서 Nova 요청 오류가 helper에서 잡혀 반환값으로 표현되는 경로와 예외가 전파되는 경로를 모두 읽어야 한다.

| 계층 | 확인 대상 |
| --- | --- |
| Action | 개별 이동 작업이 Watcher 기준으로 성공했는가? |
| Action Plan | 포함된 액션 실행이 어떻게 종료됐는가? |
| Nova | VM의 실제 위치·task 상태·migration 상태는 무엇인가? |
| 서비스 관측 | 이동 후 오류율·지연·부하가 원하는 범위인가? |

[Workflow Engine](https://github.com/openstack/watcher/blob/a5a9464fe7fbff91f723ec1676d7456847879768/watcher/applier/workflow_engine/default.py), [Migrate 구현](https://github.com/openstack/watcher/blob/a5a9464fe7fbff91f723ec1676d7456847879768/watcher/applier/actions/migration.py), [Nova helper](https://github.com/openstack/watcher/blob/a5a9464fe7fbff91f723ec1676d7456847879768/watcher/common/nova_helper.py)

!!! warning "실패·원복의 의미"
    TaskFlow의 revert 지원은 외부 자원 전체의 트랜잭션 원복 보장이 아니다. `rollback_when_actionplan_failed` 설정과 액션 구현에 따라 동작이 달라지며, migration의 revert는 출발지로 다시 이동을 요청하는 방식이다. 목적지·출발지 상태가 바뀌면 원복도 실패할 수 있다.

## 8. CLI로 객체 연결을 읽는 방법

아래 명령은 설치된 검증 환경에서 흐름을 이해하기 위한 예시다. 이 글 작성 중 실제 OpenStack에는 실행하지 않았다. CLI 옵션은 `python-watcherclient` 4.8.0 소스와 대조했다. 서버·클라이언트의 API microversion과 정책에 따라 지원되는 필드가 달라질 수 있다.

<p class="subsection-title"><strong>8-1. 이미 설치된 환경에서 조회부터 시작</strong></p>

<div class="section-body" markdown="1">

실행 위치는 Watcher client가 설치되고 적절한 OpenStack 인증·권한이 준비된 관리 단말이다. Goal, Strategy, 파라미터를 먼저 읽는다.

```bash
openstack optimize goal list
openstack optimize strategy list --goal workload_balancing
openstack optimize strategy show workload_balance
openstack optimize strategy state workload_balance
```

`strategy show`는 입력 스키마 등을 읽는 명령이고, `strategy state`는 데이터 소스·지표·모델 요구사항 상태를 조회하는 명령이다. 요구사항 조회 결과가 있더라도 모든 VM의 최신 데이터, 실행 제약, 실제 이동 성공까지 검증한 것은 아니다.

</div>

<p class="subsection-title"><strong>8-2. 단일 분석 요청의 형태</strong></p>

<div class="section-body" markdown="1">

!!! warning "검증용 클러스터에서만 생성"
    다음 명령은 템플릿과 Audit를 DB에 만들고 실제 모델·지표 분석을 요청한다. scope를 생략한 예제라 의도한 좁은 범위로 제한되지 않을 수 있다. 운영 적용 전 별도 테스트 범위를 정해야 한다. 자동 실행 옵션 `--auto-trigger`는 넣지 않는다.

```bash
openstack optimize audittemplate create study-balance workload_balancing \
  --strategy workload_balance

openstack optimize audit create --audit-template study-balance \
  --audit_type ONESHOT \
  -p metrics=instance_cpu_usage \
  -p threshold=70.0 \
  -p period=300
```

`70.0`은 파라미터 연결을 설명하기 위한 예시이며 운영 추천값이 아니다. 생성 응답의 UUID를 다음 조회에 사용한다. 실제 UUID는 환경에서 반환된 값으로 교체한다.

```bash
openstack optimize audit show <AUDIT_UUID>
openstack optimize actionplan list --audit <AUDIT_UUID>
openstack optimize actionplan show <PLAN_UUID>
openstack optimize action list --action-plan <PLAN_UUID> --detail
```

실행 전에는 액션 수, VM UUID, 출발지·목적지, 이동 방식, 의존 관계를 확인한다. 이번 학습 범위는 개념과 처리 흐름이므로 실제 계획 시작 명령을 이어서 실행하는 절차는 포함하지 않는다.

</div>

## 9. 멈춘 지점을 기준으로 조사 범위 좁히기

| 관찰 | 우선 확인할 경계 | 구분할 근거 |
| --- | --- | --- |
| Audit가 계속 `PENDING` | API → RPC → Decision Engine 수신·worker | 서비스 상태, 브로커 연결, Audit UUID 수신 로그 |
| Audit가 `FAILED` | 모델·지표·전략·Planner | 최초 예외 위치와 입력 파라미터 |
| Audit 성공, Plan 추천 상태 | 분석 → 실행 요청 | 자동 실행 여부, 명시적 시작 여부 |
| Plan 성공, 액션 0개 | 전략 → Solution → Planner | 최적화 불필요, 후보 없음, 데이터 누락 구분 |
| Plan `ONGOING` 지속 | Applier → 액션 → 외부 서비스 | 개별 Action 상태, Nova migration·task 상태 |
| 이동 액션 실패 | Watcher helper → Nova 처리 | Nova 오류·정책·목적지 제약과 실제 VM 위치 |
| 이동 성공, 부하가 다시 높음 | 실행 결과 → 지표·효과 판단 | 관측 구간, 지연 데이터, 워크로드 변화 |

이 표는 조사 출발점이다. 예를 들어 `PENDING`이 길다고 브로커 장애가 확정되는 것은 아니다. worker가 바쁘거나 수신 후 실행이 대기 중인 경우도 있어 구간별 근거가 필요하다.

로그를 조회할 때는 Audit UUID만 계속 검색하기보다 Plan과 Action, VM UUID를 차례로 확보한다. Nova에서는 VM UUID, migration 식별자, Nova 요청 ID 등 해당 로그에 실제로 기록된 키를 사용한다. Watcher Audit UUID가 Nova의 모든 로그에 자동 전파된다고 가정하지 않는다.

## 10. 소스를 읽을 때의 최소 순서

전체 저장소를 처음부터 읽을 필요는 없다. 이번 요청 경로와 연결된 파일을 다음 순서로 읽으면 된다.

1. `api/controllers/v1/audit.py`: 요청을 어디서 검증하고 저장하는가?
2. `decision_engine/rpcapi.py`와 `messaging/audit_endpoint.py`: 어느 이름과 UUID로 비동기 작업을 전달하는가?
3. `decision_engine/audit/base.py`·`oneshot.py`: 상태 변경·전략·Planner·자동 실행은 어디서 이어지는가?
4. `strategy/context/default.py`·`selection/default.py`: 전략과 입력을 어떻게 정하는가?
5. `strategy/strategies/workload_balance.py`: 어느 VM·목적지를 고르는가?
6. `planner/weight.py`: 어떤 Plan·Action·부모 관계를 저장하는가?
7. `applier/messaging/trigger.py`·`action_plan/default.py`: 실행 작업을 누가 수신하고 종료 상태를 정하는가?
8. `applier/workflow_engine/default.py`·`actions/migration.py`·`common/nova_helper.py`: 실제 서비스 호출과 성공 판단은 무엇인가?

다음 [4편 — 지표와 전략](2026-11-02-watcher-epoxy-4-metrics-strategies.md)에서는 흐름의 입력을 확대한다. CPU 지표의 단위와 VM 식별자가 틀리면 같은 코드가 정상 실행돼도 판단이 달라질 수 있기 때문이다.

**연재:** [1편 역할](2026-11-02-watcher-epoxy-1-role.md) · [2편 구조·용어](2026-11-02-watcher-epoxy-2-architecture.md) · 3편 요청 흐름 · [4편 데이터·전략](2026-11-02-watcher-epoxy-4-metrics-strategies.md)

## 11. 참고 자료와 확인 범위

- [Epoxy 사용자 가이드](https://docs.openstack.org/watcher/2025.1/user/user-guide.html).
- [CLI 4.8.0 Audit 명령](https://github.com/openstack/python-watcherclient/blob/edbc62c502e0448555548a718ba3fc7af530984b/watcherclient/v1/audit_shell.py), [Action Plan 명령](https://github.com/openstack/python-watcherclient/blob/edbc62c502e0448555548a718ba3fc7af530984b/watcherclient/v1/action_plan_shell.py), [Action 명령](https://github.com/openstack/python-watcherclient/blob/edbc62c502e0448555548a718ba3fc7af530984b/watcherclient/v1/action_shell.py).
- 소스 설명은 Watcher 14.2.0에 고정했다. 실제 서비스에 대한 RPC·API 호출과 VM 이동은 수행하지 않았다.
