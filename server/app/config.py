from dataclasses import dataclass
import os
from typing import Optional


@dataclass(frozen=True)
class Settings:
    database_url: str
    jwt_secret: str
    jwt_issuer: str = "budget-app"
    access_token_minutes: int = 30
    refresh_token_days: int = 30
    allowed_hosts: tuple[str, ...] = ("localhost", "127.0.0.1", "testserver")
    attachment_storage_path: str = "attachments"
    attachment_encryption_key: Optional[str] = None
    backup_status_path: Optional[str] = None
    backup_schedule_status_path: Optional[str] = None
    recovery_status_path: Optional[str] = None
    pairing_public_url: Optional[str] = None
    pairing_code_minutes: int = 5

    @classmethod
    def from_environment(cls) -> "Settings":
        database_url = os.environ.get("BUDGET_APP_DATABASE_URL")
        jwt_secret = os.environ.get("BUDGET_APP_JWT_SECRET")
        if not database_url:
            raise RuntimeError("BUDGET_APP_DATABASE_URL is required")
        if not jwt_secret or len(jwt_secret) < 32:
            raise RuntimeError("BUDGET_APP_JWT_SECRET must be at least 32 characters")
        if jwt_secret.startswith("replace-with-"):
            raise RuntimeError("BUDGET_APP_JWT_SECRET must be replaced before deployment")
        allowed_hosts = tuple(
            host.strip() for host in os.environ.get(
                "BUDGET_APP_ALLOWED_HOSTS", "localhost,127.0.0.1"
            ).split(",") if host.strip()
        )
        if not allowed_hosts:
            raise RuntimeError("BUDGET_APP_ALLOWED_HOSTS must contain at least one host")
        return cls(
            database_url=database_url,
            jwt_secret=jwt_secret,
            allowed_hosts=allowed_hosts,
            attachment_storage_path=os.environ.get("BUDGET_APP_ATTACHMENT_STORAGE_PATH", "attachments"),
            attachment_encryption_key=os.environ.get("BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY"),
            backup_status_path=os.environ.get("BUDGET_APP_BACKUP_STATUS_PATH"),
            backup_schedule_status_path=os.environ.get("BUDGET_APP_BACKUP_SCHEDULE_STATUS_PATH"),
            recovery_status_path=os.environ.get("BUDGET_APP_RECOVERY_STATUS_PATH"),
            pairing_public_url=os.environ.get("BUDGET_APP_PAIRING_PUBLIC_URL"),
        )
