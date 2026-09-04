from datetime import date
from typing import Literal, Optional

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


MIN_INT64 = -(2**63)
MAX_INT64 = 2**63 - 1


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


class TokenResponse(BaseModel):
    access_token: str
    refresh_token: str
    token_type: Literal["bearer"] = "bearer"


class RefreshRequest(BaseModel):
    refresh_token: str = Field(min_length=40, max_length=200)


class BudgetCreate(BaseModel):
    household_id: str
    name: str = Field(min_length=1, max_length=100)
    currency_code: str = Field(min_length=3, max_length=3)

    @field_validator("currency_code")
    @classmethod
    def normalize_currency(cls, value: str) -> str:
        return value.upper()


class BudgetResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    household_id: str
    name: str
    currency_code: str
    effective_permission: Literal["view", "contribute", "manage", "owner"]
    allocation_version: int


class GrantUpsert(BaseModel):
    user_id: str
    permission: Literal["view", "contribute", "manage"]


class GrantResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    budget_id: str
    user_id: str
    permission: str


class AccountCreate(BaseModel):
    name: str = Field(min_length=1, max_length=100)
    account_type: Literal["checking", "savings", "cash", "credit", "loan", "tracking"]
    is_on_budget: bool = True


class AccountResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    budget_id: str
    name: str
    account_type: str
    is_on_budget: bool
    is_closed: bool
    reconciled_balance_minor: Optional[int]


class CategoryGroupCreate(BaseModel):
    name: str = Field(min_length=1, max_length=100)
    sort_order: int = 0


class CategoryGroupResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    budget_id: str
    name: str
    sort_order: int


class CategoryCreate(BaseModel):
    group_id: str
    name: str = Field(min_length=1, max_length=100)
    sort_order: int = 0


class CategoryResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    budget_id: str
    group_id: str
    name: str
    sort_order: int
    is_archived: bool


class AssignmentUpsert(BaseModel):
    month: date
    assigned_minor: int = Field(ge=MIN_INT64 + 1, le=MAX_INT64)
    expected_allocation_version: Optional[int] = Field(default=None, ge=0)

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
    source_category_id: str
    destination_category_id: str
    amount_minor: int = Field(gt=0, le=MAX_INT64)
    occurred_on: date
    note: str = Field(default="", max_length=500)
    expected_allocation_version: Optional[int] = Field(default=None, ge=0)

    @model_validator(mode="after")
    def require_distinct_categories(self) -> "AllocationTransferCreate":
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
    note: str
    source: str
    allocation_version: int
    postings: list[AllocationPostingResponse]


class TransactionSplitCreate(BaseModel):
    category_id: str
    amount_minor: int = Field(ge=MIN_INT64, le=MAX_INT64)
    memo: str = Field(default="", max_length=500)


class TransactionSplitResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    category_id: str
    amount_minor: int
    memo: str


class TransactionCreate(BaseModel):
    account_id: str
    category_id: Optional[str] = None
    amount_minor: int = Field(ge=MIN_INT64, le=MAX_INT64)
    occurred_on: date
    payee_name: str = Field(default="", max_length=150)
    memo: str = Field(default="", max_length=500)
    is_cleared: bool = False
    splits: list[TransactionSplitCreate] = Field(default_factory=list, max_length=100)

    @model_validator(mode="after")
    def validate_category_shape(self) -> "TransactionCreate":
        if self.category_id is not None and self.splits:
            raise ValueError("use either category_id or splits, not both")
        if self.splits and sum(split.amount_minor for split in self.splits) != self.amount_minor:
            raise ValueError("split amounts must equal transaction amount")
        return self


class TransactionResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    budget_id: str
    account_id: str
    category_id: Optional[str]
    amount_minor: int
    occurred_on: date
    payee_name: str
    memo: str
    is_cleared: bool
    is_reconciled: bool
    created_by_user_id: str
    transfer_id: Optional[str]
    splits: list[TransactionSplitResponse] = Field(default_factory=list)


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


class TransferResponse(BaseModel):
    transfer_id: str
    source: TransactionResponse
    destination: TransactionResponse


class ReconcileRequest(BaseModel):
    statement_balance_minor: int = Field(ge=MIN_INT64, le=MAX_INT64)
    through_date: date


class ReconcileResponse(BaseModel):
    account_id: str
    reconciled_balance_minor: int
    reconciled_transaction_count: int


class CategoryMonthSummary(BaseModel):
    category_id: str
    name: str
    assigned_minor: int
    activity_minor: int
    carried_available_minor: int
    available_minor: int
    is_overspent: bool


class MonthSummaryResponse(BaseModel):
    month: date
    currency_code: str
    ready_to_assign_minor: int
    total_assigned_minor: int
    total_overspent_minor: int
    allocation_version: int
    categories: list[CategoryMonthSummary]


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
