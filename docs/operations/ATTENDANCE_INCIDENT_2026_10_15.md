# 직원 근태 입력 장애 조사 — 2026-10-15

확인 시각: 2026-10-15 09:08 Asia/Ho_Chi_Minh. 운영 대상: Supabase `ynriuoomotxuwhuxxmhj`.
요청 범위는 원인 조사이며, 운영 코드·권한·데이터를 변경하지 않았다.

## 확정 원인

근태 사진 업로드가 공용 `storage.objects`의 발주 관련 INSERT 정책 때문에 실패한다.
로그인 후 인증된 요청도 HTTP 400 / `AccessDenied`를 반환한다.

```text
permission denied for function procurement_pre_inbox_can_create_order
```

운영 마이그레이션 기록 `20261014080000_procurement_approval_inbox`의 3~5번째 문장에서 다음 변경을 확인했다.

1. 기존 `can_create_inventory_purchase_order(uuid)`를 `procurement_pre_inbox_can_create_order`로 변경했다.
2. 변경한 함수의 `PUBLIC`, `anon`, `authenticated` 실행 권한을 회수했다.
3. 원래 이름으로 새 `SECURITY DEFINER` 래퍼 함수를 만들었다. 새 함수는 추가 승인 조건을 검사한다.

기존 Storage 정책 `inventory_receipt_statement_objects_write`는 함수 객체 의존성을 유지하므로 이름이 바뀐 기존 함수를 계속 참조한다. 새 래퍼로 자동 전환되지 않았다.
운영 `pg_depend`, `pg_policies`, `pg_proc`에서 실제 참조와 실행 권한 부재를 확인했다.

이 정책은 `inventory-receipt-statements` 버킷 조건을 포함하지만, 공용 테이블의 INSERT 정책에 실행 불가능한 함수가 남아 있어 `attendance-photos` 요청도 실패한다.
사진 업로드 성공 후 근태 RPC를 호출하는 클라이언트 구조 때문에 출퇴근 기록 저장까지 진행하지 못한다.

근거 코드:

- `supabase/migrations/20260827150000_inventory_purchase_approval_receiving_prices.sql:2016`: 기존 Storage 정책 생성.
- `lib/core/services/attendance_service.dart:95`: 근태 사진 업로드.
- `lib/features/attendance/attendance_kiosk_provider.dart:56`: 사진 업로드 후 근태 RPC 호출.

위 20261014080000 마이그레이션은 조사 중인 로컬 체크아웃에 없어, 해당 변경은 운영 `supabase_migrations.schema_migrations.statements`를 직접 조회해 확인했다. 로컬 소스와 실제 운영 정의를 구분한다.

## 관측 시각과 영향

시간은 모두 베트남 시간이다. 최초 실패 관측 시각은 변경 적용 시각 자체를 뜻하지 않는다.

- 분식클럽 근태 사진 업로드 마지막 성공 관측: 2026-10-14 21:06:01.
- 최초 실패 관측: 2026-10-14 21:16:02.
- 포토 6개 매장도 2026-10-14 22:00 이후 같은 오류가 관측되며 다음 날 아침까지 이어졌다.
- 조사 시점에 포토 6개 매장과 BunsikClub Binh Thanh의 2026-10-15 근태 기록은 모두 0건이다.
- 기존 근태 조회 RPC에는 HTTP 200 응답이 관측된다.

최초 실패 시각 이후 조회된 Edge 로그의 근태 사진 POST 요청 집계:

| 매장 | HTTP 400 요청 수 |
| --- | ---: |
| BunsikClub Binh Thanh | 14 |
| PHOTO OBJET BIEN HOA | 8 |
| PHOTO OBJET DI AN | 6 |
| PHOTO OBJET LONG THANH | 12 |
| PHOTO OBJET THAO DIEN | 16 |
| PHOTO OBJET QUANG TRUNG | 9 |
| PHOTO OBJET NOW ZONE | 7 |
| 합계 | 72 |

이는 반환된 운영 로그의 요청 수이며 실패한 직원 수나 완전한 전수 집계를 뜻하지 않는다. 동일 직원의 재시도가 포함될 수 있다. 위 조회에서 성공 응답은 없었다.

## 기존 계정별 권한 — 장애와 구분

