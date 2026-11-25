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
  shipped = binding:
    usageReader ({
        inherit pkgs;
        python-stack = pkgs.ai.generic.python-stack;
        # The shipped Reader bundles no CLI; it reads the `claude` on PATH.
        claude = pkgs.emptyDirectory;
      }
      // binding);
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
  moduleReaders = evaluate: contributions: overrides:
    (evaluate (contributions ++ [{ai.credentialUsage.readers = overrides;}])).config.ai.credentialUsage.readers;
  constructors = {
    devenv = moduleReaders harness.evalDevenvModules;
    hm = moduleReaders harness.evalHmModules;
    standalone = contributions: overrides:
      mergeReaders {
        contributions = [usageModule] ++ contributions;
        inherit overrides;
      };
  };
  exe = reader: lib.getExe reader.package;
  selection.claude.package = fill;
  conflict = {ai.credentialUsage.readers.claude.package = lib.mkDefault fill;};
  direct.policy = {
    retries = 2;
    timeout = 0.375;
  };
  cpa = {
    endpoint = "http://127.0.0.1:49264/selected";
    managementKeyFile = "/dev/stdin";
    pin = "selected";
    policy = {
      retries = 1;
      timeout = 0.25;
    };
  };
  selected = (constructors.standalone [] {claude = {inherit cpa;};}).claude;
  cases = resolve: let
    readers = resolve [(owner "sample")] {};
    directReader = (resolve [] {claude = {inherit direct;};}).claude;
  in {
    # 119. A fixed vendor switch drops the second owner's id or substitutes Claude for it.
    "a second owner registers a selectable fill" =
      builtins.attrNames readers
      == ["claude" "sample"]
      && exe readers.sample == lib.getExe fill
      && readers.sample.endpoint == "https://owner.example"
      && readers.sample.transports == ["cpa"]
      && exe readers.claude == lib.getExe (shipped {})
      && readers.claude.endpoint == "https://api.anthropic.com"
      && readers.claude.transports == ["direct" "cpa"];
    # 120. Letting the last owner win would resolve the conflicting package.
    "two concrete fills for one id fail evaluation" =
      !(builtins.tryEval (exe (resolve [conflict] {}).claude)).success;
    # 121. Ignoring the explicit package returns the shipped command instead.
    "explicit package selection wins" =
      exe (resolve [] selection).claude
      == lib.getExe fill
      && exe (resolve [] {}).claude == lib.getExe (shipped {});
    # 121, 123. Selecting a different command for the same binding drops its policy.
    # Compare each constructor with the owner's bound command, also exercised on the wire.
    "the registered binding selects the configured command" =
      exe (resolve [] {claude = {inherit cpa;};}).claude
      == lib.getExe (shipped {inherit cpa;})
      && exe selected != lib.getExe (shipped {})
      && directReader.direct == direct
      && exe directReader == lib.getExe (shipped {inherit direct;})
      && exe directReader != lib.getExe (shipped {});
  };
  failures = backend: lib.attrNames (lib.filterAttrs (_: passed: !passed) (cases constructors.${backend}));
  # Independent evaluations name the backend and each failed case.
  checks = lib.mapAttrs (backend: _:
    harness.mkTest "credential-usage-registration-${backend}" (
      lib.assertMsg (failures backend == []) "${backend}: ${lib.concatStringsSep "; " (failures backend)}"
    ))
  constructors;
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
