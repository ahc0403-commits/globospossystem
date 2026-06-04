# GLOBOS POS 수동 검증 체크리스트

작성일: 2026-05-19

배포된 POS 웹앱을 사람이 직접 확인할 때 사용하는 체크리스트다.
계정 목록과 주요 화면 범위는 `integration_test/full_multi_account_smoke_test.dart`의
멀티 계정 스모크 테스트를 기준으로 정리했다.

## 1. 접속 정보

| 항목 | 값 | 확인 기준 |
|---|---|---|
| POS 웹앱 | `https://globospossystem.vercel.app` | 2026-05-19 기준 HTTP 200 확인 |
| Backend project | `ynriuoomotxuwhuxxmhj` / `globospossystem` | POS Supabase staging-like project |
| 브라우저 | Chrome desktop, 일반 창 또는 시크릿 창 | 깨끗한 검증이면 site data 삭제 후 시작 |

`https://office.globos.vn/dashboard`는 POS 수동 검증 링크가 아니다.
앱 상수에 있는 Office fallback URL이며, 이 문서 작성 시점에는 DNS가 해석되지 않았다.

## 2. 테스트 계정

아래 계정 공통 비밀번호:

```text
1234!@#$
```

### POS 계정

| 역할 / 화면 | 아이디 | 비밀번호 | 기대 진입 화면 |
|---|---|---|---|
| Waiter | `waiter@globos.test` | `1234!@#$` | 웨이터 테이블/대시보드 POS |
| Kitchen | `kitchen@globos.test` | `1234!@#$` | 주방 티켓 큐 |
| Cashier | `cashier@globos.test` | `1234!@#$` | 계산/결제 큐 |
| Store admin | `admin@globos.test` | `1234!@#$` | 매장 관리자 운영 화면 |
| Super admin | `superadmin@globos.test` | `1234!@#$` | 슈퍼 관리자 화면 |
| Full validation | `pos.validation.codex@globos.test` | `1234!@#$` | 광범위 검증용 접근 화면 |

### Office 계정

아래 계정은 POS 스모크 테스트에서 POS/Office 경계를 확인하기 위해만 나열된다.
Supabase Auth에는 존재할 수 있지만 `public.users` POS 프로필이 없으면 POS 범위 밖으로
처리되는 것이 정상이다.

| Office 범위 | 아이디 | 비밀번호 | POS에서 기대 결과 |
|---|---|---|---|
| Office store | `office.store@globos.vn` | `1234!@#$` | POS 범위 밖 처리 |
| Office brand KN | `office.brand.kn@globos.vn` | `1234!@#$` | POS 범위 밖 처리 |
| Office brand MK | `office.brand.mk@globos.vn` | `1234!@#$` | POS 범위 밖 처리 |
| Office staff | `office.staff@globos.vn` | `1234!@#$` | POS 범위 밖 처리 |
| Office super | `office.super@globos.vn` | `1234!@#$` | POS 범위 밖 처리 |

## 3. 결과 코드

| 코드 | 의미 |
|---|---|
| PASS | 기대 동작 확인 |
| FAIL | 차단성 회귀 또는 잘못된 동작 |
| PARTIAL | 주요 흐름은 동작하지만 일부 보조 항목 누락 |
| BLOCKED | 데이터, 네트워크, 계정 상태 문제로 검증 불가 |
| EXPECTED_OUT_OF_SCOPE | Office 계정이 POS 프로필 부재로 POS에 진입하지 못하는 정상 경계 |

## 4. 환경 확인

| # | 확인 항목 | 결과 | 메모 |
|---|---|---|---|
| 4.1 | `https://globospossystem.vercel.app` 접속 |  |  |
| 4.2 | 로그인 화면에 이메일, 비밀번호, 로그인 버튼 표시 |  |  |
| 4.3 | 최초 로드 후 흰 화면으로 멈추지 않음 |  |  |
| 4.4 | 로그인 페이지에서 새로고침해도 404 없이 앱 유지 |  |  |
| 4.5 | Supabase 요청이 가능할 정도로 네트워크 안정 |  |  |
| 4.6 | 검증자, 브라우저, 기기, 화면 크기, 타임존 기록 |  |  |

## 5. 로그인 및 진입 화면 확인

각 POS 계정을 독립적으로 검증한다. 계정 전환 전 반드시 로그아웃한다.

