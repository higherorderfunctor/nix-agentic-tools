import json
import pathlib
import sys

# usage: python3 inspect_ast.py <inventory-dir> <declaration-name>...   (<inventory-dir> from inventory.py)
if len(sys.argv) < 3:
    sys.exit("usage: python3 inspect_ast.py <inventory-dir> <declaration-name>...")
INV = pathlib.Path(sys.argv[1])
for filename in ['rust-ast.json', 'sdk-ast.json']:
    entries = json.loads((INV / filename).read_text())
    for entry in entries:
        if entry['name'] in sys.argv[2:]:
            print(json.dumps(entry, indent=2))
