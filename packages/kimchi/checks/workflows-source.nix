{
  lib,
  pkgs,
  ...
}: let
  kimchi = pkgs.ai.kimchi;
  workflows = pkgs.ai.kimchi-workflows;
  pin = builtins.fromJSON (builtins.readFile ../workflows-sources.json);
in {
  checks = {
    kimchi-workflows-payload = pkgs.runCommand "kimchi-workflows-payload-check" {nativeBuildInputs = [pkgs.nodejs];} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      test -f ${workflows}/src/host/extension.ts
      test -f ${workflows}/dist/host/extension.js
      node --input-type=module <<'JS'
      import assert from 'node:assert/strict';
      import fs from 'node:fs';
      const root = '${workflows}';
      const manifest = JSON.parse(fs.readFileSync(root + '/package.json', 'utf8'));
      assert.equal(manifest.version, '${pin.version}');
      assert.equal(manifest.nixSourceRev, '${pin.rev}');
      assert.deepEqual(manifest.pi.extensions, ['./src/host/extension.ts']);
      for (const name of Object.keys(manifest.dependencies)) {
        assert(fs.existsSync(root + '/node_modules/' + name), name);
      }
      for (const name of Object.keys(manifest.peerDependencies)) {
        assert(!fs.existsSync(root + '/node_modules/' + name), name);
      }
      for (const name of fs.readdirSync(root + '/node_modules', {recursive: true})) {
        const entry = root + '/node_modules/' + name;
        if (fs.lstatSync(entry).isSymbolicLink()) {
          assert(fs.realpathSync(entry).startsWith(root + '/'), entry);
        }
      }
      JS
      echo PASS > "$out"
    '';

    # Slash commands dispatch before model/credential validation. The observer
    # intercepts unrecognized input, so the negative cannot make a model turn.
    kimchi-workflows-smoke = pkgs.runCommand "kimchi-workflows-smoke" {nativeBuildInputs = [pkgs.python3];} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      python ${./workflows-smoke.py} ${kimchi}/bin/kimchi ${workflows} ${./workflows-observer.ts}
      echo PASS > "$out"
    '';

    # Copies only the two registration files: no Kimchi compile or dependency
    # build. The same exact substitutions run in Kimchi's postPatch phase.
    kimchi-workflows-source = assert workflows.version == pin.version && workflows.sourceRev == pin.rev;
      pkgs.runCommand "kimchi-externalized-extensions-source-check" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        mkdir -p src/resources
        cp ${kimchi.src}/src/cli.ts src/cli.ts
        cp ${kimchi.src}/src/resources/definitions.ts src/resources/definitions.ts
        chmod u+w src/cli.ts src/resources/definitions.ts
        ${kimchi.externalizeExtensions}
        ${lib.concatMapStrings (extension: ''
            if grep -F ${lib.escapeShellArg extension.id} src/cli.ts src/resources/definitions.ts; then
              echo 'externalized resource is still registered' >&2
              exit 1
            fi
            if grep -F ${lib.escapeShellArg extension.importLine} src/cli.ts; then
              echo 'externalized extension is still imported' >&2
              exit 1
            fi
          '')
          kimchi.externalizedExtensions}
        echo PASS > "$out"
      '';
  };
}
