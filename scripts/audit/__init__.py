"""Unified audit-schema emitters for CYPFER DFIR components.

Modules here provide library-style helpers for emitting `AUDIT`-prefixed
JSON lines to stdout, picked up by Promtail's docker service discovery
and labelled per the unified schema (source / class / case / actor /
action / verdict — see promtail/promtail-config.yaml).

Modules:
    cypfer_ai_audit  — ai_prompt + ai_response events for LLM workers
"""
