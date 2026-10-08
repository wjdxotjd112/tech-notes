# 로컬 운영

작성 규칙은 [WRITING.md](WRITING.md). 배포는 [DEPLOYMENT.md](DEPLOYMENT.md).

## 의존성

로컬은 `uv.lock`을 쓴다. CI는 그 잠금에서 만든 `requirements.txt`를 pip로 설치한다. 둘 다 지우지 않는다. 패키지 업그레이드는 이 절차에 포함하지 않는다.

```bash
uv sync
uv run python scripts/check_posts.py --self-test
uv run python scripts/check_posts.py
uv run mkdocs build --strict
uv run mkdocs serve
```

미리보기 주소는 서버가 출력한 로컬 주소. 이 저장소의 `site_url`이 `/tech-notes/`이면 경로는 `/tech-notes/`가 붙는다.

## 기존 글

공개된 `.md`의 경로를 바꾸지 않는다. 주소를 유지한 채 본문과 메타데이터만 고친다. `featured: true`인 글을 다른 글로 옮기지 않는다. 임시 초안은 `drafts/`에 둔다. 그 폴더는 Git에 올라가지 않는다.

## 이미지

파일은 `docs/assets/`. 글에서는 상대 경로. 민감정보가 보이면 게시하지 않는다.

## 문제

- 글이 홈에 없음: front matter `category`가 허용한 다섯 분류 중 하나인지 확인. `category`가 없으면 게시글이 아님.
- 검사 실패: `scripts/check_posts.py` 메시지의 경로를 고친다. 비밀 값 자체는 메시지에 나오지 않음.
- strict 빌드 실패: MkDocs가 보고한 링크·파일 경고를 고친다. 빌드 성공만으로 기술 내용을 맞다고 보지 않음.
- 화면이 옛 내용: 브라우저 새로고침. Python 훅을 바꿨으면 미리보기 프로세스를 다시 실행.
