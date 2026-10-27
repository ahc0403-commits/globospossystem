# 고객 입금 QR 변경 조사와 인쇄 경로 보완

> Current owner policy (2026-10-27): automated verification runs in Codex Cloud or a suitable isolated cloud executor under root `CLAUDE.md`. Preserve complete final-SHA evidence, exact-main, official deployment and operational gates. Historical results below do not certify this candidate.

2026-10-12 / Asia/Ho_Chi_Minh. 사용자의 첨부 QR은 MSB, BIN `970426`, 계좌 `80002014298`, 수취인 `AKJ INTERNATIONAL CO., LTD`다. 이미지의 QR을 실제 디코딩해 계좌를 확인했다.

## 운영에서 확인한 사실

- 운영 법인 계좌는 **2026-10-11 22:05:43 (+07:00)**부터 MSB 계좌다. 빈탄 직접 주문 storefront도 같은 계좌다. 오늘 생성된 직접 주문 세션 7개는 MSB 스냅샷을 사용한다.
- 어제 같은 변경을 main에 병합하고 웹에 배포한 채팅 기록을 확인했다. 초기 소스 보고서의 “배포 금지 / 운영 미적용”은 그 이후 배포 상태를 반영하지 못한 과거 기록이다.
- 현재 운영 URL의 Vercel 배포는 `dpl_Hkw4QWt5AWfAZnakkKUuryiSShZM`, SHA `4c8e1b4ed5573e0c8b2c1287d54170e99c58cb8e`, 상태 READY다. 실제 게시된 `main.dart.js`의 SHA-256은 `5a388254e522b209a254553868d87c62ed5edfbb5ab25a139a825fd0cd78def5`로 배포 기록과 같다.
- 배포된 cashier의 단독·합산 결제와 고객 표시 화면은 서버 계좌를 사용하는 코드다. 직접 주문의 본 결제·추가 결제는 storefront의 은행 정보를 사용한다. 이 소스/배포 확인은 매장 단말의 화면을 직접 확인한 결과와 구분한다.
- **배포된 인쇄 영수증에는 우리은행 개인 계좌와 `woori_bank_account_qr.jpg`가 여전히 고정돼 있었다.** 법인 계좌 변경과 연결하지 않은 구현 누락이다. 기존 테스트도 그 옛 계좌를 기대하고 있어 누락을 막지 못했다.
- 과거 직접 주문 세션 45개에는 기존 우리은행 스냅샷이 보존돼 있다. 운영 `direct_order_public_resume_storefront`는 정상 storefront 반환 시 현재 계좌를 반환하지만, paused fallback에서는 과거 스냅샷을 반환하는 차이가 있다. 열린 고객 페이지의 `_storefront.bank` 역시 초기 로딩 값이며 상태 폴링에서 갱신하지 않는다.

현재 매장 단말의 설치 버전, 이미 열린 브라우저의 실행 코드, 고객이 실제 본 QR을 직접 관찰하지 못했다. 따라서 **모든 결제 페이지가 이전 QR을 보이는 직접 원인이 오래된 앱/브라우저인지, 기존 세션인지까지 확정한 것은 아니다.** 인쇄 QR 누락은 배포 소스에서 확정했다.

## 이번에 보완한 소스

- 영수증의 고정 우리은행 텍스트·이미지 로딩을 제거했다. `CollectionBank`의 BIN·계좌·수취인으로 동일한 VietQR 생성기를 사용한다.
- `QueuedPaymentReceipt`와 print agent가 서버 payload의 `bank`를 전달한다. 계좌가 없는 영수증은 다른 법인 또는 개인 계좌를 임의로 표시하지 않는다. 내부 서비스 영수증에는 QR을 인쇄하지 않는다.
- 신규 마이그레이션 `20261012183000_receipt_collection_bank.sql`은 기존 영수증 profile 조회에 활성 법인 계좌를 JOIN해 큐에 보관한다. 이미 보관한 계좌는 payload 수정 시 유지하며, 신규 큐는 현재 계좌를 사용한다. 기존 큐/판매 원본을 일괄 다시 쓰지 않는다.
- 클라이언트의 은행 조회 RPC를 추가하지 않았다. 기존 profile 조회 한 번에 unique active-account JOIN을 추가했다. 출력 건마다 별도 은행 요청이나 SQL 반복을 넣지 않았다.
- 관련 계약 테스트를 수정하고 신규 SQL 검사도 `scripts/check_repo.sh`에 연결했다. 과거 이미지 파일은 보존했으나 현재 영수증 코드에서는 참조하지 않는다.

## 확인 결과와 한계

- 인쇄·고객 표시·직접 주문 결제·VietQR·관련 매출/라우팅 Flutter 검사 통과. 변경 Dart 파일 정적 분석과 포맷·diff 검사 통과.
- 소유한 일회성 Docker DB에서 실제 기존 enrichment 함수와 신규 마이그레이션을 적용했다. 서버 계좌 선택, 위조 payload 무시, 법인 분리, 계좌 변경 후 신규 큐, 기존 큐 계좌 보존, 미설정 매장, 주방 경로, 두 번 적용을 확인했다.
- 로컬 소규모 fixture의 계좌 JOIN 실행계획은 각 PK/active-account 인덱스로 각 1행을 읽었고 반환 1행, 실행시간 0.089ms였다. 운영 시간이나 전체 인쇄 배치 성능의 측정값은 아니다.
- 실제 생성한 ESC/POS 바이트에서 512×512 raster를 추출해 macOS Vision으로 디코딩했다. 사용자 첨부 QR과 **payload가 완전히 일치**했다:

  `00020101021138550010A000000727012500069704260111800020142980208QRIBFTTA53037045802VN63044E6F`

**이번 보완은 로컬 소스와 검증까지다. 신규 운영 마이그레이션·commit/push·웹 배포·Windows 패키지 교체를 수행하지 않았다.** 전체 릴리스 CI나 물리 프린터/현장 단말 검증도 이번 조사에서 완료한 것으로 표시하지 않는다. 실제 운영 반영에는 정식 배포 스크립트와 정확한 pushed SHA의 필수 로컬 전체 검증, 수정된 native print station 교체가 필요하다.
