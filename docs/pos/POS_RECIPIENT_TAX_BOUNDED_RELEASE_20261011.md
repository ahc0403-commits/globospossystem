# 2026-10-11 통합 운영 배포 계획과 검증

사용자가 승인한 배달비 수령 시 기사 직접 결제·채팅 첨부·영수증,
POS 구매자 정보·영수증 원장, 세금코드 회사명 조회와 프로젝트 지침·W0–W7
데이터 접근 개선을 최신 main에 통합했다. 기존 작업 폴더의 변경은 복사본으로
보존하고, `3207840872550bf573ee50b90f4f014cb2e226c0`의 깨끗한 새 작업 공간에서
범위별 공통 기준과 최종 소스를 3-way 비교했다. 최신 main의 고객 요청사항,
진행 단계, 번역, 영업일, 픽업과 출력 라우팅 계약을 유지했다.

## 통합 시 수정한 호환성

- 기존 status v9 / orders v4 / staff detail v5를 유지하고 신규 기능은
  **status v10 / orders v5 / staff detail v6 / staff list v5**로 분리했다.
  기존 직원 목록의 픽업/배달 필터도 전달한다.
- 신규 배달 주문만 고객이 배달비를 기사에게 직접 지급한다. 픽업은
  `not_applicable`, 확정된 과거 견적은 기존 정책을 유지한다.
  최신 금액 확정 함수에서 픽업의 0원 배달비도 보존한다.
- 조리 완료, 포장 완료, 배차 예약, 실제 인계와 배송 완료를 구분한다.
  기존 금융 이력, 결제 함수와 발행 영수증 snapshot은 수정하지 않는다.
- 운영에 있는 비공개 `direct-order-chat` 저장소를 SQL에도 명시한다.
  기존 객체는 보존하며 JPEG/PNG/WebP/PDF, 파일당 5 MiB 제한을 검증한다.
  결제 증빙과 일반 채팅의 분리는 메시지 종류·메타데이터·RPC에서 유지한다.
- 출력 RPC v3는 현재 v2의 출력 대상·재시도·긴급 보류·요청 메모·식기 계약을
  그대로 유지한다. 구 v1/v2는 새 payer payload를 claim할 수 없다.
  새 인쇄 앱은 DB에 v3가 아직 없을 때만 v2로 요청해 먼저 설치할 수 있다.
  권한·네트워크 오류는 구버전 요청으로 우회하지 않는다.
- 영업일 조회와 재고 페이지 조회를 새 테스트에도 반영했다. 테이블 100회
  동시 갱신의 표/주문 요청은 4회이며 영업일 메타데이터 요청은 별도로
  집계한다. 이전 보고서의 4회는 메타데이터를 제외한 수치다.

## DB 및 외부 발행 보호

운영 사전 읽기 검증에서 결제 3,832건, 주문 요청 56건, 구매자 기록 6건과
기존 API·Auth index/컬럼·고객 알림 trigger를 확인했다.
`process_payment` 정의 MD5는 `be39d85b3e5ba56462745470db5a79db`이다.
MISA dispatch는 꺼져 있으며 sending job과 활성 dispatcher cron이 없다.
이번 배포는 MISA를 활성화하지 않는다.

운영 public/Auth/Storage 스키마만 별도로 백업했다. 실제 고객·결제 데이터는
임시 DB로 복제하지 않았다. 동일 PostgreSQL 17.6.1.104의 임시 DB에 스키마를
복원하고 최소 부모 관계를 넣어 전체 묶음 SQL과 별도 사후 검증을 실행했다.
이 검증은 DDL 호환성과 권한·함수 계약을 확인하며 실데이터 부하 측정과 다르다.

18개 정식 소스 migration으로부터 결정적으로 생성한 운영 전용 파일:
[scripts/releases/20261011140000_pos_recipient_buyer_lookup_bounded_release.sql](../../scripts/releases/20261011140000_pos_recipient_buyer_lookup_bounded_release.sql).
`python3 scripts/build_pos_recipient_release.py --check`가 구성 파일 SHA와
생성 결과를 확인한다. 자동 migration 폴더 밖에 두어 개발 DB에서 구성 SQL을
중복 적용하지 않는다. 기존처럼 `supabase db push`는 사용하지 않는다.

