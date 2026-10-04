# Run the steering extractor against the pinned release's real KAS bundle and
# require every vendor sentence the default reminder is written against.
import json
import subprocess
import sys

extractor, bundle, anchors = sys.argv[1:]
result = subprocess.run(
    [sys.executable, extractor, bundle], capture_output=True, text=True
)
if result.returncode != 0 or not result.stdout:
    sys.exit(
        "FAIL: the vendor steering extractor no longer works on the pinned "
        "kiro-cli's engine bundle, so ai.kiro.workflowReminder."
        "includeVendorSteering delivers nothing.\n" + result.stderr
    )

missing = [a for a in json.load(open(anchors)) if a["text"] not in result.stdout]
if missing:
    sys.exit(
        "FAIL: the vendor workflow steering changed under the default "
        "reminder (packages/kiro-cli/lib/workflowReminder.nix). Re-review "
        "these paragraphs against the new text, then update vendorAnchors:\n"
        + "".join(f"  - {a['paragraph']}: {a['text']!r} is gone\n" for a in missing)
    )
print(f"PASS: steering extracted ({len(result.stdout)} chars); {len(json.load(open(anchors)))} reminder anchors present")
