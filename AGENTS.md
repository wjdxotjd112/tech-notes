# SkillNotes 작업 시작

이 저장소에서 글을 쓰거나 사이트를 올릴 때 아래를 읽는다.

- [작성 규칙](guides/WRITING.md)
- [로컬 운영](guides/OPERATIONS.md)
- [배포](guides/DEPLOYMENT.md)
- [템플릿](templates/post.md)

범위는 이 저장소다. 다른 저장소, 전역 설정, 테마·패키지 업그레이드는 요청 없이 하지 않는다.

글 작성·수정 요청이면 자료를 읽고 분류·제목·구성·공개 범위와 게시 여부를 먼저 제안한다. 본문 작성 전에 사용자 답변을 기다린다. 승인 후 [배포](guides/DEPLOYMENT.md)의 순서로 검사·커밋·푸시·배포 확인까지 진행하며 같은 범위의 승인을 반복하지 않는다. 이미 이 제안을 승인받았다면 다시 묻지 않는다. 설명, 검토, 초안만 요청이면 게시하지 않는다.

Cursor는 `.cursor/rules/skillnotes.mdc`, Claude는 `CLAUDE.md`가 이 파일을 가리킨다. 다른 workspace의 개인 블로그 요청은 AI-Setup의 전역 `skillnotes-publish` 스킬에서 이 저장소로 연결한다. [자동 시작 설정](guides/WRITING.md#자동-시작) 참고.
