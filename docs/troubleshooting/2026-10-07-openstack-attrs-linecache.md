---
title: "OpenStack API 지연 — attrs linecache 누적과 백포트"
summary: "토큰 발급 2초 이상, 하이퍼바이저 조회 6~7초. Python 코드 누적을 추적하고 attrs 백포트로 캐시 증가 억제"
date: 2026-10-07
category: 트러블슈팅
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

!!! abstract "핵심 요약"
    - **증상** — 특정 Controller에서만 토큰 발급 **2.3~2.4초**, 하이퍼바이저 조회 **6~7초**.
    - **원인** — 구버전 attrs가 동일한 생성 소스를 계속 캐시에 등록. 메모리와 새 이름 탐색 비용 증가.
    - **조치** — attrs upstream 수정사항을 기존 RPM 코드에 백포트. 동일 소스의 캐시 항목 재사용.
    - **검증** — 같은 Validator 10회 생성 시 관련 캐시 **원본 20개 → 수정본 2개**.

운영 관찰과 별도 테스트 서버의 패치 검증을 구분한 기록. 내부 시스템 정보는 Controller A/B/C로 익명화.

---

## 1. 시작점 — 대시보드의 하이퍼바이저 조회 지연

사내 대시보드에서 **`/os-hypervisors/detail`을 주기적으로 호출**하는 로직 사용. 해당 조회가 느려져 분석 시작, `nova-api.log`에서도 약 10초의 처리시간 확인.

Controller별로 직접 호출해 보니 **Controller C에서만 인증과 API 응답 지연** 발생.

| 관찰 항목 | 정상 노드 A/B | 문제 노드 C |
| --- | --- | --- |
| Keystone 토큰 발급 | 약 0.3초 | **약 2.3~2.4초** |
| 하이퍼바이저 조회 CLI | C보다 빠른 응답 | **약 6~7초** |
| Keystone `GET /v3` | 빠른 응답 | 빠른 응답 |
| 일부 API worker CPU | 대체로 낮음 | **약 100~200%** |
| worker RSS | 약 200,000 KiB | **약 1,700,000 KiB** |

API 로그의 약 10초와 CLI의 6~7초는 서로 다른 관측값. CLI 시간에는 인증·API 호출·클라이언트 처리 등이 포함되므로 같은 요청의 전후 성능 비교는 아님.

**장애 환경:** RHEL 9.4 · OpenStack Caracal · `python3-attrs-20.3.0-7.el9.noarch`.

**테스트 환경:** Rocky Linux 9.6 · Python 3.9.21 · jsonschema 4.16.0 · 동일 attrs RPM. Nova 코드 분석은 Epoxy 31.0.0 환경에서 진행.

---

## 2. 원인 범위를 좁힌 과정

### 네트워크 대기보다 Python 연산에 집중한 이유

| 순서 | 확인한 내용 | 판단 |
| --- | --- | --- |
| ① Microversion | 운영 대시보드는 2.87 사용. 2.87/2.88 비교에서 뚜렷한 지연 차이 없음 | 2.88의 uptime 추가 처리만으로 설명 어려움 |
| ② 직접 호출 | HAProxy를 우회한 C의 `:5000`에서도 토큰 발급 지연 | 로드밸런서만의 문제는 아님 |
| ③ 노드 비교 | 트래픽 규모·설정·패키지·Fernet key 대체로 유사. DB 대상 동일, LDAP 미사용 | 단순 요청 집중이나 설정 차이의 근거 부족 |
| ④ CPU·strace | C의 `%usr`는 높지만 관찰 범위에서 긴 DB·캐시·socket 대기는 찾지 못함 | **사용자 영역 연산 추적 필요** |
| ⑤ perf | C에서 libpython 실행이 두드러짐. Python 함수 추적으로 attrs 이름 생성 경로 확인 | **동적 코드 생성·캐시 누적 조사** |

`GET /v3`가 빠르더라도 토큰 발급 POST가 빠르다는 보장은 없음. discovery 응답과 인증 요청의 내부 처리 경로가 다르기 때문.

6개 worker PID는 그대로였지만 높은 CPU 사용이 기존 worker 사이에서 이동. POST는 계속 들어오고 있었으므로 “완전한 무요청 상태의 CPU 포화”와는 구분.

### 결정적인 증거 — 메모리와 생성 소스 번호

