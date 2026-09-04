from datetime import date, datetime, timezone
from enum import Enum
from typing import Optional
from uuid import uuid4

from sqlalchemy import BigInteger, Boolean, CheckConstraint, Date, DateTime, ForeignKey, Integer, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column, relationship

from .database import Base


def new_id() -> str:
    return str(uuid4())


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


class HouseholdRole(str, Enum):
    OWNER = "owner"
    ADULT = "adult"
    CHILD = "child"


class BudgetPermission(str, Enum):
    VIEW = "view"
    CONTRIBUTE = "contribute"
    MANAGE = "manage"


class SetupState(Base):
    __tablename__ = "setup_state"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    completed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now_utc)


class User(Base):
    __tablename__ = "users"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    email: Mapped[str] = mapped_column(String(320), unique=True, index=True)
    display_name: Mapped[str] = mapped_column(String(100))
    password_hash: Mapped[str] = mapped_column(String(512))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now_utc)


class RefreshSession(Base):
    __tablename__ = "refresh_sessions"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    token_hash: Mapped[str] = mapped_column(String(64), unique=True, index=True)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    revoked_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now_utc)


class Household(Base):
    __tablename__ = "households"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    name: Mapped[str] = mapped_column(String(100))
    owner_user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="RESTRICT"), index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now_utc)


class Membership(Base):
    __tablename__ = "memberships"
    __table_args__ = (UniqueConstraint("household_id", "user_id"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    household_id: Mapped[str] = mapped_column(ForeignKey("households.id", ondelete="CASCADE"), index=True)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    role: Mapped[str] = mapped_column(String(20))
    is_active: Mapped[bool] = mapped_column(Boolean, default=True)
    authorization_version: Mapped[int] = mapped_column(Integer, default=1)


class Invitation(Base):
    __tablename__ = "invitations"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    household_id: Mapped[str] = mapped_column(ForeignKey("households.id", ondelete="CASCADE"), index=True)
    email: Mapped[str] = mapped_column(String(320), index=True)
    role: Mapped[str] = mapped_column(String(20))
    token_hash: Mapped[str] = mapped_column(String(64), unique=True, index=True)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    accepted_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True), nullable=True)
    created_by_user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="RESTRICT"))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now_utc)


class Budget(Base):
    __tablename__ = "budgets"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    household_id: Mapped[str] = mapped_column(ForeignKey("households.id", ondelete="CASCADE"), index=True)
    name: Mapped[str] = mapped_column(String(100))
    currency_code: Mapped[str] = mapped_column(String(3))
    allocation_version: Mapped[int] = mapped_column(Integer, default=0)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now_utc)


