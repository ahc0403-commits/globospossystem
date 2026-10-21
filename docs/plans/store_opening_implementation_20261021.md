# 매장 운영 구조 이행 기록

기준 커밋: `e22f9d3e89672e36bbad6c30db303c60bb6a8f26`

계획: [구조 진단·재검증 보고서](store_opening_architecture_review_20261021.md).
구현, 로컬 검증, 운영 적용을 별도로 기록한다. 미완료 단계는 완료로 취급하지 않는다.

| 단계 | 구현/검증 상태 | 활성화 조건 |
|---|---|---|
| 0 현행 계약 | 로컬 전체 기준선 통과, 운영 읽기 확인 | 기존 매장 fixture와 유효 운영 함수 확인 |
| 1 운영 프로필·명시 배정 | 기존 흐름 기록·조회 및 관리자 UI 검증 완료; 장치/새 흐름 활성화는 후속 단계 | 기존 계정·층·주문·설정 보존, 매장 범위/동시성 검증 |
| 2 메뉴·요청행 전체 연결 | 요청행 식별·결제 재고 집합 처리 구현/검증 중 | 모든 채널·스냅샷·금액·재고·출력 연결 검증 |
| 3 단계 진행·변경 작업 | 대기 | 취소/이동·준비 lot·알림·권한·복구 검증 |
| 4 모의 운영·게시 | 대기 | 설정 해시·장치 확인·동시 접수·부분 실패 처리 |
| 5 전환·대사 | 대기 | 전체 검사, 데이터 업그레이드/복귀, 현장 검증 |

## 운영 읽기 기준선

2026-10-21 읽기 전용 조회 결과. 고객·결제 상세·인증 비밀은 수집하지 않았다.
재현 쿼리는 `scripts/preflight_store_operating_profiles.sql`이다.

| 매장 | 현행 흐름 | 출력 모드 | 테이블 | 비보관 판매행 | 활성 배정 |
|---|---|---|---:|---:|---|
| BunsikClub Binh Thanh | kitchen_tray_floor | paperless | 44 | 86 | kitchen 1, tray 1, 저장 1F 1, 저장 2F 1 |
| JeonGabok Binh Thanh | kitchen_floor | paperless | 27 | 63 | kitchen 1, 저장 2F 1, 저장 3F 2; tray 없음 |

판매행 수는 내부 S/L·면/밥 투영을 포함하므로 고객에게 표시되는 메뉴 개수가 아니다.
날짜 형식 migration의 최신 버전은 `20261021150000`이다. `20261021130000` 명시적 층 인계,
`20261021120000` 층 배정, `20261021140000` QR 전체 미결제 이력 적용 기록을 확인했다.
짧은 숫자 형식의 과거 migration도 있어 단순 문자열 MAX는 최신 버전을 뜻하지 않는다.

| 함수 | 운영 정의 MD5 (변경 감지용) |
|---|---|
| process_payment(uuid,uuid,numeric,text) | be39d85b3e5ba56462745470db5a79db |
| cashier_move_order_items(uuid,uuid,uuid,jsonb,uuid) | eacb24e77dca0f70a554df3b095a76d2 |
| cashier_cancel_item_quantity(uuid,uuid,integer,integer,uuid,text) | 5eaed7e65e6f3c6d1c86d995a7a06354 |
| direct_order_prepare_combo_items(uuid,jsonb) | 8b44832696be6c606d37ffb9ed40b18f |
| kds_can_access_topic(text) | 82610f0bc6472dc01077b1ad25271793 |
| admin_apply_store_opening_config_v3(uuid,jsonb,jsonb,text,text) | f5a0e87d650895372ac16f32af33c598 |
| kds_complete_kitchen_batch_v1(uuid,jsonb) | abe67bbbf609f028e8f8c671dbb51e23 |
| kds_complete_customer_delivery_batch_v1(uuid,jsonb) | 2182d40e5131e43afed1a003e3ef5f85 |

이 조회는 배포/장치 시험이 아니다. 기존 계정 배정을 새 구조로 옮길 때 이름으로 다시 추정하지 않는다.
전가복 저장 3F의 활성 배정이 두 개라는 실제 상태를 유지한다.

## 소비자별 회귀 기준

