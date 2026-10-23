# 전가복 KDS 조회·알림 개선 검증

2026-10-23 베트남 시간. 운영 DB와 웹 적용을 완료했다. 소스·부하 검증·운영 적용·현장 실측은 구분하며, 현장 frame/가청 시간은 미측정이다.

전가복의 active revision/Broadcast를 유지하면서 일반 invalidation을 제어 이벤트 경계 안에서 중복 제거한다. 고유 주문 100개는 delta 1회와 ticket batch 2회로 읽는다. 클라이언트 배치 50개, 서버 입력 상한 100개(중복 제거 전), 이력 페이지 50개/서버 100개이며 단말의 foreground·복구·완료 후 조회·이력이 하나의 읽기 lane을 공유한다. SQL은 요청한 큐/주문을 먼저 제한하고 품목·이벤트·ready lot·포장 관계를 각각 집계한다. 단건 RPC 반복이나 배치 실패 후 단건 fan-out은 없다.

새 RPC는 인증된 활성 POS 사용자와 배정을 확인하고 전가복·현재 베트남 날짜·활성 세션·담당 저장 층/영역으로 제한한다. 배달/픽업은 층 응답에서 제외한다. 요청한 각 ID는 카드 또는 명시적 null로 반환하며 응답의 배정도 검증한다. 세션/층/사용자/날짜 변경 전 응답과 오래된 revision은 적용하지 않는다. 모든 배치가 성공한 후에만 scanned cursor를 저장한다. 실패한 페이지는 기존 cursor에서 복구하고 50페이지 상한을 유지한다.

필수 bootstrap에서 완료 이력을 분리했고 타이머는 카드와 함께 반환한다. 완료내역은 탭 진입/페이지 이동에만 커서로 조회한다. 전가복의 시각 알림은 상태 적용 시 실행하고 음성 묶음은 최초 이벤트 기준 500ms에 실행한다. 연속 이벤트가 시간을 연장하지 않는다. 실제 스피커 재생 대기열이나 브라우저 음성 준비 시간은 이 500ms에 포함한 실측이 아니다. revision/config watchdog은 5초±0.5초다. 정상 REST 응답 시간을 더해야 복구 시간이 된다.

일시적 네트워크/DB 연결·pool 오류만 읽기 coordinator에서 최대 3번 시도한다. 15초가 지나면 추가 시도를 시작하지 않는다. 진행 중 HTTP를 시간 초과로 방치한 채 다음 요청을 중복 시작하지 않으므로, 응답이 멈춘 네트워크에 대한 15초 완료 보증은 아니다. 권한/입력 오류와 영구 오류는 재시도하지 않는다. 확정 쓰기의 후속 읽기 실패는 해당 쓰기를 outbox에 다시 넣지 않는다.

전가복에 checker/tray를 만들지 않았다. 주방 탭의 조리 시작, 명시적인 부분 층 전달, 수량/원복/멱등성, 저장 2F/3F 매핑, 직접 음료·콤보·포장·불변 S/L·식사 선택을 유지한다. 새 capability는 전가복의 kitchen/floor active 배정에만 반환한다. 다른 매장은 기존 RPC와 기본 30초 watchdog/2초 음성 묶음을 유지한다. DB를 먼저 배포한 후 새 웹을 배포하며, 캐시된 구버전은 기존 RPC를 계속 사용한다.

## 데이터와 부하 조건

운영 읽기 집계는 큐 80개, 당일 15개, 최근 7일 하루 최대 38개였다. 비어 있지 않은 79개 주문의 품목 평균 4.09, p95 9, 최대 22개다. 합성 fixture는 80개 주문의 0/1/2/3/4/5/6/7/8/9/22개 분포를 1/17/12/12/10/3/11/4/6/3/1로 복제했다. 이름·가격·계정은 합성값이며 운영 행을 복사하지 않았다.

PostgreSQL 17.6의 실제 운영 schema-only export와 PostgREST 14.5를 사용했다. DB 2CPU/2GiB, REST 1CPU/512MiB/pool 10에서 주방·저장 2F·저장 3F의 두 계정을 4/8/40단말로 반복했다. 실제 동시 접속 대수 확인은 아니며, 정상 5초 주기보다 빠르게 bootstrap·delta·두 batch·이력을 연속 요청하는 집중 부하다.

