from time import monotonic

from app.models import Budget, Household, Membership, Payee, PayeeAlias, Transaction, TransactionChange, User
from app.security import create_access_token, hash_password

from .conftest import auth
from .test_budgeting_api import create_budget, create_budget_structure


def test_payee_identity_normalization_default_and_transaction_link(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    created = client.post(f"/api/v1/budgets/{budget['id']}/payees", headers=auth(owner_token), json={
        "display_name": "  Corner   Market  ", "default_category_id": category["id"],
    })
    assert created.status_code == 201
    payee = created.json()
    assert payee["display_name"] == "Corner Market"
    assert payee["default_category_id"] == category["id"]
    duplicate = client.post(f"/api/v1/budgets/{budget['id']}/payees", headers=auth(owner_token), json={
        "display_name": "corner market",
    })
    assert duplicate.status_code == 409

    transaction = client.post(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token), json={
        "account_id": account["id"], "category_id": category["id"], "payee_id": payee["id"],
        "payee_name": "client cannot spoof this", "amount_minor": -1234, "occurred_on": "2026-09-04",
    })
    assert transaction.status_code == 201
    assert transaction.json()["payee_id"] == payee["id"]
    assert transaction.json()["payee_name"] == "Corner Market"
    listed = client.get(f"/api/v1/budgets/{budget['id']}/payees", headers=auth(owner_token)).json()
    assert listed[0]["transaction_count"] == 1
    assert listed[0]["net_amount_minor"] == -1234


def test_free_text_transaction_resolves_or_creates_canonical_payee(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    created = client.post(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token), json={
        "account_id": account["id"], "category_id": category["id"], "payee_name": "  Metadata   test ",
        "amount_minor": -200, "occurred_on": "2026-09-15",
    })
    assert created.status_code == 201, created.text
    transaction = created.json()
    assert transaction["payee_id"] is not None
    assert transaction["payee_name"] == "Metadata test"
    with session_factory() as db:
        payee = db.get(Payee, transaction["payee_id"])
        assert payee.display_name == "Metadata test"
        db.add(PayeeAlias(payee_id=payee.id, display_name="QA merchant", name_key="qa merchant", created_by_user_id=payee.created_by_user_id))
        db.commit()
    via_alias = client.post(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token), json={
        "account_id": account["id"], "category_id": category["id"], "payee_name": "qa MERCHANT",
        "amount_minor": -100, "occurred_on": "2026-09-15",
    }).json()
    assert via_alias["payee_id"] == transaction["payee_id"]
    assert via_alias["payee_name"] == "Metadata test"


