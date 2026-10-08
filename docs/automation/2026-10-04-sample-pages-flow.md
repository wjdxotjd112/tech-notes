---
title: "샘플: main에 푸시하면 사이트가 갱신되는 흐름"
summary: 이 저장소 GitHub Actions의 빌드와 Pages 배포 분리 방식
date: 2026-10-04
category: 자동화 CI/CD
tags:
  - Automation
sample: true
---

저장소 워크플로 파일 기준 설명. 특정 실행의 성공 여부는 GitHub Actions 기록으로 확인. 이 문단은 배포 성공 기록이 아님.

## 순서

1. `main` 푸시 또는 Actions 수동 실행
2. Ubuntu Runner에서 의존성 설치 후 `mkdocs build --strict`
3. 빌드된 `site/`만 Pages 아티팩트로 업로드
4. 빌드 성공이고 대상이 `main`일 때만 배포 job 실행

Pull Request는 빌드와 검증만 수행. 배포 job은 조건에 따라 미실행.

## 워크플로가 보는 것

배포에 개인 토큰 미저장. 배포 job은 GitHub가 넘겨주는 `GITHUB_TOKEN`과 Pages 권한만 사용.

```yaml
permissions:
  contents: read
```

배포 job만 `pages: write`와 `id-token: write` 추가. 빌드 실패 시 배포 job은 `needs`로 미시작.

## 볼 위치

저장소 Actions 탭에서 워크플로 `pages` 확인. 실패 단계 로그에 빌드 경고나 Pages 설정 오류. 사이트 주소와 저장소 주소는 별개.

- 사이트: `https://wjdxotjd112.github.io/tech-notes/`
- 저장소: `https://github.com/wjdxotjd112/tech-notes`
