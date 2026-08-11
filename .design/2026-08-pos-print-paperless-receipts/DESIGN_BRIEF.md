# 설계 브리프: 포스 프린트/페이퍼리스 운영 모드와 고객 영수증

Date: 2026-08-11
Source: 사용자 요구와 현재 결제·출력·고객표시·KDS·레드인보이스 구현 감사
Status: 계획 전용 — 애플리케이션 구현·DB 적용·배포하지 않음

## 1. 결정 요약

기존 `비상 대응` 개념을 고객에게 노출하지 않고, 매장 운영 방식을 다음 두 가지로 제공한다.

| 항목 | 포스 프린트 모드 | 페이퍼리스 모드 |
|---|---|---|
| 주방·트레이·층별 작업 전달 | 기존 운영 티켓 자동 출력 | KDS 보드로 전달 |
| KDS 보드 | 대기 또는 읽기 전용 상태 | 키친·트레이·층별 모두 활성 |
| KDS 한 페이지 슬롯 | 해당 없음 | Phone 4개, Tablet 이상 8개 |
| 고객 영수증 기본값 | 기존처럼 자동 종이 출력 | 결제 완료 후 디지털 영수증 QR |
| 고객 종이 영수증 | 기존 자동 출력 및 재출력 | 고객 요청 시 `종이 영수증 출력` 선택 |
| 적색 세금계산서(레드인보이스) | 기존 접수/MISA 흐름 유지 | 기존 접수/MISA 흐름 유지 |

핵심 원칙은 `운영 티켓의 종이 사용 여부`와 `고객 영수증 제공 의무`를 분리하는 것이다. 페이퍼리스 모드도 고객 영수증을 생략하지 않는다. 결제 후 고객표시 화면에 QR을 보여주며, 고객은 로그인 없이 영수증을 확인하고 PDF 저장 또는 직접 인쇄할 수 있다. 종이가 필요한 고객에게만 기존 영수증 프린터로 출력한다.

## 2. 용어와 범위

### 사용자에게 보이는 용어

- `포스 프린트 모드`: 운영 티켓과 고객 영수증을 현재 방식으로 출력
- `페이퍼리스 모드`: 운영 티켓은 KDS로 처리하고 고객 영수증은 디지털을 기본으로 제공
- `종이 영수증 출력`: 페이퍼리스 모드에서 고객 요청으로 최초 종이 사본을 출력
- `영수증 재출력`: 이미 종이 사본을 출력한 거래를 결제 이력에서 다시 출력

### 이번 범위에 포함

- 매장별 운영 모드 조회·전환·감사
- 주문 생성 시 운영 모드 스냅샷 고정
- 운영 티켓 출력/KDS 라우팅을 주문 스냅샷으로 결정
- 기존 키친·트레이·층별 KDS를 정상 페이퍼리스 화면으로 승격
- 결제 완료 후 디지털 영수증 생성·고객표시 QR·공개 영수증 보기·PDF/인쇄
- 페이퍼리스에서 선택적 종이 영수증 출력
- 단일·분할·통합 테이블·비매출/서비스 결제와 장애 시 대체 흐름
- 회귀 테스트, 점진 배포, 관측, 롤백

### 범위 제외

- MISA가 소유한 적색 세금계산서 발행 후 조회·취소·수정·PDF 기능
- SMS, Zalo, 이메일로 영수증 링크를 직접 발송하는 기능
- 고객 계정, 회원 가입, 전화번호 수집
- 회계 원장 또는 법정 전자세금계산서로 디지털 영수증을 승격하는 기능
- 기존 물리 `restaurants`/`restaurant_settings` 테이블 이름 변경
- 기존 `emergency_*` 테이블의 즉시 물리 이름 변경

## 3. 기존 구현 감사와 변경 전략

### 그대로 재사용

- `process_payment`와 `process_combined_table_payment`의 원자적 결제 계약
- `PaymentService.enqueueReceiptPrintJob`와 `enqueue_receipt_print_job`의 매장 권한·출력 payload·배치 원장
- `ReceiptBuilder`의 품목, 결제수단, 현금 수령/거스름돈, 숫자 VAT 영수증 형식
- 고객표시 전용 계정, `/customer-display`, Realtime+폴링, 매장 격리
- 기존 KDS의 주문 큐, 단계별 수량 원장, 주문 단위 완료/원복, 오프라인 outbox
- Phone 4슬롯/Tablet 8슬롯 보드와 키친·트레이·층별 공통 상세
- `RedInvoiceModal`, `red_invoice_intakes`, 비동기 MISA 접수 경계
- 기존 프린터 목적지, Print Station, Wi-Fi/USB 출력 경로
- `PosColors`, 반응형 컴포넌트, KO/VI/EN 현지화 방식

