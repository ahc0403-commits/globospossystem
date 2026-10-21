# 매장 생애주기 운영 배포 기록 (2026-10-22)

사용자 승인: 필수 CI 확인 후 운영 DB 적용·배포 및 분식클럽/전가복 주문·결제·주방 인계·매출 신고·발주 재검증.

- 대상: Supabase `ynriuoomotxuwhuxxmhj`, Vercel `globospossystem`, URL `https://globospossystem.vercel.app`.
- 적용 전 확인: 두 매장 활성, 미결 주문 각 0건. 분식클럽 `kitchen_tray_floor`, 전가복 `kitchen_floor`; `jgbt_tray1` 비활성, `jgbt_floor_1f`→저장 2F, `jgbt_floor_2f`→저장 3F.
- 운영에는 `20261021163000` 이후 일반 옵션/다중 주방 기반 12개와 생애주기 23개가 미적용이다. 이미 적용된 `20261021230000_owner_sales_reporting`은 다시 적용하지 않는다.
- 35개를 하나의 원자적 배포 묶음으로 적용하는 이유: 의존 함수 교체·가드·입고 원장의 중간 상태를 기존 클라이언트에 노출하지 않기 위함이다. `scripts/build_store_lifecycle_release.py`가 정본을 결합하고 해시를 고정한다. 적용과 component 이력 기록은 같은 transaction이다.
- 기존 매장/동선 설정, 계정·배정, 메뉴 판매 ID/가격/세금/선택, 발행 영수증 본문을 적용 전후 비교한다. 차이는 전체 rollback한다. 기존 매장의 준비/품질/로트 기능을 일괄 강제하거나 새 workflow를 활성화하지 않는다.
- 배포는 공식 `scripts/deploy_pos_production.sh`의 DB-only→web-only 두 단계다. 각각 깨끗한 exact `origin/main` SHA와 `POS release contract` 성공을 요구한다. 검사·계정 검증을 생략하지 않는다.
- 운영 검증은 실제 매출/공급업체 발주를 추가하지 않는 읽기 검증과, 배포된 schema를 복제한 격리 DB의 실제 프로시저 회귀를 함께 사용한다. 외부 신고·실제 지급·공급업체 전송은 실행하지 않는다.

## 적용 전 증거

현재 운영 schema만 export(업무 데이터 없음): `/tmp/globos-lifecycle-production-before-schema-20261022.sql`.
기존 전체 검사: `/tmp/globos-lifecycle-final-check2.log` exit 0; 최신 Flutter 2,495 통과/98 skip.
운영 배포 묶음 리허설과 CI·SHA·운영 적용·배포·사후 검증 결과는 실행 후 기록한다.

## 현재 상태

배포 준비 중. 운영 DB 변경·Vercel 배포는 아직 실행하지 않았다.
