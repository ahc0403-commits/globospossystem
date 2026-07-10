# GLOBOS POS Visual Design Improvement Guide

Updated: 2026-05-14

## 1. 디자인 개선에 직접 영향을 주는 기준

이 프로젝트에서 시각적 완성도를 높이는 기준은 단순히 “예쁜 색”이 아니라, 운영 화면에서 **더 빠르게 읽히고 더 안정적으로 보이는가**이다.
아래 7개가 실제 디자인 품질을 좌우하는 핵심 기준이다.

### 1.1 Visual Hierarchy

- 사용자가 2초 안에 `현재 화면의 제목`, `선택된 작업 맥락`, `다음 행동`을 구분할 수 있어야 한다.
- 제목, 서브카피, 메트릭, 상세 정보의 서체 강도와 크기가 명확히 분리되어야 한다.

### 1.2 Surface Depth

- 운영 화면은 `canvas -> work surface -> selected context -> action zone` 순서로 깊이감이 있어야 한다.
- 모든 박스가 같은 흰색 평면이면 정보 구조가 무너진다.

### 1.3 State Contrast

- `selected / active / warning / exception / success` 상태가 한 번에 구분되어야 한다.
- 상태는 텍스트보다 색상, 배지, 강조 영역에서 먼저 읽혀야 한다.

### 1.4 Rhythm And Density

- 조밀한 POS 화면에서도 간격이 무작위로 보이면 피로도가 커진다.
- 제목-메트릭-리스트-액션 간 수직 리듬이 반복되어야 한다.

### 1.5 Navigation Identity

- 현재 어떤 운영 레인(`live ops / back office / exception queue`)에 있는지가 사이드바와 상단 맥락에서 즉시 드러나야 한다.

### 1.6 Action Dominance

- 한 surface 안에는 `주 액션 1개`가 먼저 보여야 한다.
- 디자인적으로도 primary action만 가장 강한 accent를 가져야 한다.

### 1.7 Brand Warmth Without Visual Noise

- GLOBOS POS는 운영 툴이므로 차갑고 밋밋한 회색 평면보다는, 아주 얕은 warm tint와 lift가 있는 편이 더 안정적이고 완성도 있게 보인다.
- 단, 장식성은 최소여야 하며 실무 가독성을 해치면 안 된다.

## 2. 이번에 코드로 반영한 디자인 개선 기반

이번 수정은 개별 화면을 다시 그린 것이 아니라, **공통 디자인 시스템이 디자인 개선을 받아들일 수 있도록** 기반을 손본 것이다.

### 2.1 토큰 레벨

변경 파일:

- `/Users/andreahn/globos_pos_system/lib/core/ui/pos_design_tokens.dart`
- `/Users/andreahn/globos_pos_system/lib/core/ui/app_theme.dart`

반영 내용:

- canvas, sidebar, topbar, hero tint를 분리해서 표면 계층을 더 명확하게 만듦
- subtle shadow를 토큰으로 승격해서 모든 surface가 같은 깊이 문법을 쓰게 만듦
- `PosSurfaceTints`를 추가해 상태색을 직접 칠하는 대신, 표면 위에 얕은 semantic tint를 얹을 수 있게 만듦
- 버튼, 입력 필드, 다이얼로그 radius와 surface tint를 정리해 전역 일관성을 높임

### 2.2 프리미티브 레벨

변경 파일:

- `/Users/andreahn/globos_pos_system/lib/core/ui/toast/toast_primitives.dart`
- `/Users/andreahn/globos_pos_system/lib/core/ui/toast/toast_primitives_extended.dart`
- `/Users/andreahn/globos_pos_system/lib/core/ui/toast/toast_sidebar.dart`

반영 내용:

- `ToastWorkSurface`에 lift gradient + shadow를 적용해 flat white slab 문제를 줄임
- `ToastOperationalQueuePane` 헤더를 구조적으로 분리해서 제목/설명/메트릭의 위계를 더 분명하게 함
- `ToastMetricStrip`을 한 덩어리 정보 박스가 아니라 읽기 쉬운 metric tile 집합처럼 보이게 조정
- `ToastSelectedContextHeader`에 selection context 성격이 드러나도록 상단 강조와 urgent copy capsule을 부여
- `ToastPrimaryActionZone`과 `ToastActionRail`에 액션 구역 분리를 주어 primary CTA 집중도를 높임
- `ToastSidebar`와 `ToastSidebarPanel`에 sidebar 전용 surface와 header tint를 주어 navigation identity를 강화
- `PosListRow` selected 상태를 더 강하게 만들어 queue 선택이 더 분명하게 읽히게 함

## 3. 지금 반영된 디자인 개선 항목