| # | 계정 | 확인 항목 | 결과 | 메모 |
|---|---|---|---|---|
| 5.1 | `waiter@globos.test` | 로그인 성공 후 웨이터 테이블/대시보드 표시 |  |  |
| 5.2 | `kitchen@globos.test` | 로그인 성공 후 주방 큐 표시 |  |  |
| 5.3 | `cashier@globos.test` | 로그인 성공 후 계산/결제 큐 표시 |  |  |
| 5.4 | `admin@globos.test` | 로그인 성공 후 관리자 화면 표시 |  |  |
| 5.5 | `superadmin@globos.test` | 로그인 성공 후 슈퍼 관리자 화면 표시 |  |  |
| 5.6 | `pos.validation.codex@globos.test` | 로그인 성공 후 접근 가능한 검증 화면 표시 |  |  |
| 5.7 | 모든 계정 | 로그아웃 후 이전 역할 화면/메뉴가 남지 않음 |  |  |

## 6. POS 교차 계정 핵심 흐름

아래 순서대로 진행한다. 보이는 주문번호 또는 주문 ID가 있으면 기록한다.

| # | 계정 | 단계 | 기대 결과 | 결과 | 메모 |
|---|---|---|---|---|---|
| 6.1 | Waiter | 첫 번째 사용 가능한 테이블 선택 | 테이블/주문 작업 화면 진입 |  |  |
| 6.2 | Waiter | 인원 수 팝업이 뜨면 `2` 입력 후 확인 | 주문 작업 화면 유지 |  |  |
| 6.3 | Waiter | 첫 번째 메뉴 아이템 추가 | 카트/주문 미리보기에 아이템 표시 |  |  |
| 6.4 | Waiter | 주문 전송 | 성공 배너 표시, 주문번호 확인 가능 |  |  |
| 6.5 | Kitchen | 주방 계정 로그인 후 웨이터가 만든 주문 확인 | 주방 큐에서 해당 주문 확인 |  |  |
| 6.6 | Kitchen | 가능한 경우 주문/아이템 상태 진행 | 오류 없이 상태 변경 |  |  |
| 6.7 | Cashier | 계산원 로그인 후 같은 주문 또는 첫 결제 후보 선택 | 결제 대상 주문 선택 가능 |  |  |
| 6.8 | Cashier | 결제 실행 | 결제 성공 배너 표시 |  |  |
| 6.9 | Cashier | 결제 후 증빙/레드 인보이스 모달 확인 | 현재 UI 기준으로 완료, 건너뛰기, 닫기가 가능하고 결제를 막지 않음 |  |  |
| 6.10 | Admin | 결제 후 Reports 확인 | 데이터가 준비되어 있으면 오늘 매출/리포트에 반영 |  |  |

## 7. 관리자 화면 확인

`admin@globos.test` 계정으로 진행한다.

| # | 화면 | 확인 항목 | 결과 | 메모 |
|---|---|---|---|---|
| 7.1 | Tables | Tables 메뉴 진입, 테이블 관리 화면 표시 |  |  |
| 7.2 | Menu | Menu 메뉴 진입, 메뉴 관리 화면 표시 |  |  |
| 7.3 | Staff | Staff 메뉴 진입, 직원 목록/관리 화면 표시 |  |  |
| 7.4 | Attendance | Attendance 메뉴 진입, 출결 화면 표시 |  |  |
| 7.5 | Inventory | Inventory 메뉴 진입, 재고 화면 표시 |  |  |
| 7.6 | QC | QC 메뉴 진입, 품질 관리 화면 표시 |  |  |
| 7.7 | Settings | Settings 메뉴 진입, 설정 화면 표시 |  |  |
| 7.8 | E-Invoice | E-Invoice 메뉴 진입, 전자세금계산서 화면 표시 |  |  |
| 7.9 | Delivery Settlement | Delivery Settlement 메뉴 진입, 정산 화면 표시 |  |  |
| 7.10 | Reports | Reports 메뉴 진입, 리포트 화면 표시 |  |  |
| 7.11 | Daily Closing | Reports 안의 일마감 섹션 확인 | 이미 마감됨 또는 마감 실행 가능 상태가 명확함 |  |  |

## 8. 슈퍼 관리자 화면 확인

`superadmin@globos.test` 계정으로 진행한다.

