"""Real age envelope proof; Docker is explicitly a command double in these tests."""
import errno
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import sys
import time

import pytest

from .test_backup_restore_scripts import ARCHIVE_TOOL, BACKUP, RESTORE, _backup_environment, _environment

pytestmark = pytest.mark.skipif(not shutil.which("age") or os.name != "posix", reason="Real age and a POSIX terminal are required")
PASSPHRASE = "disposable-test-backup-passphrase-not-a-user-secret"


def run_with_passphrase(command, environment, passphrase=PASSPHRASE):
    """Give age its actual controlling terminal; never use an unsupported secret environment knob."""
    import fcntl
    import pty
    import termios

    master, slave = pty.openpty()

    def controlling_terminal():
        os.setsid()
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)

    process = None
    output = bytearray()
    pending = bytearray()
    environment = {key: value for key, value in environment.items() if not key.startswith("AGE_")}
    try:
        process = subprocess.Popen(command, env=environment, stdin=slave, stdout=slave, stderr=slave,
                                   preexec_fn=controlling_terminal)
        os.close(slave)
        slave = -1
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            ready, _, _ = select.select([master], [], [], 0.1)
            if ready:
                try:
                    chunk = os.read(master, 8192)
                except OSError as error:
                    if error.errno == errno.EIO: break
                    raise
                if not chunk: break
                output.extend(chunk)
                pending.extend(chunk)
                if len(output) > 128 * 1024:
                    raise AssertionError("Unexpected excessive terminal output")
                for prompt in (b"Enter passphrase", b"Confirm passphrase"):
                    start = pending.find(prompt)
                    if start >= 0 and b":" in pending[start:]:
                        os.write(master, passphrase.encode() + b"\n")
                        pending.clear()
                        break
            elif process.poll() is not None:
                break
        else:
            raise AssertionError("age terminal operation exceeded its bounded deadline")
        return process.wait(timeout=5), output.decode(errors="replace").replace(passphrase, "<test passphrase>")
    finally:
        if slave >= 0: os.close(slave)
        os.close(master)
        if process is not None and process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try: process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=3)


def real_encrypted_backup(tmp_path: Path) -> Path:
    environment, _ = _backup_environment(tmp_path)
    # Remove only the test-owned age double; leave the explicit Docker double in place.
    (tmp_path / "backup-tools" / "age").unlink()
    output = tmp_path / "backups"
    status, transcript = run_with_passphrase([str(BACKUP), "--project-name", "disposable-source", str(output)], environment)
    assert status == 0, transcript
    archives = list(output.glob("*.age"))
    assert len(archives) == 1
    ciphertext = archives[0].read_bytes()
    assert ciphertext.startswith(b"age-encryption.org/v1\n")
    assert b"CREATE TABLE" not in ciphertext
    assert b"BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY=test-key" not in ciphertext
    return archives[0]


def test_real_age_backup_roundtrip_preserves_verified_payload_and_uses_terminal_passphrase(tmp_path):
    archive = real_encrypted_backup(tmp_path)
    decrypted = tmp_path / "decrypted.tar.gz"
    status, transcript = run_with_passphrase([shutil.which("age"), "--decrypt", "--output", str(decrypted), str(archive)], os.environ)
    assert status == 0, transcript
    verified = tmp_path / "verified"
    validation = subprocess.run([sys.executable, str(ARCHIVE_TOOL), "extract-verified", str(decrypted), str(verified)], capture_output=True, text=True)
    assert validation.returncode == 0, validation.stderr
    assert (verified / "database.sql").read_text() == "CREATE TABLE restored (id integer);\n"
    assert (verified / "attachments" / "object-1").read_bytes() == b"encrypted-object"
    assert (verified / "attachment-key-recovery.env").stat().st_mode & 0o777 == 0o600
    environment, log = _environment(tmp_path)
    (tmp_path / "tools" / "age").unlink()
    status, transcript = run_with_passphrase([str(RESTORE), "--yes", "--project-name", "disposable-recovery", str(archive)], environment)
    assert status == 0, transcript
    assert len(log.read_text().splitlines()) == 5


@pytest.mark.parametrize("failure", ["wrong-passphrase", "corrupted-ciphertext"])
def test_real_age_failure_never_contacts_recovery_target(tmp_path, failure):
    archive = real_encrypted_backup(tmp_path)
    if failure == "corrupted-ciphertext":
        original = archive.read_bytes()
        archive.write_bytes(original[:-1] + bytes([original[-1] ^ 1]))
    environment, log = _environment(tmp_path)
    (tmp_path / "tools" / "age").unlink()
    status, transcript = run_with_passphrase(
        [str(RESTORE), "--yes", "--project-name", "disposable-recovery", str(archive)], environment,
        passphrase="incorrect-disposable-passphrase" if failure == "wrong-passphrase" else PASSPHRASE,
    )
    assert status != 0, transcript
    assert not log.exists(), "Authentication/integrity failure must precede any destination contact"
