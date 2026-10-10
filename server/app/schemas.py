from datetime import date, datetime
from typing import Annotated, Literal, Optional
import hashlib
import json
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, computed_field, field_validator, model_validator


MIN_INT64 = -(2**63)
MAX_INT64 = 2**63 - 1
TransactionRevision = Annotated[str, Field(pattern=r"^v1:[0-9a-f]{64}$")]


class BootstrapRequest(BaseModel):
    email: str = Field(min_length=3, max_length=320)
    password: str = Field(min_length=12, max_length=256)
    display_name: str = Field(min_length=1, max_length=100)
    household_name: str = Field(min_length=1, max_length=100)

    @field_validator("email")
    @classmethod
    def normalize_email(cls, value: str) -> str:
        normalized = value.strip().lower()
        if "@" not in normalized:
            raise ValueError("must be an email address")
        return normalized


class LoginRequest(BaseModel):
    email: str
    password: str
    device_name: Optional[str] = Field(default=None, min_length=1, max_length=80)


class TokenResponse(BaseModel):
    access_token: str
    refresh_token: str
    token_type: Literal["bearer"] = "bearer"


class BootstrapStatusResponse(BaseModel):
    """Safe, unauthenticated server-state discovery. Exposes no users, households, or secrets."""

    initialized: bool
    authentication_required: bool
    api_version: str


class RefreshRequest(BaseModel):
    refresh_token: str = Field(min_length=40, max_length=200)


class PairingCodeResponse(BaseModel):
    code: str
    server_url: str
    expires_at: datetime


class PairingRedeemRequest(BaseModel):
    code: str = Field(min_length=40, max_length=200)
    device_name: str = Field(min_length=1, max_length=80)

    @field_validator("device_name")
    @classmethod
    def normalize_device_name(cls, value: str) -> str:
        normalized = value.strip()
        if not normalized:
            raise ValueError("device name cannot be blank")
        return normalized


class DeviceSessionResponse(BaseModel):
    id: str
    device_name: str
    created_at: datetime
    expires_at: datetime


class BudgetCreate(BaseModel):
    household_id: str
    name: str = Field(min_length=1, max_length=100)
    currency_code: str = Field(min_length=3, max_length=3)
    # Omission preserves older clients' legacy carry behavior. New clients send an explicit choice.
    cash_rollover_policy: Optional[Literal["absorb_next_month", "carry_category_deficit"]] = None
    # Production clients receive an editable zero-money starter Plan. Test/import callers may
    # explicitly opt out when constructing an already-defined budget structure.
    starter_template: bool = True

    @field_validator("currency_code")
    @classmethod
    def normalize_currency(cls, value: str) -> str:
        return value.upper()


class BudgetDeleteConfirmation(BaseModel):
    confirmation_name: str = Field(min_length=1, max_length=100)


CapabilityName = Literal[
    "view_budget", "view_budget_totals", "view_accounts", "view_account_balances", "view_categories", "view_transactions", "view_reports", "view_allocation_history",
    "create_transaction", "edit_transaction", "delete_transaction", "request_money", "assign_money", "move_money", "manage_own_categories", "reconcile_account",
    "manage_budget_structure", "manage_payees", "manage_planning", "manage_allowances", "approve_request", "export_data",
]


class BudgetResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    household_id: str
    name: str
    currency_code: str
    effective_permission: Literal["view", "contribute", "manage", "owner"]
    allocation_version: int
    capabilities: list[CapabilityName]
    access_revision: Optional[str] = None


class GrantUpsert(BaseModel):
    user_id: str
    permission: Literal["view", "contribute", "manage"]


class GrantResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    budget_id: str
    user_id: str
    permission: str


class AccessProfileUpsert(BaseModel):
    capabilities: list[CapabilityName]
    restrict_accounts: bool = False
    account_ids: list[str] = Field(default_factory=list)
    restrict_categories: bool = False
    category_ids: list[str] = Field(default_factory=list)
    expected_version: Optional[int] = Field(default=None, ge=0)

    @model_validator(mode="after")
    def require_scope_flags(self) -> "AccessProfileUpsert":
        if self.account_ids and not self.restrict_accounts:
            raise ValueError("account_ids require restrict_accounts")
        if self.category_ids and not self.restrict_categories:
            raise ValueError("category_ids require restrict_categories")
        if len(self.capabilities) != len(set(self.capabilities)):
            raise ValueError("capabilities must be unique")
        if len(self.account_ids) != len(set(self.account_ids)):
            raise ValueError("account_ids must be unique")
        if len(self.category_ids) != len(set(self.category_ids)):
            raise ValueError("category_ids must be unique")
        return self


class AccessProfileResponse(AccessProfileUpsert):
    budget_id: str
    user_id: str
    grant_permission: Literal["view", "contribute", "manage"]
    is_custom: bool
    version: int
    updated_by_user_id: Optional[str] = None
    updated_by_display_name: Optional[str] = None
    updated_at: Optional[datetime] = None


class AccountCreate(BaseModel):
    name: str = Field(min_length=1, max_length=100)
    account_type: Literal["checking", "savings", "cash", "credit", "loan", "mortgage", "asset", "tracking"]
    is_on_budget: bool = True
    starting_balance_minor: int = Field(default=0, ge=MIN_INT64, le=MAX_INT64)


class AccountUpdate(BaseModel):
    name: str = Field(min_length=1, max_length=100)
    account_type: Literal["checking", "savings", "cash", "credit", "loan", "mortgage", "asset", "tracking"]
    is_closed: Optional[bool] = None


class AccountResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    budget_id: str
    name: str
    account_type: str
    is_on_budget: bool
    is_closed: bool
    reconciled_balance_minor: Optional[int]
    payment_category_id: Optional[str]


class AccountRevisionResponse(BaseModel):
    id: str
    account_id: str
    action: Literal["created", "updated"]
    actor_user_id: str
    actor_display_name: Optional[str] = None
    before_snapshot: Optional[dict] = None
    after_snapshot: dict
    created_at: datetime


class AccountBalanceResponse(BaseModel):
    account_id: str
    currency_code: str
    cleared_balance_minor: int
    uncleared_balance_minor: int
    working_balance_minor: int
    reconciled_balance_minor: Optional[int]
    through_date: Optional[date] = None


