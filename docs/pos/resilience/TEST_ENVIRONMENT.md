# 잔여 작업 시험 환경과 현재 DB 계약

G0 시험 계정 준비와 G1 현재 계약 수집 절차이다. 이 문서/도구의 적용을
신규 설치·업그레이드 복원, 두 DB 최초 법인 연결 또는 장시간 시험 완료로 보지 않는다.

## 샘플 계정

운영 DB의 실제 연결을 확인한 샘플 매장은 `BunsikClub SAMPLE`이다.
POS 계정은 `bunsik_sm2`(매장 관리자), `sp_pos`(캐셔), `sp_customer`(고객 화면),
`sp_kit`(주방), `sp_tray`(트레이), `sp_1f`(층), `sp_order`·`sp_pr1`(재고 주문)이다.
Office는 `sp_purchase1`의 샘플 매장 범위 구매·품질 권한을 별도로 확인한다.
이름만으로 계정을 만들거나 다른 매장의 동일 역할과 혼동하지 않는다.
요청된 `sp_sm`과 `sp_printer`는 현재 Auth/프로필 조회에서 발견되지 않았다.
인쇄 동작 시험과 별도 로그인 계정의 존재는 다른 조건이다.

ID·이메일·매장 매핑은 Git 밖 private metadata JSON에, 비밀번호와 public client
설정은 같은 private 디렉터리의 env 파일에 저장한다. 디렉터리 0700, 파일 0600을
사용한다. 비밀번호·토큰·응답 본문을 문서/스크린샷/로그에 복사하지 않는다.
설정 파일은 셸로 실행하지 않고 assignment로만 파싱한다.

```bash
python3 -B scripts/resilience/sample_accounts.py \
  --env-file /private/path/pos-sample-validation.env \
  --output /evidence/path/sample-identities.json
```

실행 전에 모든 대상/설정/외부 메타데이터를 확인한다. 미리 확인한 9개 principal에
대해서만 순차 실행하며 비밀번호 로그인은 각 1회, 재시도 0회이다. 계정별 로그인,
인증된 자기 프로필 최대 2행 조회(중복 검출), 현재 시험 세션 local 로그아웃을 한다.
HTTP 한 번의 timeout은 12초, 응답 상한은 128KiB다. 리다이렉트는 거절한다.
타 단말의 세션을 취소하는 global 로그아웃은 사용하지 않는다. 정리 결과가 불명이면
추가 로그인도 중단하고 FAIL로 남긴다. 비밀번호 변경·계정 생성·권한 변경은 없다.

이 PASS는 로그인과 자기 프로필의 ID·역할·매장·활성/credential gate 일치만 뜻한다.
구매 승인/품질 작성 등 실제 권한 행동, 샘플 외부 발행/알림 차단,
다른 매장 접근 거절, 실기기 배정 및 12시간 부하는 별도 검증이다.
기존 운영 계정 로그인 스모크 생략은 유지한다.

## 현재 유효 DB 계약

`scripts/resilience/runtime_contracts.sql`을 승인된 Supabase HTTPS SQL 연결로 POS와
Office에 각 한 번 실행한다. transport의 요청/statement deadline을 사용하며
같은 요청을 반복하는 폴링으로 만들지 않는다. 단일 SQL statement의 MVCC snapshot으로
모든 비시스템 schema의 카탈로그와 적용 migration 이력을 수집한다.

함수 signature/result/security/search_path/owner/ACL과 정의 해시, 테이블·뷰·컬럼,
제약·인덱스·트리거·RLS 정책·default ACL·extension·enum·sequence·publication,
적용 migration 원문 해시를 확인한다. 컬럼은 관계별 사전 집계하고 business row를
JOIN하지 않는다. 애플리케이션 항목별 HTTP 호출이나 SQL 쿼리 반복은 없다.
본문·조건식·기본값·migration SQL은 해시로만 내보낸다. Auth 사용자·비밀번호,
vault 값, cron 명령과 업무 데이터는 조회하지 않는다.

최대 20,000개 object/6MiB를 허용한다. 초과하면 partial 결과를 증거로 승인하지
않고 범위/일관성을 명시한 별도 분할 수집을 설계한다. 이 상한은 운영 데이터 전체를
한 응답에 넣으라는 뜻이 아니다. 카탈로그는 영업 데이터와 독립된 유한 metadata이다.

한 행의 `snapshot` JSON을 evidence 경로에 저장한 다음 다음처럼 원본/쿼리/recorder
해시와 소스 SHA를 연결한다. project 라벨은 실행자가 지정하므로 독립 서명 증거가
아니다. 실제 연결 대상과 SQL 실행 기록을 함께 보관한다.

```bash
python3 -B scripts/resilience/runtime_catalog.py record --project pos \
  --input /evidence/path/pos.raw.json --output /evidence/path/pos.catalog.json
python3 -B scripts/resilience/runtime_catalog.py record --project office \
  --input /evidence/path/office.raw.json --output /evidence/path/office.catalog.json
python3 -B scripts/resilience/runtime_catalog.py compare \
  --before /evidence/path/before.catalog.json --after /evidence/path/after.catalog.json
```

검사기는 object별 내용 해시·중복/누락/상한·예상 필드를 확인한다. 서로 다른 DB,
Postgres 버전 또는 search_path의 비교는 거절한다. 시간/목록 순서 차이는 계약
변경으로 세지 않는다. schema, type, relation 등의 해시 목록은 **복원 가능한 DDL
덤프가 아니다**. 함수 실행 결과/권한의 업무 의미도 자동 증명하지 않는다.
fresh/upgrade 검증은 현재 schema-only DDL과 실제 migration 순서를 확보해 별도로
실행하며, 이 수집 결과의 `freshInstall`/`upgradeInstall`은 `NOT_RUN`으로 남긴다.

## 도구 검증

```bash
python3 -B -m unittest discover -s scripts/resilience/tests -v
POS_CATALOG_TEST_CONTAINER=pos-resilience-catalog-FIXTURE \
  python3 -B scripts/resilience/integration_runtime_catalog.py -v
```

두 번째 명령은 네트워크 없는 별도 PostgreSQL 17 fixture 컨테이너를 명시해야 한다.
`supabase_migrations.schema_migrations(version text,name text,statements text[])`와
한 개 이상의 초기 fixture 이력을 준비한다. 테스트 변경은 transaction rollback한다.
함수 정의/security/GRANT, policy/RLS, trigger disable, index/default 및 migration 원문
변경 검출과 업무 행·민감 본문 미수집을 실제 PostgreSQL에서 검사한다.
합성 fixture 검사를 운영 전체 스키마 복원 PASS로 기록하지 않는다.
