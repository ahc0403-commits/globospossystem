# 2026-10-23 배달 주문 장애 조사 증거

이 기록은 원인 조사 결과다. 앱 수정·운영 배포 결과가 아니다.

## 운영 메타데이터 확인

읽기 전용 Supabase 커넥터로 다음을 확인했다. 고객 정보·파일·세션 비밀은 수집하지 않았다.

| 항목 | 결과 |
| --- | --- |
| 현재 `direct_order_address_detail_valid` | `CHECK (length(btrim(detail_address)) >= 1 AND length(btrim(detail_address)) <= 300)` |
| 현재 `direct_order_public_submit_v2` | 상세주소 길이 `0~300` 허용 |
| 빈 문자열의 RPC 길이 조건 | true |
| 빈 문자열의 테이블 길이 조건 | false |
| 공백의 테이블 길이 조건 | false |
| 배달 주소의 상세주소 null | 위치 출처 제약의 non-null 조건 불만족 |
| `enqueue_direct_delivery_driver_receipt` | 상세주소 빈 값 거부 조건 존재 |
| `guard_direct_delivery_driver_receipt_job` | 상세주소 빈 값 거부 조건 존재 |
| 증빙 commit | 담당자 재제출 요청이 없으면 `quoted/active`만 허용 |
| 배포된 `direct-order-public` | version 52, 해당 전송·재제출 경로에 명시적 timeout/AbortSignal 없음 |
| Vercel 운영 배포의 표시 커밋 | `913a6459d71844abc2ec0d9220556addb2b9cfa4` |
| 로컬 HEAD | `58e0fa8f95117874ed9ebe71b8479cf066dc0c96` |
| 두 커밋의 조사 대상 Dart/Edge 디렉터리 차이 | 없음 |

최근 24시간 기본 로그 범위의 집계:

```text
postgres_logs:
  direct_order_address_detail_valid: 6
  PROOF_UPLOAD_INCOMPLETE: 4
  DIRECT_ORDER_PROOF_NOT_ALLOWED: 0
  DIRECT_ORDER_PROOF_REVIEW_NOT_ALLOWED: 0
```

오류 문자열이 관측된 횟수이며 고객 수·고유 주문 수가 아니다. 스크린샷의 주문과 개별 대응시키지 않았다. `PROOF_UPLOAD_INCOMPLETE`는 최초 전송 전 객체 조회에서도 발생할 수 있다. 오류 0건 역시 브라우저·Edge의 실패 부재를 뜻하지 않는다.

보안·성능 advisor도 읽었으나 해당 출력의 일반 RLS·인덱스 권고를 이번 장애 원인으로 판단하지 않았다. 실제 관련 인덱스는 `pg_indexes`로 별도 확인했다. 사진 경로 UNIQUE, 메시지 `(request_id, created_at, id)`, 열린 재제출 요청 UNIQUE, 입금 증빙 UNIQUE가 존재한다. 실행 계획과 처리량은 측정하지 않았다.

## 로컬 검증

실행 명령:

```sh
flutter test --no-pub test/direct_order_proof_retry_test.dart test/direct_order_recipient_policy_test.dart test/direct_order_support_test.dart --reporter expanded
flutter test --no-pub test/direct_delivery_storefront_widget_test.dart --plain-name 'screenshot' --reporter expanded
flutter test --no-pub test/direct_delivery_storefront_widget_test.dart --plain-name 'proof review asks for an image' --reporter expanded
deno test --config supabase/functions/direct-order-public/deno.json supabase/functions/direct-order-public/index_test.ts
flutter test --no-pub /tmp/globos-direct-order-proof-wait-20261023_test.dart --reporter expanded
```

순서대로 23 / 2 / 1 / 26 / 2건 통과했다. 원문 출력은 [test-output.log](test-output.log)에 있다. 마지막 2건은 현재 결함을 재현하는 진단이다.

재현 소스: [proof_wait_probe_test.dart](proof_wait_probe_test.dart). 저장소 루트에서 다음과 같이 다시 실행할 수 있다.

```sh
flutter test --no-pub docs/measurements/direct-order-address-proof-20261023/proof_wait_probe_test.dart --reporter expanded
```

주입한 미완료 Future를 가상 시간 5분 후 검사한다. 업로드/commit 단계에서 완료·오류가 모두 발생하지 않고 `outcomeUncertain=true`를 유지한다. Future를 해제하면 정상 완료된다. 이 테스트는 네트워크 실패가 원래 사례의 실제 원인이었음을 증명하거나 UI 전체의 실제 기기 재현을 대신하지 않는다.

## 수행하지 않은 검증

실제 고객 주문 생성·사진 전송·결제·승인, 사고 브라우저의 네트워크 추적, 실제 iPhone/Android 확인, DB INSERT 재현, 전체 저장소 검사·앱 빌드·부하 시험·배포는 수행하지 않았다. 계획 문서·증거 파일만 저장했다.
