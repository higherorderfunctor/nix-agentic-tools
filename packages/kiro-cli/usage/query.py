"""Read observed usage for an explicit Kiro session; never infer token counts."""

import argparse
from contextlib import closing
import json
from pathlib import Path
import re
import sqlite3
import sys

from display import table, value


DIMENSIONS = ("credits", "input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens")
FOOTER_WARNINGS = (
    "Own-versus-delegate attribution within a session is unavailable; session scope can include delegate work.",
    "Disk turn credits and capture credits overlap and must never be added.",
)


def metric(total=None, known=0, observations=0):
    return {"observed_sum": total, "known": known,
            "unknown": observations - known}


def query(db, session, scope="session"):
    if not re.fullmatch(r"sess_[A-Za-z0-9_-]+", session):
        raise ValueError("--session must be a sess_UUID identifier")
    if scope not in ("session", "tree"):
        raise ValueError("scope must be session or tree")
    db.row_factory = sqlite3.Row
    db.create_function("session_name", 1, lambda path: Path(path).name, deterministic=True)
    tables = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    disk_available = {"disk_sessions", "disk_sources", "disk_records", "disk_request_ids"} <= tables
    selected = {session}
    paths = []
    if disk_available:
        rows = db.execute("""
            WITH RECURSIVE chosen(path, identifiers_json) AS (
              SELECT path,identifiers_json FROM disk_sessions WHERE session_name(path)=?
              UNION
              SELECT d.path,d.identifiers_json FROM disk_sessions d JOIN chosen p
              ON ?='tree' AND (
                json_extract(d.identifiers_json,'$.parentSessionId') IN (session_name(p.path),substr(session_name(p.path),6))
                OR json_extract(d.identifiers_json,'$.rootSessionId') IN (session_name(p.path),substr(session_name(p.path),6)))
            ) SELECT path FROM chosen
        """, (session, scope))
        for row in rows:
            paths.append(row[0])
            selected.add(Path(row[0]).name)
        # A messages file can exist before session.json is saved.
        for row in db.execute("SELECT DISTINCT session_path FROM disk_sources WHERE session_name(session_path)=?", (session,)):
            if row[0] not in paths:
                paths.append(row[0])
    aliases = sorted(selected | {value.removeprefix("sess_") for value in selected})
    placeholders = ",".join("?" for _ in aliases)
    path_marks = ",".join("?" for _ in paths) or "NULL"
    warnings = [*FOOTER_WARNINGS, "Context percentages are observations, not token counts."]
    report = {"session": session, "scope": scope, "sessions": sorted(selected),
              "attribution": {"own_vs_delegate": "unavailable", "tree_identity": "explicit parentSessionId/rootSessionId only"},
              "warnings": warnings}
    disk = {"available": disk_available, "turns": 0,
            "metrics": {name: metric() for name in DIMENSIONS}, "model_scope": "session-current"}
    if not disk_available:
        disk["unavailable_reason"] = "Index session files into this calibration database first."
    if disk_available:
        disk["omitted_records"] = None
        disk["omission_tracking"] = "disk_omissions" in tables
        if disk["omission_tracking"]:
            disk["omitted_records"] = db.execute(f"""
                SELECT count(*) FROM disk_omissions o JOIN disk_sources s ON s.path=o.source_path
                WHERE s.session_path IN ({path_marks})
            """, paths).fetchone()[0]
            if disk["omitted_records"]:
                warnings.append("Some selected disk records were omitted; their usage coverage is unknown and disk totals may be incomplete.")
        else:
            warnings.append("This disk index has no omission tracking; omitted-record coverage is unavailable.")
        totals = db.execute(f"""
            SELECT count(*) AS n,
              (SELECT sum(j.value ->> '$.usage') FROM disk_records r
                JOIN disk_sources s ON s.path=r.source_path, json_each(r.usage_json) j
                WHERE s.session_path IN ({path_marks}) AND r.kind='usage_summary'
                AND j.value ->> '$.unit'='credit'
                AND typeof(j.value ->> '$.usage') IN ('integer','real')) AS credits,
              sum(CASE WHEN json_array_length(r.usage_json)>0 AND NOT EXISTS(
                SELECT 1 FROM json_each(r.usage_json) j WHERE
                coalesce(j.value ->> '$.unit','')!='credit' OR
                typeof(j.value ->> '$.usage') NOT IN ('integer','real')) THEN 1 ELSE 0 END) AS known
            FROM disk_records r JOIN disk_sources s ON s.path=r.source_path
            WHERE s.session_path IN ({path_marks}) AND r.kind='usage_summary'
        """, paths + paths).fetchone()
        disk["turns"] = totals["n"]
        disk["metrics"] = {name: metric(observations=totals["n"]) for name in DIMENSIONS}
        disk["metrics"]["credits"] = metric(totals["credits"], totals["known"] or 0, totals["n"])
        disk["credit_count_unit"] = "turns with every summary entry numeric and unit=credit"
        disk["credit_sum_scope"] = "Observed credit entries, including partial turns; additive cost is unverified."
        disk["duplicate_request_ids"] = [dict(row) for row in db.execute(f"""
            SELECT request_id,count(*) AS occurrences FROM disk_request_ids i
            JOIN disk_sources s ON s.path=i.source_path WHERE s.session_path IN ({path_marks})
            GROUP BY request_id HAVING count(*)>1
        """, paths)]
        disk["turns_without_request_ids"] = db.execute(f"""
            SELECT count(*) FROM disk_records r JOIN disk_sources s ON s.path=r.source_path
            WHERE s.session_path IN ({path_marks}) AND r.kind='usage_summary' AND NOT EXISTS(
              SELECT 1 FROM disk_request_ids i WHERE i.source_path=r.source_path AND i.byte_offset=r.byte_offset)
        """, paths).fetchone()[0]
        if disk["duplicate_request_ids"] or scope == "tree":
            warnings.append("Disk turn credits may overlap across delegate turns or duplicate request IDs; the observed sum is not an exact additive tree cost.")
        if disk["turns_without_request_ids"]:
            warnings.append("Some disk turns lack request IDs; cross-turn overlap cannot be checked for them.")
        disk["context_observations"] = db.execute(f"""
            SELECT count(context_percentage) FROM disk_records r JOIN disk_sources s ON s.path=r.source_path
            WHERE s.session_path IN ({path_marks}) AND r.kind='contextUsage'
        """, paths).fetchone()[0]
        disk["models"] = [dict(row) for row in db.execute(f"""
            SELECT model_id,count(*) AS sessions FROM disk_sessions WHERE path IN ({path_marks}) GROUP BY model_id
        """, paths)]
    report["disk"] = disk
    captures = {"available": "captures" in tables, "observations": 0,
                "metrics": {name: metric() for name in DIMENSIONS}}
    if "captures" not in tables:
        captures["unavailable_reason"] = "No capture source has initialized this database."
    if "captures" in tables:
        globally_mapped = "0"
        if {"disk_request_ids", "disk_sources"} <= tables:
            globally_mapped = """EXISTS (SELECT 1 FROM disk_request_ids i
                JOIN disk_sources s ON s.path=i.source_path
                WHERE i.request_id IN (json_extract(c.response_json,'$.upstream_request_id'),
                  json_extract(c.response_json,'$.request_id')))"""
        captures["global_unattributed_observations"] = db.execute(f"""
            SELECT count(*) FROM captures c WHERE
              nullif(json_extract(c.metadata_json,'$."kiro:conversation_id"'),'') IS NULL
              AND NOT ({globally_mapped})
        """).fetchone()[0]
        if captures["global_unattributed_observations"]:
            warnings.append("The global capture store contains observations without a conversation identity or disk request-ID attribution; their relationship to this session is unknown and they are excluded from session totals.")
        joins = ""
        parameters = aliases
        if disk_available:
            joins = f"""OR EXISTS (SELECT 1 FROM disk_request_ids i JOIN disk_sources s ON s.path=i.source_path
                WHERE s.session_path IN ({path_marks}) AND i.request_id IN (
                  json_extract(c.response_json,'$.upstream_request_id'),json_extract(c.response_json,'$.request_id')))"""
            parameters = aliases + paths
        columns = ",".join("c." + name for name in ("id", "metadata_json", "response_json", "state", "completion_seen", *DIMENSIONS))
        chosen = f"""WITH chosen AS (SELECT {columns},json_extract(c.summary_json,'$.terminal') AS terminal FROM captures c WHERE
            json_extract(c.metadata_json,'$.\"kiro:conversation_id\"') IN ({placeholders}) {joins}) """
        sums = ",".join(f"sum({name}) AS {name},count({name}) AS {name}_known" for name in DIMENSIONS)
        total = db.execute(chosen + f"SELECT count(*) AS n,{sums},sum(CASE WHEN state!='complete' OR state IS NULL OR completion_seen!=1 OR completion_seen IS NULL THEN 1 ELSE 0 END) AS incomplete FROM chosen", parameters).fetchone()
        captures["observations"] = total["n"]
        captures["incomplete"] = total["incomplete"] or 0
        captures["metrics"] = {name: metric(total[name], total[name + "_known"], total["n"]) for name in DIMENSIONS}
        captures["models"] = []
        for row in db.execute(chosen + f"""
            SELECT json_extract(metadata_json,'$.model') AS requested_model,count(*) AS n,{sums}
            FROM chosen GROUP BY requested_model
        """, parameters):
            captures["models"].append({"requested_model": row["requested_model"], "observations": row["n"],
                "metrics": {name: metric(row[name], row[name + "_known"], row["n"]) for name in DIMENSIONS}})
        captures["association"] = "Explicit conversation ID or upstream request ID recorded for the selected session(s)."
        captures["terminal_states"] = [dict(row) for row in db.execute(chosen + """
            SELECT state,terminal,count(*) AS observations
            FROM chosen GROUP BY state,terminal
        """, parameters)]
        captures["identity_coverage"] = dict(db.execute(chosen + """
            SELECT sum(CASE WHEN json_extract(metadata_json,'$."kiro:conversation_id"') IS NOT NULL THEN 1 ELSE 0 END) AS conversation_id_present,
              sum(CASE WHEN coalesce(json_extract(response_json,'$.upstream_request_id'),json_extract(response_json,'$.request_id')) IS NOT NULL THEN 1 ELSE 0 END) AS upstream_request_id_present FROM chosen
        """, parameters).fetchone())
        captures["duplicate_upstream_request_ids"] = [dict(row) for row in db.execute(chosen + """
            , identities AS (
              SELECT id,json_extract(response_json,'$.upstream_request_id') AS request_id FROM chosen
              UNION SELECT id,json_extract(response_json,'$.request_id') FROM chosen)
            SELECT request_id,count(*) AS captures FROM identities
            WHERE request_id IS NOT NULL GROUP BY request_id HAVING count(*)>1
        """, parameters)]
        if captures["duplicate_upstream_request_ids"]:
            warnings.append("Duplicate upstream request IDs make capture totals ambiguous; every capture remains counted.")
    report["captures"] = captures
    return report


