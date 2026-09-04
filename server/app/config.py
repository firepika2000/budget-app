from dataclasses import dataclass
import os


@dataclass(frozen=True)
class Settings:
    database_url: str
    jwt_secret: str
    jwt_issuer: str = "budget-app"
    access_token_minutes: int = 30

    @classmethod
    def from_environment(cls) -> "Settings":
        database_url = os.environ.get("BUDGET_APP_DATABASE_URL")
        jwt_secret = os.environ.get("BUDGET_APP_JWT_SECRET")
        if not database_url:
            raise RuntimeError("BUDGET_APP_DATABASE_URL is required")
        if not jwt_secret or len(jwt_secret) < 32:
            raise RuntimeError("BUDGET_APP_JWT_SECRET must be at least 32 characters")
        return cls(database_url=database_url, jwt_secret=jwt_secret)

