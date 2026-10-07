---
title: "샘플: 이 저장소를 로컬에서 미리 보는 명령"
summary: 프로젝트 가상환경에서 MkDocs strict 빌드와 미리보기를 실행하는 짧은 실습 메모다.
date: 2026-10-05
category: 구축·실습
tags:
  - Linux
sample: true
---

이 글은 공개 샘플이다. 다른 서버를 구축한 기록이 아니라, 이 저장소 폴더에서 사이트를 미리 볼 때 쓰는 명령만 적는다.

## 준비

Python 3.12와 `uv`가 있다고 가정한다. 전역 인터프리터에 MkDocs를 설치하지 않는다.

```bash
uv sync
uv run mkdocs build --strict
uv run mkdocs serve
```

`serve`는 기본으로 `http://127.0.0.1:8000` 에서 보고, 글을 저장하면 다시 읽어 온다. 인터넷에 공개되는 주소는 GitHub Pages 쪽이다.

## 확인

빌드가 끝나면 `site/` 가 생긴다. 이 폴더는 Git에 넣지 않는다. 경고가 하나라도 있으면 `--strict` 때문에 빌드가 실패하고, 실패한 빌드는 Pages로 나가지 않게 워크플로를 짜 두었다.

!!! note "범위"
    여기 있는 명령은 이 저장소의 미리보기용이다. 운영 중인 다른 문서 사이트에 그대로 적용했다는 뜻은 아니다.
