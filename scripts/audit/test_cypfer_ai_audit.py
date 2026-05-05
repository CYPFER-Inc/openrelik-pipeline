"""Tests for cypfer_ai_audit.

Run from repo root:

    pip install pytest
    pytest scripts/audit/

Or run directly without pytest:

    python scripts/audit/test_cypfer_ai_audit.py
"""

from __future__ import annotations

import hashlib
import json
import re
import sys
import uuid
from pathlib import Path

# Make this test runnable both via `pytest scripts/audit/` (where the
# package import works) and via `python scripts/audit/test_...py`
# (where it doesn't). Adding the parent dir to sys.path covers both.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from cypfer_ai_audit import emit_ai_prompt, emit_ai_response  # noqa: E402


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def _parse_audit_line(line: str) -> dict:
    """Strip the AUDIT prefix and parse the JSON payload."""
    assert line.startswith("AUDIT "), f"missing AUDIT prefix: {line!r}"
    return json.loads(line[len("AUDIT "):])


def _capture_emit(capsys, fn, **kwargs):
    """Call `fn(**kwargs)` and return (return_value, parsed_audit_dict)."""
    result = fn(**kwargs)
    captured = capsys.readouterr()
    lines = [line for line in captured.out.splitlines() if line.startswith("AUDIT ")]
    assert len(lines) == 1, f"expected exactly one AUDIT line, got {len(lines)}: {lines!r}"
    return result, _parse_audit_line(lines[0])


# ---------------------------------------------------------------------------
# emit_ai_prompt
# ---------------------------------------------------------------------------

def test_emit_ai_prompt_returns_uuid_when_not_provided(capsys):
    run_id, _ = _capture_emit(
        capsys,
        emit_ai_prompt,
        case_id="9998",
        actor="ai-summary-worker",
        model="foundation-sec-8b-instruct:q8_0",
        template="summary.v1",
        prompt_text="hello",
    )
    # Should be a valid uuid4
    parsed = uuid.UUID(run_id)
    assert parsed.version == 4


def test_emit_ai_prompt_preserves_provided_run_id(capsys):
    fixed = "11111111-2222-3333-4444-555555555555"
    run_id, evt = _capture_emit(
        capsys,
        emit_ai_prompt,
        case_id="9998",
        actor="ai-summary-worker",
        model="foundation-sec-8b-instruct:q8_0",
        template="summary.v1",
        prompt_text="hello",
        run_id=fixed,
    )
    assert run_id == fixed
    assert evt["run_id"] == fixed


def test_emit_ai_prompt_full_schema(capsys):
    """Lock the v1 schema — every field that goes to Loki must be here."""
    _, evt = _capture_emit(
        capsys,
        emit_ai_prompt,
        case_id="9998",
        actor="ai-summary-worker",
        model="foundation-sec-8b-instruct:q8_0",
        template="summary.v1",
        prompt_text="hello world",
        input_tokens=1843,
    )
    assert set(evt.keys()) == {
        "ts",
        "event",
        "actor",
        "caseid",
        "verdict",
        "model",
        "template",
        "input_tokens",
        "prompt_sha256",
        "run_id",
    }
    assert evt["event"] == "ai_prompt"
    assert evt["actor"] == "ai-summary-worker"
    assert evt["caseid"] == "9998"
    assert evt["verdict"] == "ok"
    assert evt["model"] == "foundation-sec-8b-instruct:q8_0"
    assert evt["template"] == "summary.v1"
    assert evt["input_tokens"] == 1843


def test_emit_ai_prompt_sha256_matches_input(capsys):
    text = "the quick brown fox"
    _, evt = _capture_emit(
        capsys,
        emit_ai_prompt,
        case_id="1",
        actor="x",
        model="m",
        template="t",
        prompt_text=text,
    )
    assert evt["prompt_sha256"] == hashlib.sha256(text.encode("utf-8")).hexdigest()


def test_emit_ai_prompt_input_tokens_optional(capsys):
    _, evt = _capture_emit(
        capsys,
        emit_ai_prompt,
        case_id="1",
        actor="x",
        model="m",
        template="t",
        prompt_text="x",
    )
    assert evt["input_tokens"] is None


# ---------------------------------------------------------------------------
# emit_ai_response — verdict derivation is the load-bearing logic here
# ---------------------------------------------------------------------------

def test_emit_ai_response_ok(capsys):
    _, evt = _capture_emit(
        capsys,
        emit_ai_response,
        case_id="9998",
        actor="ai-summary-worker",
        run_id="abc",
        response_text="hello world",
        output_tokens=412,
        duration_ms=8420,
    )
    assert evt["event"] == "ai_response"
    assert evt["verdict"] == "ok"
    assert evt["refusal"] is False
    assert evt["run_id"] == "abc"
    assert evt["output_tokens"] == 412
    assert evt["duration_ms"] == 8420
    assert evt["response_sha256"] == hashlib.sha256(b"hello world").hexdigest()
    assert "error" not in evt


