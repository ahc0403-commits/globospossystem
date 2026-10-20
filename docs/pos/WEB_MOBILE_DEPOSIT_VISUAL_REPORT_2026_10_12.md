# 웹·모바일 입금 구분 변경 화면

2026-10-12. 로컬 구현의 실제 Flutter 위젯을 앱 테마·폰트로 렌더링했다. 금액·매장명은 검증용 예시이며 운영 매출/은행 잔액을 조회한 화면이 아니다. 운영 DB 적용·배포는 하지 않았다.
휴대폰 화면은 스크롤 내용 또는 변경 영역을 캡처했고, 실제 설치 앱의 스크린샷은 아니다.

## 법인 매출 요약

고객 계좌이체 3,000,000 VND를 별도로 표시한다. 포토 10,000,000과 마감 현금 1,750,000만 익일 입금 합계 11,750,000에 포함한다. 2026-10-12 매출의 입금 예정일은 2026-10-13이며 과부족 -50,000은 별도 상태로 표시한다.

**웹**

![법인 매출 요약 웹](/Users/andreahn/globos_pos_system/docs/pos/evidence/deposit_visual_report_20261012/sales_web.png)

**모바일**

![법인 매출 요약 모바일](/Users/andreahn/globos_pos_system/docs/pos/evidence/deposit_visual_report_20261012/sales_mobile.png)

## 매장 보고서의 결제수단 요약

현금·계좌이체·카드·페이를 상단에서 각각 표시한다. 모바일에서도 계좌이체 금액과 상세 조회 버튼을 바로 구분할 수 있다.

**웹**

![매장 보고서의 결제수단 요약 웹](/Users/andreahn/globos_pos_system/docs/pos/evidence/deposit_visual_report_20261012/payments_web.png)

**모바일**

![매장 보고서의 결제수단 요약 모바일](/Users/andreahn/globos_pos_system/docs/pos/evidence/deposit_visual_report_20261012/payments_mobile.png)

## 일일 마감

마감 확정 입금액 1,750,000 VND, 다음 날짜, MSB 법인 계좌를 함께 보여준다. 실사 현금 6,750,000에서 시재 5,000,000을 뺀 금액이며, 과부족이 있어도 마감 확정 금액은 유지한다.

**웹**

![일일 마감 웹](/Users/andreahn/globos_pos_system/docs/pos/evidence/deposit_visual_report_20261012/closing_web.png)

**모바일**

![일일 마감 모바일](/Users/andreahn/globos_pos_system/docs/pos/evidence/deposit_visual_report_20261012/closing_mobile.png)

## 포토 등록 결과

이번 파일 등록 범위 금액과 매출일·익일 입금 예정일을 표시하고, 전체 매장의 완전성은 법인 매출 요약에서 확인하도록 연결한다.

**웹**

![포토 등록 결과 웹](/Users/andreahn/globos_pos_system/docs/pos/evidence/deposit_visual_report_20261012/photo_web.png)

**모바일**

![포토 등록 결과 모바일](/Users/andreahn/globos_pos_system/docs/pos/evidence/deposit_visual_report_20261012/photo_mobile.png)

## 생성 및 확인

주요 화면 8가지 캡처가 렌더링 오류 없이 완료됐다. 앱 소스는 이번 이미지 보고 요청으로 변경하지 않았다. 화면 캡처 harness는 로컬 mock 데이터만 사용했으며 실제 입금·매출 등록·마감 RPC 쓰기를 실행하지 않았다.
