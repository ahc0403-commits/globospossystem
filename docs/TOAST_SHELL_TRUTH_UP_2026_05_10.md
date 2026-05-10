# Toast Shell Truth-Up — 2026-05-10

## Verdict: **PASS**

POS Toast shell 현황을 read-only audit 결과 기반으로 확정한다. 코드 변경 없음. 본 문서는 향후 "native ToastShell" 도입 여부를 ADR로 결정할 때 참조할 baseline이다.

---

## 1. Symbol presence (POS codebase)

| Symbol | Status | 위치 |
|---|---|---|
| `ToastShell` | **존재하지 않음** | grep 0건 |
| `ToastTopbar` / `ToastTopBar` | **존재하지 않음** | grep 0건 |
| `TopContextBar` | **존재하지 않음** | grep 0건 |
| `AppShell` | 존재 | `lib/core/ui/app_primitives.dart:204` |
| `WebSidebarLayout` | 존재 | `lib/core/layout/web_sidebar_layout.dart:20` |
| `ToastSidebar` / `ToastSidebarItem` / `ToastSidebarGroup` | 존재 | `lib/core/ui/toast/toast_sidebar.dart:24/50/59` |

이전 phase 메모/명세에 등장한 `ToastShell` / `ToastTopbar` / `TopContextBar` 는 코드베이스에 한 번도 구현된 적이 없다. PR #1 ("toast operational ux baseline") + PR #2 ("ToastConfirmDialog.show") 시점에 도입된 것은 `ToastSidebar` 어댑터와 `ToastConfirmDialog` 두 가지뿐이며, 그 외 "Toast*" 명명의 shell-level wrapper는 아직 미구현 상태다.

---

## 2. Shell hierarchy 정본 (current truth)

### Admin (web/desktop)
```
AdminScreen
  └─ ToastSidebar           (group→flat adapter, lib/core/ui/toast/toast_sidebar.dart:59)
      └─ WebSidebarLayout    (real layout — Scaffold + sidebar + topbar, lib/core/layout/web_sidebar_layout.dart:20)
```

`AdminScreen._buildWebDesktopLayout()` (`lib/features/admin/admin_screen.dart:217`)이 진입점.

### Admin (mobile)
```
AdminScreen
  └─ Scaffold
      └─ BottomNavigationBar
```

`AdminScreen._buildMobileLayout()` (`lib/features/admin/admin_screen.dart:290`). **Toast 미경유** — 별도 경로.

### Auth (login, onboarding)
```
LoginScreen / OnboardingScreen
  └─ AppShell                (decorative: Container(gradient) + SafeArea + Padding)
      └─ form widgets
```

`lib/features/auth/login_screen.dart:43`, `lib/features/onboarding/onboarding_screen.dart:40`.

### Role-scoped POS (waiter, kitchen, cashier, super_admin)
```
WaiterScreen / KitchenScreen / CashierScreen / SuperAdminScreen
  └─ Scaffold (직접)
```

Wrapper 없음. 각 screen이 자체 Scaffold + 자체 layout.

---

## 3. WebSidebarLayout은 wrapper가 아니라 real layout

`WebSidebarLayout`은 단순 pass-through가 아닌 실제 레이아웃 위젯이다:
- 2-column Row (sidebar + content)
- 사이드바 nav 그룹 헤더 렌더링
- 상단 토픞바 + leading/trailing 슬롯
- 클릭 핸들링 / 선택 인덱스 상태

`ToastSidebar`만이 단일 소비자이며, ToastSidebar는 Toast의 풍부한 데이터 모델(grouped + urgency + badge)을 WebSidebarLayout의 flat API로 변환하는 어댑터다. 둘은 짝(pair)으로 동작하며, 어느 하나만 단독 제거할 수 없다.

---

## 4. ToastSidebar는 group-to-flat adapter

`ToastSidebar.build()` (`lib/core/ui/toast/toast_sidebar.dart:102`)는 `_flatten()` 헬퍼로 그룹을 평면화한 뒤 WebSidebarLayout으로 위임한다. 단순 prop forwarding이 아니라 데이터 변환 책임이 있는 어댑터이므로 "trivial pass-through"가 아니다.

