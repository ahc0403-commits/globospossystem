# 데이터 접근 성능 개선 구현·실측 — 2026-10-11

> 이 문서는 당시 소스 검증 기록이다. 최신 main 통합·운영 적용 절차와 API 버전은 [통합 배포 문서](../../pos/POS_RECIPIENT_TAX_BOUNDED_RELEASE_20261011.md)를 참조한다.
## 결과와 범위

[개선계획](/Users/andreahn/globos_pos_system/docs/plans/data_access_performance_improvement_plan_20261010.md)의 W0–W7을 구현하고, 실제 앱 함수·SQL·Excel 파서·Edge handler를 실행해 개선을 검증했다. 요청 병합, 범위 제한, 페이지 선택 후 상세 조회, 일대다 사전 집계, 입력 제한, 작업 소유권과 제한된 재시도를 적용했다.

미커밋 사용자 변경을 보존했다. **운영 DB 변경·배포·MISA 활성화는 하지 않았다.** 격리 실측과 운영 성능은 구분한다. 저장소 전체에 성능 위반이 없다는 판정이 아니라, 감사에서 선정한 경로의 구현·회귀·실측 결과다.

[재현 방법·증거 목록](/Users/andreahn/globos_pos_system/docs/audits/data_access_20261011/README.md) · [환경](/Users/andreahn/globos_pos_system/docs/audits/data_access_20261011/environment.json) · [원시 분포 요약](/Users/andreahn/globos_pos_system/docs/audits/data_access_20261011/metrics_summary.json)

## 전후 실측

시간은 각 입력/모드 **20회 중앙값(p50)**이다. p95와 개별 표본도 저장했다. MB는 1,000,000 B이다. RSS는 각 독립 프로세스의 최대 RSS를 모아 구한 중앙값으로, 전체 실행 중 가장 큰 단일 RSS와 다르다.

| 대상·동일 입력 | 개선 전 → 후 | 검증 근거 |
|---|---|---|
| 테이블 갱신 100회 동시 진입 | HTTP **200→4**, 최대 동시 **100→1**, 본문 **2,617,200→52,344 B** | 실제 provider + 모의 전송. 전후 동일 20ms 지연·테이블/주문 fixture. 이 burst 측정은 20회 시간 비교가 아님 |
| 관리자 최초 조회 + 강제 갱신 100회 | HTTP **101→2**, 최대 동시 **100→1** | 실제 notifier + 모의 전송 |
| 발주 상세, 상품 1개·과거 발주행 10,000개 | 전체 HTTP **8→7**, 응답 **7,299,279→1,876 B**, 최대 URL **450,265→576 B** | 실제 service + 모의 전송. 이력 3개 동일. 서버 scan 측정과 별개 |
| 메뉴 분석, 조회일 주문 100개·과거 주문 100,000개 | 서버 p50 **116.675→7.031ms**, 응답 **37,287 B 동일** | 실제 유효 SQL 전후, 격리 PostgreSQL 15 |
| 재고 원가, 대상 상품 100개·타 매장 상품 100,000개 | 서버 p50 **49.007→3.266ms**, 응답 **25,092 B 동일** | 실제 유효 SQL 전후, 격리 PostgreSQL 15 |
| 개인 급여, 직원 1,001명에서 1명 | HTTP **9→3**, 반환 **3,003→3행**, 본문 **918,581→1,198 B**, p50 **189.342→8.030ms** | 실제 Supabase 17/PostgREST, 유지한 전체 조회 API와 직원 조건 비교 |
| 일별 보고서, 증빙/발행 예외 각 501개 | HTTP **1→1**, 상세 **1,002→0행**, 본문 **211,241→825 B**, 금액·건수 동일 | 실제 Supabase 17/PostgREST, v1/v2 비교. p50 83.208→82.167ms로 시간 개선은 주장하지 않음 |
| Photo Excel 10,000행, 네이티브 AOT | 파싱 **441.080→226.111ms**, 최대 RSS p50 **123.15→38.24MB** | 동일 XLSX, 각 모드 20개 독립 프로세스 |
| Photo Excel 10,000행, 실제 Chrome worker | 처리 **1,084.8→629.65ms**, 최대 rAF 간격 p50 **1,075→16.8ms** | 실제 worker 시작·JSON 전달·종료 포함. Flutter raster 시간과 별개 |
| 원재료 Excel 10,000행 | 인코딩 **1,831.229→342.539ms**, 최대 RSS p50 **281.49→29.11MB** | 실제 기존/스트리밍 encoder, 합성 행 생산기. DB/다운로드 시간 제외 |
| 레시피 Excel 시트당 10,000행, 3개 시트 | 인코딩 **694.215→175.439ms**, 최대 RSS p50 **206.55→28.48MB** | 실제 기존/스트리밍 encoder, 합성 행 생산기. DB/다운로드 시간 제외 |
| 증빙 attach 403/42501, flush 2회 | HTTP **8→4**, 업로드 **2→1**, 다른 업로드 경로 **2→1** | 실제 service + 모의 전송. 앱 재시작 후 권한 복구 시 attach만 1회 추가 |
| 긴급 푸시 1,000건, dispatcher 1개 | DB HTTP **1,010→40**, FCM 최대 동시 **1→4** | 실제 handler + 모의 DB/FCM. vendor에 필요한 1,000회 발송은 유지 |
| MISA 50건·법인 1개·유효 캐시 토큰 | DB HTTP **352→6**, 설정 조회 **150→3**, publish 동시 **≤2** | 실제 handler + 모의 DB/vendor. 토큰 refresh가 필요하면 추가 호출 발생 |

