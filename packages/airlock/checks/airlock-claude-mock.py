"""Mock the child only: prove launch delivery without running native Claude."""

import json
import os
from pathlib import Path
import sys
from urllib.parse import unquote_to_bytes, urlsplit


environment = os.environ
assert sys.argv[1:] == ["literal argument", "quotes'\"$;", "--native-flag"]
assert sys.stdin.buffer.read() == b"preserved standard input\n"
assert environment["ANTHROPIC_API_KEY"] == "native-api-key"
assert environment["ANTHROPIC_AUTH_TOKEN"] == "native-auth-token"
assert environment["ANTHROPIC_BASE_URL"] == "https://native.example.invalid"
assert os.read(int(environment["CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR"]), 256) == b"native descriptor"
assert Path(environment["CLAUDE_CONFIG_DIR"], ".credentials.json").read_bytes() == b"native oauth fixture"
assert environment["XDG_RUNTIME_DIR"] == environment["R10_NATIVE_DIRECTORY"]
assert environment["TMPDIR"] == "/unused-native-tmp"
for variable in ("ALL_PROXY", "HTTP_PROXY", "NO_PROXY", "all_proxy", "http_proxy", "https_proxy", "no_proxy"):
    assert variable not in environment, variable
proxy = urlsplit(environment["HTTPS_PROXY"])
assert proxy.scheme == "http" and proxy.hostname == "127.0.0.1" and proxy.port == 18448
assert unquote_to_bytes(proxy.username) == b"fixture"
assert unquote_to_bytes(proxy.password) == Path(environment["R10_TOKEN_SOURCE"]).read_bytes().rstrip(b"\n")
runtime = Path(environment["R10_RUNTIME"])
extra = environment.get("NODE_EXTRA_CA_CERTS")
if environment["R10_INTERCEPTED"] == "1":
    ca = (runtime / "ca" / "ca.pem").read_bytes()
    inherited = environment.get("R10_INHERITED_CA")
    expected = Path(inherited).read_bytes() + b"\n" + ca if inherited else ca
    assert Path(extra).read_bytes() == expected
    if inherited:
        assert Path(extra).parent == runtime
        assert Path(extra).stat().st_mode & 0o777 == 0o600
else:
    assert extra == environment.get("R10_INHERITED_CA")
    assert not (runtime / "ca").exists()
Path(environment["R10_MARKER"]).write_text(json.dumps({"extra": extra}))
sys.exit(23)
