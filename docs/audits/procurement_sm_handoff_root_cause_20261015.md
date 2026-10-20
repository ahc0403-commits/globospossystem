# bunsik_sm1 구매 결재 미노출 원인 조사

조사 시각: 2026-10-15 12:59, Asia/Ho_Chi_Minh. 사용자 확인 계정: `bunsik_sm1`.

## 결론

운영 데이터에서 빈탄점의 제출된 PR 14건은 모두 Store Manager 승인 대기이며, `bunsik_sm1`의 authenticated 권한으로 실제 운영 조회 RPC를 실행하면 14건 전부 승인 가능으로 반환된다. 최신 PR의 상세와 승인 동작 목록도 정상 조회된다.

확인된 화면 연결 결함은 **Store Manager의 로그인 기본 경로와 기존 재고·구매 화면이 여전히 PO 중심인 반면, 최근 수정한 PR 결재함은 별도 `/inventory-orders` 경로에만 있다는 것**이다. 로그인 후 기본 화면에 PR 결재함이나 대기 건수 연결이 없다. 별도의 ‘발주·승인·입고’ 링크를 눌러야 새 결재함에 도달한다. 실제 `bunsik_sm1`의 최근 24시간 API 로그에도 기존 조회만 있고 PR 결재함 조회는 없다.

따라서 승인 담당자 배정이나 제출 상태를 다시 바꾸는 조치보다, 실제 매니저 진입 화면에서 PR 결재함을 직접 제공하는 수정이 필요하다. 다만 사용자 단말의 현재 화면과 앱 버전은 직접 확인하지 못했으므로, 최신 `/inventory-orders`에 진입한 뒤에도 동일 증상이 발생한다고까지 입증한 것은 아니다.

## 운영 검증

운영 Supabase `ynriuoomotxuwhuxxmhj`에서 `BEGIN READ ONLY`, `SET LOCAL ROLE authenticated`, 해당 계정의 Auth subject를 담은 트랜잭션 로컬 JWT claims로 조회했다. 이는 비밀번호를 사용한 실제 로그인 검증과 구분된다. 승인 명령은 실행하지 않았다.

| 확인 항목 | 실제 결과 |
|---|---|
| `bunsik_sm1` POS profile | 활성 `store_admin`, 빈탄점 연결 정상 |
| Auth 연결 | profile의 `auth_id`에 실제 Auth 사용자 존재 |
| Store Manager roster | 현재 유효한 `store` 단계의 공용 역할 계정 |
| 매장 정책 | enabled=true, two_stage_required=true |
| PR 결재함 | pending=14, actionable=14, blocked=0, 반환 14건 |
| 최신 선택 PR | `PR-20261014-8C21C1C2D4`, submitted, 상세 16행 |
| 최신 PR 동작 | adjust_request, store_approve, return_request |
| 기존 submitted PO 조회 | 과거 PO 5건. 위 PR 14건과 다른 데이터 |

검증한 결재함 쿼리:

```json
{
  "request_view": true,
  "request_group": "pending",
  "request_scope": "mine",
  "request_sort": "submitted",
  "limit": 20
}
```

`procurement_workspace_page`를 한 번 호출해 목록과 건수를 검증했고, 별도의 선택 상세 조회에서 최신 PR 16행과 허용 동작을 확인했다. PR별 반복 조회로 전체 목록을 검증하지 않았다. 이번 조사는 성능 변경이나 부하 시험이 아니다.

## 배포 소스에서 확인한 끊어진 경로

조사 시점 production Vercel alias의 배포 메타데이터는 `fcd4bf1008842559c9bd6863d84d45fc4ec06cc4`를 가리킨다. 최근 PR 결재함 수정 `fbcba4ae`를 포함한다. DB migration history에도 `20261014080000_procurement_approval_inbox`와 `20261014081000_procurement_store_onboarding`이 존재한다. 현재 작업 폴더의 HEAD는 과거 커밋이고 사용자 변경이 많아, 아래 소스 판단은 **운영 배포 커밋을 git show/git grep으로 읽은 결과**를 기준으로 했다.