Excel 내보내기 비교의 기존 encoder 함수 본문은 작업 시작 스냅샷과 동일함을 확인했다. 현재 파일에 보존된 기존 함수와 새 encoder를 같은 AOT 실행파일에서 비교했다. 네이티브 Photo와 SQL은 별도로 고정한 개선 전 소스를 사용했다.

**작은 파일의 Chrome 총 처리 시간은 악화됐다.** 100행은 25.05→61.4ms, 1,000행은 137.2→153.95ms였다. worker 시작 비용을 포함한 결과다. 1,000행의 rAF 간격은 133.3→16.8ms로 줄었다. 모든 규모의 전체 시간을 개선했다고 주장하지 않는다.

## 읽은 행·JOIN·접근 범위

- **메뉴:** 과거 100,000개에서 기존 paid-orders 입력 정렬은 100,100행이었다. 변경 후 날짜 후보는 100행이고, 그 후보의 전체 결제를 확인한다. 기간 이후 추가 분할 결제가 있는 주문을 제외하는 기존 의미도 전후 SQL 결과 비교로 보존했다.
- **원가:** 대상 외 공급가를 포함한 98,941행 정렬·4,128KiB 디스크 spill을 대상 100행 정렬·32KiB로 줄였다. 100,000개 fixture에서 공급상품 index scan은 1행×100 loops였다. 더 작은 fixture에서는 planner가 전체 순차 스캔을 선택하기도 하므로 모든 경우의 scan이 100행이라고 해석하지 않는다.
- **발주 이력:** 실제 canonical 재고 DDL/RLS에서 과거 행 100/1,000/100,000개, 상품 1/10/100개를 검사했다. 100,000개일 때 반환 3/30/300행, 본문 1,518/14,967/149,701 B. index probe는 상품당 최신 3개이며 현재 발주 1개는 제외됐다. 입고 자식 100개를 더해도 수량 합계 200, 이력 300행으로 유지되어 JOIN 행 증폭이 없었다.
- **대시보드:** overview와 stock 패널 동시 진입은 HTTP 2회 중 stock RPC 1회이며 부족 재고 2개를 정확히 합성했다. 실제 v2 SQL은 기존 stock helper 없이 실행됐고, 상품 501개의 재고 금액 3,006·제출 7·승인 13, 타 매장 거절을 확인했다.
- **목록:** 상품 기본 50행, 관리 화면도 50행과 서버 검색·키셋으로 바꿨다. 정확한 건수는 첫 페이지에서 유지한다. 내보내기에는 불필요한 정확한 전체 건수 계산을 생략한다. 원재료 내보내기 공급가는 상품당 우선 거래처 1개만 투영한다.
- **레시피 내보내기:** recipes/menus/ingredients를 차례로 최대 500행씩 읽는다. 레시피 1,500개는 500/500/500행, 메뉴·원재료 501개는 500/1행으로 반환됐다. 타 매장 메뉴·레시피 각각 100,000개를 추가한 계획에서 매장+ID index 범위를 확인했고, 타 매장 요청·NULL/501 page limit은 거절됐다. 이름 정렬을 위해 전체 목록을 적재하는 대신 안정적인 ID 순서로 양식을 기록한다.
- **영수증:** 기본 50·최대 100개 헤더를 고른 뒤 선택 receipt key의 품목·배분만 조회한다. 정확한 합계는 유지하며 커서 이동 중 재사용한다. 실제 payments 도메인의 결제/환불 이벤트와 매장·인증 범위 변경은 합계를 무효화한다. UI·SQL 회귀 테스트를 통과했다.
- **보고서:** v2는 정확한 예외 건수와 집계를 유지하고 상세 배열을 비워 반환한다. 상세는 열었을 때 50·최대 100개 키셋 조회한다. 기존 v1 API를 유지했다. 혼합 1,500행의 금액·건수·일별·시간별·결제수단별 계산은 동결한 기존 계산과 일치했다.
- **개인 급여:** 직원 조건을 명단·수당·출퇴근 페이지와 revision 검사에 전달했다. 직원 1,001명에서 대상 직원 명단/수당/로그는 각각 1행이다. 다른 매장·권한 제거·중간 변경 감지도 확인했다.
- **고정 계정:** 사용자 디렉터리 100/10,000/100,000명에서 조회 1행·83 B, p50 1.228/1.082/1.134ms. Supabase의 기존 Auth index를 활용한다. 실제 Auth 소유 테이블을 일반 migration 역할로 조회하는 Supabase 17 fixture도 통과했다. 관리형 Auth 테이블에 새 index를 만들지 않는다.