### 수정

- Super Admin의 `비상 디지털 운영` 제어를 매장 `운영 모드` 제어로 교체
- `/emergency`와 `emergency_station`의 사용자 노출 문구·홈 진입을 페이퍼리스 작업 화면으로 전환
- 활성 세션 유무만으로 모든 운영 출력물을 보류하는 현재 조건을 주문별 모드 스냅샷 조건으로 교체
- 결제 직후 항상 자동 영수증을 큐잉하는 캐셔 흐름을 운영 모드별 정책으로 분기
- 고객표시 상태를 결제용 은행 QR와 결제 완료 영수증 QR로 명확히 분리
- 결제 완료창을 디지털 영수증 상태와 선택적 종이 출력 중심으로 확장

### 새로 생성

- 운영 모드 전환 RPC와 감사 이벤트
- 주문별 `fulfillment_mode_snapshot`
- 불변 디지털 영수증 스냅샷과 고엔트로피 공개 토큰
- 인증 없는 공개 영수증 Edge 조회와 `/receipt#token=...` 화면
- 고객표시의 `payment`/`receipt` 단계 계약
- 디지털 영수증 생성 실패 재시도 원장과 관측 지표

### 호환성 전략

첫 릴리스에서는 이미 구현된 `emergency_*` DB 구조와 RPC를 제거하거나 대규모 rename하지 않는다. 새 일반 용어의 서비스/RPC를 앞에 두고 기존 테이블을 backing ledger로 재사용한다. 기존 앱 버전이 공존하는 동안 기존 RPC도 유지하고, 새 앱이 안정화된 뒤 별도 릴리스에서 호환 view/RPC와 함께 내부 이름 정리를 검토한다. 이 방식은 데이터 이동과 화면 변경을 한 번에 수행하는 위험을 피한다.

### 예상 변경 지도

| 영역 | 주 변경 대상 | 보호할 기존 계약 |
|---|---|---|
| 라우팅/역할 | `lib/core/router/app_router.dart`, `lib/core/utils/role_routes.dart` | `/qr/:token`, 역할별 홈, 비인가 redirect |
| 모드 제어 | `lib/features/emergency_fulfillment/emergency_control_panel.dart`와 provider | 기존 매장 격리·감사·중복 탭 방지 |
| KDS | `emergency_fulfillment_screen.dart`, `emergency_fulfillment_provider.dart` | 4/8슬롯, 수량 체인, 완료/원복, Realtime/outbox |
| 운영 출력 | print enqueue/claim SQL, `print_job_agent_service.dart` | 목적지·batch·claim lease·Wi-Fi/USB 출력 |
| 결제/영수증 | `payment_service.dart`, `cashier_screen.dart`, `payment_completion_dialog.dart`, `payment_detail_screen.dart` | 결제 원자성, 기존 자동 출력, 재출력, 현금/VAT/비매출 |
| 고객표시 | `customer_display_screen.dart`, `customer_display_provider.dart`, customer display RPC | 전용 계정, 매장 한정 SELECT, Realtime+polling |
| 공개 영수증 | 새 receipt feature와 router 공개 분기 | 기존 주문 QR token/route와 namespace 분리 |
| 레드인보이스 | 원칙적으로 runtime 수정 없음 | intake/export/MISA async 경계 전체 |

적용된 과거 migration 파일은 수정하지 않고 더 최신 timestamp의 additive migration으로만 확장한다. 현재 작업 트리에 아직 커밋되지 않은 KDS action, 숫자 VAT, USB printer migration이 있으므로 구현 시작 시 로컬 파일 존재와 원격 migration history를 모두 대조한 뒤 새 timestamp를 정한다. 파일명 순서만 보고 운영 적용 여부를 추측하지 않는다.

## 4. 절대 보존 계약

다음 항목은 구현 중 변경 금지 조건이다.