1. [role_routes.dart:35](https://github.com/ahc0403-commits/globospossystem/blob/fcd4bf1008842559c9bd6863d84d45fc4ec06cc4/lib/core/utils/role_routes.dart#L35): store_admin의 로그인 홈은 `/admin`이다.
2. [admin_screen.dart:225](https://github.com/ahc0403-commits/globospossystem/blob/fcd4bf1008842559c9bd6863d84d45fc4ec06cc4/lib/features/admin/admin_screen.dart#L225): 일반 매장의 재고 메뉴는 기존 `InventoryPurchaseScreen`을 연다. 이 메뉴에 PR 대기 건수나 결재함 직접 연결이 없다.
3. [inventory_service.dart:1144](https://github.com/ahc0403-commits/globospossystem/blob/fcd4bf1008842559c9bd6863d84d45fc4ec06cc4/lib/core/services/inventory_service.dart#L1144): 기존 구매 목록은 `inventory_purchase_orders`를 조회한다. 운영 대시보드 RPC도 이 테이블의 submitted/office_approved만 집계한다.
4. [inventory_purchase_screen.dart:807](https://github.com/ahc0403-commits/globospossystem/blob/fcd4bf1008842559c9bd6863d84d45fc4ec06cc4/lib/features/inventory_purchase/inventory_purchase_screen.dart#L807): 구매관리 승인 대기 표시도 위 PO 목록에서 계산한다. `inventory_purchase_requests`에 저장된 PR은 포함되지 않는다.
5. [inventory_purchase_screen.dart:448](https://github.com/ahc0403-commits/globospossystem/blob/fcd4bf1008842559c9bd6863d84d45fc4ec06cc4/lib/features/inventory_purchase/inventory_purchase_screen.dart#L448): 별도 ‘발주·승인·입고’ 링크가 `/inventory-orders`로 이동한다.
6. [inventory_order_workflow_screen.dart:2133](https://github.com/ahc0403-commits/globospossystem/blob/fcd4bf1008842559c9bd6863d84d45fc4ec06cc4/lib/features/inventory_purchase/inventory_order_workflow_screen.dart#L2133): 이 별도 화면만 `ProcurementWorkspacePage(approvalView: true)`를 연결한다. 저장소 전체 검색에서도 PR 결재함 조회의 UI 호출 지점은 이곳이다.

## 실제 계정의 요청 로그

Supabase unified `edge_logs`의 기본 최근 24시간 범위에서 JWT subject를 `bunsik_sm1`의 Auth ID로 한정했다. 네 경로를 명시하여 집계했으며 IP, 토큰, API 키, 사용자 에이전트 원문은 이 기록에 저장하지 않았다.

| API | 요청 수 | 마지막 요청, 베트남 시각 |
|---|---:|---|
| get_inventory_purchase_dashboard_v2 | 11 | 10월 14일 21:09:00 |
| get_inventory_workflow_orders | 10 | 10월 14일 20:59:53 |
| procurement_workspace_page | 0 | 없음 |
| procurement_command | 0 | 없음 |

최근 결재함 수정 배포는 10월 14일 21:20:48, 현재 production 배포는 10월 15일 10:33:29에 생성됐다. 확인된 마지막 매니저 조회는 최근 결재함 수정 배포보다 이르다. 따라서 이 로그를 ‘수정 배포 뒤에도 최신 결재함에서 실패했다’는 증거로 해석하면 안 된다. 다만 현재 배포 소스에도 `/admin`의 기존 메뉴 연결이 남아 있다는 점은 별도로 확인했다.

## 추가로 재현된 요청자 화면 진입 회귀

`bt_pr1`은 매니저와 별도의 PR 작성 계정이다. 이 계정으로 운영 `get_inventory_order_catalog`를 조회하면 `P0001: INVENTORY_PURCHASE_FORBIDDEN`이 발생했다. 같은 경로의 최근 24시간 실제 계정 로그에 HTTP 400이 73건 있었다. 마지막 기록은 10월 15일 11:26:10이다.

원인은 [20261014080000 migration:11](https://github.com/ahc0403-commits/globospossystem/blob/fcd4bf1008842559c9bd6863d84d45fc4ec06cc4/supabase/migrations/20261014080000_procurement_approval_inbox.sql#L11)에서 요청자와 수령자를 분리하려고 `can_create_inventory_purchase_order`를 receiver roster가 없는 요청자에게 false로 바꾼 데 있다. 기존 `get_inventory_order_catalog`는 이 함수를 읽기 진입 권한으로 사용한다. 그런데 [화면 초기화:216](https://github.com/ahc0403-commits/globospossystem/blob/fcd4bf1008842559c9bd6863d84d45fc4ec06cc4/lib/features/inventory_purchase/inventory_order_workflow_screen.dart#L216)는 PR 기능 여부를 알기 위해 이 카탈로그를 먼저 호출하므로 PR 화면까지 도달하지 못한다.

이는 `bunsik_sm1` 권한 오류와는 다른 결함이다. `bunsik_sm1`의 동일 카탈로그 RPC는 정상이며 정책을 반환했다. 요청자 진입 회귀를 고치기 위해 요청자에게 수령 권한을 다시 부여해서는 안 된다.

## 여러 차례 수정 후에도 놓친 이유

- 결재함 단위 테스트와 SQL 상태 전이 검증은 있었지만, 매니저의 실제 로그인 홈에서 결재함까지 연결되는 경로는 빠져 있다. [위젯 테스트 초기 경로:257](https://github.com/ahc0403-commits/globospossystem/blob/fcd4bf1008842559c9bd6863d84d45fc4ec06cc4/test/inventory_workflow_all_stores_widget_test.dart#L257)는 `/inventory-orders`를 바로 연다.
- 같은 테스트의 [카탈로그 mock:173](https://github.com/ahc0403-commits/globospossystem/blob/fcd4bf1008842559c9bd6863d84d45fc4ec06cc4/test/inventory_workflow_all_stores_widget_test.dart#L173)은 정책을 무조건 반환한다. 실제 RPC의 권한 거부가 재현되지 않는다.
- [SQL 테스트:60](https://github.com/ahc0403-commits/globospossystem/blob/fcd4bf1008842559c9bd6863d84d45fc4ec06cc4/supabase/tests/procurement_approval_inbox.test.sql#L60)는 요청자의 can_create=false를 의도대로 검증하지만, 그 계정이 화면 시작에 사용하는 카탈로그 RPC는 확인하지 않는다.
- 최근 배포 문서는 로그인 smoke를 생략했다고 명시한다. 이는 당시 승인된 배포 범위이며, 실제 계정으로 전체 업무 동선을 확인했다는 증거로 볼 수 없다.

## 필요한 수정과 검증 범위

1. `bunsik_sm1`의 `/admin`에 현재 매장의 PR 결재함과 대기 건수를 직접 연결한다. 기존 재고·원료·업체 관리 기능을 보존한다.
2. PR 정책·화면 진입 조회를 PO 생성/수령 권한에서 분리한다. 매장 접근 경계를 유지하고 요청자에게 수령 권한을 부여하지 않는다.
3. 실제 초기 경로인 `/admin`에서 재고·구매 메뉴를 거쳐 제출 PR 상세와 승인 동작에 도달하는 회귀 검증을 추가한다. 요청자 카탈로그/정책 조회는 실제 SQL 권한으로 검증한다.
4. 운영 반영 뒤 매니저 계정의 PR 목록·상세 조회와 화면 노출을 확인한다. 실제 승인 및 발주 실행은 별도 업무 행위이므로 이번 진단에서 실행하지 않았다.

이번 작업은 원인 조사와 기록 작성이다. 앱 코드·운영 DB·계정 권한·승인 상태·배포는 변경하지 않았다. 사용자 단말의 캐시와 현재 화면은 확인하지 못했으며, 실제 로그인 기반 UI 검증도 수행하지 않았다.
