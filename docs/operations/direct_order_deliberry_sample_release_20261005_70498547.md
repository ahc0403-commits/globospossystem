# 배달 개선·Deliberry 종료·SAMPLE 신고 제외 운영 배포

2026-10-05 · 운영 URL: https://globospossystem.vercel.app

배포 커밋은 `704985470de68e4cfec10b9f6a435d702d87e612`다. [PR #538](https://github.com/ahc0403-commits/globospossystem/pull/538), [PR #539](https://github.com/ahc0403-commits/globospossystem/pull/539)를 병합하고 새 managed worktree에서 배포했다. 원래 작업 폴더의 HEAD·branch와 기존 변경/미추적 347개 파일은 배포 종료까지 모두 그대로 보존했다. 후속 문서 갱신만 원래 폴더에 기록했다.

## 적용 상태

| 대상 | 소스 구현 | 운영 DB | 운영 Edge/웹 | 운영 확인 |
|---|---|---|---|---|
| 인원수·기존 주문 접근·Grab/BE/기타·고객 동의 포장·배달비 환불 기록 | 완료 | 20261005070000 적용 | 완료 | 기존 조회·페이지 복구·입력 검증·권한·화면 확인 |
| 주방 목록 N+1 수정 | 완료 | 20261005080000 적용 | 완료 | set-based 함수·상한·실제 목록 확인 |
| Deliberry 종료 | 완료 | 20261005050000 적용 | 네 endpoint·메뉴 종료 배포 | 410·쓰기/RPC guard·cron 종료·이력 확인 |
| SAMPLE 매출 신고 제외 | 완료 | 20261005060000 적용 | 완료 | 실법인·원결제 보존, 신고 결과 제외 확인 |

고객 동의·배달비 환불·동시성·원결제/재고·방문포장 KDS 호환은 격리 SQL/Flutter에서 검증했다. 실제 기사 호출, 고객 대상 포장 전환, 은행 이체, 물리 프린터 출력은 운영 검증에서 실행하지 않았다.

## 릴리스 근거

- 새 배포 폴더: `/Users/andreahn/.codex/worktrees/delivery-final-production-20261005/globos_pos_system`.
- 각 공식 배포에서 clean worktree 및 freshly fetched `HEAD == origin/main` 확인. production gate 우회 없음.
- [정확한 main SHA의 필수 CI](https://github.com/ahc0403-commits/globospossystem/actions/runs/37339501762) 성공: 전체 Flutter 1,729 통과·94 조건부 제외, 38개 저장소 검증 단계, 웹 release build. PR CI와 main Windows 출력 프로그램 빌드도 성공.
- `scripts/deploy_pos_production.sh`로 500/600/700 DB-only 적용 후 800과 Edge·Vercel 배포. 각 migration은 검증과 remote history 등록까지 완료.
- 운영 Auth/설정·관련 회귀·Edge origin·dispatcher 인증 gate 확인. 첫 실행의 단일 HTTP 연결 지연은 종료하고 전체 공식 검증을 재실행해 성공했다. 이미 적용한 migration을 재적용하지 않았다.
- Vercel deployment `dpl_J7wvuo6iVbzVaVc6J7UG3HYBXez9`, production `READY`. 라이브 HTTP 200 및 `main.dart.js` SHA-256이 exact-main prebuilt artifact와 일치.

## 운영 검증

- 기존 주문 10건의 `status_v3`, 기존 세션 storefront 복구, 직원 상세 조회 통과. 그중 기본 방문포장 5건의 방법을 보존. 주방 실제 목록 4건, 조회 상한 200·권한·per-row context helper 미호출 확인. 세션 조회의 last_seen 변경은 transaction rollback.
- 기존 요청 32·견적 32·금융 연결 7·기사 배정 4·주방 티켓 13·결제 7의 기존 데이터 hash가 배포 전후 동일. 새 additive 컬럼만 비교에서 제외.
- 실제 기존 로그인 세션을 reload해 POS·배달포장 데스크 9개 주문·기존 상세를 확인. 새 식사 인원 수정/방문포장 제안 항목이 표시됨. 확인 중 주문·결제·환불을 생성하거나 변경하지 않음.
- 신규 고객 페이지에 “현재 주문이 많아 배달이 지연되고 있습니다. 잠시 후 다시 주문해 주세요.” 확인. 운영 접수 설정은 변경하지 않음.
- Deliberry 네 endpoint의 GET/POST/OPTIONS 12회 모두 HTTP 410, 정확한 종료 오류 및 no-store. 다섯 이력 표·보호 trigger·권한 회수 검증. 관련 cron 1→0, 다른 cron 9개의 hash 동일.
- `process_payment` 및 MISA/meInvoice 함수 정의 hash가 모두 동일.
- 2026-10-05 신고 법인 2→1: 실매장 37건/10,582,512.16 VND와 법인 데이터 hash 동일. 2026-10-04의 실매장 60건/14,680,011.23 VND도 동일. SAMPLE 원결제 1건/189,000 VND 및 hash를 보존. 기존 단일 법인 RPC도 정상 신고 결과 반환.
- 새 배달 Edge action의 인원 입력 검증·존재하지 않는 세션 접근 거절·오류 비노출·운영 CORS 5건 통과. BE/기타 HTTPS 링크의 DB 검증 통과.

## 확인 범위와 후속

- 기존 Auth 계정 준비 상태와 기존 로그인 세션은 확인했다. 보안 환경에 기존 계정의 로그인 smoke 자격증명이 없어 공식 `--skip-login-smoke`를 사용했다. **새 로그인 검증은 미실행이며 login-ready로 판정하지 않는다.** 계정 생성·비밀번호 변경은 하지 않았다.
- 실제 기사 배정·고객 동의·은행 이체·프린터 현장 확인은 후속 업무 시나리오다.
- 전체 N+1 계획은 주방 수정과 W07 Deliberry 종료만 이번 릴리스에서 완료했다. 남은 KDS delta·QR·직원/고객 목록·MISA 등 W01–W06/W08–W11 구현을 완료했다고 판정하지 않는다.

증거: [릴리스 index](evidence/direct_order_deliberry_sample_20261005_70498547/release-evidence-index.json), [운영 이력 비교](evidence/direct_order_deliberry_sample_20261005_70498547/operational-data-preservation.json), [화면 확인](evidence/direct_order_deliberry_sample_20261005_70498547/operational-ui-verification.json), [공식 배포 단계](evidence/direct_order_deliberry_sample_20261005_70498547/official-release-stage-summary.log). 자격증명과 고객 상세 payload는 증거 폴더에 포함하지 않았다.
