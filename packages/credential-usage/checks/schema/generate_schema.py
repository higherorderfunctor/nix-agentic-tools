"""Print the fill author's JSON Schema in the repository's JSON format for drift checks."""

import json
import subprocess

from credential_usage.envelope import Envelope


if __name__ == "__main__":
    subprocess.run(
        ["biome", "format", "--indent-style=space", "--stdin-file-path=usage-envelope.schema.json"],
        input=json.dumps(Envelope.model_json_schema(), indent=2),
        text=True,
        check=True,
    )