def test_payee_search_is_bounded_stable_alias_aware_and_paginated_at_household_scale(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    with session_factory() as db:
        household_id = db.get(Budget, budget["id"]).household_id
        owner_id = db.query(User.id).filter(User.email == "owner@example.com").scalar()
        values = [Payee(household_id=household_id, display_name=f"Merchant {index:05d}", name_key=f"merchant {index:05d}", created_by_user_id=owner_id) for index in range(10_000)]
        db.add_all(values); db.flush()
        db.add(PayeeAlias(payee_id=values[-1].id, display_name="Needle Alias", name_key="needle alias", created_by_user_id=owner_id))
        db.commit()
        alias_payee_id = values[-1].id
    started = monotonic()
    first = client.get(f"/api/v1/budgets/{budget['id']}/payees/search?limit=20", headers=auth(owner_token))
    assert monotonic() - started < 5.0
    assert first.status_code == 200, first.text
    assert len(first.json()["items"]) == 20
    assert first.json()["next_cursor"] is not None
    second = client.get(f"/api/v1/budgets/{budget['id']}/payees/search?limit=20&cursor={first.json()['next_cursor']}", headers=auth(owner_token))
    assert second.status_code == 200
    assert not ({item["id"] for item in first.json()["items"]} & {item["id"] for item in second.json()["items"]})
    alias = client.get(f"/api/v1/budgets/{budget['id']}/payees/search?q=needle&limit=20", headers=auth(owner_token)).json()
    assert [item["id"] for item in alias["items"]] == [alias_payee_id]
    assert alias["next_cursor"] is None
    invalid = client.get(f"/api/v1/budgets/{budget['id']}/payees/search?cursor=not-a-cursor", headers=auth(owner_token))
    assert invalid.status_code == 422


def test_payee_alias_rename_archive_and_merge_preserve_transaction_audit(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    source = client.post(f"/api/v1/budgets/{budget['id']}/payees", headers=auth(owner_token), json={"display_name": "Walmart Store"}).json()
    destination = client.post(f"/api/v1/budgets/{budget['id']}/payees", headers=auth(owner_token), json={"display_name": "Walmart"}).json()
    alias = client.post(f"/api/v1/budgets/{budget['id']}/payees/{source['id']}/aliases", headers=auth(owner_token), json={"display_name": "WM SUPERCENTER"})
    assert alias.status_code == 201
    transaction = client.post(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token), json={
        "account_id": account["id"], "category_id": category["id"], "payee_id": source["id"],
        "amount_minor": -2500, "occurred_on": "2026-09-04",
    }).json()
    renamed = client.put(f"/api/v1/budgets/{budget['id']}/payees/{source['id']}", headers=auth(owner_token), json={
        "display_name": "Walmart Store Renamed", "is_archived": False,
    })
    assert renamed.status_code == 200, renamed.text
    with session_factory() as db:
        row = db.get(Transaction, transaction["id"])
        assert row.payee_id == source["id"]
        assert row.payee_name == "Walmart Store Renamed"
        rename = db.query(TransactionChange).filter_by(transaction_id=transaction["id"], action="payee_renamed").one()
        assert '"payee_name": "Walmart Store"' in rename.before_json
    merged = client.post(f"/api/v1/budgets/{budget['id']}/payees/{source['id']}/merge", headers=auth(owner_token), json={"destination_payee_id": destination["id"]})
    assert merged.status_code == 200
    assert merged.json()["transaction_count"] == 1
    assert merged.json()["aliases"][0]["display_name"] == "WM SUPERCENTER"
    with session_factory() as db:
        row = db.get(Transaction, transaction["id"])
        assert row.payee_id == destination["id"]
        assert row.payee_name == "Walmart"
        source_row = db.get(Payee, source["id"])
        assert source_row.is_archived is True
        assert source_row.merged_into_payee_id == destination["id"]
        change = db.query(TransactionChange).filter_by(transaction_id=transaction["id"], action="payee_merged").one()
        assert change.actor_user_id is not None

    # The merged source name becomes an alias, so future typed transactions
    # continue to resolve to the destination rather than recreating a payee.
    via_merged_name = client.post(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token), json={
        "account_id": account["id"], "category_id": category["id"], "payee_name": "walmart store renamed",
        "amount_minor": -100, "occurred_on": "2026-09-15",
    })
    assert via_merged_name.status_code == 201, via_merged_name.text
    assert via_merged_name.json()["payee_id"] == destination["id"]