## 구현한 제한·최신성·재시도

| 작업 | 적용한 계약 |
|---|---|
| W0 기준선 | 시작 시 2,319개 파일 hash와 Git 상태 보존, 순수 파서·유효 SQL 기준선 고정. 개선 전/후 분포와 환경 기록 |
| W1 갱신 | 자원별 실행 1개+dirty 후속 1개, 이벤트 150ms 병합, delta 50개 순차, dirty ID 500개 상한. 변경 매장 100개씩 순차 조회. 오류·dispose·인증/매장 전환·늦은 응답 검사 |
| W2 SQL | 이력 상품 ID 100개 순차 batch·상품당 3개, 입고 사전 집계. 날짜 결제 후보·대상 매장 상품부터 한정 |
| W3 화면/내보내기 | 탭별 lazy load, 목록/예외/영수증 50행 페이지, 급여 500행 페이지. stock 조회는 사용자/매장/기준일별 진행 중 요청 공유. 내보내기 500행 순차·행 XML 점진 압축 |
| W4 입력 | 압축 10MiB, 실제 해제 합계 50MiB, 시트 10개, cell/희소 범위 200,000, ZIP entry 2,000개. Photo 10,000행 상한. Web worker 1개·30초 종료, native compute 1개 |
| W5 증빙 | 업로드 경로·완료 단계를 먼저 영속화, 같은 파일 업로드 재사용. flush 최대 10개·30초, HTTP/본문 10초·ack 1MiB. 자동 최대 3회, 일시 오류만 backoff/jitter. 영구 오류 보존·사용자/매장 범위의 명시적 재개 |
| W5 푸시 | claim/완료 50개 batch, 소유권 token·90초 lease·최대 10회. 4개 worker, invocation 45초·최대 20 batch/1,000건. 429 대기와 UNREGISTERED의 현재 token만 비활성화 |
| W6 Auth | service-role 전용 정확 이메일 RPC, nil instance·non-SSO password account 범위. 기존 계정 소유 정책 유지 |
| W7 MISA/SePay | claim 50·소유 완료 batch·90초 lease, 법인별 token refresh lease. 2개 publish worker·45초·HTTP/본문 10초. 응답 유실/잘못된 JSON은 수동 확인, 재발행 자동 재시도 금지. 실제 FCM 대상이 있을 때만 SePay dispatcher 호출 |

