# Writing time-dependent tests

Some server logic anchors "now" on the real clock — most importantly the forecast
endpoint, which projects scheduled activity forward from `date.today()`, and the
planning-horizon validation that rejects a `through` date outside `[today, today + 366d]`.
A test that hard-codes calendar dates against that logic will pass or fail depending on
the day it runs. That is test-harness debt, not a product signal.

## Rule

**A test result must not depend on the real wall clock.** If an assertion compares against a
fixed calendar date, the "today" the server sees during that test must be pinned, not read
from the machine clock.

## How to pin the clock

Use the `freeze_today` helper in `server/tests/conftest.py`. It replaces `date.today()` in
the named app modules with a fixed value, while leaving real `date(...)` construction,
comparison, and arithmetic intact:

```python
from datetime import date
from app import planning_routes
from .conftest import auth, freeze_today

def test_forecast_window(client, owner_token, session_factory, monkeypatch):
    freeze_today(monkeypatch, date(2026, 9, 1), planning_routes)
    ...  # fixed next_date / through values now fall in a deterministic window
```

Pin to the reference the test's fixtures are written around (e.g. the start of the budget
month under test), not to some later arbitrary date. Moving a fixture forward to "unstick" a
test only postpones the same failure; pinning removes the dependency permanently.

Pass every app module whose `date.today()` the request path actually consults. Each such
module uses `from datetime import date`, so `freeze_today` patches that module-global symbol.
FastAPI resolves query/path parameter types (such as `through: date`) when the app is created,
so pinning the module symbol afterward affects only the runtime `date.today()` lookups, not
request parsing.

## When you do NOT need to pin

- **Fixtures relative to `date.today()`.** Deriving dates as `date.today() + timedelta(...)`
  and asserting relative outcomes (e.g. "projected == actual + inflow") is already
  wall-clock-independent. See `test_scheduled_transactions_contract.py`.
- **Past-dated fixtures that stay in the past.** A transaction `occurred_on: "2026-09-04"` is
  only validated as "not in the future"; once past, it stays valid as the calendar advances.
- **Assertions that never reach the clock.** For example, an authorization check that returns
  `403` before any horizon validation runs — the hard-coded `through` value is irrelevant.
- **Deliberately current-time behavior.** A test that sets `expires_at = now() - 1 minute` to
  prove expiry is relative to now by construction and is already deterministic.

Reserve pinning for the real hazard: a fixed calendar date compared against the server's live
"today". If unsure, ask whether the test would still pass a year from now with no code change.
If the answer depends on the date, pin the clock.