| # | 화면 | 확인 항목 | 결과 | 메모 |
|---|---|---|---|---|
| 8.1 | Landing | 슈퍼 관리자 화면 진입, Stores 메뉴 표시 |  |  |
| 8.2 | Stores | Stores 탭 진입 | 매장 목록/관리 콘텐츠 유지 |  |  |
| 8.3 | Reports | Reports 탭 진입 | 리포트 콘텐츠 유지 |  |  |
| 8.4 | QC Status | QC Status 탭 진입 | QC 상태 콘텐츠 유지 |  |  |
| 8.5 | QC Template | QC Template 탭 진입 | 템플릿 콘텐츠 유지 |  |  |
| 8.6 | System Settings | System Settings 탭 진입 | 시스템 설정 콘텐츠 유지 |  |  |

## 9. 검증 전용 계정 확인

`pos.validation.codex@globos.test` 계정으로 진행한다.

| # | 확인 항목 | 기대 결과 | 결과 | 메모 |
|---|---|---|---|---|
| 9.1 | 로그인 | POS 진입 성공 |  |  |
| 9.2 | 표시되는 메뉴/화면 목록 기록 | 접근 가능한 화면이 명확함 |  |  |
| 9.3 | 숨김 또는 차단 화면 확인 | 제한 화면은 의도적으로 없거나 차단됨 |  |  |
| 9.4 | 보이는 경우 waiter/kitchen/cashier/admin 흐름 재확인 | 권한 없는 화면 crash 또는 빈 화면 없음 |  |  |

## 10. Office 경계 확인

POS/Office 분리 확인이 필요한 경우에만 진행한다.

| # | 계정 | 확인 항목 | 기대 결과 | 결과 | 메모 |
|---|---|---|---|---|---|
| 10.1 | `office.store@globos.vn` | POS 로그인 시도 | EXPECTED_OUT_OF_SCOPE 또는 권한 거부 |  |  |
| 10.2 | `office.brand.kn@globos.vn` | POS 로그인 시도 | EXPECTED_OUT_OF_SCOPE 또는 권한 거부 |  |  |
| 10.3 | `office.brand.mk@globos.vn` | POS 로그인 시도 | EXPECTED_OUT_OF_SCOPE 또는 권한 거부 |  |  |
| 10.4 | `office.staff@globos.vn` | POS 로그인 시도 | EXPECTED_OUT_OF_SCOPE 또는 권한 거부 |  |  |
| 10.5 | `office.super@globos.vn` | POS 로그인 시도 | EXPECTED_OUT_OF_SCOPE 또는 권한 거부 |  |  |

## 11. 회귀 확인

| # | 확인 항목 | 기대 결과 | 결과 | 메모 |
|---|---|---|---|---|
| 11.1 | 로그인 후 브라우저 새로고침 | 허용된 경로 유지 또는 로그인으로 정상 복귀 |  |  |
| 11.2 | `/admin` 같은 직접 경로 새로고침 | `index.html`이 서빙되고 route guard 정상 동작 |  |  |
| 11.3 | 좁은 화면 또는 모바일 폭 | 주요 컨트롤 사용 가능, 텍스트 겹침 없음 |  |  |
| 11.4 | Empty/loading/error 상태 | 영구 스피너 없이 상태가 명확함 |  |  |
| 11.5 | 로그아웃 후 다른 역할 로그인 | 이전 역할 메뉴/화면이 새 계정에 누수되지 않음 |  |  |
| 11.6 | 새 탭에서 앱 재접속 | 현재 세션과 auth 상태가 일관됨 |  |  |

## 12. 최종 리포트

| 항목 | 값 |
|---|---|
| 검증자 |  |
| 일시 |  |
| 브라우저/기기 |  |
| POS URL | `https://globospossystem.vercel.app` |
| 최종 판정 | PASS / FAIL / PARTIAL / BLOCKED |
| 첫 차단 이슈 |  |
| 저장한 스크린샷 |  |
| 사용한 주문번호 / 결제 참조값 |  |
| 후속 담당자 |  |
| 후속 기한 |  |

## 13. 실패 로그

| 단계 | 계정 | 실패 내용 | 재현 가능 | 심각도 | 스크린샷 / 메모 |
|---|---|---|---|---|---|
|  |  |  | YES / NO | LOW / MEDIUM / HIGH |  |
