# 포장·배달 주문 고객 편의 개선 구현 기록

작성일: 2026-10-06 · Asia/Ho_Chi_Minh

사용자가 승인한 상태 간소화, 주문 상세, 준비·배송 알림, 메뉴 요청사항, 직원 채팅 템플릿을 구현했다. 기존 작업 디렉터리의 tracked/untracked 변경을 보존했다.

| 구분 | 이번 작업의 상태 |
|---|---|
| 소스 구현 | 완료 |
| 새 migration 적용 | 격리된 Docker PostgreSQL에만 적용·검증. 운영 DB 미적용 |
| 새 Edge·웹 배포 | 미실행 |
| 실제 고객 휴대폰 푸시 수신 | 미검증 |

## 구현 결과

1. 고객 주문 현황·내 주문과 직원 기본 필터를 **확인 대기 / 결제 완료 / 완료**로 정리했다. 입금 사진 전송만으로 결제 완료가 되지 않는다. 준비 완료·기사 인계는 결제 완료 단계에 남고 실제 수령 완료가 마지막 단계다. 취소·거절·만료와 환불 대기 표시는 유지한다. 세부 필터는 직원 화면에서 펼쳐 사용할 수 있다.
2. 주문번호 옆 **주문 상세보기**에서 주문 당시 메뉴명, 단가, 수량, 금액, 메뉴별 메모, 배송비·서비스 요금, VAT, 총 결제금액, 주문번호·시간을 확인한다. 현재 메뉴가 삭제·변경되어도 주문 snapshot을 사용한다. 단가·항목 금액은 세전이며 견적 메뉴 합계·최종 금액은 기존 세금 계산을 따른다. 기사에게 별도 지급하는 배송비는 매장 결제에 미포함이라고 명시한다. 환불도 별도 표시한다.
3. 매장 수령은 준비 완료 때, 배달은 **실제 기사 인계 기록이 생성된 뒤** 자동 알림 이벤트를 만든다. KDS의 포장 완료는 준비 완료로 처리한다. 고객은 상단 종 모양 버튼에서 브라우저 푸시를 켜거나 끌 수 있다. 권한 요청은 고객이 켜기를 누를 때만 발생하며 미지원·권한 거절·설정 누락 시 주문 화면과 채팅에서 확인한다. iPhone은 홈 화면에 추가한 앱에서 사용하도록 안내한다.
4. 메뉴를 담은 뒤 카드 아래와 장바구니에서 최대 300자 요청사항을 추가·수정한다. 카테고리·언어·배송지 왕복 뒤에도 유지하며 기존 주문 항목 `note`를 통해 직원·주방에 전달한다. 현재 장바구니 모델에서는 같은 메뉴의 모든 수량에 같은 메모가 적용된다.
5. 직원 채팅에 접수 확인·견적 안내·배송 정보 확인·배송비 확인 템플릿을 추가했다. 선택한 주문의 정보로 편집 가능한 초안을 만들고 직원이 전송한다. 배송비는 직원이 현재 금액을 입력해야 한다. 기존 초안을 덮어쓸 때는 확인하며 다른 주문으로 전환하면 초안을 지운다. 초안 복사로 Google Translate 수동 번역을 지원한다. 템플릿·시스템 알림·화면 문구는 KO/VI/EN을 제공한다.

## 서버 처리와 변경 경계

- 새 `direct_order_staff_list_v3`는 화면 단계 또는 세부 상태를 **LIMIT 전에 필터링**한다. 전날 미처리 주문과 미정산 픽업 환불도 남기며 매장·직원 권한을 검증한다. 관련 항목·메시지·사진 재요청 데이터를 페이지 단위로 묶어 읽는다.
- `push_subscription`은 고객 세션 secret 검증을 거쳐 기기·토큰·언어를 등록한다. 토큰 테이블과 배치 전송 RPC는 일반 고객·직원에게 공개하지 않는다. 앱 locale 변경·재진입 시 권한 창 없이 등록을 갱신한다.
- 이벤트와 전송 대기는 유일 키로 중복 생성하지 않는다. 새 내부 dispatcher는 한 번에 최대 50건을 가져와 최대 8개 작업자로 처리한다. 2분 lease, 최대 5회 재시도와 지수 backoff를 적용하며 만료·해지 세션, 꺼진 기기, 완료·취소 주문의 오래된 알림을 건너뛴다. 응답 유실 뒤 재시도는 같은 OS 알림 tag를 사용하므로 실제 수신을 엄격한 exactly-once로 보장한다고 표현하지 않는다.
- 결제 승인, 금융 기록, 환불, 인원·포장 출력, MISA 비동기 처리와 Deliberry 폐기 정책을 유지한다. Docker SQL 검사는 기존 결제 함수 해시와 단일 결제/주문 그래프를 확인한다.
- 새 migration은 `20261006030000_direct_order_customer_experience.sql`이다. 현재 main의 `20261006020000_direct_order_receipt_packing_context.sql`과 번호가 겹치지 않도록 선택했다. 이 작업의 새 migration은 운영에 적용하지 않았다.