| 소비자 | 연결/검증 대상 |
|---|---|
| 개점 관리자 | store_setup, 원자 저장·매장 접근·프린터 테스트·인력 준비 |
| 메뉴 관리자/Excel | 부모 메뉴·내부 판매 ID, 가격 키, 구형 파일의 옵션 보존 |
| POS/QR | 주문행·선택·초안·명시적 checkout, 전가복 미결제 서빙 이력 |
| 직접 주문 | 요청행→주문행, 엄격한 구버전 응답, 견적/승인/환불·세트 재고 |
| KDS | 시작/인계 분리, 부분 수량, FIFO 준비 lot, 층 매핑·알림·동시 재시도 |
| 이동/취소 | 분할 계보, 준비/서빙·조리 후 취소 소모, 복원 충돌·결제 경합 |
| 결제/출력 | 할인·VAT·잔액, 비동기 MISA, 원본 출력/재출력, 실제 옵션 표시 |
| 재고/보고 | 레시피·소모 시점, 세트/옵션 중복 차감·집계 방지, 구매/입고 정책 보존 |
| Office | restaurants 물리 테이블과 기존 읽기 계약 보존; Office 코드 변경 없음 |

## 단계별 실행 증거

### 0단계 기준선

- `bash scripts/check_repo.sh`: 정적 분석 통과, Flutter 2,445 통과/98 skip,
  기존 SQL·Deno 검사와 web build 통과. 실행 로그는 `/tmp/globos-architecture-baseline-20261021.log`.
- 메뉴 S/L·면/밥, 개점 출력 모드, 전가복 층 동기화 SQL도 별도 재실행 통과.
- 운영 `public,pos_invoice_private` 스키마만 읽어 격리 DB에 복원했다. 운영 고객/주문 데이터는 복제하지 않았다.

### 1단계 구성 기준 기록

- `20261021163000_store_operating_profiles.sql`: 매장·구역·스테이션의 고정 ID,
  변경 불가 구성 버전, 현행 설정 해시, revision 충돌/멱등 capture, 매장 관리자 권한.
  기존 runtime authority는 legacy로 제한한다. 구성 기록은 운영 경로를 전환하지 않는다.
- 관리자 개점 화면에서 현재 구성 확인→기준 기록을 제공한다. 구형 서버의 해당 RPC 부재만
  미지원으로 처리하며 권한·통신 오류는 숨기지 않는다. 한/베/영 지원.
- `scripts/test_store_operating_profiles.sh`: 동일 ID, 구역의 타 매장 연결 차단,
  실제 authenticated 역할의 RPC/테이블 접근, 불변 버전, stale revision,
  전가복 저장 3F 두 계정 보존, 2,000테이블 한도 통과.
  격리 측정: 소스 읽기 2회/2행(기록+반환), 총 약 6.15ms. 현장 p95가 아니다.
- `scripts/test_store_operating_upgrade.sh <public,pos_invoice_private schema.sql>` 통과:
  기존 함수 1,239개와 주요 테이블 15개 내용이 그대로 유지되고,
  변경 전후 전가복 시작→수량 인계→층 서빙 및 분식클럽 주방→트레이→층 서빙 통과.
- 신규/기존 개점 Flutter 테스트 31개 통과, store_setup 정적 분석 통과.
- 실제 장치 연결·출력, 운영 DDL, 배포는 실행하지 않았다.

### 2단계 중 주문행·결제 기반(2a)

- `20261021170000_direct_order_line_identity.sql`: 신규 요청행 UUID를 승인 주문행과
  배달/픽업 조리표까지 유지한다. 기존 완료 주문의 ID는 재작성하지 않는다.
  VAT·세트 스냅샷 맵은 메뉴 ID 대신 요청행 ID로 연결하고, 승인 행 전체를 한 번에 준비한다.
- 결제의 재고 차감은 ingredient ID 순서로 잠근 뒤, 주문행/원료별 원장과 원료별 잔량을
  집합으로 반영한다. 세금 계산·할인 배분 반영도 행별 SQL 반복 대신 일괄 처리한다.
  기존 가격/VAT 계산식과 반올림·할인 잔액 배분 규칙은 유지했다.
- 실 스키마의 세트 8%/10%, 부가세 포함/별도, 서비스 요금 on/off, 승인 재시도,
  일반 픽업, 가격/VAT 스냅샷·요청→주문→조리표 ID 검증 통과.