1. 결제 성공의 기준은 현재 `process_payment`/통합 결제 RPC의 커밋이며, QR 생성·고객표시·프린터·MISA 실패가 결제를 롤백하지 않는다.
2. 같은 결제 요청의 멱등성, 분할 결제 합계, 현금 수령/거스름돈, 할인·VAT·물티슈·서비스 품목 계산을 변경하지 않는다.
3. 포스 프린트 모드에서는 현재 운영 티켓 및 고객 영수증 자동 출력 흐름을 동일하게 유지한다.
4. 페이퍼리스 모드에서만 운영 티켓 자동 출력을 억제하며, 고객 영수증 목적지와 명시적 출력은 억제하지 않는다.
5. 모드 전환은 새 주문부터 적용한다. 진행 중 주문은 생성 당시 모드로 끝까지 처리한다.
6. 모드를 여러 번 전환해도 한 주문이 종이와 KDS 양쪽으로 중복 전달되거나 어느 쪽에도 전달되지 않아서는 안 된다.
7. KDS `완료`/`취소(원복)` 수량 체인과 append-only 감사 이력은 유지한다.
8. 적색 세금계산서 접수는 디지털 영수증과 별개이며, 기존 즉시/추후 접수와 MISA 비동기 경계를 그대로 유지한다.
9. `restaurants` 실제 테이블 및 `id`, `name`, `address`, `is_active` 컬럼을 유지해 Office 앱 연동을 보호한다.
10. 기존 프린터 목적지 설정, 영수증 재출력, 결제 상세, 정산 함수, QR 주문을 보존한다.

## 5. 운영 모드 상태와 전환 계약

### 저장 값

- 매장 현재값: `restaurant_settings.fulfillment_mode`
  - `pos_print`
  - `paperless`
- 주문 생성 스냅샷: `orders.fulfillment_mode_snapshot`
- 기본값과 기존 데이터 backfill: `pos_print`
- 변경 이력: 변경 전/후 모드, 매장, 실행자, 사유, 시각을 `audit_logs`에 append-only 기록

새 컬럼은 실제 `restaurant_settings`와 `orders`에 additive로 추가하며 `store_settings` view가 새 값을 노출하도록 갱신한다. 기존 앱은 새 컬럼을 몰라도 동작해야 한다.

### 전환 권한과 UX

- Super Admin 또는 기존 정책상 운영 모드 관리가 허용된 관리자만 전환한다.
- 확인창에 매장명, 현재 모드, 변경할 모드, 새 주문부터 적용됨, 진행 중 주문 수, 프린터/KDS 상태를 표시한다.
- 전환 RPC는 행 잠금 후 비교-후-갱신하고 같은 요청 ID 재전송을 한 번만 반영한다.
- 전환 직후 새 주문부터 새 모드를 캡처한다. 기존 주문의 스냅샷을 대량 수정하지 않는다.
- `paperless → pos_print` 전환 후에도 기존 paperless 주문이 남아 있으면 KDS는 `마감 중` 상태로 계속 처리 가능하고, 모두 완료된 뒤 대기 상태로 돌아간다.
- `pos_print → paperless` 전환 전 KDS 스테이션 연결, 계정 배정, 최근 heartbeat를 확인한다. 준비되지 않았으면 경고하되 관리자 강제 전환은 사유를 남긴다.

## 6. 주문 전달과 프린트 라우팅

### 주문 생성 시점

모든 주문 생성 경로가 같은 DB 함수로 현재 매장 모드를 읽고 `orders.fulfillment_mode_snapshot`을 한 번 기록한다. QR 주문, 웨이터 주문, 추가 주문, 관리자/서비스 주문을 포함한다.

추가 주문은 현재 코드상 같은 주문에 품목을 추가할 수 있으므로 품목에도 `fulfillment_mode_snapshot` 또는 주문 배치 식별자를 둔다. 모드 전환 후 기존 테이블 주문에 추가된 품목은 `추가 시점 모드`를 캡처해야 한다. 그렇지 않으면 한 주문 안의 기존 품목과 신규 품목 전달 방식이 잘못 섞인다. 구현 preflight에서 실제 추가 주문 모델을 확인한 뒤 다음 중 최소 변경안을 선택한다.

- 권장: `order_items.fulfillment_mode_snapshot`을 추가하고 모든 출력/KDS 라우팅은 품목 스냅샷을 사용
- 대안: 기존 주문 batch 원장이 이미 완전하면 batch에 모드를 저장하고 품목이 batch를 참조

### 출력 정책

