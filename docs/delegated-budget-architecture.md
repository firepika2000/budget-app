# Delegated-budget architecture

## Security boundary

Visibility and monetary authority are separate controls. A resource grant determines which accounts, categories, transactions, and reports a member may discover. A delegated policy determines how much real household money that member may allocate and which rules apply. Neither control implies the other.

The server is authoritative. SwiftUI filtering is only presentation and deterministic demo persona switching is only a review aid; it is not an authentication boundary.

## Money flow

Creating or increasing a delegated policy transfers an equal amount in the balanced allocation ledger from household Ready to Assign into the member's private pool category. This conserves total money. The member can move only pool money among categories delegated to that same identity, subject to category minimums, maximums, approval gates, category-creation policy, and optimistic allocation version checks.

Delegated members cannot use the ordinary assignment endpoint. Decreasing authority must be funded by the remaining pool balance, so already allocated or spent money cannot silently disappear. Revocation of resource access immediately prevents discovery independently of the policy balance.

## Requests and concurrency

Additional-allocation requests are state machines with immutable action rows. Approvers may approve fully or partially from an explicit source category, request changes, or reject. Both request versions and allocation versions are checked. Budget and policy rows are locked during authority changes; stale clients receive a conflict and must reload.

## Required invariant tests

The backend suite covers pool funding, conservation, global Ready-to-Assign isolation, direct-assignment bypass rejection, cross-member/category denial, insufficient authority, hard savings bounds, stale allocation versions, policy reduction with committed allocations, request state transitions, and restricted reconciliation adjustments.
