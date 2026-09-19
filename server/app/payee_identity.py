from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from .models import Budget, Payee, PayeeAlias, User
from .payee_names import display_payee_name, normalized_payee_name


def resolve_payee(
    db: Session,
    *,
    budget: Budget,
    user: User,
    payee_id: str | None,
    payee_name: str,
    create: bool,
) -> tuple[str | None, str]:
    """Resolve text to one active household payee, optionally creating it."""
    name = display_payee_name(payee_name)
    if payee_id is not None:
        payee = db.scalar(select(Payee).where(
            Payee.id == payee_id,
            Payee.household_id == budget.household_id,
            Payee.is_archived.is_(False),
            Payee.merged_into_payee_id.is_(None),
        ))
        if payee is None:
            raise ValueError("Invalid payee")
        return payee.id, payee.display_name
    if not name:
        return None, ""

    key = normalized_payee_name(name)
    payee = db.scalar(select(Payee).where(
        Payee.household_id == budget.household_id,
        Payee.name_key == key,
        Payee.is_archived.is_(False),
        Payee.merged_into_payee_id.is_(None),
    ))
    if payee is None:
        payee = db.scalar(select(Payee).join(PayeeAlias, PayeeAlias.payee_id == Payee.id).where(
            Payee.household_id == budget.household_id,
            PayeeAlias.name_key == key,
            Payee.is_archived.is_(False),
            Payee.merged_into_payee_id.is_(None),
        ))
    if payee is not None:
        return payee.id, payee.display_name

    # Archived identities retain their uniqueness key. Do not let free text
    # silently resurrect them or surface an internal uniqueness failure.
    unavailable = db.scalar(select(Payee.id).where(
        Payee.household_id == budget.household_id,
        Payee.name_key == key,
    ))
    unavailable_alias = db.scalar(select(PayeeAlias.id).join(
        Payee, Payee.id == PayeeAlias.payee_id,
    ).where(
        Payee.household_id == budget.household_id,
        PayeeAlias.name_key == key,
    ))
    if unavailable is not None or unavailable_alias is not None:
        raise ValueError("Payee is archived or merged")

    if not create:
        return None, name

    # sqlite3 legacy mode does not BEGIN for reads or SAVEPOINT. Releasing
    # the first savepoint otherwise commits the payee outside caller rollback.
    connection = db.connection()
    if connection.dialect.name == "sqlite" and not connection.connection.driver_connection.in_transaction:
        connection.exec_driver_sql("BEGIN")
    try:
        with db.begin_nested():
            payee = Payee(
                household_id=budget.household_id,
                display_name=name,
                name_key=key,
                created_by_user_id=user.id,
            )
            db.add(payee)
            db.flush()
    except IntegrityError:
        payee = db.scalar(select(Payee).where(
            Payee.household_id == budget.household_id,
            Payee.name_key == key,
            Payee.is_archived.is_(False),
            Payee.merged_into_payee_id.is_(None),
        ))
        if payee is None:
            raise
    return payee.id, payee.display_name


def resolve_or_create_payee(
    db: Session,
    *,
    budget: Budget,
    user: User,
    payee_id: str | None,
    payee_name: str,
) -> tuple[str | None, str]:
    """Resolve transaction text to one active household payee, creating it when necessary."""
    return resolve_payee(
        db,
        budget=budget,
        user=user,
        payee_id=payee_id,
        payee_name=payee_name,
        create=True,
    )
