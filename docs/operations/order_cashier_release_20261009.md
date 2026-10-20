# 주문·캐셔 기능 운영 배포 기록

2026-10-09 · Asia/Ho_Chi_Minh

운영 DB, Edge 및 웹 반영을 완료했다. 원래 작업 사본의 기존 파일 2,286개와 Git 변경 상태를 보존했다. 배포 사본은 새 origin/main에서 생성했고, 병합 후 `91e4c9175a67624d1dd12db16304a52d1f53ffcb`와 freshly fetched origin/main이 일치하는 깨끗한 detached worktree로 배포했다. 검증한 기능 파일 45개의 해시가 병합된 main에서도 모두 동일했다.

- [병합 PR #552](https://github.com/ahc0403-commits/globospossystem/pull/552)
- [PR 필수 CI 성공](https://github.com/ahc0403-commits/globospossystem/actions/runs/37902105036)
- [정확한 main SHA 필수 CI 성공](https://github.com/ahc0403-commits/globospossystem/actions/runs/37903717541)
- [운영 POS](https://globospossystem.vercel.app)

## 적용 범위

주문별 임시 링크로 브라우저 종료·캐시 삭제 이후 진행 중 주문과 채팅을 복원한다. 완료와 필요한 환불 정산이 끝나면 링크를 무효화하고 다음 접속 때 해당 주문의 임시 캐시를 정리하며 저장한 배송지는 유지한다.

최종금액과 QR을 발행할 때 견적을 확정한다. 같은 조건의 재안내는 견적 ID를 유지하며 증빙 접수를 표시 TTL만으로 거절하지 않는다. 금액 입력의 커서·선택 범위를 유지한다. 배송비 변경은 업체·거래 참조·주문 첨부 증빙을 요구하고 서버가 차액과 환불 의무를 계산한다. 캐셔의 임의 음식 금액 변경은 차단한다.

캐셔가 메뉴와 선택 수량을 다른 테이블로 이동하고 일부 수량을 취소할 수 있다. 조리·트레이·제공 이력, 가격·VAT·옵션, 취소 원장과 실제 재고 소비량을 보존한다.

## 배포 및 운영 검증

공식 `scripts/deploy_pos_production.sh`의 DB-only 경로로 아래 migration을 순서대로 적용했다. 세 migration 모두 운영 선행 함수 정의 검사, 원자적 적용, 읽기 전용 검증, migration history 확인을 통과했다.

1. `20261009150000_direct_order_final_amount_and_access.sql`
2. `20261009151000_direct_order_verified_delivery_cost.sql`
3. `20261009152000_cashier_item_move_and_partial_cancel.sql`

기존 v3·v5 API 정의를 유지하고 새 v6에 확정 금액 정보를 추가했다. v5·v6의 세션 활동 갱신을 위한 VOLATILE 계약, 접근 키·실비·캐셔 원장 RLS와 권한, 종료·금액 보호 trigger를 확인했다. 활성·잠금 견적에서 확정 시각 누락은 0건이다. `process_payment` 외부 정의와 내부 함수의 금융 계산 부분 해시가 그대로이며, 2026-10-09 이전 정산 기록 20건의 금액 해시도 동일했다.

DB 적용 후 공식 `--yes --skip-smoke-tests` 경로로 Edge와 웹을 배포했다. 배포 사본에 복사한 origin 설정이 여러 주소를 포함해 첫 웹 배포 사전 검사가 중단됐으며, 별도 worktree의 무시된 설정 파일만 운영 주소 하나로 수정하고 다시 실행해 성공했다. 원래 작업 사본의 설정은 수정하지 않았다.

- Edge 필수 12개가 ACTIVE이며 원격 ALLOWED_ORIGINS digest가 운영 주소와 일치한다.
- `direct-order-public`은 버전 28 → 29로 배포됐다. 운영에서 내려받은 소스가 검증한 main 소스와 정확히 일치한다.
- Vercel 배포 `dpl_6nzxroumw5szJGFs25jGfCoDr6pe`가 production/READY이고 운영 주소가 같은 배포를 가리킨다. 메타데이터의 githubCommitSha가 `91e4c9175a67624d1dd12db16304a52d1f53ffcb`이다.
- 배포 직후 읽기 전용 로그에서 관찰한 direct_order/cashier RPC 44건은 HTTP 5xx가 0건이다. 이 수집 창에는 새 주문 Edge의 호출 로그가 포함되지 않아 별도 고객 시나리오 성공으로 해석하지 않는다.

스모크 테스트, HTTP·OPTIONS·로그인 probe, 테스트 주문·이체·환불 생성은 실행하지 않았다. 운영 계정 준비 여부는 기존 읽기 전용 사전 검사로 확인했다. 실제 모바일 키보드·창 종료, 캐셔 조작, Windows 출력 및 은행 이체 시나리오를 운영에서 수행한 결과는 이 기록에 포함하지 않는다.

## 로컬 검증과 보존

깨끗한 worktree의 `bash scripts/check_repo.sh` 41개 단계가 성공했다. Flutter 1,888개 통과/94개 기존 skip, Edge 24개, 임시 PostgreSQL의 주문·정산·메뉴 이동·반복 취소·실행 취소·동시 결제 충돌 검사, 정적 검사, 배포 gate 검사와 웹 release build를 통과했다. 필수 GitHub Actions도 PR과 정확한 main SHA 각각 성공했다.

배포 후 fresh fetch 기준 HEAD == origin/main이고 worktree의 Git 상태가 깨끗하다. 원래 작업 사본은 배포 전후 기존 2,286개 파일의 해시 및 Git 변경 상태가 동일했다. 이후 이 보고서와 아래 증거 폴더만 원래 작업 사본에 새로 추가했다.

[배포 요약 및 증거](evidence/order_cashier_release_20261009/release-final-summary.json) · [운영 DB 검증](evidence/order_cashier_release_20261009/database-operational-verification.json) · [배포 소스 검증](evidence/order_cashier_release_20261009/deployed-edge-source-verification.json) · [Vercel 운영 배포](evidence/order_cashier_release_20261009/vercel-after-safe.json) · [기존 작업 보존](evidence/order_cashier_release_20261009/preservation-after-production.json)
