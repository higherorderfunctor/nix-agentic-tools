import ast
import hashlib
import json
import pathlib
import tree_sitter
import tree_sitter_typescript

# codex:R0 — TypeScript (tree-sitter) and Python (ast) SDK declarations of the pinned source.
# usage: python3 sdk_ast.py → <work>/inventory/sdk-ast.json (work = $PROBE_OUT/codex-inventory or a temp dir)
import sys  # noqa: E402
S = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(S))
import codexpin  # noqa: E402
ROOT = codexpin.source()
WORK = codexpin.workdir('codex-inventory')
(WORK / 'inventory').mkdir(exist_ok=True)
parser = tree_sitter.Parser(tree_sitter.Language(tree_sitter_typescript.language_typescript()))
entries = []
manifest = []
for p in sorted((ROOT / 'sdk/typescript/src').glob('*.ts')):
    data = p.read_bytes()
    tree = parser.parse(data)
    manifest.append(dict(path=str(p.relative_to(ROOT)), sha256=hashlib.sha256(data).hexdigest(), ast_has_error=tree.root_node.has_error))
    def walk(n):
        if n.type in {'method_definition', 'function_declaration', 'class_declaration', 'type_alias_declaration'}:
            name = n.child_by_field_name('name')
            entries.append(dict(path=str(p.relative_to(ROOT)), line=n.start_point.row+1, kind=n.type, name=data[name.start_byte:name.end_byte].decode() if name else None, source=data[n.start_byte:n.end_byte].decode()))
        for child in n.named_children:
            walk(child)
    walk(tree.root_node)
for p in sorted((ROOT / 'sdk/python/src/openai_codex').glob('*.py')):
    text = p.read_text()
    tree = ast.parse(text)
    manifest.append(dict(path=str(p.relative_to(ROOT)), sha256=hashlib.sha256(text.encode()).hexdigest(), ast_has_error=False))
    for n in ast.walk(tree):
        if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            entries.append(dict(path=str(p.relative_to(ROOT)), line=n.lineno, kind=type(n).__name__, name=n.name, source=ast.get_source_segment(text,n)))
(WORK/'inventory/sdk-ast.json').write_text(json.dumps(entries,indent=2))
(WORK/'inventory/sdk-manifest.json').write_text(json.dumps(manifest,indent=2))
print(json.dumps(dict(files=len(manifest), declarations=len(entries))))
