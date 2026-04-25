"""cypfer_ai_audit — unified audit emitter for AI/LLM operations.

Emits two event classes on the standard cypfer_audit envelope:

    ai_prompt  — emitted before the model call. Returns a run_id so the
                 caller can correlate the response.
    ai_response — emitted after the model call returns (or fails). The
                  run_id ties it back to the matching prompt.

Both events are AUDIT-prefixed JSON lines printed to stdout; Promtail's
docker service discovery picks them up and applies the unified-schema
labels (source / class / case / actor / action / verdict). See the
timesketch-audit scrape in promtail/promtail-config.yaml for the
prefix-then-parse pipeline pattern this mirrors.

Hashes (SHA256), not full content, are emitted in the audit stream — full
prompt + response are stored as workflow artifacts and discoverable by
hash, keeping Loki volume bounded while preserving chain of custody.

See microcloud:llm/README.md §7 for the canonical schema definition.
"""

from __future__ import annotations

import hashlib
import json
import sys
import uuid
from datetime import datetime, timezone
from typing import Optional


# ---------------------------------------------------------------------------
# internal helpers
# ---------------------------------------------------------------------------

def _emit(obj: dict) -> None:
    """Print an AUDIT-prefixed JSON line to stdout, flushed.

    Sorted keys → identical lines for identical payloads, which makes
    log diffs and replay testing deterministic.
    """
    print("AUDIT " + json.dumps(obj, sort_keys=True), flush=True)


def _now_iso() -> str:
    """RFC3339 UTC timestamp with millisecond precision.

    Format matches what Promtail's `format: RFC3339` stage expects
    (see velociraptor-audit and timesketch-audit scrapes).
    """
    return (
        datetime.now(timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def _sha256_hex(text: str) -> str:
    """SHA256 hex digest of a UTF-8 string."""
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


# ---------------------------------------------------------------------------
# public API
# ---------------------------------------------------------------------------

def emit_ai_prompt(
    *,
    case_id: str,
    actor: str,
    model: str,
    template: str,
    prompt_text: str,
    input_tokens: Optional[int] = None,
    run_id: Optional[str] = None,
) -> str:
    """Emit an `ai_prompt` audit event before calling the model.

    Args:
        case_id: case identifier (e.g. "9998"). Lands in the JSON body
            as `caseid`; Promtail also sets a `case` label in the case
            container scrape, but the body field is authoritative.
        actor: who initiated the call (e.g. "ai-summary-worker"). For
            human-triggered tasks this is still the worker identity —
            the human's identity should be carried in a separate `triggered_by`
            field if needed (not yet in the v1 schema).
        model: registered model name (e.g.
            "foundation-sec-8b-instruct:q8_0").
        template: prompt template version (e.g. "summary.v1"). Bump this
            when the template text changes — the version goes in the
            audit stream so output quality can be correlated with template
            revisions.
        prompt_text: full constructed prompt (system + delimited evidence
            + user instruction). Used to compute `prompt_sha256`. Full
            text is NOT in the audit stream — store it as a workflow
            artifact and look it up by hash if needed.
        input_tokens: token count if known. None if not yet computed
            (some upstream APIs don't return this until response time).
        run_id: optional pre-generated UUID. If None, a fresh uuid4 is
            generated. Useful when the caller wants to correlate against
            an external request ID.

    Returns:
        The run_id — pass to `emit_ai_response` to correlate.
    """
    if run_id is None:
        run_id = str(uuid.uuid4())
    _emit(
        {
            "ts": _now_iso(),
            "event": "ai_prompt",
            "actor": actor,
            "caseid": case_id,
            "verdict": "ok",
            "model": model,
            "template": template,
            "input_tokens": input_tokens,
            "prompt_sha256": _sha256_hex(prompt_text),
            "run_id": run_id,
        }
    )
    return run_id


def emit_ai_response(
    *,
    case_id: str,
    actor: str,
    run_id: str,
    response_text: Optional[str] = None,
    output_tokens: Optional[int] = None,
    duration_ms: Optional[int] = None,
    refusal: bool = False,
    error: Optional[str] = None,
) -> None:
    """Emit an `ai_response` audit event after the model call.

    Verdict is derived from the args:
        error set       → "error"
        refusal True    → "refused"
        otherwise       → "ok"

    Refusals matter — they MUST land in the audit stream rather than
    being silently dropped (see microcloud:llm/README.md §4b and
    AI_INTEGRATION_HANDOFF.md §9.6).

    Args:
        case_id: case identifier (matches the prompt event).
        actor: who initiated the call (matches the prompt event).
        run_id: matching `ai_prompt` run_id.
        response_text: full model output. Used to compute
            `response_sha256`. None on error (no output to hash).
        output_tokens: token count if known.
        duration_ms: wall time of the model call in ms (proxy round-trip).
        refusal: True if refusal-detection flagged the output. Drives
            the verdict label used by Grafana refusal-rate panels.
        error: short error tag if the call failed (e.g. "model_timeout",
            "proxy_5xx", "quota_exceeded"). None on success.
    """
    if error:
        verdict = "error"
    elif refusal:
        verdict = "refused"
    else:
        verdict = "ok"

    obj: dict = {
        "ts": _now_iso(),
        "event": "ai_response",
        "actor": actor,
        "caseid": case_id,
        "verdict": verdict,
        "run_id": run_id,
        "duration_ms": duration_ms,
        "refusal": refusal,
    }
    if response_text is not None:
        obj["output_tokens"] = output_tokens
        obj["response_sha256"] = _sha256_hex(response_text)
    if error:
        obj["error"] = error
    _emit(obj)
