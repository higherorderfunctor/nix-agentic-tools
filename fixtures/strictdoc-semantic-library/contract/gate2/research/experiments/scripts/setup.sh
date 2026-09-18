#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

experiment_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export UV_CACHE_DIR="$experiment_root/uv-cache"
export UV_PYTHON_INSTALL_DIR="$experiment_root/python"
uv venv "$experiment_root/venv" --python 3.13.15
uv pip install --python "$experiment_root/venv/bin/python" cozo-embedded==0.7.6 networkx==3.6.1 numpy==2.5.3 rustworkx==0.18.1
python3 - "$experiment_root" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
import urllib.request
root = Path(sys.argv[1])
url = 'https://github.com/open-policy-agent/opa/releases/download/v1.20.2/opa_linux_amd64_static'
expected = '69da5179ee403d10fa11bab6cfb4ffb0d23dba5f9b682fa977db772a1da5670f'
blob = urllib.request.urlopen(url).read()
assert hashlib.sha256(blob).hexdigest() == expected
(root/'opa').write_bytes(blob)
(root/'opa').chmod(0o755)
(root/'opa-bun').mkdir(exist_ok=True)
(root/'opa-bun/package.json').write_text(json.dumps({'private':True,'dependencies':{'@open-policy-agent/opa-wasm':'1.10.0'}},indent=2)+'\n')
(root/'logs').mkdir(exist_ok=True)
(root/'results').mkdir(exist_ok=True)
PY
bun install --cwd "$experiment_root/opa-bun"
