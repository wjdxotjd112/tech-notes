---
title: "Watcher Epoxy 1편 — 무엇을 최적화하고 어디까지 책임질까"
summary: "VM 최초 배치와 운영 중 재배치의 차이에서 출발해 Watcher의 역할, 최적화 목표, Nova·Placement·모니터링과의 관계를 이해한다."
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
      <span class="editorial-summary-label">이 개념의 핵심</span>
      <h2 id="editorial-summary-title" class="editorial-summary-title">운영 중인 클라우드에서 무엇을 옮길지 판단하고 실행 계획을 만든다.</h2>
      <p>VM 생성 당시의 배치가 시간이 지나도 적절하다는 보장은 없다. Watcher는 자원 구성과 사용량을 바탕으로 최적화 전략을 실행하고, 그 결과를 OpenStack 서비스가 수행할 작업으로 연결한다.</p>
    </div>
  </div>
  <p class="editorial-summary-result"><span>먼저 구분할 것은 <strong>목표·판단·계획·실행</strong>이다. 각 단계의 성공이 다음 단계의 성공이나 성능 개선을 보장하지는 않는다.</span></p>
</section>

## 1. 학습 범위와 버전

이 연재는 Watcher를 처음 접한 엔지니어가 구성 요소와 호출 흐름을 이해하기 위한 학습 자료다. 설치·운영 실측 기록은 아니다. OpenStack 2025.1 Epoxy 문서와 해당 계열의 **Watcher 14.2.0 소스**를 대조했다. 소스 기준 커밋은 `a5a9464fe7fbff91f723ec1676d7456847879768`이다. [공식 릴리스 목록](https://releases.openstack.org/epoxy/#watcher)에서 버전과 커밋을 확인할 수 있다.

| 구분 | 기준과 의미 |
| --- | --- |
| OpenStack | 2025.1 Epoxy |
| 대상 OS | Rocky Linux 9.6. 이 글에서 설치 호환성을 시험한 것은 아님 |
| 서버 코드 | Watcher 14.2.0 고정 소스. `latest` 문서와 구분 |
| CLI 설명 | Epoxy 계열 `python-watcherclient` 4.8.0 소스 |
| 학습 순서 | 역할 → 구조·용어 → 요청 처리 → 데이터·전략 |
| 이번 범위 밖 | RPM SPEC 작성, 저장소 구성, 서비스 설치·기동, 운영 VM 이동 |

Epoxy라는 이름만으로 설치할 Watcher 패치 버전과 의존성 조합까지 고정되지는 않는다. 사내 RPM을 설계할 때는 실제 소스 태그와 패치를 별도로 고정해야 한다. 여기서는 패키징 전에 필요한 서비스 이해에 집중한다.

## 2. VM을 이미 배치했는데 왜 다시 판단할까

클라우드의 컴퓨트 노드는 CPU·메모리·디스크를 제공한다. VM은 이 자원 중 일부를 할당받아 동작한다. VM을 생성할 때 적합했던 위치라도 서비스 트래픽, 배치 작업, VM 증감 때문에 부하가 달라질 수 있다.

vCPU는 VM에 제공하는 가상 CPU 단위다. 할당한 vCPU 수와 실제 소비한 CPU 시간은 다른 값이며, VM과 물리 CPU가 언제나 1:1로 전용 연결되는 것도 아니다. 이 차이가 사용량 기반 최적화의 출발점이다.

다음은 역할 설명을 위한 가상 상황이다. 실제 측정값이나 특정 전략의 계산 결과는 아니다.

| 노드 | 같은 시점에 관찰한 상황 | 운영자가 검토할 질문 |
| --- | --- | --- |
| compute-a | VM들의 CPU 부하가 집중됨 | 일부 VM을 옮기면 집중을 줄일 수 있을까? |
| compute-b | 할당 가능한 자원과 부하 여유가 있음 | 이동 대상 VM의 제약도 만족할까? |
| compute-c | 점검 예정 | VM을 다른 노드로 옮길 수 있을까? |

운영자가 수동으로 처리하려면 VM 위치와 사용량을 확인하고, 이동 대상과 목적지를 고른 뒤, 이동 결과를 확인해야 한다. Watcher는 이 중 **분석·계획·작업 실행을 연결하는 틀**을 제공한다.

노드가 잠깐 바빴다는 사실만으로 이동이 정답은 아니다. 이동에는 네트워크와 CPU 비용이 들고, 목적지에서 새로운 자원 경합이 생길 수도 있다. 따라서 어떤 문제를 줄일지와 어떤 비용을 허용할지를 먼저 정해야 한다.

## 3. Nova Scheduler·Placement와의 역할 차이

Nova는 VM의 생명주기와 컴퓨트 작업을 관리한다. Nova Scheduler는 요청의 자원·제약에 맞는 목적지를 선택하는 역할을 맡는다. Placement는 자원 공급자(resource provider)의 인벤토리, 할당, 특성 등을 관리하고 후보 조회에 참여한다. [Nova Epoxy 스케줄링 설명](https://docs.openstack.org/nova/2025.1/reference/scheduling.html), [Placement Epoxy 개요](https://docs.openstack.org/placement/2025.1/)

| 구성 요소 | 주요 질문 | 입력과 결과 |
| --- | --- | --- |
| Nova Scheduler | 이 요청을 어느 호스트가 처리할 수 있을까? | 요청 조건·후보 → 호스트 선택 |
| Placement | 요구 자원을 충족하는 공급자와 할당 상태는 무엇일까? | 인벤토리·할당·특성 → 후보·자원 관리 |
| Watcher | 현재 배치를 어떤 목표에 맞춰 바꿀까? | 클러스터 구성·지표·전략 → 최적화 계획 |
| Nova의 migration 처리 | 요청한 VM 이동을 수행할 수 있을까? | VM·목적지·이동 조건 → 실제 이동 처리 |

Watcher의 판단에는 Nova Scheduler와 다른 목적이 있다. 예를 들어 “VM 한 대를 생성할 수 있는 위치”와 “기존 VM들을 옮겨 부하 편차를 줄이는 방법”은 서로 다른 문제다. 다만 Scheduler가 최초 생성에만 쓰이는 것은 아니다. 이동 등의 Nova 작업에서도 조건에 따라 목적지 선정과 검증에 관여한다.

또한 Placement의 할당량은 실제 CPU 사용률과 다르다. 8 vCPU를 할당받은 VM이 지금 8개 CPU를 모두 바쁘게 사용한다는 뜻은 아니다. 반대로 할당 여유가 있어도 물리 노드의 I/O나 CPU가 혼잡할 수 있다. 최적화에는 **배치 가능한 자원 정보와 실제 부하 정보가 함께** 필요하다.

Watcher가 목적지를 정했더라도 Nova가 최종 실행 요청을 거부할 수 있다. 자원 부족, CPU 호환성, 정책, VM 상태 등 실행 시점의 제약은 계속 유효하다. 이 경계는 [Watcher의 migration 액션](https://github.com/openstack/watcher/blob/a5a9464fe7fbff91f723ec1676d7456847879768/watcher/applier/actions/migration.py)과 [Nova 호출 코드](https://github.com/openstack/watcher/blob/a5a9464fe7fbff91f723ec1676d7456847879768/watcher/common/nova_helper.py)에서 확인할 수 있다.

Migration은 VM의 실행 위치를 옮기는 작업이다. live migration은 실행 중인 VM을 대상으로 하고, cold migration은 정지 과정을 포함할 수 있다. live라는 이름이 애플리케이션 영향 0을 보장하지는 않는다. Watcher 전략의 이동 방식과 Nova·하이퍼바이저의 지원 조건을 함께 확인해야 한다.

## 4. 최적배치라는 말에 들어 있는 여러 목표

Watcher에서 Goal은 최적화의 목적, Strategy는 그 목적을 달성하려는 알고리즘이다. Goal 하나에 여러 Strategy가 연결될 수 있다.

| 목적 | 생각할 수 있는 변화 | 함께 검토할 조건 |
| --- | --- | --- |
| 부하 균형 | 부하가 몰린 노드에서 여유 있는 노드로 VM 이동 | VM별 지표, 목적지 자원, migration 가능 여부 |
| 서버 통합 | VM을 적은 수의 노드에 모아 빈 노드 확보 | 통합 후 여유, 장애 시 수용 능력, 전원 제어 범위 |
| 유지보수 | 점검할 노드의 VM 이동 | 이동 불가 VM, 서비스 중지 범위, 작업 순서 |
| 열·에너지 최적화 | 온도·전력 조건을 고려한 배치 변경 | 해당 지표의 수집 여부와 지원 액션 |

이 표는 목표를 이해하기 위한 분류다. 설치하면 모든 목표가 즉시 동작한다는 의미는 아니다. 전략별로 필요한 지표·모델·액션이 다르고, 설명에 PoC 또는 환경 가정이 명시된 전략도 있다. 실제 이름과 등록 관계는 [14.2.0의 플러그인 목록](https://github.com/openstack/watcher/blob/a5a9464fe7fbff91f723ec1676d7456847879768/setup.cfg)에서 확인한다.

부하 균형과 서버 통합은 방향이 다를 수 있다. VM을 넓게 분산하면 노드 간 부하 편차가 줄어들 수 있지만, 더 많은 노드를 켜 두어야 할 수 있다. 반대로 통합하면 노드당 부하는 높아질 수 있다. “최적”을 이해하려면 무엇을 줄이고 무엇을 유지할지 먼저 읽어야 한다.

!!! tip "최적화 목표를 읽는 기준"
    CPU 사용률이 낮다는 한 가지 사실만으로 좋은 배치라고 판단하지 않는다. 전략이 줄이려는 값, 유지해야 하는 제약, 작업 비용을 함께 본다.

## 5. 관찰에서 실행까지의 큰 흐름

<figure class="flow" aria-label="Watcher 최적화의 큰 처리 순서">
  <ol>
    <li>구성·사용량 확인</li>
    <li>전략으로 판단</li>
    <li>실행 계획 생성</li>
    <li>계획 실행·확인</li>
  </ol>
</figure>

**구성·사용량 확인.** 어떤 노드와 VM이 있고 어디에 연결돼 있는지 모델을 만든다. 사용량은 별도의 데이터 소스에서 조회한다. VM 목록과 CPU 사용률은 같은 데이터가 아니다.

**전략으로 판단.** 목표, 분석 범위, 파라미터를 받아 이동 후보 등의 해법을 만든다. 구현된 전략의 규칙에 따라 판단하므로, Watcher 전체를 하나의 AI 모델이나 전역 최적해 계산기로 이해하면 실제 동작과 어긋난다.

**실행 계획 생성.** 해법의 작업들을 실행 순서와 의존 관계가 있는 Action Plan으로 만든다. 분석 요청인 Audit와 실행 계획은 별도 객체다.

**계획 실행·확인.** Applier가 액션을 수행한다. VM 이동은 Nova API 등의 서비스 호출로 이어진다. 자동 실행을 설정하지 않았다면 계획을 검토하고 명시적으로 시작하는 단계를 둘 수 있다. [Audit 처리 코드](https://github.com/openstack/watcher/blob/a5a9464fe7fbff91f723ec1676d7456847879768/watcher/decision_engine/audit/base.py)

실행 이후의 효과 확인에는 별도의 관측이 필요하다. VM이 이동했다는 사실과 애플리케이션 응답시간이 줄었다는 사실은 다르다. 같은 조건의 지표를 비교해야 효과를 설명할 수 있다.

## 6. 기존 관측 도구는 어디에 연결될까

이미 Prometheus·Thanos와 로그·알림 체계를 운영하더라도 Watcher에 필요한 데이터가 모두 준비됐다고 볼 수는 없다. 서비스의 역할을 나누면 연동 지점을 찾기 쉽다.

| 도구·계층 | 이 연재에서 보는 역할 | Watcher와 연결할 때의 질문 |
| --- | --- | --- |
| Prometheus | 시계열 지표의 수집·조회 | 지원하는 지표 이름·단위·라벨이 있는가? |
| Thanos | 여러 지표 저장소를 조회하는 계층 | Watcher가 사용하는 HTTP API와 식별 정보도 제공되는가? |
| Alertmanager | 알림 전달 경로 | 알림이 자동으로 Audit 생성·실행으로 연결되는가, 별도 연동이 필요한가? |
| Loki 등 로그 체계 | Watcher와 Nova의 장애 근거 조회 | Audit·Plan·VM 식별자로 처리 경로를 찾을 수 있는가? |
| 오브젝트 스토리지 | 관측 시스템 등의 데이터 저장 기반 | 저장 경로와 Watcher 지표 조회 경로를 구분했는가? |

Watcher 14.2.0 기본 데이터 소스 목록에 Loki나 오브젝트 스토리지가 직접 지표 백엔드로 등록돼 있는 것은 아니다. 또한 Alertmanager를 운영한다는 이유만으로 최적화 작업이 자동 실행되지는 않는다. 이벤트 기반 분석은 이벤트 입력과 인증·매핑을 별도로 확인해야 한다. 기본 등록은 [DataSourceManager](https://github.com/openstack/watcher/blob/a5a9464fe7fbff91f723ec1676d7456847879768/watcher/decision_engine/datasources/manager.py), 이벤트 입력의 사례는 [Epoxy Aodh 연동 문서](https://docs.openstack.org/watcher/2025.1/user/event_type_audit.html)를 참고한다.

Prometheus를 쓰는 경우에도 호스트의 node exporter 지표만으로 VM별 CPU 사용량까지 알 수 있는 것은 아니다. 4편에서 이 차이와 Thanos를 대상으로 확인할 항목을 다룬다.

## 7. 처음부터 알아둘 동작의 한계

- **모든 자원을 같은 방식으로 최적화하지 않는다.** 전략이 요구하는 모델과 지표, 실행할 수 있는 액션 범위가 기준이다.
- **계획은 생성 당시의 판단이다.** 실행 전까지 VM 위치와 자원 여유가 바뀔 수 있다.
- **지표가 없다는 사실은 사용량 0과 다르다.** 누락을 낮은 부하로 해석하면 잘못된 이동 후보가 만들어질 수 있다.
- **Audit 성공은 VM 이동 완료를 뜻하지 않는다.** 분석과 실행의 상태를 나눠 읽어야 한다.
- **재시도·취소·revert가 완전한 원복을 보장하지 않는다.** 외부 서비스 작업과 실제 자원 상태를 함께 확인해야 한다.

이런 경계를 알면 패키징 검증 항목도 달라진다. 프로세스가 뜨는지만 보는 단계에서, 모델 수집·지표 조회·계획 생성·실행 결과를 나눠 검증하는 단계로 이어진다. 실제 RPM 구성과 설치 검증은 이번 네 편의 범위에 포함하지 않는다.

## 8. 이해 확인과 다음 글

다음 질문에 설명할 수 있으면 역할의 큰 틀을 이해한 상태다.

1. VM을 생성한 뒤에도 배치를 다시 판단할 이유는 무엇인가?
2. Placement의 자원 할당 정보만으로 CPU 부하를 알 수 있을까?
3. Watcher가 계획을 만들었는데도 Nova가 실행을 거부할 수 있는 이유는 무엇인가?
4. VM 이동 성공과 최적화 효과 확인은 왜 다른가?

다음 [2편 — 구성 요소와 핵심 용어](2026-11-02-watcher-epoxy-2-architecture.md)에서는 이 흐름을 실제 프로세스와 객체에 연결한다.

**연재:** 1편 역할 · [2편 구조·용어](2026-11-02-watcher-epoxy-2-architecture.md) · [3편 요청 흐름](2026-11-02-watcher-epoxy-3-flow.md) · [4편 데이터·전략](2026-11-02-watcher-epoxy-4-metrics-strategies.md)

## 9. 참고 자료와 확인 범위

- [Watcher Epoxy 아키텍처](https://docs.openstack.org/watcher/2025.1/architecture.html): 구성 요소와 객체 관계.
- [Watcher Epoxy 관리자 가이드](https://docs.openstack.org/watcher/2025.1/admin/index.html): 전략·데이터 소스의 탐색 시작점.
- [Epoxy 주요 변경 사항](https://releases.openstack.org/epoxy/highlights.html#watcher): Prometheus 추가, Ceilometer API 데이터 소스 제거, Monasca 데이터 소스 폐기 예정 표시. Ceilometer 수집 체계 전체가 제거됐다는 뜻은 아님.
- 이 글의 동작 설명은 공식 문서·고정 소스에 근거한다. Rocky 9.6 설치, 실제 Thanos 연결, 최적화 효과는 이 글에서 시험하지 않았다.