class BudgetGrant(Base):
    __tablename__ = "budget_grants"
    __table_args__ = (UniqueConstraint("budget_id", "user_id"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    budget_id: Mapped[str] = mapped_column(ForeignKey("budgets.id", ondelete="CASCADE"), index=True)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    permission: Mapped[str] = mapped_column(String(20))


class BudgetAccessProfile(Base):
    __tablename__ = "budget_access_profiles"
    __table_args__ = (UniqueConstraint("budget_id", "user_id"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    budget_id: Mapped[str] = mapped_column(ForeignKey("budgets.id", ondelete="CASCADE"), index=True)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    restrict_accounts: Mapped[bool] = mapped_column(Boolean, default=False)
    restrict_categories: Mapped[bool] = mapped_column(Boolean, default=False)
    updated_by_user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="RESTRICT"))
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now_utc, onupdate=now_utc)


class CapabilityGrant(Base):
    __tablename__ = "capability_grants"
    __table_args__ = (UniqueConstraint("budget_id", "user_id", "capability"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    budget_id: Mapped[str] = mapped_column(ForeignKey("budgets.id", ondelete="CASCADE"), index=True)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    capability: Mapped[str] = mapped_column(String(50), index=True)


class ResourceGrant(Base):
    __tablename__ = "resource_grants"
    __table_args__ = (
        UniqueConstraint("budget_id", "user_id", "resource_type", "resource_id"),
        CheckConstraint("resource_type IN ('account', 'category')", name="ck_resource_grant_type"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    budget_id: Mapped[str] = mapped_column(ForeignKey("budgets.id", ondelete="CASCADE"), index=True)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    resource_type: Mapped[str] = mapped_column(String(20), index=True)
    resource_id: Mapped[str] = mapped_column(String(36), index=True)


class Account(Base):
    __tablename__ = "accounts"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    budget_id: Mapped[str] = mapped_column(ForeignKey("budgets.id", ondelete="CASCADE"), index=True)
    name: Mapped[str] = mapped_column(String(100))
    account_type: Mapped[str] = mapped_column(String(30))
    is_on_budget: Mapped[bool] = mapped_column(Boolean, default=True)
    is_closed: Mapped[bool] = mapped_column(Boolean, default=False)
    payment_category_id: Mapped[Optional[str]] = mapped_column(
        ForeignKey("categories.id", ondelete="RESTRICT", use_alter=True),
        nullable=True,
        unique=True,
    )
    reconciled_balance_minor: Mapped[Optional[int]] = mapped_column(BigInteger, nullable=True)
    reconciled_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now_utc)


class CategoryGroup(Base):
    __tablename__ = "category_groups"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    budget_id: Mapped[str] = mapped_column(ForeignKey("budgets.id", ondelete="CASCADE"), index=True)
    name: Mapped[str] = mapped_column(String(100))
    sort_order: Mapped[int] = mapped_column(Integer, default=0)


class Category(Base):
    __tablename__ = "categories"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    budget_id: Mapped[str] = mapped_column(ForeignKey("budgets.id", ondelete="CASCADE"), index=True)
    group_id: Mapped[str] = mapped_column(ForeignKey("category_groups.id", ondelete="CASCADE"), index=True)
    name: Mapped[str] = mapped_column(String(100))
    sort_order: Mapped[int] = mapped_column(Integer, default=0)
    is_archived: Mapped[bool] = mapped_column(Boolean, default=False)
    system_type: Mapped[Optional[str]] = mapped_column(String(30), nullable=True)
    linked_account_id: Mapped[Optional[str]] = mapped_column(String(36), nullable=True, unique=True)
    delegated_user_id: Mapped[Optional[str]] = mapped_column(
        ForeignKey("users.id", ondelete="RESTRICT"), index=True, nullable=True
    )


class CategoryTarget(Base):
    __tablename__ = "category_targets"
    __table_args__ = (
        UniqueConstraint("category_id"),
        CheckConstraint("target_amount_minor > 0", name="ck_category_target_amount_positive"),
        CheckConstraint(
            "minimum_contribution_minor >= 0",
            name="ck_category_target_minimum_nonnegative",
        ),
        CheckConstraint("priority >= 0 AND priority <= 100", name="ck_category_target_priority_range"),
        CheckConstraint(
            "recurrence_months IS NULL OR recurrence_months > 0",
            name="ck_category_target_recurrence_positive",
        ),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    budget_id: Mapped[str] = mapped_column(ForeignKey("budgets.id", ondelete="CASCADE"), index=True)
    category_id: Mapped[str] = mapped_column(ForeignKey("categories.id", ondelete="CASCADE"), index=True)
    target_type: Mapped[str] = mapped_column(String(30))
    target_amount_minor: Mapped[int] = mapped_column(BigInteger)
    target_date: Mapped[Optional[date]] = mapped_column(Date, nullable=True)
    recurrence_months: Mapped[Optional[int]] = mapped_column(Integer, nullable=True)
    minimum_contribution_minor: Mapped[int] = mapped_column(BigInteger, default=0)
    priority: Mapped[int] = mapped_column(Integer, default=50)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True)
    created_by_user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="RESTRICT"))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now_utc)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now_utc, onupdate=now_utc)


class ScheduledTransaction(Base):
    __tablename__ = "scheduled_transactions"
    __table_args__ = (
        CheckConstraint("interval_count > 0", name="ck_scheduled_interval_positive"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    budget_id: Mapped[str] = mapped_column(ForeignKey("budgets.id", ondelete="CASCADE"), index=True)
    account_id: Mapped[str] = mapped_column(ForeignKey("accounts.id", ondelete="RESTRICT"), index=True)
    destination_account_id: Mapped[Optional[str]] = mapped_column(
        ForeignKey("accounts.id", ondelete="RESTRICT"), index=True, nullable=True
    )
    category_id: Mapped[Optional[str]] = mapped_column(
        ForeignKey("categories.id", ondelete="RESTRICT"), index=True, nullable=True
    )
    name: Mapped[str] = mapped_column(String(150))
    amount_minor: Mapped[int] = mapped_column(BigInteger)
    next_date: Mapped[date] = mapped_column(Date, index=True)
    recurrence_unit: Mapped[str] = mapped_column(String(20))
    interval_count: Mapped[int] = mapped_column(Integer, default=1)
    memo: Mapped[str] = mapped_column(String(500), default="")
    is_active: Mapped[bool] = mapped_column(Boolean, default=True)
    created_by_user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="RESTRICT"))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now_utc)