class AccountDebtTermsUpsert(BaseModel):
    terms_type: Literal["credit_card", "installment_loan"]
    annual_rate_basis_points: Optional[int] = Field(default=None, ge=0, le=100_000)
    rate_type: Optional[Literal["fixed", "variable"]] = None
    payment_frequency: Optional[Literal["weekly", "biweekly", "monthly"]] = None
    scheduled_payment_minor: Optional[int] = Field(default=None, ge=0, le=MAX_INT64)
    minimum_payment_rule: Optional[Literal["fixed", "percentage", "greater_of"]] = None
    minimum_payment_minor: Optional[int] = Field(default=None, ge=0, le=MAX_INT64)
    minimum_payment_rate_basis_points: Optional[int] = Field(default=None, ge=0, le=10_000)
    due_day: Optional[int] = Field(default=None, ge=1, le=31)
    statement_day: Optional[int] = Field(default=None, ge=1, le=31)
    original_principal_minor: Optional[int] = Field(default=None, ge=0, le=MAX_INT64)
    original_term_months: Optional[int] = Field(default=None, ge=1, le=1_200)
    remaining_term_months: Optional[int] = Field(default=None, ge=0, le=1_200)
    promotional_rate_basis_points: Optional[int] = Field(default=None, ge=0, le=100_000)
    promotional_ends_on: Optional[date] = None

    @model_validator(mode="after")
    def validate_type_specific_terms(self):
        if self.terms_type == "credit_card":
            if any(value is not None for value in (
                self.scheduled_payment_minor, self.original_principal_minor,
                self.original_term_months, self.remaining_term_months,
            )):
                raise ValueError("credit-card terms cannot contain installment-loan fields")
            if self.payment_frequency not in (None, "monthly"):
                raise ValueError("credit-card payment frequency must be monthly")
            if self.minimum_payment_rule == "fixed" and self.minimum_payment_minor is None:
                raise ValueError("fixed minimum payment requires minimum_payment_minor")
            if self.minimum_payment_rule == "percentage" and self.minimum_payment_rate_basis_points is None:
                raise ValueError("percentage minimum payment requires minimum_payment_rate_basis_points")
            if self.minimum_payment_rule == "greater_of" and (
                self.minimum_payment_minor is None or self.minimum_payment_rate_basis_points is None
            ):
                raise ValueError("greater_of requires both minimum payment inputs")
        elif any(value is not None for value in (
            self.minimum_payment_rule, self.minimum_payment_minor,
            self.minimum_payment_rate_basis_points, self.statement_day,
            self.promotional_rate_basis_points, self.promotional_ends_on,
        )):
            raise ValueError("installment-loan terms cannot contain credit-card fields")
        return self


class AccountDebtTermsResponse(AccountDebtTermsUpsert):
    account_id: str
    budget_id: str
    projection_ready: bool
    missing_projection_fields: list[str]
    updated_at: datetime


class AccountDebtTermsRevisionResponse(BaseModel):
    id: str
    account_id: str
    action: Literal["created", "updated", "deleted"]
    actor_user_id: str
    actor_display_name: Optional[str] = None
    before_snapshot: Optional[dict] = None
    after_snapshot: Optional[dict] = None
    created_at: datetime


class DebtProjectionRequest(BaseModel):
    first_payment_on: date
    extra_payment_minor: int = Field(default=0, ge=0, le=MAX_INT64)


class DebtProjectionPointResponse(BaseModel):
    payment_number: int
    payment_date: date
    starting_principal_minor: int
    interest_minor: int
    payment_minor: int
    ending_principal_minor: int


class DebtProjectionResponse(BaseModel):
    account_id: str
    currency_code: str
    status: Literal["incomplete", "paid_off", "non_amortizing", "iteration_limit"]
    missing_projection_fields: list[str] = Field(default_factory=list)
    starting_principal_minor: int
    extra_payment_minor: int
    payoff_date: Optional[date] = None
    payment_count: int = 0
    projected_interest_minor: int = 0
    projected_total_cost_minor: int = 0
    points: list[DebtProjectionPointResponse] = Field(default_factory=list)


class DebtStrategyProjectionRequest(BaseModel):
    first_payment_on: date
    strategy: Literal["avalanche", "snowball", "custom"]
    rollover: bool
    extra_payment_minor: int = Field(default=0, ge=0, le=MAX_INT64)
    account_ids: list[str] = Field(default_factory=list, max_length=100)
    custom_order: list[str] = Field(default_factory=list, max_length=100)
    target_date: Optional[date] = None


class DebtStrategyIncompleteAccount(BaseModel):
    account_id: str
    missing_projection_fields: list[str]


class DebtStrategyAccountResponse(BaseModel):
    account_id: str
    payoff_date: Optional[date] = None
    payoff_month: Optional[int] = None
    projected_interest_minor: int
    projected_total_paid_minor: int


class DebtStrategyProjectionResponse(BaseModel):
    currency_code: str
    status: Literal["incomplete", "paid_off", "non_amortizing", "iteration_limit"]
    strategy: Literal["avalanche", "snowball", "custom"]
    rollover: bool
    extra_payment_minor: int
    payoff_order: list[str] = Field(default_factory=list)
    debt_free_date: Optional[date] = None
    payment_count: int = 0
    projected_interest_minor: int = 0
    projected_total_paid_minor: int = 0
    projected_total_cost_minor: int = 0
    accounts: list[DebtStrategyAccountResponse] = Field(default_factory=list)
    incomplete_accounts: list[DebtStrategyIncompleteAccount] = Field(default_factory=list)
    target_date: Optional[date] = None
    required_extra_payment_minor: Optional[int] = None
    on_target: Optional[bool] = None


class DebtPayoffPlanUpsert(BaseModel):
    strategy: Literal["avalanche", "snowball", "custom"]
    rollover: bool = True
    extra_payment_minor: int = Field(default=0, ge=0, le=MAX_INT64)
    account_ids: list[str] = Field(default_factory=list, max_length=100)
    custom_order: list[str] = Field(default_factory=list, max_length=100)
    target_date: Optional[date] = None

    @model_validator(mode="after")
    def validate_account_order(self):
        if len(set(self.account_ids)) != len(self.account_ids):
            raise ValueError("account_ids must not contain duplicates")
        if len(set(self.custom_order)) != len(self.custom_order):
            raise ValueError("custom_order must not contain duplicates")
        if self.strategy == "custom" and set(self.custom_order) != set(self.account_ids):
            raise ValueError("custom_order must contain every selected account exactly once")
        if self.strategy != "custom" and self.custom_order:
            raise ValueError("custom_order is available only for the custom strategy")
        return self


