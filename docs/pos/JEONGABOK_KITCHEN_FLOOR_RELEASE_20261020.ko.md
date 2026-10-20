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

주방·층 일괄 처리는 기존 집합 처리 kernel과 한 번의 RPC를 재사용한다. 1,000행/총 1,000수량 상한과 단말당 쓰기 직렬화를 유지한다. 데이터 범위는 해당 매장·활성 세션·선택한 원장이다. SQL 회귀 검사는 운영의 public/auth 및 메뉴 계산서 private 스키마만 복제한 로컬 격리 DB에서 합성 데이터로 수행한다. 운영 주문이나 테스트 계정을 만들지 않는다. 운영 데이터는 복제하지 않았다. private 스키마 복원 전에 생성되지 않은 계산서 정책 네 개는 이 격리 DB의 직접 테이블 RLS 검사 범위 밖이며, 메뉴 관리 RPC의 권한 검사는 실제 함수를 사용했다.

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

## 함께 배포하는 S/L·맵기

사용자가 2026-10-20 메뉴 옵션을 함께 구현·배포하도록 승인했고, 최종 규격은 **S/L**로 정정했다. M은 허용하지 않는다.

- 단일/S/L, 맵기 미확인/안 매움/매운 메뉴, 등록된 조절 맵기 선택명을 관리자 메뉴 화면과 엑셀에서 관리한다. S/L과 허용 맵기 조합은 **각각 고유 메뉴 ID와 실제 판매 가격으로 등록**한다. 주문 목록에 각 선택과 가격이 별도 표시되어 함께 주문할 수 있다. 메뉴·규격별 레시피/계산서 매핑을 기존 ID 체계로 명시적으로 연결하며 임의 배수를 만들지 않는다.
- `portion_code`, `spice_level`, `spice_choice`가 구조화된 원본이다. `option_base_names`로 원래 이름을 보존한다. 기존 POS/QR/직접 주문/프린터 계약에서도 선택 정보가 보이도록 다국어 표시명 앞에 S/L·맵기 아이콘과 텍스트를 붙인다. 긴 메뉴명에서도 선택 정보가 먼저 보인다.
- 실제 조절 가능한 메뉴만 허용 선택마다 등록한다. 고정 메뉴에 자유 맵기 입력을 제공하지 않는다. 사용자 주문은 등록된 판매 ID와 서버 단가를 사용한다.
- `menu_option_key`는 규격·맵기·가격의 서버 검증값이다. POS/QR/직접 주문, 임시 장바구니, 오프라인 payload에서 유지한다. 관리자 수정 후 오래된 선택을 재전송하면 다시 선택하도록 거절한다. 검증은 정렬된 공유 잠금과 한 번의 집합 비교로 수행한다.
- `menu_option_snapshot`은 주문 당시 선택·다국어 이름·단가를 보존한다. 주방·층·재접속·내역·기존 영수증 label에 반영한다. KDS 집계 키는 구조화된 선택도 포함한다. 콤보 구성품은 각각의 판매 ID/기존 구성품 스냅샷을 유지한다.
- 기존 메뉴 가격·이름·판매 상태·레시피·계산서 매핑을 일괄 변경하지 않는다. 기존 메뉴는 단일/맵기 미확인이다. 실제 S/L 가격과 맵기는 관리자가 등록해야 하며 이번 배포에서 임의 분류/가격을 입력하지 않는다.
- 엑셀에는 `양(S/L)`, `기본맵기`(`unknown`, `not_spicy`, `spicy`), `맵기선택명`을 추가한다. 빠진 구버전 열은 기존 값을 보존하고, 명시적인 빈 규격/선택명은 해제한다. S/L 별 행은 허용하고 같은 조합의 중복은 행 번호로 알린다.

## 통합 배포 순서와 복구

이번 릴리스에는 서로 다른 운영 게이트를 가진 migration 두 개가 필요하다. 공식 스크립트의 단일 migration 제한을 유지하고 두 번 실행한다. 메뉴 migration은 계정 변경 없이 호환 스키마/RPC를 먼저 제공한다. 다음 전가복 migration은 미전달 주문/포장이 없는지를 다시 확인하고 계정과 전달 방식을 원자 전환한다. 마지막 실행에서 Edge·앱 배포와 운영 로그인까지 완료한다. Git 자동 배포는 `vercel.json`에서 비활성화되어 있다. 정확한 main SHA와 필수 CI 성공 조건은 매 실행에 적용한다.