class MonthlyAssignment(Base):
    __tablename__ = "monthly_assignments"
    __table_args__ = (UniqueConstraint("category_id", "month"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    budget_id: Mapped[str] = mapped_column(ForeignKey("budgets.id", ondelete="CASCADE"), index=True)
    category_id: Mapped[str] = mapped_column(ForeignKey("categories.id", ondelete="CASCADE"), index=True)
    month: Mapped[date] = mapped_column(Date)
    assigned_minor: Mapped[int] = mapped_column(BigInteger)


class AllocationOperation(Base):
    __tablename__ = "allocation_operations"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    budget_id: Mapped[str] = mapped_column(ForeignKey("budgets.id", ondelete="CASCADE"), index=True)
    occurred_on: Mapped[date] = mapped_column(Date, index=True)
    kind: Mapped[str] = mapped_column(String(30), index=True)
    actor_user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="RESTRICT"), index=True)
    note: Mapped[str] = mapped_column(String(500), default="")
    source: Mapped[str] = mapped_column(String(30), default="manual")
    reversal_of_id: Mapped[Optional[str]] = mapped_column(
        ForeignKey("allocation_operations.id", ondelete="RESTRICT"), nullable=True, unique=True
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now_utc)
    postings: Mapped[list["AllocationPosting"]] = relationship(
        back_populates="operation",
        cascade="all, delete-orphan",
        lazy="selectin",
    )


class AllocationPosting(Base):
    __tablename__ = "allocation_postings"
    __table_args__ = (
        CheckConstraint(
            "(bucket = 'category' AND category_id IS NOT NULL) OR "
            "(bucket = 'ready_to_assign' AND category_id IS NULL)",
            name="ck_allocation_posting_bucket_category",
        ),
        CheckConstraint("amount_minor <> 0", name="ck_allocation_posting_nonzero"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    operation_id: Mapped[str] = mapped_column(
        ForeignKey("allocation_operations.id", ondelete="CASCADE"), index=True
    )
    budget_id: Mapped[str] = mapped_column(ForeignKey("budgets.id", ondelete="CASCADE"), index=True)
    bucket: Mapped[str] = mapped_column(String(30))
    category_id: Mapped[Optional[str]] = mapped_column(
        ForeignKey("categories.id", ondelete="RESTRICT"), index=True, nullable=True
    )
    amount_minor: Mapped[int] = mapped_column(BigInteger)
    operation: Mapped[AllocationOperation] = relationship(back_populates="postings")


class Transaction(Base):
    __tablename__ = "transactions"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    budget_id: Mapped[str] = mapped_column(ForeignKey("budgets.id", ondelete="CASCADE"), index=True)
    account_id: Mapped[str] = mapped_column(ForeignKey("accounts.id", ondelete="RESTRICT"), index=True)
    category_id: Mapped[Optional[str]] = mapped_column(ForeignKey("categories.id", ondelete="RESTRICT"), index=True, nullable=True)
    transfer_id: Mapped[Optional[str]] = mapped_column(String(36), index=True, nullable=True)
    amount_minor: Mapped[int] = mapped_column(BigInteger)
    occurred_on: Mapped[date] = mapped_column(Date, index=True)
    payee_name: Mapped[str] = mapped_column(String(150), default="")
    memo: Mapped[str] = mapped_column(String(500), default="")
    is_cleared: Mapped[bool] = mapped_column(Boolean, default=False)
    is_reconciled: Mapped[bool] = mapped_column(Boolean, default=False)
    created_by_user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="RESTRICT"), index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now_utc)
    splits: Mapped[list["TransactionSplit"]] = relationship(
        back_populates="transaction",
        cascade="all, delete-orphan",
        lazy="selectin",
    )


class TransactionSplit(Base):
    __tablename__ = "transaction_splits"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    transaction_id: Mapped[str] = mapped_column(ForeignKey("transactions.id", ondelete="CASCADE"), index=True)
    category_id: Mapped[str] = mapped_column(ForeignKey("categories.id", ondelete="RESTRICT"), index=True)
    amount_minor: Mapped[int] = mapped_column(BigInteger)
    memo: Mapped[str] = mapped_column(String(500), default="")
    transaction: Mapped[Transaction] = relationship(back_populates="splits")


