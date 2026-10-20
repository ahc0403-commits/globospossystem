# 고객 결제 QR 이미지 보고

2026-10-12. 현재 로컬 소스의 실제 고객 결제 위젯을 앱 테마와 예시 주문 데이터로 렌더링했다. 실제 매장 단말의 캡처나 이번 운영 배포 결과는 아니다. 앱 소스·운영 DB를 변경하거나 실제 주문 결제/입금을 실행하지 않았다.

표시 계좌: **MSB / 80002014298 / AKJ INTERNATIONAL CO., LTD**. 사용자가 제공한 QR의 BIN·계좌와 같다. 수취인 표시는 제공된 계좌 정보이며 은행의 실명 조회를 실행한 결과는 아니다.

## 매장 고객 표시 화면

가로 화면 1024×768. 예시 주문 결제금액 **181,000 VND**. 원본 Flutter `CustomerPaymentContent`가 서버 계좌 snapshot을 받는 경로에 동일한 계좌 데이터를 주입했다. 예시 메뉴·서비스 요금·할인·결제 합계와 VietQR을 함께 표시한다.

![매장 고객 표시 QR](/Users/andreahn/globos_pos_system/docs/pos/evidence/customer_payment_qr_20261012/customer_display_1024.png)

## 모바일 직접 주문 결제 안내

390×844. 예시 주문 **325,000 VND**, 이체 내용 A1024. 실제 `DirectOrderStorefrontScreen`의 결제 안내 sheet를 fixture service로 열었다. storefront의 bank 응답에 위 MSB 계좌를 제공했으며 실제 주문 생성·결제·증빙 업로드를 실행하지 않았다.

![모바일 직접 주문 결제 QR](/Users/andreahn/globos_pos_system/docs/pos/evidence/customer_payment_qr_20261012/mobile-quote-payment.png)

## 고객 표시 화면의 세로 배치

390×844에서 같은 고객 표시 위젯을 렌더링한 모습이다. 직접 주문 모바일 결제 안내와 다른 화면이다.

![세로 고객 표시 화면](/Users/andreahn/globos_pos_system/docs/pos/evidence/customer_payment_qr_20261012/customer_display_390.png)

## 결제 QR 확대

첫 고객 표시 화면에서 QR 영역을 직접 캡처했다. 예시 결제금액 181,000 VND와 DEMO 참조를 포함한다.

![결제 QR 확대](/Users/andreahn/globos_pos_system/docs/pos/evidence/customer_payment_qr_20261012/payment_qr.png)

## 확인 결과

고객 표시 가로·세로 렌더링 2건, 모바일 직접 주문 결제 화면 검사 1건 통과. macOS Vision으로 이미지 4개의 QR을 실제 디코딩했다. 모두 BIN 970426, 계좌 80002014298, VND 코드 704이며 각 화면의 예시 금액과 일치했다. EMV TLV 및 CRC-16도 별도로 검증했다. 고객 표시 QR은 앱 생성기의 기대 payload와 완전히 일치한다.

[디코딩 검증값](/Users/andreahn/globos_pos_system/docs/pos/evidence/customer_payment_qr_20261012/qr_validation.json). 실제 은행 앱으로 송금하거나 매장 단말 카메라로 스캔한 확인은 하지 않았다. 배포 금지 지시를 유지했다.