class DebtPayoffPlanResponse(DebtPayoffPlanUpsert):
    id: str
    budget_id: str
    user_id: str
    updated_at: datetime


class DebtPayoffPlanRevisionResponse(BaseModel):
    id: str
    user_id: str
    action: Literal["created", "updated", "deleted"]
    before_snapshot: Optional[DebtPayoffPlanUpsert]
    after_snapshot: Optional[DebtPayoffPlanUpsert]
    created_at: datetime


class CategoryGroupCreate(BaseModel):
    name: str = Field(min_length=1, max_length=100)
    sort_order: int = 0


class OrderedIDsUpdate(BaseModel):
    ordered_ids: list[str] = Field(min_length=1, max_length=500)


class CategoryGroupUpdate(BaseModel):
    name: str = Field(min_length=1, max_length=100)
    sort_order: int = 0
    is_archived: bool = False


class CategoryGroupResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    budget_id: str
    name: str
    sort_order: int
    is_archived: bool


class BudgetStructureRevisionResponse(BaseModel):
    id: str
    resource_type: Literal["category_group", "category"]
    resource_id: str
    action: Literal["created", "updated"]
    actor_user_id: str
    actor_display_name: Optional[str] = None
    before_snapshot: Optional[dict] = None
    after_snapshot: dict
    created_at: datetime


class CategoryCreate(BaseModel):
    group_id: str
    name: str = Field(min_length=1, max_length=100)
    icon_name: Optional[str] = Field(default=None, max_length=50)
    note: str = Field(default="", max_length=500)
    sort_order: int = 0
    delegated_user_id: Optional[str] = None
    is_essential: bool = False
    is_emergency_fund: bool = False


class CategoryResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    budget_id: str
    group_id: str
    name: str
    icon_name: Optional[str]
    note: str
    sort_order: int
    is_archived: bool
    is_essential: bool
    is_emergency_fund: bool
    system_type: Optional[str]
    linked_account_id: Optional[str]
    delegated_user_id: Optional[str]
    is_favorite: bool = False
    favorite_sort_order: Optional[int] = None


class CategoryFavoriteUpsert(BaseModel):
    sort_order: int = Field(default=0, ge=0, le=10_000)


class CategoryDelegationUpdate(BaseModel):
    delegated_user_id: Optional[str] = None


class CategoryUpdate(BaseModel):
    group_id: str
    name: str = Field(min_length=1, max_length=100)
    icon_name: Optional[str] = Field(default=None, max_length=50)
    note: str = Field(default="", max_length=500)
    sort_order: int = 0
    is_archived: bool = False
    is_essential: Optional[bool] = None
    is_emergency_fund: Optional[bool] = None


class DelegatedCategoryRuleUpsert(BaseModel):
    category_id: str
    rule_kind: Literal["hard_limit", "soft_target", "approval_gated"]
    minimum_minor: Optional[int] = Field(default=None, ge=0, le=MAX_INT64)
    maximum_minor: Optional[int] = Field(default=None, ge=0, le=MAX_INT64)

    @model_validator(mode="after")
    def validate_bounds(self) -> "DelegatedCategoryRuleUpsert":
        if self.minimum_minor is not None and self.maximum_minor is not None and self.minimum_minor > self.maximum_minor:
            raise ValueError("minimum cannot exceed maximum")
        return self


class DelegatedBudgetPolicyUpsert(BaseModel):
    user_id: str
    pool_category_id: str
    authority_minor: int = Field(ge=0, le=MAX_INT64)
    allow_category_creation: bool = True
    allow_reallocation: bool = True
    expected_allocation_version: Optional[int] = Field(default=None, ge=0)
    rules: list[DelegatedCategoryRuleUpsert] = Field(default_factory=list, max_length=100)


class DelegatedCategoryRuleResponse(DelegatedCategoryRuleUpsert):
    id: str


class DelegatedBudgetPolicyResponse(BaseModel):
    id: str
    budget_id: str
    user_id: str
    pool_category_id: str
    authority_minor: int
    assigned_minor: int
    available_to_assign_minor: int
    allow_category_creation: bool
    allow_reallocation: bool
    rules: list[DelegatedCategoryRuleResponse]


class DelegatedBudgetPolicyRevisionResponse(BaseModel):
    id: str
    policy_id: str
    member_user_id: str
    action: Literal["created", "updated"]
    actor_user_id: str
    actor_display_name: Optional[str] = None
    before_snapshot: Optional[dict] = None
    after_snapshot: dict
    created_at: datetime


class CategoryTargetUpsert(BaseModel):
    target_type: Literal["monthly_funding", "savings_balance", "target_by_date", "recurring_expense", "weekly_spending"]
    target_amount_minor: int = Field(gt=0, le=MAX_INT64)
    target_date: Optional[date] = None
    recurrence_months: Optional[int] = Field(default=None, gt=0, le=1200)
    minimum_contribution_minor: int = Field(default=0, ge=0, le=MAX_INT64)
    priority: int = Field(default=50, ge=0, le=100)
    is_active: bool = True

    @model_validator(mode="after")
    def validate_target_shape(self) -> "CategoryTargetUpsert":
        if self.target_type in {"target_by_date", "recurring_expense", "weekly_spending"} and self.target_date is None:
            raise ValueError("target_date is required for dated targets")
        if self.target_type == "recurring_expense" and self.recurrence_months is None:
            raise ValueError("recurrence_months is required for recurring expense targets")
        if self.target_type == "weekly_spending" and self.target_amount_minor > MAX_INT64 // 5:
            raise ValueError("weekly target amount is too large")
        return self


class CategoryTargetSnoozeUpdate(BaseModel):
    is_snoozed: bool


class CategoryTargetSnoozeResponse(BaseModel):
    category_id: str
    month: date
    is_snoozed: bool


class CategoryTargetResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    budget_id: str
    category_id: str
    target_type: str
    target_amount_minor: int
    target_date: Optional[date]
    recurrence_months: Optional[int]
    minimum_contribution_minor: int
    priority: int
    is_active: bool


class CategoryTargetRevisionResponse(BaseModel):
    id: str
    category_id: str
    target_id: Optional[str] = None
    action: Literal["created", "updated", "deleted", "snoozed", "resumed"]
    actor_user_id: str
    actor_display_name: Optional[str] = None
    before_snapshot: Optional[dict] = None
    after_snapshot: Optional[dict] = None
    affected_month: Optional[date] = None
    created_at: datetime


