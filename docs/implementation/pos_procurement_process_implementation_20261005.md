# POS·Office 구매 프로세스 구현 결과 — 2026-10-05

[전체 개선 계획](/Users/andreahn/globos_pos_system/docs/plans/pos_procurement_process_improvement_20261005.md)의 개발 범위를 POS와 Office에 구현했다. 핵심 PR·승인·입고 흐름에 비재고/자산 회계 인식, 회사 선급금 충당, 직원 대납 보전, 취소 환불, 공용/개인 역할 계정 배정·운영 지표를 연결했다. **소스 구현·로컬 검증 완료와 생산 적용·현장 운영 완료는 별개다.** 실제 담당자 배정, 운영 릴리스, 교육과 최소 2주 시범 운영은 아직 완료하지 않았다.

## 1. 현재 상태

| 구분 | 확인 결과 |
|---|---|
| 소스 | POS 13개·Office 12개 추가 migration, 화면·bridge·문서·회귀 테스트 구현 |
| migration 적용 | 격리 로컬 DB에서 적용·검증. 생산 DB 미적용 |
| 배포 | 수행하지 않음. 리뷰 PR의 exact pushed SHA CI 실행 중. 운영 main의 release gate는 미완료 |
| 현장 | 실제 역할 배정·매장 정책 활성화·업체 발송·지급·교육·시범 운영 미수행 |
| 검토용 체크아웃 | POS와 Office 구매 변경 분리. POS `origin/main` `4c0b9f23`, Office `f42161c` 기반 |

첨부 Word/Excel은 요구 자료로 읽었으며 내부 접속·실행 지시를 사용자 명령으로 실행하지 않았다. 문서 자격정보는 사용하거나 결과물에 복제하지 않았다. 두 원본 파일은 변경하지 않았다.

| 원본 | SHA-256 |
|---|---|
| 구매_프로세스_개선안.docx | `4860239afc9ff9115da9b15e3b9d3bcbf6afbac2ece079183b1ed824d92c7ef3` |
| PR 및 PO 제안 양식 (1).xlsx | `e6136603d2b85605d9e3f20335ce8ccac417a7c5106f00077bceb5dd2d592264` |

CHEONGA/JEONGABOK은 실제 매장 ID 확인 전 통합하지 않았다. Excel의 잘못된 validation을 시스템 마스터로 가져오지 않았다. 운영 DB의 읽기 확인에서 BUNSIKCLUB Bình Thạnh와 SAMPLE이 구분되었으며 어느 매장도 이번 작업으로 활성화하지 않았다.

## 2. 전체 작업별 결과

