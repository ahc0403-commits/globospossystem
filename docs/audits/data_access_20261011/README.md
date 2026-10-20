# 재현 방법과 증거

이 폴더는 2026-10-11 구현 후 측정이다. 개선 전 소스와 측정은 `baseline/`, `sql/*_before.sql`, 시작 source manifest 및 [이전 감사](/Users/andreahn/globos_pos_system/docs/audits/data_access_20261010/README.md)에 연결된다. production credentials는 사용하지 않았다.

## 증거 구분

| 경로 | 내용 |
|---|---|
| `REPORT.md`, `ROLLOUT.md` | 결과·한계, 아직 실행하지 않은 운영 적용/복구 절차 |
| `source_manifest_before/after.json`, `implementation_delta.json` | 동일 확장자/경로 범위의 시작/최종 source hash; 추가 경로는 `extra_source_manifest_after.json`. 기존 dirty Git diff 전체를 이번 작업에 귀속시키지 않음 |
| `sql-menu-before/after/`, `sql-cost-before/after/` | 유효 함수 20회 서버 표본, inner EXPLAIN/BUFFERS, 응답 bytes |
| `sql-integrated-owned/`, `sql-integrated-recipe/`, `sql-integrated-complete/` | 실제 canonical 재고 DDL/RLS·이력/receipt JOIN·cursor·scope, 레시피 export page·index 계획, dashboard 금액·범위 검사. 관련 없는 identity/menu 테이블은 fixture |
| `claims-final/` | 실제 queue DDL·owned claim/completion·만료·token rotation/refresh 경쟁·canonical SePay polling 경로 |
| `edge-results.json`, `sepay-edge-results.json` | 실제 handler + 합성 DB/vendor 전송. 20회 표본 및 DB HTTP·동시성·failure 시나리오 |
| `client-results.json`, `financial-results.json` | client 모의 전송 지표와 실제 Supabase/PostgREST 전후 측정(있는 경우) |
| `photo/` | 동일 XLSX 입력, 개선 전/후 AOT 표본, 실제 Chrome worker 처리/rAF 표본 |
| `export-results.json`, `recipe-export-results.json` | 실제 encoder의 전후 시간·최대 RSS·파일 크기. 행 생산기는 합성, DB 시간 제외 |
| `metrics_summary.json`, `checks/` | p50/p95 분포, 검사 로그와 exit 결과 |

SQL의 scan 출력행×loops, 필터 제거 행, index recheck, BUFFERS와 정렬/집계 메모리를 별도로 읽는다. 부모와 자식 scan을 합산하지 않는다. HTTP body bytes에는 header/TLS 비용을 포함하지 않는다. 첫 실행은 cold-disk-cache 측정이 아니다.

## 재현

저장소 루트에서 실행한다. Dart/Flutter/Deno·Docker·Node/Chrome 버전은 `environment.json`을 참고한다. 아래 SQL 검증은 독립 컨테이너를 생성·삭제하며 기존 DB에 접속하지 않는다.

```bash
bash scripts/check_repo.sh
flutter test test/data_access
python3 scripts/tests/data_access/verify_bounded_reads.py /tmp/pos-bounded-reads
python3 scripts/tests/data_access/verify_dispatch_claims.py /tmp/pos-owned-claims
bash scripts/test_financial_inputs_postgrest.sh
```

메뉴/원가 전후 probe는 각각 동일 seed·관련 인덱스·20 warm 표본을 사용한다. 최소 timing fixture의 access guard는 stub이므로 위 RLS 통합 검증을 함께 읽는다.

```bash
python3 docs/audits/data_access_20261011/sql/menu_probe.py ignored /tmp/pos-menu-before docs/audits/data_access_20261011/sql/menu_before.sql
python3 docs/audits/data_access_20261011/sql/menu_probe.py ignored /tmp/pos-menu-after supabase/migrations/20261011010000_bounded_data_reads.sql
python3 docs/audits/data_access_20261011/sql/cost_probe.py ignored /tmp/pos-cost-before docs/audits/data_access_20261011/sql/cost_before.sql
python3 docs/audits/data_access_20261011/sql/cost_probe.py ignored /tmp/pos-cost-after supabase/migrations/20261011010000_bounded_data_reads.sql
```