```sh
# ENV_FILE은 비밀 파일 경로. 문서/로그에 내용을 복사하지 않는다.
ENV_FILE=<secure-env> CONFIRM_PRODUCTION_DEPLOY=DEPLOY_GLOBOS_PROD \
  scripts/deploy_pos_production.sh --db-only --yes \
  --migration supabase/migrations/20261020100000_menu_portion_spice.sql \
  --test test/menu_portion_spice_test.dart
ENV_FILE=<secure-env> CONFIRM_PRODUCTION_DEPLOY=DEPLOY_GLOBOS_PROD \
  TEST_TARGETS="test/jeongabok_kitchen_floor_test.dart test/menu_portion_spice_test.dart test/direct_order_combo_service_test.dart" \
  scripts/deploy_pos_production.sh --yes \
  --migration supabase/migrations/20261020090000_jeongabok_kitchen_floor.sql
```

메뉴→전가복 및 전가복→메뉴 적용 순서를 모두 격리 DB에서 검증했다. 새 선택을 등록한 뒤 열/스냅샷을 삭제하거나 구버전의 묵시적 주문으로 되돌리지 않는다. 장애 시 판매 가능 상태로 접수를 조절하고 스냅샷을 보존하는 수정 migration을 적용한다. checker 계정을 임의 복구하지 않는다.

## 로컬 검증 결과

- SQL: S/L 동시 주문과 가격 합계, 허용 외 규격·가격 위변조·다른 매장 선택 차단, 관리자 권한, 실제 POS 생성/추가·QR 주문·직접 주문 준비, 메뉴 수정 후 주문 스냅샷 유지, 구버전 엑셀 보존과 S/L 신규 등록을 실제 유효 함수로 검증했다. 콤보 구성품의 구조화된 선택과 디지털/물리 영수증, 가격 수정 뒤 부분 테이블 이동도 확인했다.
- 전가복: 1F/2F/3F, 부분·일괄 처리·원복·멱등성·콤보·남은 음식 포장·다른 매장 checker 유지와 실제 deferred broadcast topic을 검증했다. 폐기 계정의 기존 JWT는 실제 authenticated 역할과 RLS로 orders/order_items/KDS 원장 조회가 0행임을 확인했다.
- 동시성: 주방/층 각각 20개 동시 동일 요청에서 실제 변경 1회, 중복 응답 19회, 감사 이벤트 2개로 완료했다.
- 메뉴 10/100/500개: 기존 페이지 상한 200을 유지하여 요청 1/1/3회, 응답 5,350/48,283/241,615 bytes. 로컬 서버 내 20회 측정 p50 1.483/3.537/20.265 ms, p95 2.356/5.879/58.594 ms. 주문 선택 10/50/50행 검증 0.380/0.593/0.614 ms(각 단일 측정).
- S/L을 포함한 활성 주문 10/100/500건에서 주방·층 완료 각각 RPC 1회. 주방 22.210/77.659/555.176 ms, 층 7.801/74.331/483.080 ms. 최대 응답 약 20 KB. 감사 이벤트는 수량별이 아니라 주문행별이다.
- 메뉴 옵션 조회/검증은 배치 JOIN이며 POS 추가/QR의 품목별 INSERT와 QR 콤보 조회 반복을 제거했다. 스냅샷만 갱신할 때 기존 행 트리거의 조회·갱신 알림을 재실행하지 않는다. 기존 주문 INSERT의 업무/FK 행 트리거는 유지하므로 전체 SQL statement 수가 상수라는 주장은 하지 않는다.
- 측정은 합성 데이터·격리 PostgreSQL에서 수행했으며 네트워크, 현장 단말, 메모리, 운영 부하와 KDS COMMIT의 deferred broadcast 소요 시간을 포함하지 않는다.

## 검증·배포 결과

전체 저장소 검사, 정확한 main SHA의 GitHub CI 및 공식 배포 결과는 이 변경의 PR과 작업 배포 증거에 기록한다. 운영 반영 여부를 위의 로컬 검증만으로 판단하지 않는다.