| 전체 큐 / 당일 | 단말 | batch p95 | bootstrap p95 | 이력 p95 |
|---|---:|---:|---:|---:|
| 80 / 15 | 4 | 19ms | 25ms | 43ms |
| 80 / 15 | 8 | 63ms | 60ms | 69ms |
| 80 / 15 | 40 | 321ms | 404ms | 436ms |
| 5,000 / 38 | 4 | 15ms | 26ms | 58ms |
| 5,000 / 38 | 8 | 93ms | 103ms | 110ms |
| 5,000 / 38 | 40 | 520ms | 504ms | 606ms |
| 50,000 / 38 | 4 | 24ms | 54ms | 50ms |
| 50,000 / 38 | 8 | 77ms | 75ms | 111ms |
| 50,000 / 38 | 40 | 597ms | 583ms | 685ms |
| 50,000 / 120 | 4 | 36ms | 67ms | 78ms |
| 50,000 / 120 | 8 | 114ms | 218ms | 197ms |
| 50,000 / 120 | 40 | 912ms | 1,100ms | 1,092ms |

측정한 HTTP 3,744건은 오류 0건이고 단말별 동시 읽기 최대 1개였다. 50건 batch 응답 최대 309,957 bytes로 1MiB 이하여서 50개 상한을 유지한다. bootstrap 최대 704,398 bytes, 이력 최대 329,027 bytes다. 83개 nested 실제 실행 계획에서 단일 관계 접근의 최대 검사 행은 이벤트 1,047개, 큐 120개, 품목/주문품목 366개였다. 5만 큐 전체를 반복 스캔하지 않았다. 이 숫자는 모든 쿼리의 합산 행 수가 아니라 관계 접근별 최대다. 메모리 표본 최고치는 DB 987.8MiB와 REST 129MiB이며 DB cache를 포함한다. Flutter heap은 측정하지 않았다.

HTTP delta fixture는 빈 로그의 복구 응답을 시험했다. 100개 변경·중복 ID·두 batch·제어 이벤트 경계·부분 실패/cursor 보존은 실제 client handler에 mock HTTP를 연결한 Flutter 테스트로 따로 검증했다. 이를 실제 100개 방송 전달의 end-to-end 측정으로 간주하지 않는다.

## 검증과 재현

- `test/jeongabok_kds_bounded_sync_test.dart`: 필수 이력 분리, 공유 읽기 lane, 100개 변경/중복, 제어 경계, 부분 실패, tombstone 누락, stale revision, 응답 중 재배정/확정 수량 변경, 3회 재시도와 영구 오류.
- `test/kds_realtime_sync_test.dart`: batch 처리 실패 시 cursor 보존과 전체 성공 후 저장, 기존 delta 순서·범위·복구 계약.
- `test/emergency_fulfillment_responsive_test.dart`: 즉시 시각 알림과 최초 500ms window, 기존 화면/부분 전달/음료/콤보 계약. 관련 Flutter 테스트 총 98개 통과.
- `scripts/test_jeongabok_kds_bounded_sync.sh`: SQL 범위·권한·현재 단건 카드와 동등성(전체 schema 실행), 불변 메뉴 선택·부분 수량·ready sequence·취소·픽업/배달·직접 음료·종료 세션, rollback/reapply.
- `scripts/measure_jeongabok_kds_sync.sh <schema-only.sql> <output-dir>`: 전체 운영 schema에서 위 부하와 nested 실행 계획·응답 크기·메모리 재현.
- 전체 저장소 검사와 exact-main 필수 GitHub Actions 성공 후 `scripts/deploy_pos_production.sh`의 DB-only 단일 migration과 web-only를 순차 실행한다.

원본 수치는 [측정 디렉터리](../measurements/jeongabok-kds-20261023/)에 보존했다. 버튼→상대 단말 frame p95 1.5초, 데이터→시각 p95 100ms, 실제 첫 가청 시간·물리 단말 현재 접속 수는 계측하지 않았다. 집중 부하 40대의 위 수치를 이 목표의 달성 증거로 사용하지 않는다.

## 운영 적용 증거