아래 항목은 이미 코드에 반영된 상태다.

### 3.1 전역 시각 계층 개선

- 배경, topbar, sidebar, work surface가 같은 흰색으로 뭉개지지 않게 분리
- 카드와 패널이 떠 보이지도, 너무 붙어 보이지도 않도록 중간 깊이감 부여

### 3.2 선택 맥락 강조 강화

- selected context header가 단순 텍스트 띠가 아니라 “현재 작업 중인 맥락”으로 읽히도록 강화
- 선택된 queue row가 더 즉시 보이도록 selection tint와 shadow 추가

### 3.3 메트릭 가독성 개선

- metric strip이 숫자만 나열된 줄이 아니라, 빠르게 스캔 가능한 정보 타일처럼 보이게 조정
- label과 value 대비를 키워서 운영자가 숫자를 더 빠르게 읽게 함

### 3.4 내비게이션 정체성 강화

- sidebar header와 selected nav row가 더 명확히 구분되도록 조정
- 현재 어느 운영 레인을 보고 있는지 화면 분위기 자체로 더 잘 드러나게 함

### 3.5 액션 우선순위 가시화

- action zone을 본문과 시각적으로 분리
- primary action이 정보 카드 속에 섞이지 않고 마지막 단계로 읽히도록 정리

## 4. 디자인 관점에서 아직 남은 개선 항목

이 항목들은 “다시 흐름을 설계하자”가 아니라, 이미 정리된 구조 위에서 더 완성도를 높이는 디자인 후속 작업이다.

### 4.1 Copy Density Tuning

- 일부 admin/HQ 탭은 helper copy가 길어서 surface가 무거워 보인다.
- 긴 설명은 1줄 요약 + 세부는 아래 블록으로 재배치하는 것이 좋다.

### 4.2 Metric Count Budget

- 상단 metric은 surface당 2~4개까지만 유지하는 것이 가장 안정적이다.
- 일부 탭은 지표 수가 많아져서 다시 평면적인 리포트 화면처럼 보일 수 있다.

### 4.3 Status Tone Normalization

- 일부 화면은 warning/success/danger 톤이 맞춰졌지만, inventory/QC 세부 블록은 여전히 톤 편차가 남아 있을 수 있다.
- 상태 배지와 배경 tint를 더 일관되게 정리할 여지가 있다.

### 4.4 Card Density Balance

- photo_ops, inventory 일부 섹션은 카드 내부 요소가 많아 visually busy하게 느껴질 수 있다.
- 같은 정보라도 title, chip, narrative 순서를 정리하면 더 고급스럽게 보인다.

## 5. 디자인에 맞춰 꼭 필요한 UI/UX 보완만 추린 항목

이미 UI/UX 리팩터링은 많이 진행됐으므로, 아래는 **디자인을 살리기 위해서만 필요한 최소 보완 항목**이다.

### 5.1 Helper Copy Shortening

- 이유: 긴 부연 문구는 디자인 밀도를 무너뜨린다.
- 필요 작업: surface header 하위 설명을 1문장 수준으로 제한

### 5.2 Metric Budget Enforcement

- 이유: metric이 너무 많으면 아무리 디자인을 올려도 “복잡한 화면”처럼 보인다.
- 필요 작업: 각 핵심 surface 상단에 핵심 지표만 2~4개 유지

### 5.3 One Primary CTA Per Surface

- 이유: 디자인상 accent가 강해질수록 primary action이 2개 이상이면 오히려 혼란이 커진다.
- 필요 작업: 각 surface에서 strongest accent button은 1개만 유지

### 5.4 Overflow Discipline

- 이유: 드문 액션이 인라인에 많으면 시각적 긴장도가 높아지고 밀도가 깨진다.
- 필요 작업: move, cancel, admin utility 류는 overflow/menu 유지

### 5.5 Section Ordering For Narrative Cards

- 이유: 일부 back-office 카드는 정보 순서가 들쭉날쭉해서 디자인 완성도가 떨어져 보일 수 있다.
- 필요 작업: `title -> status chip -> metric row -> narrative -> action` 순서 고정

## 6. 결론

이번 단계의 핵심은 “새 디자인을 몇 장 그렸다”가 아니라,
**현재 운영 UI 전체가 더 높은 디자인 품질을 일관되게 받아들일 수 있도록 토큰과 프리미티브를 먼저 고친 것**이다.

따라서 다음 단계는 큰 UX 재설계가 아니라:

- 카피 밀도 조정
- metric 개수 절제
- 상태 톤 정규화
- 일부 back-office 카드 정렬

정도의 작은 후속 조정이 가장 효과적이다.
