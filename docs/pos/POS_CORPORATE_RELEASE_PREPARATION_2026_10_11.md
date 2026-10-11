# 법인 계좌·매출신고·MISA 배포 및 필수 CI 준비

작성일: 2026-10-11. 준비 범위는 검토 가능한 소스, 원자적 SQL 패키지, 필수 CI다. **배포 금지 지시가 유효하다.** 운영 DB 쓰기, Edge/Web 배포, main 병합, 설치 자동화 앱 갱신, 신고·발행·고객 발송은 실행하지 않는다.

## 격리한 후보

- 기반 main: `c998d7e89712293caae50340ccc9063bed6288c1`.
- 브랜치: `codex/corporate-sales-release-prep-20261011`.
- 작업 경로: `/Users/andreahn/.codex/worktrees/corporate-sales-release-prep/globos_pos_system`.
- 기존 작업 폴더의 사용자 변경은 보존하고, 이번 계좌·매출·계산서·연락처·결제 수정과 필요한 검증만 옮겼다. 최신 main의 구매자 편집·영수증 원장·직접 주문 수정도 보존했다.
- 콜라 10%, 환타 8% 유지. 음료 마스터·세율 계산기 변경 없음.

## 적용물과 사전 검증

운영 이력에 `20261011140000`이 다른 배포로 이미 등록돼 있어 후보의 구성 파일 번호를 `20261011200000` / `201000` / `202000` / `203000`으로 변경했다. 이 구성 파일은 원본 정의이며 **운영에는 개별 적용하지 않는다.**

실제 운영 적용 후보는 `scripts/releases/20261011204000_corporate_sales_invoice_contacts_release.sql` 하나다. 네 구성 파일을 계좌 → 품목 원장 → 요약/페이지 → 연락처/추가 결제 순서로 하나의 트랜잭션에 넣는다. SQL 적용 실패 시 전부 롤백된다. 잠금 대기 제한은 3초, SQL 명령 제한은 120초다. 끝에서 결제 의미와 익명 권한 차단을 검증하고 커밋한다. 운영 이력에는 패키지 버전 `20261011204000` 하나만 기록한다.

`python3 scripts/build_pos_corporate_sales_release.py --check`가 구성 SHA-256과 생성 파일 일치를 확인한다. 파일 해시는 `scripts/releases/corporate_sales_release_manifest.json`에 보관한다.

운영 프로젝트 `ynriuoomotxuwhuxxmhj`에서 실제 선행 함수의 anchor, 새 스키마 미적용, AKJ 법인 1개를 **READ ONLY 트랜잭션**으로 확인해 `CORPORATE_RELEASE_PREFLIGHT=PASS`를 받았다. 고객 데이터나 자격 증명을 출력하지 않았다. 미래 배포 시 동일 검사를 다시 실행해야 한다. 이 결과는 SQL을 적용한 증거가 아니다.

## 필수 CI

GitHub main 보호 규칙은 `POS release contract`, strict=true다. `.github/workflows/pos_release_contract.yml`은 PR 후보의 정확한 SHA에서 `bash scripts/check_repo.sh`를 실행한다. 검증에는 전체 Flutter 분석·테스트·Web 빌드, 기존 SQL/Edge/배포 게이트 회귀와 아래 신규 계약을 포함한다.

- 구성 SQL과 원자적 패키지 각각의 실제 적용 시험.
- 마지막 단계 강제 실패 후 전체 스키마와 선행 함수가 복원되는 롤백 시험.
- 일반 연락처 4조건, 단독/혼합 결제, 미발행 재검증과 발행·claim 원본 보호.
- 9품목/10개, 406,000 공급가액·33,560 VAT·439,560 VND 총액·CK·콜라 10%·환타 8%.
- Photo 수동 등록·서비스 단위, 실제 현금 부분만 다음날 입금액에 합산, tenant 권한과 100건 페이지 계약.

기존 고정 해시 테스트는 이번 계좌 코드와 새 번역 키만 갱신하고 나머지 고정 파일을 보존한다. 변경된 내보내기 테스트는 품목별 금액 보존, 불일치 원장 차단, 별도 POS Ledger를 확인한다. 모든 기존 테스트와 CI 게이트를 유지한다.

필수 CI의 최종 성공 여부와 후보 SHA는 PR checks가 기준이다. **PR CI 성공만으로 운영 배포 게이트를 통과했다고 선언하지 않는다.** 미래 배포는 병합 후 freshly fetched origin/main과 같은 깨끗한 HEAD, 그 main SHA의 성공한 필수 CI를 다시 요구한다.

`vercel.json`의 `git.deploymentEnabled=false`로 후보 push/PR의 Git 자동 배포를 차단했다. 공식 CLI 배포 경로는 보존한다. GitHub workflow들은 검증/빌드만 수행하며 Web/DB 배포 작업이 없다. [Vercel 공식 Git 설정 문서](https://vercel.com/docs/project-configuration/git-configuration)

## 자동화 호환 준비

자동화는 기존 소스 위치에서만 수정·검증했다. 설치 앱과 예약 실행은 갱신하지 않는다. 해당 소스 8개 파일 해시를 같은 manifest에 기록했다. POS와 자동화는 공통 `pos-payment-v3` 기대값과 실제 Dart 생성 엑셀 91개를 대조한다. 자동화 전체 513개 시험이 통과한 이전 증거는 연락처 보완 보고서에 있고, 이 후보에서 생성한 엑셀로도 호환성을 확인한다.

실제 MISA 가져오기/미리보기 수용, 회계 담당자의 메뉴 명칭·단위 승인, 운영 화면/계좌/입금액 확인은 미래 운영 검증 사항이다. 현재 기록을 실연동 완료나 실제 발송 완료로 해석하지 않는다.

## 미래 배포 순서 — 이번에는 실행 금지

1. 별도 운영 배포 허가를 받은 뒤 검토·main 병합과 해당 main SHA의 필수 CI 성공을 확인한다.
2. 깨끗한 exact-main 작업 폴더에서 공식 배포 스크립트의 인증·환경·Supabase 대상·MISA/직접 주문 비밀정보·기존 게이트를 통과한다. 검사를 생략하지 않는다.
3. 공식 명령은 `bash scripts/deploy_pos_production.sh --migration scripts/releases/20261011204000_corporate_sales_invoice_contacts_release.sql --yes`다. 이 명령은 이번 준비에서 실행하지 않았다. 기존 스크립트 순서에 따라 호환 Edge 배포 후 사전검사/원자적 DB 적용, Web 배포, 로그인 검증을 수행한다.
4. 성공 후 정확한 SHA·SQL 패키지 해시·운영 이력 번호·배포 URL·검증 결과를 기록한다. 운영 MISA 조회·가져오기 검증과 실제 발행/발송은 각 허가 범위에 맞춰 분리한다.
5. 미발행 원본은 거래일에 맞는 승인 명칭·단위를 준비한 후 명시적으로 재검증한다. 기발행/claim 원본은 보존한다.

DB 커밋 전 실패는 전체 트랜잭션 롤백으로 처리한다. 커밋 뒤 Web 문제는 공식 게이트를 통한 수정 배포를 우선하며, 데이터·발행 이력을 지우거나 기존 법인 수금 계좌를 되돌리는 자동 역마이그레이션은 제공하지 않는다. 이전 Web artifact 보존만으로 새 DB를 되돌릴 수 있다고 판단하지 않는다.
