# 데이터 접근 집중 감사 — 증거와 재현

[검증 보고서](REPORT.md) · [개선계획](/Users/andreahn/globos_pos_system/docs/plans/data_access_performance_improvement_plan_20261010.md)

## 자료

| 파일 | 내용 |
|---|---|
| `inventory_history_probe_test.dart`, `inventory_history_results.json` | 실제 InventoryService, 합성 HTTP 이력 100/1,000/10,000건, 호출·반환 행·bytes·시간·프로세스 RSS |
| `refresh_probe_test.dart`, `refresh_tests.log` | 실제 테이블 갱신 1/100회 재진입 + 기존 27개 테스트 |
| `catalog_refresh_probe_test.dart`, `catalog_refresh.log` | 실제 Super Admin 강제 갱신 100개 대기자 재현 |
| `proof_retry_probe_test.dart`, `proof_retry.log` | 실제 증빙 서비스의 성공 업로드 후 영구 첨부 오류 재시도 |
| `refresh_retry_results.json` | 위 원본 로그에서 추출한 계측 JSON |
| `sql/probe.py`, `sql/results.json`, `sql/menu_*_inner_explain.json` | 실제 메뉴 분석 함수·내부 쿼리 EXPLAIN |
| `sql/inventory_cost_probe.py`, `sql/inventory_cost_results.json`, `sql/cost_*_inner_explain.json` | 실제 재고 원가 함수·내부 쿼리 EXPLAIN |
| `photo/generate.dart`, `photo/photo_probe.dart`, `photo/results.json` | 정상 OOXML fixture 생성, 실제 파서 AOT 실행 3크기×3회 |
| `edge/probe.ts`, `edge/results.json`, `edge/*_stub.ts` | 변경하지 않은 MISA/긴급 푸시 handler와 모의 전송 |
| `edge/probe_auth_scan.ts`, `edge/auth_results.json` | 현재 Auth helper 추출·합성 디렉터리 조회 |
| `test_summary.json` | 기존 46개 + 계측 7개 Flutter 테스트 통과 기록 |
| `source_manifest_initial.json`, `source_manifest_final.json`, `scope_summary.json` | 감사 시점 소스 목록·SHA-256, 동시 변경 목록, HEAD |

## 측정 해석

- Flutter 3.41.6 / Dart 3.11.4, Deno 2.7.13. SQL은 독립 `postgres:15` 컨테이너(2 CPU, 1 GiB, 포트 비공개)이며 전체 Supabase/RLS/운영 스키마 재현은 아니다. 실제 함수 본문을 추출하고 권한 guard만 fixture로 대체한다.
- HTTP 모의 응답은 실제 앱/handler 코드가 처리한다. **반환 행은 DB 스캔 행이 아니다.** 응답 bytes는 합성 JSON 크기이며 실제 압축 전송량이나 운영 비용을 뜻하지 않는다.
- SQL의 Actual Rows×Loops는 노드 출력 행 수다. 처리량을 해석할 때 필터 제거 행·index recheck와 BUFFERS를 함께 확인한다. 보고서 표의 대상 scan은 제거 행이 0이다. 부모/자식 노드의 행·시간을 중복 합산하지 않는다. 노드 메모리는 전체 backend RSS가 아니다.
- Flutter RSS는 test VM·fixture·GC를 포함하며 한 프로세스의 high-water가 누적된다. Excel RSS는 AOT 프로세스별 값이다. Deno heap delta는 음수가 될 수 있고 peak가 아니다.
- Flutter/Edge fixture에는 1ms 또는 20ms의 합성 응답 대기가 있다. host에서 다른 작업도 실행됐다. 시간과 p95는 fixture 처리시간이며 운영 지연으로 해석하지 않는다. 특히 5회 표본의 nearest-rank p95는 최댓값이다.
- MISA fixture는 비활성 기본값을 모의 응답에서 켠다. 운영 활성 상태·공급자 멱등성·실제 발행 결과를 증명하지 않는다.
- 모든 네트워크 요청은 모의 처리 또는 포트 비공개 임시 DB다. 운영 자격증명·실제 고객자료를 사용하지 않았다. 본 자료의 문자열은 가짜 계정/토큰이다.
- 아래 probe는 **현재 문제를 재현하는 기준선**이다. 개선 후 같은 수치를 강제하는 영구 테스트로 편입하지 말고 개선계획의 상한·정합성 테스트로 전환한다.

