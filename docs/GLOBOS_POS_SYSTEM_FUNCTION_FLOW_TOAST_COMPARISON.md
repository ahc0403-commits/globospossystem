# GLOBOS POS System 기능/업무 플로우/화면 역할 정리 및 Toast POS 비교

## 1. 문서 목적

이 문서는 현재 코드베이스 기준으로 GLOBOS POS System이 실제로 제공하는 기능, 역할별 업무 플로우, 각 화면의 책임을 정리하고, 이를 Toast POS와 비교할 수 있도록 운영 관점에서 구조화한 문서다.

비교 기준은 "일반적인 Toast POS 운영 모델"과, 이 저장소 안에 이미 반영된 Toast 스타일 운영 UI 원칙(`Queue -> Select -> Act -> Optional Detail`)을 함께 참고한다. 즉, 외형 디자인 비교가 아니라 실제 업무 수행 구조와 운영 소프트웨어의 역할 비교에 초점을 둔다.

## 2. 한눈에 보는 시스템 성격

GLOBOS POS는 베트남 F&B 매장을 위한 멀티테넌트 POS이며, 단순 주문/결제 앱이 아니라 아래 기능을 한 시스템 안에 묶고 있다.

- 홀 주문 접수와 테이블 운영
- 주방 생산 큐 처리
- 캐셔 결제와 영수증 출력
- 결제 후 전자세금계산서 비동기 처리
- 매장 관리자용 메뉴/직원/리포트/재고/출결/QC/설정
- 딜리버리 정산(Deliberry settlement)
- 본사/슈퍼어드민용 다매장 운영
- Photo Objet 역할용 다점포 운영 대시보드

Toast POS와 비교하면, GLOBOS POS는 "POS + 백오피스 + 본사 운영 + 전자세금계산서 예외 처리"가 더 강하게 한 제품 안에 결합된 구조다.

## 3. 역할 체계

현재 라우팅과 인증 상태 기준으로 확인되는 주요 역할은 아래와 같다.

- `waiter`: 홀 주문/테이블 운영
- `kitchen`: 주방 주문 큐 처리
- `cashier`: 결제 처리
- `admin`, `store_admin`, `brand_admin`: 매장 운영/백오피스 관리
- `super_admin`: 시스템/다매장 운영
- `photo_objet_master`, `photo_objet_store_admin`: 다점포 운영 모니터링

Toast와 비교하면, Toast도 FOH/BOH/manager 권한 분리는 일반적이지만, 이 프로젝트는 `brand_admin`, `photo_objet_*`, `super_admin`처럼 "운영 조직 구조"를 더 세밀하게 권한 모델에 반영하고 있다.

## 4. 전체 업무 플로우

### 4.1 매장 운영 기본 플로우

1. 로그인
2. 역할별 홈 화면 진입
3. 웨이터가 테이블 선택 후 주문 생성 또는 기존 주문 이어받기
4. 주문 항목이 주방 큐로 반영
5. 주방이 아이템 상태를 `pending -> preparing -> ready -> served`로 진행
6. 캐셔가 결제 대상 주문을 선택하고 결제 처리
7. 결제 후 영수증 출력, 증빙 사진 업로드, 전자세금계산서 작업 생성/추적
8. 관리자는 리포트, 마감, 재고, 출결, QC, 설정을 후속 관리

### 4.2 운영 지원 플로우

- `admin`은 테이블 레이아웃, 메뉴, 인력, 정산, 리포트, 재고, QC를 운영
- `super_admin`은 매장 생성, 다매장 리포트, 공통 QC 템플릿, 시스템 설정을 관리
- `photo_ops` 역할은 여러 매장을 하나의 운영 큐 관점으로 모니터링

### 4.3 Toast와의 차이

- Toast는 일반적으로 주문 -> 주방 -> 결제 흐름이 중심이고, 백오피스/리포트/온라인 주문/정산이 제품군으로 연결된다.
- GLOBOS POS는 현재 코드 구조상 이 기능들을 한 앱 안에서 직접 다루는 비중이 더 높다.
- 특히 베트남 전자세금계산서와 매장별 예외 처리 흐름이 결제 후 업무의 핵심 일부로 들어가 있다는 점이 Toast 대비 가장 큰 차별점이다.

