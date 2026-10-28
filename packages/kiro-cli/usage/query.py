"""Read observed usage for an explicit Kiro session; exact counters win, ~estimates fill only their gaps."""

import argparse
from contextlib import closing
import json
from pathlib import Path
import re
import sqlite3
import sys

import credit_discount
from disk_index import LINKS, session_id
from display import table, value


DIMENSIONS = ("credits", "input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens")
COUNTERS = (*DIMENSIONS, "total_tokens")
ESTIMATED = ("total_tokens", "input_tokens", "output_tokens", "cache_read_tokens")
HIT_SHARE = .01  # Estimated cached tokens must reach this share of input to count as a hit.
# Output characters beyond output_text that still bill as output tokens, from retained events.
# Terminal response.completed items count only for a kind with no deltas, so neither is counted twice;
# only the first completed event counts when a stream repeats it.
EXTRA_OUTPUT_CHARS = """(SELECT sum(chars) FROM (
    SELECT CASE
      WHEN json_extract(e.data_json,'$.type') IN ('response.function_call_arguments.delta','response.reasoning_text.delta')
        THEN length(json_extract(e.data_json,'$.delta'))
      WHEN e.event_name='toolUseEvent' THEN length(json_extract(e.data_json,'$.input'))
      WHEN e.event_name='reasoningContentEvent' THEN length(json_extract(e.data_json,'$.text')) END AS chars
    FROM events e WHERE e.capture_id=c.id
    UNION ALL SELECT CASE
      WHEN json_extract(item.value,'$.type')='function_call' AND NOT EXISTS(SELECT 1 FROM events d WHERE d.capture_id=c.id
          AND json_extract(d.data_json,'$.type')='response.function_call_arguments.delta')
        THEN length(json_extract(item.value,'$.arguments'))
      WHEN json_extract(item.value,'$.type')='reasoning' AND NOT EXISTS(SELECT 1 FROM events d WHERE d.capture_id=c.id
          AND json_extract(d.data_json,'$.type')='response.reasoning_text.delta')
        THEN (SELECT sum(length(json_extract(part.value,'$.text'))) FROM json_each(item.value,'$.content') part
              WHERE json_extract(part.value,'$.type')='reasoning_text') END
    FROM events e, json_each(e.data_json,'$.response.output') item
    WHERE e.capture_id=c.id AND e.seq=(SELECT min(f.seq) FROM events f WHERE f.capture_id=c.id
      AND json_extract(f.data_json,'$.type')='response.completed')))"""
CONVERSATION_POOL = """CASE WHEN nullif(json_extract({metadata},'$."kiro:conversation_id"'),'') IS NULL THEN 'unknown'
    WHEN json_extract({metadata},'$."kiro:conversation_id"') IN (?,?) THEN 'root_conversation'
    ELSE 'other_linked_conversations' END"""
FOOTER_WARNINGS = (
    "Own-versus-delegate attribution within a session is unavailable; session scope can include delegate work.",
    "Disk turn credits and capture credits overlap and must never be added.",
)


def metric(total=None, known=0, observations=0):
    return {"observed_sum": total, "known": known,
            "unknown": observations - known}


