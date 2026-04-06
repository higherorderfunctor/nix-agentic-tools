# withBuddy — patch claude-code binary with a pre-computed buddy salt.
{
  lib,
  mkBuddySalt,
  python3,
  runCommand,
  sigtool ? null,
  stdenv,
}: claude-code: buddyOpts: let
  salt = builtins.readFile (mkBuddySalt buddyOpts);
  original = "friend-2026-401";
in
  runCommand "claude-code-buddy-${buddyOpts.species}-${buddyOpts.rarity or "common"}" {
    nativeBuildInputs =
      [python3]
      ++ lib.optional stdenv.hostPlatform.isDarwin sigtool;
    meta = claude-code.meta or {};
  } ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :

    cp -r ${claude-code} $out
    chmod -R u+w $out

    patched=0
    for f in $(find $out -type f \( -name "claude-code" -o -name "cli.js" -o -name "cli.mjs" \)); do
      python3 -c "
    import sys
    path = sys.argv[1]
    old = sys.argv[2].encode()
    new = sys.argv[3].encode()
    data = open(path, 'rb').read()
    count = data.count(old)
    if count > 0:
        patched = data.replace(old, new)
        open(path, 'wb').write(patched)
        print(f'Patched {count} occurrence(s) in {path}')
    " "$f" "${original}" "${salt}" && patched=1
    done

    if [[ "$patched" -eq 0 ]]; then
      echo "ERROR: salt '${original}' not found in any binary" >&2
      exit 1
    fi

    ${lib.optionalString stdenv.hostPlatform.isDarwin ''
      codesign --force --sign - $out/bin/claude-code
    ''}
  ''
