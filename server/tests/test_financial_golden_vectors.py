"""Provider-neutral financial operations executed against the server provider.

The JSON fixture contains product vocabulary only.  This module is the provider
adapter: endpoint paths, authentication, and database inspection stay here so a
future Deterministic or On-Device runner can consume the same vectors.
"""

from __future__ import annotations

import json
from datetime import date
from pathlib import Path

import pytest
from sqlalchemy import func, select

from app import budgeting_routes, planning_routes
from app.models import Account, AllocationOperation, AllocationPosting, CreditCardReserveEvent, Transaction, TransactionSplit

from .conftest import auth, freeze_today
from .test_budgeting_api import create_budget


VECTOR_PATH = Path(__file__).parent / "financial_vectors" / "v1.json"
VECTORS = json.loads(VECTOR_PATH.read_text(encoding="utf-8"))
PERIOD_VECTORS = json.loads((VECTOR_PATH.parent / "planning-periods-v1.json").read_text(encoding="utf-8"))


class ServerFinancialVectorRunner:
    """Thin translation from product operations to the current server contract."""

    def __init__(self, client, owner_token, session_factory, case_id: str):
        self.client = client
        self.headers = auth(owner_token)
        self.session_factory = session_factory
        self.budget = create_budget(client, owner_token, session_factory, name=f"Golden {case_id}")
        self.budget_id = self.budget["id"]
        self.accounts: dict[str, dict] = {}
        self.categories: dict[str, dict] = {}
        self.groups: dict[str, dict] = {}
        self.schedules: dict[str, dict] = {}
        self.transactions: dict[str, dict] = {}
        self.month = date.today().replace(day=1).isoformat()
        self.today = date.today().isoformat()

    def request(self, method: str, path: str, body: dict | None = None):
        response = getattr(self.client, method)(path, headers=self.headers, json=body)
        assert response.status_code < 300, response.text
        return response

    def execute(self, operation: dict) -> None:
        handler = getattr(self, f"op_{operation['op']}")
        handler(operation)

    def op_create_account(self, operation: dict) -> None:
        response = self.request("post", f"/api/v1/budgets/{self.budget_id}/accounts", {
            "name": operation["name"],
            "account_type": operation["kind"],
            "is_on_budget": operation["on_budget"],
            "starting_balance_minor": operation["opening_minor"],
        })
        self.accounts[operation["ref"]] = response.json()

    def op_create_category(self, operation: dict) -> None:
        group_name = operation["group"]
        if group_name not in self.groups:
            self.groups[group_name] = self.request(
                "post", f"/api/v1/budgets/{self.budget_id}/category-groups", {"name": group_name}
            ).json()
        response = self.request("post", f"/api/v1/budgets/{self.budget_id}/categories", {
            "group_id": self.groups[group_name]["id"], "name": operation["name"]
        })
        self.categories[operation["ref"]] = response.json()

    def op_assign(self, operation: dict) -> None:
        category_id = self.categories[operation["category"]]["id"]
        path = f"/api/v1/budgets/{self.budget_id}/categories/{category_id}/assignment"
        body = {"month": operation.get("month", self.month), "assigned_minor": operation["amount_minor"]}
        if operation.get("expected_error"):
            assert operation["expected_error"] == "insufficient_funds"
            before = self.financial_state()
            response = self.client.put(path, headers=self.headers, json=body)
            assert response.status_code == 409, response.text
            assert response.json()["detail"] == "Not enough real money to assign"
            assert self.financial_state() == before
        else:
            self.request("put", path, body)

    def op_move(self, operation: dict) -> None:
        self.request("post", f"/api/v1/budgets/{self.budget_id}/allocation-transfers", {
            "source_category_id": self.categories[operation["source"]]["id"],
            "destination_category_id": self.categories[operation["destination"]]["id"],
            "amount_minor": operation["amount_minor"], "occurred_on": operation.get("occurred_on", self.today),
        })

    def op_transaction(self, operation: dict) -> None:
        result = self.request("post", f"/api/v1/budgets/{self.budget_id}/transactions", self.transaction_body(operation)).json()
        if operation.get("ref"):
            self.transactions[operation["ref"]] = result

    def transaction_body(self, operation: dict) -> dict:
        body = {
            "account_id": self.accounts[operation["account"]]["id"],
            "amount_minor": operation["amount_minor"], "occurred_on": operation.get("occurred_on", self.today),
            "payee_name": f"Golden {operation['classification']}", "is_cleared": operation.get("cleared", True),
        }
        if operation.get("category"):
            body["category_id"] = self.categories[operation["category"]]["id"]
        if operation.get("splits"):
            body["splits"] = [
                {"category_id": self.categories[ref]["id"], "amount_minor": amount}
                for ref, amount in operation["splits"].items()
            ]
        return body

    def op_edit_transaction(self, operation: dict) -> None:
        transaction_id = self.transactions[operation["ref"]]["id"]
        self.transactions[operation["ref"]] = self.request(
            "put", f"/api/v1/budgets/{self.budget_id}/transactions/{transaction_id}", self.transaction_body(operation)
        ).json()

    def op_transfer(self, operation: dict) -> None:
        self.request("post", f"/api/v1/budgets/{self.budget_id}/transfers", {
            "source_account_id": self.accounts[operation["source"]]["id"],
            "destination_account_id": self.accounts[operation["destination"]]["id"],
            "amount_minor": operation["amount_minor"], "occurred_on": operation.get("occurred_on", self.today),
            "is_cleared": True,
        })

    def op_reconcile(self, operation: dict) -> None:
        account_id = self.accounts[operation["account"]]["id"]
        self.request("post", f"/api/v1/budgets/{self.budget_id}/accounts/{account_id}/reconcile", {
            "statement_balance_minor": operation["statement_minor"],
            "through_date": operation.get("through_date", self.today),
            "create_adjustment": operation["create_adjustment"],
            "adjustment_reason": "Golden vector explicit adjustment",
        })

    def op_schedule(self, operation: dict) -> None:
        body = {
            "account_id": self.accounts[operation["account"]]["id"],
            "amount_minor": operation["amount_minor"], "next_date": operation.get("next_date", self.today),
            "recurrence_unit": operation["recurrence"], "name": "Golden schedule",
        }
        if operation.get("category"):
            body["category_id"] = self.categories[operation["category"]]["id"]
        self.schedules[operation["ref"]] = self.request(
            "post", f"/api/v1/budgets/{self.budget_id}/scheduled-transactions", body
        ).json()

    def op_realize(self, operation: dict) -> None:
        schedule_id = self.schedules[operation["schedule"]]["id"]
        self.request("post", f"/api/v1/budgets/{self.budget_id}/scheduled-transactions/{schedule_id}/realize")

    def op_observe(self, operation: dict) -> None:
        before = self.financial_state()
        actual = self.observe(operation["expected"], operation.get("month", self.month))
        assert actual == operation["expected"]
        assert self.observe(operation["expected"], operation.get("month", self.month)) == actual
        assert self.financial_state() == before, "Reading/reloading planning periods must not post money"

    def financial_state(self) -> dict:
        with self.session_factory() as db:
            return {model.__tablename__: sorted(repr(tuple(row)) for row in db.execute(
                select(model.__table__)
            )) for model in (Account, AllocationOperation, AllocationPosting, Transaction, TransactionSplit, CreditCardReserveEvent)}

    def observe(self, expected: dict, month: str | None = None) -> dict:
        result: dict = {}
        month = month or self.month
        response = self.client.get(f"/api/v1/budgets/{self.budget_id}/months/{month}", headers=self.headers)
        assert response.status_code == 200, response.text
        summary = response.json()
        rows = {row["category_id"]: row for row in summary["categories"]}
        account_balances = {
            ref: self.client.get(
                f"/api/v1/budgets/{self.budget_id}/accounts/{account['id']}/balance", headers=self.headers
            ).json()
            for ref, account in self.accounts.items()
        }
        balances = {ref: value["working_balance_minor"] for ref, value in account_balances.items()}
        if "account_balances" in expected:
            result["account_balances"] = {ref: {key: account_balances[ref][key] for key in fields}
                                          for ref, fields in expected["account_balances"].items()}
        if "funding_limit_minor" in expected:
            response = self.client.get(f"/api/v1/budgets/{self.budget_id}/smart-funding/{month}", headers=self.headers)
            assert response.status_code == 200, response.text
            result["funding_limit_minor"] = response.json()["funding_limit_minor"]
        if "accounts" in expected:
            result["accounts"] = {ref: balances[ref] for ref in expected["accounts"]}
        if "unassigned_minor" in expected:
            result["unassigned_minor"] = summary["ready_to_assign_minor"]
        if "categories" in expected:
            result["categories"] = {}
            for ref, fields in expected["categories"].items():
                row = rows[self.categories[ref]["id"]]
                result["categories"][ref] = {field: row[field] for field in fields}
        if "total_budget_cash_minor" in expected:
            result["total_budget_cash_minor"] = sum(
                balances[ref] for ref, account in self.accounts.items()
                if account["is_on_budget"] and account["account_type"] in {"checking", "savings", "cash"}
            )
        if "net_worth_minor" in expected:
            result["net_worth_minor"] = sum(balances.values())
        if "cards" in expected:
            result["cards"] = {}
            for ref in expected["cards"]:
                account = self.accounts[ref]
                reserved = rows[account["payment_category_id"]]["available_minor"]
                liability = max(-balances[ref], 0)
                result["cards"][ref] = {
                    "liability_minor": liability,
                    "reserved_minor": reserved,
                    "unfunded_debt_minor": max(liability - reserved, 0),
                }
        if "transaction_count" in expected:
            result["transaction_count"] = len(self.client.get(
                f"/api/v1/budgets/{self.budget_id}/transactions", headers=self.headers
            ).json())
        if "allocation_postings_sum_minor" in expected:
            with self.session_factory() as db:
                result["allocation_postings_sum_minor"] = int(db.scalar(
                    select(func.coalesce(func.sum(AllocationPosting.amount_minor), 0)).where(
                        AllocationPosting.budget_id == self.budget_id
                    )
                ) or 0)
        return result


