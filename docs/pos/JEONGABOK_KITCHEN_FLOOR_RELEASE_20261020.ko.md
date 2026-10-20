# 전가복 주방 → 층 직접 전달

사용자 승인: 2026-10-20, 구현·검증·운영 배포 및 checker ID 정리.

## 운영 계약

- 적용 매장: JeonGabok Binh Thanh (`273b057e-3b69-46e3-93c1-6194c2802849`) 하나.
- 주방 조리 완료 → 해당 층 준비 → 층 직원 고객 전달. 조리 완료로 실제 전달을 자동 확정하지 않는다.
- `jgbt_tray1`의 프로필·Auth 로그인·매장 접근·station·필수 계정·푸시를 비활성화한다. 이력과 ID 참조는 보존한다.
- 다른 매장의 주방 → checker → 층 방식과 계정은 유지한다.
- 전가복 저장 층 `1F`·`2F`·`3F`는 동일 층 계정으로 전달한다. 화면 표시 G·1F·2F 변환은 기존 표시 계약을 유지한다.
- 남은 음식 포장: 층 → 주방 → 층 → 고객. 배달/고객 픽업은 조리 완료 시 준비 완료만 반영하며, 실제 기사/고객 인계는 기존 담당자가 별도로 확정한다.
- 큐의 `kitchen_direct_to_floor`는 생성 시 고정한다. 기존 수량 체인과 QR/보고서의 호환을 위해 tray 수량 필드는 주방 완료 수량의 투영으로 유지한다. 가상의 checker 사용자나 checker 처리 이벤트는 생성하지 않는다.
- 새로운 전가복 주문은 checker 조회·catch-up·실시간·푸시 대상에서 제외한다. 폐기 계정의 기존 JWT도 제한 정책으로 legacy table 구독을 읽지 못한다.

## 구현과 검증

정확한 대상 UUID를 허용하는 서버 함수와 큐 스냅샷으로 범위를 제한한다. 신규 migration은 유효 함수의 변경 위치가 예상과 다르면 전체 트랜잭션을 중단한다. 전달 방식, 층 매핑, 계정 변경은 한 migration에 원자 적용한다. 진행 주문/남은 음식 포장이 있으면 전환을 중단한다.

주방·층 일괄 처리는 기존 집합 처리 kernel과 한 번의 RPC를 재사용한다. 1,000행/총 1,000수량 상한과 단말당 쓰기 직렬화를 유지한다. 데이터 범위는 해당 매장·활성 세션·선택한 원장이다. SQL 회귀 검사는 운영의 public/auth 스키마만 복제한 로컬 격리 DB에서 합성 데이터로 수행한다. 운영 주문이나 테스트 계정을 만들지 않는다. 격리 복제에서 제외된 invoice private 스키마의 정책 네 개는 KDS 검증 범위 밖이다.

검증 명령:

```sh
flutter test test/jeongabok_kitchen_floor_test.dart test/kds_start_ready_workflow_test.dart test/kds_tray_floor_customer_delivery_test.dart test/kds_subsecond_set_based_delivery_test.dart
bash scripts/check_repo.sh
# 격리·시드 DB에서 supabase/tests/jeongabok_kitchen_floor_test.sql 실행
```

SQL 검사: 층 3개 분리, 부분/일괄 조리, 별도 고객 전달, 멱등 재전송, payload 충돌, 이미 전달한 수량 원복 금지, 콤보 부모/구성품, stale 일괄 처리 전체 원복, 남은 음식 포장, checker 비활성화/재활성화 방지, 다른 매장 기존 인계와 매장 경계.

## 배포와 복구

정확한 main SHA의 GitHub `POS release contract` 성공을 확인하고 `scripts/deploy_pos_production.sh --migration supabase/migrations/20261020090000_jeongabok_kitchen_floor.sql`로 배포한다. 전·후 다른 매장 계정·배정·설정·진행 수량의 해시를 비교한다. 운영 검증은 읽기와 실제 기존 계정 로그인으로 수행한다.

직접 전달 주문이 시작된 뒤 서버를 이전 checker 수량 의미로 단순 되돌리거나 폐기 계정을 재활성화하지 않는다. 장애 시 주문 접수를 일시 중단하고 진행 수량을 보존하여 전가복 분기를 수정하는 별도 migration을 적용한다. 전가복 설정이 없는 이전 앱도 서버의 직접 전달 처리를 사용하지만 새 앱으로 갱신해야 올바른 문구/원복 버튼을 표시한다.

## 메뉴 S/M·맵기 계획 연계

다른 채팅에서 전달된 `/Users/andreahn/globos_pos_system/docs/plans/menu_size_spice_checker_integrated_plan_20261020.md`는 메뉴 옵션의 별도 구현 계약이다. 이번 변경은 기존 주문행 ID·메뉴명·메모·수량·가격을 재작성하거나 합치지 않는다. 구조화된 옵션 도입 시 이 계획의 CartItem/직접 주문/KDS 집계 키와 서버 가격 검증을 함께 반영해야 한다. 메뉴 옵션의 운영 구현 여부는 checker 제거와 구분해 기록한다.

## 검증·배포 결과

진행 중. 검증 실행과 운영 배포 완료 후 실제 결과·커밋·측정 한계를 아래에 기록한다.
