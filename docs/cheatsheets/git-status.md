---
title: "샘플: 상태를 다시 볼 때 쓰는 Git 명령"
summary: 작업 트리와 최근 커밋 확인용 명령 모음
date: 2026-10-03
category: 구축설계
tags:
  - Linux
  - Automation
sample: true
---

공개용 샘플. 사내 원격 주소나 계정은 미수록.

| 상황 | 명령 | 보는 것 |
| --- | --- | --- |
| 지금 바뀐 파일 | `git status` | 추적 여부, 스테이징 여부 |
| 내용 차이 | `git diff` | 아직 스테이징하지 않은 변경 |
| 최근 기록 | `git log --oneline -5` | 최근 5개 커밋 제목 |
| 원격과 차이 | `git status -sb` | 현재 브랜치가 앞섰는지 |

브랜치 삭제나 이력 수정 명령은 미수록. 실수한 글은 파일 수정 후 새 커밋으로 푸시하면 사이트 재빌드. 직전 정상 커밋으로 되돌릴 때도 강제 푸시 대신 되돌리는 커밋 생성.

```bash
git status -sb
git diff
git log --oneline -5
```
