# PR account release, 2026-10-07

> 2026-10-24 소유자 정책: 앞으로의 자동 검증은 최종 후보·깨끗한 exact-main SHA에 묶인 전체 로컬 증거를 사용한다. GitHub는 commit/push 보관 용도이며 Actions/runner 성공은 필수 증거가 아니다. 기존 공식 배포·운영 검증은 유지하고 실행 스크립트·원격 보호 규칙의 남은 의존성은 우회하지 않는다. 아래 과거 실행 사실은 당시 이력이다.

The purchasing requester now opens the actual PR workspace, with stable creation-date pagination, scoped status counts, persistent exact-command retries, owner draft/returned edits, audited cancellation, beverage category support and KO/EN/VI A4 PDFs. Receiving, explicit PO links and existing Office updated-date pagination retain their contracts.

## Release scope and gates

Prepared from clean origin/main 73b47d90e67b59567b64c9ed4bf421e7397fd3ba in a separate worktree. Unrelated changes in the user's original POS and Office checkouts are excluded. Office requires the small companion beverage category/localization change before requester traffic.

The new migration is `20261007095000_procurement_pr_account.sql`. Version `20261007010000` already belongs to the unrelated direct-order customer-context migration and must never be repaired or replaced for this feature.

The migration repeats the production predecessor hashes and permission/index/category prerequisites inside its apply transaction. The matching read-only preflight and verification files run through the canonical production migration gate. The rollback restores the exact preceding functions, constraint and index state, and refuses if any beverage PR exists, including cancelled records. After beverage traffic, roll forward; never delete audit history to enable rollback. Migration history changes remain a separate gated operation.

Required checks: repository contract, existing procurement/Office/combined-receiving SQL regressions, exact predecessor rollback/reapply and rollback refusal, PR keyset query measurements, requester widget and PDF acceptance tests. Complete local verification must pass on the final candidate and clean exact merged main SHA before canonical deployment, with reproducible logs and remote push confirmation. Deploy only through `scripts/deploy_pos_production.sh` against the fixed POS Supabase and Vercel projects. Verify migration history, web provenance, existing-account login, requester list/detail/edit/retry/cancel behavior and Office compatibility after release. Do not create or reset Auth accounts.

This checked-in document describes release scope and required gates. Actual deployment SHA, timestamps and operational results are recorded separately after deployment; source completion alone is not production completion.