## 5. 화면별 역할 정리

## 5.1 로그인 `/login`

역할:

- 사용자를 인증
- 사용자 프로필에서 역할, 기본 매장, 접근 가능한 매장 목록을 로드
- 역할에 맞는 홈 화면으로 자동 분기

Toast 비교:

- Toast도 로그인 후 역할별 화면 진입은 유사하다.
- 다만 이 프로젝트는 `accessibleStores`, `primaryStoreId`, `activeStoreId`를 별도로 다루므로 단일 매장 단말보다 멀티매장 접근 모델이 더 강하다.

## 5.2 온보딩 `/onboarding`

역할:

- `super_admin`이 아직 매장을 갖고 있지 않을 때 최초 매장 생성
- 매장명, 주소, 운영 모드(`standard`, `buffet`, `hybrid`), 1인당 요금 입력
- 관리자 계정 생성 후 초기 구성을 마무리

Toast 비교:

- Toast의 초기 세팅은 보통 설치/백오피스 설정 흐름에 더 가깝다.
- GLOBOS POS는 앱 내부에서 최초 매장 생성과 운영 모드 선택까지 직접 처리한다.

## 5.3 웨이터 화면 `/waiter`

핵심 역할:

- 테이블 현황 로드
- 테이블 선택 후 주문 세션 시작
- 버페/하이브리드 매장에서는 게스트 수 입력
- 주문 생성, 추가 주문, 장바구니 초기화
- 주문 취소
- 테이블 이동(transfer table)

업무 성격:

- "테이블 중심" 운영 화면
- 주문 자체보다 좌석/테이블 상태와 현재 서비스 진행이 먼저 보이는 구조

Toast 비교:

- Toast FOH와 가장 유사한 화면이다.
- 다만 Toast는 좌석 배치, 코스, modifier, handheld 중심 확장이 더 일반적이고, GLOBOS POS는 현재 코드상 테이블/버페 인원/추가주문/테이블이동 같은 핵심 레스토랑 운영에 집중되어 있다.

## 5.4 주방 화면 `/kitchen`

핵심 역할:

- 매장별 주방 주문 큐 로드
- 신규 주문 카드 강조
- 아이템 상태를 `pending -> preparing -> ready -> served`로 순차 전환
- 오래된 주문, 주의 주문을 시각적으로 드러냄

업무 성격:

- 전형적인 KDS(Kitchen Display System) 역할
- "주문 카드 큐 -> 선택 -> 상태 변경" 구조가 명확함

Toast 비교:

- Toast KDS와 같은 종류의 운영 표면이다.
- 다만 현재 구현은 생산 라인, 코스 분리, prep station 분할보다 "한 큐 안에서 안전하게 상태를 전진"시키는 단순성과 명확성에 초점을 둔다.

## 5.5 캐셔 화면 `/cashier`

핵심 역할:

- 결제 가능한 주문 목록 조회
- 주문 선택 후 결제 수단 선택
- 결제 처리
- 결제 성공 토스트/에러 토스트 처리
- 영수증 출력
- 결제 증빙 사진 업로드 및 오프라인 큐 flush
- 전자세금계산서 상태 배지와 후속 상세 화면 진입
- 일일 캐셔 요약 확인

업무 성격:

- "정산 대상 큐 -> 주문 선택 -> 결제 실행 -> 증빙/세금계산서 후속" 구조
- 단순 결제 완료가 끝이 아니라, 증빙과 전자세금계산서 후속 처리가 결제 경험에 붙어 있음

Toast 비교:

- Toast의 결제/체크아웃 역할과 유사하다.
- 그러나 GLOBOS POS는 베트남 운영 요구사항 때문에 "결제 이후 문서화/증빙/전자세금계산서 예외 처리"가 더 두껍다.
- Toast가 일반적으로 payment workflow 중심이라면, 여기서는 settlement evidence workflow가 더 강하다.

