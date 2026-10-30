"""Keep a client's composed extra-CA bundle alive until that command exits."""

import os
import shutil
import signal
import subprocess
import sys
import tempfile
from pathlib import Path


def run(ca, inherited, command):
    child = None

    def forward(number, _frame):
        if child is None:
            raise SystemExit(128 + number)
        child.send_signal(number)

    for number in (signal.SIGINT, signal.SIGTERM):
        signal.signal(number, forward)
    root = os.environ.get("XDG_RUNTIME_DIR") or os.environ.get("TMPDIR") or "/tmp"
    with tempfile.TemporaryDirectory(prefix="airlock-client.", dir=root) as directory:
        bundle = Path(directory) / "ca.pem"
        with bundle.open("wb") as output:
            for index, source in enumerate(filter(None, (inherited, ca))):
                if index:
                    output.write(b"\n")
                with open(source, "rb") as certificate:
                    shutil.copyfileobj(certificate, output)
        child = subprocess.Popen(command, env=os.environ | {"NODE_EXTRA_CA_CERTS": str(bundle)})
        status = child.wait()
    return status if status >= 0 else 128 - status


if __name__ == "__main__":
    sys.exit(run(sys.argv[1], sys.argv[2], sys.argv[3:]))
