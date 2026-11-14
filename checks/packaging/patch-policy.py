"""Reject owned Nix patch bypasses, not arbitrary computed Nix obfuscation.

Recognize direct/quoted bindings, inherit, applyPatches references, and shell
GNU patch / Git apply (bare, absolute or interpolated; continued lines).
Nix comments and shell comments are ignored; shell strings remain inspected.
The pnpm table records application delegated to the package manager, with local
reasons and operation anchors rather than release versions or whole-file hashes.
"""

import pathlib
import re
import sys


# Standard package aliases share interpolation handling with their executables.
PATCH_TOOL = r'pkgs\.(?:git(?:Minimal)?|gnupatch|patch)'
GET_EXE = rf'(?:lib\.)?getExe\s+{PATCH_TOOL}'


# Path, operation, local reason. No version/hash is part of these exceptions.
PNPM = {
    "packages/kimchi/checks/package-identity.nix": [
        ("pkgs.pnpmConfigHook", "pnpmConfigHook owns the offline patchedDependencies install across peers."),
    ],
    "packages/kimchi/packages/ai/kimchi/package.nix": [
        ("pnpmDeps = pkgs.fetchPnpmDeps", "pnpm owns patchedDependencies across peer variants during fetching."),
        ("pkgs.pnpmConfigHook", "pnpmConfigHook repeats the patchedDependencies install offline for the build."),
    ],
    "packages/kimchi/packages/ai/kimchiExtensions/kimchi-workflows/package.nix": [
        ("[pkgs.nodejs kimchi.pnpmDeps.pnpm pkgs.pnpmConfigHook]", "pnpmConfigHook owns Kimchi patchedDependencies for every toolchain peer."),
    ],
    "packages/oxlint/checks.nix": [
        ("pkgs.pnpmConfigHook", "Exercise the real offline configure hook and production preBuild probe,"),
    ],
    "packages/oxlint/packages/ai/devTools/oxlint/package.nix": [
        ("pnpmDeps = pkgs.fetchPnpmDeps", "pnpm owns patchedDependencies during fetching; pre-applying skips peers."),
        ("prev.nativeBuildInputs or []", "pnpmConfigHook installs patchedDependencies offline across every peer."),
    ],
}
# Exact fixture statements only: changing flags or adding another bypass fails.
FIXTURES = {
    "checks/packaging/patch-artifacts.nix": [
        'patch -p1 --fuzz=0 < "$patchFile"',
    ],
    "checks/packaging/patch-helper.nix": [
        'rejectsOverride = builtins.tryEval (builtins.deepSeq (patching.attrs {patchFlags = ["--fuzz=2"];}) true);',
        '(cd baseline; patch -p1 --fuzz=0 < ${patch 1})',
        '(cd baseline-drift; patch -p1 < ${patch 1})',
    ],
}


def views(text):
    """Mask comments and string bodies in code; collect intact shell strings.

    Recurse into Nix interpolations so bindings there still get checked. Keep
    offsets/newlines for diagnostics. This is a lexer, not a Nix evaluator.
    """
    code = list(text)
    strings = []

    def blank(start, end):
        code[start:end] = ['\n' if c == '\n' else ' ' for c in text[start:end]]

    def walk(i, interpolation=False):
        depth = 0
        while i < len(text):
            start = i
            if text.startswith('/*', i) or text[i] == '#':
                end = text.find('*/' if text[i] == '/' else '\n', i + 1)
                i = len(text) if end < 0 else end + (2 if text[start] == '/' else 0)
                blank(start, i)
            elif text.startswith("''", i) or text[i] == '"':
                delimiter = "''" if text.startswith("''", i) else '"'
                i += len(delimiter)
                body = i
                interpolations = []
                while i < len(text):
                    if delimiter == "''" and (text.startswith("'''", i) or text.startswith("''$", i) or text.startswith("''\\", i)):
                        i += 3
                    elif delimiter == '"' and text[i] == '\\':
                        i += 2
                    elif text.startswith('${', i):
                        begin = i + 2
                        i = walk(begin, True)
                        interpolations.append((begin, i - 1, code[begin:i - 1]))
                    elif text.startswith(delimiter, i):
                        break
                    else:
                        i += 1
                end = i
                i += len(delimiter)
                shell = list(text[body:end])
                for begin, finish, _ in interpolations:
                    expression = text[begin:finish]
                    if not re.fullmatch(rf'\s*(?:{PATCH_TOOL}|{GET_EXE})\s*', expression):
                        # An unknown Nix value is still a shell operand, not whitespace.
                        shell[begin - 2 - body:finish + 1 - body] = ['_' if c != '\n' else '\n' for c in text[begin - 2:finish + 1]]
                if not re.search(r'\bdescription\s*=\s*$', text[max(0, start - 100):start]):
                    strings.append((body, ''.join(shell)))
                # Quoted attribute names stay visible; other strings do not.
                if delimiter == '"' and re.fullmatch(r'patches|patchFlags|applyPatches', text[body:end]):
                    code[start] = code[end] = ' '
                else:
                    # Preserve interpolation code already visited separately.
                    blank(start, i)
                    for begin, end, content in interpolations:
                        code[begin:end] = content
            elif interpolation and text[i] == '}' and depth == 0:
                return i + 1
            else:
                depth += (text[i] == '{') - (text[i] == '}')
                i += 1
        return i

    walk(0)
    return ''.join(code), strings