def cache_hit_rate(row):
    evaluable = row["cache_evaluable"]
    hits = row["cache_hits"] or 0
    return {"hits": hits, "evaluable": evaluable, "unknown": row["n"] - evaluable,
            "percentage": 100 * hits / evaluable if evaluable else None}


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
        rows = db.execute(f"""
            WITH RECURSIVE chosen(path, identifiers_json) AS (
              SELECT path,identifiers_json FROM disk_sessions WHERE session_name(path)=?
              UNION
              SELECT d.path,d.identifiers_json FROM disk_sessions d JOIN chosen p
              ON ?='tree' AND EXISTS(SELECT 1 FROM json_each(d.identifiers_json) j
                WHERE j.key IN ({",".join("?" for _ in LINKS)})
                AND j.value IN (session_name(p.path),substr(session_name(p.path),6)))
            ) SELECT path FROM chosen
        """, (session, scope, *LINKS))
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
    warnings = [*FOOTER_WARNINGS, "Context percentages are observations; ~token values derived from them are estimates."]
    report = {"session": session, "scope": scope, "sessions": sorted(selected),
              "attribution": {"own_vs_delegate": "unavailable", "tree_identity": "explicit " + "/".join(LINKS) + " only"},
              "warnings": warnings}
    disk = {"available": disk_available, "turns": 0,
            "metrics": {name: metric() for name in DIMENSIONS}, "model_scope": "session-current"}
    disk["metadata_omission_tracking"] = "disk_session_omissions" in tables
    disk["metadata_omitted_sessions"] = (db.execute("SELECT count(*) FROM disk_session_omissions").fetchone()[0]
                                          if disk["metadata_omission_tracking"] else None)
    if disk["metadata_omitted_sessions"]:
        warnings.append("Some session metadata was omitted from the disk index; descendant discovery may be incomplete because omitted ancestry is unknown.")
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
                "metrics": {name: metric() for name in COUNTERS}}
    captures["pools"] = {
        pool: {"observations": 0, "metrics": {name: metric() for name in COUNTERS},
               "cache_hit_rate": {"hits": 0, "evaluable": 0, "unknown": 0, "percentage": None}, "estimates": {}}
        for pool in ("other_linked_conversations", "root_conversation", "unknown")}
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
              AND nullif(json_extract(c.metadata_json,'$."kiro:root_conversation_id"'),'') IS NULL
              AND NOT ({globally_mapped})
        """).fetchone()[0]
        if captures["global_unattributed_observations"]:
            warnings.append("The global capture store contains observations without a conversation identity, root-conversation lineage, or disk request-ID attribution; their relationship to this session is unknown and they are excluded from session totals.")
        joins = ""
        parameters = list(aliases)
        if scope == "tree":
            joins = f"OR json_extract(c.metadata_json,'$.\"kiro:root_conversation_id\"') IN ({placeholders})"
            parameters += aliases
        if disk_available:
            joins += f""" OR EXISTS (SELECT 1 FROM disk_request_ids i JOIN disk_sources s ON s.path=i.source_path
                WHERE s.session_path IN ({path_marks}) AND i.request_id IN (
                  json_extract(c.response_json,'$.upstream_request_id'),json_extract(c.response_json,'$.request_id')))"""
            parameters += paths
        columns = ",".join("c." + name for name in ("id", "metadata_json", "response_json", "state", "completion_seen", *DIMENSIONS))
        chosen = f"""WITH chosen AS (SELECT {columns},json_extract(c.summary_json,'$.terminal') AS terminal,
            json_extract(c.summary_json,'$.metering_events') AS metering_events FROM captures c WHERE
            json_extract(c.metadata_json,'$.\"kiro:conversation_id\"') IN ({placeholders}) {joins}) """
        sums = ",".join(f"sum({name}) AS {name},count({name}) AS {name}_known" for name in DIMENSIONS)
        sums += """,sum(CASE WHEN input_tokens IS NOT NULL AND output_tokens IS NOT NULL THEN input_tokens+output_tokens END) AS total_tokens,
            count(CASE WHEN input_tokens IS NOT NULL AND output_tokens IS NOT NULL THEN 1 END) AS total_tokens_known,
            count(cache_read_tokens) AS cache_evaluable,
            sum(CASE WHEN cache_read_tokens>0 THEN 1 ELSE 0 END) AS cache_hits"""
        total = db.execute(chosen + f"SELECT count(*) AS n,{sums},sum(CASE WHEN state!='complete' OR state IS NULL OR completion_seen!=1 OR completion_seen IS NULL THEN 1 ELSE 0 END) AS incomplete FROM chosen", parameters).fetchone()
        captures["observations"] = total["n"]
        captures["incomplete"] = total["incomplete"] or 0
        captures["metrics"] = {name: metric(total[name], total[name + "_known"], total["n"]) for name in COUNTERS}
        captures["cache_hit_rate"] = cache_hit_rate(total)
        if scope == "tree":
            report["sessions"] = sorted(selected | {
                session_id(name)
                for row in db.execute(chosen + "SELECT DISTINCT json_extract(metadata_json,'$.\"kiro:conversation_id\"') FROM chosen", parameters)
                if isinstance(name := row[0], str) and re.fullmatch(r"(?:sess_)?[A-Za-z0-9_-]+", name)})
        captures["models"] = []
        for row in db.execute(chosen + f"""
            SELECT json_extract(metadata_json,'$.model') AS requested_model,count(*) AS n,{sums}
            FROM chosen GROUP BY requested_model
        """, parameters):
            captures["models"].append({"requested_model": row["requested_model"], "observations": row["n"],
                "metrics": {name: metric(row[name], row[name + "_known"], row["n"]) for name in COUNTERS},
                "cache_hit_rate": cache_hit_rate(row), "estimates": {}})
        for row in db.execute(chosen + f"""
            SELECT {CONVERSATION_POOL.format(metadata="metadata_json")} AS pool,
                count(*) AS n,{sums}
            FROM chosen GROUP BY pool
        """, [*parameters, session, session.removeprefix("sess_")]):
            captures["pools"][row["pool"]] = {
                "observations": row["n"], "metrics": {name: metric(row[name], row[name + "_known"], row["n"]) for name in COUNTERS},
                "cache_hit_rate": cache_hit_rate(row), "estimates": {}}
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
        captures["multiple_metering_events"] = db.execute(chosen + "SELECT count(*) FROM chosen WHERE metering_events>1", parameters).fetchone()[0]
        if captures["multiple_metering_events"]:
            warnings.append(f"{captures['multiple_metering_events']} selected call(s) carried more than one meteringEvent; their credits keep the last value, which may not be the call's total charge.")
    captures["estimates"] = {}
    if scope == "tree":
        warnings.append("Root-linked lineage may include forks as well as subagents; it is not proof of caller role.")
    report["attribution"]["pool_rule"] = "Root conversation matches the selected session ID (with or without sess_); Other linked conversations have a different recorded conversation ID; Unknown has no recorded conversation ID. This partition does not identify main versus delegate roles."
    if scope == "tree":
        report["attribution"]["tree_identity"] = "Explicit " + "/".join(LINKS) + " or captured root_conversation_id only"
    report["captures"] = captures
    call_reports(db, report, chosen if captures["available"] else None, parameters if captures["available"] else [])
    return report


def call_reports(db, report, chosen, parameters):
    """Per-call credit-discount diagnostic and ~token estimates, aggregated per model and pool."""
    captures = report["captures"]
    sources = [captures, *captures.get("models", []), *captures["pools"].values()]
    tallies = {}
    for source in sources:
        source["credit_discount"] = credit_discount.aggregate()
        tallies[id(source)] = {"estimated": dict.fromkeys(ESTIMATED, 0), "sums": dict.fromkeys(ESTIMATED, 0),
                               "known": dict.fromkeys(ESTIMATED, 0), "hits": 0}
    if chosen is None:
        return
    models = {source["requested_model"]: source for source in captures["models"]}
    event_tables = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    proof = "0 AS retained,0 AS terminal,0 AS text_only,0 AS no_reasoning_tools"
    extra_chars = EXTRA_OUTPUT_CHARS if "events" in event_tables else "NULL"
    if {"events", "chunks"} <= event_tables:
        proof = """
          c.request_gzip IS NOT NULL AND EXISTS(SELECT 1 FROM events e WHERE e.capture_id=c.id)
            AND EXISTS(SELECT 1 FROM chunks k WHERE k.capture_id=c.id)
            AND NOT EXISTS(SELECT 1 FROM events e WHERE e.capture_id=c.id AND e.frame_gzip IS NULL)
            AND NOT EXISTS(SELECT 1 FROM chunks k WHERE k.capture_id=c.id AND k.application_gzip IS NULL) AS retained,
          json_extract(c.summary_json,'$.terminal')='response.completed'
            AND json_extract(c.summary_json,'$.output_count_source')='terminal_output'
            AND (SELECT count(*) FROM events e WHERE e.capture_id=c.id AND json_extract(e.data_json,'$.type')='response.completed')=1 AS terminal,
          EXISTS(SELECT 1 FROM events e WHERE e.capture_id=c.id AND json_extract(e.data_json,'$.type')='response.completed'
            AND json_type(e.data_json,'$.response.output')='array' AND json_array_length(e.data_json,'$.response.output')>0
            AND NOT EXISTS(SELECT 1 FROM json_each(e.data_json,'$.response.output') item
              WHERE coalesce(json_extract(item.value,'$.type'),'')!='message'
              OR coalesce(json_type(item.value,'$.content'),'')!='array'
              OR EXISTS(SELECT 1 FROM json_each(item.value,'$.content') part
                WHERE coalesce(json_extract(part.value,'$.type'),'')!='output_text'
                OR coalesce(json_type(part.value,'$.text'),'')!='text'))) AS text_only,
          NOT EXISTS(SELECT 1 FROM events e WHERE e.capture_id=c.id AND (
            coalesce(json_extract(e.data_json,'$.type'),'') LIKE '%reasoning%'
            OR coalesce(e.event_name,'') LIKE '%reasoning%'
            OR coalesce(json_extract(e.data_json,'$.type'),'') LIKE '%function_call%'
            OR coalesce(json_extract(e.data_json,'$.type'),'') LIKE '%tool%'
            OR coalesce(e.event_name,'') LIKE '%function_call%'
            OR coalesce(e.event_name,'') LIKE '%tool%'
            OR coalesce(json_extract(e.data_json,'$.item.type'),'message')!='message'
            OR coalesce(json_extract(e.data_json,'$.part.type'),'output_text')!='output_text')) AS no_reasoning_tools
        """
    for row in db.execute(chosen + f"""SELECT c.id,c.metadata_json,c.credits,c.context_usage_percentage,
        c.input_tokens,c.output_tokens,c.cache_read_tokens,
        json_extract(c.summary_json,'$.output_text_chars') AS chars,{extra_chars} AS extra_chars,
        {CONVERSATION_POOL.format(metadata="c.metadata_json")} AS pool,
        c.state='complete' AND c.completion_seen=1 AND c.transport_ended=1 AND c.issues_json='[]'
          AND c.dropped_bytes=0 AND c.dropped_chunks=0 AS complete
        FROM chosen JOIN captures c ON c.id=chosen.id""", [*parameters, report["session"], report["session"].removeprefix("sess_")]):
        metadata = json.loads(row["metadata_json"] or "{}")
        facts = {key: row[key] for key in ("credits", "chars")}
        facts.update(context=row["context_usage_percentage"], model=metadata.get("model"), effort=metadata.get("effort"))
        facts["complete"] = bool(row["complete"])
        result = credit_discount.preflight(facts)
        if result is None:
            evidence = db.execute("SELECT " + proof + " FROM captures c WHERE c.id=?", (row["id"],)).fetchone()
            facts.update({key: bool(evidence[key]) for key in ("retained", "terminal", "text_only", "no_reasoning_tools")})
            result = credit_discount.classify(facts)
        values, estimated = call_counters(row, metadata.get("model"))
        for source in (captures, models[metadata.get("model")], captures["pools"][row["pool"]]):
            credit_discount.add(source["credit_discount"], result, row["id"])
            tally = tallies[id(source)]
            for name in ESTIMATED:
                if values[name] is not None:
                    tally["sums"][name] += values[name]
                    tally["known"][name] += 1
                    tally["estimated"][name] += name in estimated
            cached = values["cache_read_tokens"] or 0
            # An estimated split counts as a hit only above fit noise (tens of tokens on 1-5 char calls).
            tally["hits"] += (cached > 0 and cached >= HIT_SHARE * values["input_tokens"]
                              if "cache_read_tokens" in estimated else cached > 0)
    for source in sources:
        tally, n = tallies[id(source)], source["observations"]
        # Only groups with at least one estimated call get ~cells; exact-only groups keep their observed sums.
        for name in ESTIMATED:
            if tally["estimated"][name]:
                source["estimates"][name] = metric(tally["sums"][name], tally["known"][name], n)
        if tally["estimated"]["cache_read_tokens"]:
            evaluable = tally["known"]["cache_read_tokens"]
            source["estimates"]["cache_hit_rate"] = {"hits": tally["hits"], "evaluable": evaluable, "unknown": n - evaluable,
                                                     "percentage": 100 * tally["hits"] / evaluable}


def call_counters(row, model):
    """One call's counters: exact where reported, else its ~estimate; returns (values, estimated names)."""
    chars = row["chars"]
    if isinstance(chars, int) and isinstance(row["extra_chars"], int):
        chars += row["extra_chars"]
    exact = {name: row[name] for name in ("input_tokens", "output_tokens", "cache_read_tokens")}
    guess = credit_discount.estimate(model, row["context_usage_percentage"], row["credits"], chars,
                                     exact["output_tokens"], exact["input_tokens"]) or {}
    exact["total_tokens"] = (exact["input_tokens"] + exact["output_tokens"]
                             if exact["input_tokens"] is not None and exact["output_tokens"] is not None else None)
    values = {name: exact[name] if exact[name] is not None else guess.get(name) for name in ESTIMATED}
    return values, {name for name in ESTIMATED if exact[name] is None and values[name] is not None}


