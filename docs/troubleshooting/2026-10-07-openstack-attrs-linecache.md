---
title: "OpenStack API 지연 — attrs linecache 누적과 백포트"
summary: "대시보드 조회 지연에서 출발해 Python 검사 코드의 중복 보관을 추적한 과정. 원인을 좁힌 근거와 수정 전후 검증"
date: 2026-10-07
category: 트러블슈팅
summary_style: editorial
tags:
  - OpenStack
  - Linux
  - Observability
figure_label: "API LATENCY / ATTRS"
figure_lines:
  - "API schema validation"
  - "  → generated Python source"
  - text: "  → linecache growth"
    em: true
---

<section class="editorial-summary" aria-labelledby="editorial-summary-title">
  <div class="editorial-summary-layout">
    <div class="editorial-summary-copy">
      <span class="editorial-summary-label">이 기록의 결론</span>
      <h2 id="editorial-summary-title" class="editorial-summary-title">같은 검사 코드가<br>계속 쌓이고 있었다.</h2>
      <p>특정 Controller에서만 API 응답이 느려졌다.<br>추적 끝에 확인한 것은 attrs가 생성한 검사 코드였다. 같은 소스가 다른 이름으로 반복 저장되면서 메모리 사용량과 이름 탐색 비용이 늘어났다.</p>
    </div>
    <aside class="editorial-summary-facts" aria-label="문제 노드에서 관찰한 지연">
      <div>
        <span class="editorial-fact-label">토큰 발급</span>
        <p class="editorial-fact-value">2<span>초 이상</span></p>
      </div>
      <div>
        <span class="editorial-fact-label">하이퍼바이저 조회</span>
        <p class="editorial-fact-value">6–7<span>초</span></p>
      </div>
    </aside>
  </div>
  <p class="editorial-summary-result"><span>attrs 수정사항을 백포트해 <strong>동일 소스의 캐시 항목을 재사용</strong>하도록 바꿨다. 반복 시험에서 중복 저장이 멈췄고, 토큰 발급·Nova·Cinder API의 정상 응답을 확인했다.</span></p>
</section>

## 1. 환경과 요청 처리 구조

<div class="environment-section" markdown="1">

| 항목 | 환경 |
| --- | --- |
| OS | RHEL 9.4 |
| OpenStack | Caracal |
| Python | 3.9 계열 |
| attrs 패키지 | `python3-attrs-20.3.0-7.el9.noarch` |
| Keystone worker process | 6개 / Controller |

<div class="environment-grid" markdown="1">

<div markdown="1">

**Controller 구성**

[![HAProxy와 세 Controller의 API 구성](../assets/openstack-attrs-linecache/controller-topology.svg){ .architecture-diagram }](../assets/openstack-attrs-linecache/controller-topology.svg)

</div>

<div markdown="1">

**토큰 발급 흐름**

[![Keystone worker의 토큰 발급 처리 순서](../assets/openstack-attrs-linecache/token-request-flow.svg){ .architecture-diagram }](../assets/openstack-attrs-linecache/token-request-flow.svg)

</div>

</div>

<div class="section-body" markdown="1">

- **HAProxy:** 앞단에서 각 Controller로 API 요청 분배.
- **Keystone:** 사용자 인증과 토큰 발급. **Nova API:** 가상머신·하이퍼바이저 조회.
- **worker:** 요청 처리 프로세스. **PID:** 프로세스 식별 번호. 각 Controller에서 worker 6개 실행.

</div>

</div>

---

## 2. 증상과 영향

<div class="section-body" markdown="1">

사내 대시보드는 **`/os-hypervisors/detail`을 주기적으로 호출**한다. 이 조회가 느려져 분석을 시작했고, `nova-api.log`에서도 약 10초의 처리시간을 확인했다.

Controller별로 호출해 보니 **문제 노드에서만 토큰 발급과 목록 조회가 느렸다.**

