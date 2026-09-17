# Cashier whole-order cancellation and bank transfer QR

Cashier and management roles may cancel an unpaid order even if workers have
marked menu items served. The cancellation ledger, audit trail, payment guard,
store scope, and waiter restrictions are preserved. Cancellation includes served
items, and undo reopens the order before restoring items so KDS triggers restore
food, combo components, and floor-direct drinks with their prior progress.

Selecting bank transfer opens the existing Woori account QR with the selected
order's remaining amount and order reference, and publishes the customer display.
Closing the QR does not post a payment. The existing payment completion action
and proof flow remain explicit. Combined bank transfers now use the existing
combined-total QR confirmation before payment as well.

Validation: widget tests cover QR visibility, displayed amount, customer display
publication, closing without payment, subsequent payment/proof flow, and combined
QR for both payment methods. Isolated database tests cover served/unserved food,
combo drinks, whole-order undo, ledger, duplicate requests, unauthorized roles,
waiter flag bypass, cross-store access, and payments. Migration preflight,
verification, rollback and reapply are exercised against the isolated DB.

Kitchen follow-up: untouched menus sort above menus with any kitchen-start
quantity, including partial starts of multi-quantity menus. Detail and order-card
lists share this stable ordering. Undoing all starts returns the menu to the
untouched group. Remaining quantities stay actionable and order FIFO is unchanged.
Unit and widget tests cover the first tap, partial quantity and undo.
