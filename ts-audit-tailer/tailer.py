#!/usr/bin/env python3
"""ts-audit-tailer — emit Timesketch audit events to stdout.

Timesketch has no unified audit feed — user actions are recorded in the
Postgres DB (searchhistory for sketch queries, analysissession for
analyzer runs). This tailer polls those tables for new rows and prints
an AUDIT-prefixed JSON line per event. Promtail's Docker SD picks up
the stdout on this container's name and ships the lines to Loki with
the unified audit-schema labels (see the promtail timesketch-audit scrape
in ../promtail/promtail-config.yaml).

Gaps accepted for v1:
  - Per-sketch ACL events (who was granted access to sketch X) aren't
    tracked in a first-class table and aren't emitted here.
  - Login events are handled by Authentik — not re-emitted here.
  - Destructive ops (sketch delete) aren't emitted because TS doesn't
    write an audit row; the sketch row simply disappears.

Extend by adding another query block in main() and a new event name.
"""

import json
import os
import signal
import sys
import time
from datetime import datetime, timezone

import psycopg2


DB_HOST = os.environ.get("DB_HOST", "postgres")
DB_NAME = os.environ.get("DB_NAME", "timesketch")
DB_USER = os.environ.get("DB_USER", "timesketch")
DB_PASS = os.environ["DB_PASS"]  # required

POLL_SECONDS = int(os.environ.get("POLL_SECONDS", "10"))
STATE_FILE = os.environ.get("STATE_FILE", "/state/position.json")
BATCH_SIZE = int(os.environ.get("BATCH_SIZE", "500"))


def emit(obj: dict) -> None:
    """Print an AUDIT-prefixed JSON line to stdout, flushed."""
    print("AUDIT " + json.dumps(obj, default=str), flush=True)


def warn(msg: str) -> None:
    print(f"warn: {msg}", file=sys.stderr, flush=True)


def load_state() -> dict:
    try:
        with open(STATE_FILE) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {"searchhistory_id": 0, "analysissession_id": 0}


def save_state(state: dict) -> None:
    try:
        tmp = STATE_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(state, f)
        os.replace(tmp, STATE_FILE)
    except OSError as e:
        warn(f"save_state failed: {e}")


def iso_utc(dt: datetime | None) -> str:
    if dt is None:
        dt = datetime.now(timezone.utc)
    elif dt.tzinfo is None:
        # TS stores "timestamp without time zone" — interpret as UTC.
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.isoformat().replace("+00:00", "Z")


def tail_searchhistory(cur, last_id: int) -> int:
    cur.execute(
        """
        SELECT sh.id,
               sh.created_at,
               u.username,
               sh.sketch_id,
               s.name   AS sketch_name,
               sh.query_string,
               sh.query_result_count
        FROM searchhistory sh
        LEFT JOIN "user"  u ON u.id = sh.user_id
        LEFT JOIN sketch  s ON s.id = sh.sketch_id
        WHERE sh.id > %s
        ORDER BY sh.id ASC
        LIMIT %s
        """,
        (last_id, BATCH_SIZE),
    )
    for id_, ts, username, sketch_id, sketch_name, query, result_count in cur.fetchall():
        emit(
            {
                "ts": iso_utc(ts),
                "event": "sketch_search",
                "actor": username or "unknown",
                "sketch_id": sketch_id,
                "sketch_name": sketch_name,
                "query": (query or "")[:500],  # bound the body
                "result_count": result_count,
            }
        )
        last_id = id_
    return last_id


def tail_analysissession(cur, last_id: int) -> int:
    cur.execute(
        """
        SELECT a.id,
               a.created_at,
               u.username,
               a.sketch_id,
               s.name   AS sketch_name
        FROM analysissession a
        LEFT JOIN "user"  u ON u.id = a.user_id
        LEFT JOIN sketch  s ON s.id = a.sketch_id
        WHERE a.id > %s
        ORDER BY a.id ASC
        LIMIT %s
        """,
        (last_id, BATCH_SIZE),
    )
    for id_, ts, username, sketch_id, sketch_name in cur.fetchall():
        emit(
            {
                "ts": iso_utc(ts),
                "event": "analyzer_run",
                "actor": username or "unknown",
                "sketch_id": sketch_id,
                "sketch_name": sketch_name,
            }
        )
        last_id = id_
    return last_id


def main() -> None:
    state = load_state()
    print(
        f"ts-audit-tailer starting: host={DB_HOST} db={DB_NAME} poll={POLL_SECONDS}s "
        f"resume sh_id={state['searchhistory_id']} as_id={state['analysissession_id']}",
        file=sys.stderr,
        flush=True,
    )
    while True:
        try:
            with psycopg2.connect(
                host=DB_HOST,
                dbname=DB_NAME,
                user=DB_USER,
                password=DB_PASS,
                connect_timeout=5,
            ) as conn:
                with conn.cursor() as cur:
                    state["searchhistory_id"] = tail_searchhistory(
                        cur, state["searchhistory_id"]
                    )
                    state["analysissession_id"] = tail_analysissession(
                        cur, state["analysissession_id"]
                    )
                save_state(state)
        except psycopg2.OperationalError as e:
            # TS postgres may be briefly down on case startup / restart;
            # don't spam — one line per failed cycle is plenty.
            warn(f"db unreachable: {e.__class__.__name__}")
        except Exception as e:  # noqa: BLE001
            warn(f"unexpected: {e.__class__.__name__}: {e}")
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    main()
