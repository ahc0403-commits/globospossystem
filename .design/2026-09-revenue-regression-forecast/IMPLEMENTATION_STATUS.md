# 매출 예측 구현 상태

- 기준일: 2026-09-16
- 구분: 소스 구현 / 자동 검증 / DB 적용 / 배포 / 운영 검증을 별도로 기록한다.

## 현재 구현된 소스

- 모든 매장에서 재사용하는 `RevenueForecastPanel`을 기존 매출 분석과 Photo 운영
  화면에 연결했다. 오늘 진행 중 매출은 호치민 시간 기준으로 학습에서 제외한다.
- 최소 28개 영업일을 사용하는 일별 추세·요일 회귀와 순방향 과거 검증
  (MAE, RMSE, WAPE, 동일 요일 기준)을 구현했다.
- 레스토랑은 테이블 회전, 주방, 체커, 층별 서비스 처리량, 식사·결제·정리시간,
  일 영업시간과 영업 요일을 수용 능력 상한에 반영한다.
- 레스토랑의 여섯 단독 개선 시나리오를 같은 수요로 재계산하고 추가 매출·서비스 수,
  입력 변경과 다음 병목을 표시한다. 순수 식사시간 단축은 권하지 않는다.
- Photo는 기기당 8분, 유료 1회 85,000 VND를 고정하고 기기 수·영업시간·영업 요일·
  무료 서비스 회수를 용량에 반영한다. 개선 제안과 개선 시트는 생성하지 않는다.
- 10억/15억 VND 목표를 완전 월 기준으로 판정하고 최초 도달, 3개월 유지,
  수요 부족과 용량 초과를 구분한다.
- 영업일 누락, 휴무일 양수 활동, 중복일, 음수·NaN, 전부 0, 잘못된 프로필을
  오류로 처리한다. 휴무일은 수요가 있어도 실현 매출과 용량을 0으로 계산한다.
- KO/VI/EN, 320px·200% 글자 배치, 실행 중 언어 전환의 draft/result 보존,
  모바일 카드/목록, 접근 가능한 필드·버튼과 오류 상태를 구현했다.
- 매장별 immutable revision 프로필, optimistic conflict, RLS/read scope와
  관리자 역할별 store-scoped save RPC를 additive migration으로 작성했다.
- 예측 전용 XLSX에 결과, 월별 수요/용량, 회귀계수, 과거 검증, 입력 snapshot,
  프로필 revision과 레스토랑 개선 비교를 기록한다.

## 자동 검증 범위

- 순수 계산, 경계조건, Photo 고정 정책, 프로필 JSON, SQL 정적 계약, XLSX,
  반응형 widget, 세 언어 키 동등성, 지연 프로필 응답과 실행 중 언어 전환을 검사한다.
- `flutter analyze`: 전체 저장소 통과.
- 예측 관련 계산/프로필/SQL/XLSX/widget/i18n 및 연동 테스트: 통과.
- `flutter build web --release`: 통과. 기존 `image 4.3.0`의 Wasm dry-run lint와
  Cupertino font 경고는 남아 있으나 JS web release 산출물은 생성됐다.
- 전체 `flutter test`: 1,442건 통과, 3건 skip 후 1개의 기존 비관련 차단만 남았다.
  `direct_delivery_regression_isolation_test`가 사용자 작업 중 변경된
  `payment_total_calculator.dart`의 frozen hash 불일치로 실패한다. 매출 예측 대상
  테스트와 신규 현지화 hash 계약은 통과한다.

## 아직 완료로 표시하지 않는 항목

- migration은 작성만 했고 운영 DB에 적용하지 않았다.
- production web/native 배포와 exact-SHA CI를 실행하지 않았다.
- 실제 매장별 테이블/좌석, 시간대·메뉴 경로, 휴게·중단 window, 공유 인력 이동을
  원천 이벤트에서 자동 집계하는 RPC는 아직 없다. 현재 프로필은 관리자가 확인한
  일 단위 처리량을 직접 입력하는 방식이다.
- 명시적 무매출 확인/부분·실패 원천 fingerprint를 저장하는 일별 확인 원장은 아직 없다.
- 복합 병목 시나리오, 시간대 스케줄러, 통계적 예측 구간, 사용자 지정 목표는 아직 없다.
- VoiceOver/TalkBack/NVDA, 400% 확대, 실제 iOS/Android/브라우저 파일 저장,
  성능 p50/p95, 현장 번역 검수와 운영자 UAT는 수행하지 않았다.

따라서 현재 상태는 배포 가능한 운영 완료가 아니라 **검증 가능한 1차 소스 구현**이다.
DB 적용과 공개는 `CLAUDE.md`의 release gate와 공식 production script를 통과한 뒤
별도 증거로 기록한다.
