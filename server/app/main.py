from __future__ import annotations

from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles

from .config import Settings
from .budgeting_routes import router as budgeting_router
from .household_routes import router as household_router
from .web_routes import ASSET_ROOT, router as web_router
from .database import build_session_factory
from .routes import router


def create_app(settings: Settings | None = None) -> FastAPI:
    resolved_settings = settings or Settings.from_environment()
    app = FastAPI(
        title="Budget App API",
        version="0.1.0",
        docs_url="/api/docs",
        redoc_url=None,
    )
    app.state.settings = resolved_settings
    app.state.session_factory = build_session_factory(resolved_settings.database_url)
    app.include_router(router)
    app.include_router(budgeting_router)
    app.include_router(household_router)
    app.include_router(web_router)
    app.mount("/admin-assets", StaticFiles(directory=ASSET_ROOT), name="admin-assets")
    return app