def capture_tables(captures):
    """Shared model totals and conversation groups for both human reports."""
    def counter(source, name):
        observed = source["metrics"][name]
        estimated = name in source.get("estimates", {})
        item = source["estimates"][name] if estimated else observed
        total = item["observed_sum"]
        if total is None:
            return None
        text = f"{total:,.6f}" if name == "credits" else value(total)
        if estimated:
            text = "~" + text
        if item["unknown"]:
            text += f" ({item['known']}/{item['known'] + item['unknown']})"
        return text
    show_discount = any(source["credit_discount"]["eligible"] or source["credit_discount"]["anomaly"]
                        for source in (captures, *captures.get("models", [])))
    def row(label, source):
        rate = source.get("estimates", {}).get("cache_hit_rate") or source.get("cache_hit_rate", {})
        hit = rate.get("percentage")
        hit = f"~{hit:.1f}%" if hit is not None else None
        if hit is not None and rate["unknown"]:
            hit += f" ({rate['evaluable']}/{source['observations']})"
        discount = source["credit_discount"]
        percentage = discount["percentage"]
        discount_cell = f"~{percentage:.1f}% ({discount['eligible']}/{discount['requests']})" if percentage is not None else None
        return [label, source["observations"] if captures["available"] else None,
                *(counter(source, name) for name in ("total_tokens", "input_tokens", "output_tokens", "cache_read_tokens")),
                hit, counter(source, "credits"), *([discount_cell] if show_discount else [])]
    columns = ["Model", "Requests", "Total tokens", "Input", "Output", "Cached", "Hit %", "Credits", *(["Discount %"] if show_discount else [])]
    model_rows = [row(model["requested_model"], model) for model in captures.get("models", [])]
    pool_rows = [row("Total", captures)]
    pool_rows += [row(label, captures["pools"][pool])
                  for pool, label in (("root_conversation", "Root conversation"), ("other_linked_conversations", "Other linked"), ("unknown", "Unknown"))]
    notes = (["Discount % includes partial credit discounts, not observed cache hits; experimental (classified/all requests).",
              f"Profile anomalies: {captures['credit_discount']['anomaly']}; excluded: {captures['credit_discount']['excluded']}."] if show_discount else [])
    return "\n".join([table(columns, model_rows), "", table(["Pool", *columns[1:]], pool_rows), *notes])


