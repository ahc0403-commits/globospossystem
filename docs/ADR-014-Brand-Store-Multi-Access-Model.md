# ADR-014 — Brand/Store Multi-Access Model

## 상태
**승인됨** — 2026-04-14

## 컨텍스트
- 현재 POS 권한 모델은 `users.restaurant_id` 단일 축을 기준으로 동작한다.
- 실제 운영 요구사항은 상위 사용자가 하위 전체를 보고, 스토어 사용자는 자기 스토어만 보도록 확장되어야 한다.
- `photo_objet_master`, `photo_objet_store_admin`, `brand_admin`, `store_admin` 같은 역할은 단일 스토어 FK만으로는 안전하게 표현되지 않는다.
- Flutter 앱은 현재 로그인 후 단일 `storeId`를 전제로 라우팅과 조회를 수행한다.
- 기존 RLS와 Flutter 흐름을 한 번에 갈아엎으면 회귀 위험이 크다.

## 결정
단일 `restaurant_id` 모델을 즉시 제거하지 않고, 브랜드/스토어 다중 접근 모델을 병행 도입한 뒤 점진 전환한다.

## 핵심 원칙
1. 상위 권한은 하위 전체를 본다.
2. 스토어 권한은 해당 스토어로 한정한다.
3. 최종 권한 집행 단위는 항상 `store`다.
4. `brand`는 접근 가능한 `store` 집합을 계산하는 상위 단위다.
5. 조회 범위와 현재 작업 대상은 분리한다.
6. 모든 쓰기 작업은 명시적 `store_id`를 입력받아 서버에서 검증한다.

## 역할 매트릭스
- `brand_admin`
  - 자기 브랜드 하위 전체 스토어 조회 가능
  - 자기 브랜드 하위 전체 스토어 관리 작업 가능
- `store_admin`
  - 자기 스토어만 조회/수정 가능
- `photo_objet_master`
  - 자기 브랜드 하위 전체 스토어의 사진 도메인 조회/승인 가능
  - 일반 운영 도메인 관리 권한은 부여하지 않음
- `photo_objet_store_admin`
  - 자기 스토어의 사진 도메인만 조회/승인 가능

## 데이터 모델 결정
기존 `users.restaurant_id`는 과도기 호환용으로 유지하되, 아래 구조를 추가한다.

### `users`
- `brand_id`
  - 사용자의 기본 소속 브랜드
- `primary_store_id`
  - 사용자의 기본 작업 스토어

### `user_brand_access`
- 사용자가 접근 가능한 브랜드 범위의 진실
- 상위 조직 권한은 여기서 정의한다

### `user_store_access`
- 사용자가 최종적으로 접근 가능한 스토어 범위의 진실
- RLS와 Flutter가 소비하는 최종 접근 단위는 여기로 정규화한다
- `source_type`으로 직접 할당(`direct`)과 브랜드 상속(`brand_inherited`)을 구분한다

## 브랜드 하위 스토어 규칙
- 브랜드 하위 영업점은 `브랜드명 001`, `브랜드명 002` 형식으로 생성한다.
- 브랜드 접근이 부여되면 해당 브랜드 하위 모든 스토어를 `user_store_access`에 자동 전개한다.
- 브랜드에 새 스토어가 생기면 관련 브랜드 접근 유저에게 자동 반영한다.
- 스토어 비활성화/제거 시 관련 access도 함께 비활성화한다.

## 인증/권한 결정
권한 계산의 진실은 DB가 가진다. Flutter는 계산 결과를 소비한다.

### JWT claims
커스텀 access token hook으로 아래 값을 주입한다.
- `role`
- `brand_ids`
- `accessible_store_ids`
- `primary_store_id`

### 운영 원칙
- 로그인 시 claims를 계산한다.
- 관리자 권한 변경 후에는 claim refresh 경로를 호출한다.
- 기존 table-lookup helper/RLS는 fallback으로 유지한다.

## Flutter UX 결정
- 접근 가능한 스토어가 1개면 자동 선택한다.
- 2개 이상이면 헤더 스위처에서 `active store`를 선택한다.
- 조회 범위는 권한 전체를 허용할 수 있지만, 쓰기 작업은 항상 현재 `active store` 기준으로 수행한다.
- 마지막 선택 스토어는 클라이언트에 저장할 수 있으나, 서버 권한 검증이 최종 진실이다.

## 서버 경계 결정
- 쓰기 작업과 권한 부여/회수는 RPC 또는 DB 함수로 처리한다.
- 모든 mutation/RPC는 명시적으로 `store_id`를 받는다.
- 서버는 입력된 `store_id`가 `accessible_store_ids` 안에 있는지 검증한다.

## 전환 전략
1. `users.brand_id`, `users.primary_store_id` 추가
2. `user_brand_access`, `user_store_access` 추가
3. 브랜드 접근 → 스토어 접근 자동 전개 함수/동기화 경로 추가
4. auth hook + claim refresh 도입
5. 기존 단일 store helper를 fallback으로 유지
6. Flutter 헤더 스위처와 active store 상태 추가
7. role별 점진 전환 후 `photo objet` 구현

## 왜 이 구조인가
- 현재 단일 store 모델을 즉시 제거하지 않아 기존 POS 기능 회귀를 줄일 수 있다.
- 브랜드 상위 권한과 스토어 한정 권한을 같은 권한 모델 안에서 일관되게 표현할 수 있다.
- `photo_objet_master`처럼 다중 스토어 역할을 이후에 안정적으로 올릴 수 있다.
- RLS 최종 단위를 `store`로 통일해 DB 정책을 단순하게 유지할 수 있다.

## 구현 전 확인 사항
- 기존 `users.restaurant_id`의 과도기 의미를 문서화할 것
- access sync 실패 시 복구 경로를 마련할 것
- claim refresh를 관리자 변경 플로우의 기본 동작으로 둘 것
- `photo objet`는 다중 접근 모델 안정화 이후 구현할 것

## 관련 문서
- [ADR-013 — Store Type Classification](/Users/andreahn/globos_pos_system/docs/ADR-013-Store-Type-Classification.md)
- [phase_0_repo_audit.md](/Users/andreahn/globos_pos_system/docs/phase_0_repo_audit.md)
- [phase_1_architecture.md](/Users/andreahn/globos_pos_system/docs/phase_1_architecture.md)
