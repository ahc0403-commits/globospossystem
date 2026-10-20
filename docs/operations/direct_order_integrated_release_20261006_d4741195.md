# 직접 주문 통합 개선 운영 배포 — 2026-10-06

운영 DB·Edge·웹을 main `d47411953e707243490cc2965082ee3fece35a5a`로 반영했다. 같은 SHA의 Windows Print Station ZIP을 제공한다. **현장 Windows 설치·실제 종이 출력과 신규 로그인 smoke는 아직 확인하지 않았다.**

## 반영 기능

- 고객 메뉴 상단 고정 카테고리, 전체/카테고리 필터, 가로 이동. 기존 배달/포장 선택을 유지한다.
- 계좌이체 안내와 입금 캡처 보내기를 분리한다. 같은 사진 재시도·접수 확인과 Storage 일시 오류 복구를 지원한다.
- 배달·방문포장의 고객 영수증, 주방·층·트레이·확인·인계 전표, 네이티브 재출력, 디지털/PDF에서 인원 N명·일회용품 N세트를 전달·표시한다. 주문당 세트 수를 메뉴 수량/출력 부수로 곱하지 않는다. 일반 홀 주문에는 이 포장 영역을 표시하지 않는다.
- 과거 print payload/snapshot을 변경하지 않는다. 인원 없는 과거 주문은 직원 확인 필요로 표시하고 수량을 임의로 추정하지 않는다.

## 배포 근거