2026-10-15 사용자 정정: 키친·트레이·층별 계정에는 원래 근태 권한이 없다. 이 권한 부재는 의도된 계약이며 결함이 아니다. 앞선 조사에서 이를 추가 문제로 분류하고 권한 확대를 제안한 해석을 철회한다.

아래 역할·활성 상태와 근태 RPC 허용 여부는 운영 DB 정의를 기준으로 확인했다. 확인한 계정은 모두 활성 상태이며 매장 연결도 존재한다.

| 계정 | 운영 역할 | 근태 저장 RPC 역할 조건 |
| --- | --- | --- |
| `bh_ops1`, `da_ops1`, `lt_ops1`, `td_ops1`, `qt_ops1`, `nz_ops1` | `photo_objet_store_operator` | 허용. 공통 사진 업로드 장애로 저장 중단 |
| `bt_pos1`, `bt_tab1` | `cashier` | 허용. 공통 사진 업로드 장애로 저장 중단 |
| `bt_kit` | `kitchen` | 기존 계약대로 미허용. 변경 대상 아님 |
| `bt_tray`, `bt_1f`, `bt_2f` | `emergency_station` | 기존 계약대로 미허용. 변경 대상 아님 |

운영 `record_employee_attendance`의 허용 목록에는 `kitchen`, `emergency_station`이 없다.
로컬 `lib/core/utils/role_routes.dart:103`도 `emergency_station`의 `/attendance-kiosk` 진입을 허용하지 않는다. 이 화면 조건은 로컬 소스 확인 결과이며 실제 배포 번들의 화면 동작은 별도로 실행하지 않았다.

## 재현 및 조사 한계

운영 DB에서 실제 INSERT를 실행하지 않는 다음 검사로 SQLSTATE `42501`과 동일 함수 권한 오류를 재현했다.

```sql
BEGIN READ ONLY;
SET LOCAL ROLE authenticated;
EXPLAIN (COSTS OFF)
INSERT INTO storage.objects(bucket_id, name)
VALUES (
  'attendance-photos',
  '8bc9eef5-dcd5-46b1-b931-23f77132322c/diagnostic-plan-only/no-file-created.jpg'
);
ROLLBACK;
```

`EXPLAIN`에 `ANALYZE`를 사용하지 않았고, 계획 단계에서 실패했다. 파일·사진·근태 행은 생성하지 않았다.
실제 직원 계정 로그인, 사진 촬영·업로드, 출퇴근 입력은 수행하지 않았다. 원인 조사만 진행했으므로 앱 테스트·빌드·배포는 수행하지 않았다.

## 권장 복구 범위

1. 새 마이그레이션에서 `inventory_receipt_statement_objects_write`를 재생성해 현재의 `can_create_inventory_purchase_order(uuid)` 래퍼를 참조하도록 수정한다. 기존 버킷·매장·수령 승인 조건을 보존한다. 이전 내부 함수에 실행 권한을 되돌리면 새 승인 조건을 우회하는 외부 호출 경로를 열 수 있으므로 그 방식은 피한다.
2. 같은 Storage 테이블의 정책 함수 의존성·실행 권한을 함께 확인하고, 근태·발주 파일 업로드 회귀 검증과 타 매장 거부 검증을 추가한다.
3. 근태 저장 RPC의 역할 허용 목록과 화면·내비게이션 권한을 보존한다. 키친·트레이·층별 계정의 근태 권한을 추가하지 않는다.
4. 실패 기간의 근태는 자동 복구할 저장 행이 없다. 실제 출퇴근 시각을 확인해 기존 관리자 수동 근태 절차로 보완해야 한다. 실패 로그의 사진 촬영/업로드 시각을 곧바로 확정 출퇴근 시각으로 간주하지 않는다.

운영 수정·배포는 수행하지 않았다. 복구 시 프로젝트의 공식 배포 절차와 해당 SHA 검증을 적용해야 한다.

후속 계획: [근태 기능 개선 계획 재수립](ATTENDANCE_IMPROVEMENT_PLAN_2026_10_15.md).

후속 실행: 2026-10-15 DB 장애 복구와 웹 개선 배포를 완료했다. 이 문서의 미배포·0건·오류 집계는 최초 조사 시점의 기록이다. [실행·검증 기록](ATTENDANCE_RECOVERY_IMPLEMENTATION_2026_10_15.md)을 참조한다.
