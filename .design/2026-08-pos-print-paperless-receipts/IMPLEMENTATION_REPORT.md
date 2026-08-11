# 포스 프린트 / 페이퍼리스 운영 모드 구현 보고

작성일: 2026-08-11
상태: 로컬 구현 및 검증 완료, 배포하지 않음

## 구현 범위

- Super Admin에서 매장별 `포스 프린트 모드`와 `페이퍼리스 모드`를 전환한다.
- 모드 변경은 새 주문과 새 추가 메뉴부터 캡처하며 기존 주문은 원래 전달 채널로 마감한다.
- 페이퍼리스 주문은 종이 운영 티켓을 claim하지 않고 키친 → 트레이 → 층별 KDS로 전달한다.
- 휴대폰은 4슬롯, 태블릿은 8슬롯이며 각 주문 상세에서 전체 메뉴, `완료 (다음 단계)`, `취소 (원복)`을 제공한다.
- 포스 프린트 모드는 기존 자동 영수증 출력을 유지한다.
- 페이퍼리스 결제는 불변 디지털 영수증을 생성하고 캐셔 완료창과 고객표시 화면에 동적 QR을 제공한다.
- 고객은 공개 영수증에서 PDF 저장/공유 및 인쇄를 할 수 있고, 직원은 선택적으로 종이 영수증을 출력할 수 있다.
- 일반 영수증은 결제 증빙이며 적색 세금계산서가 아니라는 경계를 화면과 데이터 계약에 유지한다.
- 기존 Red Invoice/MISA 비동기 흐름과 결제 원자성은 변경하지 않았다.

## 안전 장치

- 운영 모드, 주문, 추가 메뉴, print job에 모드 스냅샷을 저장한다.
- 전환 RPC는 Super Admin 전용이며 요청 ID 멱등성과 감사 로그를 가진다.
- 공개 영수증 raw token은 DB에 저장하지 않고 SHA-256 hash만 저장한다.
- 공개 링크는 90일 만료, 영수증당 활성 3개 제한, 만료 30일 후 hash 정리를 적용한다.
- token은 URL fragment로만 전달하고 Flutter 시작 전에 주소·브라우저 이력에서 제거한다. 앱 탐색 이력에는 `/receipt`만 남긴다.
- anon/authenticated의 공개 조회 RPC 실행권한과 직접 테이블 조회를 차단하고, exact-origin·요청 검증·IP HMAC 속도 제한을 가진 Edge Function만 service role로 조회한다.
- 공개 페이지와 API는 `no-store`, `no-referrer`, `noindex/noarchive`, `nosniff` 정책을 적용한다.
- 유효 조회의 `last_presented_at` 쓰기는 최대 하루 한 번으로 제한한다.
- 고객표시 DB payload에는 공개 token이나 영수증 전체 내용 대신 receipt ID만 저장한다.
- 결제 후 QR, 고객표시, PDF 또는 프린터가 실패해도 이미 성공한 결제는 롤백하거나 중복 실행하지 않는다.
- 페이퍼리스에서 프린트로 복귀하면 기존 페이퍼리스 주문만 KDS에서 drain한 뒤 세션을 닫는다.
- 논리 rollback은 새 주문을 프린트 모드로 돌리되 기존 영수증, 감사 기록, 진행 중 KDS 작업을 삭제하지 않는다.

## 검증 결과

- 1차 기능 검증: `flutter test` 968 passed / 환경 의존 2 skipped, Node 58 passed, 취약 패키지 0, Web release build와 `scripts/check_repo.sh` PASS
- 보안 보완 후 집중 검증: Edge Function format/lint/check 및 5/5 테스트 PASS, Flutter 영수증 계약 7/7 PASS
- 보안 보완 후 격리 Postgres rehearsal: preflight → migration → verify → 만료/활성 링크 제한/쓰기 완화/속도 제한 runtime fixture → logical rollback PASS
- 보안 보완 후 최종 전체 저장소 게이트: `flutter test` 969 passed / 환경 의존 2 skipped, Node 58 passed, 패키지 취약점 0, 배포 스크립트 계약·Web release build·Git 공백 검사 PASS
- 운영 DB migration, 원격 배포, production login, 파일럿 활성화: 실행하지 않음

## 캡처 목록

- `screenshots/operation_mode_admin.png`
- `screenshots/operation_mode_confirm.png`
- `screenshots/kitchen_tablet_8_slots.png`
- `screenshots/kitchen_tablet_menu_detail.png`
- `screenshots/tray_tablet_8_slots.png`
- `screenshots/tray_tablet_menu_detail.png`
- `screenshots/tray_phone_4_slots.png`
- `screenshots/floor_tablet_8_slots.png`
- `screenshots/floor_tablet_menu_detail.png`
- `screenshots/cashier_paperless_completion.png`
- `screenshots/customer_display_receipt_qr.png`
- `screenshots/public_receipt_phone.png`

캡처는 운영 데이터나 실계정을 사용하지 않은 결정적 로컬 fixture로 생성했다.

## 배포 전 남은 운영 게이트

- 실제 계정/장치로 다중 역할 E2E 및 실프린터 dry run
- `DIGITAL_RECEIPT_RATE_LIMIT_SECRET` 운영 secret 생성 및 이름 확인(값은 저장소/로그에 남기지 않음)
- Supabase 앞단 WAF/비용 상한 설정과 독립 침투 테스트
- 공개 영수증 90일 보존·폐기 정책의 운영 승인
- 파일럿 매장의 KDS 배정, 직원 교육, 영수증 선택 출력 문구 승인
- production-like snapshot에 대한 별도 원격 migration rehearsal
- exact pushed head SHA의 GitHub Actions 확인과 명시적 배포 승인
