# Financial Invariants & Enforcing Tests

The money-safety properties that must remain true as the UI/API evolve, and the tests that enforce each. Money is always exact `Int64` minor units. If a future change breaks one of these, a listed test should fail with enough context (seed / step / operation / balances) to debug it.

## How the property harness works
`test_invariants_property.py` runs seeded, reproducible random sequences (seeds `1, 7, 42, 1337, 2026`, 32 steps each) of valid operations — income, assign, move, spend, refund, transfer, split, credit purchase, target, schedule. After **every** applied step it recomputes conservation quantities **directly from stored rows** and asserts the identities below. Failures print the seed, step index, operation, computed state, and recent operations. To fuzz harder, widen the seed list or `steps` locally. No third-party fuzzing dependency is used (seeded `random.Random`).

The RTA identities are **non-vacuous**: the server's Ready-to-Assign (from the `months/{month}` endpoint, its own code path) is compared against an independent recomputation from raw allocation postings + transactions. A double-count or leak in either path makes them diverge.

## Invariant catalogue

| # | Invariant | Enforced by |
|---|---|---|
| **I1** | Sum of ALL allocation postings for a budget == 0 (no allocation mints/destroys money) | `test_invariants_property` (every step); `test_money_conservation` (all paths) |
| **I2** | Server RTA == uncategorized on-budget cash + allocation(None) (RTA reflects real cash, server matches independent recompute) | `test_invariants_property` |
| **I3** | RTA + Σ assigned == uncategorized on-budget cash (assign/move only shuffle between RTA and categories) | `test_invariants_property` |
| **I4** | Σ transfer-leg amounts == 0 (on-budget transfers conserve total cash; create no income/spending) | `test_invariants_property`; `test_advanced_ledger::test_transfer_is_balanced_and_does_not_create_income` |
| **I5** | For every split, Σ split amounts == parent amount (no penny drift) | `test_invariants_property` (every step); `test_advanced_ledger::test_split_total_must_equal_transaction_total`; `test_targets`/entry validators |
| **I6** | Targets and pre-realization schedules change no conservation quantity | `test_invariants_property::test_targets_and_schedules_are_conservation_neutral`; `test_targets_contract::test_target_lifecycle_never_creates_or_moves_money`; `test_scheduled_transactions_contract::test_scheduled_items_do_not_touch_actuals_before_realization` |

### Account / category orthogonality
| Property | Enforced by |
|---|---|
| Account transfer changes location, not purpose; no income/spending | `test_advanced_ledger` transfer tests; I4 |
| Allocation move changes purpose, not account cash | `test_invariants_property` (move op keeps account balances; I3 holds) |
| Assigning money does not change account balances | `test_targets_contract` money-unchanged; `test_invariants_property` |
| Spending changes account + category activity; refunds reverse | `test_analytics` refund netting; `test_advanced_ledger` edit recalculation |

### Credit-card reserve conservation
| Property | Enforced by |
|---|---|
| Funded purchase reserves cash; payment is not a second expense | `test_credit_cards::test_funded_card_purchase_...` |
| Partially funded purchase raises debt without inventing reserve | `test_credit_cards::test_partially_funded_...` |
| Payment > reserve rejected (unfunded) | `test_credit_cards::test_partially_funded_...` (409) |
| Refund releases only the attributed reserve | `test_credit_cards::test_card_refund_...`, `test_refund_cannot_release_...` |
| **Payment reserve is explainable**: Visa Payment available == Σ reserve events + explicit allocations to it | `test_invariants_targeted::test_payment_reserve_is_explainable_from_reserve_events` |
| Editing/deleting a card purchase rebuilds the reserve exactly once | `test_credit_cards::test_editing_funded_card_purchase_...`, `test_deleting_funded_card_purchase_...` |

