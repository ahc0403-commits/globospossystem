# 배달 주문 견적·고객 링크·결제 안내서 구현

작성일: 2026-10-13 · 시간 기준: Asia/Ho_Chi_Minh

상태: 소스 구현·로컬 검증 완료 / 운영 미반영

## 해결한 원인

운영 DB 함수 정의와 PostgreSQL 오류 로그에서 최초 견적 생성 실패를 확인했다. 공개 견적 RPC는 고객 직접 결제를 전달하지만, 실제 저장 함수 `direct_order_staff_quote_before_final_amount`는 새 견적을 먼저 매장 선결제로 INSERT했다. 정책 2 검증 트리거가 INSERT를 거부해 이후 결제 방식 UPDATE까지 도달하지 못했다.

소스의 기본값에 의존하는 저장 함수와 운영의 명시적 결제 방식 INSERT 변형 모두를 지원하는 additive migration을 추가했다. 최초 INSERT부터 배송 정책에 맞는 값을 저장하고 배송비 제외 및 검증 트리거를 유지한다. 포장의 `not_applicable` 지원 여부도 확인하며, 과거 주문과 이미 확정한 견적·결제 기록은 다시 계산하지 않는다.

기존 테스트가 견적을 직접 미리 INSERT한 뒤 견적 RPC를 재호출해 최초 저장 경로를 검증하지 못한 점도 보완했다. 이제 견적이 없는 새 주문으로 수정 전 오류를 먼저 재현한 뒤 수정 후 실제 RPC와 HTTP 호출을 확인한다.

## 캐셔 동작

- 선택 주문 상세에 서버의 예상금액을 표시한다. 확정 견적이 생기면 같은 위치에 확정금액을 고정해 품목 목록을 스크롤해도 확인할 수 있다. 예상금액은 미확정으로 표시하고, 조회 실패를 0원으로 바꾸지 않는다.
- 상품/VAT/서비스차지 계산은 제한된 서버 함수 하나를 사용한다. VAT 프로필과 기존 2자리 금액 반올림을 유지하며, 음식과 배송비를 다시 합산하지 않는다. 성공한 견적 저장 뒤 백그라운드 갱신이 실패해도 확인된 확정금액을 유지한다.
- 고객 주문 링크 복사와 고객 채팅 전송 버튼을 추가했다. 직원 권한 및 매장 범위를 확인하고, 주문별 무작위 키를 기존 주문 전용 접근 경로에 연결한다. 발급 기록은 해시만 보관하고 동일 작업 재시도는 링크·메시지를 중복 생성하지 않는다.
- 주문 링크는 번역 큐에 보내지 않는다. 고객과 캐셔 화면에서 URL을 그대로 표시하고 주문 링크용 열기/복사 버튼을 사용한다.
- 견적서 PDF 및 결제 안내서 PDF·PNG를 저장하거나 고객 채팅으로 전송할 수 있다. PDF는 전체 품목을 포함하고 PNG는 결제금액·계좌·QR·주문번호를 포함한 결제 요약 이미지다.
- 안내서 QR은 승인된 해당 매장 계좌와 서버의 미결제 잔액으로 생성한다. 최종 주문금액과 이번 송금 금액을 구분하고 배송 주문은 기사에게 배송비를 직접 지불하는 안내를 표시한다. 포장에는 기사 결제 안내를 표시하지 않는다.

링크를 외부 메신저로 전달할 때는 복사 버튼을 사용한다. 이번 작업에서 실제 고객에게 메시지를 보내거나 외부 메신저 자동 발송을 실행하지 않았다.

## 문서와 재시도 경계

파일 생성 직전에 상태·견적 ID/버전·미결제 잔액·승인 계좌를 조회한다. 파일을 고객 채팅에 연결하는 순간에도 같은 주문 잠금 안에서 다시 확인한다. 견적/계좌/잔액이 달라지면 이전 데이터로 만든 새 파일의 전송을 거부한다. 결제 완료·거절·종료 주문의 새 결제 안내서 생성은 차단한다.

업로드 응답 유실 시 같은 파일 경로와 바이트로 재시도한다. 이미 연결된 문서는 원래 메시지를 반환하므로 중복으로 전송하지 않는다. 문서 첨부는 일반 고객 채팅 첨부이며 입금 증빙, 결제 승인, 주문 완료, 재고 처리 또는 매출 생성으로 취급하지 않는다.

## 변경 경로

