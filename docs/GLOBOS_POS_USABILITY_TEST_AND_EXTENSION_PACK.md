# GLOBOS POS Usability Test and Extension Pack

## 1. 목적

이 문서는 `waiter / cashier / kitchen` 핵심 화면 재설계를 실제 현장 시나리오로 검증하기 위한 usability test 항목과, 그 결과를 `admin / HQ / e-invoice`로 확장하는 적용 규칙을 정의한다.

## 2. 테스트 원칙

- 테스트는 예쁜 화면 평가가 아니라 작업 성공률 평가다.
- 역할별로 가장 자주 하는 태스크를 기준으로 측정한다.
- 시간이 걸리는 이유, 되돌아가는 이유, 잘못 누르는 이유를 수집한다.
- 오프라인, 권한 제한, 예외 상황도 포함한다.

## 3. 공통 측정 항목

| 항목 | 정의 |
| --- | --- |
| First action time | 화면 진입 후 첫 유효 행동까지 걸린 시간 |
| Task completion time | 태스크 완료까지 총 시간 |
| Error count | 잘못된 탭/클릭/되돌아가기 횟수 |
| Assistance count | 도움 요청 또는 설명 필요 횟수 |
| State recognition | 상태를 3초 내 인지했는지 여부 |
| Confidence score | 사용 후 자기평가 1~5 |
| Stress signal | 멈춤, 재탐색, 반복 클릭 발생 여부 |

권장 기준:

- First action time: 3초 이내
- 핵심 태스크 완료율: 95% 이상
- primary CTA 오인식: 5% 이하

## 4. Waiter Test Pack

### 4.1 시나리오

1. 빈 테이블에 새 주문 생성
2. 진행 중 테이블에 추가 주문 전송
3. 버페 테이블에 게스트 수 입력 후 주문 시작
4. 잘못 선택한 테이블에서 빠져나오기
5. 주문 작성 중 네트워크 불안정 상태 인지

### 4.2 관찰 포인트

- 테이블 큐에서 어떤 테이블을 먼저 눌러야 하는지 바로 이해하는가
- 메뉴 탐색과 체크 검토가 동시에 과부하를 만들지 않는가
- `SEND ORDER`가 너무 늦게 발견되지 않는가
- 드문 기능이 메인 작업을 방해하지 않는가

### 4.3 성공 기준

- 새 주문 생성 60초 이내
- 추가 주문 전송 30초 이내
- 게스트 수 입력 경로를 설명 없이 완료
- 테이블 이동 기능을 메인 액션으로 오해하지 않음

## 5. Cashier Test Pack

### 5.1 시나리오

1. 결제 대상 주문 선택 후 카드 결제
2. 현금 결제 후 영수증 출력
3. 카드 결제 후 증빙 사진 업로드
4. 서비스 처리 결제 진행
5. 오프라인일 때 결제 불가 상태 인지

### 5.2 관찰 포인트

- 결제 대상 큐에서 어떤 주문이 payable인지 바로 보이는가
- 결제 수단 버튼의 의미가 충분히 분리되는가
- `PROCESS PAYMENT`가 언제 활성화되는지 명확한가
- 결제 후 증빙/e-invoice 단계가 메인 결제를 방해하지 않는가

### 5.3 성공 기준

- 기본 결제 완료 25초 이내
- 증빙 필요 결제 완료 45초 이내
- 오프라인 시 잘못된 결제 시도 없이 이유를 이해
- e-invoice 예외 도구를 결제 중에 찾으려 하지 않음

## 6. Kitchen Test Pack

### 6.1 시나리오

1. 새 주문을 발견하고 prep 시작
2. 오래된 주문을 먼저 찾아 처리
3. 한 주문 내 여러 아이템 상태를 순차 변경
4. 준비 완료 항목을 빠르게 식별
5. 현재 스테이션 기준 필요한 주문만 확인

### 6.2 관찰 포인트

- 가장 오래된 주문을 3초 안에 찾는가
- `pending / preparing / ready` 구분을 텍스트 없이도 이해하는가
- 카드/컬럼 구조가 밀집 상황에서도 견디는가
- 한 번에 눌러야 할 버튼이 분명한가

### 6.3 성공 기준

- 새 주문 발견 3초 이내
- 상태 전환 오작동 5% 이하
- 장기 대기 주문 식별 5초 이내
- ready 항목 확인 3초 이내

## 7. 권한/오프라인 예외 테스트

모든 역할 공통으로 아래 시나리오를 점검한다.

1. 권한 없는 액션이 비활성화 이유와 함께 보이는가
2. 오프라인 상태에서 가능한 행동과 불가능한 행동이 명확한가
3. 선택이 없을 때 사용자가 다음 행동을 이해하는가
4. 상위 단계가 안 끝났을 때 `Waiting on upstream step` 같은 문구가 충분히 설명적인가

## 8. 테스트 운영 방법

