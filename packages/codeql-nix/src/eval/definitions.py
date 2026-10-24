"""Bounded source inventory over the authenticated S2 tree, never evaluated values.

Plans carry source structure to the module adapter. Only upstream collection can
turn a plan into an evaluated candidate. Unknown syntax remains explicit.
"""

from collections import defaultdict
import json

from protocol import abi


class Source:
    def __init__(self, rows, data, model):
        self.data = data
        self.rows = {tuple(json.loads(row[5])): row for row in rows}
        self.children = defaultdict(list)
        for path, row in sorted(self.rows.items()):
            if path:
                self.children[path[:-1]].append(row)
        self.helpers = {h['name']: h for h in (model or {}).get('helpers', [])
                        if h['kind'] in ('if', 'merge', 'order', 'override')}
        self.default = (model or {}).get('constants', {}).get('ordinaryOverridePriority')
        self.opaque = False

    def text(self, node):
        return self.data[node[2]:node[3]].decode('utf-8')

    def child(self, node):
        return [n for n in self.children[tuple(json.loads(node[5]))]
                if n[4] not in ('comment', '(', ')', '{', '}', '[', ']', ';', '=', ':', '.', ',', 'let', 'in', 'rec')]

    def unwrap(self, node):
        while node[4] == 'parenthesized_expression':
            children = self.child(node)
            if len(children) != 1:
                break
            node = children[0]
        return node

    def literal(self, node):
        if node[4] == 'identifier':
            return self.text(node)
        if node[4] == 'string_expression' and not any(n[4] == 'interpolation' for n in self.child(node)):
            try:
                return json.loads(self.text(node))
            except ValueError:
                pass
        return None

    def binding(self, node):
        children = self.child(node)
        if node[4] != 'binding' or len(children) != 2 or children[0][4] != 'attrpath':
            return None
        path = [self.literal(n) for n in self.child(children[0])]
        if not path or None in path:
            return None
        return path, children[0], children[1]

    def bindings(self, node):
        return [n for child in self.child(node)
                for n in (self.child(child) if child[4] == 'binding_set' else [child])]

    def environment(self, bindings, env):
        # Recursive lexical definitions shadow the outer environment immediately.
        local = env.copy()
        for node in bindings:
            bound = self.binding(node)
            if bound:
                local[bound[0][0]] = ('expression', bound[2], local) if len(bound[0]) == 1 else None
            elif node[4] in ('inherit', 'inherit_from'):
                children = self.child(node)
                source = next((n for n in children if n[4] not in ('inherit', 'inherited_attrs')), None)
                names = [n for c in children if c[4] == 'inherited_attrs' for n in self.child(c)]
                for name in names:
                    spelling = self.literal(name)
                    if spelling is not None:
                        local[spelling] = ('inherited', source, spelling, env if source is None else local)
        return local

    def identity(self, node, env, visited=()):
        node = self.unwrap(node)
        if node[0] in visited:
            return None
        visited += (node[0],)
        if node[4] in ('variable_expression', 'identifier'):
            name = self.text(node)
            value = env.get(name)
            if value == 'library':
                return 'library'
            if isinstance(value, tuple):
                if value[0] == 'expression':
                    return self.identity(value[1], value[2], visited)
                _, source, name, scope = value
                if source is None:
                    return self.identity(node, scope, visited[:-1]) if scope is not env else None
                if self.identity(source, scope, visited) == 'library':
                    return name if name in self.helpers else None
        if node[4] == 'select_expression':
            children = self.child(node)
            if len(children) == 2 and self.identity(children[0], env, visited) == 'library':
                names = self.child(children[1])
                if len(names) == 1:
                    name = self.literal(names[0])
                    return name if name in self.helpers else None
        return None

    def call(self, node, env):
        original = self.unwrap(node)
        node = original
        args = []
        while node[4] == 'apply_expression':
            children = self.child(node)
            if len(children) != 2:
                return None
            node, argument = children
            args.insert(0, argument)
            node = self.unwrap(node)
        helper = self.helpers.get(self.identity(node, env))
        if helper and len(args) == helper['arity']:
            return original, helper, args
        return None

    def walk(self, node, remaining, env, chain=(), anchor=None, position=()):
        node = self.unwrap(node)
        if node[4] == 'let_expression':
            children = self.child(node)
            body = children[-1]
            bindings = [n for c in children[:-1] for n in (self.child(c) if c[4] == 'binding_set' else [c])]
            return self.walk(body, remaining, self.environment(bindings, env), chain, anchor, position)
        call = self.call(node, env)
        if call:
            application, helper, args = call
            kind = helper['kind']
            record = {'kind': kind, 'anchor': application[0]}
            content = args[-1]
            if kind == 'merge':
                content = self.unwrap(content)
                if content[4] != 'list_expression':
                    self.opaque = True
                    return []
                return [candidate for i, element in enumerate(self.child(content))
                        for candidate in self.walk(element, remaining, env,
                            (*chain, record | {'index': i}), anchor, position)]
            if kind == 'if':
                header = self.text(self.unwrap(args[0]))
                record['truth'] = header if header in ('true', 'false') and header not in env else 'unknown'
            else:
                header = helper.get('priority')
                if helper['arity'] == 2:
                    header = self.text(self.unwrap(args[0]))
                    try:
                        abi.priority(header)
                    except ValueError:
                        header = None
                record['priority'] = header
            return self.walk(content, remaining, env, (*chain, record), anchor, position)
        if remaining:
            if node[4] not in ('attrset_expression', 'rec_attrset_expression'):
                self.opaque = True
                return []
            bindings = self.bindings(node)
            scope = self.environment(bindings, env) if node[4] == 'rec_attrset_expression' else env
            candidates = []
            for binding in bindings:
                bound = self.binding(binding)
                if bound is None:
                    self.opaque = True
                    continue
                names, path_anchor, value = bound
                if names[:len(remaining)] == remaining:
                    candidates.extend(self.walk(value, [], scope, chain, path_anchor, (*position, *names)))
                elif remaining[:len(names)] == names:
                    candidates.extend(self.walk(value, remaining[len(names):], scope, chain, path_anchor, (*position, *names)))
            return candidates
        # dischargeProperties cannot see through order/override payloads. A
        # source guard behind that barrier says nothing about effective activity.
        barrier = False
        guards = []
        supported = True
        for wrapper in chain:
            if wrapper['kind'] == 'if':
                guards.append('unknown' if barrier else wrapper['truth'])
            if barrier and wrapper['kind'] != 'order':
                supported = False
            barrier |= wrapper['kind'] in ('order', 'override')
        active = 'false' if 'false' in guards else 'unknown' if 'unknown' in guards else 'true'
        # Only value constructors that cannot produce a property record are
        # ordinary leaves. Computed expressions remain opaque, even when their
        # outer spelling is not a call (for example `if` or `with`).
        safe_leaf = node[4] in (
            'float_expression', 'function_expression', 'hpath_expression',
            'indented_string_expression', 'integer_expression', 'list_expression',
            'path_expression', 'spath_expression', 'string_expression', 'uri_expression')
        if node[4] == 'variable_expression':
            name = self.text(node)
            safe_leaf = name in ('false', 'null', 'true') and name not in env
        elif node[4] == 'unary_expression':
            parts = self.child(node)
            safe_leaf = (len(parts) == 2 and parts[0][4] == '-' and
                         self.unwrap(parts[1])[4] in ('float_expression', 'integer_expression'))
        if not safe_leaf and active != 'false':
            self.opaque = True
            return []
        overrides = [w['priority'] for w in chain if w['kind'] == 'override']
        priority = (overrides[0] if len(overrides) == 1 else self.default if not overrides else None) if supported else None
        if (not safe_leaf or active == 'unknown') and not overrides:
            priority = None
        return [{'active': active, 'anchor': anchor[0], 'chain': list(chain),
                 'group': [w['index'] for w in chain if w['kind'] == 'merge'],
                 'position': list(position), 'priority': priority,
                 'requiresLibrary': bool(chain), 'correspondence': supported, 'start': anchor[2]}]

    def module(self):
        root = self.rows.get(())
        if root is None:
            return {'candidates': [], 'opaque': True}
        children = self.child(root)
        if len(children) != 1:
            return {'candidates': [], 'opaque': True}
        body = self.unwrap(children[0])
        env = {}
        if body[4] == 'function_expression':
            parts = self.child(body)
            for parameter in parts[:-1]:
                if parameter[4] == 'identifier':
                    env[self.text(parameter)] = None
            formal = next((p for p in parts[:-1] if p[4] == 'formals'), parts[0])
            if formal[4] == 'formals':
                for f in self.child(formal):
                    if f[4] == 'formal':
                        names = self.child(f)
                        if names:
                            env[self.text(names[0])] = None
                        if names and self.text(names[0]) == 'lib' and abi.library_formal(
                                {n[0]: n for n in self.rows.values()}, body[0], names[0][0]):
                            env['lib'] = 'library'
            body = parts[-1]
        # A literal module body may introduce lexical aliases before its attrset.
        while self.unwrap(body)[4] == 'let_expression':
            parts = self.child(self.unwrap(body))
            env = self.environment([n for c in parts[:-1] for n in
                                    (self.child(c) if c[4] == 'binding_set' else [c])], env)
            body = parts[-1]
        body = self.unwrap(body)
        if body[4] not in ('attrset_expression', 'rec_attrset_expression'):
            return {'candidates': [], 'opaque': True}
        bindings = self.bindings(body)
        explicit = any(self.binding(n) and self.binding(n)[0][0] in ('config', 'options') for n in bindings)
        if explicit:
            # Match the top-level attribute, including config.demo.answer and
            # several disjoint config-prefixed bindings. Mixed module forms are
            # invalid upstream and cannot establish a complete source inventory.
            allowed = {'_class', '_file', 'config', 'disabledModules', 'freeformType',
                       'imports', 'key', 'meta', 'options'}
            self.opaque |= any(self.binding(n) is None or self.binding(n)[0][0] not in allowed for n in bindings)
        candidates = self.walk(body, ['config', *self.request] if explicit else self.request, env)
        return {'candidates': sorted(candidates, key=lambda c: (c['start'], c['group'])), 'opaque': self.opaque}


def source_inventory(anchor_rows, sources, mappings, model, requested_path):
    grouped = defaultdict(list)
    for _, row in anchor_rows:
        grouped[row[1]].append(row)
    plans = {}
    for file, (path, _) in sources.items():
        source = Source(grouped[file], path.read_bytes(), model)
        source.request = requested_path
        plans[file] = source.module()
    return [{'path': copied, **plans[files[0]]} for copied, value in mappings.items()
            for files in ([value] if isinstance(value, str) else value,)
            if len(files) == 1 and files[0] in plans]