| 관찰 항목 | 정상 노드 A/B | 문제 노드 C |
| --- | --- | --- |
| Keystone 토큰 발급 | 약 0.3초 | **약 2.3~2.4초** |
| 하이퍼바이저 조회 CLI | 문제 노드보다 빠른 응답 | **약 6~7초** |
| Keystone `GET /v3` | 빠른 응답 | 빠른 응답 |
| 일부 API worker CPU | 대체로 낮음 | **약 100~200%** |
| worker RSS | 약 200,000 KiB | **약 1,700,000 KiB** |

RSS는 프로세스가 실제 물리 메모리에 보유한 메모리 크기다. 문제 노드의 worker는 정상 노드보다 훨씬 많은 메모리를 사용하고 있었다.

API 로그의 약 10초와 CLI의 6~7초는 서로 다른 호출에서 나온 값이다. CLI에는 인증과 클라이언트 처리도 포함될 수 있어, 두 값의 차이를 한 구간의 비용으로 계산할 수는 없다.

</div>

---

## 3. 원인 분석

<p class="subsection-title"><strong>3-1. 원인을 좁힌 과정</strong></p>

<div class="section-body" markdown="1">

API 버전 → HAProxy → 요청량 → 통신 대기 → Python 실행 순서로 범위를 좁혔다.

<details class="analysis-toggle" markdown="1">
<summary>3-1-1. API 버전 때문에 추가 작업이 생긴 것은 아닐까?</summary>

**의심한 이유:** Nova는 API 버전에 따라 처리 내용이 달라질 수 있어, 특정 버전의 추가 작업이 지연을 만드는지 확인 필요.

**확인:** `2.87`과 `2.88`을 비교했다. 테스트에서는 차이가 있었지만 운영 대시보드는 `2.87`을 사용했고, 운영 비교에서는 뚜렷한 차이를 찾지 못했다.

**판단:** 2.88의 uptime 관련 추가 처리만으로는 설명하기 어려웠다. 공통 인증·API 처리 경로로 조사 범위 이동.


</details>

<details class="analysis-toggle" markdown="1">
<summary>3-1-2. 로드밸런서를 우회해도 느릴까?</summary>

**의심한 이유:** API 앞단의 HAProxy에서 요청을 중계·분배하는 시간이 길어질 가능성.

**확인:** HAProxy를 거치지 않고 문제 노드의 Keystone `:5000`으로 직접 호출했다. 이때도 토큰 발급에 약 2초 이상 소요.

**판단:** 로드밸런서만의 문제보다 문제 노드 내부의 처리 경로를 확인할 필요.

`GET /v3`는 API 버전·서비스 정보를 확인하는 가벼운 요청이다. 토큰 발급 POST는 인증 데이터를 받아 검사와 인증을 수행한다. GET이 빠르다는 사실만으로 토큰 발급 경로까지 정상이라고 볼 수는 없다.


</details>

<details class="analysis-toggle" markdown="1">
<summary>3-1-3. 요청이 많아서 처리하지 못하는 상황일까?</summary>

**의심한 이유:** 문제 노드에 요청이 몰리면 worker가 바빠지고 뒤의 요청도 지연될 가능성.

**확인:** tcpdump로 Keystone 통신을 비교했다. 노드 간 통신 규모는 대체로 유사했고, 설정·패키지·Fernet key도 비슷했다. Fernet key는 토큰 암호화에 쓰이는 키다. 높은 CPU·메모리는 문제 노드에서만 관찰.

**판단:** 현재 요청량 차이만으로 설명하기 어려워 worker 내부 상태에 집중했다.

- 6개 worker PID는 유지, CPU가 높은 worker만 교대. 특정 PID 하나가 아니라 6개 전체를 관찰한 이유.
- POST는 계속 유입되는 상태. 요청량이 적었던 것이며 완전한 무요청 상태는 아님.


</details>

