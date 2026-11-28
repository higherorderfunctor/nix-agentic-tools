import json
import subprocess
import sys
import tempfile
from pathlib import Path


extractor = sys.argv[1]
warning = '[cli-settings] failed to read workspace cli.json:'
properties = [
    'CHAT_DEFAULT_MODEL:"chat.defaultModel"',
    'CHAT_MODEL_DEFAULTS:"chat.modelDefaults"',
] + [f'CHAT_TEST_{index:02d}:"chat.fixture{index}"' for index in range(43)]
members = ["pn.CHAT_DEFAULT_MODEL", "pn.CHAT_MODEL_DEFAULTS"] + [
    f'"chat.allowed{index}"' for index in range(8)
] + ['"chat.enableTangentMode"']
registry_assignment = f'pn={{{",".join(properties)}}};'


def merge_fn(seed, loop):
    return (
        f'function merge(){{let e={seed};try{{let w=readWorkspace(path());{loop}'
        f'}}catch(err){{logger.warn("{warning}",err)}}return e}}'
    )


def guarded_loop(guard, extra=""):
    return f"for(const [k,v] of Object.entries(w))if({guard})e[k]=v{extra}"


def merge_with_guard(guard, extra="", *, seed="globalLoad()"):
    return merge_fn(seed, guarded_loop(guard, extra))


composer = "function compose(){return{...globalLoad(),...merge()}}"
empty_seed = merge_with_guard("Cq.has(k)", seed="{}")
explicit_path = empty_seed.replace("merge()", "merge(p=path())", 1).replace(
    "readWorkspace(path())", "readWorkspace(p)", 1
)
extra_copy = ';if("chat.surprise" in w)e["chat.surprise"]=w["chat.surprise"]'
probe_mismatch = "workspace merge does not apply exactly the extracted allowlist"


def bundle(*, registry=None, allowlist=None, merge=None):
    registry = registry or registry_assignment
    allowlist = allowlist or f'Cq=new Set([{",".join(members)}]);'
    merge = merge or merge_with_guard("Cq.has(k)")
    return 'var pn,Cq;' + registry + allowlist + merge