def observed_value(metric):
    total = metric["observed_sum"]
    if total is not None and metric["unknown"]:
        return f"{value(total)} ({metric['known']}/{metric['known'] + metric['unknown']})"
    return total


def render(report):
    captures, disk = report["captures"], report["disk"]
    sessions = len(report["sessions"])
    lines = [f"Session: {report['session']}  Scope: {report['scope']} ({sessions} session{'s' if sessions != 1 else ''})",
             "", "Captured calls (requested model; observed sums):"]
    rows = [[model["requested_model"], model["observations"],
             *(observed_value(model["metrics"][name]) for name in DIMENSIONS)]
            for model in captures.get("models", [])]
    rows.append(["TOTAL", captures["observations"] if captures["available"] else None,
                 *(observed_value(captures["metrics"][name]) for name in DIMENSIONS)])
    lines.append(table(["Model", "Calls", "Credits", "Input", "Output", "Cache read", "Cache write"], rows))
    if captures["available"]:
        count = captures["observations"]
        lines += ["", f"Capture coverage: {count} attributed call{'s' if count != 1 else ''}; {captures['incomplete']} incomplete.",
                  "Counters present (known/attributed; missing counters stay unknown):",
                  "; ".join(f"{label} {captures['metrics'][name]['known']}/{count}"
                            for label, name in zip(("credits", "input", "output", "cache read", "cache write"), DIMENSIONS)),
                  f"Global unattributed calls: {captures['global_unattributed_observations']} (excluded)."]
    else:
        lines.append("Capture coverage unavailable: " + captures["unavailable_reason"])
    lines += ["", "Disk observations (separate from captures):"]
    if disk["available"]:
        credits = disk["metrics"]["credits"]
        lines += ["Disk observations are from the last explicit index and may be stale.",
                  f"Turns: {disk['turns']}; observed credits: {value(credits['observed_sum'])}; fully known turns: {credits['known']}/{disk['turns']}.",
                  f"Omitted records: {value(disk['omitted_records'])}; turns without request IDs: {disk['turns_without_request_ids']}.",
                  "Disk model is session-current metadata, not a per-call model:",
                  table(["Model", "Sessions"], [[model["model_id"], model["sessions"]] for model in disk["models"]]),
                  disk["credit_sum_scope"]]
    else:
        lines.append("Disk coverage unavailable: " + disk["unavailable_reason"])
    lines += ["— = unknown or unobserved; sums include only observed values.",
              "Partial cells show sum (known calls/all calls).",
              *FOOTER_WARNINGS]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, required=True)
    parser.add_argument("--session", required=True)
    parser.add_argument("--scope", choices=("session", "tree"), default="session")
    parser.add_argument("--json", action="store_true", help="write the complete structured report as JSON")
    args = parser.parse_args()
    try:
        uri = args.db.resolve().as_uri() + "?mode=ro"
        with closing(sqlite3.connect(uri, uri=True)) as db:
            report = query(db, args.session, args.scope)
            if args.json:
                print(json.dumps(report, indent=2, sort_keys=True))
            else:
                print(render(report))
                for warning in report["warnings"]:
                    if warning not in FOOTER_WARNINGS:
                        print("Warning: " + warning, file=sys.stderr)
    except (OSError, ValueError, sqlite3.Error) as error:
        parser.exit(1, f"cannot query calibration database: {error}\n")


if __name__ == "__main__":
    main()
