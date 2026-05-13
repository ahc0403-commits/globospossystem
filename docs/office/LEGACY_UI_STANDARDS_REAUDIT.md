# Legacy UI Standards Re-Audit

## Audit Scope

Audit date: `2026-05-13`

Baseline verified before document cleanup:

- `git checkout main`
- `git pull origin main`
- `git status --short`
- `flutter analyze`
- `flutter test`

Repo-wide keyword search was run against the requested legacy/UI-standard terms,
with focused review of:

- `docs/`
- `docs/office/`
- `lib/app/`
- `lib/shared/`
- `lib/features/`

## Found Legacy Standard Artifacts

| Artifact | Finding | Decision | New source-of-truth link |
|---|---|---|---|
| `docs/ui_ux_operational_refresh_plan.md` | Still instructed readers to keep the established dark operational tone and to refine it rather than replace it. This conflicts with the current light-first operational direction. | Deprecated | [Toast Operational UI Source of Truth](TOAST_OPERATIONAL_UI_SOURCE_OF_TRUTH.md) |
| `docs/TOAST_STYLE_OPERATING_PLATFORM_STANDARD.md` | Previously declared itself the binding UI source of truth. Keeping that status would leave multiple active standard files. | Deprecated and superseded | [Toast Operational UI Source of Truth](TOAST_OPERATIONAL_UI_SOURCE_OF_TRUTH.md) |
| `docs/TOAST_POS_OPERATIONAL_UX_STANDARD.md` | POS-only standard remained readable as a parallel active standard instead of a historical rationale file. | Deprecated | [Toast Operational UI Source of Truth](TOAST_OPERATIONAL_UI_SOURCE_OF_TRUTH.md) |
| `docs/TOAST_STYLE_REDESIGN_EXECUTION_PLAN.md` | Contained speculative shell/component replacement guidance and functioned like a parallel redesign authority before the new Office redesign lock. | Deprecated and replaced by a narrower master plan | [Office Operational UI Redesign Master Plan](OFFICE_OPERATIONAL_UI_REDESIGN_MASTER_PLAN.md) |
| `docs/TOAST_SHELL_TRUTH_UP_2026_05_10.md` | Factually stale. It claimed `ToastShell` and `ToastTopbar` were absent, but actual code now contains them in `lib/core/ui/toast/toast_primitives_extended.dart` and uses them from `lib/features/auth/login_screen.dart`, `lib/features/onboarding/onboarding_screen.dart`, `lib/core/layout/web_sidebar_layout.dart`, and `lib/features/photo_ops/photo_ops_screen.dart`. | Deprecated as stale audit output | [Toast Operational UI Source of Truth](TOAST_OPERATIONAL_UI_SOURCE_OF_TRUTH.md) |

## Retained But Repointed Documents

| Artifact | Finding | Decision | New source-of-truth link |
|---|---|---|---|
| `docs/inventory_purchase_office_design.md` | Still active as domain design, but its UI banner needed to point to the new single Office source-of-truth file. | Retained and repointed | [Toast Operational UI Source of Truth](TOAST_OPERATIONAL_UI_SOURCE_OF_TRUTH.md) |
| `docs/superpowers/plans/2026-05-02-flexible-floor-layout.md` | Still active as an implementation plan, but its banner pointed to the older standard naming. | Retained and repointed | [Toast Operational UI Source of Truth](TOAST_OPERATIONAL_UI_SOURCE_OF_TRUTH.md) |
| `docs/superpowers/plans/2026-05-04-i18n-global-language-rollout.md` | Still active as an implementation plan, but its banner pointed to the older standard naming. | Retained and repointed | [Toast Operational UI Source of Truth](TOAST_OPERATIONAL_UI_SOURCE_OF_TRUTH.md) |

## Code Reality Notes

The re-audit also checked whether legacy-standard names still exist in code.
They do, but as implementation details rather than active standard documents.

Examples confirmed on disk:

- `lib/core/ui/app_theme.dart` still defines `AppColors`.
- `lib/core/ui/app_primitives.dart` still defines `AppPanel` and `AppShell`.
- `lib/core/layout/web_sidebar_layout.dart` still defines the tracked admin
  shell path.
- `lib/core/ui/toast/toast_primitives_extended.dart` defines `ToastShell` and
  `ToastTopbar`.

These were retained. This audit did not authorize runtime UI rewrites.

## Delete / Deprecated / Keep Summary

- Deleted: none
- Deprecated: `docs/ui_ux_operational_refresh_plan.md`,
  `docs/TOAST_STYLE_OPERATING_PLATFORM_STANDARD.md`,
  `docs/TOAST_POS_OPERATIONAL_UX_STANDARD.md`,
  `docs/TOAST_STYLE_REDESIGN_EXECUTION_PLAN.md`,
  `docs/TOAST_SHELL_TRUTH_UP_2026_05_10.md`
- Kept with updated source-of-truth references:
  `docs/inventory_purchase_office_design.md`,
  `docs/superpowers/plans/2026-05-02-flexible-floor-layout.md`,
  `docs/superpowers/plans/2026-05-04-i18n-global-language-rollout.md`
- Kept unchanged as implementation or historical context: runtime code symbols,
  archived docs, feature-specific slice reports

## Remaining Blocker Before UI Redesign

No document-level blocker remains after this cleanup, provided future UI work
uses the Office source-of-truth document and acceptance checklist above.

## Verdict

PASS: legacy UI standards no longer remain as active source-of-truth guidance.
After this re-audit, new UI work should follow
`docs/office/TOAST_OPERATIONAL_UI_SOURCE_OF_TRUTH.md` only.
