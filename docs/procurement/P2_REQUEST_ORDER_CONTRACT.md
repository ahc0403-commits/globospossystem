# P2 PR and official PO foundation

The store capability is disabled by default. The POS RPCs are `procurement_workspace` and `procurement_command`; Office actor input is accepted only on the service-role boundary. Ordinary POS users derive identity from their session. No Office ID is inserted into POS auth.users.

Supported foundation commands: configure, create_request, save_request, submit_request, store_approve, return_request, save_quote, select_quote, office_approve, senior_approve, issue_po, send_po, confirm_po. PR revisions preserve prior priced lines and archive quotes. Pricing changes invalidate approval. Selected quote quantities must cover the request; issuing supplier POs consumes each quote allocation once. Policies with missing limits require senior review; nonpreferred suppliers also require senior review.

Legacy PO/line mutations cannot modify v2 records. V2 receipt verification requires supplier confirmation and executes the private P1 routine, retaining maker/checker and atomic stock gates. The read response redacts commercial prices from POS orderers and includes server-owned allowed actions.

`bash scripts/test_procurement_v2.sh` passed existing receiving/concurrency tests and the v2 PR -> quote -> independent senior approval -> issued/sent/confirmed PO behavior. Interface integration, extended inspection/returns, accounting allocation, and replenishment are subsequent sequenced steps. No database deployment or pilot activation has occurred.
