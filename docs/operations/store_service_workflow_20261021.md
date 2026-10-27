# 매장별 음식 제공 동선과 현금 입금 QR 수정

> Current owner policy (2026-10-27): automated verification runs in Codex Cloud or a suitable isolated cloud executor under root `CLAUDE.md`. Preserve complete final-SHA evidence, exact-main, official deployment and operational gates. Historical results below do not certify this candidate.

분식클럽은 주방 → 트레이 → 층, 전가복 빈탄점은 주방 → 층이 기본이다.
개점 설정의 프린터/운영 설정 단계에서 음식 제공 동선을 별도로 저장한다.
`paperless`/`pos_print` 선택과 음식 제공 동선은 독립된 설정이다.

`admin_validate_store_opening_config_v3`와 `admin_apply_store_opening_config_v3`는
기존 테이블·프린터 검증/저장을 유지하며 `kds_workflow`를 원자적으로 저장한다.
동선 변경은 최고 관리자에게만 허용하고, 열린 주문·미전달 음식·포장 작업이
있으면 차단한다. 기존 주문의 `kitchen_direct_to_floor` 스냅샷은 보존한다.
전가복의 폐기된 트레이 계정과 손님 층 이름 규칙은 전가복에만 유지한다.
계정 및 스테이션 배정은 기존 인력 설정에서 관리한다.

트레이 카드/상세 화면은 `전달 수량 / 주문 총수량`을 표시한다. 주방 완료가
0이어도 주문 수량은 표시하며, 실제 전달 가능한 수량은 주방 완료 수량을 넘지 않는다.

현금 입금 QR은 최종 합계를 보고서 표시와 동일한 정수 VND로 한 번 반올림한다.
재현 금액 `3,389,971.9`는 `3,389,972 VND`로 QR에 들어간다.
원래 결제·매출·마감 기록은 바꾸지 않는다.

검증: 트레이·QR 관련 Flutter 122개, 화면 캡처 8개, 설정 관련 Flutter 51개 통과.
격리 SQL에서 저장·권한·테넌트·진행 주문 보호·스냅샷 보존을 확인했다.
실제 스키마 복제본에서 분식클럽 트레이 경유, 전가복 조리 시작/명시적 인계,
새 매장의 설정 기반 직접 전달과 층 이름 보존도 통과했다.
500개 주문 일괄 처리 실측은 주방 완료 약 345ms, 층 제공 약 406ms,
단계당 RPC 1회, 응답 약 20KB였다(격리 fixture 기준).
500개 큐 행의 동선 판정에 설정 집계는 1회 호출되었다(1행, 약 0.002ms;
격리된 작은 설정 fixture 기준이며 운영 부하 측정값은 아님).

소스 구현 및 로컬 검증 기록이다. 운영 반영 여부는 공식 배포 스크립트와
동일 main SHA의 필수 로컬 검사 결과로 별도 확인한다.

후속 검증에서 이벤트 트리거가 동선 설정을 항목마다 재조회하는 경로를 발견해,
이미 읽은 큐·변경 이벤트의 동선 스냅샷을 전파하도록 보완했다.
설정 ID 집계 함수는 외부 authenticated/service_role RPC로 노출하지 않는다.
이 보완 전에는 운영 migration 및 웹 배포를 실행하지 않았다.