def test_payee_and_alias_names_share_one_deterministic_namespace(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    first = client.post(f"/api/v1/budgets/{budget['id']}/payees", headers=auth(owner_token), json={
        "display_name": "Corner Market",
    }).json()
    second = client.post(f"/api/v1/budgets/{budget['id']}/payees", headers=auth(owner_token), json={
        "display_name": "Neighborhood Shop",
    }).json()

    canonical_collision = client.post(
        f"/api/v1/budgets/{budget['id']}/payees/{second['id']}/aliases",
        headers=auth(owner_token), json={"display_name": " corner   market "},
    )
    assert canonical_collision.status_code == 409

    alias = client.post(
        f"/api/v1/budgets/{budget['id']}/payees/{first['id']}/aliases",
        headers=auth(owner_token), json={"display_name": "CM Store"},
    )
    assert alias.status_code == 201
    payee_collision = client.post(f"/api/v1/budgets/{budget['id']}/payees", headers=auth(owner_token), json={
        "display_name": "cm store",
    })
    assert payee_collision.status_code == 409
    rename_collision = client.put(
        f"/api/v1/budgets/{budget['id']}/payees/{second['id']}", headers=auth(owner_token),
        json={"display_name": "CM STORE", "is_archived": False},
    )
    assert rename_collision.status_code == 409


def test_merge_deduplicates_aliases_and_rejects_inactive_endpoints(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    source = client.post(f"/api/v1/budgets/{budget['id']}/payees", headers=auth(owner_token), json={"display_name": "Source Store"}).json()
    destination = client.post(f"/api/v1/budgets/{budget['id']}/payees", headers=auth(owner_token), json={"display_name": "Destination Store"}).json()
    assert client.post(
        f"/api/v1/budgets/{budget['id']}/payees/{source['id']}/aliases", headers=auth(owner_token),
        json={"display_name": "Legacy Source"},
    ).status_code == 201

    merged = client.post(
        f"/api/v1/budgets/{budget['id']}/payees/{source['id']}/merge", headers=auth(owner_token),
        json={"destination_payee_id": destination["id"]},
    )
    assert merged.status_code == 200, merged.text
    assert {item["display_name"] for item in merged.json()["aliases"]} == {"Legacy Source", "Source Store"}
    assert client.post(
        f"/api/v1/budgets/{budget['id']}/payees/{source['id']}/aliases", headers=auth(owner_token),
        json={"display_name": "Must Fail"},
    ).status_code == 409
    assert client.post(
        f"/api/v1/budgets/{budget['id']}/payees/{source['id']}/merge", headers=auth(owner_token),
        json={"destination_payee_id": destination["id"]},
    ).status_code == 409


def test_scoped_payee_search_does_not_disclose_alias_metadata(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, private_category = create_budget_structure(client, owner_token, budget["id"])
    group = client.post(f"/api/v1/budgets/{budget['id']}/category-groups", headers=auth(owner_token), json={
        "name": "Shared", "sort_order": 20,
    }).json()
    shared_category = client.post(f"/api/v1/budgets/{budget['id']}/categories", headers=auth(owner_token), json={
        "group_id": group["id"], "name": "Allowance", "sort_order": 10,
    }).json()
    payee = client.post(f"/api/v1/budgets/{budget['id']}/payees", headers=auth(owner_token), json={
        "display_name": "Visible Store",
    }).json()
    assert client.post(
        f"/api/v1/budgets/{budget['id']}/payees/{payee['id']}/aliases", headers=auth(owner_token),
        json={"display_name": "Private Household Alias"},
    ).status_code == 201
    assert client.post(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token), json={
        "account_id": account["id"], "category_id": shared_category["id"], "payee_id": payee["id"],
        "amount_minor": -100, "occurred_on": "2026-09-15",
    }).status_code == 201

    with session_factory() as db:
        household = db.query(Household).one()
        member = User(email="payee-privacy@example.com", display_name="Scoped", password_hash=hash_password("password long enough"))
        db.add(member); db.flush()
        db.add(Membership(household_id=household.id, user_id=member.id, role="child")); db.commit()
        member_id = member.id
    token = create_access_token(member_id, client.app.state.settings)
    assert client.put(f"/api/v1/budgets/{budget['id']}/grants", headers=auth(owner_token), json={
        "user_id": member_id, "permission": "view",
    }).status_code == 200
    assert client.put(f"/api/v1/budgets/{budget['id']}/access/{member_id}", headers=auth(owner_token), json={
        "capabilities": ["view_budget", "view_accounts", "view_categories", "view_transactions"],
        "restrict_accounts": True, "account_ids": [account["id"]],
        "restrict_categories": True, "category_ids": [shared_category["id"]],
    }).status_code == 200

    visible = client.get(f"/api/v1/budgets/{budget['id']}/payees/search?q=visible", headers=auth(token))
    assert visible.status_code == 200
    assert [item["display_name"] for item in visible.json()["items"]] == ["Visible Store"]
    assert visible.json()["items"][0]["aliases"] == []
    by_alias = client.get(f"/api/v1/budgets/{budget['id']}/payees/search?q=private", headers=auth(token))
    assert by_alias.status_code == 200
    assert by_alias.json() == {"items": [], "next_cursor": None}


def test_category_scoped_payees_exclude_uncategorized_income_and_private_defaults(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    root = f"/api/v1/budgets/{budget['id']}"
    group = client.post(f"{root}/category-groups", headers=auth(owner_token), json={"name": "Private"}).json()
    hidden = client.post(f"{root}/categories", headers=auth(owner_token), json={"group_id": group["id"], "name": "Private"}).json()
    visible_payee = client.post(f"{root}/payees", headers=auth(owner_token), json={
        "display_name": "Shared Merchant", "default_category_id": hidden["id"],
    }).json()
    private_payee = client.post(f"{root}/payees", headers=auth(owner_token), json={"display_name": "Private Salary"}).json()
    for payee, category_id, amount in [(visible_payee, category["id"], -100), (visible_payee, None, 50000), (private_payee, None, 90000)]:
        response = client.post(f"{root}/transactions", headers=auth(owner_token), json={
            "account_id": account["id"], "category_id": category_id, "payee_id": payee["id"],
            "amount_minor": amount, "occurred_on": "2026-09-15",
        })
        assert response.status_code == 201, response.text
    with session_factory() as db:
        household = db.query(Household).one()
        member = User(email="category-payee-scope@example.com", display_name="Scoped", password_hash=hash_password("password long enough"))
        db.add(member); db.flush()
        db.add(Membership(household_id=household.id, user_id=member.id, role="adult")); db.commit()
        member_id = member.id
    token = create_access_token(member_id, client.app.state.settings)
    assert client.put(f"{root}/grants", headers=auth(owner_token), json={"user_id": member_id, "permission": "view"}).status_code == 200
    assert client.put(f"{root}/access/{member_id}", headers=auth(owner_token), json={
        "capabilities": ["view_budget", "view_transactions"], "restrict_accounts": False, "account_ids": [],
        "restrict_categories": True, "category_ids": [category["id"]],
    }).status_code == 200
    transactions = client.get(f"{root}/transactions/search", headers=auth(token))
    assert transactions.status_code == 200
    assert transactions.json()["total_count"] == 1
    for path in ["payees/search", "payees"]:
        response = client.get(f"{root}/{path}", headers=auth(token))
        assert response.status_code == 200
        rows = response.json()["items"] if path.endswith("search") else response.json()
        assert [row["id"] for row in rows] == [visible_payee["id"]]
        assert rows[0]["transaction_count"] == 1
        assert rows[0]["net_amount_minor"] == -100
        assert rows[0]["default_category_id"] is None
    assert client.get(f"{root}/payees/search?q=Private", headers=auth(token)).json() == {"items": [], "next_cursor": None}
    owner_rows = client.get(f"{root}/payees/search", headers=auth(owner_token)).json()["items"]
    owner_payee = next(row for row in owner_rows if row["id"] == visible_payee["id"])
    assert owner_payee["transaction_count"] == 2
    assert owner_payee["net_amount_minor"] == 49900
    assert owner_payee["default_category_id"] == hidden["id"]


def test_free_text_does_not_resurrect_archived_payee(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account, category = create_budget_structure(client, owner_token, budget["id"])
    payee = client.post(f"/api/v1/budgets/{budget['id']}/payees", headers=auth(owner_token), json={
        "display_name": "Retired Merchant",
    }).json()
    assert client.post(
        f"/api/v1/budgets/{budget['id']}/payees/{payee['id']}/aliases", headers=auth(owner_token),
        json={"display_name": "Old Storefront"},
    ).status_code == 201
    archived = client.put(f"/api/v1/budgets/{budget['id']}/payees/{payee['id']}", headers=auth(owner_token), json={
        "display_name": "Retired Merchant", "is_archived": True,
    })
    assert archived.status_code == 200
    transaction = client.post(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token), json={
        "account_id": account["id"], "category_id": category["id"], "payee_name": "retired merchant",
        "amount_minor": -100, "occurred_on": "2026-09-15",
    })
    assert transaction.status_code == 422
    assert transaction.json()["detail"] == "Invalid payee"
    via_archived_alias = client.post(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token), json={
        "account_id": account["id"], "category_id": category["id"], "payee_name": "old storefront",
        "amount_minor": -100, "occurred_on": "2026-09-15",
    })
    assert via_archived_alias.status_code == 422
    assert via_archived_alias.json()["detail"] == "Invalid payee"


def test_system_transaction_names_do_not_require_payee_identity(client, owner_token, session_factory):
    budget = create_budget(client, owner_token, session_factory)
    account = client.post(f"/api/v1/budgets/{budget['id']}/accounts", headers=auth(owner_token), json={
        "name": "Checking", "account_type": "checking", "is_on_budget": True, "starting_balance_minor": 10000,
    }).json()
    transactions = client.get(f"/api/v1/budgets/{budget['id']}/transactions", headers=auth(owner_token)).json()
    assert transactions[0]["payee_name"] == "Starting Balance"
    assert transactions[0]["payee_id"] is None
    assert account["id"] == transactions[0]["account_id"]
