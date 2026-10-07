# 문서 구성 요소 예시

[문서 표현 표준](FORMATTING.md)의 구현 예시. 글 전체의 목차나 절 수를 정하는 템플릿이 아님. 필요한 블록만 재사용하고 예시 문장은 새 글의 실제 자료로 교체. 문서 자체는 블로그 글 목록에 게시되지 않음.

## 편집형 핵심 요약

새 글의 front matter에 다음 속성 추가. 제목·분류·날짜·태그 등 나머지 필수 항목은 [작성 규칙](WRITING.md#메타데이터) 참고.

```yaml
summary_style: editorial
```

첫 본문에 아래 HTML 배치. 숫자 없는 예시가 기본이며, 측정 자료가 없는 글에도 사용 가능. 순수 HTML 안에서는 `<strong>`과 `<a>` 사용. 요약 ID는 페이지 안에서 유일하게 유지.

```html
<section class="editorial-summary editorial-summary--text-only" aria-labelledby="editorial-summary-title">
  <div class="editorial-summary-layout">
    <div class="editorial-summary-copy">
      <span class="editorial-summary-label">이 기록의 결론</span>
      <h2 id="editorial-summary-title" class="editorial-summary-title">확인한 핵심 판단을 한 문장으로.</h2>
      <p>어떤 문제나 목적에서 출발했는지 설명. 제공된 근거에서 무엇을 확인했는지 자연스럽게 연결.</p>
    </div>
  </div>
  <p class="editorial-summary-result"><span>어떤 조치나 선택을 했고 <strong>어디까지 확인했는지</strong> 짧게 설명.</span></p>
</section>
```

### 관측값이 있는 경우

확인된 수치가 있으면 바깥 `section`의 `editorial-summary--text-only`만 제거. `editorial-summary-copy` 다음에 아래 `aside`를 추가해 `editorial-summary-layout` 안의 두 번째 자식으로 배치. 관측값 1개면 안쪽 `div` 1개만 사용. 라벨은 대상·조건, 값은 수치·단위 역할. 수치는 본문에 근거와 측정 조건 설명.

```html
<aside class="editorial-summary-facts" aria-label="주요 관측값">
  <div>
    <span class="editorial-fact-label">측정 대상과 조건</span>
    <p class="editorial-fact-value">확인한 수치<span>단위</span></p>
  </div>
</aside>
```

실제 완성 예시는 [기준 글의 첫 본문](../docs/troubleshooting/2026-10-07-openstack-attrs-linecache.md). 그 글의 `2초 이상`, `6–7초`는 다른 글에 복사하지 않음. 그림·강조 박스를 요약 안에 추가하지 않고 필요한 설명은 본문으로 이동.

## 하위 제목과 들여쓴 설명

`markdown="1"`과 빈 줄 유지. HTML 안에서도 목록·코드·표가 Markdown으로 변환돼야 함. 하위 번호는 해당 글의 실제 순서로 작성.

```markdown
<p class="subsection-title"><strong>2-1. 확인할 대상</strong></p>

<div class="section-body" markdown="1">

설명의 목적과 확인 근거.

- 서로 병렬인 사실이나 이유.
- 같은 설명 단위의 다음 사실.

</div>
```

## 분석 토글

`summary`는 닫혀 있어도 의미를 알 수 있는 질문. 중요한 결론은 토글 밖에도 제시. 기본적으로 닫힌 상태이며 키보드로 조작 가능한 HTML `details` 사용.

```markdown
<details class="analysis-toggle" markdown="1">
<summary>2-2. 확인하려는 가설이 증상을 설명할까?</summary>

**의심한 이유:** 제공된 사실에 근거한 확인 목적.

**확인:** 실제 사용한 방법과 결과. 미실행이면 예상 결과와 구분.

**판단:** 확인 범위 안의 결론과 다음 조사 방향.

</details>
```

## 결론·핵심·주의 박스

유형은 정보 역할로 선택. 네 박스를 모든 글에 의무적으로 추가하지 않음. 안쪽 내용은 4칸 들여쓰기 유지.

```markdown
!!! danger "결론 — 근거로 확인한 원인"
    실제 원인과 이를 뒷받침하는 관측. 미확인 가설은 확정 결론으로 표시하지 않음.

!!! tip "핵심 — 기억할 판단"
    구성 선택의 이유나 검증에서 확인할 동작.

!!! warning "실행 전 확인"
    조치의 영향·조건·주의.

!!! note "보충 설명"
    읽는 데 필요한 짧은 보충 정보.
```

긴 보조 절차는 `??? note "확인 명령과 상세 출력"`로 접을 수 있음. 핵심 결과와 실행 전 주의는 접힌 부분에만 두지 않음.

## 환경 표와 구성도 묶음

환경 영역은 작은 본문·표 글자 사용. 구성도 둘이 실제로 필요한 경우만 두 열 배치. 이미지는 새 글의 자산 경로로 교체하고 링크의 SVG 원본도 함께 제공.

````markdown
<div class="environment-section" markdown="1">

| 항목 | 환경 |
| --- | --- |
| 관련 제품·패키지 | 확인된 버전 |

<div class="environment-grid" markdown="1">

<div markdown="1">

**구성 요소와 연결**

[![구성 요소와 요청 전달 방향](../assets/글-slug/topology.svg){ .architecture-diagram }](../assets/글-slug/topology.svg)

</div>

<div markdown="1">

**요청 처리 흐름**

[![요청부터 결과까지의 순서](../assets/글-slug/request-flow.svg){ .architecture-diagram }](../assets/글-slug/request-flow.svg)

</div>

</div>

</div>
````

노드·화살표·글자·여백 규격은 [그림 기준](FORMATTING.md#7-그림을-선택하는-기준). SVG 파일을 위 경로에 실제로 만들고 한글·라벨·선을 PC와 모바일에서 확인. 기준 자산의 내용과 환경을 그대로 복사하지 않음.

## 짧은 처리 흐름

분기 없는 짧은 순서에만 사용. 여러 노드나 병렬 경로가 있으면 SVG로 작성.

```html
<figure class="flow" aria-label="설명할 처리 순서">
  <ol>
    <li>첫 단계</li>
    <li>다음 단계</li>
    <li>결과</li>
  </ol>
</figure>
```

## 코드와 출력

명령·출력은 별도 펜스. 파일 구분은 `title`, 핵심 줄은 `hl_lines`. 실행 위치·교체할 값·주의는 펜스 밖에서 설명. 예시는 저장소 변경사항을 조회하는 명령이며 실제 실행 결과를 의미하지 않음.

````markdown
```bash title="저장소 상태 확인" hl_lines="2"
git status --short
git diff --stat
```
````

복사 버튼은 테마가 생성하므로 별도 버튼이나 스크립트 추가 불필요. 표·코드의 긴 줄은 해당 영역만 가로 스크롤. 새 글에 `<style>`·인라인 `style`·외부 폰트·임의 색상 추가 없이 공통 클래스 재사용.
