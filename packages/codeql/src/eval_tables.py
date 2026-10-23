"""Render weak head normal form module facts as a generation-local CodeQL data extension."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import time


PACK = "nix-agentic-tools/eval-tables"
MODEL = "nix-agentic-tools/eval-data"
# Column order is the public EvalTables.qll schema, shared by every producer.
TABLES = {
    "definition": ("evalDefinition", "source path file line column moduleFile priority active conditionCount wins aliasForward kind"),
    "eval_source": ("evalSource", "source status error wallSeconds peakMb rowCounts"),
    "module": ("evalModule", "source file key importedBy disabled"),
    "option": ("evalOption", "source path type typeDescription highestPrio isDefined internal readOnly visible hasDefault hasApply generated instance"),
    "option_decl": ("evalOptionDecl", "source path file line column"),
    "value": ("evalValue", "source path kind value"),
}


def render(tables, destination):
    destination.mkdir(parents=True, exist_ok=True)
    (destination / "qlpack.yml").write_text(json.dumps({
        "name": MODEL, "version": "0.0.0", "library": True,
        "extensionTargets": {PACK: "*"}, "dataExtensions": ["rows.model.yml"],
    }) + "\n")
    extensions = [{"addsTo": {"pack": PACK, "extensible": predicate},
                   "data": [[row[column] for column in columns.split()] for row in tables.get(table, [])]}
                  for table, (predicate, columns) in TABLES.items()]
    # JSON is YAML; escaping and booleans have one standard encoder.
    (destination / "rows.model.yml").write_text(json.dumps({"extensions": extensions}, separators=(",", ":")) + "\n")
    (destination / "status.json").write_text(json.dumps(tables.get("eval_source", []), indent=2) + "\n")


def generate(root, sources, destination):
    tables = {name: [] for name in TABLES}
    for source in sources:
        expression = f'''let args = ({source["expression"]}); in
          (import ./packages/codeql/lib/eval-tables.nix {{ inherit (args) lib; }})
          {{ inherit (args) modules result; root = ./.; source = {json.dumps(source["name"])}; }}'''
        started = time.monotonic()
        with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
            process = subprocess.Popen(["nix", "eval", "--impure", "--json", "--expr", expression],
                                       cwd=root, stdout=output, stderr=errors)
            # Per-source child RSS, rather than the cumulative child-process peak.
            _, status, usage = os.wait4(process.pid, 0)
            process.returncode = os.waitstatus_to_exitcode(status)
            output.seek(0)
            errors.seek(0)
            error = errors.read().decode(errors="replace")
            if "error: interrupted by the user" in error:
                raise RuntimeError("Nix evaluation was interrupted; stop before retrying")
            record = {"source": source["name"], "status": "ok", "error": "",
                      "wallSeconds": time.monotonic() - started,
                      "peakMb": usage.ru_maxrss / 1024.0, "rowCounts": "{}"}
            if process.returncode == 0:
                try:
                    rows = json.load(output)
                    record["rowCounts"] = json.dumps({name: len(value) for name, value in rows.items()}, sort_keys=True)
                    for name, value in rows.items():
                        tables[name].extend(value)
                except (ValueError, KeyError, TypeError) as failure:
                    record.update(status="failed", error=str(failure))
            else:
                record.update(status="failed", error=error[-16384:])
            if record["status"] == "failed":
                print(f'CodeQL eval source {source["name"]}: failed: {record["error"]}', flush=True)
            tables["eval_source"].append(record)
    render(tables, destination)
    return tables["eval_source"]
