# One independent 256-bit secret per named client, shared by the two launchers.
# flock covers first-start races; replace publishes only a complete 0600 file.
import fcntl
import os
from pathlib import Path
import secrets
import sys
import tempfile

os.umask(0o077)
root = Path(sys.argv[1]) / "gate-keys"
root.mkdir(parents=True, exist_ok=True, mode=0o700)
root.chmod(0o700)
with (root / ".lock").open("a") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    target = root / sys.argv[2]
    if not target.exists():
        fd, temporary = tempfile.mkstemp(dir=root)
        with os.fdopen(fd, "w") as handle:
            handle.write(secrets.token_hex(32))
        os.replace(temporary, target)
    key = target.read_text()
    if len(key) != 64 or any(char not in "0123456789abcdef" for char in key):
        sys.exit("invalid internal key file")
    target.chmod(0o600)
    sys.stdout.write(key)
