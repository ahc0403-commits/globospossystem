# 직접 주문 고객 화면·입금 캡처·전체 포장 출력 개선 기록

작성일: 2026-10-06, Asia/Ho_Chi_Minh.

배달·방문포장 주문의 세 가지 개선을 소스에 구현했다. 사용자가 확인한 누락 경로는 **Windows Print Station 자동 출력**이며, 추가 지시에 따라 고객 영수증뿐 아니라 **전체 출력폼**에 인원·일회용품 수량을 전달하고 표시하도록 보완했다.

| 상태 | 증거 |
|---|---|
| 소스 구현 | 완료. 아래 기능·SQL·출력·화면 검증 참조. |
| 운영 migration 적용 | 완료. 최종 main의 `20261006020000` 적용·운영 검증·history 확인. |
| 운영 Edge·웹 배포 | 완료. exact-main `d4741195`, 필수 CI 성공 후 공식 스크립트 exit 0. |
| Windows Print Station 패키지·설치 | 같은 main SHA의 ZIP 빌드·제공 완료. 현장 설치 SHA는 미확인. |
| 실제 종이·현장 포장 확인 | 미실행. 테스트는 payload·ESC/POS bytes·agent dispatch까지 검증. |

최종 운영 상태·깨끗한 main 전체 검사·배포·검증은 [release 기록](../operations/direct_order_integrated_release_20261006_d4741195.md)을 따른다. 아래 로컬 구현 당시 검증은 이력이며, 당시 dirty 작업 트리의 기존 실패는 배포한 fresh main에 포함되지 않았다.

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

## 변경 경계

- 초기 [migration 초안](../../supabase/migrations/20261006010000_direct_order_receipt_packing_context.sql)은 권한 검증 포장 조회와 새 print/digital snapshot 보강에 한정한다. 주문·인원 column을 중복 생성하지 않는다. 최종 운영 release에서는 main의 다른 migration과 timestamp가 겹쳐 `20261006020000_direct_order_receipt_packing_context.sql`로 변경했다.
- `process_payment`의 본문, 금액·VAT·재고·직원 사진 승인 경계와 MISA 비동기 처리를 유지한다. 기존 `PaymentService`는 시작 시점 파일과 동일하다. 사진 재시도·출력으로 결제나 조리 티켓을 다시 생성하지 않는다.
- 입력 범위 1~100명, JPEG/PNG/WebP 최대 5 MiB, private Storage와 세션 소유권을 유지한다. 사진 시도는 현재 화면 메모리에 보관한다.
- 시작 HEAD는 `cc4de81adb8870fd479cb12edd773cda635a01cd`였다. 기존 tracked/untracked 수정은 보존했다. [작업 전후 차이](evidence/direct_order_integrated_20261006/task-only.patch)와 [파일 해시](evidence/direct_order_integrated_20261006/changed-files.json)는 시작 시점의 작업 디렉터리를 기준으로 이번 변경만 기록한다. 이 patch를 다른 HEAD에 그대로 적용할 수 있다는 의미는 아니다.

## 검증

| 검사 | 결과·로그 |
|---|---|
| 관련 Flutter 서비스·화면·출력·PDF 회귀 | **139 통과**. [로그](evidence/direct_order_integrated_20261006/focused-final.log) |
| Edge 행동 테스트 | **21 통과**. 목록/다운로드 오류의 삭제 0회, 실제 이미지 불량 처리 확인. [로그](evidence/direct_order_integrated_20261006/edge-final.log) |
| Edge format·lint·type check | 통과. [type check 로그](evidence/direct_order_integrated_20261006/edge-check.log) |
| 로컬 PostgreSQL 승인→자동 enqueue→payload | 통과. 전체 전표·직원 수량 수정·기존 job 보존·권한·정상 홀/합산 snapshot 제외·payment anchor 보존 확인. [로그](evidence/direct_order_integrated_20261006/sql-final.log) |
| `dart analyze lib test --fatal-infos` | **No issues found**. [로그](evidence/direct_order_integrated_20261006/analysis-final.log) |
| `flutter build web --no-pub --release` | 통과. 기존 외부 패키지 wasm dry-run·Cupertino font 경고는 남음. [로그](evidence/direct_order_integrated_20261006/web-build-final.log) |
| 전체 Flutter | **1,708 통과 / 94 skip / 기존 실패 2건**. 전체 PASS 아님. [로그](evidence/direct_order_integrated_20261006/flutter-final-complete.log) |
| `bash scripts/check_repo.sh` | 전체 PASS 아님. 기존 감사용 Dart probe의 정적 검사 4건에서 중단. [로그](evidence/direct_order_integrated_20261006/check-repo.log) |

