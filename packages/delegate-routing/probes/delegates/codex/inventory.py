import gc

gc.disable()

import hashlib
import json
import os
import pathlib
import subprocess

import tree_sitter
import tree_sitter_rust

# codex:R0 — CLI help/feature inventory, emitted app-server schema, tree-sitter Rust AST of the
# pinned source, committed fixtures. Needs tree-sitter==0.25.2 and tree-sitter-rust==0.24.2 (see README).
# usage: python3 inventory.py   → <work>/inventory/ (work = $PROBE_OUT/codex-inventory or a temp dir)
S = pathlib.Path(__file__).resolve().parent
import sys  # noqa: E402
sys.path.insert(0, str(S))
import codexpin  # noqa: E402
SRC = codexpin.source()
B = codexpin.binary()
R = codexpin.repo_root()
WORK = codexpin.workdir('codex-inventory')
OUT = WORK / 'inventory'
OUT.mkdir(exist_ok=True)
HOME = OUT / 'home'
HOME.mkdir(exist_ok=True)
env = dict(os.environ, CODEX_HOME=str(HOME))
commands = [[], ['exec'], ['exec', 'resume'], ['exec', 'fork'], ['review'], ['app-server'], ['cloud'], ['cloud', 'exec'], ['cloud', 'status'], ['cloud', 'list'], ['cloud', 'diff'], ['cloud', 'apply'], ['help', 'mcp-server'], ['features', 'list'], ['queue'], ['agents'], ['remote-control'], ['exec-server']]
help_results = []
for args in commands:
    cmd = [B, *args] if args == ['features', 'list'] else [B, *args, '--help']
    r = subprocess.run(cmd, capture_output=True, text=True, env=env, cwd=WORK, timeout=30)
    help_results.append(dict(argv=cmd, exit=r.returncode, stdout=r.stdout, stderr=r.stderr))
(OUT / 'cli.json').write_text(json.dumps(help_results, indent=2))
cmd = [B, 'app-server', 'generate-json-schema', '--experimental', '--out', str(OUT / 'schema')]
r = subprocess.run(cmd, capture_output=True, text=True, env=env, cwd=WORK, timeout=30)
assert r.returncode == 0, r.stderr
schema = json.loads((OUT / 'schema' / 'codex_app_server_protocol.schemas.json').read_text()) if (OUT / 'schema' / 'codex_app_server_protocol.schemas.json').exists() else None
(OUT / 'schema-generation.json').write_text(json.dumps(dict(argv=cmd, exit=r.returncode, stdout=r.stdout, stderr=r.stderr), indent=2))
parser = tree_sitter.Parser(tree_sitter.Language(tree_sitter_rust.language()))
patterns = ['core/src/agent/**/*.rs', 'core/src/tools/handlers/multi_agents*.rs', 'core/src/tools/handlers/multi_agents/**/*.rs', 'core/src/tools/handlers/multi_agents_v2/**/*.rs', 'core/src/session/multi_agents.rs', 'core/src/config/mod.rs', 'core/src/tools/registry.rs', 'core/src/tools/mod.rs', 'config/src/config_toml.rs', 'config/src/hook_config.rs', 'features/src/*.rs', 'cli/src/main.rs', 'exec/src/lib.rs', 'exec/src/cli.rs', 'app-server-protocol/src/protocol/v2.rs', 'app-server-protocol/src/protocol/common.rs', 'app-server/src/request_processors/thread_processor.rs', 'app-server/src/request_processors/thread_processor/**/*.rs', 'app-server/src/request_processors/turn_processor.rs', 'core/src/tasks/mod.rs', 'core/src/session/handlers.rs', 'core/src/session/mod.rs', 'core/src/tools/spec_plan.rs', 'core/src/agent_message_board.rs', 'ext/agent-message-board/src/**/*.rs', 'ext/agent/src/lib.rs', 'app-server-transport/src/transport/remote_control/mod.rs', 'app-server-daemon/src/settings.rs', 'core/src/session/step_activation.rs', 'config/src/types.rs', 'config/src/mcp_types.rs', 'app-server/src/request_processors/thread_input.rs', 'hooks/src/engine/hooks_config.rs', 'mcp-types/src/config.rs', 'cloud-tasks-client/src/api.rs', 'cloud-tasks-client/src/http.rs', 'app-server-protocol/src/protocol/v2/thread.rs', 'app-server-protocol/src/protocol/v2/turn.rs', 'cli/src/remote_control_cmd.rs', 'cli/src/exec_server_command.rs', 'core/src/tools/registry/*.rs', 'hooks/src/declarations.rs', 'hooks/src/engine/discovery.rs', 'core/src/tools/registry/builders.rs', 'core/src/tools/registry/handlers.rs', 'cloud-tasks/src/**/*.rs']
paths = sorted({p for pat in patterns for p in (SRC / 'codex-rs').glob(pat) if 'test' not in p.name})
items = []
manifest = []
def walk(n, data, path):
    if n.type in {'function_item', 'struct_item', 'enum_item', 'const_item', 'trait_item', 'function_signature_item'}:
        name = n.child_by_field_name('name')
        if name:
            calls = []
            fields = []
            def descendants(x):
                if x.type == 'call_expression':
                    fn = x.child_by_field_name('function')
                    if fn:
                        calls.append(data[fn.start_byte:fn.end_byte].decode())
                if x.type == 'field_declaration':
                    key = x.child_by_field_name('name')
                    typ = x.child_by_field_name('type')
                    if key:
                        fields.append(dict(name=data[key.start_byte:key.end_byte].decode(), type=data[typ.start_byte:typ.end_byte].decode() if typ else None))
                for c in x.named_children:
                    descendants(c)
            descendants(n)
            items.append(dict(path=path, name=data[name.start_byte:name.end_byte].decode(), kind=n.type, line=n.start_point.row + 1, end_line=n.end_point.row + 1, fields=fields, calls=sorted(set(calls)), source=data[n.start_byte:n.end_byte].decode()))
    for child in n.named_children:
        walk(child, data, path)
for p in paths:
    data = p.read_bytes()
    path = str(p.relative_to(SRC))
    tree = parser.parse(data)
    manifest.append(dict(path=path, sha256=hashlib.sha256(data).hexdigest(), ast_has_error=tree.root_node.has_error))
    walk(tree.root_node, data, path)
(OUT / 'rust-ast.json').write_text(json.dumps(items, indent=2))
(OUT / 'source-manifest.json').write_text(json.dumps(manifest, indent=2))
fixtures = {str(p.relative_to(R)): json.loads(p.read_text()) for p in (R / 'packages/delegate-routing/fixtures/capabilities').glob('codex*.json')}
(OUT / 'committed-fixtures.json').write_text(json.dumps(fixtures, indent=2))
(WORK / 'provenance.json').write_text(json.dumps(dict(binary=B, version=subprocess.check_output([B, '--version'], text=True).strip(), binary_sha256=hashlib.sha256(pathlib.Path(B).resolve().read_bytes()).hexdigest(), source=str(SRC), pin=json.loads((R / 'packages/chatgpt-codex/sources.json').read_text()), ast_parser=tree_sitter_rust.__file__), indent=2))
print(json.dumps(dict(files=len(paths), declarations=len(items), parse_errors=sum(x['ast_has_error'] for x in manifest), cli_commands=len(commands))))