with tempfile.TemporaryDirectory(prefix="kiro-settings-fixtures-") as tmp:
    source = Path(tmp) / "tui.js"

    def run(text):
        source.write_text(text)
        return subprocess.run([extractor, str(source)], capture_output=True, text=True)

    # The input has both symbolic and literal allowlist entries. Most registry
    # entries are deliberately not overridable; the allowlist has keys absent
    # from the registry. Exact membership catches a same-size substitution.
    expected = {
        "settingKeys": ["chat.defaultModel", "chat.modelDefaults"]
        + [f"chat.fixture{index}" for index in range(43)],
        "workspaceOverridableSettings": [
            "chat.defaultModel",
            "chat.enableTangentMode",
            "chat.modelDefaults",
        ]
        + [f"chat.allowed{index}" for index in range(8)],
    }

    expected = {key: sorted(keys) for key, keys in expected.items()}

    # A property key, member name, or label that only shares the merge's or the
    # composer's spelling is not a use of it.
    unrelated_names = {
        "accessor names do not read the loader bindings": "const o={get compose(){return 1},set merge(v){}};",
        "break labels do not read the merge binding": "merge:for(;;)break merge;",
        "class field names do not read the composer binding": "class D{compose=2};",
        "object method names do not read the merge binding": "const o={merge(){return 1}};",
        "property access does not read the merge binding": "const o={x:1};o.merge;",
        "property keys do not read the merge binding": "const o={merge:1};",
    }
    accepted = {
        # 3.6.2 supports both the default workspace path and an explicit one.
        "defaulted path forwarded to the reader is not an unsupported parameter": bundle(
            merge=explicit_path + composer + 'merge("other");'
        ),
        "global-loader seed is still accepted without a composer": bundle(),
        "property spelled arguments is not a read of the call arguments": bundle(
            merge=explicit_path.replace(
                "Cq.has(k)", "Cq.has(k)&&({arguments:true}).arguments"
            )
            + composer
        ),
        # 3.1.0 seeds the merge with {} and a separate composer adds the globals.
        **{
            name: bundle(merge=empty_seed + composer + member)
            for name, member in unrelated_names.items()
        },
    }
    rejected = {
        "allowlist key deleted for boolean": (
            bundle(
                merge=merge_with_guard(
                    "Cq.has(k)",
                    ';if(typeof w["chat.defaultModel"]==="boolean")delete e["chat.defaultModel"]',
                )
            ),
            probe_mismatch,
        ),
        "ambiguous registry": (
            bundle(registry=registry_assignment * 2),
            "settings anchors are ambiguous or absent (registry 2, allowlist 1, merge 1)",
        ),
        "argument count read by the copy guard": (
            bundle(
                merge=explicit_path.replace("Cq.has(k)", "Cq.has(k)||arguments.length>0")
                + composer
            ),
            "unsupported loader shape",
        ),
        "argument value read by the copy guard": (
            bundle(
                merge=explicit_path.replace(
                    "Cq.has(k)", 'Cq.has(k)||arguments[0]?.endsWith?.("cli.json")'
                )
                + composer
            ),
            "unsupported loader shape",
        ),
        "composer redeclared": (
            bundle(merge=empty_seed + composer + "function compose(){return globalLoad()}"),
            "composer name is mutated, shadowed, or escapes",
        ),
        "composer with a parameter": (
            bundle(merge=empty_seed + "function compose(a){return{...globalLoad(),...merge()}}"),
            "unsupported loader shape",
        ),
        "compound guard beside composer": (
            bundle(merge=merge_with_guard('Cq.has(k)||k.startsWith("mcp.")', seed="{}") + composer),
            probe_mismatch,
        ),
        "computed allowlist member": (
            bundle(allowlist=f'Cq=new Set([{",".join(members)},pn["CHAT_TEST_00"]]);'),
            "unresolved or computed member",
        ),
        "computed merge key": (
            bundle(merge=empty_seed + composer + "const o={[merge](){return 1}};"),
            "merge name is mutated, shadowed, or escapes",
        ),
        "derived copy key": (
            bundle(merge=merge_fn("{}", 'for(const [k,v] of Object.entries(w))if(Cq.has(k)){e[k]=v;e[k+".copy"]=v}') + composer),
            probe_mismatch,
        ),
        "duplicate registry key": (
            bundle(registry=f'pn={{{",".join(properties + [properties[0]])}}};'),
            "repeats CHAT_DEFAULT_MODEL",
        ),
        "extra copy after the loop (3.0.0)": (
            bundle(merge=merge_with_guard("Cq.has(k)", extra_copy)),
            probe_mismatch,
        ),
        "extra copy after the loop (3.1.0)": (
            bundle(merge=merge_with_guard("Cq.has(k)", extra_copy, seed="{}") + composer),
            probe_mismatch,
        ),
        "extra copy for boolean true": (
            bundle(
                merge=merge_with_guard(
                    "Cq.has(k)", ';if(w["chat.surprise"]===true)e["chat.surprise"]=true'
                )
            ),
            probe_mismatch,
        ),
        "forwarded parameter without a default": (
            bundle(merge=explicit_path.replace("p=path()", "p") + composer),
            "unsupported loader shape",
        ),
        "merge assigned by destructuring": (
            bundle(merge=empty_seed + composer + "({merge}=globalLoad());"),
            "merge name is mutated, shadowed, or escapes",
        ),
        "merge assigned": (
            bundle(merge=empty_seed + composer + "merge=function(){return{}};"),
            "merge name is mutated, shadowed, or escapes",
        ),
        "merge nested beside top-level composer": (
            bundle(
                merge="function outer(){"
                + empty_seed
                + "}"
                + composer
            ),
            "unsupported loader shape",
        ),
        "merge rebound by var destructuring": (
            bundle(merge=empty_seed + composer + "var {merge}=globalLoad();"),
            "merge name is mutated, shadowed, or escapes",
        ),
        "missing merge warning": (
            bundle(merge="function merge(){}"),
            "settings anchors are ambiguous or absent (registry 1, allowlist 1, merge 0)",
        ),
        "missing registry control": (
            bundle(registry=f'pn={{{",".join(properties[1:])}}};'),
            "settings anchors are ambiguous or absent (registry 0, allowlist 1, merge 1)",
        ),
        "missing set": (
            'var pn,Cq;' + registry_assignment + merge_with_guard("Cq.has(k)"),
            "settings anchors are ambiguous or absent (registry 1, allowlist 0, merge 1)",
        ),
        "mutated allowlist": (bundle() + 'Cq.add("chat.unknown");', "mutated, shadowed, or escapes"),
        "nested composer shadowing merge": (
            bundle(
                merge=empty_seed
                + "function outer(){function merge(){return{}}"
                + composer
                + "}"
            ),
            "unsupported loader shape",
        ),
        "non-call default path": (
            bundle(merge=explicit_path.replace("p=path()", 'p="literal"') + composer),
            "unsupported loader shape",
        ),
        "parameter not forwarded": (
            bundle(merge=explicit_path.replace("readWorkspace(p)", "readWorkspace(path())") + composer),
            "unsupported loader shape",
        ),
        "parameter on a global-loader seed": (
            bundle(merge=explicit_path.replace("let e={}", "let e=globalLoad()")),
            "unsupported loader shape",
        ),
        "parameter read by the copy guard": (
            bundle(
                merge=explicit_path.replace("Cq.has(k)", 'Cq.has(k)||p.endsWith("cli.json")')
                + composer
            ),
            "unsupported loader shape",
        ),
        "parse error": (bundle() + "function (", "not valid JavaScript"),
        "reversed composer spread": (
            bundle(merge=empty_seed + "function compose(){return{...merge(),...globalLoad()}}"),
            "unsupported loader shape",
        ),
        "second parameter": (
            bundle(merge=explicit_path.replace("p=path()", "p=path(),q") + composer),
            "unsupported loader shape",
        ),
        "shadowed merge beside composer": (
            bundle(merge=empty_seed + composer + "function outer(){let merge=1}"),
            "merge name is mutated, shadowed, or escapes",
        ),
        "swapped loop binding (3.0.0)": (
            bundle(merge=merge_fn("globalLoad()", "for(const [v,k] of Object.entries(w))if(Cq.has(v))e[k]=v")),
            probe_mismatch,
        ),
        "truthiness guard": (
            bundle(merge=merge_with_guard("Cq.has(k)&&v")),
            probe_mismatch,
        ),
        "two composers": (
            bundle(merge=empty_seed + composer + composer.replace("compose", "composeAgain")),
            "unsupported loader shape",
        ),
        "type guard": (
            bundle(merge=merge_with_guard('Cq.has(k)&&typeof v==="string"')),
            probe_mismatch,
        ),
        "unknown allowlist symbol": (
            bundle(allowlist=f'Cq=new Set([{",".join(members)},pn.CHAT_UNKNOWN]);'),
            "unresolved or computed member",
        ),
        "wrong merge set": (
            bundle(merge=merge_with_guard("other.has(k)")),
            "no longer consults",
        ),
    }
    cases = {**{name: (text, None) for name, text in accepted.items()}, **rejected}
    for name, (text, diagnostic) in sorted(cases.items()):
        result = run(text)
        if diagnostic is None:
            assert result.returncode == 0, f"{name}: {result.stderr}"
            facts = json.loads(result.stdout)
            assert facts == expected, (name, facts)
        else:
            assert result.returncode != 0, f"{name}: unexpectedly accepted"
            assert diagnostic in result.stderr, f"{name}: expected {diagnostic!r}; got {result.stderr}"
        print(f"ok [{name}]")
