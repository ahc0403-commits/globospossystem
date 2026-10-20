# 빈탄점 배달 주문 페이지 장애 진단

확인 시각: 2026-10-11 17:47 Asia/Ho_Chi_Minh.

## 결론

운영 주문 목록 RPC `public.direct_order_public_orders_v5(uuid,text,integer)`가
`STABLE`로 선언되어 PostgREST에서 읽기 전용 트랜잭션으로 실행된다.
이 함수는 `direct_order_public_orders_v4`를 호출하고, 그 안의
`direct_order_validate_session`이 `direct_order_sessions.last_seen_at`을
UPDATE하므로 SQLSTATE `25006`으로 실패한다.

운영 경로:

```text
고객 페이지 초기 로딩
  → direct-order-public / action=orders_v5
  → PostgREST /rpc/direct_order_public_orders_v5
  → direct_order_public_orders_v4
  → direct_order_validate_session
  → UPDATE direct_order_sessions SET last_seen_at = now()
  → SQLSTATE 25006 / PostgREST HTTP 405
  → Edge Function의 일반 RPC 오류 변환 / HTTP 503
  → 화면: 배달 주문 페이지를 불러올 수 없습니다.
```

## 확인한 증거

- 운영 페이지 `https://globospossystem.vercel.app/#/order/bunsikclub-binh-thanh`에서
  사용자가 보고한 오류 화면을 직접 재현했다.
- 매장은 활성 상태이고, 주문 페이지는 활성화되어 있으며 접수 일시 중지 상태가 아니다.
- 메뉴 조회 API는 HTTP 200, 메뉴 77개, 응답 38,929 bytes, 측정 0.627초였다.
  운영 origin에 대한 CORS 허용 응답도 정상이다. 응답 본문과 은행 정보는 기록하지 않았다.
- 운영 웹 번들에는 `orders_v5`, `status_v10` 호출이 있으며 `orders_v4` 호출은 없다.
  번들 SHA-256:
  `8a6eb4f503d65a740bbe83400342feaa76b2d16476871aa847e1aa26d942f7bb`.
- 운영 Edge Function `direct-order-public` 버전 39는 `orders_v5`를
  `direct_order_public_orders_v5` RPC로 전달한다. 미등록 SQL 오류는
  `DIRECT_ORDER_TEMPORARILY_UNAVAILABLE` / HTTP 503으로 변환한다.
- 운영 DB의 함수 정의를 읽어 `orders_v5`의 `provolatile='s'` (`STABLE`)와
  위 호출 관계를 확인했다. 기존 `orders_v4`는 `provolatile='v'` (`VOLATILE`)다.
- 운영 로그에서 17:42:28~17:45:16 사이 `/rpc/direct_order_public_orders_v5`는
  HTTP 405, 대응하는 `direct-order-public` 요청은 HTTP 503으로 반복 실패했다.
- 유효한 빈탄점 세션을 DB 안에서만 선택하고 `BEGIN READ ONLY` 조건으로
  `orders_v5`를 호출했을 때 아래 오류와 호출 스택을 재현했다.
  세션 ID와 비밀 해시는 출력하거나 파일에 저장하지 않았다.

```text
ERROR: 25006: cannot execute UPDATE in a read-only transaction
CONTEXT: UPDATE public.direct_order_sessions SET last_seen_at = now()
direct_order_validate_session → direct_order_public_orders_v4
→ direct_order_public_orders_v5
```

## 필요한 수정과 검증

최소 수정은 운영 버전의 아래 두 공개 RPC를 `VOLATILE`로 선언하는 것이다.
`status_v10`도 `STABLE`이며 기존 `status_v9` 호출을 감싸므로 동일한 세션 갱신
경로를 확인하고 함께 처리해야 한다. 이 문서에서는 목록 경로만 오류 재현했다.

```sql
ALTER FUNCTION public.direct_order_public_orders_v5(uuid,text,integer) VOLATILE;
ALTER FUNCTION public.direct_order_public_status_v10(uuid,text,uuid) VOLATILE;
```

수정 후 PostgREST 스키마 캐시를 갱신하고, 실제 REST POST를 통해 주문 목록 및
상태 조회를 검증해야 한다. 일반 SQL 연결에서만 호출하면 읽기 전용 트랜잭션
조건이 빠져 이 문제를 놓칠 수 있다. 신규 세션의 빈 목록과 기존 주문이 있는
세션의 목록, 주문 상태 링크를 확인하고 고객 페이지가 정상 표시되는지 검증한다.
접근 범위와 응답 형식, 기존 일괄 조회 구조를 유지한다.

PostgREST 공식 동작:
[Function access mode](https://postgrest.org/en/stable/references/transactions.html#access-mode-on-functions).
POST라도 `STABLE`/`IMMUTABLE` 함수는 READ ONLY, `VOLATILE` 함수는 READ WRITE로 실행된다.

## 작업 범위

이번 요청은 원인 조사다. 운영 DB 함수, Edge Function, 웹 배포는 변경하지 않았다.
진단 중 DB 호출은 롤백 트랜잭션을 사용했다. 수정 SQL은 실행하지 않은 제안이다.
현재 작업 폴더의 소스는 `orders_v4`/`status_v6`를 사용하며 운영 배포 버전과 다르다.
수정 작업은 최신 운영 소스와 대응 마이그레이션을 기준으로 준비해야 한다.
운영 적용에는 프로젝트의 정식 배포 절차와 정확한 main SHA의 필수 CI 검사를 적용한다.


## 후속 운영 반영

2026-10-11 19:05 Asia/Ho_Chi_Minh에 정식 DB 배포 절차로 수정이 적용됐다. 주문 API와 기존 오류 화면의 재시도가 정상으로 전환됨을 확인했다. [운영 반영 및 검증 기록](/Users/andreahn/globos_pos_system/docs/operations/direct_order_public_rpc_session_activity_release_20261011.md)을 참고한다. 본문의 수정 전 진단은 당시의 상태 기록이다.