<details class="analysis-toggle" markdown="1">
<summary>3-1-4. DB나 캐시 응답을 기다리는 것은 아닐까?</summary>

**의심한 이유:** 토큰 발급에는 사용자·권한 조회가 있어 DB나 캐시 연결 대기도 후보. 같은 DB를 사용하더라도 노드별 통신 경로는 다를 수 있음. LDAP은 미사용.

**확인:** strace로 통신·대기 작업과 소요시간을 살폈다. 관찰 범위에서 긴 DB·Memcached·socket 응답 대기는 찾지 못했고, CPU는 주로 `%usr`에서 증가했다.

**판단:** `%usr`는 프로그램 코드 실행에 사용한 CPU 비율이다. 외부 응답 대기보다 Python 안의 연산을 추적할 필요가 있었다. 이번 수집만으로 모든 I/O 문제를 배제한 것은 아니다.


</details>

<details class="analysis-toggle" markdown="1">
<summary>3-1-5. Python 안에서는 어떤 작업이 반복될까?</summary>

**의심한 이유:** 높은 `%usr`와 짧은 통신 대기를 보고 Python 내부의 반복 연산을 의심했다. strace로는 문자열 생성·캐시 검색 같은 내부 연산을 확인하기 어렵다.

**확인:** perf로 실행이 집중된 라이브러리를 비교했다. 정상 노드는 비밀번호 해시 계산과 관련된 `_bcrypt.abi3.so`, **문제 노드는 Python 실행을 담당하는 libpython**이 두드러졌다. 별도 bcrypt 시험에서는 노드 간 뚜렷한 차이를 찾지 못했다.

Python 함수 호출을 추적하는 USDT 이벤트로 범위를 더 좁혔다. 확인한 위치는 다음과 같다.

- `attr/_make.py`의 **`_generate_unique_filename()`** — 동적으로 만든 코드에 붙일 이름 생성.
- `uuid.py`의 **`__str__()`** — 이름 예약에 쓰는 식별 값을 문자열로 변환.
- `<attrs generated ... Validator-N>` — 검사 도구의 생성 소스에 붙은 가상 파일명.

- **생성 파일명 번호:** 정상 노드 약 2만, 문제 노드 약 69만. `Validator-N`의 N은 파일명에 붙은 번호이며 객체·캐시 개수를 직접 센 값은 아님.
- **메모리:** `RssAnon`·`Anonymous`·`Private_Dirty`·`VmData` 증가. 프로세스의 사유·익명 메모리에 누적 관찰.

**판단:** 큰 번호의 생성 소스, 이름 생성 함수의 반복 실행, 프로세스 메모리 증가가 함께 나타났다. 코드 생성·보관 경로로 조사 범위 축소.


</details>

관찰한 통신 대기와 요청량 차이만으로는 지연을 설명하기 어려웠다. **Python 실행 추적에서 이름 생성 함수의 반복 호출과 메모리 증가가 함께 나타나**, 생성 코드의 보관 경로를 확인하기로 했다.

</div>

<p class="subsection-title"><strong>3-2. 확인한 원인 — 같은 소스의 반복 등록</strong></p>

<div class="section-body" markdown="1">

추적한 이름 생성 함수는 토큰 요청의 입력값 검사에 쓰이는 도구를 준비할 때 호출된다. 이 경로에서 attrs가 만든 소스를 어떻게 보관하는지 확인했다.

