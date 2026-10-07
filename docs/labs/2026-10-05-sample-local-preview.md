---
title: "샘플: 이 저장소를 로컬에서 미리 보는 명령"
summary: 프로젝트 가상환경에서 MkDocs strict 빌드와 미리보기를 실행하는 메모
date: 2026-10-05
category: 구축설계
tags:
  - Linux
sample: true
---

공개 샘플. 다른 서버 구축 기록이 아니라, 이 저장소의 로컬 미리보기 명령만 수록.

## 준비

Python 3.12와 `uv` 사용 가정. 전역 인터프리터에는 MkDocs 미설치.

```bash
uv sync
uv run mkdocs build --strict
uv run mkdocs serve
```

`serve` 기본 주소 `http://127.0.0.1:8000`. 글 저장 시 다시 읽음. 인터넷 공개 주소는 GitHub Pages.

## 확인

빌드 후 `site/` 생성. 이 폴더는 Git 미포함. 경고가 있으면 `--strict`로 빌드 실패, 실패 빌드는 Pages 미배포.

!!! note "적용 범위"
    - 이 저장소의 미리보기용 명령
    - 다른 운영 문서 사이트에 적용한 결과는 아님