## Flutter 재현

저장소 루트에서 실행한다. 기존 기록을 보존하려면 새 출력 디렉터리를 사용한다. `.dart_tool/package_config.json`과 현재 프로젝트 의존성이 준비돼 있어야 한다.

```bash
set -o pipefail
audit_output_dir="$(mktemp -d /tmp/pos-data-audit-reproduction.XXXXXX)"
DATA_AUDIT_OUTPUT="$audit_output_dir" flutter test --no-pub --concurrency=1 --reporter expanded \
  docs/audits/data_access_20261010/inventory_history_probe_test.dart \
  test/kitchen_query_bounds_test.dart test/catalog_query_test.dart \
  test/features/procurement/procurement_pagination_test.dart \
  | tee "$audit_output_dir/inventory-and-contracts.log"
flutter test --no-pub --concurrency=1 --reporter expanded \
  docs/audits/data_access_20261010/refresh_probe_test.dart \
  docs/audits/data_access_20261010/catalog_refresh_probe_test.dart \
  docs/audits/data_access_20261010/proof_retry_probe_test.dart \
  test/coalesced_refresh_test.dart test/provider_poll_guard_test.dart \
  test/polling_utils_test.dart | tee "$audit_output_dir/refresh-and-retry.log"
```

## SQL 재현

두 script는 현재 checkout의 정확한 함수 본문을 추출한다. 각자 만든 컨테이너만 `finally`에서 제거하며 기존 Supabase/다른 작업의 컨테이너를 변경하지 않는다. Docker와 `postgres:15` 이미지가 필요하다. 출력은 `/tmp/globos_sql_performance_20261010/`이며 이 증거 폴더의 JSON은 덮어쓰지 않는다.

```bash
python3 docs/audits/data_access_20261010/sql/probe.py
python3 docs/audits/data_access_20261010/sql/inventory_cost_probe.py
```

## Excel 재현

fixture generator는 프로젝트의 기존 `test/helpers/external_excel_fixture.dart`를 사용한다. 바이너리와 생성 XLSX는 저장소 증거에 포함하지 않았다.

```bash
mkdir -p /tmp/globos-client-audit-20261010
dart --packages=.dart_tool/package_config.json docs/audits/data_access_20261010/photo/generate.dart
dart compile exe --packages=.dart_tool/package_config.json \
  docs/audits/data_access_20261010/photo/photo_probe.dart \
  -o /tmp/globos-client-audit-20261010/photo_probe
for audit_rows in 100 1000 10001; do
  for audit_repeat in 1 2 3; do
    /tmp/globos-client-audit-20261010/photo_probe "/tmp/globos-client-audit-20261010/photo_${audit_rows}.xlsx"
  done
done
```

## Edge 재현

증거 폴더를 새 임시 디렉터리에 복사한 뒤 실행한다. `probe_auth_scan.ts`는 복사된 위치에 최신 helper를 생성한다. 원래 실행 이후 이 생성 경로만 상대 위치로 정리했다. import map의 프로젝트 경로와 script의 root는 `/Users/andreahn/globos_pos_system`을 전제로 한다.

```bash
edge_probe_dir="$(mktemp -d /tmp/pos-edge-audit-reproduction.XXXXXX)"
cp -R docs/audits/data_access_20261010/edge/. "$edge_probe_dir/"
deno run --no-check --no-remote --allow-env \
  --allow-read="/Users/andreahn/globos_pos_system,$edge_probe_dir" \
  --import-map="$edge_probe_dir/import_map.json" "$edge_probe_dir/probe.ts" \
  > "$edge_probe_dir/reproduced-results.json"
deno run --no-check --no-remote \
  --allow-read="/Users/andreahn/globos_pos_system,$edge_probe_dir" \
  --allow-write="$edge_probe_dir" "$edge_probe_dir/probe_auth_scan.ts" \
  > "$edge_probe_dir/reproduced-auth-results.json"
```

Deno에는 네트워크 권한을 주지 않는다. Auth helper는 복사한 현재 소스이므로 이후 구현이 바뀌면 그 시점 함수를 측정한다.