| 상태 | 증거 |
|---|---|
| 새 exact-main 작업 트리 | `/Users/andreahn/.codex/worktrees/direct-order-integrated-release/globos_pos_system`, 최초 main `2991ed405cfcabacdccebc6a1a41bf6742a861a8`, 최종 깨끗한 detached HEAD `d4741195` |
| 병합 | [PR #543](https://github.com/ahc0403-commits/globospossystem/pull/543), PR 필수 검사 성공 후 보호 main에 병합 |
| 정확한 main SHA release gate | [POS Release Contract](https://github.com/ahc0403-commits/globospossystem/actions/runs/37419159279) 성공. 같은 SHA의 Windows/재고/매입 검사도 성공 |
| 로컬 전체 검사 | `scripts/check_repo.sh` 38단계 PASS, Flutter 1,789 PASS / 94 skip / 0 fail, Edge 21 PASS |
| 공식 운영 절차 | `scripts/deploy_pos_production.sh --yes --skip-login-smoke --migration supabase/migrations/20261006020000_direct_order_receipt_packing_context.sql` 및 관련 Flutter 테스트 5개. exit 0 |
| DB 적용 | `20261006020000_direct_order_receipt_packing_context.sql` 적용·검증·원격 migration history 확인. 최초 초안의 `20261006010000`은 main의 매입 migration과 겹쳐 최종 release에서 renumber함 |
| 운영 Auth 준비 상태 | 기존 required 계정 readiness 및 test-data hygiene PASS. 계정/비밀번호를 새로 만들거나 재설정하지 않음 |
| Edge | 공식 스크립트로 반영, 정확한 운영 CORS 및 비인가 dispatcher 차단 확인. 퇴역 Deliberry 4개 endpoint는 HTTP 410 유지 |
| Vercel | `dpl_6MxE9cfnemZnNUDqUJcYteYMi3QS`, production READY, GitHub metadata main/d4741195 확인, 운영 alias HTTP 200 |
| 운영 파일 | live `main.dart.js`와 배포 prebuilt 동일. SHA-256 `42bb2c2c7e4762b6141b5081c771bc230a59f8e06154376d3f6399baa99ecd8c` |

## 운영 검증 범위

- 실제 고객 URL `https://globospossystem.vercel.app/#/order/bunsikclub-binh-thanh`를 새로 불러와 상단 전체/매장 카테고리, 라면 선택 필터, 세로 스크롤 후 고정 바, 기존 배달/포장 선택을 확인했다.
- 운영 `storefront_v2` HTTP 200, 카테고리 14개·메뉴 78개·CORS 정상. 없는 사진 경로의 `proof_commit_v2`가 새 복구 응답 HTTP 409 `PROOF_UPLOAD_INCOMPLETE`를 반환함을 확인했다. 사진 업로드·실제 고객 주문·결제는 생성하지 않았다.
- 운영의 기존 연결 주문 8건에 대해 배포된 helper/trigger로 6개 출력폼 payload, 직원 권한 단건 RPC, 새 디지털 snapshot 보강을 검증했다. 일반 주문과 합산 snapshot 제외도 확인했다. 임시 테이블과 ROLLBACK을 사용해 영구 테스트 행 0건. 8건 중 7건은 과거 인원 NULL이며 그 값을 유지했다.
- 배포 전후 기존 direct 결제 8건·financial 8건·print payload 13건 및 결제/MISA 함수 12개 해시가 동일했다. 기존 direct 디지털 snapshot은 0건이었다. `PaymentService`와 유효 `process_payment` anchor는 변경하지 않았다.
- 캡처 UI의 실패/같은 사진 재시도와 전체 출력 ESC/POS/PDF 표시 자체는 관련 행동 테스트로 검증했다. 이번 운영 확인에서 실제 고객 사진 전송·직원 승인·현장 종이 출력까지 실행하지 않았다.

## Windows Print Station 파일

[새 ZIP](/Users/andreahn/Desktop/GLOBOS_PrintStation_20261006_d4741195/globos_print_station_windows_x64_d4741195.zip) · [업데이트 안내](/Users/andreahn/Desktop/GLOBOS_PrintStation_20261006_d4741195/README_업데이트.md)

[Windows main 빌드](https://github.com/ahc0403-commits/globospossystem/actions/runs/37419159278) artifact `11392681853`. ZIP 44,219,026 bytes, SHA-256 `9960b141f9b5612ba9ae06a156aef9bf422e358d5fb1bcf98e2fad794c8861de`. 압축 CRC, x64 PE 실행 파일, 세 runtime DLL 및 data 폴더를 확인했다.

기존 Print Station을 종료하고 **ZIP 전체를 새 폴더에 압축 해제**한 뒤 `globos_print_station.exe`를 실행한다. 두 버전을 동시에 실행하지 않는다. 기존 프린터 연결을 확인하고 실제 배달/포장 각 3명 주문에서 사용하는 모든 출력폼의 `SO NGUOI: 3`, `DUNG CU: 3 BO`를 확인해야 한다. 현장 설치 SHA와 실제 종이는 미확인이다.

## 남은 현장 확인과 작업 보존

신규 로그인 smoke는 secure fixed-account 자격증명이 없어 공식 옵션으로 생략했다. 이 배포를 신규 로그인 검증 완료로 표시하지 않는다. 실제 캡처 전송/재시도·직원 승인과 Windows 설치/종이 확인은 현장 후속 확인 범위다.

원래 작업 디렉터리는 checkout/reset/stash/clean하지 않았다. release 작업 중 기존 tracked/untracked 2,181개 파일의 해시가 모두 보존됨을 확인했다. 마지막에 이번 기능의 계획·구현 기록 2개만 운영 결과로 갱신하고 별도 release 보고서/증거를 추가했다. 관련 vault 문서도 실제 배포 상태로 갱신했다. 사용자 코드와 무관한 파일은 보존했다.

증거: [색인](evidence/direct_order_integrated_release_20261006_d4741195/evidence-index.json), [공식 배포](evidence/direct_order_integrated_release_20261006_d4741195/official-deploy.log), [검증 요약](evidence/direct_order_integrated_release_20261006_d4741195/official-deploy-summary.json), [운영 데이터 보존](evidence/direct_order_integrated_release_20261006_d4741195/operational-data-preservation.json), [Windows 검증](evidence/direct_order_integrated_release_20261006_d4741195/windows-package-verification.json).

![운영 카테고리 선택](evidence/direct_order_integrated_release_20261006_d4741195/operational-category-filter.jpg)

![스크롤 후 고정 카테고리](evidence/direct_order_integrated_release_20261006_d4741195/operational-category-sticky.jpg)