ATTRIBUTE = re.compile(r'\b(?:patches|patchFlags)\s*=|\bapplyPatches\b|\binherit\b[^;]*\b(?:patches|patchFlags)\b[^;]*;', re.S)
# Command starts include shell operators, substitutions and compound prefixes.
COMMAND = re.compile(
    r'(?:^|[\n;|&(`])\s*(?:(?:do|elif|else|if|then|until|while|!|\{)\s+)*(?:exec\s+)?["\']?'
    rf'(?P<exe>(?:\$\{{[^}}]+\}}|/[^\s"\';|&]+)?(?:/bin/)?(?:patch|git)|\$\{{\s*{GET_EXE}\s*\}})'
    r'["\']?(?=\s|$)(?P<args>[^\n;|&`]*)', re.M,
)
SHELL_WORD = r'''(?:[^\s"']+|"[^"\n]*"|'[^'\n]*')+'''


def violations(path, text):
    if path == 'lib/packaging/patching.nix':
        return []  # The sole implementation, not a consumer exception.
    errors = []
    for snippet in FIXTURES.get(path, []):
        if text.count(snippet) != 1:
            errors.append('stale negative-control operation: ' + snippet)
        text = text.replace(snippet, ' ' * len(snippet))
    code, strings = views(text)
    for match in ATTRIBUTE.finditer(code):
        errors.append(f'line {code.count(chr(10), 0, match.start()) + 1}: direct patch attribute/application')
    for offset, body in strings:
        body = re.sub(r'\\\n', '  ', body)
        body = re.sub(r'(?m)^\s*#[^\n]*', '', body)
        for match in COMMAND.finditer(body):
            exe, args = match['exe'], match['args']
            if 'git' in exe:
                application = re.match(rf'\s*(?:(?:-C|-c|--git-dir|--work-tree)\s+{SHELL_WORD}\s+|--[\w-]+(?:={SHELL_WORD})?\s+)*apply(?:\s|$)', args)
                if not application or re.search(r'(?:^|\s)--check(?:\s|$)', args[application.end():]):
                    continue
            errors.append(f'line {text.count(chr(10), 0, offset + match.start()) + 1}: direct patch command')
    for operation, reason in PNPM.get(path, []):
        if operation not in code or '# ' + reason not in text:
            errors.append('stale pnpm exception: ' + operation)
    return errors


def scan(root):
    count = 0
    errors = []
    for directory in ('checks', 'dev', 'lib', 'packages'):
        for file in sorted((root / directory).rglob('*.nix')):
            if not file.is_file():
                continue
            count += 1
            path = file.relative_to(root).as_posix()
            errors.extend(f'{path}: {error}' for error in violations(path, file.read_text()))
    if not count:
        errors.append('no Nix source files scanned')
    for path in PNPM.keys() | FIXTURES.keys():
        if not (root / path).is_file():
            errors.append('stale exception path: ' + path)
    return count, errors


if __name__ == '__main__':
    count, errors = scan(pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else '.'))
    print('\n'.join(errors) if errors else f'patch-policy: {count} Nix files passed; pnpm operations/reasons current')
    sys.exit(bool(errors))
