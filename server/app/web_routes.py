from pathlib import Path

from fastapi import APIRouter
from fastapi.responses import FileResponse


router = APIRouter(include_in_schema=False)
WEB_ROOT = Path(__file__).resolve().parent.parent / "web"
ASSET_ROOT = WEB_ROOT / "assets"


@router.get("/admin")
@router.get("/admin/")
def admin_app() -> FileResponse:
    response = FileResponse(WEB_ROOT / "index.html", media_type="text/html")
    response.headers["Content-Security-Policy"] = (
        "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
        "connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'"
    )
    response.headers["Referrer-Policy"] = "no-referrer"
    response.headers["X-Content-Type-Options"] = "nosniff"
    return response