## 검증

| 검사 | 결과 |
|---|---|
| 관련 Flutter 회귀·새 기능·화면 진입 검사 | **73 PASS** · [로그](evidence/direct_order_customer_experience_20261006/flutter-final.log) |
| 실제 폰트로 모바일 390×844 화면 캡처·검사 | **33 PASS** · [로그](evidence/direct_order_customer_experience_20261006/visual-tests.log) |
| 공개 Edge와 알림 dispatcher 행동 테스트 | **26 PASS** · [로그](evidence/direct_order_customer_experience_20261006/edge-final.log) |
| Edge format·lint·type check | PASS · [type check](evidence/direct_order_customer_experience_20261006/edge-check.log) |
| PostgreSQL 실제 승인·KDS·기사 인계·알림 재시도·권한 | PASS · [로그](evidence/direct_order_customer_experience_20261006/sql-final.log) |
| 목록 1·50·100·200건 | 각각 실제 페이지 수 확인, 주문별 context/detail RPC 호출 **0회** |
| `dart analyze lib test --fatal-infos` | No issues found · [로그](evidence/direct_order_customer_experience_20261006/analysis.log) |
| `flutter build web --no-pub --release` | PASS · [로그](evidence/direct_order_customer_experience_20261006/web-build.log) |
| 공식 배포 검사·DB-only 격리 shell fixture | PASS · [로그](evidence/direct_order_customer_experience_20261006/deploy-checks.log) |
| 전체 Flutter | **1,716 PASS / 94 skip / 기존 실패 2건** · [로그](evidence/direct_order_customer_experience_20261006/flutter-all.log) |
| `bash scripts/check_repo.sh` | 기존 감사용 Dart 파일의 정적 검사 4건에서 중단 · [로그](evidence/direct_order_customer_experience_20261006/check-repo.log) |

전체 Flutter의 두 실패는 `direct_order_arrival_alert_test.dart`의 기존 locale 파일 해시와 `route_operational_state_coverage_contract_test.dart`의 기존 Admin 테스트 제목 불일치다. 이번 작업이 추가한 화면 진입은 coverage registry를 갱신하고 별도 검사에서 통과했다. 전체 저장소 검사 또는 운영 release gate를 PASS라고 보고하지 않는다. 웹 빌드의 기존 외부 패키지 wasm dry-run·Cupertino font 경고는 남는다.

고객 화면은 실제 앱 widget와 저장소 폰트로 렌더링한 **합성 테스트 데이터**이며 실제 운영 고객 주문이나 푸시 수신 증거가 아니다. 메뉴 요청사항의 모바일 줄바꿈을 확인하고 전체 폭 배치로 수정했다.

- [세 단계 주문 현황](evidence/direct_order_customer_experience_20261006/screenshots/customer-paid-ko.png)
- [완료 주문 상세](evidence/direct_order_customer_experience_20261006/screenshots/completed-order-details-ko.png)
- [메뉴 요청사항](evidence/direct_order_customer_experience_20261006/screenshots/menu-item-request-ko.png)
- [주문 알림 설정](evidence/direct_order_customer_experience_20261006/screenshots/customer-notification-settings-ko.png)

## 운영 반영 시 남은 확인

1. 최신 main과 기존 사용자 작업을 보존하며 이번 변경을 검토한다. 시작 기준 코드 변경은 [task-code.patch](evidence/direct_order_customer_experience_20261006/task-code.patch), [해시 목록](evidence/direct_order_customer_experience_20261006/changed-files.json)에 있다. 이 patch는 실제 작업 전 snapshot이 있는 파일과 새 파일 32개만 포함한다. 기존 설계 문서 4개에 추가한 사양과 기존 fallback fixture의 추가 변경은 해당 원본 파일에서 별도로 확인한다. 다른 HEAD에 그대로 적용 가능하다는 의미는 아니다.
2. 정확한 pushed HEAD의 필수 GitHub Actions 성공 후 `scripts/deploy_pos_production.sh` 공식 절차로 migration·공개 Edge·새 dispatcher·웹을 함께 반영한다. v3 목록 RPC가 준비된 DB와 새 앱 버전을 맞춘다. 배포 스크립트에 dispatcher 배포·401 인증 검사와 Edge 검증을 추가했다.
3. 기존 Firebase 웹 build 정의와 VAPID, Edge `FIREBASE_SERVICE_ACCOUNT_JSON`, Vault/Edge `CRON_SECRET`, `direct-order-customer-push-every-minute` cron 활성 상태를 확인한다. 없는 설정의 값을 추정하거나 새 비밀 값을 저장하지 않았다.
4. 실제 매장 수령·배달 주문으로 허용/거절/해지, 화면을 닫은 상태의 알림, 실제 기사 인계 시점, 재시도 중복, KO/VI/EN 표시를 확인한다. 현재 소스·격리 테스트만으로 실제 고객 수신이나 운영 해결 완료를 주장하지 않는다.