class ScheduledTransactionCreate(BaseModel):
    account_id: str
    destination_account_id: Optional[str] = None
    category_id: Optional[str] = None
    payee_id: Optional[str] = None
    name: str = Field(min_length=1, max_length=150)
    amount_minor: int = Field(ge=MIN_INT64, le=MAX_INT64)
    next_date: date
    recurrence_unit: Literal["once", "days", "weeks", "months", "years"]
    interval_count: int = Field(default=1, gt=0, le=365)
    end_date: Optional[date] = None
    remaining_occurrences: Optional[int] = Field(default=None, ge=1, le=10_000)
    memo: str = Field(default="", max_length=500)
    financial_classification: Optional[Literal["interest_charge"]] = None

    @model_validator(mode="after")
    def validate_schedule_shape(self) -> "ScheduledTransactionCreate":
        if self.amount_minor == 0:
            raise ValueError("scheduled amount must be nonzero")
        if self.destination_account_id is not None:
            if self.destination_account_id == self.account_id:
                raise ValueError("scheduled transfer accounts must be different")
            if self.category_id is not None or self.payee_id is not None or self.amount_minor < 0:
                raise ValueError("scheduled transfers use a positive amount and no category or payee")
        if self.financial_classification == "interest_charge" and self.amount_minor >= 0:
            raise ValueError("interest charges must be outflows")
        if self.end_date is not None and self.end_date < self.next_date:
            raise ValueError("schedule end date cannot precede the next occurrence")
        if self.recurrence_unit == "once" and self.end_date is not None:
            raise ValueError("one-time schedules do not use an end date")
        if self.recurrence_unit == "once" and self.remaining_occurrences is not None:
            raise ValueError("one-time schedules do not use an occurrence limit")
        if self.end_date is not None and self.remaining_occurrences is not None:
            raise ValueError("choose either an end date or an occurrence limit")
        return self


class ScheduledTransactionUpdate(ScheduledTransactionCreate):
    remaining_occurrences: Optional[int] = Field(default=None, ge=0, le=10_000)
    is_active: bool = True

    @model_validator(mode="after")
    def validate_completed_occurrence_limit(self) -> "ScheduledTransactionUpdate":
        if self.remaining_occurrences == 0 and self.is_active:
            raise ValueError("an exhausted occurrence limit must be inactive")
        return self


class ScheduledTransactionResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    budget_id: str
    account_id: str
    destination_account_id: Optional[str]
    category_id: Optional[str]
    payee_id: Optional[str]
    name: str
    amount_minor: int
    next_date: date
    recurrence_unit: str
    interval_count: int
    end_date: Optional[date] = None
    remaining_occurrences: Optional[int] = None
    memo: str
    financial_classification: Optional[str] = None
    is_active: bool
    last_realized_on: Optional[date] = None


class ScheduledTransactionRevisionResponse(BaseModel):
    id: str
    schedule_id: str
    action: str
    actor_user_id: str
    actor_display_name: Optional[str] = None
    before_snapshot: Optional[dict] = None
    after_snapshot: Optional[dict] = None
    transaction_ids: Optional[list[str]] = None
    created_at: datetime


class ScheduledRealizationResponse(BaseModel):
    scheduled_transaction_id: str
    transaction_ids: list[str]
    realized_on: date
    next_date: Optional[date]
    is_active: bool
    last_realized_on: date


class ForecastOccurrence(BaseModel):
    scheduled_transaction_id: str
    name: str
    occurred_on: date
    account_id: str
    destination_account_id: Optional[str]
    category_id: Optional[str]
    amount_minor: int


class ForecastAccountBalance(BaseModel):
    account_id: str
    name: str
    actual_balance_minor: int
    projected_balance_minor: int


class ForecastResponse(BaseModel):
    as_of: date
    through: date
    currency_code: str
    actual_total_on_budget_minor: int
    projected_total_on_budget_minor: int
    lowest_projected_total_minor: int
    accounts: list[ForecastAccountBalance]
    occurrences: list[ForecastOccurrence]


class AssignmentUpsert(BaseModel):
    mutation_operation_id: Optional[UUID] = None
    month: date
    assigned_minor: int = Field(ge=MIN_INT64 + 1, le=MAX_INT64)
    expected_allocation_version: Optional[int] = Field(default=None, ge=0)

    @model_validator(mode="after")
    def require_identified_observation(self) -> "AssignmentUpsert":
        if self.mutation_operation_id is not None and self.expected_allocation_version is None:
            raise ValueError("identified assignments require expected_allocation_version")
        return self

    @field_validator("month")
    @classmethod
    def require_first_of_month(cls, value: date) -> date:
        if value.day != 1:
            raise ValueError("month must be the first day of a month")
        return value


class AssignmentResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    budget_id: str
    category_id: str
    month: date
    assigned_minor: int
    allocation_version: int


class AllocationTransferCreate(BaseModel):
    mutation_operation_id: Optional[UUID] = None
    source_category_id: str
    destination_category_id: str
    amount_minor: int = Field(gt=0, le=MAX_INT64)
    occurred_on: date
    note: str = Field(default="", max_length=500)
    expected_allocation_version: Optional[int] = Field(default=None, ge=0)

    @model_validator(mode="after")
    def require_distinct_categories(self) -> "AllocationTransferCreate":
        if self.mutation_operation_id is not None and self.expected_allocation_version is None:
            raise ValueError("identified money moves require expected_allocation_version")
        if self.source_category_id == self.destination_category_id:
            raise ValueError("allocation categories must be different")
        return self


class AllocationPostingResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    bucket: str
    category_id: Optional[str]
    amount_minor: int


class AllocationOperationResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    budget_id: str
    occurred_on: date
    kind: str
    actor_user_id: str
    actor_display_name: Optional[str] = None
    note: str
    source: str
    allocation_version: int
    postings: list[AllocationPostingResponse]


class AllocationOperationPageResponse(BaseModel):
    items: list[AllocationOperationResponse]
    next_cursor: Optional[str] = None


class TransactionSplitCreate(BaseModel):
    category_id: str
    amount_minor: int = Field(ge=MIN_INT64, le=MAX_INT64)
    memo: str = Field(default="", max_length=500)
    financial_classification: Optional[Literal["interest_charge"]] = None

    @model_validator(mode="after")
    def validate_financial_classification(self) -> "TransactionSplitCreate":
        if self.financial_classification == "interest_charge" and self.amount_minor >= 0:
            raise ValueError("interest charge split portions must be outflows")
        return self


class TransactionSplitResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    category_id: str
    amount_minor: int
    memo: str
    financial_classification: Optional[str] = None


class TransactionCreate(BaseModel):
    account_id: str
    category_id: Optional[str] = None
    payee_id: Optional[str] = None
    amount_minor: int = Field(ge=MIN_INT64, le=MAX_INT64)
    occurred_on: date
    payee_name: str = Field(default="", max_length=150)
    memo: str = Field(default="", max_length=500)
    financial_classification: Optional[Literal["interest_charge"]] = None
    is_cleared: bool = False
    flag: Optional[str] = Field(default=None, max_length=30)
    tags: list[str] = Field(default_factory=list, max_length=20)
    attachment_metadata: list[dict[str, str]] = Field(default_factory=list, max_length=20)
    client_operation_id: Optional[str] = Field(default=None, min_length=36, max_length=36)
    splits: list[TransactionSplitCreate] = Field(default_factory=list, max_length=100)

    @field_validator("flag")
    @classmethod
    def normalize_flag(cls, value: Optional[str]) -> Optional[str]:
        if value is None:
            return None
        normalized = value.strip().lower()
        return normalized or None

    @field_validator("tags")
    @classmethod
    def normalize_tags(cls, value: list[str]) -> list[str]:
        normalized: list[str] = []
        seen: set[str] = set()
        for item in value:
            tag = item.strip().lower()
            if not tag:
                continue
            if len(tag) > 40:
                raise ValueError("each tag must be at most 40 characters")
            if tag not in seen:
                normalized.append(tag)
                seen.add(tag)
        return normalized

    @model_validator(mode="after")
    def validate_category_shape(self) -> "TransactionCreate":
        if self.category_id is not None and self.splits:
            raise ValueError("use either category_id or splits, not both")
        if self.splits and sum(split.amount_minor for split in self.splits) != self.amount_minor:
            raise ValueError("split amounts must equal transaction amount")
        if self.financial_classification is not None and self.splits:
            raise ValueError("classify split portions instead of the parent transaction")
        if self.financial_classification == "interest_charge" and self.amount_minor >= 0:
            raise ValueError("interest charges must be outflows")
        return self


class TransactionUpdate(TransactionCreate):
    expected_revision: Optional[TransactionRevision] = None
    mutation_operation_id: Optional[UUID] = None

    @model_validator(mode="after")
    def require_replay_observation(self) -> "TransactionUpdate":
        if self.mutation_operation_id is not None and self.expected_revision is None:
            raise ValueError("expected_revision is required for an identified edit")
        return self


class TransactionDuplicateRequest(BaseModel):
    occurred_on: date


class TransactionVoidRequest(BaseModel):
    reason: str = Field(default="", max_length=500)


class TransactionScheduleRequest(BaseModel):
    recurrence_unit: Literal["days", "weeks", "months", "years"]
    interval_count: int = Field(default=1, gt=0, le=365)
    next_date: Optional[date] = None


class TransactionAttachmentResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: str
    transaction_id: str
    filename: str
    content_type: str
    byte_count: int
    sha256: str
    created_at: datetime
    detached_at: Optional[datetime] = None


class TransactionBulkUpdateRequest(BaseModel):
    mutation_operation_id: Optional[UUID] = None
    expected_revisions: Optional[dict[str, TransactionRevision]] = Field(default=None, max_length=200)
    transaction_ids: list[str] = Field(min_length=1, max_length=200)
    action: Literal["set_cleared", "set_flag", "add_tags", "remove_tags"]
    cleared: Optional[bool] = None
    flag: Optional[str] = Field(default=None, max_length=30)
    tags: list[str] = Field(default_factory=list, max_length=20)

    @field_validator("transaction_ids")
    @classmethod
    def unique_transaction_ids(cls, value: list[str]) -> list[str]:
        if len(set(value)) != len(value):
            raise ValueError("transaction_ids must be unique")
        return value

    @field_validator("flag")
    @classmethod
    def normalize_bulk_flag(cls, value: Optional[str]) -> Optional[str]:
        if value is None:
            return None
        return value.strip().lower() or None

    @field_validator("tags")
    @classmethod
    def normalize_bulk_tags(cls, value: list[str]) -> list[str]:
        normalized = TransactionCreate.normalize_tags(value)
        if not normalized:
            raise ValueError("tags must contain at least one non-empty tag")
        return normalized

    @model_validator(mode="after")
    def validate_action_value(self) -> "TransactionBulkUpdateRequest":
        if self.mutation_operation_id is not None and self.expected_revisions is None:
            raise ValueError("identified bulk commands require expected_revisions")
        if self.expected_revisions is not None and set(self.expected_revisions) != set(self.transaction_ids):
            raise ValueError("expected_revisions must cover exactly the selected transactions")
        if self.action == "set_cleared" and self.cleared is None:
            raise ValueError("cleared is required for set_cleared")
        if self.action in {"add_tags", "remove_tags"} and not self.tags:
            raise ValueError("tags are required for tag actions")
        return self


class TransactionResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    budget_id: str
    account_id: str
    category_id: Optional[str]
    payee_id: Optional[str] = None
    amount_minor: int
    occurred_on: date
    created_at: datetime
    payee_name: str
    memo: str
    financial_classification: Optional[str] = None
    is_cleared: bool
    is_reconciled: bool
    flag: Optional[str]
    tags: list[str] = Field(default_factory=list)
    attachment_metadata: list[dict[str, str]] = Field(default_factory=list)
    created_by_user_id: str
    created_by_display_name: Optional[str] = None
    last_modified_by_user_id: Optional[str] = None
    last_modified_by_display_name: Optional[str] = None
    last_modified_at: Optional[datetime] = None
    transfer_id: Optional[str]
    scheduled_transaction_id: Optional[str] = None
    status: str = "posted"
    voided_at: Optional[datetime] = None
    voided_by_user_id: Optional[str] = None
    void_reason: Optional[str] = None
    reversal_of_transaction_id: Optional[str] = None
    reversal_transaction_id: Optional[str] = None
    splits: list[TransactionSplitResponse] = Field(default_factory=list)

    @computed_field
    @property
    def revision(self) -> str:
        # Exact authorized transaction content, not display attribution or wall-clock time.
        payload = self.model_dump(mode="json", include={
            "id", "budget_id", "account_id", "category_id", "payee_id", "amount_minor",
            "occurred_on", "payee_name", "memo", "financial_classification", "is_cleared",
            "is_reconciled", "flag", "tags", "attachment_metadata", "transfer_id",
            "scheduled_transaction_id", "status", "voided_at", "voided_by_user_id", "void_reason",
            "reversal_of_transaction_id", "reversal_transaction_id", "splits",
        })
        payload["splits"].sort(key=lambda split: split["id"])
        return "v1:" + hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