- **Python 추적:** `attr/_make.py`의 `_generate_unique_filename()`, `uuid.py`의 `__str__()` 반복 실행.
- **메모리:** C에서 RSS뿐 아니라 `RssAnon`·`Anonymous`·`Private_Dirty`·`VmData`도 크게 증가.
- **생성 파일명 suffix:** 정상 노드 약 **2만**, C 약 **69만** 수준.

메모리 지표는 프로세스의 익명·사유 메모리 증가를 뒷받침하는 근거. 해당 수치만으로 특정 Python 객체가 원인이라는 뜻은 아니며, **실제 함수 추적과 문제 코드 구현을 함께 확인**한 것이 핵심.

!!! note "Validator-69만의 정확한 의미"
    `Validator-N`의 N은 attrs가 만든 **가상 파일명의 번호**. 살아 있는 Validator 객체 수나 직접 센 linecache 개수가 아님. worker마다 캐시가 독립적이므로 해당 PID/TID 기준으로 해석.

??? note "사용한 진단 명령과 해석"
    실행 위치는 분석 대상 Linux 노드. `P` 또는 `HOT_PID`에는 해당 시점의 worker PID 지정. 추적은 서비스에 영향을 줄 수 있으므로 짧게 수집하고 원본 통신 로그의 민감정보 점검 필요.

    **Keystone 통신 확인**

    ```bash
    tcpdump -i any -nn -tttt 'tcp port 5000'
    ```

    패킷 규모 비교용. 패킷 수를 HTTP 요청 수 또는 처리 비용과 동일하게 취급하지 않음.

    **스레드별 CPU 확인**

    ```bash
    pidstat -t -u -p "$P" 1
    ```

    **네트워크 syscall과 소요시간 확인**

    ```bash
    timeout -s INT 10 strace -f -ttT -yy -p "$P" \
      -e trace=%network,poll,ppoll,select,pselect6 \
      -o /tmp/keystone-network.strace
    ```

    **epoll·accept 요약**

    ```bash
    timeout -s INT 10 strace -f -c \
      -e trace=epoll_wait,epoll_pwait,epoll_ctl,accept,accept4 \
      -p "$HOT_PID"
    ```

    `epoll_wait`의 요약 비율은 선택한 syscall의 집계 시간 비중이지 CPU 사용률이 아님. 이 비율만으로 busy-spin 또는 timeout을 확정할 수 없음.

    perf의 DSO 분석은 실행 라이브러리를 좁히는 단계. Python USDT는 함수 호출 경로 확인용이며, 이벤트 수가 CPU 사용시간을 뜻하지는 않음. 임시 probe를 추가했다면 수집 후 제거.

??? note "별도 Nova 테스트 환경에서 확보한 추가 증거"
    `/servers/detail`의 query schema 검증 → `_SchemaValidator` → `jsonschema.validators.extend()` → `create()` → attrs 생성 코드 경로 확인.

    독립 Python 시험에서 생성 클래스 ID가 서로 다르고 관련 캐시 항목도 증가. 실제 요청을 처리하는 worker 추적에서도 검증 함수·이름 생성 함수·generated Validator 실행을 연결.

    보존된 관측값: API 로그 약 2.09~2.63초, worker RSS 약 928MB~1.14GB, `%usr` 70~100%, 생성 파일명 번호 약 37만 수준.

    운영의 `/os-hypervisors/detail`과 같은 조건의 측정은 아님. 초기 대량 토큰 발급만으로는 동일한 CPU 포화가 재현되지 않았으므로 요청 횟수만으로 재현 성공을 판단하지 않음.

---

## 3. 원인 — 같은 코드인데 매번 새 캐시 항목 생성

Keystone의 `SchemaValidator`가 `jsonschema.validators.extend()`를 호출하고, jsonschema가 새 Validator 클래스를 생성. `@attr.s`는 해당 클래스의 `__init__`·`__eq__` 같은 메서드 소스를 생성.

- **`__init__`:** 객체 생성 시 schema 등 필드 초기화.
- **`__eq__`:** 객체 간 동등성 비교. HTTP 요청을 비교하기 위한 추가 작업은 아님.
- **`linecache`:** 동적으로 만든 소스를 traceback·디버거에 표시하기 위한 Python 소스 캐시.

캐시에 저장되는 것은 **Validator 객체 자체가 아니라 생성된 메서드의 소스 문자열과 메타데이터**. 실제 디스크 파일이 아닌 가상 파일명으로 관리.

### 기존 방식