Edge harness는 실제 production entry point를 import하고 전송만 대체한다. 서비스 키/토큰은 fixture 문자열이며 외부 요청이 없다. queue 소유권은 위 SQL probe가 별도로 검증한다.

```bash
deno run --no-config --import-map=scripts/tests/data_access/edge/import_map.json --allow-env --allow-read scripts/tests/data_access/edge/probe.ts > /tmp/pos-edge-results.json
deno run --no-config --import-map=scripts/tests/data_access/edge/import_map.json --allow-env --allow-read scripts/tests/data_access/edge/sepay_probe.ts > /tmp/pos-sepay-results.json
```

Photo AOT 전후에는 동일 입력을 사용한다. 이 폴더의 XLSX 4개는 실측에 쓴 합성 파일이다. 각 크기/모드마다 20개 독립 프로세스를 번갈아 실행해 `elapsed_ms`, `max_rss_bytes`를 수집한다.

```bash
dart compile exe docs/audits/data_access_20261011/photo/before_probe.dart -o /tmp/photo-before
dart compile exe docs/audits/data_access_20261011/photo/after_probe.dart -o /tmp/photo-after
/tmp/photo-before docs/audits/data_access_20261011/photo/photo_10000.xlsx
/tmp/photo-after docs/audits/data_access_20261011/photo/photo_10000.xlsx
```

Chrome 측정은 사용자 브라우저 프로필과 분리된 임시 headless 프로필·localhost를 사용한다. 실제 새 worker의 시작/JSON 복제/종료 비용을 포함한다. `CHROME_BIN`으로 실행 경로를 지정할 수 있다. 100/1,000/10,000/10,001행을 각 20회 측정한다.

```bash
dart compile js -O2 docs/audits/data_access_20261011/photo/before_web_probe.dart -o /tmp/photo-before.js
bash scripts/build_photo_import_worker.sh
node scripts/tests/data_access/browser/measure_photo.mjs docs/audits/data_access_20261011/photo /tmp/photo-before.js web/photo_import_worker.js /tmp/photo-browser-results.json
```

기록 당시 browser runner의 `rows` 출력이 거절 파일의 입력 행 수를 0으로 덮어쓴 문제는 `workload_rows` 메타데이터를 별도로 두어 수정했다. 최종 자료는 알려진 크기 순서·160개 표본·양 모드 거절을 확인해 입력 규모만 보완했고, 시간/rAF 값은 바꾸지 않았다.

내보내기 probe의 before는 현재 파일에 보존된 기존 builder다. 함수 본문이 작업 시작 스냅샷과 같음을 확인했다. 인코딩과 행 생성 비용을 비교하며 DB 조회/FileSaver 비용을 포함하지 않는다. 레시피 `10000`은 각 3개 시트에 10,000개 행을 뜻한다.

```bash
dart compile exe scripts/tests/data_access/browser/export_probe.dart -o /tmp/ingredient-export-probe
/tmp/ingredient-export-probe 10000 before
/tmp/ingredient-export-probe 10000 after
dart compile exe scripts/tests/data_access/browser/recipe_export_probe.dart -o /tmp/recipe-export-probe
/tmp/recipe-export-probe 10000 before
/tmp/recipe-export-probe 10000 after
```

클라이언트의 100회 burst 요청 수는 `test/data_access/refresh_probe_test.dart`, `catalog_refresh_probe_test.dart`에서 재현한다. 개선 전 수치는 이전 감사의 raw log/manifest에 보존했다. `inventory_stock_share_test.dart`는 dashboard/stock panel의 동일 조회 공유와 정확한 부족 재고 수를 검사한다. `financial-results.json`의 before는 유지한 매장 전체 급여 API와 보고서 v1, after는 직원 조건과 v2이며, 동일 격리 DB/권한/seed에서 번갈아 실행한다.
