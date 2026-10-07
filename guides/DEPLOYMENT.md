# 배포

로컬 준비는 [OPERATIONS.md](OPERATIONS.md). 글 내용은 [WRITING.md](WRITING.md).

## 게시 순서

“블로그에 정리해줘”, “글로 작성해줘”, “기술 노트로 올려줘”이면 아래 순서로 진행한다. 작성 전 검토를 한 번 받고 승인 후에는 같은 범위의 승인을 반복하지 않는다.

1. [AGENTS.md](../AGENTS.md), 이 문서, 비슷한 기존 글을 확인.
2. 자료를 검토하고 분류·제목·구성·공개 범위·게시 여부를 제안. **본문 작성 전에 답변을 기다림.** 승인된 제안이 이미 있으면 반복하지 않음. 초안·검토 요청은 게시 제외.
3. [templates/](../templates/post.md)의 해당 파일로 작성. 해당 없는 절과 자리표시자는 제거.
4. 근거, 익명화, 문체를 검토. 이미지의 민감정보도 확인.
5. `uv run python scripts/check_posts.py --self-test`, `uv run python scripts/check_posts.py`, `uv run mkdocs build --strict`.
6. 이번 글과 직접 관련된 diff만 확인.
7. 그 파일만 커밋하고 `main`에 푸시. force push 없음.
8. 그 커밋의 GitHub Actions `pages`가 끝날 때까지 확인.
9. 워크플로가 성공한 뒤 게시 URL과 제목·분류·요약이 보이는지 확인.
10. 변경 파일, 검사 결과, 커밋, 배포, 남은 한계를 짧게 보고.

CI는 `python -m pip install -r requirements.txt` 다음 같은 검사와 `mkdocs build --strict`를 실행한다. 로컬 `uv sync`와 CI pip의 입력 파일은 다르고, 패키지 목록은 `uv.lock`에서 `requirements.txt`로 내보낸 같은 세트다.

`main` 푸시만 배포한다. Pull Request는 빌드와 검사만 하고 배포하지 않는다. 검사나 빌드가 실패하면 배포 job이 실행되지 않는다. 배포 확인에 실패하면 게시 완료로 보고하지 않는다.

## 멈추는 경우

- 공개 범위가 불명확하거나 민감정보가 남음
- 핵심 사실이 없어 결론을 만들어야 함
- 검사 또는 빌드 실패
- 권한 부족, 해결되지 않은 충돌
- 초안만, 검토만, 게시 보류

단순 설명이나 자료 검토는 게시로 확대하지 않는다. 브랜치 보호를 해제하지 않는다.

## 실패와 복구

Actions의 `pages`에서 빨간 job 로그를 본다. 원인을 고친 새 커밋을 `main`에 푸시한다. 이미 공개된 `main` 이력을 강제로 다시 쓰지 않는다. 이전 정상 내용으로 되돌릴 때도 그 내용의 새 커밋을 푸시한다.

배포가 성공해도 빌드 성공은 기술 내용이 맞다는 뜻이 아니다. 게시 URL에서 글이 열리는지 따로 확인한다.