SQL은 한 트랜잭션으로 실행하며 lock timeout 3초, statement timeout 30초다.
결제 함수·direct 금융 행·발행된 digital snapshot을 전후 비교하고 차이가
있으면 전체 적용을 취소한다. 수동 재실행이나 이력 repair로 실패를 숨기지 않는다.
세금코드 조회는 Bunsik Club Binh Thanh만 활성화하며 나머지는 기본 OFF다.

## 배포 순서

1. PR과 정확한 main SHA의 필수 GitHub Actions 검사 및 Windows 인쇄 앱 빌드를
   확인한다. 공유 작업 폴더를 reset/stash하지 않는다.
2. 운영 계정 자격 증명을 보안 환경 파일에 설정한다. 비밀번호를 로그·문서나
   채팅에 남기지 않는다. Auth readiness와 실제 로그인은 별도로 검증한다.
3. 새 Windows 인쇄 앱을 매장에 먼저 설치한다. DB 배포 전에는 v2로 기존 출력이
   유지되는지 확인한다. 교체 전인 에이전트는 배포 후 새 배달 영수증을 처리하지
   못하므로 설치와 현장 출력 확인이 운영 완료 조건이다.
4. 깨끗한 exact-main 작업 공간에서 공식 스크립트의 DB-only 모드로 묶음 SQL을
   적용한다. 사전 조건·원자적 적용·사후 검증·remote migration 이력을 확인한다.
5. 공식 스크립트 `--skip-db`로 Edge/Web를 배포한다. DB가 먼저 적용되어 새
   batch RPC를 사용하는 dispatcher가 이전 DB를 호출하지 않게 한다.
   MISA는 비활성 상태로 새 owned-batch handler만 배포한다.
6. 운영 URL·실제 계정 로그인·접근 범위·세금코드 조회·실제 영수증 읽기·첨부
   권한·retired endpoint를 검증한다. 실제 고객 메시지/결제/외부 발행을
   테스트 데이터로 만들지 않는다. 물리 프린터 결과는 현장에서 확인한다.

```sh
ENV_FILE=/Users/andreahn/.config/globos/pos-production.env \
TEST_TARGETS=all \
scripts/deploy_pos_production.sh --yes --db-only \
  --migration scripts/releases/20261011140000_pos_recipient_buyer_lookup_bounded_release.sql

ENV_FILE=/Users/andreahn/.config/globos/pos-production.env \
TEST_TARGETS=all \
scripts/deploy_pos_production.sh --yes --mode prebuilt --skip-db
```

기존 [배포 runbook](POS_PRODUCTION_DEPLOYMENT_RUNBOOK.md)의 clean Git,
새로 fetch한 exact-main SHA, 그 SHA의 필수 CI, 고정 운영 대상과 로그인 검증
조건을 모두 따른다. 생략 옵션으로 우회하지 않는다.

## 검증 상태 구분

기능·동시성 SQL, 운영 스키마 리허설과 운영 사전 읽기는 통과했다.
이 문서는 운영 배포 성공을 주장하지 않는다. 전체 저장소 최종 검사,
정확한 main CI·Windows 빌드, 운영 적용, 웹·로그인·현장 출력은 각각의
실행 결과로 별도로 기록한다. 원래 각 구현 보고서는 이전 날짜의 소스 검증
기록이며 이번 통합 검사의 통과 여부를 대신하지 않는다.

문제가 생기면 기능·dispatcher를 중지하고 직전 Web/Edge 버전을 복구한다.
신규 금융·첨부·구매자 기록을 삭제하거나 발행/결제 이력을 되돌리지 않는다.
읽기 함수는 백업된 실제 운영 predecessor로 복원하는 별도 검토 SQL을 사용한다.
MISA 결과 불명 작업은 포털 확인 대상으로 보존하며 자동 재발행하지 않는다.
