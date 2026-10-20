# 구매 PR 결재함 운영 반영 및 실계정 검증

확인 완료: 2026-10-15T14:26:02.412117+07:00 (베트남 시각).

운영 주소: [GLOBOS POS](https://globospossystem.vercel.app).
배포 커밋: `fd522b41efd0525aa8b62af8fd96140cd1f2ca73`.
[수정 PR #574](https://github.com/ahc0403-commits/globospossystem/pull/574)는 병합됐다.

## 실제 계정 검증 결과

| 계정 | 실제 로그인 후 운영 화면 | 결과 |
|---|---|---|
| bunsik_sm1 | 기본 `/admin`의 PR 결재함 | 미결 14 · 결재 가능 14 · 보류 0 |
| bt_pr1 | `/inventory-orders`의 구매요청 관리 | 권한 오류 없이 미결 요청 16건 표시 |

운영 Auth에 기존 비밀번호로 로그인한 뒤 실제 브라우저에서 두 화면을 확인했다.
별도의 API 검증도 배포 전후 모두 통과했다. 매니저는 목록과 승인 가능한 상세,
요청자는 카탈로그와 PR 목록을 조회했다. 요청자의 `can_receive=false`도 확인했다.
비밀번호 재설정, PR 생성, 실제 승인·발주·입고 명령은 실행하지 않았다.

## 반영 내용과 배포 근거

매니저 기본 화면에 PR 결재함과 영구 메뉴를 연결했다. 기존 탭과 명시적인 탭
링크를 유지했다. 카탈로그 조회는 수령 권한과 분리하고 현재 역할·매장 접근을
검사한다. 품목별 역할 재조회는 이미 읽은 역할 값 재사용으로 바꿨다.

- [운영 커밋의 필수 전체 CI 통과](https://github.com/ahc0403-commits/globospossystem/actions/runs/38695467168).
- 공식 `scripts/deploy_pos_production.sh --db-only`로 migration
  `20261015070000` 적용·자체 검증·원격 이력 존재 확인 완료.
- 두 실제 계정 API 검증 및 후보 앱의 로그인부터 화면 조회까지 확인 후,
  같은 스크립트의 `--web-only`로 운영 웹 배포 완료. 검사 생략 옵션을 사용하지 않았다.
- 운영 HTTP 확인과 배포 스크립트의 매니저 로그인 검사가 통과했다.
- Vercel `dpl_HzpEPfsw5NiRdf9WJG7RtKPsznab`은 READY이며 운영 별칭과 위 커밋을 확인했다.
- 배포 후 운영 주소에서 두 계정의 실제 로그인·화면 조회와 API 검증을 다시 완료했다.

관련 Flutter/라우팅, 구매 SQL·권한·입고·동시성 검사와 웹 빌드를 검증했다.
전체 로컬 검사에서 발견된 기존 macOS 시각 기준 차이 8건은 변경 전 소스에서도
동일하게 재현됐다. 기준 이미지를 변경하지 않았으며 Linux의 필수 전체 CI는 통과했다.

## 실제 API 측정

| 계정 | HTTP 호출 수 | 응답 합계 bytes | 호출 경과시간 합계 ms |
|---|---:|---:|---:|
| bunsik_sm1 | 6 | 319,784 | 1880.97 |
| bt_pr1 | 5 | 179,669 | 1510.71 |

위 수치는 로그인·프로필·카탈로그·PR 목록·선택 상세·로그아웃 중 해당 계정에
필요한 호출을 포함한다. 매니저 목록은 14건, 요청자 목록은 16건을 한 페이지로
반환했다. 화면 페이지 크기는 20건이며 품목별 원격 호출을 추가하지 않았다.
실제 네트워크가 포함된 단일 검증 세션 측정이며 부하 시험이나 성능 개선 비율을
뜻하지 않는다. 서버 내부 실행 계획과 앱 메모리는 이 운영 측정에 포함하지 않았다.

## 증거 파일

- [배포 전 실제 계정 API 검증](evidence/procurement_home_20261015/before_web_account_checks.json)
- [배포 후 실제 계정 API 검증](evidence/procurement_home_20261015/after_web_account_checks.json)
- [배포 전 브라우저 검증](evidence/procurement_home_20261015/browser_checks_before_web.json)
- [운영 브라우저 검증](evidence/procurement_home_20261015/browser_checks_after_web.json)
- [배포 별칭과 소스 커밋](evidence/procurement_home_20261015/deployment.json)
- [운영 커밋 CI 결과](evidence/procurement_home_20261015/main_ci.json)

증거에 비밀번호·토큰·품목 본문을 기록하지 않았다. 로그인 입력용 임시 보안 파일은
검증을 마친 뒤 삭제했다. 기존 작업 폴더의 사용자 변경은 보존했다.
