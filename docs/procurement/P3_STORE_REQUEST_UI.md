# P3 — Store request workspace

Inventory order toolbar opens a dedicated v2 request workspace with multiple product lines, base/stock units, current-stock timestamp, optional suggested suppliers, required arrival date/reason, edits, submission, return reasons and server-authorized approvals. The API owns action visibility. Existing receiving remains reachable in the existing workflow.

Pending commands are persisted under actor + store identity before sending. Uncertain transport failures retain their exact key/payload across restarts; explicit transactional rejections clear the command for correction. Reload alone never discards an uncertain command. The feature remains disabled until store policy is configured.

Validation: four widget tests cover disabled stores, retry identity, store isolation and impossible dates; changed files pass Flutter analysis. No deployment performed.
