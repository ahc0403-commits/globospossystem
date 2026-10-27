# 고객 주문 5개 항목 운영 배포·검증 결과

5개 항목의 운영 반영과 아래 범위의 배포 후 검증을 완료했다. 운영 웹 READY 시각은 **2026-10-23T19:45:45+07:00**, 기록 시각은 2026-10-23T19:53:25+07:00이다. 시간대는 Asia/Ho_Chi_Minh이며 운영자는 ahc0403-commits / Codex다.

- 운영 웹: [GLOBOS POS](https://globospossystem.vercel.app), [BunsikClub 주문 화면](https://globospossystem.vercel.app/#/order/bunsikclub-binh-thanh).
- 최종 main SHA: `c853fbbab7c6fa46b66512c6dd78da27edc4ff5e`.
- Vercel: `dpl_5EvFqaL9jhEpKag7bbJ1TPdbYugv`, READY / production. 프로젝트 `prj_glOhZuHqHUHyAsGaSx5BVip3MIJJ`.
- Supabase: `ynriuoomotxuwhuxxmhj`. `direct-order-public` v54 ACTIVE.
- 마이그레이션: `20261023120000`, `20261023121000` 적용·원자적 사후 검증·이력 등록 완료.
- [기능 PR #625](https://github.com/ahc0403-commits/globospossystem/pull/625), [검증 로그 서식 PR #627](https://github.com/ahc0403-commits/globospossystem/pull/627) 병합 완료.
- [최종 SHA의 필수 CI](https://github.com/ahc0403-commits/globospossystem/actions/runs/39951639305) 성공. 공식 `scripts/deploy_pos_production.sh`의 DB-only 2회와 기본 Edge/웹 배포 경로를 사용했다. 각 dry-run을 검토한 뒤 같은 명령에서 dry-run만 제거해 실행했고, 게이트 우회 옵션은 사용하지 않았다.

| 항목 | 운영 반영 및 확인 결과 | 기능 회귀 검증 |
| --- | --- | --- |
| 1. 상세주소 선택 입력 | 빈 값·공백·null·300자 제약과 301자 거부, 제출 함수의 빈 값 정규화, 기사 전표 검증을 확인했다. 실제 운영 배송지 화면에 상세주소 선택 입력이 표시된다. | 실제 v1/v2/v3 제출, 필수 기본주소/이름/전화, 픽업·검색·지도·수동 주소, 재전송 멱등성, 빈 상세주소 기사 전표 검사 통과. |
| 2. 이체 증빙 재전송 | 승인 전 교체 함수의 소스 해시·서비스 역할 전용 권한과 새 upload/commit API 등록을 확인했다. 잘못된 고객 세션은 HTTP 404로 차단된다. | 사진 교체·승인 경합 3개, 원본 이력 보존, 오래된 사진 승인 차단, 중복 결제·재고 차감 방지, 단계별 timeout 및 같은 경로 복구 통과. |
| 3. 채팅 자동 갱신 | 고객용 변경 조회 함수·메시지 변경 트리거 3개를 확인했다. 직원용 실시간 신호 테이블 게시와 발행 트리거 3개도 활성 상태다. 새 변경 API는 잘못된 세션 접근을 차단한다. | 2초(+최대 0.5초 분산) 자동 확인, 변경 시 선택 상세만 갱신, 완료 주문의 열린 채팅, 재연결·화면 복귀·실패 backoff 및 직원 이벤트 병합 통과. |
| 4. 은행 앱 연결 | 운영 JS에 VietQR 은행 연결 코드가 반영됐으며, 공식 빌드와 실제 배포 파일 해시가 일치한다. MB·VietinBank·BIDV·OCB·ACB 앱 선택을 지원한다. | 계좌·금액·수취인·참조 전달, 비밀 없는 반환 URL, 실패 안내와 320px 화면 검사 통과. 실제 은행 앱·송금 확인은 아래 현장 범위다. |
| 5. 관리자 메모 분리 | 전체 주문 메모 15건이 관리자 전용이고 음식 항목 메모 10건은 유지됐다. BunsikClub 기존 확정 메모 1건의 관리자 보존 및 준비/기사/영수증 제외, 기존 주문 1건의 주방·체커 화면용 데이터 2개를 확인했다. 운영 입력창에도 관리자 메모와 메뉴별 조리 요청 구분 안내가 표시된다. | 관리자 전용 답변, 명시적 준비 대상 변경, 조리 메모 유지, 추가 전표·기사·고객 출력 제외 및 원문 수정 재분류 통과. |

최종 CI는 저장소 64단계, 전체 Flutter **2,563개 통과·98개 제외**, 별도 실제 SQL/API **19개·76개**, 독립 Chrome 인증 **3개**를 통과했다. 별도 실행이 필요한 SQL/API 및 Windows/Chrome 검사는 해당 전용 작업에서 확인했다. 관련 파일을 분리 사본에서 실행한 Flutter 191개, 정적 분석, 실제 DB 통합 검사도 통과했다. 전체 운영 스키마 export를 사용하는 선택적 업그레이드 검사는 export가 제공되지 않아 실행하지 않았다.

운영에서는 새 함수 3개 본문 해시가 검증 소스와 일치했다. 실제 공개 카탈로그는 HTTP 200, 새 채팅·사진 업로드·commit의 잘못된 세션은 HTTP 404 `DIRECT_ORDER_UNAVAILABLE`을 반환했다. Edge Origin, 인증 없는 dispatcher 차단, 퇴역 Deliberry HTTP 410, 운영 HTTP 및 지정 운영 계정(cashier) 로그인 검사도 통과했다. 기존 주소·이름·전화 등 실제 고객 정보를 입력하거나 영업 주문·매출을 생성하지 않았다. 브라우저 확인 중 추가한 로컬 장바구니 항목은 제거해 0개로 정리했다.

운영 JS SHA-256은 `6314382bbfa0114716439bd7fa4a5f3ebbcaea9226bbb5b69cd743b4be5ccd20`이며 공식 로컬 빌드와 같았다. 코드 내 Supabase 연결 대상은 운영 프로젝트 한 곳으로 확인했다.

**남은 제한과 현장 확인**

- iOS/Android, Safari/Chrome 및 Zalo 인앱 브라우저에서 실제 은행 앱 설치·외부 앱 허용 상태와 실송금은 검증하지 않았다. 실제 고객 사진 교체·직원 입금 승인·양쪽 실제 메시지 왕복을 운영 고객 대상으로 수행하지 않았다. 이 흐름은 격리 DB·Edge·위젯 회귀로 검증했고, 운영에서는 배포·권한·서버 출력·API 경로를 확인했다.
- 고객 채팅은 폴링 간격에 네트워크 시간이 더해진다. 실패 시 최대 30초 backoff가 있으며 기존 고객 15초, 직원 30초 안전 조회도 유지한다. 긴 대화의 전체 상세 이력 응답과 실제 모바일 부하·메모리 측정은 이번 범위에 포함하지 않았다.
- 지원 목록 밖 은행 앱은 기존 QR·계좌 복사를 사용한다. 은행에서 돌아와도 결제가 자동 완료되지 않으며 고객 증빙과 직원의 실제 입금 확인이 필요하다. 다른 브라우저로 돌아오면 원래 주문 탭에서 이어가야 할 수 있다.
- 배포 전부터 열려 있던 고객·관리자·주방·체커 탭은 새 코드와 데이터를 불러오도록 한 번 새로 고침한다. 이후 고객 선택 대화는 자동 갱신된다.
- 기존 전체 주문 메모에 조리 지시를 적었던 경우 관리자가 준비 대상으로 재지정해야 한다. 이미 발행한 전표는 보존한다. 명시적 준비/배달 대상과 음식 항목 메모는 유지했다.
- 원래 장애 단말의 실제 네트워크·Storage 실패 구간은 확인하지 못했다. 이번 변경은 재전송 제한과 제한 없는 대기를 재현해 수정한 결과다.

운영 UI 확인 화면:

![운영 상세주소 선택 입력과 관리자 메모 안내](/Users/andreahn/globos_pos_system/docs/measurements/direct-order-production-release-20261023/production-address-admin-note.png)

실행 증거는 같은 폴더의 `db1/2(-dry-run).log`, `web-edge(-dry-run).log`, `final-main-ci.json`, `final-main-ci-complete.log`, `production-*.json`, 검증 SQL/Python 및 `vercel-after.json`에 보존했다. 명령의 ENV_FILE은 기존 보안 설정 파일을 사용했고 비밀 값은 로그에 출력하지 않았다.

첫 main 시도의 마지막 Git 공백 검사는 생성 로그의 줄 끝 공백 때문에 실패했다. 기능 소스 변경 없이 로그 5개를 정리한 #627을 병합하고 정확한 최종 SHA에서 필수 CI 전체를 다시 통과시킨 뒤에만 운영 변경을 시작했다.
