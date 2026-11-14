"""Production-shaped source bypasses and controls for the patch policy."""

import pathlib
import runpy
import sys

policy = runpy.run_path(sys.argv[1] if len(sys.argv) > 1 else str(pathlib.Path(__file__).with_name('patch-policy.py')))
violations = policy['violations']
for command in [
    'git apply fix.patch',
    'patch -p1 < fix.patch',
    '${lib.getExe pkgs.gitMinimal} apply fix.patch',
    '${lib.getExe pkgs.gnupatch} -p1 < fix.patch',
    '${pkgs.gitMinimal}/bin/git apply fix.patch',
    '${pkgs.gnupatch}/bin/patch -p1 < fix.patch',
]:
    for shell in [
        command,
        f'if {command}; then echo ok; fi',
        f'if false; then echo skip; elif {command}; then echo ok; fi',
        f'if true; then {command}; else echo skip; fi',
        f'if false; then echo skip; else {command}; fi',
        f'until {command}; do echo retry; done',
        f'while {command}; do echo retry; done',
        f'for input in fix.patch; do {command}; done',
        f'! {command}',
        f'{{ {command}; }}',
    ]:
        source = f"postPatch = ''{shell}'';"
        assert violations('packages/example/package.nix', source), source
for source in [
    'patches = [ ./fix.patch ];',
    '"patchFlags"\n = [ "-p1" ];',
    'inherit patches;',
    'inherit\n (old)\n patches;',
    'inherit (old) version patchFlags;',
    'pkgs.applyPatches { src = upstream; }',
    'pkgs."applyPatches" { src = upstream; }',
    '"${pkgs.applyPatches { src = upstream; }}"',
    "postPatch = ''patch -p1 < fix.patch'';",
    "postPatch = ''/usr/bin/patch -p1 < fix.patch'';",
    'postPatch = \'\'"/usr/bin/patch" -p1 < fix.patch\'\';',
    "postPatch = ''${pkgs.patch}/bin/patch \\\n -p1 < fix.patch'';",
    "postPatch = ''${lib.getExe pkgs.patch} -p1 < fix.patch'';",
    "postPatch = ''git apply fix.patch'';",
    'postPatch = \'\'git -C "path with spaces" apply input.patch\'\';',
    "postPatch = ''git -C 'path with spaces' apply input.patch'';",
    "postPatch = ''${pkgs.git}/bin/git -C ${source} apply input.patch'';",
    "postPatch = ''git apply --check fix.patch; git apply fix.patch'';",
    "postPatch = ''${pkgs.git}/bin/git -C source apply fix.patch'';",
    "postPatch = ''/usr/bin/git \\\n apply fix.patch'';",
    'postPatch = "patch -p1 < fix.patch";',
]:
    assert violations('packages/example/package.nix', source), source
for source in [
    '# patches = [];\n/* pkgs.applyPatches {}; */ version = "2.0";',
    'description = "patch the binary";',
    'src = (packageLib.patching {inherit pkgs;}).source {patchFiles = [./fix.patch];};',
    "postPatch = ''# patch -p1 < fix.patch\necho 'patch -p1' '';",
    "postPatch = ''git apply --check --reverse fix.patch'';",
    "postPatch = ''git diff -- apply.patch'';",
    "postPatch = ''${pkgs.git}/bin/git apply --check fix.patch'';",
    "postPatch = ''if ${lib.getExe pkgs.gitMinimal} apply --check fix.patch; then echo ok; fi'';",
    "postPatch = ''while git diff -- apply.patch; do echo patch; done'';",
    "postPatch = ''echo if patch; echo while git apply; echo gnupatch'';",
    'postPatch = \'\'git -C "path with spaces" apply --check input.patch\'\';',
    "postPatch = ''${pkgs.git}/bin/git -C ${source} apply --check input.patch'';",
    "postPatch = ''${pkgs.git}/bin/git -C ${source} diff -- apply.patch'';",
    'inherit (source) version; patchFiles = [];',
    'name = "patch-helper";',
]:
    assert not violations('packages/example/package.nix', source), source
for path, entries in policy['PNPM'].items():
    source = '\n'.join('# ' + reason + '\n' + operation for operation, reason in entries)
    assert not violations(path, source)
    assert not violations(path, source + '\nversion = "99.0.0";')
    assert violations(path, source.replace(entries[0][0], 'removed-operation'))
    assert violations(path, source.replace(entries[0][1], 'removed-reason'))
for path, snippets in policy['FIXTURES'].items():
    source = '\n'.join(snippets)
    assert not violations(path, source)
    assert violations(path, source + '\npatchFlags = [];')
    assert violations(path, source.replace(snippets[0], ''))
print('PASS: forbidden forms, comments, helper calls, read-only Git, unrelated versions, stale exceptions')