class TransactionPageResponse(BaseModel):
    items: list[TransactionResponse]
    next_cursor: Optional[str] = None
    total_count: int


class TransactionFieldChangeResponse(BaseModel):
    field: str
    value_kind: Literal["text", "money_minor", "date", "state", "list", "restricted"]
    before_value: Optional[str] = None
    after_value: Optional[str] = None


class TransactionChangeResponse(BaseModel):
    id: str
    transaction_id: Optional[str] = None
    transaction_payee_name: Optional[str] = None
    transaction_occurred_on: Optional[date] = None
    action: str
    actor_user_id: str
    actor_display_name: Optional[str] = None
    changed_fields: list[str] = Field(default_factory=list)
    changes: list[TransactionFieldChangeResponse] = Field(default_factory=list)
    created_at: datetime


class PayeeCreate(BaseModel):
    display_name: str = Field(min_length=1, max_length=150)
    default_category_id: Optional[str] = None


class PayeeUpdate(BaseModel):
    display_name: str = Field(min_length=1, max_length=150)
    is_archived: bool = False
    default_category_id: Optional[str] = None


class PayeeAliasCreate(BaseModel):
    display_name: str = Field(min_length=1, max_length=150)


class PayeeAliasResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: str
    display_name: str


class PayeeResponse(BaseModel):
    id: str
    household_id: str
    display_name: str
    is_archived: bool
    merged_into_payee_id: Optional[str] = None
    default_category_id: Optional[str] = None
    transaction_count: int = 0
    net_amount_minor: int = 0
    aliases: list[PayeeAliasResponse] = Field(default_factory=list)


class PayeePageResponse(BaseModel):
    items: list[PayeeResponse]
    next_cursor: Optional[str] = None


class PayeeMerge(BaseModel):
    destination_payee_id: str


class PayeeRevisionResponse(BaseModel):
    id: str
    payee_id: str
    budget_id: Optional[str] = None
    action: Literal["created", "updated", "alias_added", "alias_removed", "merged", "preference_updated"]
    actor_user_id: str
    actor_display_name: Optional[str] = None
    before_snapshot: Optional[dict] = None
    after_snapshot: dict
    created_at: datetime


class SpendingCategoryReport(BaseModel):
    category_id: str
    category_name: str
    category_group: str
    spending_minor: int
    transaction_ids: list[str]
    transaction_ids_truncated: bool = False


class SpendingReportResponse(BaseModel):
    start_date: date
    end_date: date
    currency_code: str
    total_spending_minor: int
    categories: list[SpendingCategoryReport]


class SpendingTrendPoint(BaseModel):
    period_start: date
    period_end: date
    spending_minor: int
    transaction_ids: list[str]
    transaction_ids_truncated: bool = False


class SpendingTrendSeries(BaseModel):
    dimension_id: str
    dimension_name: str
    category_group: Optional[str] = None
    spending_minor: int
    transaction_ids: list[str]
    transaction_ids_truncated: bool = False
    points: list[SpendingTrendPoint]


class SpendingTrendsReportResponse(BaseModel):
    start_date: date
    end_date: date
    currency_code: str
    dimension: Literal["category", "group", "payee"]
    total_spending_minor: int
    series: list[SpendingTrendSeries]


class IncomeSpendingPeriod(BaseModel):
    period_start: date
    period_end: date
    income_minor: int
    spending_minor: int
    difference_minor: int
    income_transaction_ids: list[str]
    spending_transaction_ids: list[str]
    income_transaction_ids_truncated: bool = False
    spending_transaction_ids_truncated: bool = False


class IncomeSpendingReportResponse(BaseModel):
    start_date: date
    end_date: date
    currency_code: str
    income_minor: int
    spending_minor: int
    difference_minor: int
    savings_rate: Optional[float]
    income_transaction_ids: list[str]
    spending_transaction_ids: list[str]
    income_transaction_ids_truncated: bool = False
    spending_transaction_ids_truncated: bool = False
    periods: list[IncomeSpendingPeriod]


class NetWorthPoint(BaseModel):
    as_of: date
    assets_minor: int
    liabilities_minor: int
    net_worth_minor: int
    transaction_ids: list[str]
    transaction_ids_truncated: bool = False


class NetWorthAccount(BaseModel):
    account_id: str
    account_name: str
    account_type: str
    is_on_budget: bool
    balance_minor: int
    transaction_ids: list[str]
    transaction_ids_truncated: bool = False


class NetWorthReportResponse(BaseModel):
    start_date: date
    end_date: date
    currency_code: str
    assets_minor: int
    liabilities_minor: int
    net_worth_minor: int
    points: list[NetWorthPoint]
    accounts: list[NetWorthAccount]


class DebtPoint(BaseModel):
    as_of: date
    debt_minor: int
    net_debt_change_minor: int
    recorded_interest_minor: int


class DebtAccount(BaseModel):
    account_id: str
    account_name: str
    account_type: str
    is_on_budget: bool
    debt_minor: int
    recorded_interest_minor: int


class InsightsSummaryResponse(BaseModel):
    currency_code: str
    net_cash_flow_minor: int
    net_worth_minor: Optional[int] = None
    debt_minor: Optional[int] = None
    recorded_interest_month_minor: Optional[int] = None
    expected_margin_minor: Optional[int] = None


class DebtCostAccountResponse(BaseModel):
    account_id: str
    account_name: str
    principal_minor: int
    effective_rate_basis_points: Optional[int] = None
    estimated_monthly_interest_minor: Optional[int] = None
    missing_fields: list[str] = []


class DebtCostResponse(BaseModel):
    as_of: date
    currency_code: str
    model: Literal["unchanged_balance_monthly_apr"] = "unchanged_balance_monthly_apr"
    accounts: list[DebtCostAccountResponse]