| copy type | `pos_print` 품목 | `paperless` 품목 | 명시적 고객 요청 |
|---|---|---|---|
| kitchen | 기존대로 큐/출력 | KDS만, 자동 출력 억제 | 해당 없음 |
| tray | 기존대로 큐/출력 | KDS만, 자동 출력 억제 | 해당 없음 |
| floor | 기존대로 큐/출력 | KDS만, 자동 출력 억제 | 해당 없음 |
| confirmation | 기존대로 큐/출력 | KDS 완료 원장으로 대체 | 해당 없음 |
| receipt | 결제 후 기존 자동 출력 | 자동 출력하지 않음 | 항상 출력 허용 |

- 출력 여부는 claim 시점의 `현재 매장 모드`가 아니라 job 또는 품목에 저장된 스냅샷으로 결정한다.
- 기존 활성 세션만 보고 매장의 모든 운영 job을 hold하는 trigger/claim 조건은 호환 레이어를 거쳐 주문 스냅샷 기반으로 좁힌다.
- 페이퍼리스 운영 job은 삭제하지 않는다. `digitally_routed` 같은 감사 가능한 해소 상태로 남기되 프린터가 claim하지 못하게 한다.
- 포스 프린트 job은 매장이 이후 paperless로 전환돼도 계속 출력한다.
- 전환·재연결 시 오래된 job을 자동 일괄 출력하지 않는다.

## 7. 페이퍼리스 KDS 화면

- 기존 `/emergency` 내부 화면과 역할 계정을 재사용하되 사용자 노출에서는 `페이퍼리스 작업`, `키친`, `트레이`, `층별`로 표기한다.
- Phone은 페이지당 4슬롯, Tablet 이상은 8슬롯이다. 키친·트레이·층별 모두 같은 기준을 사용한다.
- 카드 진입 시 전체 메뉴명·수량·현재 단계를 표시한다.
- `완료(다음으로)`는 처리 가능한 모든 delta를 원자적으로 다음 단계에 전달한다.
- `취소(원복)`는 직전 완료 action을 보상 기록으로 되돌리며 다음 단계가 처리한 수량은 DB에서 거절한다.
- 포스 프린트 모드에서도 마감 중인 paperless 주문이 있으면 해당 카드만 계속 보인다.
- KDS 연결 실패가 주문 생성을 막지 않으며 경고·폴링·outbox·수기 백업 절차를 유지한다.

세부 화면·수량 계약은 기존 `.design/2026-08-emergency-kds-grid/` 문서를 재사용한다. 새 계획은 그 UI를 일반 운영 모드에 연결하는 범위만 다룬다.

## 8. 고객 영수증 수명주기

### 결제 완료 순서

```text
결제 RPC 커밋
  → 결제 증빙 사진/확인(기존 조건 유지)
  → 레드인보이스 즉시/추후 접수(기존, 결제와 비동기)
  → 디지털 영수증 ensure 요청(멱등, 실패해도 결제 성공 유지)
  → 운영 모드별 완료창
      pos_print: 기존 자동 종이 출력 상태 + 재출력
      paperless: 고객표시 QR + 종이 영수증 출력 선택
```

디지털 영수증은 결제 데이터의 새로운 회계 원장이 아니라, 커밋된 주문·결제 데이터를 고객에게 보여주는 불변 snapshot이다. 생성 실패 시 원본 결제에서 재생성할 수 있어야 한다.

### `digital_receipts`

권장 additive 필드:

- `id uuid`
- `restaurant_id uuid` — 실제 `restaurants` FK 유지
- `order_id uuid`
- `combined_payment_group_id uuid null`
- `receipt_number text`
- `snapshot jsonb` — 발행 시점의 불변 표시 데이터
- `created_at`
- `revoked_at`, `revoked_by`, `revocation_reason` — 오발행/보안 대응용, 일반 취소 기능 아님
- 단일 주문 영수증의 멱등 unique key

공개 링크는 별도 `digital_receipt_links`에 둔다.

- `id`, `digital_receipt_id`, `token_hash`
- `created_at`, `expires_at`, `last_presented_at`, `revoked_at`
- raw token은 발급 응답에만 존재하고 DB·로그·analytics에는 남기지 않음
- 링크는 90일 동안 유효하고 영수증당 활성 링크는 최대 3개다. 새 링크 발급 시 가장 오래된 초과 링크만 폐기한다.
- 만료 30일 후 링크 hash를 제거하고, `last_presented_at`은 하루에 한 번 이하로만 갱신한다.

