---
title: "글 제목"
summary: "목록과 글 상단에 보일 짧은 명사형 요약"
date: 2026-10-07
category: 트러블슈팅
tags:
  - Linux
sample: true
---

`category`는 다음 중 하나.

- 트러블슈팅
- 구축설계
- 자동화 CI/CD
- 성능 튜닝

태그는 기술 주제. 예: `OpenStack`, `Linux`, `Network`, `Storage`, `Observability`, `CI/CD`.

본문은 `docs/` 아래 하위 폴더에 둠. 폴더 이름은 파일 정리용이고, 홈 목록은 위 메타데이터로 생성. 대표 글은 `featured: true`를 한 글에만 둠.

문체는 짧은 개조식·명사형. 조건, 이유, 부정, 주의는 빼지 않음. 미확인을 완료처럼 쓰지 않음. 명령, 코드, 로그, 인용은 원문 유지.

```bash
echo "sample"
```

!!! note "확인"
    미실행 명령의 출력은 결과로 적지 않음