@pytest.mark.parametrize("vector", VECTORS["cases"], ids=lambda vector: vector["id"])
def test_server_provider_matches_financial_golden_vector(
    client, owner_token, session_factory, vector
):
    assert VECTORS["format_version"] == 1
    runner = ServerFinancialVectorRunner(client, owner_token, session_factory, vector["id"])
    for operation in vector["operations"]:
        runner.execute(operation)


def test_vector_money_values_are_exact_integer_minor_units():
    def visit(value):
        if isinstance(value, dict):
            for key, child in value.items():
                if key.endswith("_minor") and child is not None:
                    assert type(child) is int
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)

    visit(VECTORS)
    visit(PERIOD_VECTORS)


@pytest.mark.parametrize("vector", PERIOD_VECTORS["cases"], ids=lambda vector: vector["id"])
def test_server_provider_matches_persistent_month_vectors(client, owner_token, session_factory, monkeypatch, vector):
    assert PERIOD_VECTORS["format_version"] == 1
    freeze_today(monkeypatch, date.fromisoformat(vector["as_of"]), budgeting_routes, planning_routes)
    runner = ServerFinancialVectorRunner(client, owner_token, session_factory, vector["id"])
    runner.today = vector["as_of"]
    runner.month = vector["as_of"][:7] + "-01"
    for operation in vector["operations"]:
        runner.execute(operation)
