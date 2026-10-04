# Run the steering extractor against the pinned release's real KAS bundle and
# require every vendor sentence the default reminder is written against.
# An anchor with `scope = "bundle"` is matched against the raw bundle text
# instead of the extracted steering: the reminder also corrects text that lives
# outside the steering (the workflow-creator prompt, the engine's errors, the
# agent registries).
import json
import subprocess
import sys

extractor, bundle, anchors_path = sys.argv[1:]
result = subprocess.run(
    [sys.executable, extractor, bundle], capture_output=True, text=True
)
if result.returncode != 0 or not result.stdout:
    sys.exit(
        "FAIL: the vendor steering extractor no longer works on the pinned "
        "kiro-cli's engine bundle, so ai.kiro.workflowReminder."
        "includeVendorSteering delivers nothing.\n" + result.stderr
    )

with open(bundle, encoding="utf-8", errors="replace") as handle:
    haystacks = {"steering": result.stdout, "bundle": handle.read()}
with open(anchors_path) as handle:
    anchors = [{"scope": "steering", **a} for a in json.load(handle)]

unknown = sorted({a["scope"] for a in anchors} - haystacks.keys())
if unknown:
    sys.exit("FAIL: unknown vendorAnchors scope(s): %s" % ", ".join(unknown))

missing = [a for a in anchors if a["text"] not in haystacks[a["scope"]]]
if missing:
    sys.exit(
        "FAIL: the vendor workflow text changed under the default "
        "reminder (packages/kiro-cli/lib/workflowReminder.nix). Re-review "
        "these paragraphs against the new text, then update vendorAnchors:\n"
        + "".join(
            f"  - {a['paragraph']} ({a['scope']}): {a['text']!r} is gone\n"
            for a in missing
        )
    )
print(
    f"PASS: steering extracted ({len(result.stdout)} chars); "
    f"{len(anchors)} reminder anchors present"
)
