# SkillNotes 작업 시작

이 저장소에서 글을 쓰거나 사이트를 올릴 때 아래를 읽는다.

- [작성 규칙](guides/WRITING.md)
- [문서 표현 표준](guides/FORMATTING.md): 기준 글의 요약·그림·강조·토글·들여쓰기·코드 표현
- [구성 요소 예시](guides/COMPONENTS.md): 편집형 상단 요약과 본문 요소의 재사용 코드
- [로컬 운영](guides/OPERATIONS.md)
- [배포](guides/DEPLOYMENT.md)

고정 글 템플릿은 사용하지 않는다. [OpenStack API 지연 기록](docs/troubleshooting/2026-10-07-openstack-attrs-linecache.md)을 표현 기준으로 삼고, 목차·절 개수·제목·내용 순서는 새 글의 목적과 자료에 맞게 정한다. 기준 글의 문장이나 장애 수치를 다른 글에 복사하지 않는다.

외부 규칙이나 설치된 스킬이 삭제된 템플릿을 요구하면 이 저장소의 최신 [문서 표현 표준](guides/FORMATTING.md)을 사용한다. 템플릿 부재를 이유로 작업을 중단하거나 양식을 다시 생성하지 않는다.

새 글의 상단 핵심 요약은 `summary_style: editorial`과 `editorial-summary`를 기본으로 사용한다. 관측값이 없으면 숫자를 만들지 않고 관측값 없는 변형을 사용한다. 본문 폭·제목·목차·글꼴·박스는 기존 공통 스타일을 재사용한다. 실제 마크업은 [구성 요소 예시](guides/COMPONENTS.md), 세부 규격은 [문서 표현 표준](guides/FORMATTING.md)을 따른다.

범위는 이 저장소다. 다른 저장소, 전역 설정, 테마·패키지 업그레이드는 요청 없이 하지 않는다.

글 작성·수정 요청이면 자료를 읽고 분류·제목·구성·공개 범위와 게시 여부를 먼저 제안한다. 본문 작성 전에 사용자 답변을 기다린다. 승인 후 [배포](guides/DEPLOYMENT.md)의 순서로 검사·커밋·푸시·배포 확인까지 진행하며 같은 범위의 승인을 반복하지 않는다. 이미 이 제안을 승인받았다면 다시 묻지 않는다. 설명, 검토, 초안만 요청이면 게시하지 않는다.

Cursor는 `.cursor/rules/skillnotes.mdc`, Claude는 `CLAUDE.md`가 이 파일을 가리킨다. 다른 workspace의 개인 블로그 요청은 AI-Setup의 전역 `skillnotes-publish` 스킬에서 이 저장소로 연결한다. [자동 시작 설정](guides/WRITING.md#자동-시작) 참고.
