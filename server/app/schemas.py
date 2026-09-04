from datetime import date
from typing import Literal, Optional

from pydantic import BaseModel, ConfigDict, Field, field_validator


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
    token_type: Literal["bearer"] = "bearer"


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
    assigned_minor: int

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


class TransactionCreate(BaseModel):
    account_id: str
    category_id: Optional[str] = None
    amount_minor: int
    occurred_on: date
    payee_name: str = Field(default="", max_length=150)
    memo: str = Field(default="", max_length=500)
    is_cleared: bool = False


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
    created_by_user_id: str
