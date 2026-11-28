"""Offline fixtures only: no Kiro, credentials, home paths or network."""

import contextlib
import io
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

import capture
import disk_index
import query


def encoded(payload, **fields):
    return (json.dumps({"payload": payload, **fields}) + "\n").encode()


def usage(value=1.25):
    return encoded({
        "type": "usage_summary", "executionId": "execution-a", "turnId": "turn-a",
        "promptTurnSummaries": [{"usage": value, "unit": "credit", "text": "SECRET"}],
        "requestIds": ["upstream-a", "upstream-b"], "elapsedTime": 20,
        "status": "success", "text": "SECRET",
    }, timestamp="2026-10-01T00:00:00Z")


class DiskIndexTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.sessions = self.root / "sessions"
        self.session = self.sessions / "workspace" / "sess_synthetic"
        self.session.mkdir(parents=True)
        self.messages = self.session / "messages.jsonl"
        self.metadata = self.session / "session.json"
        self.metadata.write_text(json.dumps({
            "modelId": "synthetic-current", "createdAt": "2026-10-01",
            "contextWindowTokens": 1000, "prompt": "SECRET", "enabled": True,
            "parentSessionId": "parent-synthetic",
        }))
        self.path = self.root / "private" / "calibration.sqlite"
        self.db = disk_index.open_database(self.path)
        self.addCleanup(lambda: self.db.close())
        self.captured(self.db, "synthetic")

    @staticmethod
    def captured(db, conversation, root=None, started=0):
        db.executescript(capture.SCHEMA)
        metadata = {"invocation": "a" * 32, "kiro:conversation_id": conversation,
                    **({"kiro:root_conversation_id": root} if root else {})}
        db.execute("INSERT INTO captures(id,started_utc_ns,metadata_json) VALUES (?,?,?)",
                   (conversation + str(started), started, json.dumps(metadata)))
        db.commit()

    def messages_not_parsed(self):
        original = disk_index.decode
        def decode(data, path, offset):
            if path.name != "session.json":
                raise AssertionError("parsed again")
            return original(data, path, offset)
        return patch.object(disk_index, "decode", side_effect=decode)

    def scan(self):
        disk_index.index_tree(self.db, self.sessions)

    def count(self):
        return self.db.execute("SELECT count(*) FROM disk_records").fetchone()[0]

    def test_numeric_facts_privacy_and_request_identity(self):
        # Store the numeric projection and ordered identities, never source text or public permissions.
        self.messages.write_bytes(usage() + encoded({
            "type": "session_metadata", "key": "contextUsage",
            "executionId": "execution-a", "value": {"usagePercentage": 4.2, "text": "SECRET"},
        }) + encoded({"type": "assistant", "text": "SECRET"}))
        self.scan()
        self.assertEqual(self.count(), 2)
        row = self.db.execute("SELECT * FROM disk_records WHERE kind='usage_summary'").fetchone()
        self.assertEqual(json.loads(row["usage_json"]), [{"usage": 1.25, "unit": "credit"}])
        self.assertEqual((row["execution_id"], row["turn_id"], row["elapsed_ms"]),
                         ("execution-a", "turn-a", 20))
        self.assertEqual([row[0] for row in self.db.execute("SELECT request_id FROM disk_request_ids ORDER BY request_index")],
                         ["upstream-a", "upstream-b"])
        session = self.db.execute("SELECT * FROM disk_sessions").fetchone()
        self.assertEqual(session["model_scope"], "session-current")
        self.assertEqual(json.loads(session["identifiers_json"]), {"parentSessionId": "parent-synthetic"})
        self.assertEqual(json.loads(session["numeric_metadata_json"]), {"contextWindowTokens": 1000})
        self.assertNotIn("SECRET", "\n".join(self.db.iterdump()))

    def test_partial_tail_append_restart_and_idempotence(self):
        first, second = usage(), usage(2)
        self.messages.write_bytes(first + second[:15])
        self.scan()
        self.assertEqual(self.count(), 1)
        self.assertEqual(self.db.execute("SELECT offset FROM disk_sources").fetchone()[0], len(first))
        self.db.close()
        self.db = disk_index.open_database(self.path)
        with self.messages.open("ab") as stream:
            stream.write(second[15:])
        self.scan()
        self.scan()
        self.assertEqual(self.count(), 2)

    def test_truncate_replace_and_same_size_rewrite_retire_old_facts(self):
        self.messages.write_bytes(usage() * 2)
        self.scan()
        self.messages.write_bytes(usage(3))
        self.scan()
        self.assertEqual(self.count(), 1)
        replacement = self.session / "replacement"
        replacement.write_bytes(usage(4) * 3)
        replacement.replace(self.messages)
        self.scan()
        self.assertEqual(self.count(), 3)
        self.messages.write_bytes(usage(5) * 3)
        os.utime(self.messages, ns=(1, 2))
        self.scan()
        values = [json.loads(row[0])[0]["usage"] for row in self.db.execute("SELECT usage_json FROM disk_records")]
        self.assertEqual(values, [5, 5, 5])
        self.assertEqual(self.db.execute("SELECT count(*) FROM disk_request_ids").fetchone()[0], 6)

    def test_malformed_complete_lines_are_visible_omissions(self):
        invalid = b'{"SECRET":broken}\n'
        invalid_usage = encoded({"type": "usage_summary", "requestIds": "SECRET"})
        # Syntax, record shape and parser recursion must all be reported, without leaking the line.
        deeply_nested = b'{"SECRET_DEEP":' + b'[' * 1200 + b'0' + b']' * 1200 + b'}\n'
        self.messages.write_bytes(usage() + invalid + invalid_usage + deeply_nested + usage(2))
        self.scan()
        self.assertEqual(self.count(), 2)
        omissions = self.db.execute("SELECT * FROM disk_omissions ORDER BY byte_offset").fetchall()
        self.assertEqual([(row["byte_offset"], row["byte_count"], row["reason"]) for row in omissions],
                         [(len(usage()), len(invalid), "invalid_json_or_usage_record"),
                          (len(usage()) + len(invalid), len(invalid_usage), "invalid_json_or_usage_record"),
                          (len(usage()) + len(invalid) + len(invalid_usage), len(deeply_nested),
                           "invalid_json_or_usage_record")])
        self.assertEqual(self.db.execute("SELECT offset FROM disk_sources").fetchone()[0], self.messages.stat().st_size)
        self.assertNotIn("SECRET", "\n".join(self.db.iterdump()))

    def test_database_failure_rolls_back_facts_omissions_and_checkpoint(self):
        self.messages.write_bytes(usage())
        self.scan()
        self.db.execute("""CREATE TRIGGER fail_insert BEFORE INSERT ON disk_records
                        BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END""")
        with self.messages.open("ab") as stream:
            stream.write(b'broken\n' + usage(2))
        with self.assertRaisesRegex(sqlite3.IntegrityError, "synthetic failure"):
            self.scan()
        self.assertEqual(self.count(), 1)
        self.assertEqual(self.db.execute("SELECT count(*) FROM disk_omissions").fetchone()[0], 0)
        self.assertEqual(self.db.execute("SELECT offset FROM disk_sources").fetchone()[0], len(usage()))

    def test_parse_memory_failure_is_omitted_and_following_usage_is_indexed(self):
        exhausted = encoded({"type": "tool_result", "text": "SECRET"})
        healthy = usage(2)
        self.messages.write_bytes(exhausted + healthy)
        original = disk_index.decode
        def decode(data, *args):
            if data == exhausted:
                raise MemoryError("SECRET")
            return original(data, *args)
        with patch.object(disk_index, "decode", side_effect=decode):
            self.scan()
        self.assertEqual(self.count(), 1)
        self.assertEqual(dict(self.db.execute("SELECT * FROM disk_omissions").fetchone()),
                         {"source_path": str(self.messages), "byte_offset": 0,
                          "byte_count": len(exhausted), "reason": "parse_memory_exhausted"})
        self.assertEqual(self.db.execute("SELECT offset FROM disk_sources").fetchone()[0],
                         len(exhausted) + len(healthy))
        self.assertNotIn("SECRET", "\n".join(self.db.iterdump()))

    def test_blank_complete_lines_advance_checkpoint_without_omissions(self):
        self.messages.write_bytes(b'\n \t\r\n' + usage() + b'  \n')
        self.scan()
        self.assertEqual(self.count(), 1)
        self.assertEqual(self.db.execute("SELECT count(*) FROM disk_omissions").fetchone()[0], 0)
        self.assertEqual(self.db.execute("SELECT offset FROM disk_sources").fetchone()[0], self.messages.stat().st_size)

    def test_missing_record_fields_stay_null_without_inventing_request_ids(self):
        self.messages.write_bytes(encoded({"type": "usage_summary"}) + encoded({
            "type": "session_metadata", "key": "contextUsage", "value": {},
        }))
        self.scan()
        row = self.db.execute("SELECT * FROM disk_records WHERE kind='contextUsage'").fetchone()
        self.assertIsNone(row["context_percentage"])
        self.assertIsNone(row["execution_id"])
        self.assertIsNone(row["timestamp"])
        self.assertEqual(self.db.execute("SELECT count(*) FROM disk_request_ids").fetchone()[0], 0)

    def test_large_tool_record_is_parsed_and_discarded_between_usage(self):
        tool = encoded({"type": "tool_result", "image": "SECRET_IMAGE" * 100})
        self.messages.write_bytes(usage() + tool + usage(2))
        with patch.object(disk_index, "MAX_RECORD", 2048):
            self.scan()
        self.assertEqual(self.count(), 2)
        self.assertEqual(self.db.execute("SELECT count(*) FROM disk_omissions").fetchone()[0], 0)
        self.assertNotIn("SECRET", "\n".join(self.db.iterdump()))

    def test_oversized_tail_is_retried_then_omitted_atomically_on_restart(self):
        first = usage()
        oversized = b'{"SECRET_UNKNOWN": "' + b'x' * 3000 + b'"}'
        self.messages.write_bytes(first + oversized)
        with patch.object(disk_index, "MAX_RECORD", 1024):
            self.scan()
            self.scan()
            self.assertEqual(self.count(), 1)
            self.assertEqual(self.db.execute("SELECT offset FROM disk_sources").fetchone()[0], len(first))
            self.assertEqual(self.db.execute("SELECT count(*) FROM disk_omissions").fetchone()[0], 0)
            self.db.close()
            self.db = disk_index.open_database(self.path)
            with self.messages.open("ab") as stream:
                stream.write(b'\n' + usage(2))
            self.scan()
            self.scan()
        omission = dict(self.db.execute("SELECT * FROM disk_omissions").fetchone())
        self.assertEqual(omission, {"source_path": str(self.messages), "byte_offset": len(first),
                         "byte_count": len(oversized) + 1, "reason": "record_exceeds_parse_budget"})
        self.assertEqual(self.count(), 2)
        self.assertEqual(self.db.execute("SELECT offset FROM disk_sources").fetchone()[0], self.messages.stat().st_size)
        self.assertNotIn("SECRET", "\n".join(self.db.iterdump()))
        # Replacement removes omission metadata through the same cascade as usage facts.
        replacement = self.session / "replacement"
        replacement.write_bytes(usage(3))
        replacement.replace(self.messages)
        self.scan()
        self.assertEqual(self.count(), 1)
        self.assertEqual(self.db.execute("SELECT count(*) FROM disk_omissions").fetchone()[0], 0)
        self.messages.write_bytes(b'broken\n' + usage(4))
        self.scan()
        self.assertEqual(self.db.execute("SELECT count(*) FROM disk_omissions").fetchone()[0], 1)
        self.messages.write_bytes(usage(5))  # Truncation also cascades omissions.
        self.scan()
        self.assertEqual(self.count(), 1)
        self.assertEqual(self.db.execute("SELECT count(*) FROM disk_omissions").fetchone()[0], 0)

    def test_oversized_record_drains_with_bounded_reads(self):
        class TrackedStream(io.BytesIO):
            def readline(self, size=-1):
                calls.append(size)
                return super().readline(size)
        calls = []
        with patch.object(disk_index, "MAX_RECORD", 100), patch.object(disk_index, "DRAIN_CHUNK", 64):
            stream = TrackedStream(b'x' * 400 + b'\nnext\n')
            disk_index.read_record(stream)
        self.assertEqual(calls[0], 101)
        self.assertEqual(set(calls[1:]), {64})
        self.assertEqual(stream.read(), b'next\n')

    def test_symlinks_are_ignored(self):
        outside = self.root / "outside"
        outside.write_bytes(usage())
        self.messages.symlink_to(outside)
        self.scan()
        self.assertEqual(self.count(), 0)

    def test_cli_summary_warns_about_omitted_usage_coverage(self):
        self.messages.write_bytes(usage() + b'broken\n')
        result = subprocess.run([sys.executable, disk_index.__file__, "--db", str(self.path),
                                 "--sessions", str(self.sessions)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("1 sources, 1 usage/context records, 1 omitted records", result.stdout)
        self.assertIn("unknown usage coverage", result.stderr)
        structured = subprocess.run([sys.executable, disk_index.__file__, "--db", str(self.path),
                                     "--sessions", str(self.sessions), "--json"], capture_output=True, text=True)
        self.assertEqual(structured.returncode, 0, structured.stderr)
        self.assertEqual(json.loads(structured.stdout), {"sources": 1, "records": 1, "omitted_records": 1})

    def test_cli_requires_explicit_inputs(self):
        result = subprocess.run([sys.executable, str(Path(disk_index.__file__))],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("the following arguments are required: --db, --sessions", result.stderr)

    def test_cli_full_pass_waits_for_index_lock(self):
        self.messages.write_bytes(usage())
        held = capture.lock_beside(self.path, disk_index.INDEX_LOCK, shared=True)
        try:
            process = subprocess.Popen([sys.executable, disk_index.__file__, "--db", str(self.path),
                                        "--sessions", str(self.sessions)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            with self.assertRaises(subprocess.TimeoutExpired):
                process.wait(timeout=1)
            tables = {row[0] for row in self.db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            self.assertNotIn("disk_sources", tables)  # it waits before touching the index
        finally:
            os.close(held)
        stdout, stderr = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 0, stderr)
        self.assertIn("1 sources, 1 usage/context records", stdout)
        self.assertEqual(os.stat(str(self.path) + disk_index.INDEX_LOCK).st_mode & 0o777, 0o600)

    def test_invalid_session_metadata_does_not_block_later_sessions(self):
        self.messages.write_bytes(usage())
        self.scan()  # Seed metadata that must be retired when it becomes invalid.
        self.metadata.write_text('{"parentSessionId":')
        other = self.sessions / "workspace/sess_z_later"
        other.mkdir()
        (other / "session.json").write_text(json.dumps({"modelId": "later"}))
        (other / "messages.jsonl").write_bytes(usage(2))
        self.captured(self.db, "sess_z_later")
        self.scan()
        self.assertEqual(self.count(), 2)
        self.assertIsNone(self.db.execute("SELECT path FROM disk_sessions WHERE path=?", (str(self.session),)).fetchone())
        omission = self.db.execute("SELECT session_path,reason FROM disk_session_omissions").fetchone()
        self.assertEqual(tuple(omission), (str(self.session), "invalid_session_metadata"))
        result = subprocess.run([sys.executable, disk_index.__file__, "--db", str(self.path), "--sessions", str(self.sessions), "--json"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"sources": 2, "records": 2, "omitted_records": 1})
        self.assertIn("descendant discovery may be incomplete", result.stderr)
        self.metadata.write_text(json.dumps({"modelId": "repaired", "parentSessionId": "parent-repaired"}))
        self.scan()
        self.assertEqual(self.db.execute("SELECT count(*) FROM disk_session_omissions").fetchone()[0], 0)
        row = self.db.execute("SELECT model_id,identifiers_json FROM disk_sessions WHERE path=?", (str(self.session),)).fetchone()
        self.assertEqual(row["model_id"], "repaired")
        self.assertEqual(json.loads(row["identifiers_json"])["parentSessionId"], "parent-repaired")

    def test_unreadable_session_metadata_is_visible_but_sql_errors_propagate(self):
        self.messages.write_bytes(usage())
        with patch.object(disk_index, "read_session", side_effect=PermissionError("synthetic")):
            self.scan()
        self.assertEqual(self.count(), 1)
        self.assertEqual(self.db.execute("SELECT reason FROM disk_session_omissions").fetchone()[0], "unreadable_session_metadata")
        with patch.object(disk_index, "index_session", side_effect=sqlite3.OperationalError("synthetic database failure")):
            with self.assertRaisesRegex(sqlite3.OperationalError, "database failure"):
                self.scan()

    def test_unchanged_tree_neither_writes_nor_reparses_transcripts_and_model_updates(self):
        self.messages.write_bytes(usage())
        self.scan()
        changes = self.db.total_changes
        with self.messages_not_parsed():
            self.scan()
        self.assertEqual(self.db.total_changes, changes)
        self.metadata.write_text(json.dumps({"modelId": "new-current"}))
        with self.messages_not_parsed():
            self.scan()
        self.assertEqual(self.db.execute("SELECT model_id FROM disk_sessions").fetchone()[0], "new-current")

    def test_batches_checkpoint_before_further_parsing_and_allow_capture(self):
        self.messages.write_bytes(usage() * 130)
        paused, release = threading.Event(), threading.Event()
        errors, calls = [], []
        original = disk_index.decode
        def decode(*args):
            calls.append(1)
            if len(calls) == 130:  # session metadata plus 128 committed message records
                paused.set()
                if not release.wait(3):
                    raise AssertionError("test capture stalled behind index transaction")
            return original(*args)
        def scan():
            try:
                with disk_index.open_database(self.path) as db:
                    disk_index.index_tree(db, self.sessions)
                db.close()
            except BaseException as error:
                errors.append(error)
        with patch.object(disk_index, "decode", side_effect=decode):
            worker = threading.Thread(target=scan)
            worker.start()
            try:
                self.assertTrue(paused.wait(3))
                self.assertEqual(self.count(), 128)
                self.assertEqual(self.db.execute("SELECT offset FROM disk_sources").fetchone()[0], len(usage()) * 128)
                collector = capture.Collector(self.path)
                ident = collector.begin({}, b"{}")
                collector.finish(ident)
                collector.close()
            finally:
                release.set()
                worker.join(4)
        self.assertFalse(worker.is_alive())
        self.assertFalse(errors, errors)
        self.assertEqual(self.count(), 130)

    def test_existing_disk_index_adds_omission_table_without_replaying_facts(self):
        self.messages.write_bytes(usage())
        self.scan()
        self.db.execute("DROP TABLE disk_omissions")
        with self.messages_not_parsed():
            self.scan()
        self.assertEqual(self.count(), 1)
        self.assertEqual(self.db.execute("SELECT count(*) FROM disk_omissions").fetchone()[0], 0)

    def test_capture_schema_can_follow_disk_schema(self):
        self.messages.write_bytes(usage())
        with contextlib.closing(disk_index.open_database(self.path.parent / "disk-first.sqlite")) as db:
            disk_index.index_tree(db, self.sessions)
            self.captured(db, "sess_synthetic")
            disk_index.index_tree(db, self.sessions)
            self.assertEqual(db.execute("SELECT count(*) FROM disk_records").fetchone()[0], 1)
            self.assertIsNotNone(db.execute("SELECT name FROM sqlite_master WHERE name='captures'").fetchone())

    def child(self, name, metadata, records=b"", mtime=None):
        session = self.sessions / "other-workspace" / name
        session.mkdir(parents=True)
        (session / "session.json").write_text(json.dumps(metadata))
        (session / "messages.jsonl").write_bytes(records)
        if mtime is not None:
            for path in session.iterdir():
                os.utime(path, ns=(mtime, mtime))
        return session

    def ids(self, session):
        row = self.db.execute("SELECT identifiers_json FROM disk_sessions WHERE path=?", (str(session),)).fetchone()
        return row and json.loads(row[0])

    def test_workflow_steps_follow_root_and_owner_and_unlinked_sessions_are_pruned(self):
        self.messages.write_bytes(usage())
        step = self.child("sess_step", {"rootConversationId": "sess_synthetic", "id": "sess_step", "_meta": {"kiro": {
            "workflow": {"workflowId": "wf_a", "nodeId": "node-a", "type": "step"},
            "serverSession": {"role": "workflow-step", "ownerSessionId": "sess_synthetic"}}}}, usage(2))
        self.child("sess_helper", {"parentSessionId": "step"}, usage(3))
        unlinked = self.child("sess_unlinked", {"rootConversationId": "sess_elsewhere"}, usage(4))
        self.scan()
        step_ids = {"nodeId": "node-a", "ownerSessionId": "sess_synthetic", "role": "workflow-step",
                    "rootConversationId": "sess_synthetic", "workflowId": "wf_a"}
        self.assertEqual(self.ids(step), step_ids)
        self.assertIsNone(self.ids(unlinked))
        self.assertEqual(self.count(), 3)
        self.assertIsNone(self.db.execute("SELECT 1 FROM disk_sources WHERE session_path=?", (str(unlinked),)).fetchone())
        # A full scan, not just requested history, repairs legacy lineage even if the file did not change.
        self.db.execute("UPDATE disk_sessions SET identifiers_json='{}',lineage_version=0 WHERE path=?", (str(step),))
        self.db.commit()
        self.scan()
        self.assertEqual(self.ids(step), step_ids)
        self.assertEqual(self.count(), 3)
        self.db.execute("DELETE FROM captures")
        self.db.commit()
        self.captured(self.db, "sess_elsewhere")
        self.scan()
        self.assertEqual([Path(row[0]).name for row in self.db.execute("SELECT path FROM disk_sessions")], ["sess_unlinked"])
        self.assertEqual(self.count(), 1)

    def test_unlinked_sessions_older_than_captures_are_not_read(self):
        self.db.execute("DELETE FROM captures")
        self.captured(self.db, "synthetic", started=10**18)
        old = self.child("sess_old", {"rootConversationId": "sess_synthetic"}, usage(), mtime=10**18 - 1)
        os.utime(self.metadata, ns=(1, 1))  # A captured session is read regardless of age.
        self.messages.write_bytes(usage(2))
        os.utime(self.messages, ns=(1, 1))
        read = []
        original = disk_index.read_session
        with patch.object(disk_index, "read_session", side_effect=lambda path: read.append(path.parent) or original(path)):
            self.scan()
        self.assertEqual(read, [self.session])
        self.assertIsNone(self.ids(old))
        self.assertEqual(self.count(), 1)

    def test_history_discovers_never_indexed_descendant_in_an_old_workspace(self):
        """An in-place append leaves the workspace mtime unchanged but still appears in history."""
        self.messages.write_bytes(usage())
        self.child("sess_step", {"ownerSessionId": "sess_synthetic"}, usage(2))
        old = 10**18
        recent = old + 10**10
        for path in (self.messages, self.metadata):
            os.utime(path, ns=(recent, recent))
        self.scan()
        nested = self.child("sess_nested", {"_meta": {"kiro": {"serverSession": {"ownerSessionId": "sess_step"}}}},
                            mtime=old)
        os.utime(nested.parent, ns=(old, old))
        messages = nested / "messages.jsonl"
        with messages.open("ab") as stream:
            stream.write(usage(3))
        os.utime(messages, ns=(recent, recent))
        self.assertEqual(nested.parent.stat().st_mtime_ns, old)
        disk_index.index_tree(self.db, self.sessions, requested=("sess_synthetic",))
        self.assertEqual(self.ids(nested), {"ownerSessionId": "sess_step"})
        self.assertEqual(self.count(), 3)

    def test_history_reparses_legacy_lineage_with_unchanged_metadata(self):
        """A cache with only top-level identifiers must still discover a nested owner link."""
        self.messages.write_bytes(usage())
        child = self.child("sess_child", {
            "sessionId": "child",
            "_meta": {"kiro": {"serverSession": {"ownerSessionId": "sess_synthetic"}}},
        })
        self.db.executescript("""
            CREATE TABLE disk_sessions (
                path TEXT PRIMARY KEY, model_id TEXT, model_scope TEXT NOT NULL,
                created_at TEXT, last_modified_at TEXT, numeric_metadata_json TEXT NOT NULL,
                file_identity TEXT NOT NULL, identifiers_json TEXT NOT NULL
            );
        """)
        info = (child / "session.json").stat()
        identity = f"{info.st_dev}:{info.st_ino}:{info.st_size}:{info.st_mtime_ns}"
        with self.db:
            self.db.execute("INSERT INTO disk_sessions VALUES (?,NULL,'session-current',NULL,NULL,'{}',?,?)",
                            (str(child), identity, '{"sessionId": "child"}'))
        with (child / "messages.jsonl").open("ab") as messages:
            messages.write(usage(2))

        disk_index.index_tree(self.db, self.sessions, requested=("sess_synthetic",))
        result = query.query(self.db, "sess_synthetic", "tree")
        self.assertEqual((result["sessions"], result["disk"]["turns"]),
                         (["sess_child", "sess_synthetic"], 2))

    def test_history_refreshes_indexed_descendant_in_an_old_workspace(self):
        """Walking every workspace reuses unchanged metadata and transcript checkpoints."""
        self.messages.write_bytes(usage())
        step = self.child("sess_step", {"ownerSessionId": "synthetic"}, usage(2))
        nested = self.child("sess_nested", {"parentSessionId": "sess_step"}, usage(3))
        old = 10**18
        recent = old + 10**10
        for path in (step / "session.json", step / "messages.jsonl", nested / "session.json",
                     nested.parent, self.session.parent):
            os.utime(path, ns=(old, old))
        for path in (self.messages, self.metadata):
            os.utime(path, ns=(recent, recent))
        disk_index.index_tree(self.db, self.sessions, requested=("sess_synthetic",))
        self.assertEqual(self.count(), 3)
        messages = nested / "messages.jsonl"
        with messages.open("ab") as stream:
            stream.write(usage(4))
        os.utime(messages, ns=(recent, recent))
        statements = []
        self.db.set_trace_callback(statements.append)
        self.addCleanup(self.db.set_trace_callback, None)
        with (patch.object(os, "scandir", wraps=os.scandir) as scandir,
              patch.object(disk_index, "read_session", wraps=disk_index.read_session) as read):
            disk_index.index_tree(self.db, self.sessions, requested=("sess_synthetic",))
        self.assertCountEqual([call.args[0] for call in scandir.call_args_list],
                              [self.sessions, self.session.parent, nested.parent])
        read.assert_not_called()
        self.assertEqual(self.count(), 4)
        lookups = [sql for sql in statements if sql.startswith("SELECT path FROM disk_sessions WHERE json_extract")]
        plans = {row[3] for sql in lookups for row in self.db.execute("EXPLAIN QUERY PLAN " + sql)}
        # Every supported ancestry lookup must stay indexed; a production list could silently lose a key.
        for link in ("ownerSessionId", "parentSessionId", "rootConversationId", "rootSessionId"):
            self.assertTrue(any(f"SEARCH disk_sessions USING INDEX disk_sessions_{link} " in plan for plan in plans),
                            plans)

    def test_history_updates_departed_lineage_and_leaves_unrelated_rows(self):
        """Retire a stale link to the requested tree without refreshing or pruning unrelated history."""
        self.messages.write_bytes(usage())
        departed = self.child("sess_departed", {"parentSessionId": "sess_synthetic"}, usage(2))
        unrelated = self.child("sess_unrelated", {"parentSessionId": "sess_elsewhere"}, usage(3))
        self.captured(self.db, "sess_unrelated")
        self.scan()
        (departed / "session.json").write_text('{"parentSessionId":"sess_other"}')
        (unrelated / "session.json").write_text('{"parentSessionId":"sess_different"}')
        with (unrelated / "messages.jsonl").open("ab") as messages:
            messages.write(usage(4))
        disk_index.index_tree(self.db, self.sessions, requested=("sess_synthetic",))
        self.assertEqual(self.ids(departed), {"parentSessionId": "sess_other"})
        self.assertEqual(self.ids(unrelated), {"parentSessionId": "sess_elsewhere"})
        self.assertEqual(self.count(), 3)

    def test_history_read_error_keeps_committed_batch_and_resumes(self):
        """Interrupt a replacement transcript and resume from the first batch's checkpoint."""
        self.messages.write_bytes(usage())
        self.scan()
        record = usage(3)
        self.messages.write_bytes(record * 130)
        checkpoint = len(record) * 128
        self.metadata.write_text('{"modelId":"replacement"}')
        read_record = disk_index.read_record
        reads = 0

        def fail_after_batch(stream):
            nonlocal reads
            reads += 1
            if reads == 129:
                raise OSError("private fixture details")
            return read_record(stream)

        with (patch.object(disk_index, "read_record", side_effect=fail_after_batch),
              contextlib.redirect_stderr(io.StringIO()) as output):
            disk_index.index_tree(self.db, self.sessions, requested=("sess_synthetic",))
        self.assertEqual(output.getvalue(),
                         f"Warning: could not read Kiro session {self.session}; disk observations may be stale.\n")
        self.assertEqual(self.count(), 128)
        self.assertEqual(self.db.execute("SELECT offset FROM disk_sources").fetchone()[0], checkpoint)
        self.assertEqual(self.db.execute("SELECT model_id FROM disk_sessions").fetchone()[0], "replacement")
        self.assertEqual(json.loads(self.db.execute("SELECT usage_json FROM disk_records WHERE byte_offset=0").fetchone()[0]),
                         [{"usage": 3, "unit": "credit"}])

        def read_remaining(stream):
            self.assertGreaterEqual(stream.tell(), checkpoint)
            return read_record(stream)

        with patch.object(disk_index, "read_record", side_effect=read_remaining):
            disk_index.index_tree(self.db, self.sessions, requested=("sess_synthetic",))
        self.assertEqual(self.count(), 130)

    def test_history_records_unrelated_unreadable_metadata_without_losing_lineage(self):
        """Keep the cached child and its turn when another tree encounters a metadata read error."""
        child = self.child("sess_child", {"parentSessionId": "sess_other"}, usage())
        self.captured(self.db, "sess_other")
        self.scan()
        metadata = child / "session.json"
        metadata.write_text('{"parentSessionId":"sess_changed"}')
        read_session = disk_index.read_session

        def read_metadata(path):
            """Fail the read after discovery has found the changed file."""
            if path == metadata:
                raise PermissionError("fixture metadata is unreadable")
            return read_session(path)

        with (patch.object(disk_index, "read_session", read_metadata),
              contextlib.redirect_stderr(io.StringIO()) as warnings):
            disk_index.index_tree(self.db, self.sessions, requested=("sess_other",))
            self.assertEqual(self.db.execute("SELECT count(*) FROM disk_session_omissions").fetchone()[0], 0)
            disk_index.index_tree(self.db, self.sessions, requested=("sess_synthetic",))
        self.assertEqual((self.ids(child), self.count()), ({"parentSessionId": "sess_other"}, 1))
        self.assertEqual([tuple(row) for row in self.db.execute("SELECT * FROM disk_session_omissions")],
                         [(str(child), "unreadable_session_metadata")])
        self.assertEqual(warnings.getvalue().splitlines(),
                         [f"Warning: could not read Kiro session {child}; disk observations may be stale."] * 2)

    def test_full_pass_keeps_rows_from_other_session_roots(self):
        self.messages.write_bytes(usage())
        self.scan()
        other = self.root / "other-sessions"
        (other / "workspace").mkdir(parents=True)
        disk_index.index_tree(self.db, other)
        self.assertEqual(self.count(), 1)

    def test_cli_reports_errors_without_traceback(self):
        # A missing root raises OSError; an existing non-directory raises ValueError.
        for root, stderr in ((self.metadata, "--sessions must be a directory\n"), (self.root / "missing", None)):
            with self.subTest(root=root.name):
                result = subprocess.run([sys.executable, disk_index.__file__, "--db", str(self.path),
                                         "--sessions", str(root)], capture_output=True, text=True,
                                        env={**os.environ, "LC_ALL": "C"})
                self.assertEqual((result.returncode, result.stdout), (1, ""))
                if stderr is None:
                    self.assertIn("No such file or directory", result.stderr)
                    self.assertNotIn("Traceback", result.stderr)
                else:
                    self.assertEqual(result.stderr, stderr)

    def test_top_level_lineage_wins_over_nested_keys(self):
        ids = disk_index.session_identifiers({"parentSessionId": "sess_local", "_meta": {"kiro": {
            "serverSession": {"parentSessionId": "srv_x", "role": "workflow-step"}}}})
        self.assertEqual(ids, {"parentSessionId": "sess_local", "role": "workflow-step"})

    def test_history_clears_repaired_omission_out_of_scope(self):
        self.messages.write_bytes(usage())
        unlinked = self.child("sess_unlinked", {}, usage(4))
        (unlinked / "session.json").write_text("{")
        self.scan()
        rows = lambda: self.db.execute("SELECT count(*) FROM disk_session_omissions").fetchone()[0]
        self.assertEqual(rows(), 1)
        (unlinked / "session.json").write_text("{}")
        os.utime(unlinked.parent)
        disk_index.index_tree(self.db, self.sessions, requested=("sess_synthetic",))
        self.assertEqual(rows(), 0)

    def test_cli_vacuums_after_pruning(self):
        self.messages.write_bytes(usage() * 2000)
        self.scan()
        self.db.execute("DELETE FROM captures")
        self.db.commit()
        self.db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        before = self.path.stat().st_size
        collector = capture.Collector(self.path)  # A running collector holds its lock and an idle connection.
        try:
            result = subprocess.run([sys.executable, disk_index.__file__, "--db", str(self.path),
                                     "--sessions", str(self.sessions), "--json"], capture_output=True, text=True)
        finally:
            collector.close()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"sources": 0, "records": 0, "omitted_records": 0})
        self.assertEqual(self.db.execute("PRAGMA freelist_count").fetchone()[0], 0)
        self.assertLess(self.path.stat().st_size, before / 4)

    def test_cli_leaves_free_pages_it_did_not_prune(self):
        self.messages.write_bytes(usage())
        self.scan()
        # Pages another writer freed, as sealing does, are reused by later captures, not vacuumed.
        self.db.execute("CREATE TABLE scratch(data BLOB)")
        self.db.execute("INSERT INTO scratch VALUES (?)", (bytes(1000000),))
        self.db.execute("DROP TABLE scratch")
        self.db.commit()
        free = self.db.execute("PRAGMA freelist_count").fetchone()[0]
        self.assertGreater(free, 0)
        result = subprocess.run([sys.executable, disk_index.__file__, "--db", str(self.path),
                                 "--sessions", str(self.sessions), "--json"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"sources": 1, "records": 1, "omitted_records": 0})
        self.assertEqual(self.db.execute("PRAGMA freelist_count").fetchone()[0], free)


if __name__ == "__main__":
    unittest.main()