class CreditCardReserveEvent(Base):
    __tablename__ = "credit_card_reserve_events"
    __table_args__ = (
        CheckConstraint("amount_minor <> 0", name="ck_credit_reserve_event_nonzero"),
        CheckConstraint(
            "(source_transaction_id IS NOT NULL AND transfer_id IS NULL) OR "
            "(source_transaction_id IS NULL AND transfer_id IS NOT NULL)",
            name="ck_credit_reserve_event_source",
        ),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    budget_id: Mapped[str] = mapped_column(ForeignKey("budgets.id", ondelete="CASCADE"), index=True)
    credit_account_id: Mapped[str] = mapped_column(ForeignKey("accounts.id", ondelete="RESTRICT"), index=True)
    payment_category_id: Mapped[str] = mapped_column(ForeignKey("categories.id", ondelete="RESTRICT"), index=True)
    source_transaction_id: Mapped[Optional[str]] = mapped_column(
        ForeignKey("transactions.id", ondelete="RESTRICT"), index=True, nullable=True
    )
    transfer_id: Mapped[Optional[str]] = mapped_column(String(36), index=True, nullable=True)
    occurred_on: Mapped[date] = mapped_column(Date, index=True)
    amount_minor: Mapped[int] = mapped_column(BigInteger)
    kind: Mapped[str] = mapped_column(String(30))
    actor_user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="RESTRICT"), index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now_utc)


class FinancialRequest(Base):
    __tablename__ = "financial_requests"
    __table_args__ = (
        CheckConstraint("requested_amount_minor > 0", name="ck_financial_request_amount_positive"),
        CheckConstraint(
            "approved_amount_minor IS NULL OR approved_amount_minor >= 0",
            name="ck_financial_request_approved_nonnegative",
        ),
        CheckConstraint(
            "status IN ('pending', 'approved', 'partially_approved', 'rejected', "
            "'changes_requested', 'cancelled', 'expired')",
            name="ck_financial_request_status",
        ),
        CheckConstraint(
            "(status IN ('approved', 'partially_approved') AND approved_amount_minor IS NOT NULL "
            "AND source_category_id IS NOT NULL AND allocation_operation_id IS NOT NULL) OR "
            "(status NOT IN ('approved', 'partially_approved') AND allocation_operation_id IS NULL)",
            name="ck_financial_request_approval_link",
        ),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    household_id: Mapped[str] = mapped_column(ForeignKey("households.id", ondelete="CASCADE"), index=True)
    budget_id: Mapped[str] = mapped_column(ForeignKey("budgets.id", ondelete="CASCADE"), index=True)
    requester_user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="RESTRICT"), index=True)
    request_type: Mapped[str] = mapped_column(String(40), default="additional_allocation")
    destination_category_id: Mapped[str] = mapped_column(ForeignKey("categories.id", ondelete="RESTRICT"), index=True)
    requested_amount_minor: Mapped[int] = mapped_column(BigInteger)
    reason: Mapped[str] = mapped_column(String(500), default="")
    status: Mapped[str] = mapped_column(String(30), default="pending", index=True)
    version: Mapped[int] = mapped_column(Integer, default=0)
    approved_amount_minor: Mapped[Optional[int]] = mapped_column(BigInteger, nullable=True)
    source_category_id: Mapped[Optional[str]] = mapped_column(
        ForeignKey("categories.id", ondelete="RESTRICT"), index=True, nullable=True
    )
    allocation_operation_id: Mapped[Optional[str]] = mapped_column(
        ForeignKey("allocation_operations.id", ondelete="RESTRICT"), unique=True, nullable=True
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now_utc)
    resolved_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True), nullable=True)


class RequestAction(Base):
    __tablename__ = "request_actions"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    request_id: Mapped[str] = mapped_column(ForeignKey("financial_requests.id", ondelete="CASCADE"), index=True)
    actor_user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="RESTRICT"), index=True)
    action: Mapped[str] = mapped_column(String(30), index=True)
    amount_minor: Mapped[Optional[int]] = mapped_column(BigInteger, nullable=True)
    note: Mapped[str] = mapped_column(String(500), default="")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now_utc)