CAPTURE_NOTES = (
    "Partial cells: sum (known/all requests); ~ adds estimates where a call lacks the exact counter; — unavailable.",
    "~Tokens: total = context % of the model window; output ≈ chars/4 (text, tool arguments, reasoning); cached fitted from credits.",
    "Hit % = requests with cached tokens (reported, or ~estimated at 1% of input or more) / requests with a cached value.",
    "Root conversation carries the selected ID; Other linked holds workflow steps and subagents and may include helpers/forks. Disk credits are excluded.",
)


def render(report):
    captures, disk = report["captures"], report["disk"]
    sessions = len(report["sessions"])
    lines = [f"Session: {report['session']}  Scope: {report['scope']} ({sessions} session{'s' if sessions != 1 else ''})",
             "", "Captured calls (requested model; observed sums):"]
    lines.append(capture_tables(captures))
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
        lines += ["Disk observations refreshed after this launch." if disk.get("refreshed") else "Disk observations are from the last index and may be stale.",
                  f"Turns: {disk['turns']}; observed credits: {value(credits['observed_sum'])}; fully known turns: {credits['known']}/{disk['turns']}.",
                  f"Omitted records: {value(disk['omitted_records'])}; turns without request IDs: {disk['turns_without_request_ids']}.",
                  f"Session metadata omissions (global): {value(disk['metadata_omitted_sessions'])}; omitted ancestry may hide descendants.",
                  "Disk model is session-current metadata, not a per-call model:",
                  table(["Model", "Sessions"], [[model["model_id"], model["sessions"]] for model in disk["models"]]),
                  disk["credit_sum_scope"]]
    else:
        lines.append("Disk coverage unavailable: " + disk["unavailable_reason"])
    lines += [*CAPTURE_NOTES, *FOOTER_WARNINGS]
    return "\n".join(lines)


def render_summary(report):
    """Compact model totals and conversation groups; no transcript or disk costs."""
    captures = report["captures"]
    credits = captures["metrics"]["credits"]
    coverage = (f"Captured calls only; credits known {credits['known']}/{captures['observations']}; incomplete {captures.get('incomplete', 0)}."
                if captures["available"] else "Capture source unavailable; totals unknown.")
    return "\n".join([
        capture_tables(captures), coverage, *CAPTURE_NOTES,
    ])


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