<figure class="flow">
  <ol>
    <li>동일 코드 생성</li>
    <li>빈 이름 탐색</li>
    <li>매번 항목 추가</li>
  </ol>
  <ul>
    <li>기존 attrs 20.3.0. 같은 내용이어도 새 이름 예약. 화살표는 처리 순서.</li>
  </ul>
</figure>

기존 `_generate_unique_filename()`은 UUID로 임시 항목을 예약. 이름이 이미 있으면 `-2`, `-3` 등을 처음부터 탐색해 빈 이름 확보.

**반복 생성 → 캐시 메모리 증가 → 다음 이름 탐색 비용 증가.** 메모리가 부족하지 않아도 이 탐색에 CPU를 사용하며 API 응답 지연 가능.

근거: [attrs 20.3.0 원본 함수](https://github.com/python-attrs/attrs/blob/20.3.0/src/attr/_make.py#L1429-L1456), [jsonschema 4.16.0 클래스 생성](https://github.com/python-jsonschema/jsonschema/blob/v4.16.0/jsonschema/validators.py), [Keystone Caracal 검증 코드](https://github.com/openstack/keystone/blob/24.0.0/keystone/common/validation/validators.py).

---

## 4. 해결 — 동일한 생성 소스 재사용

<figure class="flow">
  <ol>
    <li>메서드 소스 생성</li>
    <li>이름·소스 비교</li>
    <li>동일 항목 재사용</li>
  </ol>
  <ul>
    <li>백포트 후 처리. 이름은 같지만 소스가 다르면 별도 항목 등록. 동적 클래스 생성과 디버깅 기능 유지.</li>
  </ul>
</figure>

수정 대상은 `/usr/lib/python3.9/site-packages/attr/_make.py`. 최신 파일 전체 교체가 아니라 [upstream 수정 #828](https://github.com/python-attrs/attrs/commit/38580632ceac1cd6e477db71e1d190a4130beed4)을 20.3.0 구조에 맞게 백포트.

### GitHub에서 실제 수정 줄 확인

[코드 변경 보기 — 빨간색 원본 / 초록색 수정본](https://github.com/wjdxotjd112/tech-notes/commit/93fe7d8ee88b13328e773f69ed50f991866f0542){ .button }

[원본 코드](https://github.com/wjdxotjd112/tech-notes/blob/4ebd34d/examples/attrs-linecache/attr/_make.py) · [수정 코드](https://github.com/wjdxotjd112/tech-notes/blob/93fe7d8ee88b13328e773f69ed50f991866f0542/examples/attrs-linecache/attr/_make.py) · [전체 diff 다운로드](../assets/openstack-attrs-linecache/python-attrs-20.3.0-7.el9-linecache-backport.patch)

원본 등록과 코드 수정을 별도 커밋으로 분리. **변경 커밋은 `_make.py` 한 파일만 수정**하므로 실제 삭제·추가 줄만 비교 가능. GitHub의 diff 보기 옵션에서 `Split`을 선택하면 좌우 비교 가능.

| 수정 부분 | 핵심 변경 |
| --- | --- |
| `_generate_unique_filename()` | UUID 예약·반복 탐색 제거, 기본 이름 생성만 담당 |
| `_make_method()` | 기존 이름과 소스 내용을 비교해 동일 항목 재사용 |
| `_make_init()`·`_make_eq()`·`_make_hash()` | 공통 메서드 생성 경로 사용 |

새 공통 처리의 핵심 부분. 전체 함수가 아닌 설명용 발췌:

```python title="attr/_make.py — 동일 소스 재사용"
old_val = linecache.cache.setdefault(filename, linecache_tuple)
if old_val == linecache_tuple:
    break
```

`linecache_tuple`에는 생성한 소스와 파일명 등이 포함. 내용까지 같으면 재사용, 다르면 suffix로 분리. **캐시 삭제나 클래스 생성 중단이 아닌 중복 소스 보관 방지**.

---

## 5. 검증 — 10회 생성해도 캐시 2개 유지

검증 대상은 같은 소스의 캐시 누적 여부. 수십만 번 요청할 필요 없이 Keystone의 실제 `SchemaValidator`를 동일 조건으로 10회 생성해 비교.

**보존된 테스트 결과 — 각 조건은 별도 Python 시험 프로세스**

```text
원본:        2,4,6,8,10,12,14,16,18,20
패치본:      2,2,2,2,2,2,2,2,2,2
설치 수정본: 2,2,2,2,2,2,2,2,2,2
```

**원본은 매번 증가, 수정본은 최초 `__init__`·`__eq__` 소스 2개 재사용.** 전체 linecache 크기가 아닌 해당 Validator 이름의 관련 항목 수.

추가 확인 결과:

- **기능:** 객체 생성·비교·해시, 다른 소스 분리, 동시 클래스 생성, Keystone 스키마 검증 PASS.
- **API:** Keystone discovery·토큰 발급, Nova 하이퍼바이저 조회, Cinder 서비스 조회 성공.

제한된 smoke test이며 전체 OpenStack 회귀 테스트는 아님. 운영의 패치 전후 응답시간 수치는 별도 측정 대상.

??? note "수동 적용과 캐시 확인 명령"
    검증한 대상은 `python3-attrs-20.3.0-7.el9.noarch`. 버전이나 설치 코드가 다르면 동일 수정사항을 무조건 적용하지 않고 차이부터 확인.

    1. `rpm -q`·`rpm -V`로 버전과 변경 여부 확인.
    2. 원본 `_make.py`와 기존 bytecode 백업.
    3. 위 GitHub 변경 커밋을 기준으로 실제 파일 수동 수정.
    4. 문법·기본 기능·관련 캐시 증가 여부 확인.
    5. 승인된 작업 시간에 관련 worker 순차 재기동 후 API 확인.

    **대상 노드에서 버전·파일·문법 확인**

    ```bash
    rpm -q python3-attrs
    rpm -V python3-attrs
    python3 -m py_compile /usr/lib/python3.9/site-packages/attr/_make.py
    ```

    **대상 Python 3.9에서 별도 시험 프로세스 실행**

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

    실행 중인 Keystone worker의 캐시를 읽거나 지우는 명령이 아님. 별도 프로세스에서 관련 항목을 초기화한 뒤 증가 여부 확인.

    `.pyc`는 Python이 생성하는 bytecode이므로 직접 편집하지 않음. 수동 수정 후 `rpm -V`에 소스·bytecode 변경이 표시되는 것은 예상 결과.

---

## 6. 운영 반영과 재발 방지

**재기동은 임시 완화, 백포트는 누적 원인 수정.** 파일만 수정해도 실행 중인 worker의 기존 코드와 캐시는 그대로 남으므로 계획된 재기동 필요.

!!! warning "운영 작업 전 확인"
    관련 서비스는 Keystone을 구동하는 httpd와 Nova·Cinder API 등. 실제 구동 방식에 맞춰 대상 확인, HAProxy drain·노드별 순차 작업·원본 복원 계획 준비. 테스트에서도 worker 종료 지연과 일시적 서비스 실패 이력이 있어 재기동 영향 점검 필요.

수동 변경은 RPM 업데이트·재설치로 덮어써질 수 있음. 장기 운영에는 **수정 이력을 관리하는 사내용 백포트 RPM 또는 배포사 공식 패키지** 사용 검토. 이 글의 수정본은 배포사 공식 RPM이 아님.

최종 운영 확인은 **동일 API의 응답시간 + worker CPU·RSS + 시간이 지난 뒤의 재발 여부**. 재기동 직후의 개선만으로 패치 효과를 확정하지 않음.

Controller C에만 크게 누적된 정확한 운영 이력도 별도 확인 대상. 현재 요청량이 같아도 과거 호출 경로·횟수나 worker 가동시간까지 같다는 뜻은 아님.

---

## 관련 사례와 참고 자료

- [attrs Issue #826](https://github.com/python-attrs/attrs/issues/826): 같은 이름의 동적 클래스 반복 생성 시 성능 저하.
- [attrs 수정 #828](https://github.com/python-attrs/attrs/commit/38580632ceac1cd6e477db71e1d190a4130beed4): 동일 생성 소스의 캐시 재사용.
- [Launchpad #2121607](https://bugs.launchpad.net/nova/+bug/2121607): Caracal 이후 Nova API 시간·메모리 증가, python-attrs로 원인 연결.
- [Ubuntu Jammy 최종 수정 패키지](https://bugs.launchpad.net/nova/+bug/2121607/comments/18): `21.2.0-1ubuntu1`에 단일 수정 백포트. 초기 21.4.0 업그레이드 제안과 구분.
- [Ubuntu 업데이트 배포 완료](https://bugs.launchpad.net/nova/+bug/2121607/comments/17): 2025년 12월 9일 기록.
- [백포트 코드의 attrs MIT 라이선스](../assets/openstack-attrs-linecache/UPSTREAM_LICENSE.txt).
