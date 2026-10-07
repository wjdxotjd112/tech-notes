---
title: "샘플: main에 푸시하면 사이트가 갱신되는 흐름"
summary: 이 저장소의 GitHub Actions가 빌드와 Pages 배포를 나누는 방식을 적는다.
date: 2026-10-04
category: 자동화·CI/CD
tags:
  - CI/CD
sample: true
---

이 글은 저장소에 들어 있는 워크플로 파일을 기준으로 한 설명이다. 특정 실행이 성공했는지는 GitHub의 Actions 기록으로 확인한다. 이 문단 자체가 배포 성공 기록은 아니다.

## 순서

1. `main`에 푸시하거나 Actions에서 수동 실행을 고른다.
2. Ubuntu Runner가 의존성을 설치하고 `mkdocs build --strict`를 실행한다.
3. 빌드가 만든 `site/`만 Pages 아티팩트로 올린다.
4. 빌드가 성공하고 대상이 `main`일 때만 배포 job이 실행된다.

Pull Request에서는 빌드와 검증만 하고 배포 job은 조건에 걸려 실행되지 않는다.

## 워크플로가 보는 것

배포에 개인 토큰을 저장하지 않는다. 배포 job은 GitHub가 넘겨주는 `GITHUB_TOKEN`과 Pages 권한만 쓴다.

```yaml
permissions:
  contents: read
```

배포 job만 `pages: write`와 `id-token: write`를 추가로 가진다. 빌드가 실패하면 배포 job은 `needs` 때문에 시작하지 않는다.

## 볼 위치

저장소의 Actions 탭에서 워크플로 이름 `pages`를 연다. 실패한 단계의 로그에 빌드 경고나 Pages 설정 오류가 남는다. 사이트 주소와 저장소 주소는 다르다.

- 사이트: `https://wjdxotjd112.github.io/tech-notes/`
- 저장소: `https://github.com/wjdxotjd112/tech-notes`