class DebtReportResponse(BaseModel):
    start_date: date
    end_date: date
    currency_code: str
    opening_debt_minor: int
    debt_minor: int
    principal_reduction_minor: int
    recorded_interest_range_minor: int
    recorded_interest_month_minor: int
    recorded_interest_ytd_minor: int
    recorded_interest_trailing_12_minor: int
    recorded_interest_lifetime_minor: int
    interest_tracking_started_on: Optional[date]
    points: list[DebtPoint]
    accounts: list[DebtAccount]


class PlanPerformancePoint(BaseModel):
    period_start: date
    period_end: date
    assigned_minor: int
    activity_minor: int
    spending_minor: int
    carried_available_minor: int
    available_minor: int
    overspent_minor: int
    ready_to_assign_minor: int


class PlanPerformanceReportResponse(BaseModel):
    start_date: date
    end_date: date
    currency_code: str
    points: list[PlanPerformancePoint]


class ResilienceReportResponse(BaseModel):
    as_of: date
    through: date
    currency_code: str
    cash_buffer_minor: int
    current_on_budget_minor: int
    projected_on_budget_minor: int
    lowest_projected_on_budget_minor: int
    scheduled_income_minor: int
    scheduled_outflows_minor: int
    expected_margin_minor: int
    average_age_of_money_days: Optional[int] = None
    daily_burn_rate_minor: Optional[int] = None
    runway_days: Optional[int] = None
    burn_rate_window_days: int = 90
    essential_expense_coverage_days: Optional[int] = None
    emergency_fund_coverage_days: Optional[int] = None
    unavailable_metrics: dict[str, str]


class TransferCreate(BaseModel):
    source_account_id: str
    destination_account_id: str
    amount_minor: int = Field(gt=0, le=MAX_INT64)
    occurred_on: date
    memo: str = Field(default="", max_length=500)
    is_cleared: bool = False

    @model_validator(mode="after")
    def require_distinct_accounts(self) -> "TransferCreate":
        if self.source_account_id == self.destination_account_id:
            raise ValueError("transfer accounts must be different")
        return self


class IdentifiedTransferCreate(TransferCreate):
    mutation_operation_id: Optional[UUID] = None


class TransferResponse(BaseModel):
    transfer_id: str
    source: TransactionResponse
    destination: TransactionResponse


class ReconcileRequest(BaseModel):
    statement_balance_minor: int = Field(ge=MIN_INT64, le=MAX_INT64)
    through_date: date
    create_adjustment: bool = False
    adjustment_reason: str = Field(default="", max_length=500)
    expected_cleared_balance_minor: Optional[int] = Field(default=None, ge=MIN_INT64, le=MAX_INT64)


class ReconcileResponse(BaseModel):
    account_id: str
    reconciled_balance_minor: int
    reconciled_transaction_count: int
    adjustment_transaction_id: Optional[str] = None
    adjustment_amount_minor: int = 0


class ReconciliationHistoryResponse(BaseModel):
    id: str
    account_id: str
    actor_user_id: str
    actor_display_name: Optional[str] = None
    statement_date: date
    statement_balance_minor: int
    cleared_balance_before_minor: int
    reconciled_transaction_count: int
    adjustment_transaction_id: Optional[str] = None
    created_at: datetime


class ImportCandidateResponse(BaseModel):
    source_row: int
    occurred_on: date
    amount_minor: int = Field(ge=MIN_INT64, le=MAX_INT64)
    payee: str
    memo: str
    exact_transaction_ids: list[str] = Field(default_factory=list)
    possible_transaction_ids: list[str] = Field(default_factory=list)
    suggestions_truncated: bool = False
    duplicate_source_row: Optional[int] = None
    suggested_category_id: Optional[str] = None
    approval_action: Optional[Literal["post", "skip"]] = None
    posted_transaction_id: Optional[str] = None
    reversal_transaction_id: Optional[str] = None


class StatementImportResponse(BaseModel):
    id: str
    budget_id: str
    account_id: str
    status: Literal["review", "approved", "cancelled"]
    version: int
    source_format: Literal["csv", "ofx", "qfx", "qif", "mt940", "camt", "pdf", "pdf_ocr"]
    candidate_count: int
    candidates: list[ImportCandidateResponse]
    created_at: datetime


class StatementImportSummary(BaseModel):
    id: str
    budget_id: str
    account_id: str
    status: Literal["review", "approved", "cancelled"]
    version: int
    source_format: Literal["csv", "ofx", "qfx", "qif", "mt940", "camt", "pdf", "pdf_ocr"]
    candidate_count: int
    created_at: datetime


class StatementImportListResponse(BaseModel):
    items: list[StatementImportSummary]
    has_more: bool
    next_offset: Optional[int] = None


class StatementImportCancelRequest(BaseModel):
    expected_version: int = Field(ge=0)


class StatementImportUndoRequest(BaseModel):
    expected_version: int = Field(ge=0)


class StatementImportApprovalItem(BaseModel):
    source_row: int = Field(ge=1)
    action: Literal["post", "skip"]
    category_id: Optional[str] = None


class StatementImportApproveRequest(BaseModel):
    expected_version: int = Field(ge=0)
    items: list[StatementImportApprovalItem] = Field(min_length=1, max_length=10000)

    @field_validator("items")
    @classmethod
    def require_unique_rows(cls, value: list[StatementImportApprovalItem]) -> list[StatementImportApprovalItem]:
        if len({item.source_row for item in value}) != len(value):
            raise ValueError("source rows must be unique")
        return value


class FinancialRequestCreate(BaseModel):
    request_type: Literal[
        "additional_allocation", "purchase_approval", "savings_withdrawal",
        "category_transfer", "large_purchase", "allowance_exception",
    ] = "additional_allocation"
    destination_category_id: str
    requested_amount_minor: int = Field(gt=0, le=MAX_INT64)
    reason: str = Field(default="", max_length=500)


class RequestActionResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    actor_user_id: Optional[str]
    actor_display_name: Optional[str] = None
    action: str
    amount_minor: Optional[int]
    note: str
    created_at: datetime


class FinancialRequestResponse(BaseModel):
    id: str
    household_id: str
    budget_id: str
    requester_user_id: str
    requester_display_name: Optional[str] = None
    request_type: str
    destination_category_id: str
    requested_amount_minor: int
    reason: str
    status: str
    version: int
    approved_amount_minor: Optional[int]
    source_category_id: Optional[str]
    allocation_operation_id: Optional[str]
    created_at: datetime
    expires_at: Optional[datetime]
    resolved_at: Optional[datetime]
    actions: list[RequestActionResponse]


