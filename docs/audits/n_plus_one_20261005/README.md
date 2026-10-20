# N+1 audit evidence — 2026-10-05

Repository root에서 실행한다. 운영 DB·외부 API에 연결하지 않는다.
보고서는 `docs/n_plus_one_full_code_audit_20261005.md`에 있다.

## Evidence and limits

- `sql_probe_results.json`: 실제 migration의 함수 본문을 추출한 PostgreSQL 15 테스트. `pg_stat_statements.track=all`, `track_functions=all`. 합성 최소 테이블·사용자·권한 fixture이며 전체 migration/RLS 재현은 아니다. `table_read_calls`는 대상 테이블을 읽는 중첩 SQL 실행 횟수다. HTTP 호출 수 또는 physical disk read 수가 아니다.
- `edge_probe_results.jsonl`: 실제 MISA helper에 fake Supabase transport와 유효한 가짜 캐시 토큰을 사용했다. dispatcher 전체 HTTP integration이 아니다. 작업별 helper 호출 경로는 dispatcher 소스에서 확인했다.
- `kds_probe.log`: 실제 `KdsRealtimeSync.catchUp`과 fake gateway, 현재 provider와 같은 ticket 조회 callback을 사용한 3개 테스트. 전체 provider/widget/서버 integration이 아니다.
- `direct_order_sql.log`: 기존 `test/direct_order_delivery_fallback_sql_test.sh` 재실행 결과. 개선된 v3와 기존 staff/customer SQL의 실행계획을 함께 확인했다.
- `source_manifest_initial.json`, `source_manifest_final.json`, `scope_summary.json`: 작업 중 변경된 소스 구분용 SHA-256 목록. 배포된 운영 버전의 증거가 아니다. 매니페스트에서 docs, .design, env 파일을 제외한다.
- `scan.dart`, `scan_sql.py`: 후보 추출기다. 완전한 call graph, SQL migration interpreter 또는 N+1 자동 판정기가 아니다. SQL 결과에서 rename/drop/dynamic patch는 별도로 확인해야 한다. 결과 파일은 `/tmp/globos-n1-audit-20261005`에 생성된다.

## Reproduction

Docker, Python 3, 프로젝트 Flutter/Dart 의존성, Deno가 필요하다.

```bash
mkdir -p /tmp/globos-n1-audit-20261005
python3 docs/audits/n_plus_one_20261005/probe_sql.py
deno run --no-config docs/audits/n_plus_one_20261005/probe_edge.ts
bash test/direct_order_delivery_fallback_sql_test.sh
```

SQL probe는 임시 Docker 컨테이너를 만들고 `finally`에서 삭제한다. 포트를 공개하지 않는다. 저장된 결과는 덮어쓰지 않으며 `/tmp`에 새 결과를 만든다. Deno probe는 외부 네트워크 권한을 요구하지 않는다.

KDS probe는 테스트 검색 경로에 임시 복사해 실행한다. 아래 스크립트는 기존 파일이 있으면 중단하며, 자신이 생성한 임시 파일만 제거한다.

```bash
bash <<'SH'
set -eu
probe=test/_n1_audit_reproduction_test.dart
if test -e "$probe"; then
  echo "Refusing to overwrite existing $probe" >&2
  exit 1
fi
trap 'rm -f "$probe"' EXIT
cp docs/audits/n_plus_one_20261005/kds_probe.dart "$probe"
flutter test --no-pub "$probe"
SH
```

전체 소스 후보 재추출:

```bash
mkdir -p /tmp/globos-n1-audit-20261005
dart --packages=.dart_tool/package_config.json docs/audits/n_plus_one_20261005/scan.dart
python3 docs/audits/n_plus_one_20261005/scan_sql.py
```

`capture_manifest.py`는 현재 소스의 final manifest를 갱신하므로, 원래 감사 증거를 보존하려면 별도 디렉터리에서 실행하거나 기존 증거를 먼저 보관한다.