snapshot에는 매장명·주소·사업자 정보, 영수증 번호, 테이블, 결제시각, 메뉴·수량·단가, 할인, 서비스 요금, VAT, 합계, 결제수단별 금액, 현금 수령/거스름돈, 비매출 여부를 넣는다. 카드/계좌 등 민감값은 현재 영수증 수준 이상 노출하지 않고 마스킹한다. 적색 세금계산서 접수 정보나 MISA 상태는 넣지 않는다.

### 생성과 복구

- `ensure_digital_receipt(order_id, request_id)`는 인증된 매장 직원만 호출하고 결제 완료 여부와 매장 접근을 재검증한다.
- 같은 주문/결제에 반복 호출하면 기존 영수증 ID를 반환한다.
- `issue_digital_receipt_link(receipt_id)`는 호출할 때마다 새 고엔트로피 token을 발급하고 hash만 저장한다. 네트워크 응답을 잃고 재호출해 미사용 link가 생기는 것은 허용하되, 결제나 영수증 snapshot을 중복 생성하지 않는다.
- QR 생성 실패가 결제 RPC를 롤백하지 않는다.
- 클라이언트 재시도와 결제 이력의 `디지털 영수증 다시 표시`로 복구한다.
- 서버 측 주기적 보정 작업은 `결제 완료 + 영수증 없음`만 찾아 ensure하며 결제/금액을 수정하지 않는다.

## 9. 공개 영수증 보안 계약

- 외부 URL은 `/receipt#token=...`이다. fragment는 서버 요청과 Referer에 전송되지 않으며, Flutter 부팅 전에 JS 메모리로 넘기고 브라우저 주소에서 즉시 제거한다.
- 앱 router는 token 없는 `/receipt`만 인증 redirect 전에 공개 경로로 처리하고 navigation history에는 `/receipt`만 저장한다.
- token은 192-bit 암호학적 난수이며 raw 값은 발급 응답과 현재 탭 메모리에만 존재하고 DB에는 SHA-256 hash만 저장한다.
- anon/authenticated는 영수증 조회 RPC와 테이블을 직접 읽을 수 없다. 공개 화면은 exact-origin CORS와 요청 크기/형식 검증, IP HMAC 기반 속도 제한을 적용한 `public-receipt` Edge Function만 호출한다.
- Edge Function의 service role만 `get_public_receipt(token)` SECURITY DEFINER RPC를 호출하며, RPC는 link hash·90일 만료·link/receipt revoke를 확인하고 허용 필드만 반환한다.
- RPC는 고정 `search_path`, 명시적 revoke/grant, UUID/매장 추측 방지, 오류 메시지 단일화 계약을 가진다.
- URL·token·전체 snapshot을 analytics, crash log, audit detail에 남기지 않는다.
- `/receipt` 응답은 `no-store`, `no-referrer`, `noindex/noarchive`, `nosniff`, frame 차단 헤더를 가진다.
- 공개 화면은 수정 기능 없이 보기, PDF 저장, 브라우저 인쇄, OS 공유만 제공한다.
- PDF는 동일 snapshot으로 서버/클라이언트 중 한 경로만 사용해 화면과 금액이 달라지지 않게 한다.
- 공개 링크는 발급 후 90일 동안 유효하며 관리자가 개별 revoke할 수 있다. 만료 후에는 결제 이력에서 새 QR을 발급하거나 선택적으로 종이 영수증을 출력한다.
- 인프라 WAF/비용 상한과 독립 침투 테스트는 코드 보완과 별도의 배포 승인 게이트다.

## 10. 고객표시 화면 상태

현재 `customer_payment_displays`를 새 장치 없이 확장한다.

| phase | 화면 | QR 종류 |
|---|---|---|
| `idle` | 다음 고객 대기 | 없음 |
| `payment` | 주문 품목·합계·결제 안내 | 기존 은행 결제 QR |
| `receipt` | 결제 완료·영수증 안내·유효 시간 | 디지털 영수증 QR |
| `error` | QR 준비 실패, 직원에게 종이 영수증 요청 안내 | 없음 |