권장 표본:

- Waiter 3명 이상
- Cashier 3명 이상
- Kitchen 3명 이상
- 관리자/HQ 2명 이상

권장 방식:

- 종이 또는 저충실도 프로토타입 1차
- 인터랙티브 프로토타입 2차
- 실제 단말 또는 유사 화면 밀도에서 3차

기록해야 할 것:

- 멈춘 지점
- 되돌아간 지점
- 가장 먼저 찾은 버튼
- 잘못 누른 버튼
- “다음에 무엇을 해야 하는지 몰랐던 순간”

## 9. Admin 확장 규칙

Admin은 라이브 오퍼레이션보다 `작업 큐 + 선택 기록 + 복합 액션` 성격이 강하다.

적용 규칙:

- 첫 화면은 KPI가 아니라 작업 리스트
- 검색/필터를 상단 또는 좌측에 배치
- 선택 항목 상세는 우측 패널
- 이력과 고급 설정은 drawer

권장 확장 순서:

1. Inventory
2. QC
3. Reports
4. Staff
5. Tables / Settings

### Admin 샘플 패턴

```text
+-------------------------------------------------------------------------------------+
| FILTERS / SEARCH | LIST OF WORK ITEMS | SELECTED ITEM DETAIL | PRIMARY ACTIONS      |
+-------------------------------------------------------------------------------------+
```

## 10. HQ 확장 규칙

HQ/Photo Ops는 `리스트 관리 화면`보다 `우선순위 관제 화면`에 가깝다.

적용 규칙:

- 첫 화면은 매장별 KPI 나열이 아니라 경고 큐
- 그다음이 매장 리스트
- 마지막이 매장 drill-down

권장 큐:

- Sales anomaly
- Inventory alert
- Attendance issue
- QC unresolved
- E-Invoice failed

### HQ 샘플 패턴

```text
+------------------------------------------------------------------------------------------------+
| PRIORITY ALERT BAR                                                                             |
+------------------------------------------------------------------------------------------------+
| ISSUE QUEUE                             | STORE LIST                      | SELECTED STORE      |
|-----------------------------------------|---------------------------------|---------------------|
| [QC overdue][Store A]                   | Store A  Sales / Inventory      | Drill-down links    |
| [E-Invoice failed][Store C]             | Store B  Sales / Attendance     | Active exceptions   |
| [Inventory risk][Store B]               | Store C  QC / E-Invoice         | Next actions        |
+------------------------------------------------------------------------------------------------+
```

## 11. E-Invoice 확장 규칙

E-Invoice는 admin의 한 탭이지만 설계 문법은 일반 back-office보다 `exception operations surface`에 더 가깝다.

적용 규칙:

- 상태 필터가 항상 먼저
- 실패/지연/수동검토 건이 기본 큐
- 선택 후 복구 액션이 보임
- payload, portal link, raw status는 optional detail로 이동

권장 상태 그룹:

- Failed
- Pending Polling
- Manual Review
- Resolved

### E-Invoice 샘플 패턴

```text
+------------------------------------------------------------------------------------------------+
| STATUS FILTERS | Failed | Pending Polling | Manual Review | Resolved                            |
+------------------------------------------------------------------------------------------------+
| EXCEPTION QUEUE                         | RECOVERY PANEL                 | OPTIONAL DETAIL    |
|-----------------------------------------|--------------------------------|--------------------|
| Job #A | failed_terminal                | [Retry Dispatch]               | payload            |
| Job #B | stale                          | [Open Portal]                  | lookup_url         |
| Job #C | polling disabled               | [Mark Resolved]                | audit trail        |
+------------------------------------------------------------------------------------------------+
```

## 12. 단계적 실행 순서

1. `waiter / cashier / kitchen` low-fi validation
2. semantic token and action rule freeze
3. clickable prototype
4. usability test round 1
5. `inventory / QC / e-invoice` 확장
6. `HQ / Photo Ops / super-admin` 확장

## 13. 완료 기준

이 문서 기준으로 다음 질문에 "예"라고 답할 수 있어야 한다.

- 각 역할은 첫 화면에서 다음 행동을 3초 안에 찾는가
- 예외 처리 도구가 메인 작업을 방해하지 않는가
- 상태 색상과 배지가 화면마다 같은 의미를 유지하는가
- 권한 없는 사용자가 잘못된 기능을 기본 화면에서 보지 않는가
- HQ는 첫 화면에서 어느 매장에 먼저 개입해야 할지 알 수 있는가

## 14. 연계 문서

- `docs/GLOBOS_POS_ROLE_TASK_MATRIX_AND_OPERATIONAL_GRAMMAR.md`
- `docs/GLOBOS_POS_CORE_SURFACE_WIREFRAMES_AND_TOKEN_SPEC.md`
- `docs/GLOBOS_POS_TOAST_OPERATIONAL_REDESIGN_PROPOSAL.md`
