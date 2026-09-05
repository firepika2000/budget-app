from __future__ import annotations

import os
from pathlib import Path
import socket
import subprocess


ROOT = Path(__file__).resolve().parents[2]
LAUNCHER = ROOT / "budget"
FINDER_LAUNCHER = ROOT / "Start Budget Server.command"


def run_launcher(*arguments: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(LAUNCHER), *arguments],
        cwd="/tmp",
        env=env,
        check=False,
        capture_output=True,
        text=True,
        timeout=30,
    )


def test_help_works_outside_repository_and_lists_canonical_commands():
    result = run_launcher("--help", env=os.environ.copy())
    assert result.returncode == 0
    assert "server" in result.stdout
    assert "doctor" in result.stdout
    assert "migrate" in result.stdout
    assert "test" in result.stdout


def test_doctor_is_non_destructive_and_hides_secret(tmp_path):
    env = os.environ.copy()
    secret = "doctor-only-secret-that-must-never-be-printed"
    env.update({
        "BUDGET_APP_DATABASE_URL": f"sqlite:///{tmp_path / 'missing' / 'budget.db'}",
        "BUDGET_APP_JWT_SECRET": secret,
        "BUDGET_PORT": "59321",
    })
    result = run_launcher("doctor", env=env)
    combined = result.stdout + result.stderr
    assert "Repository:" in combined
    assert "Alembic:" in combined
    assert "Port 59321: free" in combined
    assert secret not in combined
    assert not (tmp_path / "missing").exists(), "doctor must not create or migrate a database"


def test_unknown_command_has_useful_exit_status():
    result = run_launcher("not-a-command", env=os.environ.copy())
    assert result.returncode == 2
    assert "Unknown command" in result.stderr


def test_doctor_detects_port_conflict_without_printing_secrets(tmp_path):
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        port = listener.getsockname()[1]
        env = os.environ.copy()
        secret = "port-test-secret-that-must-never-be-printed"
        env.update({
            "BUDGET_APP_DATABASE_URL": f"sqlite:///{tmp_path / 'missing' / 'budget.db'}",
            "BUDGET_APP_JWT_SECRET": secret,
            "BUDGET_PORT": str(port),
        })
        result = run_launcher("doctor", env=env)
    combined = result.stdout + result.stderr
    assert result.returncode != 0
    assert f"Port {port}: in use" in combined
    assert secret not in combined


def test_finder_launcher_is_executable_and_delegates_to_canonical_launcher():
    assert os.access(FINDER_LAUNCHER, os.X_OK)
    source = FINDER_LAUNCHER.read_text()
    assert '"$SCRIPT_DIR/budget" server' in source
    assert "uvicorn" not in source


def test_fresh_environment_updates_pip_before_editable_install():
    source = LAUNCHER.read_text()
    create_index = source.index('python3 -m venv "$VENV_DIR"')
    pip_update_index = source.index('"$VENV_PYTHON" -m pip install --upgrade pip')
    editable_install_index = source.index('"$VENV_PYTHON" -m pip install -e "$SERVER_DIR[dev]"')
    assert create_index < pip_update_index < editable_install_index