- payload에 `phase`, `display_revision`, 필요한 최소 receipt presentation 정보만 둔다.
- `payment` QR asset과 `receipt` 동적 QR을 서로 다른 widget/key/색상/문구로 분리한다.
- 결제 완료 시 cashier가 `receipt`를 publish하고, 다음 결제 시작 시 `payment`로 덮어쓴다.
- 일정 시간 후 자동 idle로 전환할 수 있지만 고객이 스캔할 시간을 충분히 보장한다. 최초 기준은 90초이며 실제 매장 검토에서 조정한다.
- customer display가 오프라인이어도 cashier 완료창 자체에서 QR을 보여주는 보조 경로를 둔다.
- 같은 매장의 여러 고객표시 장치를 지원해야 한다면 현재 `store_id` 단일 행 구조를 `terminal_id` 키로 확장하는 것은 별도 선행 조건이다. v1은 현재와 동일하게 매장당 한 활성 고객표시를 기본 계약으로 둔다.

## 11. 캐셔 완료창과 종이 출력

### 포스 프린트 모드

- 기존 결제 후 `enqueue_receipt_print_job(p_reprint=false)` 자동 호출을 유지한다.
- 완료창은 출력 대기/성공/실패와 기존 `재출력`을 유지한다.
- 디지털 영수증은 생성하되 UI 기본 경로로 강제하지 않아, 추후 이력 조회와 장애 복구에 사용할 수 있다.

### 페이퍼리스 모드

- 결제 직후 자동 종이 출력은 하지 않는다.
- 완료창의 주 상태는 `고객 화면에 영수증 QR 표시됨`이다.
- 동작은 다음 세 가지로 제한한다.
  - `종이 영수증 출력`: 최초 batch 1을 멱등하게 큐잉
  - `QR 다시 표시`: 고객표시와 cashier QR을 다시 publish
  - `완료`: 다음 고객으로 진행
- 버튼 중복 탭은 같은 요청 ID로 한 번만 반영한다.
- 최초 선택 출력 실패 시 결제 완료 상태는 유지하고 프린터 재시도/다른 장치 안내를 제공한다.

현재 완료창의 `onReprint` 하나로 최초 출력과 재출력을 함께 처리하면 중복 batch가 생길 수 있다. 서비스 계약을 다음처럼 분리한다.

- `printFirstReceiptCopy(orderId)` → `p_reprint=false`, 기존 batch 1 반환
- `reprintReceipt(orderId)` → `p_reprint=true`, 결제 이력에서만 batch 2 이상 생성

## 12. 결제 유형별 계약

### 단일·분할 결제

- 주문당 디지털 영수증 하나를 발행한다.
- 분할 결제는 모든 결제수단과 각 금액을 한 snapshot에 표시한다.
- 결제 도중 일부만 완료된 상태에는 최종 영수증 QR을 발행하지 않는다.

### 통합 테이블 결제

첫 릴리스는 현재 종이 출력과 동일하게 원 주문별 영수증을 유지한다. 완료창에서 테이블별 영수증 카드/QR을 순서대로 보여주며 `전체 종이 출력`과 개별 출력을 구분한다. 통합 한 장 영수증은 세무·품목·취소 계약을 추가로 바꾸므로 별도 제품 결정 전 만들지 않는다.

### 비매출/서비스 결제

- 기존 SERVICE 영수증 형식과 `is_revenue=false` 계약을 유지한다.
- 디지털 영수증은 제공하지만 레드인보이스 흐름을 열지 않는다.

### 취소·조정·재결제

- 이미 발행된 영수증 snapshot을 조용히 덮어쓰지 않는다.
- 기존 취소/조정이 새 결제 레코드를 만드는 현재 계약을 따르고, 새 거래에 새 영수증 번호를 발행한다.
- 원 영수증에는 시스템이 이미 가진 취소 상태만 표시하며, 공개 링크 revoke가 회계 취소를 대신하지 않는다.

## 13. 레드인보이스 경계

- 적색 세금계산서는 이미 구현된 방향을 그대로 사용한다.
- 디지털 영수증 QR은 회사 내부 비용 증빙용 일반 영수증이며 적색 세금계산서가 아니다.
- 영수증 QR 스캔이 MISA 발행 요청, red invoice intake 생성, 세무 신고를 자동 실행하지 않는다.
- `RedInvoiceModal`의 즉시 입력·명함·Zalo·기타 추후 접수, daily export, MISA 비동기 dispatch를 수정하지 않는다.
- MISA 장애, 고객의 적색 세금계산서 미신청, intake 전송 지연이 결제 완료·디지털 영수증·종이 출력에 영향을 주지 않는다.

## 14. 장애와 오프라인 처리