## 5.6 결제 상세 `/payments/:paymentId`

핵심 역할:

- 결제 상태
- 주문 정보
- 전자세금계산서 job 상태
- 증빙 사진 상태
- `lookup_url` 기반 외부 포털 추적

업무 성격:

- 읽기 전용 운영 스냅샷
- 결제 후 발생하는 문제를 운영자가 추적하는 예외/감사 화면

Toast 비교:

- Toast에도 주문/결제 상세 조회는 가능하지만, 이 정도로 e-invoice job과 proof 상태를 함께 읽는 구조는 GLOBOS POS의 지역 특화 성격이 강하다.

## 5.7 관리자 화면 `/admin`

관리자 화면은 매장 운영 백오피스의 핵심 허브다. 현재 탭 구조는 아래와 같다.

- Tables
- Menu
- Staff
- Reports
- Attendance
- Inventory
- QC
- Settings
- Deliberry Settlement
- E-Invoice

Toast 비교:

- Toast 백오피스와 가장 가까운 역할을 하지만, GLOBOS POS는 매장 운영자가 앱 안에서 직접 처리하는 범위가 더 넓다.
- 특히 `QC`, `Deliberry Settlement`, `E-Invoice`는 Toast의 일반적인 POS 백오피스보다 더 지역/운영 특화된 탭이다.

### 5.7.1 Tables

역할:

- 테이블 목록과 레이아웃 관리
- 테이블 추가/수정/삭제
- 배치 드래프트 저장/초기화

Toast 비교:

- Toast의 floor plan 관리와 유사
- 현재 구조는 "실제 매장 좌석 운영"보다는 "레이아웃 관리 도구"에 더 가깝다

### 5.7.2 Menu

역할:

- 메뉴 카테고리 관리
- 메뉴 추가/수정
- 운영 가능한 메뉴 구조 유지

Toast 비교:

- Toast menu management와 유사
- 현재 구현은 재고/레시피 연동의 기반 데이터 관리 성격이 강함

### 5.7.3 Staff

역할:

- 직원 계정 생성/수정
- 역할 할당
- 매장/브랜드/특수 역할 부여

Toast 비교:

- Toast의 employee/permissions 관리와 유사
- 다만 이 프로젝트는 멀티브랜드/멀티스토어 접근과 특수 역할 모델이 더 복잡하다

### 5.7.4 Reports

역할:

- 매출 리포트
- 홀/딜리버리/총매출/비용 관찰
- 운영 주의 신호 확인
- 일마감(`Close Today`)

Toast 비교:

- Toast reporting + closeout 성격과 유사
- GLOBOS POS는 `proof completion`, `failed e-invoice`, `WT08 readiness` 같은 운영 경고가 들어가 있어 단순 숫자 리포트보다 "운영 이슈 발견" 기능이 강하다

### 5.7.5 Attendance

역할:

- 출결 기록 조회
- 급여 프리뷰 생성/저장/잠금 해제
- 급여 export

Toast 비교:

- Toast는 보통 time tracking/employee management와 연결되지만, 이 프로젝트는 출결과 payroll preview가 관리자 워크스페이스 안에 더 직접적으로 들어와 있다

주의:

- 별도 `attendance-kiosk` 화면이 있으나 라우터에서 현재 비활성화되어 있어 dormant 상태로 보는 것이 맞다.

### 5.7.6 Inventory

역할:

- 원재료 등록
- 레시피 매핑
- 실사(stock count)
- 재고 트랜잭션 조회
- 발주 추천 실행
- 추천 기반 발주서 생성
- 발주 승인/입고/잔량 확인 흐름

Toast 비교:

- Toast Inventory 계열 기능과 비교 가능한 영역
- 하지만 이 프로젝트는 "추천 -> 주문 생성 -> 승인 handoff -> 입고 확인"이 코드 안에서 더 명시적으로 보이며, 운영 예외 문구와 안전장치가 강하게 드러난다

### 5.7.7 QC

역할:

- 점검 항목 템플릿 관리
- 주간 뷰 / 기간 검색
- 점검 결과 조회
- 후속조치(follow-up) 관리

