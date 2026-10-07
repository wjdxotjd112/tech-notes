# 코드·그림 복사 예제

[작성 기준](../guides/FORMATTING.md). 필요한 예제만 복사하고 설명·대상·값은 실제 자료로 변경. 모든 글에 코드나 그림을 강제로 추가하지 않음.

## 조회 명령과 출력

````markdown
실행 위치: 해당 Linux 노드. 목적: 루트 파일시스템의 사용량 확인.

```bash
df -h /
```

출력 확인: 사용률과 남은 공간을 읽고 증상과 함께 판단. 실제 출력이 없으면 로그나 수치를 만들지 않음.
````

출력이 있는 경우 명령과 별도의 `text` 펜스에 원문 발췌. “실제 출력 — 사용자 제공” 또는 “예상 출력 예시”처럼 근거 표시.

## 설정 파일 일부

````markdown
파일: `mkdocs.yml`. 아래는 복사 버튼 설정 예시.

```yaml title="mkdocs.yml — 일부"
theme:
  features:
    - content.code.copy
```
````

## 특정 코드 줄 설명

````markdown
설명용 코드 예시. 생성된 번호는 원본 파일의 줄 번호가 아님.

```python title="조건 확인 예시" linenums="1" hl_lines="2"
def has_errors(errors):
    return bool(errors)
```
````

## 단순 처리 순서

````html
<figure class="flow">
  <ol>
    <li>요청 수신</li>
    <li>데이터 검증</li>
    <li>응답 반환</li>
  </ol>
  <ul>
    <li>그림 1. 단순 처리 순서의 개념도. 실제 호출 추적 결과는 아님</li>
  </ul>
</figure>
````

## SVG 또는 화면 증적

````markdown
[![요청 수신에서 검증을 거쳐 응답을 반환하는 흐름](../assets/example/diagram.svg)](../assets/example/diagram.svg)

그림 1. 요청 처리 순서의 개념도. 실제 호출 추적 결과는 아님.

[원본 그림 열기](../assets/example/diagram.svg)
````

예시 경로를 실제 파일 경로로 교체. 복잡한 구성은 [SVG 템플릿](assets/diagram.svg)을 글별 자산 폴더로 복사해 수정.

## 주의박스

````markdown
!!! warning "실행 주의"
    서비스 재시작 시 처리 중인 요청에 영향 가능. 작업 대상과 복구 방법 확인 후 진행.
````