| 장애 | 고객/직원 동작 | 시스템 계약 |
|---|---|---|
| 고객표시 오프라인 | cashier 화면의 QR 제시 | 결제 성공 유지, 표시 재시도 |
| 영수증 ensure 실패 | 종이 출력 안내/재시도 | 결제 성공 유지, 결제 이력에서 복구 |
| 영수증 프린터 장애 | QR 사용, 출력 job 재시도 | 중복 batch 금지 |
| 인터넷 단절 | 가능하면 로컬 종이 출력, 연결 후 QR 생성 | 디지털 영수증이 결제를 막지 않음 |
| KDS 장치 단절 | 화면 경고·폴링·outbox·수기 백업 | 주문 생성/결제 유지, 누락 감사 |
| 모드 전환 중 주문 | 생성 transaction의 snapshot 사용 | 현재 설정 재조회로 라우팅 변경 금지 |
| 고객 QR 재스캔 | 같은 불변 영수증 표시 | 주문/결제 상태 변경 없음 |

인터넷과 프린터가 동시에 사용할 수 없는 경우 cashier는 결제를 완료하고 `영수증 제공 대기`를 명확히 기록한다. 복구 후 결제 이력에서 QR 또는 종이를 제공할 수 있어야 한다.

## 15. 관측과 감사

다음 지표를 매장·모드별로 수집하되 raw token이나 민감 payload는 기록하지 않는다.

- 모드 전환 횟수, 실행자, 강제 전환 사유
- 주문/품목별 captured mode와 실제 전달 채널 일치율
- 운영 print 억제 수, KDS 완료/원복/동기화 실패 수
- 디지털 영수증 ensure 성공/지연/실패/복구 수
- 고객표시 receipt publish 성공/실패
- 선택적 종이 출력률, 최초 출력 실패율, 재출력률
- 결제 완료 대비 영수증 존재율
- 같은 주문의 운영 종이+KDS 중복 전달 탐지

필수 경보:

- 결제 완료 후 60초가 지나도 디지털 영수증이 없고 종이 영수증도 없는 거래
- paperless 품목이 운영 프린터에 claim됨
- pos_print 품목이 KDS에만 존재하고 출력 job이 없음
- 수량 체인 위반, 다른 매장/층 접근, 반복 토큰 실패 급증

## 16. 점진 배포와 롤백

### Phase A — 계약 고정

- 현재 dirty worktree와 사용자 소유 VAT/USB/프린터 변경을 보존한다.
- 포스 프린트 기준선, 결제 유형, 영수증 출력, 고객표시, 레드인보이스, KDS 테스트를 먼저 고정한다.

### Phase B — Expand, 기능 OFF

- additive 컬럼·테이블·RPC·RLS·view·preflight/verify/rollback을 배포한다.
- 기존 데이터는 `pos_print`로 backfill한다.
- 새 앱은 feature flag OFF 상태에서 기존 동작과 동일해야 한다.

### Phase C — Shadow

- 모든 결제에 디지털 영수증 snapshot을 shadow 생성하되 고객에게 QR을 노출하지 않는다.
- 현재 종이 영수증과 금액·VAT·결제수단·품목을 자동 비교한다.
- 운영 라우팅은 현재 출력 그대로 두고 captured mode/예상 채널만 기록해 mismatch를 확인한다.

### Phase D — 내부/파일럿 매장

- 직원 결제에서 공개 영수증/PDF/QR/선택 출력 확인
- 한 매장 한 교대에서 paperless를 활성화하고 KDS 장치 준비·4/8슬롯·완료/원복·전환 중 주문을 실기기로 확인
- 종이 절감률보다 누락·중복 0건을 우선 gate로 사용

### Phase E — 점진 확대

- 매장별 opt-in, 언제든 `pos_print`로 되돌릴 수 있게 유지
- rollback은 현재 설정만 print로 전환하되 이미 생성된 paperless 주문은 KDS에서 drain한다.
- schema/table drop이나 기존 RPC 제거는 별도 릴리스 전 수행하지 않는다.

운영 DB 적용과 배포는 별도 승인 후 `scripts/deploy_pos_production.sh`만 사용하고, exact pushed head SHA의 필수 GitHub Actions 성공 전에는 release gate를 PASS로 보고하지 않는다.

## 17. 테스트 매트릭스

기존 회귀 suite에서 최소 다음 파일을 직접 gate로 사용한다.