소유권 테스트는 작업 1/50/1,000개·동시 DB 세션 1/2/8개에서 중복 claim, 다른 owner 완료, 반복 완료를 확인했다. 다른 owner와 반복 완료는 모두 0행 변경이었다. MISA 만료 claim은 수동 확인 이벤트 1개와 재claim 0개로 보존된다. token refresh 8개 경쟁자는 1개만 이겼다. 연기된 작업은 발행 시도 횟수를 소비하지 않는다. 구버전 푸시 완료 RPC도 새 owner의 작업을 덮어쓰지 못한다.

FCM은 외부 수신과 DB 완료를 하나의 트랜잭션으로 묶을 수 없다. 이벤트 ID의 알림 tag로 표시 중복을 줄이지만 exactly-once 발송을 보장하지 않는다. MISA는 vendor 멱등성 보장을 추정하지 않고 결과를 모르는 발행을 포털에서 확인하게 한다.

## 검증 상태와 남은 범위

**`bash scripts/check_repo.sh` exit 0**, Flutter 전체 1,906개 통과·95개 제외, 실제 Supabase/PostgREST 재무 76개 통과, Flutter Web release build 성공. 마지막 추가 검증에서도 stock 공유 테스트 1개, 확장 SQL/RLS dashboard 검증, `dart analyze --fatal-infos`가 통과했다. 제품 코드는 전체 검사 후 변경하지 않았다. 결과는 [최종 검사 기록](/Users/andreahn/globos_pos_system/docs/audits/data_access_20261011/checks/verification.json)과 [전체 로그](/Users/andreahn/globos_pos_system/docs/audits/data_access_20261011/checks/check-repo-final.log)에 보존했다. 검증에는 static analysis, Flutter 전체 테스트, SQL/RLS·실제 PostgREST(행 cap 100), Edge 실제 handler harness, 입력 경계·업로드 재시작/권한 복구, Photo worker 빌드·Flutter Web release build가 포함된다.

- DB 시간 표는 PostgreSQL 15의 실제 함수 실행 시간이다. 최소 메뉴/원가 fixture의 권한 guard는 stub이며, RLS는 별도의 canonical 재고/재무 통합 fixture에서 검사했다. 전체 운영 migration chain·trigger·실데이터를 복제한 환경은 아니다.
- 클라이언트/Edge HTTP 수·본문 bytes는 실제 코드에 연결한 모의 전송 값이다. mock 반환 행을 DB scan 행으로 집계하지 않았다. 실제 vendor RTT, 운영 네트워크, browser heap peak·물리 POS 기기 raster 시간은 측정하지 않았다.
- 20회 warm SQL 및 별도 첫 실행을 기록했다. 파일 파서는 20개 fresh 프로세스와 warm OS cache를 사용했다. DB 디스크 cache를 비운 cold 실험, 1/10/50명의 전체 앱 동시 사용자 부하는 미실행이다. 소유권은 1/2/8 세션, handler는 1/2/8 dispatcher로 검사했다. FCM 4개·MISA 2개는 invocation당 상한이고 전체 배포의 전역 동시성 상한이 아니다.
- 상품 선택기는 필요할 때 해당 매장 전체 목록을 500행 배치로 모으며, 선택한 레시피/새 메뉴 탭은 기존 전체 레시피 조회·표시/사용량 계산을 유지한다. 전체 초기 테이블 복구도 해당 매장의 활성 주문 전체 범위다. 이 경로의 절대 행·메모리 상한을 이번 작업이 보장하지 않는다. 내보내기는 cell matrix를 제거했지만 FileSaver에 전달할 최종 압축 결과는 보유하므로 파일 크기에 비례하는 메모리가 남는다.
- 입력 byte/cell 예산은 process RSS의 절대 상한이 아니다. 압축 해제 크기를 거짓 신고한 51MiB entry, 11개 시트, A200001 희소 cell, Photo 10,001행을 거절하고 Excel date-time 형식도 보존하는 회귀 검사를 추가했다.
- 운영 적용 전 Auth index/컬럼, 실제 RLS/권한·데이터 크기, vendor 429/timeout과 대표 POS 기기의 지연을 확인해야 한다. index 생성의 운영 잠금·쓰기 비용도 별도 평가 대상이다. [적용·복구 절차](/Users/andreahn/globos_pos_system/docs/audits/data_access_20261011/ROLLOUT.md)를 준비했다.