---

## 5. AppShell은 auth-only decorative wrapper

`AppShell` (`lib/core/ui/app_primitives.dart:204`)은 26줄 짜리 decorative widget — Container(gradient) + SafeArea + Padding. login / onboarding 두 화면에서만 사용되며, role-scoped 또는 admin 화면에서는 사용되지 않는다.

기술적으로는 inline 가능하지만, 두 곳에 동일 스타일 리터럴이 중복되며 단일 진리원천(single source of truth)이 손실된다. "최소 cleanup, UI 변경 금지" 제약 하에서 제거 이득이 없다.

---

## 6. 제거 가능한 wrapper

**0개.**

| Symbol | 결정 | 이유 |
|---|---|---|
| AppShell | 유지 | inlining 시 styling 리터럴 중복; SSO 손실; 기능적 단순화 이득 없음 |
| WebSidebarLayout | 유지 | 실제 레이아웃 로직 보유; ToastSidebar의 단일 의존 대상 |
| ToastSidebar 패밀리 | 유지 | 전략적 어댑터 (group→flat); 제거 시 AdminScreen이 자체 변환 또는 WebSidebarLayout 직접 결합 |

---

## 7. 남은 Toast migration debt (informational)

다음 항목들은 **본 문서 범위 밖**이며 별도 ADR로 결정해야 한다:

1. **Native ToastShell 도입 여부**  
   현재 admin web/desktop 경로는 어댑터 체인(ToastSidebar → WebSidebarLayout). Toast가 자체 shell layout을 직접 소유하도록 통합하면 어댑터 한 단을 제거할 수 있으나, 이는 shell hierarchy 재설계 범위. → **ADR 필요**.

2. **Native ToastTopbar 도입 여부**  
   현재 topbar는 WebSidebarLayout 내부에서 렌더. 분리/native화 여부는 위 1번과 함께 결정. → **ADR 필요**.

3. **Mobile admin → Toast 경로 확장**  
   현재 `_buildMobileLayout`은 BottomNavigationBar 사용, Toast 미경유. Toast의 모바일 변형이 명세상 존재하지 않음 — 모바일 Toast layout 도입 여부 결정 필요. → **ADR 필요**.

4. **Auth 라우트 Toast-native 대체**  
   현재 login/onboarding은 `AppShell` 사용. Toast-native AuthShell이 없어 대체 불가. 신규 위젯 도입 여부 결정 필요. → **ADR 필요**.

---

## 8. Decision anchor

본 문서는 다음 질문들에 대한 audit 시점(2026-05-10) 사실을 고정한다:

- **"POS에 ToastShell이 있나?"** → 없음
- **"POS에 ToastTopbar가 있나?"** → 없음
- **"WebSidebarLayout은 dead wrapper인가?"** → 아님. real layout
- **"ToastSidebar는 trivial pass-through인가?"** → 아님. data-shape adapter
- **"AppShell을 즉시 제거할 수 있나?"** → 가능하지만 이득 없음 (UI 변경 금지 제약 하)
- **"Toast 통합 phase가 끝났나?"** → 어댑터 체인 잔존. shell native 통합은 ADR 후 수행

---

## Validation snapshot (this audit)

| 검증 | 결과 |
|---|---|
| `dart format --set-exit-if-changed` (wrapper 7 files) | PASS — 0 changed |
| `flutter analyze --no-pub` (wrapper 6 paths) | PASS — No issues found |
| Tracked routing/sidebar contract tests | **존재하지 않음** (untracked codex 작업 3건은 사전 조건상 fail; 본 audit 무관) |
| 코드 변경 | **0 lines** (read-only audit + 본 문서만 추가) |

---

**Last updated**: 2026-05-10  
**Audit branch**: `feat/full-multi-account-smoke-expansion` (PR #3 base; 본 문서는 PR #3 커밋과 분리됨)  
**Reference commit**: `58455ab` (smoke test expansion) / parent `9285a82` (main)