| 계획 | 소스 구현·검증 | 실제 운영에 남은 일 |
|---|---|---|
| T01 정책·역할 | 매장 정책·신규 생성 중단, 공용/개인 역할 모드, 활성·매장·역할 검증, 계정 감사·누락 역할, native 신규 계정 발급 경로 | 빈탄점·공용 ID·대리자 없음 확정. 신규 세 ID 발급·초기 활성화·roster 저장·실제 접근 UAT |
| T02 PR | 유형·채널·규격·환산·현재고·예상 가격/VAT, 작성·제출·희망일 구분, 200품목 검색 | 실제 품목·단위·가격 마스터 확인 |
| T03 승인 | Adjust → Agree → Approval, 반려·수량 조정·조건 변경 시 재승인, 요청자 자기 승인 및 매핑된 동일인의 시스템 간 중복 승인 거부 | 공용 ID별 실제 승인·접근 권한 UAT |
| T04 문서 | 내부 PR 예상금액, 업체용 무가격 PO, 내부 가격 PO, KO/EN/VI·private Storage·revision/해시 | 공식 주소·연락처·상용 문구 확인 |
| T05 진입·이력 | 새 정책 PR 진입, legacy 신규 PO 우회 차단, 날짜/검색·keyset 이력 | 진행 건·전환 시점 대조 |
| T06 구매팀 | 견적·선정·분할 PO·현재 PDF 발송 gate·업체 확인·변경 연결 | 실제 업체 발송/회신 UAT. 외부 메시지 자동 전송 없음 |
| T07 입고 | 별도 검증자·원자적 재고, 6+4 부분입고, 회차별 합격·거절·잔량 | 실제 단위·검수 증빙·현장 담당자 확인 |
| T08 후속 | 실제 후속 확정 입고/교환·반품·취소 잔량·게시된 credit 검증 | 실제 반품·Invoice 조정·환불 UAT |
| T09 대조/AP | 원본 필수·라인/VAT/중복/순입고 대조·변경 보류·지급 상태 mirror | 실제 동기화·부분 지급·마감 대조 |
| T10 비용/자산 | 실제 비용계정·고정자산/CCDC 등록 선택, 취득 clearing에 인식, 기존 자산 원장으로 자본화, 재고 미생성·이중 인식 거부 | 회사의 실제 계정·자산 기준·등록·책임자/위치 확정 |
| T11 Shopee | 플랫폼 주문·직원 ID·원 선결제 연결, 실제 회사 출금/환불 전표, AP 선급 충당·직원 채무 전환·보전, 한도·중복 지급·취소/역분개 통제 | 실제 현금/은행·선급 계정·직원 원장 대조 및 UAT |
| T12 SOP·교육·시범 | 역할별 SOP, 실제 시범/UAT 기록 양식·운영 전환표 준비 | 실제 교육·매장 처리·마감 대조·최소 2주 관찰 |
| T13 반복·평가·KPI | 기존 사람 검토형 보충 제안·업체 평가 재사용, 90일 승인 대기·입고 대기·미결 이슈·무가격 문서·회계 보류 지표 | 실제 기준선·SLA 확정 및 운영 후 평가 |
| T14 N+1 | 부모 페이지 먼저 조회, set-based 집계·bounded batch·선택 상세, 호출 수·payload·대량 EXPLAIN | staging/생산 네트워크 포함 p50/p95·실제 분포 확인 |

## 3. 중요한 업무 통제

### 승인과 문서

신규 PR은 생성 시 policy 2를 고정하며 기존 policy 1의 승인·회계 snapshot hash를 보존한다. 선택한 가격·VAT·수량 조건 변경은 재승인을 요구한다. 실제 principal과 시각·표시 이름을 기록한다. 이름/이메일로 동일인을 추정하지 않고 관리자와 HR의 명시 매핑을 사용한다. 담당자 roster는 책임과 식별을 기록한다. **기존 Auth 권한을 부여하거나 만료시키는 기능은 아니다.** 실제 역할/위임 권한은 기존 권한 관리에서 별도로 설정해야 한다. 공용 역할 계정은 HR person 없이 배정하며 같은 계정의 승인 분리를 유지한다. 서로 다른 공용 ID를 사용하는 개인의 동일 여부는 보장하지 않는다. 개인 모드는 기존 명시 HR 매핑을 유지한다.

업체용 PO의 API와 PDF는 명시 허용 필드만 출력하며 가격·VAT·합계·은행·내부 승인 증거를 제외한다. 파일 경로에는 매장·종류·대상·source hash·file hash를 포함하고 기존 파일을 덮어쓰지 않는다. 현재 revision의 업체용 PDF가 있어야 발송을 기록한다. 자동 이메일/메신저 전송은 추가하지 않았다.

### 입고·후속·회계 원본

10개 중 첫 6개 후 두 번째 4개는 두 번째 회차의 잔량과 비교한다. 재고 품목만 원자적으로 한 번 반영한다. 비재고와 자산은 가짜 재고 품목·stock transaction을 만들지 않는다. 추가 납품/교환 종결은 실제 같은 매장·업체·품목의 후속 확정 입고를 선택한다. Credit은 원 Invoice와 조정 관계가 있는 실제 게시 전표만 인정한다.

알려진 v2 PO의 원본 필수 marker는 snapshot 캐시 소실에도 남는다. 원본 없음·오래됨·가격/VAT/수량 차이·중복 allocation·반품 후 변경은 보류한다. 결제 증빙 metadata 추가만으로 상업·입고 hash를 무효화하지 않는다. POS 지급 요약은 금액/은행을 제외하고 10분 경과·버전 차이를 갱신 필요로 표시한다. 조회 요약으로 지급을 승인하지 않는다.

