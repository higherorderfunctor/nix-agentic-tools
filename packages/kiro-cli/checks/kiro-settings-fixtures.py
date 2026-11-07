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


def merge_with_guard(guard):
    return (
        'function merge(){let e=globalLoad();try{let w=readWorkspace(path());'
        f'for(const [k,v] of Object.entries(w))if({guard})e[k]=v'
        f'}}catch(err){{logger.warn("{warning}",err)}}return e}}'
    )


def merge_with_empty_seed(guard):
    return (
        'function merge(){let e={};try{let w=readWorkspace(path());'
        f'for(const [k,v] of Object.entries(w))if({guard})e[k]=v'
        f'}}catch(err){{logger.warn("{warning}",err)}}return e}}'
    )


composer = "function compose(){return{...globalLoad(),...merge()}}"
empty_seed = merge_with_empty_seed("Cq.has(k)")


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

    happy = run(bundle())
    assert happy.returncode == 0, happy.stderr
    result = json.loads(happy.stdout)
    assert len(result["settingKeys"]) == 45, result
    assert len(result["workspaceOverridableSettings"]) == 11, result
    assert "chat.defaultModel" in result["workspaceOverridableSettings"]

    # 3.1.0 seeds the merge with {} and a separate composer adds the globals.
    modern = run(bundle(merge=empty_seed + composer))
    assert modern.returncode == 0, modern.stderr
    modern_result = json.loads(modern.stdout)
    assert len(modern_result["settingKeys"]) == 45, modern_result
    assert len(modern_result["workspaceOverridableSettings"]) == 11, modern_result
    assert "chat.defaultModel" in modern_result["workspaceOverridableSettings"]

    cases = {
        "accept all": (
            bundle(merge=merge_with_guard("Cq.has(k)||true")),
            "does not apply exactly",
        ),
        "accept sentinel": (
            bundle(merge=merge_with_guard('Cq.has(k)||k==="kiro.extractor.unknown"')),
            "does not apply exactly",
        ),
        "ambiguous registry": (
            bundle(registry=registry_assignment * 2),
            "ambiguous or absent",
        ),
        "composer with a parameter": (
            bundle(merge=empty_seed + "function compose(a){return{...globalLoad(),...merge()}}"),
            "unsupported loader shape",
        ),
        "computed allowlist member": (
            bundle(allowlist=f'Cq=new Set([{",".join(members)},pn["CHAT_TEST_00"]]);'),
            "unresolved or computed member",
        ),
        "duplicate registry key": (
            bundle(registry=f'pn={{{",".join(properties + [properties[0]])}}};'),
            "repeats CHAT_DEFAULT_MODEL",
        ),
        "empty seed without composer": (
            bundle(merge=empty_seed),
            "unsupported loader shape",
        ),
        "missing merge warning": (bundle(merge="function merge(){}"), "ambiguous or absent"),
        "missing set": ('var pn,Cq;' + registry_assignment + merge_with_guard("Cq.has(k)"), "ambiguous or absent"),
        "mutated allowlist": (bundle() + 'Cq.add("chat.unknown");', "mutated, shadowed, or escapes"),
        "negated guard": (
            bundle(merge=merge_with_guard("!Cq.has(k)")),
            "does not apply exactly",
        ),
        "missing registry control": (
            bundle(registry=f'pn={{{",".join(properties[1:])}}};'),
            "ambiguous or absent",
        ),
        "parse error": (bundle() + "function (", "not valid JavaScript"),
        "nested composer shadowing merge": (
            bundle(
                merge=empty_seed
                + "function outer(){function merge(){return{}}"
                + composer
                + "}"
            ),
            "unsupported loader shape",
        ),
        "merge assigned": (
            bundle(merge=empty_seed + composer + "merge=function(){return{}};"),
            "merge name is mutated, shadowed, or escapes",
        ),
        "merge assigned by destructuring": (
            bundle(merge=empty_seed + composer + "({merge}=globalLoad());"),
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
        "redeclared merge": (
            bundle(merge=empty_seed + composer + "function merge(){return{...globalLoad()}}"),
            "merge name is mutated, shadowed, or escapes",
        ),
        "reversed composer spread": (
            bundle(merge=empty_seed + "function compose(){return{...merge(),...globalLoad()}}"),
            "unsupported loader shape",
        ),
        "shadowed merge beside composer": (
            bundle(merge=empty_seed + composer + "function outer(){let merge=1}"),
            "merge name is mutated, shadowed, or escapes",
        ),
        "two composers": (
            bundle(merge=empty_seed + composer + composer.replace("compose", "composeAgain")),
            "unsupported loader shape",
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
    for name, (text, message) in cases.items():
        result = run(text)
        assert result.returncode != 0, f"{name}: unexpectedly accepted"
        assert message in result.stderr, f"{name}: {result.stderr}"
        print(f"ok [{name}]")