class FinancialRequestDecision(BaseModel):
    decision: Literal["approve", "reject", "changes_requested"]
    expected_request_version: int = Field(ge=0)
    approved_amount_minor: Optional[int] = Field(default=None, gt=0, le=MAX_INT64)
    source_category_id: Optional[str] = None
    note: str = Field(default="", max_length=500)

    @model_validator(mode="after")
    def validate_approval(self) -> "FinancialRequestDecision":
        if self.decision == "approve" and (
            self.approved_amount_minor is None or self.source_category_id is None
        ):
            raise ValueError("approval requires amount and source category")
        if self.decision != "approve" and (
            self.approved_amount_minor is not None or self.source_category_id is not None
        ):
            raise ValueError("only approvals identify funding")
        return self


class FinancialRequestCancel(BaseModel):
    expected_request_version: int = Field(ge=0)
    note: str = Field(default="", max_length=500)


class FinancialRequestRevision(FinancialRequestCreate):
    expected_request_version: int = Field(ge=0)


class AllowanceSplitCreate(BaseModel):
    destination_category_id: str
    amount_minor: int = Field(gt=0, le=MAX_INT64)


class AllowancePlanCreate(BaseModel):
    delegated_user_id: str
    source_category_id: str
    name: str = Field(min_length=1, max_length=100)
    amount_minor: int = Field(gt=0, le=MAX_INT64)
    next_issue_date: date
    recurrence_unit: Literal["week", "month"]
    interval_count: int = Field(default=1, ge=1, le=52)
    rollover_policy: Literal["rollover", "use_it_or_lose_it"] = "rollover"
    splits: list[AllowanceSplitCreate] = Field(min_length=1, max_length=10)

    @model_validator(mode="after")
    def validate_splits(self) -> "AllowancePlanCreate":
        if len({split.destination_category_id for split in self.splits}) != len(self.splits):
            raise ValueError("allowance destination categories must be unique")
        if sum(split.amount_minor for split in self.splits) != self.amount_minor:
            raise ValueError("allowance splits must equal the plan amount")
        return self


class AllowanceSplitResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    destination_category_id: str
    amount_minor: int


class AllowancePlanResponse(BaseModel):
    id: str
    budget_id: str
    delegated_user_id: str
    source_category_id: Optional[str]
    name: str
    amount_minor: int
    next_issue_date: date
    recurrence_unit: str
    interval_count: int
    rollover_policy: str
    is_active: bool
    splits: list[AllowanceSplitResponse]


class AllowanceIssueRequest(BaseModel):
    issue_date: date
    expected_allocation_version: int = Field(ge=0)


class AllowanceStatusUpdate(BaseModel):
    is_active: bool


class AllowanceIssuanceResponse(BaseModel):
    id: str
    plan_id: str
    budget_id: str
    issued_on: date
    amount_minor: int
    reclaimed_minor: int
    allocation_operation_id: str
    actor_user_id: str
    created_at: datetime
    next_issue_date: date


class AllowancePlanRevisionResponse(BaseModel):
    id: str
    plan_id: str
    action: Literal["created", "paused", "reactivated", "issued"]
    actor_user_id: str
    actor_display_name: Optional[str] = None
    before_snapshot: Optional[dict] = None
    after_snapshot: dict
    created_at: datetime


class CategoryMonthSummary(BaseModel):
    category_id: str
    name: str
    assigned_minor: int
    activity_minor: int
    carried_available_minor: int
    available_minor: int
    is_overspent: bool
    target_type: Optional[str] = None
    target_amount_minor: Optional[int] = None
    target_date: Optional[date] = None
    target_priority: int = 50
    is_target_snoozed: bool = False
    recommended_contribution_minor: int = 0
    underfunded_minor: int = 0
    cash_overspent_minor: int = 0
    credit_overspent_minor: int = 0
    funded_credit_spending_minor: int = 0


class MonthSummaryResponse(BaseModel):
    month: date
    currency_code: str
    ready_to_assign_minor: int
    budget_totals_visible: bool = True
    all_date_unassigned_minor: Optional[int] = None
    funding_limit_minor: Optional[int] = None
    total_assigned_minor: int
    total_overspent_minor: int
    allocation_version: int
    categories: list[CategoryMonthSummary]


class SmartFundingProposal(BaseModel):
    category_id: str
    category_name: str
    amount_minor: int
    before_available_minor: int
    after_available_minor: int
    target_type: Optional[str] = None
    target_priority: int = 50
    recommended_contribution_minor: int = 0
    remaining_need_minor: int = 0


class SmartFundingPreviewResponse(BaseModel):
    month: date
    currency_code: str
    before_ready_to_assign_minor: int
    proposed_minor: int
    after_ready_to_assign_minor: int
    allocation_version: int
    proposals: list[SmartFundingProposal]
    remaining_need_minor: int = 0
    unfunded_category_count: int = 0
    funding_limit_minor: int = 0


class SmartFundingCommit(BaseModel):
    month: date
    expected_allocation_version: int = Field(ge=0)


class HouseholdSummary(BaseModel):
    id: str
    name: str
    role: Literal["owner", "adult", "child"]
    is_active: bool


class MeResponse(BaseModel):
    id: str
    email: str
    display_name: str
    households: list[HouseholdSummary]


class InvitationCreate(BaseModel):
    email: str = Field(min_length=3, max_length=320)
    role: Literal["adult", "child"]

    @field_validator("email")
    @classmethod
    def normalize_invite_email(cls, value: str) -> str:
        normalized = value.strip().lower()
        if "@" not in normalized:
            raise ValueError("must be an email address")
        return normalized


class InvitationResponse(BaseModel):
    invitation_token: str
    email: str
    role: str
    expires_at: str


class InvitationSummary(BaseModel):
    id: str
    email: str
    role: str
    status: Literal["pending", "accepted", "expired", "canceled"]
    expires_at: str
    created_at: str
    created_by_display_name: str


class HouseholdAccessEventResponse(BaseModel):
    id: str
    event_type: str
    actor_display_name: str
    subject_display_name: Optional[str] = None
    detail: Optional[str] = None
    created_at: str


class InvitationAccept(BaseModel):
    invitation_token: str = Field(min_length=20, max_length=200)
    password: str = Field(min_length=12, max_length=256)
    display_name: str = Field(min_length=1, max_length=100)


class MemberResponse(BaseModel):
    user_id: str
    email: str
    display_name: str
    role: str
    is_active: bool
    authorization_version: int
