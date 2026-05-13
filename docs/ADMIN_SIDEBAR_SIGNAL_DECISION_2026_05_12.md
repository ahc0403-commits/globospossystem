# ARCHIVE — Admin Sidebar Signal Decision — 2026-05-12

This file is preserved as pre-lock redesign planning only.

Do not use it as the current UI standard or redesign entry point.

Use these documents instead:

- [Toast Operational UI Source of Truth](office/TOAST_OPERATIONAL_UI_SOURCE_OF_TRUTH.md)
- [Office Operational UI Redesign Master Plan](office/OFFICE_OPERATIONAL_UI_REDESIGN_MASTER_PLAN.md)
- [Legacy UI Standards Re-Audit](office/LEGACY_UI_STANDARDS_REAUDIT.md)

Historical note:

- keep this file for provenance around the 2026-05-12 sidebar-signal decision

## Verdict

`admin_sidebar_signal_provider.dart` should remain **unrestored** and should be
 treated as **archive-or-redesign**, not as the next tracked implementation
 target.

## Current Tracked Truth

The tracked app now has fresh tracked replacements for the two higher-priority
 redesign lanes:

- `payment_detail` is live on tracked `main`
- `inventory_purchase` has a tracked read-only overview and a tracked
  read-only detail slice inside the existing inventory workspace

That changes the context around the old quarantined sidebar provider:

- it is no longer needed as a prerequisite to reopen either feature
- it is still not justified as a standalone restore

## Why It Should Not Be Restored

The quarantined file was previously classified as `archive_or_redesign`
 because:

1. it had **no tracked consumer**
2. it depended on a **quarantined inventory purchase runtime**
3. it added derivative signal plumbing rather than a user-facing primary flow

Those reasons still hold.

Even though tracked `inventory_purchase` now exists again, the tracked
 implementation shape is different:

- tracked inventory purchase is embedded inside `InventoryTab`
- the current tracked slice is read-only
- there is still no established tracked sidebar consumer contract

So the old provider cannot be assumed to fit the current tracked design.

## What The Provider Used To Represent

The quarantined provider attempted to aggregate admin alert counts across:

- QC signals
- delivery settlement signals
- inventory purchase alerts

That kind of aggregation is only worth reviving if the tracked admin shell
 explicitly needs:

- a sidebar badge
- a persistent alert chip
- or a dashboard summary consumer

No such tracked consumer exists today.

## Decision

Current decision:

- **do not restore** the quarantined `admin_sidebar_signal_provider.dart`
- **do not recreate** it just because `inventory_purchase` now has tracked
  read-only UI
- **do not introduce sidebar signal plumbing before a real consumer exists**

## Safe Future Trigger

This file should only be reconsidered if all of the following become true:

1. the tracked admin shell defines a concrete sidebar/dashboard consumer
2. the signal contract is explicitly scoped to tracked data sources only
3. the inventory purchase signal inputs are based on tracked runtime/service
   boundaries, not quarantined assumptions
4. the resulting UI value is clear enough to justify the extra state layer

## Best Lane From Here

If the team later wants this capability, the best lane is:

- **fresh redesign around tracked data sources**

Not:

- direct restore
- partial copy from quarantined runtime
- side-loading into the admin shell ahead of a consumer

## Immediate Non-Action

For the current phase:

- no runtime restore
- no provider restore
- no sidebar wiring
- no new signal service layer

The next meaningful tracked work should continue to prioritize primary user
 flows over derivative alert plumbing.