### Delegated authority conservation
| Property | Enforced by |
|---|---|
| Funding a pool moves authority, does not duplicate money | `test_invariants_property` (I1/I3 across delegated_authority op); `test_delegated_access` |
| Member reallocation preserves total controlled allocation == authority | `test_invariants_targeted::test_delegated_authority_conserved_across_member_reallocations` |
| Member cannot exceed the ceiling; cannot draw household RTA; cannot Smart-Fund | `test_delegated_access` (reallocation boundary, assign 403, smart-funding 403) |
| Approval funds once from an authorized source; partial approval can't double-spend | `test_delegated_access` (partial + double approval) |
| Reject/cancel then approve creates no money | `test_invariants_targeted::test_approve_after_reject_or_cancel_creates_no_money` |
| Scheduled future income / target metadata never expand authority | `test_scheduled_transactions_contract`; `test_targets_contract`; I6 |

### Actual vs forecast separation
| Property | Enforced by |
|---|---|
| Targets/scheduled future items don't change actual balances or RTA | I6; contract tests |
| Realizing a schedule runs the ordinary actual path exactly once | `test_scheduled_transactions_contract::test_realization_creates_exactly_one_transaction_and_advances` |
| Forecast operations don't mutate actual state | `test_planning`; `test_scheduled_transactions_contract` forecast tests |

### Month boundary
| Property | Enforced by |
|---|---|
| Positive Available rolls forward as carried, not as new cash; RTA is view-month-independent | `test_invariants_targeted::test_positive_rollover_carries_without_creating_current_cash` |
| Overspending / future-month semantics | `test_advanced_ledger`; assignment endpoint rejects future-month assignment (422) |
| Recurrence boundaries (Jan31→Feb, leap year, month-end, weekly, annual) | `test_scheduled_transactions_contract::test_recurrence_boundaries` |

### Reconciliation integrity
| Property | Enforced by |
|---|---|
| Reconcile without adjustment creates no money | `test_advanced_ledger` reconciliation suite |
| Adjustment is explicit, auditable, and requires household financial authority | `test_advanced_ledger::test_reconciliation_adjustment_is_an_explicit_auditable_transaction`, `test_reconciliation_rejects_stale_balance_and_restricted_adjustment` |
| Positive cash reconciliation becomes explicit real money; credit reconciliation doesn't create RTA | `test_advanced_ledger` positive/credit reconciliation tests |

### Request / approval race behavior
| Property | Enforced by |
|---|---|
| Double approve → exactly one winner (stale version 409) | `test_delegated_access::test_double_approval_...` |
| Approve after reject / after cancel → 409, no money | `test_invariants_targeted::test_approve_after_reject_or_cancel_creates_no_money` |
| Partial approval moves the existing allocation once | `test_delegated_access::test_partial_request_approval_...` |

### Scheduled realization race behavior
| Property | Enforced by |
|---|---|
| Repeated realize can't double-post (advance under row lock) | `test_scheduled_transactions_contract` (realize, once-schedule, not-due) |
| Permission revoked before realization blocks it | `test_scheduled_transactions_contract::test_realization_rechecks_scope_after_permission_revoked` |
| Deleted / deactivated / cross-budget denied | `test_scheduled_transactions_contract` auth tests |

## Known limitations
- **Concurrency is not proven under true parallelism.** The suite runs on SQLite single-threaded, so `SELECT … FOR UPDATE` row-lock behavior (realization, approval, delegated authority) is verified **deterministically** (advance-then-reject, stale-version 409) rather than with concurrent workers. The row locks provide the guarantee on PostgreSQL; a real concurrency harness would need a Postgres test fixture. This is a documented gap, not a proven guarantee.
- The property harness is owner-driven; delegated conservation is covered by dedicated deterministic tests rather than inside the random loop.
- Interest/fee entries are modeled as ordinary categorized/uncategorized transactions (no dedicated type), so they are covered by the generic income/expense invariants.

## Verdict
**INVARIANT SUITE STRONG WITH CAVEATS** — global money conservation, account/category orthogonality, credit-reserve explainability, delegated-authority conservation, actual-vs-forecast separation, month rollover, split exactness, reconciliation integrity, and approval terminal-state safety are all enforced, most after every step of seeded random sequences. The single caveat is that row-lock **concurrency** is proven deterministically, not under true Postgres parallelism.
