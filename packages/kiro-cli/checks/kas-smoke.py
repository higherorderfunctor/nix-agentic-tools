"""Exercise actual KAS imports/resources and ACP initialization without a login."""

import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile


def initialize(command, env):
    with tempfile.TemporaryFile(mode="w+") as errors:
        process = subprocess.Popen(command, env=env, stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=errors, text=True)
        try:
            request = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
                "protocolVersion": 1, "clientCapabilities": {},
                "clientInfo": {"name": "nix-check", "version": "1"}}}
            process.stdin.write(json.dumps(request) + "\n")
            process.stdin.flush()
            if not select.select([process.stdout], [], [], 30)[0]:
                raise AssertionError("KAS initialize timed out")
            reply = json.loads(process.stdout.readline())
            assert reply["id"] == 1 and reply["result"]["protocolVersion"] == 1, reply
            assert reply["result"]["agentCapabilities"]["loadSession"] is True, reply
        except Exception:
            errors.seek(0)
            print(errors.read(), file=sys.stderr)
            raise
        finally:
            process.terminate()
            process.communicate(timeout=10)


def main():
    node, server = sys.argv[1:]
    # Imports alone can leave optional native modules deferred. Exercise the
    # WASM solver and explicitly load ONNX's native backend.
    script = """
      const require = (await import('node:module')).createRequire(process.argv[1]);
      const ort = require('onnxruntime-node');
      if (!ort.listSupportedBackends().length) throw Error('no ONNX backend');
      const {Context} = await require('z3-solver').init();
      const {Solver,Int} = new Context('smoke');
      const solver = new Solver(); const x = Int.const('x'); solver.add(x.eq(1));
      if (await solver.check() !== 'sat') throw Error('WASM solver failed');
      console.log('PASS: native ONNX dependency and WASM solver');
      process.exit(0);
    """
    with tempfile.TemporaryDirectory() as home:
        env = {"PATH": os.environ["PATH"], "HOME": home, "CFFIXED_USER_HOME": home,
               "KIRO_DISABLE_TELEMETRY": "1", "XDG_CACHE_HOME": home + "/cache",
               "XDG_CONFIG_HOME": home + "/config", "XDG_DATA_HOME": home + "/data"}
        subprocess.run([node, "--input-type=module", "-e", script, server],
                       env=env, check=True, timeout=45)
        kas = Path(server).parents[5]
        ripgrep = list(kas.glob("node_modules/@vscode/ripgrep-*/bin/rg"))
        assert len(ripgrep) == 1, ripgrep
        subprocess.run([str(ripgrep[0]), "--version"], env=env, check=True, timeout=10)
        initialize([node, server], env)
        assert not list(Path(home).rglob("acp-server.js")), "unexpected runtime materialization"
        print("PASS: real KAS ACP initialize with isolated state")


if __name__ == "__main__":
    main()
