# Budget App

A self-hostable, zero-based budgeting system with a native iPhone client and privacy-aware family sub-budgets.

## Current status

The repository contains the first two domain slices:

- Strongly typed household and budget identities with deny-by-default authorization.
- Exact minor-unit money arithmetic and zero-based monthly budget calculations.

Product and architecture decisions are recorded in `docs/`.

## Run the tests

```sh
swift test
```

## Read next

- [Product brief](docs/product-brief.md)
- [Architecture direction](docs/architecture.md)

## Near-term milestone

Build the versioned server API and PostgreSQL schema around the tested access and calculation rules, then connect a small SwiftUI client that can configure a server, sign in, and list only the budgets shared with the current user.
