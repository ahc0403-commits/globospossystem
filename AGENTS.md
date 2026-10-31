> **모든 명령 시작 전 필수 선행 확인**

계획 수립·조사·구현·검증·운영 배포 등 모든 사용자 작업과 명령을 시작하기 전에
[공통 작업 원칙](docs/WORKING_PRINCIPLES_KO.md), [프로젝트 지침](CLAUDE.md),
현재 작업 경로에 적용되는 `AGENTS.md`·`CLAUDE.md`·`claude.md`의 최신 본문을
먼저 읽고 따른다. 공통 작업 원칙이나 필수 프로젝트 지침이 없거나 읽을 수 없으면
변경 작업을 시작하지 않고 정확한 파일 경로와 차단 이유를 보고한다.
선택적 문서와 대소문자 별칭은 존재하고 적용되는 경우에 확인한다.

이 요구는 에이전트가 따라야 하는 문서 지침이다. 이 문서 적용으로 셸 hook,
sandbox, CI 또는 배포 스크립트에 기술적 강제가 추가된 것은 아니다.

<INSTRUCTIONS>
Read `docs/WORKING_PRINCIPLES_KO.md` first, then root `CLAUDE.md` and the
instruction files applicable to the current path before every task or command.
Follow the global loading rules for other applicable instruction files.
If a required instruction file is missing or unreadable, stop before changes and
report its exact path and blocker. Optional absent aliases do not require copies.
The root `CLAUDE.md` is the single canonical project instruction file.
Do not create a separate `claude.md` copy; read case-only aliases once.
Follow platform instruction precedence and the user's explicit requests.
Preserve tracked and untracked uncommitted workspace changes and follow the
production gates in `CLAUDE.md`.
Use GitHub for authorized commits/pushes and review. Work in the approved existing
Codex Cloud workspace and its supported isolated environments; do not move
verification to the user's Mac or another VM without authorization. The owner's
cloud policy in root `CLAUDE.md` supersedes historical local-only requirements.
Apply the global final-SHA evidence contract; GitHub Actions/runner success is not required.
Retain clean exact-main, official deployment and operational gates; report executable dependencies without bypassing them.
</INSTRUCTIONS>