Toast 비교:

- Toast 기본 POS보다 더 운영감사/현장품질 관리에 가깝다
- 본질적으로 POS 기능이라기보다 store operations compliance 도구다

### 5.7.8 Settings

역할:

- 매장 운영 모드 설정
- 프린터 연결 테스트 / 테스트 출력
- PIN 변경/삭제
- 기타 매장 설정 갱신

Toast 비교:

- Toast device/settings와 일부 유사
- 다만 GLOBOS POS는 식당 운영 모드(`standard/buffet/hybrid`)가 핵심 업무 모델을 바꾸므로 설정의 의미가 더 크다

### 5.7.9 Deliberry Settlement

역할:

- 딜리버리 미정산 매출 확인
- 정산 이력 조회
- 상태별 필터
- 입금 예정/분쟁/미수금 등 운영 주의 구간 파악

Toast 비교:

- Toast Delivery/3rd-party integration과 유사한 문제 영역이지만, GLOBOS POS는 정산 자체를 별도 운영 워크스페이스로 강하게 분리해 두고 있다
- 코드 주석상 이 흐름은 Photo Objet office 운영과도 분리된 "별도 금융 워크플로우"로 취급된다

### 5.7.10 E-Invoice

역할:

- 실패/정체/폴링 대기 전자세금계산서 job 조회
- dispatch/polling 비활성화 상태 감시
- 수동 재시도/운영 개입 포인트 확인

Toast 비교:

- Toast 표준 POS 비교에서 가장 차별화되는 탭
- 베트남 세무/전자세금계산서 운영 때문에 생기는 지역 특화 운영 표면이다

## 5.8 QC 체크 화면 `/qc-check`

역할:

- 현장 점검 수행
- 항목별 `Pass / Fail / N/A`
- 메모 작성
- 증빙 사진 첨부
- 점검 결과 제출

Toast 비교:

- Toast POS의 일반적 주문/결제 흐름 밖에 있는 운영관리 기능
- 매장 운영 감사 도구로 이해하는 편이 정확하다

## 5.9 Photo Ops `/photo-ops`

역할:

- 다점포 운영 현황 요약
- 우선순위 큐
- 매출 요약
- 출결 요약
- 재고 경고
- 급여 프리뷰
- 접근 가능한 매장 범위 확인

업무 성격:

- POS 화면이라기보다 브랜드/운영 총괄용 통합 관제판

Toast 비교:

- Toast의 다점포 운영 분석 기능과 부분적으로 비교 가능하지만, GLOBOS POS는 `photo_objet_*` 역할을 별도 운영 주체로 두고 있으며, 현장 운영 이슈 큐에 더 가깝다

## 5.10 슈퍼어드민 `/super-admin`

역할:

- Stores
- All Reports
- QC Status
- QC Template
- System Settings

세부 책임:

- 매장 생성 및 진입
- 전체 매장 리포트 집계
- HQ 공통 QC 기준 관리
- 시스템 레벨 설정
- 특정 매장 admin 화면으로 drill-down

Toast 비교:

- Toast enterprise/back-office HQ 관리와 일부 유사
- 그러나 GLOBOS POS는 본사 QC 템플릿과 매장 생성 흐름이 더 직접적으로 묶여 있어 "운영 플랫폼 관리자" 성격이 강하다

## 6. Toast와 비교한 기능 구조 요약

| 비교 항목 | GLOBOS POS | Toast POS와의 관계 |
| --- | --- | --- |
| 홀 주문/테이블 | 구현됨 | 매우 유사 |
| 주방 큐/KDS | 구현됨 | 유사 |
| 결제/영수증 | 구현됨 | 유사 |
| 결제 분할/증빙 | 구현됨 | 유사하나 증빙 후속이 더 강함 |
| 전자세금계산서 운영 | 강하게 구현됨 | GLOBOS 특화 |
| 매장 관리자 백오피스 | 넓게 구현됨 | 유사하지만 범위 더 넓음 |
| 출결/급여 프리뷰 | 앱 내부에 직접 포함 | Toast 대비 운영 관리 비중 큼 |
| 재고/발주 추천/입고 | 구현됨 | 유사하지만 운영 안전장치 강조 |
| QC/현장 점검 | 강하게 구현됨 | GLOBOS 특화 |
| 다점포 HQ 관리 | 구현됨 | 유사 |
| Photo Ops 통합 관제 | 구현됨 | GLOBOS 특화 |
| 딜리버리 정산 워크스페이스 | 구현됨 | GLOBOS 특화 |

