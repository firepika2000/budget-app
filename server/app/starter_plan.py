"""Canonical zero-money Plan structure installed for genuinely new budgets."""

from sqlalchemy.orm import Session

from .category_names import normalized_category_name
from .models import BudgetStructureRevision, Category, CategoryGroup


STARTER_PLAN: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("Monthly Bills", ("Housing", "Utilities", "Phone & Internet")),
    ("Everyday Spending", ("Groceries", "Transportation", "Dining & Fun")),
    ("True Expenses", ("Medical", "Home & Car Maintenance", "Annual Bills")),
    ("Goals", ("Emergency Fund", "Savings Goals")),
)


def install_starter_plan(db: Session, budget_id: str, actor_user_id: str) -> None:
    """Add organization only: no assignments, targets, accounts, or transactions."""
    for group_index, (group_name, category_names) in enumerate(STARTER_PLAN):
        group = CategoryGroup(
            budget_id=budget_id,
            name=group_name,
            sort_order=(group_index + 1) * 100,
        )
        db.add(group)
        db.flush()
        db.add(BudgetStructureRevision(
            budget_id=budget_id, resource_type="category_group", resource_id=group.id,
            action="created", actor_user_id=actor_user_id, before_snapshot=None,
            after_snapshot={"name": group.name, "sort_order": group.sort_order, "is_archived": False},
        ))
        for category_index, category_name in enumerate(category_names):
            category = Category(
                budget_id=budget_id,
                group_id=group.id,
                name=category_name,
                name_key=normalized_category_name(category_name),
                sort_order=(category_index + 1) * 100,
            )
            db.add(category)
            db.flush()
            db.add(BudgetStructureRevision(
                budget_id=budget_id, resource_type="category", resource_id=category.id,
                action="created", actor_user_id=actor_user_id, before_snapshot=None,
                after_snapshot={
                    "group_id": category.group_id, "name": category.name, "icon_name": None,
                    "note": "", "sort_order": category.sort_order, "is_archived": False,
                    "is_essential": False, "is_emergency_fund": False,
                    "delegated_user_id": None,
                },
            ))