- `supabase/migrations/20261013020000_direct_order_quote_payment_guide.sql`: 실제 견적 저장 함수 보정, 공통 금액 계산, 상세 v6, 직원 링크 발급 및 상태 검증이 포함된 결제 문서·첨부 RPC.
- `lib/features/direct_order/direct_order_cashier_screen.dart`: 고정 금액, 링크·파일 동작, 재시도 상태 및 배경 조회 실패 처리.
- `lib/features/direct_order/direct_order_staff_service.dart`: 상세 v6, 링크·문서·검증된 문서 업로드 연결.
- `lib/features/direct_order/direct_order_payment_document.dart`: 3개 언어 견적 PDF·결제 PDF·결제 요약 PNG와 송금 QR.
- `lib/features/direct_order/direct_order_tracking_link.dart`, `direct_order_storefront_screen.dart`: 고객 주문 링크 표시.
- `supabase/functions/direct-order-public/index.ts`: 새 SQL 오류의 명시적 계약 등록. 신규 Edge 발송 액션은 추가하지 않고 기존 고객 접근·서명 업로드 경로를 사용한다.

## 검증

`bash scripts/check_repo.sh`가 종료 코드 0으로 완료됐다. 정적 분석, 전체 Flutter 테스트 2,065개 통과·97개 건너뜀, SQL·Edge·Node 및 배포 절차 계약 검사, 웹 릴리스 빌드와 변경 공백 검사가 통과했다. 일반 웹 빌드는 42.4초에 완료했으며 기존 Wasm 호환성·Cupertino 폰트 경고는 남아 있다.

검증은 운영 함수 정의/로그의 읽기, 격리된 PostgreSQL·PostgREST, Flutter 위젯 및 실제 문서 렌더링으로 나눠 수행했다. 운영 고객 주문을 수정하거나 거절 주문을 다시 열지 않았다.

확인한 항목:

- 견적을 미리 만들지 않은 새 주문의 원래 오류 재현과 최초 배달/포장 견적 생성.
- 확정 견적 재호출·동시 최초 견적 생성에서 견적 1개 및 견적 메시지 1개.
- 예상금액과 확정금액, VAT·서비스차지 및 이전 금융 기록 보존.
- 매장/주문 범위, 링크 발급·전송 재시도, 번역 큐로 접근 키 전송 금지.
- 계좌·잔액·견적 버전·종료 상태 검증, 첨부 재시도 및 결제/입금 증빙 생성 방지.
- 390/1440 너비와 한국어·베트남어·영어 금액 표시, 배경 갱신 실패, 응답 유실.
- 1·20·100품목의 3개 언어 PDF, 실제 PNG의 QR 해독 및 계좌/금액/참조 확인.

목록은 기존 기본 한도 100건, 상세·예상금액은 선택 주문 1건만 조회한다. 서버 계산·문서는 최대 100품목이고 직원 작업은 화면당 동시에 1개다. 문서 파일은 10 MiB 이하다. 품목별 원격 요청을 추가하지 않고 세율 프로필 계산은 순수 함수로 처리한다. 내부 계산에서 데이터 조회와 집계를 품목별로 반복하지 않는다.

실제 HTTP 측정은 격리 DB와 로컬 PostgREST를 사용한다. 운영 네트워크 지연·앱 메모리·현장 사용자 부하는 측정하지 않았으며 성능 개선 비율을 주장하지 않는다. 재조회 두 개가 필요한 기존 결제 후 프린터 상태 경로는 변경하지 않았다.

증거:

- [최종 저장소 검사 결과](/Users/andreahn/globos_pos_system/outputs/direct-order-payment-guide-20261013/verification.json)

- [HTTP 호출 및 동시성 측정](/Users/andreahn/globos_pos_system/outputs/direct-order-payment-guide-20261013/rpc_measurements.json)
- [PDF 내용 검사](/Users/andreahn/globos_pos_system/outputs/direct-order-payment-guide-20261013/pdf_validation.json)
- [실제 PNG의 QR 해독](/Users/andreahn/globos_pos_system/outputs/direct-order-payment-guide-20261013/qr_validation.json)
- [베트남어 결제 안내 이미지 — 테스트 계좌](/Users/andreahn/globos_pos_system/outputs/direct-order-payment-guide-20261013/payment-vi.png)
- [캐셔 화면 — 격리된 테스트 데이터](/Users/andreahn/globos_pos_system/outputs/direct-order-payment-guide-20261013/cashier-vi.png)

## 운영 반영

운영에는 추가 migration을 먼저 적용한 뒤 대응 앱과 오류 계약을 함께 반영한다. migration의 실제 저장 함수 앵커가 운영 정의와 다르면 원자적으로 중단하며 기존 함수를 임의로 덮어쓰지 않는다. 기본 저장 방식과 운영의 명시적 INSERT 변형을 각각 로컬에서 검증했다.

배포는 기존 `scripts/deploy_pos_production.sh`와 정확한 pushed head SHA의 필수 CI 성공을 거친다. 이번 작업에서 운영 DB 적용·웹 배포·실제 고객 전송은 실행하지 않았다. 운영 반영 후 실제 캐셔 계정, 고객 링크 새 브라우저, 서명 업로드, 모바일 은행 앱의 QR 읽기를 인수 확인한다.