??? note "토큰 요청에서 검사 코드가 생성되는 과정"
    `openstack token issue`는 Keystone의 `POST /v3/auth/tokens`에 인증 방식·사용자·프로젝트 정보를 JSON으로 전달한다. Keystone은 **입력 데이터의 구조를 검사한 뒤 사용자 인증과 토큰 발급을 진행한다.** 구조의 검사 규칙을 스키마(schema), 그 규칙에 따라 입력을 확인하는 도구를 Validator라고 부른다.

    [Keystone Caracal의 토큰 발급 코드](https://github.com/openstack/keystone/blob/24.0.0/keystone/api/auth.py)에서 확인한 순서:

    ```python title="keystone/api/auth.py — 토큰 발급 처리 일부" hl_lines="2"
    auth_data = self.request_body_json.get('auth')
    auth_schema.validate_issue_token_auth(auth_data)
    token = authentication.authenticate_for_token(auth_data)
    ```

    강조된 두 번째 줄이 스키마 검증의 진입점이다. `SchemaValidator` → jsonschema의 `extend()` → `create()`로 연결돼 새 Validator 클래스를 만든다. **`@attr.s`를 통해 attrs가 초기화·비교 등의 보조 코드를 생성한다.**

    클래스는 객체의 데이터와 기능을 정의한 설계도다. 여기서는 요청 처리 중 검사 도구의 클래스를 새로 만들기 때문에 동적 클래스 생성으로 표현했다.

    입력값 검사는 필요한 항목이 빠졌거나 자료형이 잘못된 요청을 걸러내는 단계. 검사 도구를 준비하려면 다음 기본 기능도 필요.

    | 생성되는 코드 | 필요한 이유 |
    | --- | --- |
    | `__init__` | 검사 도구를 만들 때 사용할 스키마 등 초기값 설정 |
    | `__eq__` | 객체 간 동등성 비교. attrs의 기본 생성 기능 |
    | `__hash__` | 해시 기능을 사용하는 클래스에서 생성. 이번 수정 범위에도 포함 |

attrs는 메서드 소스를 문자열로 만들고 실행 가능한 Python 코드로 변환한다. 실제 파일에서 읽은 코드가 아니므로, 오류 분석 때 소스를 다시 표시하려면 별도로 보관해야 한다.

보관 위치는 Python의 **linecache**. 가상 파일명을 붙여 각 worker의 메모리에 소스 문자열과 관련 정보를 저장한다. 디스크 파일이나 외부 Memcached와는 별개다.

기존 구현에서는 같은 소스가 이미 있어도 재사용하지 않았다. `Validator-2`, `Validator-3`처럼 새 이름을 붙여 다시 등록하는 방식이었다.

<figure class="flow">
  <ol>
    <li>검사 코드 생성</li>
    <li>빈 이름 탐색</li>
    <li>새 항목으로 보관</li>
  </ol>
  <ul>
    <li>같은 소스도 다른 번호로 반복 저장.</li>
  </ul>
</figure>

`_generate_unique_filename()`은 UUID로 이름을 예약하고, 이미 사용된 이름이면 `-2`·`-3` 등을 처음부터 탐색한다. **생성 소스가 같은지 비교해 기존 항목을 재사용하는 처리는 없었다.**

이 동작이 반복되면서 두 가지 비용이 쌓였다.

- **메모리:** 같은 메서드 소스를 worker 메모리에 계속 보관.
- **CPU:** 다음 코드를 등록할 때 이미 사용된 이름들을 처음부터 다시 탐색.

많은 항목이 쌓인 worker는 현재 요청량이 적어도 한 번의 준비 작업에 큰 비용이 들 수 있다. 트래픽 규모는 비슷한데 문제 노드만 CPU·메모리 사용량이 크고 느렸던 관측과 맞아떨어졌다. 3-1의 추적에서도 이름 생성 함수의 반복 호출과 사유·익명 메모리 증가를 함께 확인했다.

!!! danger "결론 — 동일 소스의 중복 등록과 이름 탐색 비용 누적"
    **같은 생성 소스를 재사용하지 않는 구현을 병목으로 판단했다.** 소스의 중복 보관과 반복 이름 탐색이 메모리·CPU 비용을 함께 늘렸고, 다음 절의 수정 전후 시험에서 중복 등록 방지 동작을 확인했다.

다만 문제 노드에 더 많이 누적된 정확한 과거 호출·가동 이력은 별도로 확인해야 한다.

**해결 방향:** 코드 생성과 디버깅용 소스 보관은 유지하고, 같은 소스는 기존 항목을 재사용. 백포트 내용과 검증 결과는 다음 절에 정리했다.

관련 소스: [Keystone 검증 연결](https://github.com/openstack/keystone/blob/24.0.0/keystone/auth/schema.py), [Keystone SchemaValidator](https://github.com/openstack/keystone/blob/24.0.0/keystone/common/validation/validators.py), [jsonschema 4.16.0 클래스 생성](https://github.com/python-jsonschema/jsonschema/blob/v4.16.0/jsonschema/validators.py), [attrs 20.3.0 이름 생성](https://github.com/python-attrs/attrs/blob/20.3.0/src/attr/_make.py#L1429-L1456).

??? note "사용한 진단 명령 — 목적·옵션·결과 읽기"
    !!! warning "실행 전 확인"
        대상은 분석할 Controller. `P` 또는 `HOT_PID`에는 현재 확인한 worker PID 지정. strace와 perf는 처리 성능에 영향을 줄 수 있어 짧게 수집. 통신 로그에는 인증 정보가 포함될 수 있으므로 외부 공유 전 점검 필요.

    **통신량 비교: tcpdump**

    **왜 확인했는지:** 문제 노드에만 많은 요청이 들어오는지 확인. 처리 비용을 비교하기 전 트래픽 차이부터 점검.

    ```bash
    tcpdump -i any -nn -tttt 'tcp port 5000'
    ```

    - `-i any`: 모든 네트워크 인터페이스에서 수집.
    - `-nn`: IP·포트 번호를 이름으로 변환하지 않고 숫자로 표시.
    - `-tttt`: 패킷 시각을 날짜와 시간으로 표시.
    - `tcp port 5000`: 출발지 또는 목적지 TCP 포트가 5000인 패킷만 표시.

    **읽는 방법:** 노드별 통신 규모와 시각 비교. 패킷 수가 HTTP 요청 수와 정확히 같지는 않음.

    **worker의 CPU 확인: pidstat**

    **왜 확인했는지:** 같은 worker가 계속 CPU를 쓰는지, 처리 주체가 바뀌는지 확인. 어느 프로세스를 추적할지 결정하는 단계.

    ```bash
    pidstat -t -u -p "$P" 1
    ```

    - `-t`: 프로세스 내부 스레드까지 표시.
    - `-u`: CPU 사용 정보 표시.
    - `-p "$P"`: 지정한 PID만 관찰.
    - `1`: 1초 간격으로 출력.

    **읽는 방법:** 순간값 한 번보다 반복 출력의 `%usr`·`%system`·`%CPU` 변화 확인. `%system`은 커널 작업, `%usr`는 프로그램 코드 실행에 사용한 CPU.

    **통신 대기시간 확인: strace**

    **왜 확인했는지:** API가 느린 동안 DB·캐시 응답을 기다리는지 확인. CPU 연산이 느린 상황과 외부 응답 대기 구분.

    ```bash
    timeout -s INT 10 strace -f -ttT -yy -p "$P" \
      -e trace=%network,poll,ppoll,select,pselect6 \
      -o /tmp/keystone-network.strace
    ```

    - `timeout -s INT 10`: 10초 뒤 인터럽트 신호로 추적 종료.
    - `-p`: 지정한 프로세스에 추적 연결. `-f`: 스레드·자식 프로세스도 추적.
    - `-tt`: 호출 시각을 세밀하게 표시. `-T`: 개별 호출에 걸린 시간 표시.
    - `-yy`: 연결 등 파일 디스크립터의 상세 정보 표시.
    - `-e trace=…`: 통신과 대기 계열만 선택. `-o`: 결과를 파일로 저장.

    **읽는 방법:** 특정 연결의 호출에서 긴 시간이 반복되는지 확인. 긴 호출이 없다는 결과만으로 모든 I/O 문제를 배제하지 않음.

    **이벤트 대기 요약: epoll·accept**

    **왜 확인했는지:** 연결을 받거나 이벤트를 기다리는 호출에 시간이 몰리는지 보조 확인.

    ```bash
    timeout -s INT 10 strace -f -c \
      -e trace=epoll_wait,epoll_pwait,epoll_ctl,accept,accept4 \
      -p "$HOT_PID"
    ```

    `-c`는 개별 로그 대신 syscall 호출 수·시간·오류 수를 집계. `epoll_wait`는 이벤트 대기, `epoll_ctl`은 감시 대상 등록·변경, `accept`는 연결 수락 관련 호출.

    **읽는 방법:** 요약 비율은 선택한 syscall의 집계 시간 비중이며 프로세스 CPU 사용률이 아님. `epoll_wait`가 100%라는 이유만으로 반복 연산이나 timeout 확정 불가.

    perf의 라이브러리 분석은 실행 위치를 좁히는 과정, Python USDT는 함수 호출 경로 확인용. 함수 진입 이벤트 수가 CPU 사용시간은 아니며 임시 probe는 수집 후 제거.

</div>

---

## 4. 해결 방안

<p class="subsection-title"><strong>4-1. 동일 소스를 재사용하도록 코드 수정</strong></p>

<div class="section-body" markdown="1">

이미 공개된 [attrs 수정 #828](https://github.com/python-attrs/attrs/commit/38580632ceac1cd6e477db71e1d190a4130beed4)을 기존 20.3.0 코드에 반영했다. **기존 버전을 유지하면서 필요한 수정만 가져오는 백포트** 방식이다.

수정 파일은 `/usr/lib/python3.9/site-packages/attr/_make.py`. 다른 최신 버전의 파일 전체를 그대로 교체하지는 않았다.

<figure class="flow">
  <ol>
    <li>검사 코드 생성</li>
    <li>이름·내용 비교</li>
    <li>같으면 기존 항목 사용</li>
  </ol>
  <ul>
    <li>같은 소스는 재사용, 다른 소스만 추가 저장.</li>
  </ul>
</figure>

!!! tip "수정의 핵심 — 보관은 유지, 같은 소스는 재사용"
    **이름과 소스 내용이 같으면 기존 항목 재사용**, 내용이 다르면 별도 등록. 검사 클래스 생성이나 디버깅용 소스 보관 기능 자체를 없애는 수정은 아님.

[코드 변경 보기 — 빨간색 원본 / 초록색 수정본](https://github.com/wjdxotjd112/tech-notes/commit/93fe7d8ee88b13328e773f69ed50f991866f0542){ .button }

[원본 코드](https://github.com/wjdxotjd112/tech-notes/blob/4ebd34d/examples/attrs-linecache/attr/_make.py) · [수정 코드](https://github.com/wjdxotjd112/tech-notes/blob/93fe7d8ee88b13328e773f69ed50f991866f0542/examples/attrs-linecache/attr/_make.py) · [전체 diff 다운로드](../assets/openstack-attrs-linecache/python-attrs-20.3.0-7.el9-linecache-backport.patch)

GitHub 변경 커밋에서는 `_make.py` 한 파일만 수정했다. 좌우 비교를 선택하면 제거한 코드와 추가한 코드를 함께 볼 수 있다.

| 수정 위치 | 변경 목적 |
| --- | --- |
| `_generate_unique_filename()` | 기본 이름 생성만 담당하도록 변경 |
| `_make_method()` | 이름과 소스 내용 비교, 동일 항목 재사용 |
| `_make_init()`·`_make_eq()`·`_make_hash()` | 공통 생성·보관 경로 사용 |

</div>


<p class="subsection-title"><strong>4-2. 캐시 누적 여부를 분리해서 검증</strong></p>

<div class="section-body" markdown="1">

HTTP 요청 전체에는 인증, DB, 네트워크, worker 분배 등 여러 요인이 포함된다. 이번 수정에서는 **검사 도구를 준비할 때 같은 소스가 중복 보관되는지**를 확인했다.

별도 Rocky Linux 9.6 테스트 노드에서 Keystone의 `SchemaValidator` 생성 경로만 분리해 10회 반복했다. 같은 작업을 수행할 때 원본과 수정본의 소스 보관 항목이 어떻게 늘어나는지 비교했다.

10회는 **누적 방식이 바뀌었는지 확인하기 위한 횟수**다. 운영 성능이나 장기 안정성을 모두 검증한 부하량은 아니다.

</div>

<p class="subsection-title"><strong>4-3. 수정 전후 결과</strong></p>

<div class="section-body" markdown="1">

이 시험에서는 검사 도구를 한 번 준비할 때 `__init__`와 `__eq__`의 소스가 한 항목씩 생성됐다. 최초 등록 항목은 **2개**.

| 같은 검사 도구를 준비한 횟수 | 원본의 관련 소스 보관 항목 | 수정본의 관련 소스 보관 항목 |
| --- | --- | --- |
| 1회 | 2개 | 2개 |
| 2회 | 4개 | 2개 |
| 5회 | 10개 | 2개 |
| 10회 | **20개** | **2개** |

!!! tip "검증 결과 읽기"
    **원본은 같은 소스를 계속 추가, 수정본은 최초 2개를 재사용.** 처음 준비할 때의 기능을 유지하면서도, 반복 준비 시 중복 항목이 늘지 않는지 확인한 결과다.

각 조건은 별도의 Python 시험 프로세스에서 측정했다. 실제 설치한 수정본에서도 같은 결과를 확인했다.

표의 수치는 이 시험의 Validator 관련 소스 항목 수다. 전체 linecache 크기나 운영 worker의 캐시를 직접 센 값은 아니다.

추가 기능 확인도 진행:

- 객체 초기화·비교·해시, 다른 생성 소스의 분리, 동시 생성, Keystone 스키마 검증 정상.
- Keystone 토큰 발급·Nova 하이퍼바이저 조회·Cinder 서비스 조회 성공.

API의 정상 응답까지 확인했다. 다만 운영 환경의 패치 전후 응답시간이나 전체 OpenStack 회귀 시험을 대신하는 결과는 아니다.

??? note "수동 수정과 검증 명령"
    !!! warning "적용 대상과 복구 준비"
        검증한 패키지는 `python3-attrs-20.3.0-7.el9.noarch`. 다른 버전이나 이미 수정된 코드에는 그대로 적용하지 않고 차이 확인. 원본 소스·기존 bytecode 백업과 관련 서비스의 원복 계획 준비.

    **패키지와 원본 상태 확인**

    **목적:** 수정할 파일이 검증한 버전인지, 다른 변경이 이미 있는지 확인.

    ```bash
    rpm -q python3-attrs
    rpm -V python3-attrs
    ```

    `-q`는 설치 버전 조회, `-V`는 RPM에 기록된 파일 상태와 실제 파일 비교. 수정 전 차이가 있으면 먼저 확인.

    이후 원본 `_make.py`와 기존 `.pyc`를 백업하고 GitHub 변경 커밋에 맞춰 소스 수동 수정. `.pyc`는 Python이 생성하는 실행용 bytecode이므로 직접 편집하지 않음.

    **Python 문법 확인**

    **목적:** 수동 편집 과정의 들여쓰기·문법 오류를 서비스 반영 전에 확인.

    ```bash
    python3 -m py_compile /usr/lib/python3.9/site-packages/attr/_make.py
    ```

    `-m py_compile`은 Python의 문법 검사·bytecode 생성 모듈 실행. 서비스와 같은 Python 3.9 사용. 문법 통과가 기능 검증까지 뜻하지는 않음.

    **같은 검사 도구 10회 준비**

    **목적:** 최초 준비 이후에도 동일 코드의 보관 항목이 계속 늘어나는지 확인.

    ```bash
    python3 - <<'PY'
    import linecache
    from keystone.common.validation.validators import SchemaValidator

    marker = "jsonschema.validators.create.<locals>.Validator"
    for key in list(linecache.cache):
        if marker in key:
            del linecache.cache[key]

    counts = []
    for _ in range(10):
        SchemaValidator({"type": "object"})
        counts.append(sum(marker in key for key in linecache.cache))

    print("linecache_counts=" + ",".join(map(str, counts)))
    PY
    ```

    `marker`는 해당 검사 도구의 소스 이름만 골라 세기 위한 문자열. 간단한 객체 형식의 스키마를 반복 사용해 조건 고정.

    **수정본의 확인 기준:** `2,2,2,2,2,2,2,2,2,2`처럼 최초 등록 이후 항목 수 유지. 이 명령은 새 시험 프로세스만 사용하며 실행 중인 Keystone worker의 캐시를 지우지 않음.

</div>

---

## 5. 운영 반영과 재발 방지

<div class="section-body" markdown="1">

**worker를 재기동하면 누적된 메모리가 초기화돼 일시적으로 빨라질 수 있다.** 원본 코드가 남아 있으면 같은 조건에서 다시 쌓일 수 있으므로 재기동은 임시 완화에 해당한다. 백포트는 누적 방식 자체를 수정하는 조치.

수정 파일을 저장해도 실행 중인 worker는 이전에 읽은 코드를 사용한다. 새 코드를 반영하려면 관련 서비스의 계획된 재기동이 필요하다.

!!! warning "운영 반영 전"
    실제 서비스 구동 방식을 확인한 뒤 HAProxy에서 대상 노드의 요청을 빼고 순차 작업. 해당 환경의 대상은 Keystone을 구동하는 httpd와 Nova·Cinder API 등. 원본 복원·재기동 절차와 주요 API 확인 준비. 테스트에서도 종료 지연과 일시적 서비스 실패 이력이 있어 재기동 영향 점검 필요.

수동 변경은 RPM 재설치·업데이트로 덮어써질 수 있다. 장기 운영에는 **수정 이력을 관리하는 백포트 RPM 또는 배포사 공식 패키지** 검토.

운영 반영 후에는 같은 API의 응답시간과 worker CPU·RSS를 확인하고, 시간이 지나도 다시 증가하지 않는지 관찰한다. **재기동 직후뿐 아니라 반복 요청 이후의 상태까지 확인**해야 한다.

</div>

---

## 6. 관련 사례와 참고 자료

<div class="section-body" markdown="1">

- [attrs Issue #826](https://github.com/python-attrs/attrs/issues/826): 같은 이름의 클래스를 반복 생성할수록 처리 비용이 커진 문제.
- [attrs 수정 #828](https://github.com/python-attrs/attrs/commit/38580632ceac1cd6e477db71e1d190a4130beed4): 동일 생성 소스의 보관 항목 재사용.
- [Launchpad #2121607](https://bugs.launchpad.net/nova/+bug/2121607): Caracal 이후 Nova API 응답시간·메모리 증가를 조사해 python-attrs로 원인 연결.
- [Ubuntu Jammy 수정 패키지](https://bugs.launchpad.net/nova/+bug/2121607/comments/18): 기존 21.2.0에 수정사항을 백포트한 `21.2.0-1ubuntu1`. [2025년 12월 9일 업데이트 배포 완료](https://bugs.launchpad.net/nova/+bug/2121607/comments/17).
- [strace 옵션 설명](https://man7.org/linux/man-pages/man1/strace.1.html) · [pidstat 옵션 설명](https://man7.org/linux/man-pages/man1/pidstat.1.html).
- [백포트 코드의 attrs MIT 라이선스](../assets/openstack-attrs-linecache/UPSTREAM_LICENSE.txt).

</div>
