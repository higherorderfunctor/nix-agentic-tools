"""Check and pre-commit entry point: refuse direct patches in owned Nix sources.

Tree-sitter separates Nix code and shell strings, then identifies Bash commands.
This checks direct forms, not arbitrary computed Nix obfuscation.
"""

import pathlib
import re
import shlex
import sys

from tree_sitter import Language, Parser
import tree_sitter_bash
import tree_sitter_nix

BASH = Parser(Language(tree_sitter_bash.language()))
NIX = Parser(Language(tree_sitter_nix.language()))


# Standard package aliases share interpolation handling with their executables.
PATCH_TOOL = r'pkgs\.(?:git(?:Minimal)?|gnupatch|patch)'
GET_EXE = rf'(?:lib\.)?getExe\s+{PATCH_TOOL}'


# Exact fixture statements only: changing flags or adding another bypass fails.
FIXTURES = {
    "checks/packaging/patch-artifacts.nix": [
        'patch -p1 --fuzz=0 < "$patchFile"',
    ],
    "checks/packaging/patch-helper.nix": [
        'rejectsOverride = builtins.tryEval (builtins.deepSeq (patching.attrs {patchFlags = ["--fuzz=2"];}) true);',
        '(cd baseline; patch -p1 --fuzz=0 < ${patch})',
        '(cd baseline-drift; patch -p1 < ${patch})',
    ],
}


def views(text):
    """Use Nix syntax to keep code and shell strings in separate scan views."""
    source = text.encode()
    code = bytearray(source)
    strings = []

    def blank(start, end):
        code[start:end] = bytes(10 if byte == 10 else 32 for byte in source[start:end])

    def visit(node):
        start, end = node.start_byte, node.end_byte
        if node.type == 'comment':
            blank(start, end)
        elif node.type in {'string_expression', 'indented_string_expression'}:
            delimiter = 2 if node.type == 'indented_string_expression' else 1
            body, finish = start + delimiter, end - delimiter
            shell = bytearray(source[body:finish])
            interpolations = []
            for child in node.named_children:
                if child.type != 'interpolation':
                    continue
                visit(child)
                begin, stop = child.start_byte, child.end_byte
                interpolations.append((begin, stop, code[begin:stop]))
                expression = source[begin + 2:stop - 1].decode()
                width = stop - begin
                if re.fullmatch(rf'\s*{GET_EXE}\s*', expression):
                    replacement = ('git' if 'git' in expression else 'patch').ljust(width)
                elif re.fullmatch(rf'\s*{PATCH_TOOL}\s*', expression):
                    replacement = '/'.ljust(width, '_')
                else:
                    # Unknown interpolation remains one shell operand.
                    replacement = ''.join('\n' if byte == 10 else '_' for byte in source[begin:stop])
                shell[begin - body:stop - body] = replacement.encode()
            if not re.search(rb'\bdescription\s*=\s*$', source[max(0, start - 100):start]):
                strings.append((body, shell.decode()))
            if delimiter == 1 and source[body:finish] in {b'patches', b'patchFlags', b'applyPatches'}:
                code[start] = code[end - 1] = 32
            else:
                blank(start, end)
                for begin, stop, content in interpolations:
                    code[begin:stop] = content
        else:
            for child in node.named_children:
                visit(child)

    visit(NIX.parse(source).root_node)
    return code.decode(), strings


ATTRIBUTE = re.compile(r'\b(?:patches|patchFlags)\s*=|\bapplyPatches\b|\binherit\b[^;]*\b(?:patches|patchFlags)\b[^;]*;', re.S)

def descendants(node):
    yield node
    for child in node.named_children:
        yield from descendants(child)


def shell_commands(body):
    """Read command words from Bash syntax, excluding comments and redirects."""
    for node in descendants(BASH.parse(body.encode()).root_node):
        if node.type != 'command':
            continue
        operands = [child for child in node.named_children
                    if child.type not in {'variable_assignment', 'file_redirect', 'heredoc_redirect'}]
        parent = node.parent
        if parent.type == 'negated_command':
            parent = parent.parent
        if parent.type == 'redirected_statement':
            for redirect in parent.named_children:
                if redirect.type == 'file_redirect':
                    # Bash's grammar groups words after a redirect as destinations.
                    # Only its first destination is a filename; the rest are argv.
                    operands.extend(redirect.children_by_field_name('destination')[1:])
        words = []
        for operand in operands:
            try:
                words.extend(shlex.split(operand.text.decode()))
            except ValueError:
                words.append(operand.text.decode())
        if words and words[0] == 'exec':
            words.pop(0)
        if words:
            yield node.start_point.row, words


def git_applies(command):
    """Distinguish Git application from read-only apply --check."""
    i = 0
    while i < len(command):
        word = command[i]
        if word in {'-C', '-c', '--git-dir', '--work-tree'}:
            i += 2
        elif word.startswith('--'):
            i += 1
        else:
            break
    if i >= len(command) or command[i] != 'apply':
        return False
    options = command[i + 1:]
    if '--' in options:
        options = options[:options.index('--')]
    return '--apply' in options or '--check' not in options


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
        for row, words in shell_commands(body):
            executable = words[0].rsplit('/', 1)[-1]
            if executable == 'patch' or (executable == 'git' and git_applies(words[1:])):
                errors.append(f'line {text.encode().count(b'\n', 0, offset) + row + 1}: direct patch command')
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
    for path in FIXTURES.keys():
        if not (root / path).is_file():
            errors.append('stale exception path: ' + path)
    return count, errors


if __name__ == '__main__':
    count, errors = scan(pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else '.'))
    print('\n'.join(errors) if errors else f'patch-policy: {count} Nix files passed')
    sys.exit(bool(errors))