- PR [#623](https://github.com/ahc0403-commits/globospossystem/pull/623)을 병합한 정확한 main은 `943f2640297d87b7b1579ef119905a5ed6466855`다.
- 최종 소스 `1863cd21`의 [PR CI](https://github.com/ahc0403-commits/globospossystem/actions/runs/39922278570)와 병합 main의 [배포 CI](https://github.com/ahc0403-commits/globospossystem/actions/runs/39925274906)가 모두 성공했다. 로컬 전체 검사도 최종 소스에서 exit 0이다(Flutter 2,544 passed/98 skipped, 관련 98 passed, 별도 Chrome 단말 인증 3 passed).
- 공식 `scripts/deploy_pos_production.sh`의 DB-only dry-run → 실제 단일 migration `20261023080000` 적용 → 이력 presence 확인을 순차 실행했다. 운영 읽기 확인 시각은 15:57:35다.
- 같은 공식 스크립트의 web-only dry-run → 실제 배포를 실행했다. skip 옵션 없이 운영 Auth/test-data hygiene, 정적 분석·관련 테스트, Vercel build/deploy, 운영 URL HTTP 200, 기존 승인 캐셔 계정 로그인·프로필 조회가 통과했다. 해당 로그인 smoke는 전가복 비밀번호를 사용한 검사가 아니다.
- Vercel production `dpl_A48yV8fV1yLzBxr3Pqiz6ov5EwVo`가 `READY`이며 운영 alias `globospossystem.vercel.app`와 metadata SHA가 위 main에 일치한다. 웹 배포 완료는 약 15:59다.
- 전가복 4개 활성 배정의 Auth 연결·확정 상태·매장 claim은 각각 4/4였고 활성 tray 배정은 0이다. 계정을 생성/초기화/재활성화하지 않았다.
- 분식클럽 4개 활성 배정의 sync config는 기존 함수와 동일했다. 기존 `get_kds_bootstrap_v2`, `get_kds_ticket_v2`, `get_emergency_station_snapshot` 본문 해시도 변경되지 않았다.

### 실제 운영 데이터의 읽기 대조

15:57:35에 한 read-only repeatable-read snapshot에서 기존 bootstrap과 새 bootstrap을 배정별로 순서대로 실행했다. 카드의 수량·불변 메뉴 선택·포장·상태와 snapshot header가 4/4 일치했다. 새 카드에 함께 반환되는 station timer와 추가 호환 tray-ready metadata만 비교 시 정규화했다. 입력/출력 전체 이름이나 사용자 ID는 증거 파일에 저장하지 않았다.

| 실제 배정 | 현재 카드 | 기존 DB 시간 | 새 DB 시간 | 기존 / 새 응답 bytes |
|---|---:|---:|---:|---:|
| 저장 2F | 17 | 354.193ms | 45.044ms | 128,226 / 65,716 |
| 저장 3F A | 0 | 30.489ms | 9.942ms | 979 / 979 |
| 저장 3F B | 0 | 28.666ms | 9.902ms | 979 / 979 |
| 주방 | 20 | 319.601ms | 33.818ms | 139,430 / 71,990 |

각 배정의 **단일 DB 표본**이며 기존 함수를 먼저 실행했다. HTTP·네트워크·frame·가청 시간을 포함하지 않고 p95나 혼잡 시간 보증도 아니다. 완료 이력을 필수 응답에서 분리한 bytes 차이는 의도된 변경이다. 카드와 이력 데이터를 누락시켜 얻은 동일 범위 속도 비교로 해석하지 않는다. 완료 이력은 별도의 제한된 페이지에서 조회한다.

배포 전 13:58~14:58의 실제 HTTP 로그에서는 저장 2F 단건 조회 18건 p95 807ms, 주방 16건 p95 919ms였고 오류는 0이었다. 서로 다른 날짜/부하·계층의 위 DB 표본과 직접 비율 비교하지 않는다.

운영 증거는 [production-release.json](../measurements/jeongabok-kds-20261023/production-release.json)에 보존했다. 새 batch/500ms/5초 동작은 전가복 단말이 새 웹 번들을 읽은 후 사용한다. 기존에 열려 있는 전가복 단말은 새로고침이 필요하다. 물리 단말의 버튼→표시와 가청 시간은 별도 현장 계측 대상이다.

### 배포 후 실제 HTTP 관찰의 한계

15:57:30~16:02:00의 전가복 실제 클라이언트 로그에서는 설정 조회만 저장 2F 10건·주방 19건을 관찰했다. 오류 0건, origin p95는 각각 27ms/57ms다. 새 ticket batch/bootstrap/history RPC 호출은 **0건**이므로 신규 클라이언트의 실사용 HTTP p95 개선을 검증했다고 말할 수 없다. 이는 짧은 관찰 구간이며, 기존 전가복 단말에서 새 웹 번들을 새로고침하고 현장 표시·가청 확인을 이어가야 한다. 서버·웹 배포 완료와 현장 활성화 확인을 구분한다.