### 비재고·고정자산·CCDC

Invoice 라인마다 기존 활성 postable 비용계정 또는 취득 clearing 계정을 선택한다. 자산 라인은 실제 같은 매장의 고정자산/CCDC 등록과 취득원가·credit 계정·책임자·위치를 검증한다. Invoice 게시 시 비용/clearing의 복수 차변과 AP 대변을 균형 있게 기록한다. 실제 자본화는 기존 ACC-XLS-13 승인·활성화 경로에서 취득 자산 차변/clearing 대변으로 처리한다. 이미 자본화한 자산을 먼저 중복 인식하거나 Invoice 진행 중 연결된 원가·credit 계정을 바꾸지 못한다. 회사별 계정번호나 임의 자산 등록을 새로 만들지 않았다.

### 회사 선결제·직원 대납·환불

구매의 채널 기록은 회계 출금을 실행하지 않는다. 직원 대납은 Auth UUID와 별개인 실제 Office HR 직원 ID 및 원 선결제 ID를 보존한다. 다른 직원의 선결제에 환불/보전을 연결하거나 원 기록의 남은 금액을 넘길 수 없다. 직원 검색은 페이지 크기 200으로 제한한다.

Finance에서 기존 현금·은행·총계정원장 기능으로 승인·실행·게시한 전표를 선택한다. 실제 분개·매장·증빙·금액·원 Invoice 조정 또는 선급 정산 영수증 관계를 서버에서 확인한다. 회사는 현금 출금의 선급자산 차변과 동일 계정의 AP 충당 대변을 연결한다. 직원은 공급업체 AP를 실제 같은 직원의 채무로 전환하고 실제 직원 보전 출금과 연결한다. 직원 보전이 공급업체 AP를 다시 지급하지 않는다.

Invoice 전 회사 선결제와 취소 환불은 별도 AP를 만들지 않고 실제 현금 전표에 연결한다. 기존 현금 기능이 증빙을 전표 헤더 대신 원 cash workflow에 보관하는 경우에도 실제 서명/정산 영수증과 게시 관계를 확인한다. 과거 게시 전표를 사후 수정하지 않는다. 전표 검색은 증빙 집합을 먼저 결합해 20개 헤더만 반환하며 선택 2개와 현재 페이지만 화면에 유지한다.

게시된 실제 충당만 AP의 paid/settled 금액에 합산한다. 추가 회사 지급은 기존 지급액과 충당액을 합친 잔액을 넘길 수 없다. 충당/자금 전표가 역분개되면 잔액을 재계산한다. 선결제 보류 해제에는 기존 회계 통제를 유지한다. 같은 증빙·금액의 재시도는 새 키로도 기존 결과를 반환하고 금액 변경은 거부한다.

## 4. 조회 계약과 성능 증거

| 경로 | 조회 계약 |
|---|---|
| PR/PO 목록 | 기본 20, 최대 50 요약·keyset. 전체 line/quote/receipt 이력 제외 |
| 선택 상세 | 200라인; 견적/입고20·이슈/반품50·감사100 |
| Office 다중 매장 | 100매장/200PO batch. 1/20/100/200매장 mock은 1/1/1/2 호출 |
| snapshot/회계 상태 | 50PO batch. 20/100/200PO mock은 1/2/4 읽기, PO별 fallback 없음 |
| 화면 | 20/100요약 × 1/20/200라인 초기+선택 총 2읽기 |
| 수요/업체 | 원장·입고·할당·이슈를 GROUP BY 후 조인, 상관 SubPlan 없이 집계 |
| 새 Finance 선택 | 20개 게시 전표 검색, 200개 계정/자산/직원 선택 검색. 전체 GL/HR 이력 다운로드 없음 |