- 업그레이드 전에 만든 승인 대기 요청의 승인과 기존 승인 요청의 반복 처리도 통과했다.
- 주문 500행(각 3개+기조리 취소 1개), 완전 취소 1행(기소모 2개), 원료 2개에서
  2회 분할 결제, 정확한 1,002개 재고 원장, 중복 결제 거부 통과.
  최종 로컬 측정: 재고 집합 SQL 1회/1,002행/28.057ms, 두 결제의 가격 준비
  2회/2개 집계 결과/72.318ms, VAT 반영 2회/1,000행/182.091ms.
  측정된 문장만의 합계이며 결제 전체의 p95나 전체 SQL 호출 수는 아니다.
- `20261021171000_invoice_mapping_pending_marker.sql`: 기존 매핑 보류 trigger가 쓰는
  `invoice_mapping_required`를 CHECK가 거부해 비동기 작업이 남지 않는 오류를 보완했다.
  변경 전 코드에서도 같은 오류를 재현했으며, 수정 후 승인별 작업 1개 보존을 확인했다.
  실제 운영에서 누락된 작업의 존재/범위는 아직 확인하지 않았고 자동 재발행하지 않는다.
- 실제 이전 payment core를 같은 DB에 비교용으로 복원하고, 동일 주문 ID에서 이전 실행을
  subtransaction으로 되돌린 뒤 신규 실행과 대조했다. 세금 포함/별도 × 서비스 요금 on/off ×
  할인 없음/정률/정액/특정 행/전액 할인 20조합에서 행별 VAT·할인·결제·재고 원장·비동기 큐가 일치했다.
- 별도 두 connection의 동시 결제에서 공유 원료 2개, 결제 2개, 재고 원장 4개의 대사 통과.
- 일반 선택군, 요청행 기반 카트/구형 초안 변환, 새 선택의 출력·KDS 연결은 **미완료**다.
  이 때문에 기존 요청당 메뉴 중복 제약을 유지한다. 맵기/짜기 등 신규 선택이나 다중 주방을
  현재 매장에 활성화하지 않았다. 단계 2 전체 완료로 표시하지 않는다.

### 동시 작업과 migration 번호 조정

- 진행 중 최신 `origin/main` `6251f05790646e48527e2b9abf51ee6e7f54fba9`와 운영 읽기에서
  `20261021160000_all_store_sales_reporting.sql` 적용을 확인했다.
- 미적용 매장 구성 파일만 `20261021163000_store_operating_profiles.sql`로 변경했다.
  SQL SHA256 `d51f7e50a8df7d500e5f4b580d9f9b6fb1b37cd8ae46c9929fbfd8b64da19b5b`가 변경 전후 동일하다.
  163000의 로컬/최신 main/운영 이력 미사용과 local+main 경로 합집합의 버전 고유성을 확인했다.
- 운영에 적용된 160000 파일·migration history는 변경하지 않았다. 새 운영 스키마를 다시
  읽어 매출 집계 두 overload의 정의/권한 보존을 업그레이드 검증에서 확인했다.
  현재 운영 스키마의 기존 함수 1,239개 중 의도한 11개 외 정의 변경 없음,
  모든 기존 함수의 owner/ACL/security definer/search_path 보존을 확인했다.
  실 결제 fixture에서 전가복 1건 10,800 VND, 분식클럽 2건 21,600 VND,
  추가 등록 무매출 매장 표시, 두 overload 결과 일치와 일반 계정 접근 거부도 통과했다.
- 새 매출 함수 운영 MD5: `(date)` `5f32a8731128341ffd1593997b01d0c3`,
  `(date,boolean)` `c25e31662f27cbdcf428ff3fd6641b07`.

## 남은 완료 조건

일반 옵션/변형 등록과 세 채널의 행 식별, 옵션·구성품의 금액/재고/출력 연결,
일반 단계/라우팅 및 부분 취소·이동·복구, 모의 운영/검증 해시 게시 제어,
전체 migration 처음부터 재생, 전환·복귀와 현장 장치 검증은 남아 있다.
현재 실행한 격리 업그레이드 검증은 현재 운영 스키마에 새 migration을 적용한 시험이며,
과거 모든 migration의 신규 DB 재생이나 운영 배포를 뜻하지 않는다.
