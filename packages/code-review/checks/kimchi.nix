{
  harness,
  pkgs,
  ...
}: let
  framework = pkgs.ai.kimchiExtensions.kimchi-workflows;
  package = pkgs.ai.code-review;
  delivered = harness.evalHm {
    ai.kimchi.enable = true;
    ai.programs.code-review = {
      enable = true;
      runtimes.kiro.enable = false;
    };
  };
  skill = delivered.config.ai.kimchi.skills.code-review;
  storeEntry = pkgs.writeText "code-review-store.workflow.ts" ''
    import { createReviewWorkflow, roles, type Profile } from "${package}/share/code-review/kimchi/workflow.ts";
    export default createReviewWorkflow({
      roles: Object.fromEntries(roles.map(role => [role, {model_id: `fixture/''${role}`, effort: "high"}])) as Profile["roles"],
      limits: {concurrency: 6, max_waves: 3}
    });
  '';
in {
  checks.code-review-kimchi = pkgs.stdenvNoCC.mkDerivation {
    pname = "code-review-kimchi-check";
    version = "1";
    inherit (framework) pnpmDeps src;
    nativeBuildInputs = [pkgs.git pkgs.nodejs pkgs.pnpmConfigHook framework.pnpmDeps.pnpm pkgs.python3];
    dontBuild = true;
    doCheck = true;
    checkPhase = ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      export HOME="$TMPDIR/home"
      mkdir -p node_modules/@kimchi-dev suite
      ln -s ${framework} node_modules/@kimchi-dev/kimchi-workflows
      cp -r ${framework}/dist .
      export CODE_REVIEW_STORE_ENTRY=${storeEntry}
      cp -r ${package}/share/code-review/. suite/
      chmod -R u+w suite
      cp ${../src/kimchi}/offline-entry.workflow.ts ${../src/kimchi}/workflow.test.ts suite/kimchi/
      cp ${../src/transport}/offline-entry.workflow.ts ${../src/transport}/workflow.test.ts suite/transport/
      node ${framework}/bin/kimchi-workflows.mjs verify --entry ${storeEntry} --test ./suite/kimchi/workflow.test.ts --package-root .
      node ${framework}/bin/kimchi-workflows.mjs verify --entry ./suite/transport/offline-entry.workflow.ts --test ./suite/transport/workflow.test.ts --package-root .
      cp ${./saved-entries.test.ts} suite/saved-entries.test.ts
      CODE_REVIEW_SAVED_ENTRIES="$(${pkgs.python3}/bin/python3 - ${skill}/SKILL.md <<'PY'
      import json, pathlib, re, sys
      skill = pathlib.Path(sys.argv[1]).read_text()
      print(json.dumps([re.search(label.replace(" ", r"\s+") + r":\s*`([^`]+)`", skill).group(1) for label in ["Review workflow", "Pull workflow", "Push workflow"]]))
      PY
      )"
      export CODE_REVIEW_SAVED_ENTRIES
      ${pkgs.python3}/bin/python3 - <<'PY'
      import json, os, subprocess
      for entry in json.loads(os.environ['CODE_REVIEW_SAVED_ENTRIES']):
          subprocess.run(['node', '${framework}/bin/kimchi-workflows.mjs', 'verify', '--entry', entry, '--test', './suite/saved-entries.test.ts', '--package-root', '.'], check=True)
      PY
    '';
    installPhase = ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      touch "$out"
    '';
  };
}