로컬 100/1,000/10,000건 fixture에서 수요 원장 scan loop는 모두 1이며 supplier·50건 snapshot·20건 목록의 payload는 거의 일정하다. 목록은 부모 페이지를 먼저 고른 뒤 업체를 붙이고 단일 매장 index를 사용한다. 10회 DB 실행 샘플의 p50/p95와 9개 `EXPLAIN (ANALYZE, BUFFERS)` 원본을 [성능 evidence](/Users/andreahn/globos_pos_system/docs/implementation/evidence/procurement_20261005/read_performance.json)에 저장한다. 네트워크 시간은 제외되며 로컬 가드 1,500ms를 생산 SLA라고 주장하지 않는다. 실제 호출 수는 HTTP mock/화면 테스트 근거이고 성능 JSON의 API 수치는 조회 계약 표기다.

이번 구매 범위의 행별 HTTP 조회와 주요 내부 상관 집계를 제거했다. 다른 POS 도메인 전체에 N+1이 없다고 판정하지 않는다. 쓰기는 문서별 원자성·재시도 계약을 유지한다.

## 5. 검증 결과와 한계

| 검증 | 결과 |
|---|---|
| POS 전체 구매 SQL suite | PASS: 기존 v2/동시성/입고·upgrade hash·새 승인·문서·부분입고·후속·직원 소유·roster·metrics·page·성능 |
| Office 구매 SQL suite | PASS: 원본/대조/AP·보류·credit·비재고/자산·native Invoice 게시·선급 충당·직원 채무/보전·현금 환불·한도/재시도/역분개 |
| POS 구매 Flutter | 23 passed + 전체 대화상자 141개 coverage contract |
| Office 구매 Flutter + 기존 기능 | 47 passed (25 focused + 기존 22 기능, golden 제외) |
| POS/Office focused analyze | No issues found |
| Office bridge | `deno check` PASS. 최신 main 통합 후 review 100 passed (공용 모드·위조 확인·권한/타 매장·HR 생략·개인 모드 회귀 포함) |
| Office i18n | KO/EN/VI 세 검사 PASS |
| PDF | 양쪽 합계 12개, 각 200라인·날짜·비고·PR 합계·외부 비공개 필드 제외 확인 |
| 웹 build | 양쪽 PASS. Office wrapper 사용. POS의 기존 폰트/wasm 관련 경고는 남음 |
| 기존 Office golden 4개 | 수정 전 `07b2...`에서 동일 실패 재현, 실제 이미지 SHA가 현재와 4개 모두 동일. baseline 미갱신 |
| 원본/번호 | 입력 두 hash 불변, 두 저장소 migration version 중복 없음 |

native Finance 테스트는 실제 Invoice 게시·원장 연결 SQL을 실행하되 격리 fixture의 권한/workflow 일부를 stub으로 구성한다. 실제 계정의 전 과정 승인·현금 실행·자산 승인 E2E를 대신하지 않는다. 이전 정확한 PR SHA의 GitHub 전체 테스트는 POS 1,703 passed/94 skipped, Office 2,322 passed였고 필수 검사도 통과했다. 공용 ID 변경 후 최종 새 SHA의 CI 결과는 외부 릴리스 검증 기록에서 확인한다. 생산 부하·실제 지급/실물 UAT·운영 main release gate는 미완료다. Office의 달력에 의존하던 HR planning golden은 고정 기준일과 날짜 전후 회귀 검사로 보완했으며 기준 이미지는 변경하지 않았다.

[최종 검증 요약](/Users/andreahn/globos_pos_system/docs/implementation/evidence/procurement_20261005/validation_summary.json)과 [파일 snapshot](/Users/andreahn/globos_pos_system/docs/implementation/evidence/procurement_20261005/source_manifest.json)을 확인한다. snapshot은 현재 파일의 해시이며 공유 작업공간의 전체 변경이 이번 작업만의 변경임을 보장하지 않는다.

## 6. 릴리스·시범 운영

POS migration `20261005030000`~`20261005043000` 13개: 계약 → 문서/채널 → page → 집계 → 후속/비재고 → Storage → legacy → 상태 → roster/metrics → index → 매장 검증 fixed-account 준비 → 공용 역할 roster → 직원 지급 소유. 운영에 적용된 별도 `20261005038000_office_store_batch_reads`와 번호가 겹쳐 미적용 구매 직원 소유 migration을 `20261005043000`으로 분리했다.