- `test/cashier_receipt_print_contract_test.dart`
- `test/payment_detail_contract_test.dart`
- `test/receipt_builder_contract_test.dart`
- `test/receipt_numeric_vat_contract_test.dart`
- `test/customer_payment_display_contract_test.dart`
- `test/emergency_digital_fulfillment_contract_test.dart`
- `test/emergency_fulfillment_responsive_test.dart`
- `test/print_routing_contract_test.dart` 및 Wi-Fi/USB printer tests
- `test/combined_table_payment_contract_test.dart`와 분할/할인/합계 payment tests
- `test/red_invoice_intake_export_contract_test.dart`
- `test/red_invoice_intake_overlay_operational_test.dart`
- `test/pilot_red_invoice_smoke_contract_test.dart`
- `test/router_role_guard_test.dart`

### 불변 회귀

- 단일 현금/카드/이체, 현금 거스름돈, 분할 결제, 통합 테이블 결제
- 할인, VAT, 서비스요금, 물티슈, 긴 품목명, 비매출/서비스 주문
- payment proof, 적색 세금계산서 즉시/추후 접수, MISA 실패
- 결제 상세 최초 출력/재출력, Wi-Fi/USB/Print Station
- QR 주문/추가 주문, 취소/복원, 정산 함수

### 모드와 라우팅

- print→paperless, paperless→print, 빠른 연속 전환, 같은 요청 재전송
- 전환 직전/중/직후 주문과 기존 주문 추가 품목
- 포스 주문은 출력만, paperless 주문은 KDS만, 영수증 요청은 양쪽 모두 허용
- 앱 구버전/신버전 공존과 기존 RPC 호환

### 디지털 영수증

- token 추측·변조·revoked·없는 token·다른 매장 접근
- 같은 결제 ensure 중복, 두 장치 동시 요청, 재연결 재시도
- snapshot과 종이 영수증의 품목/합계/VAT/결제수단 일치
- 모바일/태블릿/데스크톱 보기, PDF, 브라우저 인쇄, KO/VI/EN
- 고객표시 payment QR와 receipt QR 구분, 오프라인 fallback, 자동 idle

### KDS

- Phone 4/Tablet 8슬롯, 페이지 이동, 카드 상세 전체 메뉴
- 키친→트레이→층별 완료, 허용 원복, downstream 처리 후 원복 거절
- 추가 주문, 중복 탭, 두 장치 경쟁, offline outbox, 마감 중 drain

## 18. 완료 기준

- 포스 프린트 모드의 주문·출력·결제·영수증·레드인보이스 회귀 결과가 기준선과 동일하다.
- 모드 전환 전 주문은 이전 방식, 전환 후 주문/추가 품목은 캡처된 방식으로 정확히 한 채널에만 전달된다.
- 페이퍼리스 키친·트레이·층별 화면이 Tablet 8슬롯, Phone 4슬롯이며 상세의 메뉴·완료·원복이 정상 동작한다.
- 페이퍼리스 결제 후 고객표시와 cashier fallback에 영수증 QR이 나타나고 공개 페이지/PDF/인쇄가 같은 금액을 표시한다.
- 종이 요청 시 최초 batch만 한 번 출력되고, 결제 이력의 명시적 재출력만 batch를 증가시킨다.
- 분할·통합·비매출 결제에도 영수증이 누락되지 않는다.
- QR, 프린터, 고객표시, MISA 중 하나가 실패해도 이미 성공한 결제가 롤백되거나 중복 생성되지 않는다.
- 다른 매장/층 데이터와 영수증 token이 노출되지 않는다.
- 관련 테스트, 전체 `flutter test`, `flutter analyze`, Web build, SQL preflight/verify/rollback, `bash scripts/check_repo.sh`, `git diff --check`가 통과한다.
- Critical/High 독립 회귀 이슈 0건과 실매장 파일럿 승인 후에만 확대한다.

## 19. 구현 전 확인할 제품 결정

계획의 기본값은 다음과 같으며, 변경 요청이 없으면 이대로 구현한다.

1. 모드는 새 주문/새 추가품목부터 적용한다.
2. 페이퍼리스 고객 영수증은 QR 기본, 종이는 요청 시 출력한다.
3. 통합 테이블 결제는 기존과 같이 주문별 영수증을 제공한다.
4. 고객표시 영수증 QR은 90초 후 대기로 돌아가며 cashier에서 다시 표시할 수 있다.
5. 공개 영수증은 보존 정책 기간 동안 유효하고 개별 revoke만 허용한다.
6. SMS/Zalo/이메일 발송은 v1에서 제외한다.
7. 적색 세금계산서 구현은 수정하지 않는다.
