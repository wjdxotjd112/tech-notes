---
title: "샘플: 증상과 가설을 나누어 적는 법"
summary: 화면 확인용 샘플. 지연 시간·장애 규모 없이, 기록할 질문만 구분
date: 2026-10-07
category: 트러블슈팅
tags:
  - Linux
  - Observability
featured: true
sample: true
figure_label: SAMPLE NOTES / 01
figure_lines:
  - "symptom"
  - "  → hypothesis"
  - text: "  → check one thing"
    em: true
---

글 목록, 대표 영역, 검색 확인용 샘플. 특정 시스템의 측정 결과는 아님.

로그를 열기 전, 아래 세 줄 기록.

1. 현재 증상
2. 그 증상으로 의심하는 지점
3. 그 의심을 가릴 확인 한 가지

```text
symptom    api timeout
hypothesis name lookup stalls
check      resolver config and one query
```

확인 한 가지 후, 결과만 다음 줄에 기록. 맞는 원인으로 바로 올리지 않음.

<figure class="flow">
  <ol>
    <li>증상</li>
    <li>가설</li>
    <li>확인</li>
  </ol>
  <ul>
    <li>증상, 가설, 확인 순서. 측정값은 없음</li>
  </ul>
</figure>