def test_emit_ai_response_input_tokens(capsys):
    """Authoritative prompt token count is filled on the response event,
    sourced from response.usage.prompt_tokens — avoids needing a
    client-side tokenizer in the worker just to populate the audit."""
    _, evt = _capture_emit(
        capsys,
        emit_ai_response,
        case_id="9998",
        actor="ai-summary-worker",
        run_id="abc",
        response_text="hello world",
        input_tokens=1843,
        output_tokens=412,
        duration_ms=8420,
    )
    assert evt["input_tokens"] == 1843
    assert evt["output_tokens"] == 412


def test_emit_ai_response_input_tokens_optional(capsys):
    """input_tokens unset stays None (matches the ai_prompt event's own
    null-by-default behaviour pre-tokenizer)."""
    _, evt = _capture_emit(
        capsys,
        emit_ai_response,
        case_id="9998",
        actor="ai-summary-worker",
        run_id="abc",
        response_text="hello world",
        output_tokens=412,
        duration_ms=8420,
    )
    assert evt["input_tokens"] is None


def test_emit_ai_response_refusal(capsys):
    _, evt = _capture_emit(
        capsys,
        emit_ai_response,
        case_id="9998",
        actor="ai-summary-worker",
        run_id="abc",
        response_text="I cannot help with that request.",
        output_tokens=8,
        duration_ms=1200,
        refusal=True,
    )
    assert evt["verdict"] == "refused"
    assert evt["refusal"] is True
    # response_sha256 is still set — the refusal text itself is the audit-relevant content
    assert "response_sha256" in evt


def test_emit_ai_response_error_no_output(capsys):
    _, evt = _capture_emit(
        capsys,
        emit_ai_response,
        case_id="9998",
        actor="ai-summary-worker",
        run_id="abc",
        duration_ms=600000,
        error="model_timeout",
    )
    assert evt["verdict"] == "error"
    assert evt["error"] == "model_timeout"
    # No response_text → no sha256 / output_tokens fields
    assert "response_sha256" not in evt
    assert "output_tokens" not in evt


def test_emit_ai_response_error_takes_precedence_over_refusal(capsys):
    """If both error and refusal are set, error wins — chain-of-custody priority."""
    _, evt = _capture_emit(
        capsys,
        emit_ai_response,
        case_id="9998",
        actor="ai-summary-worker",
        run_id="abc",
        duration_ms=100,
        refusal=True,
        error="proxy_5xx",
    )
    assert evt["verdict"] == "error"


# ---------------------------------------------------------------------------
# format invariants
# ---------------------------------------------------------------------------

def test_audit_line_is_audit_prefixed(capsys):
    emit_ai_prompt(
        case_id="1", actor="x", model="m", template="t", prompt_text="x",
    )
    captured = capsys.readouterr()
    assert captured.out.startswith("AUDIT ")
    assert captured.out.endswith("\n")


def test_audit_line_is_single_json_object(capsys):
    """Promtail's regex stage expects exactly one JSON object per line."""
    emit_ai_response(
        case_id="1", actor="x", run_id="r",
        response_text="x", output_tokens=1, duration_ms=1,
    )
    captured = capsys.readouterr()
    audit_lines = [l for l in captured.out.splitlines() if l.startswith("AUDIT ")]
    assert len(audit_lines) == 1
    payload = audit_lines[0][len("AUDIT "):]
    obj = json.loads(payload)  # must parse cleanly
    assert isinstance(obj, dict)


def test_timestamp_is_rfc3339_utc_millis(capsys):
    _, evt = _capture_emit(
        capsys,
        emit_ai_prompt,
        case_id="1", actor="x", model="m", template="t", prompt_text="x",
    )
    # 2026-04-25T12:34:56.789Z
    assert re.match(
        r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$",
        evt["ts"],
    ), f"unexpected ts format: {evt['ts']!r}"


def test_keys_are_sorted_for_determinism(capsys):
    """Sorted keys → identical JSON for identical payloads. Useful for
    log diffing and replay testing."""
    emit_ai_prompt(
        case_id="9998",
        actor="ai-summary-worker",
        model="m",
        template="t",
        prompt_text="x",
        run_id="fixed-id",
    )
    captured = capsys.readouterr()
    payload = captured.out.split("AUDIT ", 1)[1].strip()
    # Re-serialising parsed JSON with sort_keys=True must produce the same string
    obj = json.loads(payload)
    assert payload == json.dumps(obj, sort_keys=True)


# ---------------------------------------------------------------------------
# stand-alone runner so this works without pytest installed
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    try:
        import pytest
    except ImportError:
        print("pytest not installed; running smoke tests inline.", file=sys.stderr)
        # Minimal smoke: just make sure each public function emits a line
        run_id = emit_ai_prompt(
            case_id="9998",
            actor="ai-summary-worker",
            model="foundation-sec-8b-instruct:q8_0",
            template="summary.v1",
            prompt_text="hello",
        )
        emit_ai_response(
            case_id="9998",
            actor="ai-summary-worker",
            run_id=run_id,
            response_text="OK",
            output_tokens=1,
            duration_ms=42,
        )
        print(f"\nsmoke OK; run_id={run_id}", file=sys.stderr)
        sys.exit(0)
    sys.exit(pytest.main([__file__, "-v"]))