전체 Flutter의 남은 두 실패는 기존 `direct_order_arrival_alert_test.dart`의 생성 locale 해시 불일치와 `route_operational_state_coverage_contract_test.dart`의 Admin 테스트 제목 불일치다. 이번 변경에서 해당 테스트·locale 원본·감사 probe를 수정하지 않았다. 관련 테스트 통과를 전체 저장소 검사 또는 운영 release gate 통과로 표시하지 않는다.

## 운영 반영·현장 확인 단계 — 최초 작성 당시

1. 현재 사용자 작업을 보존하며 최종 release 변경을 검토 가능한 깨끗한 checkout에 통합한다. 정확한 pushed HEAD의 필수 GitHub Actions와 Windows 빌드 성공 증거를 확보한다.
2. `scripts/deploy_pos_production.sh`의 운영 gate를 따라 migration, Edge, 웹을 반영한다. 신규 포장 RPC가 있는 DB 버전과 해당 client 버전을 맞춘다.
3. 같은 release의 Windows Print Station을 현장에 설치하고 설치 SHA를 기록한다. 웹·DB만 반영해도 기존 Windows 출력 프로그램의 폼은 바뀌지 않는다.
4. 실제 배달·방문포장 주문 각각 3명을 선택해 고객 영수증과 실제 사용하는 주방·층·트레이·확인·인계 출력폼, 네이티브 재출력, 디지털/PDF에 3명·3세트가 나타나는지 확인한다. 일반 홀 주문은 포장 영역이 없어야 한다.
5. 입금 캡처 독립 전송·일시 실패 재시도와 직원 수량 수정 후 새 전표를 현장에서 확인한다. 운영 DB에 가짜 결제·매출을 생성하는 방식으로 대체하지 않는다.

소스에서 확인한 누락은 직접 출력·디지털 metadata 전달과 일부 전표 표시였다. 현장에서 누락된 특정 주문의 원인, 설치 버전, 실제 프린터 출력은 아직 확정하지 않았으므로 **운영 해결 완료로 판정하지 않는다**.

계획·최종 사양: [통합 계획](../plans/direct_order_integrated_customer_and_packing_improvement_20261006.md), [UI](../../.design/2026-08-direct-delivery-ordering/UI_SPEC.md), [API](../../.design/2026-08-direct-delivery-ordering/DIRECT_ORDER_API_CONTRACT.md), [locale](../../.design/2026-08-direct-delivery-ordering/DIRECT_ORDER_LOCALE_CONTRACT.md).

## 운영 반영 결과 — 2026-10-06

새 exact-main 작업 트리에서 필요한 변경만 최신 main과 통합하고 [PR #543](https://github.com/ahc0403-commits/globospossystem/pull/543)으로 병합했다. release SHA `d47411953e707243490cc2965082ee3fece35a5a`의 필수 GitHub Actions·Windows build가 성공했고, `scripts/deploy_pos_production.sh`로 DB `20261006020000`·Edge·웹을 운영 반영했다. fresh main 전체 검사는 38단계 PASS, Flutter 1,789 PASS / 94 skip / 0 fail이다.

실제 고객 화면의 카테고리 필터·고정 바, 운영 API, 기존 주문 8건의 6개 출력폼 payload·권한 RPC·새 디지털 metadata를 확인했다. 기존 결제/financial/전표와 결제/MISA 함수 해시를 보존했다. 검증용 주문·결제·실제 print job은 생성하지 않았다.

새 Windows ZIP은 제공했으나 현장 설치·실제 종이와 신규 로그인 smoke, 실제 고객 캡처 전송/재시도·직원 승인은 미검증이다. 운영 서비스 반영과 이 현장 확인을 구분한다. 상세 증거·파일·설치 안내: [release 기록](../operations/direct_order_integrated_release_20261006_d4741195.md).
