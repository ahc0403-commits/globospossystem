# 직접 주문 고객 화면·입금 캡처·전체 포장 출력 개선 기록

작성일: 2026-10-06, Asia/Ho_Chi_Minh.

배달·방문포장 주문의 세 가지 개선을 소스에 구현했다. 사용자가 확인한 누락 경로는 **Windows Print Station 자동 출력**이며, 추가 지시에 따라 고객 영수증뿐 아니라 **전체 출력폼**에 인원·일회용품 수량을 전달하고 표시하도록 보완했다.

| 상태 | 증거 |
|---|---|
| 소스 구현 | 완료. 아래 기능·SQL·출력·화면 검증 참조. |
| 운영 migration 적용 | 미실행. 로컬 격리 PostgreSQL에서만 적용·검증. |
| 운영 Edge·웹 배포 | 미실행. 로컬 release 웹 빌드만 완료. |
| Windows Print Station 배포·설치 | 미실행. 현장 설치 SHA도 미확인. |
| 실제 종이·현장 포장 확인 | 미실행. 테스트는 payload·ESC/POS bytes·agent dispatch까지 검증. |

## 구현 결과

1. 메뉴 화면 상단에 `전체`와 매장 카테고리를 고정했다. 메뉴를 내려도 바가 남으며, 선택한 카테고리만 필터링한다. 장바구니·메모·입력 인원은 카테고리·언어·배송지 왕복에서 유지한다. 모바일 스와이프, 데스크톱 방향 버튼, 긴 이름과 빈 메뉴를 처리한다.
2. 주문 현황에 `계좌이체 안내`와 `입금 캡처 보내기`를 각각 배치했다. 캡처 선택·미리보기·취소·진행·실패를 구분하고 같은 사진으로 재시도할 수 있다. 업로드 결과가 불확실하면 동일한 주문·견적·재요청 ID와 경로로 접수를 먼저 확인한다. 전송 성공 뒤 현황 조회가 실패해도 전송 완료를 유지한다. Edge의 Storage 일시 오류는 재시도 가능한 오류로 분리하고 유효한 사진을 삭제하지 않는다.
3. 아래 모든 출력 경로에서 배달·방문포장 주문의 `식사 인원 N명 / 일회용품 N세트`를 메뉴 위에 표시한다. 종이는 기존 베트남어 정책에 따라 `SO NGUOI: N`, `DUNG CU: N BO`이며 세트 수는 굵고 두 배 높이다.

| 출력폼 | 데이터·표시 보완 |
|---|---|
| 고객 결제 영수증·큐 재출력 | 새 print job에 인원·수령 방법·주문 참조번호를 보강하고 agent에서 builder로 전달. |
| 주방·층 전표·트레이 라벨·주문 확인 전표 | 같은 packing payload와 공통 표시 영역 사용. 기존 라우팅·출력 부수 유지. |
| 기사·직원 인계전표 | 공통 포장 영역으로 같은 수량 표시. |
| 결제 상세 네이티브 직접 출력 | 매장·직원 권한과 주문 연결을 확인하는 단건 읽기 RPC 사용. |
| 디지털 영수증·80mm PDF | 새 단일 direct 주문 snapshot에 metadata를 보강하고 화면·PDF에 표시. |

수량은 주문당 총 세트 수다. 예를 들어 인원 3명, 메뉴 수량 7개, 층 전표 2부여도 **각 전표는 3세트**다. 일반 홀 주문의 손님 수를 일회용품 수량으로 표시하지 않는다. direct 주문의 인원이 누락·범위 밖이면 직원 확인 필요를 표시하고 1명으로 추정하지 않는다.

기존 출력 job과 디지털 snapshot은 수정하지 않는다. 인원 3명으로 생성한 기록은 3명을 유지하며 직원이 5명으로 수정한 뒤 생성하는 새 재출력·인계전표에 5명을 사용한다. 합산 디지털 영수증은 단일 주문 수량을 임의로 넣지 않는다.

## 최신 main 통합과 release 경계

사용자의 운영 release 지시에 따라 2026-10-06 새 managed worktree를 만들었다.
기준 main은 `2991ed405cfcabacdccebc6a1a41bf6742a861a8`이다. 원래 작업 디렉터리의
tracked/untracked 수정은 옮기거나 초기화하지 않고 이번 변경만 3-way 통합했다.
최신 main의 배달/포장 선택, 영업시간 refresh clock, pickup KDS와 Grab 결제 모드,
추가 SQL 오류 registry를 보존했다. 320px 화면의 장바구니 검증은 실제 메뉴 scroll
후 클릭하도록 갱신했다. 기존 Direct Order payload도 인원 누락 시 확인 안내를 표시한다.

- `process_payment`, `PaymentService`, 금액·VAT·재고·직원 승인 경계와 MISA는 그대로다.
- 신규 migration은 권한 검증 단건 포장 context와 새 print/digital metadata에 한정한다.
- 운영 SQL 검증은 기존 실제 주문, 배포된 함수와 임시 테이블을 사용한다. 고객 주문,
  결제, 실제 print queue에는 테스트 데이터를 생성하지 않는다.
- 공식 `scripts/deploy_pos_production.sh`와 정확한 pushed main SHA의 필수 CI를 사용한다.
  Windows 패키지도 같은 SHA의 GitHub Actions artifact로 제공한다.

## 검증 상태

최신 main에서 관련 기능·전체 저장소·SQL·Edge·Windows 빌드 및 운영 검증을 진행한다.
원래 작업 디렉터리의 기존 실패 2건과 감사 probe는 최신 main에 함께 가져오지 않았다.
새 release 결과를 해당 SHA의 CI·공식 배포 로그·운영 검증·artifact hash로 기록한다.
실제 Windows 현장 설치와 물리 프린터 출력은 원격 확인 증거가 없으면 확인 완료로 표시하지 않는다.

최종 사양: [통합 계획](../plans/direct_order_integrated_customer_and_packing_improvement_20261006.md),
[UI](../../.design/2026-08-direct-delivery-ordering/UI_SPEC.md),
[API](../../.design/2026-08-direct-delivery-ordering/DIRECT_ORDER_API_CONTRACT.md),
[locale](../../.design/2026-08-direct-delivery-ordering/DIRECT_ORDER_LOCALE_CONTRACT.md).