Office 구매 migration `20261005020000`~`20261005029000` 및 `20261005032000`/`20261005033000` 12개: 원본 → 선결제 hold → credit → 이력 → 상태 → 계정/자산 인식 → native 정산 → Finance 화면 조회 → Invoice 전 현금 → 계정/자산 검색 → 개인 HR 역할 확인 → 매장 구매 native 템플릿. 기존 canonical Finance/HR migration이 선행되어야 한다. 동시 작업의 `20261005030000`/`20261005031000`을 보존하고 구매의 HR 역할 확인을 `20261005032000`으로 분리했다.

POS의 11개 외부 read-only post-apply 검증 SQL과 두 개 embedded 검증을 준비했고 각 migration 직후 격리 DB에서 실행했다. 배포 스크립트의 convention gate를 우회하지 않는다. 인덱스/조회 migration은 하나의 원자적 transaction으로 묶었다.

두 DB migration을 버전순으로 준비하고 기존 기능을 유지한 채 bridge/UI를 릴리스한 후 검증된 매장만 새 정책을 활성화한다. 매장·역할·실제 계정·마스터 확인 → 정확한 head SHA의 필수 CI → 운영 배포 승인 → migration/앱 적용 → 역할별 UAT → 교육·최소 2주 시범 → 확대로 진행한다. 배포 후 현장 확인 전에는 완료 상태를 올리지 않는다.

[운영 SOP](/Users/andreahn/globos_pos_system/docs/operations/pos_procurement_sop_20261005.md), [전환·시범 기록](/Users/andreahn/globos_pos_system/docs/operations/pos_procurement_rollout_20261005.md), [UAT 기록표](/Users/andreahn/globos_pos_system/docs/operations/pos_procurement_uat_20261005.csv)를 준비했다. 빈탄점·SM/BM 기존 ID·신규 세 역할 ID·공용 사용·대리자 없음 조건을 사용자 답변대로 반영했다. 신규 Auth 계정/roster는 아직 운영에 저장하지 않았다. 비밀정보 없는 native 발급 명세를 준비했다.

기존 사용자 변경은 보존했다. 원 Office Git의 `pack too short`/bad HEAD는 삭제·복구하지 않았다. 건강한 별도 clone에서 확인한 origin/main에 구매 변경만 적용했고 동시 작업의 store batch/sales 변경은 원 체크아웃에 보존했다. 최초 backup이 없는 Office page와 three-way 파일은 건강한 baseline과 구매 추가 부분을 대조했다. 완전한 작업 전 snapshot을 주장하지 않는다.

검토 위치: [POS](/Users/andreahn/.codex/worktrees/procurement-process/globos_pos_system), [Office](/Users/andreahn/Documents/procurement-release-20261005/office). 모두 `codex/procurement-process-20261005` 로컬 branch에 구매 변경을 commit으로 보존했다. 구매 변경을 push하고 [POS #537](https://github.com/ahc0403-commits/globospossystem/pull/537), [Office #168](https://github.com/ahc0403-commits/restaurant_office_app/pull/168) draft PR을 만들었다. CI는 실행 중이며 merge/운영 배포는 수행하지 않았다. 새 상품/정책 대화상자의 실제 취소·검증·확인 동작과 coverage inventory를 보완했다. 정확한 최종 SHA와 CI 결과는 [릴리스 검증 기록](/Users/andreahn/Documents/procurement-release-20261005/release_verification.md)에 별도로 보존한다. 운영 릴리스는 POS `scripts/deploy_pos_production.sh`, Office 기존 gate/wrapper를 사용하며 Office는 clean exact origin/main, migration history 해결, 명시 확인이 필요하다.

복구는 신규 PR 생성 중단과 호환 릴리스로 진행한다. 확정 재고·반품·지급을 삭제하거나 증빙 금액으로 실제 원장을 대체하지 않는다.
