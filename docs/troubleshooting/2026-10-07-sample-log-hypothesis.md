---
title: "샘플: 증상과 가설을 나누어 적는 법"
summary: 화면 확인용 샘플이다. 지연 시간이나 장애 규모는 넣지 않고, 기록에 남길 질문만 구분한다.
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

이 글은 사이트의 글 목록, 대표 영역, 검색을 확인하려고 만든 샘플이다. 특정 시스템에서 측정한 결과가 아니다.

로그를 열기 전에 세 줄을 먼저 적는다.

1. 지금 보이는 증상은 무엇인가.
2. 그 증상으로 의심하는 지점은 어디인가.
3. 그 의심을 맞거나 틀리게 만들 확인 한 가지는 무엇인가.

```text
symptom    api timeout
hypothesis name lookup stalls
check      resolver config and one query
```

확인 한 가지가 끝나면 결과만 다음 줄에 적는다. 맞는 원인으로 바로 올리지 않는다.

![증상, 가설, 확인을 나란히 둔 샘플 그림](../assets/sample-flow.svg)
