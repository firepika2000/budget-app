from typing import Literal

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

