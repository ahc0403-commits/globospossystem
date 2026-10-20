# 리포트 현금이체 QR

스토어매니저(`store_admin`)와 브랜드매니저(`brand_admin`)의 리포트에서
현금 카드 또는 **현금이체 QR 생성** 버튼을 누르면 당일 입금액을 입력할 수 있다.
기존 관리자·슈퍼관리자 역할에도 동일한 진입점을 제공한다.

사용자가 **25자 이내 짧은 적요를 QR에 자동 입력**하는 방식을 선택했다.
후속 지시에 따라 적요에서 회사명을 제거하고 분식클럽을 `BC`, 빈탄점을 `BT`로
표시한다. QR 적요는 `BC BT Cash Doanh thu 1710`(25자)이다.
마지막 네 자리는 일·월이다. 날짜는 리포트 조회 기간과 별개로 창을 연 시점의
베트남 현지 날짜를 사용한다.

[VietQR 생성 API 문서](https://vietqr.io/en/danh-sach-api/link-tao-ma-nhanh/api-tao-ma-qr/)는
적요를 25자로 제한한다. 짧은 적요는 영문·숫자·공백만 사용하고,
QR 스캔 시 수금 계좌·금액과 함께 자동 입력된다. 베트남어 매장명의 성조를
제거하고 공백을 줄이며, 매장명이 길거나 영문으로 표현되지 않으면 매장 ID에서
계산한 고정 접미사를 사용해 길이를 맞춘다. 브랜드 약칭은 최대 3자,
매장 약칭은 최대 10자이며, `Cash Doanh thu`를 포함해 25자가 넘는 다른 매장은
현금 표시를 `C`로 줄여 날짜를 유지한다. `Binn Thanh`, `Bình Thạnh` 표기도
빈탄점 약칭 `BT`로 처리한다.
25자를 초과하거나 QR 생성기에서 바뀔 수 있는 적요는 오류로 처리한다.

참고 문구 `BC BT Cash Doanh thu dd/mm`에도 회사명을 넣지 않으며,
선택적으로 복사할 수 있다. 등록된 매장명에 브랜드가 이미
있으면 중복하지 않는다. QR에는 짧은 적요가 들어간다.

계좌는 기존 `get_store_collection_bank(p_store_id)` RPC에서 선택한 매장의
법인 수금 계좌를 가져온다. 기존 접근 권한 검사를 사용하고, 임의 계좌를 대신
사용하지 않는다. 브랜드·매장명이나 계좌가 없으면 QR 생성을 막는다.
입금액은 양의 정수 VND이며, 1동 단위를 유지한다. 금액을 수정하면 이전 QR을
즉시 숨겨 재생성하도록 한다. 실제 송금, 입금 완료 기록, 일일 마감 저장은 수행하지 않는다.

검증 결과:

- 짧은 적요 수정 후 새 기능 테스트 31건과 기존 VietQR 테스트 3건, 합계 34건 통과.
  초기 구현에서 기존 리포트·입금·마감·VietQR 테스트 106건도 통과했다.
- `dart analyze --fatal-infos`, `flutter build web --release` 통과.
- 390/768/1440 너비, 한국어·베트남어·영어, 글자 크기 100%/200%의
  18개 조합에서 생성 및 화면 오류 없음 확인.
- 합성 데이터 화면 3장에서 Apple Vision으로 실제 QR을 해독하고, 테스트 수금 계좌,
  1,622,160 VND, 적요 `BC BT Cash Doanh thu 1710`, CRC를 독립 검증했다.
- 모의 HTTP 검증에서 화면 진입 전 추가 요청 0회, 창을 열면 계좌 RPC 1회,
  금액 수정·재생성 시 추가 요청 0회였다. 실패 후 명시적 재시도만 1회 추가한다.
  운영 서버 성능·실제 은행 앱의 스캔과 송금은 검증하지 않았다.

화면과 QR 해독 결과는 `outputs/cash-deposit-qr-20261017/`에 있다.
초기 구현 검증 단계에서는 DB 마이그레이션과 운영 배포를 실행하지 않았다.

사용자의 후속 배포 승인에 따라 운영 웹 반영을 완료했다. 릴리스 커밋은
`877672f304db3f9b7d68b94ea328be0d804c8386`이며, [PR #585](https://github.com/ahc0403-commits/globospossystem/pull/585) 및
[최종 main 필수 CI](https://github.com/ahc0403-commits/globospossystem/actions/runs/38997083306)가 통과했다. 공식
`scripts/deploy_pos_production.sh --web-only --yes` 경로로 배포했으며,
운영 계정 로그인과 운영 별칭의 READY 상태, 서비스 앱 파일의 SHA-256 일치를
확인했다. DB 마이그레이션과 Edge 함수 배포는 수행하지 않았다.
검증 기록은 `outputs/cash-deposit-qr-20261017/production_release.json`에 있다.

## 조회일·조회금액 정정 (2026-10-17)

앞의 오늘 날짜·수동 입력·`ddmm` 동작은 사용자 정정에 따라 폐기한다.
현금 카드에 표시한 조회 결과 금액을 자동 사용하고, 적용된 단일 조회일을
`dd/mm`으로 QR에 넣는다. 예: `BC BT Cash Doanhthu 16/10` (25자).
금액 입력란을 제거하고 복사 적요와 실제 QR 적요를 동일하게 맞췄다.
여러 날 조회는 하루 조회를 안내하며 조회 없음·로딩·0원·소수 금액은 생성하지 않는다.

수정 PR: https://github.com/ahc0403-commits/globospossystem/pull/586
관련 Flutter 테스트 126건 및 정적 분석 통과. 생성된 QR 3장을 독립 해독하여
1,622,160 VND, `16/10`, 수금 계좌 테스트 값과 CRC 일치를 확인했다.
수정 화면과 QR 검증 증거: `outputs/cash-deposit-report-fix-20261017/`.
운영 재배포는 필수 CI 후 진행한다.

포토 확장: 사용자가 법인별 조회 합계를 선택했다. 관리자 매출신고하기의 포토
입금 카드와 QR 버튼에서 조회 합계·조회 영업일·선택 법인 수금 계좌를 사용한다.
적요는 `PO Cash Doanh thu 16/10`. 추가 조회 요청 없이 기존 요약의 계좌를
재사용한다. 전체 관련 테스트 157건·정적 분석 통과, 포토 QR 이미지 3장에서
108,001 VND와 적요·계좌 테스트 값·CRC를 독립 검증했다.

### 조회일·금액 정정 및 포토 합계 QR 운영 재배포 완료

- 운영 커밋: `a9b49e07cf1601c46e7985ca715e786f7d5fbab2` (PR #586).
- 필수 CI: PR `39000288023`, 정확한 운영 커밋 `39001328399` 모두 성공.
- 공식 `scripts/deploy_pos_production.sh --web-only --yes` 성공. 검사 생략 없음.
- 운영 URL: https://globospossystem.vercel.app
- 새 배포: `dpl_CbtfrPgHUZ1KJyUhDv7BD1FZSqnT`, READY production, 운영 별칭과 ID 일치.
- 조회 날짜 `16/10`, 조회 금액 자동 사용, 포토 법인별 합계 QR 포함.
- 관련 Flutter 테스트 157건, 운영 로그인 및 HTTP 점검 통과.
- 실제 운영 JS는 로컬 공식 릴리스 빌드와 SHA-256 일치:
  `2d44f792319f562f84acd5aea3c7cc664e9c91520ae03f52960b8fff5d2d9fc2`.
- DB·Edge Function 배포 없음. 실제 매니저 로그인 UI와 은행 송금은 별도 실행하지 않았음.
- 증거: `outputs/cash-deposit-report-fix-20261017/production_release.json`.

### Doanh thu 띄어쓰기 수정

사용자 정정에 따라 `Doanh thu`의 띄어쓰기를 복원했다. 25자 이내를 유지하기
위해 `Cash`를 `C`로 줄여 `BC BT C Doanh thu 16/10`(23자)을 표시·복사·QR에
동일하게 사용한다. 이전 문서의 `Doanhthu`는 당시 배포 형식이며 이번 수정으로
폐기한다. 관련 테스트 64건·정적 분석 통과, QR 이미지 3장의 적요·금액·CRC 일치.
수정 PR: https://github.com/ahc0403-commits/globospossystem/pull/587

띄어쓰기 수정 운영 배포 완료: `a2aa22ad54e3e534bbd0be76301380c1ca841df2`.
PR 필수 CI `39005289669`, 운영 커밋 CI `39006508489` 성공 후 공식 웹 전용
배포 스크립트로 배포했다. 운영 로그인·HTTP·READY 별칭 일치를 확인했다.
운영 앱에서 `Doanhthu` 문자열이 없어졌으며 `C Doanh thu`가 포함됨을 확인했다.
운영 JS와 공식 빌드 SHA-256:
`22c7070f1775957d12c8c207b3282e268fed3ec5bfb33b3ed22f8e0ffaf76736`.
증거: `outputs/cash-memo-spacing-20261017/production_release.json`.
