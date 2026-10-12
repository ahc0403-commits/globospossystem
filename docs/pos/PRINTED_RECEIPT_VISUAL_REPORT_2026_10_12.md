# 출력 영수증 이미지 보고

2026-10-12. **로컬 출력 바이트를 재현한 80mm 영수증 미리보기**다. 실물 프린터로 출력하거나 운영 배포하지 않았다. 계좌는 사용자가 요청한 MSB 정보를 제공했고, 주문·매장명·영수증번호·시각·금액 등은 예시 데이터다.

실제 `ReceiptBuilder.buildPaymentReceipt`가 만든 ESC/POS 바이트를 저장했다. 문자·행·열·굵기·크기·정렬·급지와 QR raster 명령을 해석해 576 dot 폭으로 그렸다. 프린터 내장 글꼴은 소프트웨어에서 사용할 수 없어 Courier New로 문자 모양을 근사했다. 실제 장비의 글꼴·농도·용지 여백·절단 위치를 보장하는 사진은 아니다. QR은 출력 바이트의 **512×512 단색 raster**를 그대로 추출해 사용했다.

## 결제 영수증

예시: 쌀국수 2개 180,000 + 물티슈 2,000 − 할인 1,000 = 총 **181,000 VND**. 표시 VAT는 합계에 포함된 금액이며 다시 더하지 않는다. MSB 계좌·수취인과 QR이 아래에 나온다.

![80mm 결제 영수증](/Users/andreahn/globos_pos_system/docs/pos/evidence/printed_receipt_20261012/receipt_80mm.png)

## 인쇄 QR

**MSB / 80002014298 / AKJ INTERNATIONAL CO., LTD**. 현재 영수증의 QR은 계좌용 정적 VietQR으로 금액을 포함하지 않는다. 영수증의 결제 총액은 문자로 표시한다.

![영수증 QR 확대](/Users/andreahn/globos_pos_system/docs/pos/evidence/printed_receipt_20261012/receipt_qr.png)

## 확인 결과

실제 바이트 생성과 미리보기 렌더링이 통과했다. macOS Vision으로 영수증 전체와 추출 QR을 각각 디코딩했다. 두 결과는 사용자의 최초 첨부 QR에서 확인한 payload와 완전히 일치했다: BIN 970426, 계좌 80002014298, VND 704, 국가 VN. 실제 송금·은행 앱 스캔·현장 프린터 출력은 실행하지 않았다.

- [출력 바이트](/Users/andreahn/globos_pos_system/docs/pos/evidence/printed_receipt_20261012/receipt_80mm.escpos.bin)
- [출력 문자](/Users/andreahn/globos_pos_system/docs/pos/evidence/printed_receipt_20261012/receipt_text.txt)
- [검증 값](/Users/andreahn/globos_pos_system/docs/pos/evidence/printed_receipt_20261012/validation.json)

보고용 임시 capture 파일만 사용했으며 앱 코드·운영 DB·프린터 설정을 이번 요청으로 바꾸지 않았다. 신규 계좌 profile migration 및 native print station의 운영 반영 여부는 앞선 [QR 조사 문서](/Users/andreahn/globos_pos_system/docs/pos/PAYMENT_QR_INVESTIGATION_2026_10_12.md)의 범위와 구분한다.
