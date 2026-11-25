# Readers register by module merging, and every constructor resolves the same selection.
# cspell:ignore rfile wfile
{
  harness,
  lib,
  pkgs,
  ...
}: let
  python = pkgs.ai.generic.python-stack.withPackages (ps: [ps.pydantic]);
  # Standalone construction evaluates the module files Home Manager and devenv do.
  mergeReaders = (import ../lib/default.nix).ai.credential-usage.mergeReaders {inherit pkgs lib;};
  inherit ((import ../../claude-code/lib/default.nix).ai.claude-code) usageModule usageReader;
  # Expectations read Claude's library, never the registration under test.
  shipped = usageReader {
    inherit pkgs;
    python-stack = pkgs.ai.generic.python-stack;
    # The shipped Reader bundles no CLI; it reads the `claude` on PATH.
    claude = pkgs.emptyDirectory;
  };
  # An ordinary derivation stands in for another owner's packaged Reader.
  fill = pkgs.hello;
  claude = (import ../../../lib/strict-shell-application.nix pkgs) {
    name = "claude";
    text = "printf '%s\\n' '2.1.0 (Claude Code)'";
  };
  # Owners default every leaf, as Claude's own module does.
  owner = id: {
    ai.credentialUsage.readers.${id} = lib.mapAttrs (_: lib.mkDefault) {
      package = fill;
      endpoint = "https://owner.example";
      transports = ["cpa"];
    };
  };
  # Real backend imports exercise both wrappers.
  backends = {
    devenv = harness.evalDevenvModules;
    hm = harness.evalHmModules;
  };
  registered = evaluate: modules: (evaluate modules).config.ai.credentialUsage.readers;
  exe = reader: lib.getExe reader.package;
  selection.ai.credentialUsage.readers.claude.package = fill;
  conflict.ai.credentialUsage.readers.claude.package = lib.mkDefault fill;
  binding.ai.credentialUsage.readers.claude.cpa = {
    endpoint = "http://127.0.0.1:49264/selected";
    managementKeyFile = "/dev/stdin";
    pin = "selected";
    policy = {
      retries = 1;
      timeout = 0.25;
    };
  };
  merged = contributions: overrides: mergeReaders {inherit contributions overrides;};
  selected = (merged [usageModule] binding.ai.credentialUsage.readers).claude;
  # Each case fails on the wrong implementation its comment names.
  cases = backend: let
    registered' = registered backends.${backend};
  in {
    # 119. Both ids keep their own package: a fixed vendor switch drops the new id.
    "a second owner registers a selectable fill" =
      builtins.all (readers:
        builtins.attrNames readers
        == ["claude" "sample"]
        && exe readers.sample == lib.getExe fill
        && readers.sample.endpoint == "https://owner.example"
        && readers.sample.transports == ["cpa"]
        && exe readers.claude == lib.getExe shipped
        && readers.claude.endpoint == "https://api.anthropic.com"
        && readers.claude.transports == ["direct" "cpa"])
      [
        (registered' [(owner "sample")])
        (merged [usageModule (owner "sample")] {})
      ];
    # 120. Two owners default one id: letting the last owner win evaluates here.
    # Only the package differs. Force its executable without forcing a whole derivation.
    "two concrete fills for one id fail evaluation" =
      builtins.all (readers: !(builtins.tryEval (exe readers.claude)).success)
      [
        (registered' [conflict])
        (merged [usageModule conflict] {})
      ];
    # 121. An explicit selection wins and the shipped command is the same everywhere:
    # a constructor that ignores the selection returns the shipped command instead.
    "standalone, Home Manager and devenv resolve the same selected reader" =
      exe (registered' [selection]).claude
      == lib.getExe fill
      && exe (merged [usageModule] selection.ai.credentialUsage.readers).claude == lib.getExe fill
      && exe (registered' []).claude == lib.getExe shipped
      && exe (merged [usageModule] {}).claude == lib.getExe shipped;
    # All constructors select the command executed by the transport check below.
    "the registered binding selects the same executable" =
      exe (registered' [binding]).claude == exe selected && exe selected != lib.getExe shipped;
  };
  failures = backend: lib.attrNames (lib.filterAttrs (_: passed: !passed) (cases backend));
  # Independent evaluations name the backend and each failed case.
  checks = lib.mapAttrs (backend: _:
    harness.mkTest "credential-usage-registration-${backend}" (
      lib.assertMsg (failures backend == []) "${backend}: ${lib.concatStringsSep "; " (failures backend)}"
    ))
  backends;
in {
  checks.credential-usage-registration = pkgs.runCommand "credential-usage-registration" {nativeBuildInputs = [claude python];} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    mkdir "$out"
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: path: "ln -s ${path} \"$out/${name}\"") checks)}
    python3 -I - <<'PYTHON'
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    import json
    import os
    import secrets
    import subprocess
    from threading import Event, Thread

    from pydantic import BaseModel, ConfigDict, ValidationError

    requests = []
    finished = Event()

    class ForwardedCall(BaseModel):
        model_config = ConfigDict(strict=True, hide_input_in_errors=True)
        auth_index: str

    class Discovery(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def reply(self, value):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(json.dumps(value).encode())

        def do_GET(self):
            requests.append((self.path, self.headers.get("Authorization"), None))
            if len(requests) == 1:
                # A silent peer forces the selected HTTP timeout and retry.
                finished.wait(10)
                return
            self.reply({"files": [
                {"account_type": "oauth", "provider": "claude", "auth_index": index}
                for index in ("other", "selected")
            ]})

        def do_POST(self):
            try:
                payload = ForwardedCall.model_validate_json(self.rfile.read(int(self.headers["Content-Length"])))
            except ValidationError:
                self.send_error(400)
                return
            requests.append((self.path, self.headers.get("Authorization"), payload.auth_index))
            self.reply({"status_code": 503, "body": "private response"})

    key = secrets.token_hex(32)
    with ThreadingHTTPServer(("127.0.0.1", 49264), Discovery) as server:
        Thread(target=server.serve_forever, daemon=True).start()
        try:
            result = subprocess.run(
                ["${exe selected}"], input=key, text=True, capture_output=True, timeout=8,
                env={**os.environ, "DELEGATE_USAGE_CPA_CLAUDE_URL": "http://ignored.invalid"},
            )
        finally:
            finished.set()
            server.shutdown()
    assert result.returncode == 1 and not result.stdout
    assert result.stderr == "usage: claude usage request failed\n"
    # 34, 40, 121–124. Retrying discovery must preserve the bound endpoint,
    # runtime key and chosen auth index even with two eligible logins.
    assert requests == [
        ("/selected/v0/management/auth-files", f"Bearer {key}", None),
        ("/selected/v0/management/auth-files", f"Bearer {key}", None),
        ("/selected/v0/management/api-call", f"Bearer {key}", "selected"),
    ]
    PYTHON
  '';
}
