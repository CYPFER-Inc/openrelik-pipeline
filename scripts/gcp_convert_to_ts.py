#!/usr/bin/env python3
"""
gcp_convert_to_ts.py -- convert an existing GCP Cloud Logging JSON
array file to TimeSketch-uploadable JSONL.

Use this when you already have the raw JSON (e.g. from `gcloud
logging read --format=json > 2025-11.json`) and just need to reshape
it for TS ingest. No gcloud required.

Streams the input via ijson so:
  * Multi-GB files run in constant memory.
  * Stream-level corruption (e.g. gcloud died mid-export and wrote
    stderr into the file -- the case-1336 2025-11.json scenario)
    halts the stream but EVERY event before the bad point is already
    on disk in the output. Partial output is real output.
  * Per-event errors don't kill the run; counted and skipped.

Each output line is the original GCP event verbatim plus three added
fields TS expects:
    datetime         copied from event.timestamp (TS sorts on this)
    message          synthesised "<method> by <actor> on <project>"
                     (falls back gracefully for jsonPayload /
                      textPayload shapes)
    timestamp_desc   "GCP log entry" (analyst-facing column label)

Usage:
    pip install ijson
    python gcp_convert_to_ts.py <input.json> <output.jsonl>

Then upload <output.jsonl> via the TS Web UI -> Add timeline.
"""

import json
import sys
import time

try:
    import ijson
except ImportError:
    sys.stderr.write("ijson not found. Install with: pip install ijson\n")
    sys.exit(2)


PROGRESS_EVERY = 100_000


def synthesise(ev):
    """Add datetime / message / timestamp_desc in place. Handles the
    three common GCP log shapes (protoPayload audit logs, jsonPayload
    custom, textPayload raw) gracefully."""
    pp = ev.get("protoPayload") or {}
    jp = ev.get("jsonPayload") or {}
    tp = ev.get("textPayload")
    res_labels = (ev.get("resource") or {}).get("labels") or {}

    method = (
        pp.get("methodName")
        or jp.get("event_subtype")
        or jp.get("eventName")
        or ev.get("severity")
        or "gcp"
    )
    actor = (
        (pp.get("authenticationInfo") or {}).get("principalEmail")
        or jp.get("actor")
        or "unknown"
    )
    project = res_labels.get("project_id") or "unknown"

    if tp:
        snippet = tp.replace("\n", " ")[:200]
        msg = f"{ev.get('severity', 'gcp')} - {snippet}"
    else:
        msg = f"{method} by {actor} on {project}"

    ev["datetime"] = ev.get("timestamp")
    ev["message"] = msg
    ev["timestamp_desc"] = "GCP log entry"
    return ev


def main():
    if len(sys.argv) != 3:
        sys.stderr.write(f"usage: {sys.argv[0]} <input.json> <output.jsonl>\n")
        sys.exit(2)

    src, dst = sys.argv[1], sys.argv[2]
    ok = 0
    bad = 0
    started = time.monotonic()
    last_progress = started

    with open(src, "rb") as fin, open(dst, "w", encoding="utf-8") as fout:
        try:
            for ev in ijson.items(fin, "item"):
                try:
                    synthesise(ev)
                    fout.write(json.dumps(ev, separators=(",", ":")) + "\n")
                    ok += 1
                except Exception as exc:
                    bad += 1
                    if bad <= 10:
                        sys.stderr.write(
                            f"  per-event error #{ok + bad}: {exc}\n"
                        )

                if (ok + bad) % PROGRESS_EVERY == 0:
                    now = time.monotonic()
                    elapsed = now - started
                    interval = now - last_progress
                    rate = (
                        PROGRESS_EVERY / interval
                        if interval > 0 else 0
                    )
                    sys.stderr.write(
                        f"  ... {ok:>12,} events ok, {bad:>6,} bad, "
                        f"{elapsed:>6.0f}s elapsed, "
                        f"{rate:>7,.0f} ev/s\n"
                    )
                    sys.stderr.flush()
                    last_progress = now
        except ijson.JSONError as exc:
            sys.stderr.write(
                f"\nSTREAM-LEVEL parse error after {ok:,} ok / {bad:,} bad: "
                f"{exc}\n"
                "Everything before this point IS in the output -- partial\n"
                "JSONL is uploadable as-is. The unrecovered tail is the\n"
                "events between the corruption and end of file.\n"
            )

    elapsed = time.monotonic() - started
    sys.stderr.write(
        "\nSummary\n-------\n"
        f"  converted ok: {ok:>12,} events\n"
        f"  per-event errors (skipped): {bad:>6,}\n"
        f"  elapsed: {elapsed:.0f}s\n"
        f"  output: {dst}\n"
    )


if __name__ == "__main__":
    main()
