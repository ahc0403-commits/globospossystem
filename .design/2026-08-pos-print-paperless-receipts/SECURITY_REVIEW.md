# 디지털 영수증 공개 QR 보안 검토

작성일: 2026-08-11
범위: 공개 영수증 링크·조회 API·브라우저 전달·DB 보존
상태: 코드 보완 및 로컬 공격 계약 검증 완료, 배포·운영 보안 승인 전

## 보호 대상과 비포함 정보

- 공개 snapshot: 매장/영수증 번호, 결제시각, 메뉴·수량·금액, 결제수단 종류, 현금 수령·거스름돈
- 포함 금지: 고객 이름·연락처, 카드/계좌 식별값, Red Invoice 접수 정보, MISA 상태·원문
- PDF는 브라우저에서 snapshot으로 생성하며 서버에 PDF 파일을 저장하지 않는다.

## 적용한 통제

| 위협 | 통제 |
|---|---|
| token 추측 | 24 random bytes(192-bit), 정확한 base64url 형식 검증 |
| DB 유출 시 링크 재사용 | DB에는 SHA-256 token hash만 저장 |
| URL/Referer/서버 로그 노출 | `/receipt#token=...`, preboot 메모리 handoff 후 `history.replaceState`, navigation history에는 `/receipt`만 저장 |
| 무기한 공개 | 발급 후 90일 만료, receipt/link revoke 확인 |
| 링크 무한 발급 | 영수증당 동시 활성 링크 최대 3개, receipt row lock으로 동시 발급 직렬화 |
| 보존량 증가 | 만료 30일 후 link hash batch 삭제, rate-limit HMAC row는 비활성 2일 후 삭제 |
| 직접 DB 우회 | anon/authenticated table read와 `get_public_receipt` 실행권한 제거, service role만 허용 |
| API 남용 | exact-origin CORS, POST 전용, 2KB body 제한, token 형식 검증, IP HMAC 기준 분당 30회/5분 차단 |
| 쓰기 증폭 | `last_presented_at` 갱신 최대 하루 1회 |
| 검색·캐시·클릭재킹 | no-store, no-referrer, noindex/noarchive, nosniff, frame deny 헤더 |
| 오류 기반 열거 | 없는/변조/만료/revoked token은 동일 `RECEIPT_UNAVAILABLE` 응답 |
| secret 유출 | rate-limit HMAC secret은 환경변수 이름만 배포 gate에서 검사하고 값은 코드·로그에 기록하지 않음 |

## 자동 검증

- Edge handler: 정상 조회, CORS/메서드 차단, 동일 안전 오류, rate-limit 선차단, backend 오류 비식별화
- Postgres runtime fixture: 활성 링크 3개, 정상/만료 조회, presentation write throttle, 만료 hash cleanup, 30회 허용/31회 차단, RPC privilege
- migration verify: expiry 컬럼, hash lookup, 고정 권한, active-link cap/row lock, Office `restaurants` 계약
- Flutter contract: token 없는 공개 route, fragment URL, navigation history 비식별화, Edge Function 전용 조회, 보안 헤더

## 남은 운영 위험과 배포 게이트

- 애플리케이션 속도 제한은 Supabase Edge Function에 도달한 뒤 실행된다. 비용형 DDoS를 앞단에서 차단하려면 Supabase/WAF 비용 상한과 트래픽 규칙이 별도로 필요하다.
- IP 식별은 Edge gateway가 전달하는 proxy header를 전제로 한다. 배포 전 실제 응답 환경에서 header 신뢰성과 spoof 차단을 확인해야 한다.
- `DIGITAL_RECEIPT_RATE_LIMIT_SECRET`은 32자 이상 난수로 운영 secret에 생성해야 한다. 누락 시 함수는 fail-closed 503이다.
- exact production origin, Vercel 보안 헤더, Edge 403/404/429 동작은 배포 후 smoke test가 필요하다.
- 독립 보안 검토/침투 테스트와 실제 다중 장치 E2E가 끝나기 전에는 production security approval로 간주하지 않는다.
