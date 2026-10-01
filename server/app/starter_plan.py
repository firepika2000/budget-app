"""Canonical zero-money Plan structure installed for genuinely new budgets."""

from sqlalchemy.orm import Session

from .category_names import normalized_category_name
from .models import Category, CategoryGroup


STARTER_PLAN: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("Monthly Bills", ("Housing", "Utilities", "Phone & Internet")),
    ("Everyday Spending", ("Groceries", "Transportation", "Dining & Fun")),
    ("True Expenses", ("Medical", "Home & Car Maintenance", "Annual Bills")),
    ("Goals", ("Emergency Fund", "Savings Goals")),
)


def install_starter_plan(db: Session, budget_id: str) -> None:
    """Add organization only: no assignments, targets, accounts, or transactions."""
    for group_index, (group_name, category_names) in enumerate(STARTER_PLAN):
        group = CategoryGroup(
            budget_id=budget_id,
            name=group_name,
            sort_order=(group_index + 1) * 100,
        )
        db.add(group)
        db.flush()
        for category_index, category_name in enumerate(category_names):
            db.add(Category(
                budget_id=budget_id,
                group_id=group.id,
                name=category_name,
                name_key=normalized_category_name(category_name),
                sort_order=(category_index + 1) * 100,
            ))
