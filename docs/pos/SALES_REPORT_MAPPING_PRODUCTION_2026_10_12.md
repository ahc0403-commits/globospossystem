# POS 매출 신고 매핑 운영 반영 기록

**운영 DB 적용·POS 웹 배포 완료.** 확인 시각: 2026-10-12T04:04:59+07:00 / Asia/Ho_Chi_Minh. 사용자의 운영 적용·배포 요청으로 실행했다.

## 배포 소스와 게이트

- [PR #561](https://github.com/ahc0403-commits/globospossystem/pull/561) 병합 완료.
- 실제 배포 main SHA: `4c8e1b4ed5573e0c8b2c1287d54170e99c58cb8e`.
- 로컬 전체 `scripts/check_repo.sh` 성공: Flutter 2,029개 통과, 정적 분석, SQL/Edge/배포 계약 및 웹 릴리스 빌드 통과.
- [main의 필수 POS release contract](https://github.com/ahc0403-commits/globospossystem/actions/runs/38172780554) 성공. PR 검사도 성공했고 두 소스 트리 해시는 같다.
- 원래 작업 공간의 기존 사용자 변경은 보존했다. 최신 main을 기준으로 별도 관리 작업 공간에서 이번 변경만 커밋·검사·배포했다.

## 운영 DB

정식 `scripts/deploy_pos_production.sh`로 드라이런 후 아래 마이그레이션을 각각 별도 DB-only 실행으로 순서대로 적용했다. 각 실행에서 exact-main/GitHub 게이트, 로컬 검사, 원자적 적용, 자체 검증, 이력 등록·재확인을 통과했다. `supabase db push`나 게이트 우회는 사용하지 않았다.

| 운영 이력 | 적용 내용 | 결과 |
|---|---|---|
| `20261012010000` | 메뉴·물티슈 승인 및 원본 재검증·기신고 보호 | 적용·이력 확인 |
| `20261012020000` | 페이지·집계·승인 revision·원본 fingerprint | 적용·이력 확인 |
| `20261012030000` | 실제 메뉴 73건 + 물티슈 1건 초기 등록 | 74건 등록·이력 확인 |

초기 승인 기간은 **2026-10-11 00:00 이상 ~ 2026-10-12 00:00 미만 (+07:00)**이다. 현재·향후 판매 기간으로 연장하지 않았다. 기간 밖 판매는 별도 유효한 승인 정보가 필요하다. 기존 유일한 활성 Super Admin을 사용자 승인 실행 주체로 기록했고, 계정 자체는 수정하지 않았다.

반영 후 실제 SQL 확인: 식당 105건 + Photo 464건 = **영수증 569건**, 원품목 **1,026개**, 엑셀 품목 **1,034행**, 승인 revision **74**. 첫 페이지 100건과 원본 fingerprint를 확인했다. 제공된 완료 보고에 따른 보호 상태는 `user_provided_report`이며, MISA의 발행·전송 성공 상태를 새로 만들거나 재검증하지 않았다.

반영 전후 물리 매장, 메뉴 마스터, `process_payment` 정의, 10/11 기신고 범위의 품목·구매자·결제 스냅샷 해시가 **모두 일치**했다. 운영 원본이나 기처리 매출을 다시 생성·발행하지 않았다.

## 운영 웹과 로그인

정식 스크립트의 전체 배포 경로로 서버 함수 및 Vercel 웹을 배포했다. 운영 Auth/매장 접근 확인, 서버 인증·CORS 확인, 라이브 HTTP 확인, 실제 지정 운영 계정 로그인 및 POS 프로필 조회가 성공했다. DB-only 결과를 로그인 확인으로 대신하지 않았다.

- [운영 POS](https://globospossystem.vercel.app)
- Vercel 배포 ID: `dpl_Hkw4QWt5AWfAZnakkKUuryiSShZM`, 상태 `READY`, target `production`.
- Vercel 배포 metadata의 SHA가 위 main SHA와 일치한다.
- 게시된 `main.dart.js`와 로컬 prebuilt 파일의 SHA-256이 일치한다: `5a388254e522b209a254553868d87c62ed5edfbb5ab25a139a825fd0cd78def5`.

**MISA 접속·가져오기·발행·세무당국 전송·이메일 외부 시험은 사용자 요청대로 제외했다.** Windows 빌드는 CI에서 통과했지만, Windows 현장 설치나 물리 프린터 시험은 이번 웹 배포 범위가 아니다.

## 증거

- [배포 metadata](evidence/sales_mapping_production_20261012/deployment.json)
- [운영 SQL 확인](evidence/sales_mapping_production_20261012/db-verification.log)
- [이력 확인](evidence/sales_mapping_production_20261012/migration-history.log)
- [배포 로그 — 이메일·토큰 비식별 처리](evidence/sales_mapping_production_20261012/deployment-sanitized.log)
- [보존 전](evidence/sales_mapping_production_20261012/preservation-before.json) / [보존 후](evidence/sales_mapping_production_20261012/preservation-after.json)

[소스 구현 기록](SALES_REPORT_MAPPING_IMPLEMENTATION_2026_10_12.md)과 [XLSX v3 수신 계약](SALES_XLSX_V3_CONTRACT.md)의 성능 한계 및 자동화 소비자 계약은 계속 적용된다.