## 7. 이 시스템의 핵심 차별점

### 7.1 Toast보다 더 "운영 플랫폼"에 가깝다

GLOBOS POS는 POS 화면만 잘 만드는 것이 목적이 아니라, 매장 운영자가 실제로 겪는 후속 업무까지 한 제품 안에서 이어지게 하는 방향이 강하다. 결제 후 증빙, 전자세금계산서, QC, 출결, 급여 프리뷰, 딜리버리 정산이 그 예다.

### 7.2 베트남 로컬 운영 요구사항이 중심이다

전자세금계산서 job, WeTax 연계, lookup URL, dispatch/polling 운영 플래그는 이 시스템이 단순한 글로벌 POS 복제가 아니라 베트남 실무를 위해 설계된 제품임을 보여준다.

### 7.3 멀티매장/멀티역할 모델이 깊다

`accessibleStores`, `brand_admin`, `super_admin`, `photo_objet_*` 구조 때문에, 이 시스템은 단일 점포용 POS보다 운영 조직 체계를 더 많이 반영한다.

## 8. 현재 코드 기준으로 봤을 때의 해석

현재 제품은 Toast처럼 "주문-결제"만 빠르게 처리하는 POS라기보다 아래 세 층을 함께 가진다.

1. 현장 실행층: Waiter, Kitchen, Cashier
2. 매장 운영층: Admin, QC Check, Reports, Inventory, Attendance
3. 본사/관제층: Super Admin, Photo Ops, E-Invoice exception handling

따라서 GLOBOS POS를 Toast와 비교할 때는 "Toast POS 단말" 하나와 비교하기보다, Toast의 POS + KDS + Back Office + 일부 multi-location operations를 합친 운영 플랫폼으로 보는 쪽이 더 정확하다.

## 9. 결론

GLOBOS POS는 Toast와 같은 레스토랑 POS의 기본 골격을 공유한다. 즉, 테이블/주문/주방/결제/관리자 보고 체계는 같은 문제를 푼다.

하지만 실제 구현 중심축은 다르다.

- Toast는 범용 레스토랑 운영 제품군에 가깝다.
- GLOBOS POS는 베트남 매장 운영 실무와 다점포 운영, 전자세금계산서, QC, 딜리버리 정산까지 한 앱 안에서 이어 붙인 운영 플랫폼에 가깝다.

그래서 이 시스템을 설명할 때 가장 적절한 한 문장은 아래와 같다.

> GLOBOS POS는 "Toast와 유사한 레스토랑 POS 골격 위에, 베트남 매장 운영과 본사 운영 기능을 깊게 얹은 통합 운영 시스템"이다.

## 10. 근거로 읽은 주요 코드

- `lib/core/router/app_router.dart`
- `lib/features/auth/auth_provider.dart`
- `lib/features/onboarding/onboarding_screen.dart`
- `lib/features/waiter/waiter_screen.dart`
- `lib/features/kitchen/kitchen_screen.dart`
- `lib/features/cashier/cashier_screen.dart`
- `lib/features/payment/payment_detail_screen.dart`
- `lib/features/admin/admin_screen.dart`
- `lib/features/admin/tabs/*`
- `lib/features/delivery/screens/delivery_settlement_tab.dart`
- `lib/features/photo_ops/photo_ops_screen.dart`
- `lib/features/super_admin/super_admin_screen.dart`
- `lib/core/services/order_service.dart`
- `lib/core/services/payment_service.dart`
- `lib/core/services/daily_closing_service.dart`
- `docs/office/TOAST_OPERATIONAL_UI_SOURCE_OF_TRUTH.md`
