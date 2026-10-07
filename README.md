# Fieldnotes

개인 기술 기록을 MkDocs로 만들어 GitHub Pages에 올리는 저장소다.

- 사이트: https://wjdxotjd112.github.io/tech-notes/
- 저장소: https://github.com/wjdxotjd112/tech-notes

화면은 MkDocs Material을 바탕으로 Option B 저널 배치에 맞춰 고쳤다. Material 테마는 MIT 라이선스다. 글 라이선스는 정하지 않았다.

## 폴더

| 경로 | 역할 |
| --- | --- |
| `docs/` | 공개할 Markdown과 이미지 |
| `overrides/` | 홈·글 화면 템플릿 |
| `docs/stylesheets/`, `docs/javascripts/` | 화면과 목록 필터 |
| `hooks/journal.py` | 글 메타데이터로 목록을 만든다 |
| `mkdocs.yml` | 사이트 이름, 주소, 테마, 확장 |
| `templates/post.md` | 새 글에 복사할 메타데이터 예시 |
| `.github/workflows/pages.yml` | 검사와 Pages 배포 |

`site/`와 `.venv/`는 빌드 결과와 로컬 환경이라 커밋하지 않는다.

## 로컬에서 보기

```bash
uv sync
uv run mkdocs serve
```

브라우저에서 `http://127.0.0.1:8000` 을 연다. 검사만 하려면 `uv run mkdocs build --strict` 를 실행한다.

## 새 글

1. `templates/post.md`를 `docs/` 아래 알맞은 폴더에 복사한다.
2. 파일명은 `YYYY-MM-DD-짧은-이름.md`로 한다. 치트시트는 주제가 드러나는 이름이면 된다.
3. 메타데이터를 고치고 본문을 작성한다.
4. 커밋한 뒤 `main`에 푸시한다.

폴더와 카테고리 예:

| 폴더 | `category` |
| --- | --- |
| `docs/troubleshooting/` | 트러블슈팅 |
| `docs/labs/` | 구축·실습 |
| `docs/design/` | 개념·설계 |
| `docs/automation/` | 자동화·CI/CD |
| `docs/cheatsheets/` | 치트시트 |

```yaml
title: "글 제목"
summary: "목록에 보일 요약"
date: 2026-10-07
category: 트러블슈팅
tags:
  - Linux
sample: false
```

- `date`는 `YYYY-MM-DD`다. 홈 목록은 이 값으로 최신 글이 위로 온다.
- `category`는 위 표의 다섯 값 중 하나다.
- `tags`는 기술 주제다. 예: OpenStack, Linux, Network, Storage, Observability, CI/CD.
- 홈 대표 글은 `featured: true`인 글이다. 한 글에만 둔다.
- `sample: true`는 예시 글 표시다. 실제 기록에는 뺀다.

이미지를 `docs/assets/`에 두고 Markdown에서 상대 경로로 연결한다.

```markdown
![설명](../assets/example.png)
```

## 사이트 문구

제목과 주소는 `mkdocs.yml`의 `site_name`, `site_url`이다. 홈의 큰 제목과 소개 문장은 `overrides/partials/fn-home.html`이다. 상단 메뉴는 `overrides/partials/fn-header.html`이다.

## 배포

`main`에 푸시되면 GitHub Actions가 의존성을 설치하고 strict 빌드를 한 뒤, 성공했을 때만 `site/`를 Pages에 배포한다. Actions 탭에서 워크플로 `pages`를 연다. 실패하면 빨간 job의 로그를 본다. Pull Request는 빌드만 하고 배포하지 않는다.

글을 고치려면 해당 `.md`를 수정하고 다시 푸시한다. 이전 정상 내용으로 되돌릴 때도 파일을 그 내용으로 맞춘 새 커밋을 푸시한다. 이미 공개된 `main` 이력을 강제로 다시 쓰지 않는다.

## 공개 전 확인

- 고객사, 사내 호스트명, 사내 URL, 계정, 토큰이 없는가
- IP를 적는다면 문서용 대역(`192.0.2.x`, `198.51.100.x`, `203.0.113.x`)만 쓰는가
- 실행하지 않은 명령의 출력을 결과처럼 적지 않았는가
