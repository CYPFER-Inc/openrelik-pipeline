# 2026-04 Pre-production openrelik-pipeline Audit

**Status:** read-only audit pass. No fixes land in this PR.
**Scope:** `openrelik-pipeline` repo only — `install.sh`, `app.py`, `Dockerfile`,
`docker-compose.yml`, `scripts/audit/`, `scripts/roster/`, `scripts/vault.py`,
`scripts/mirror-images.sh`, `scripts/update-digests.sh`, `velociraptor/`,
`config.env.example`, `.github/workflows/`. The three configure repos
(`openrelik-or-config`, `openrelik-ts-config`, `openrelik-vr-config`) are
audited separately under `docs/audit/2026-04-{or,ts,vr}-config-audit.md` in
their respective repos. MicroCloud / nginx / Cloudflare / Authentik / LGTM
are infrastructure dependencies — covered by the MC audit, referenced here
only where they intersect with this repo.
**Base:** `origin/dev` at `460ffa8` (PR #75 merged — fix/llm-source-case-env).
**Worktree:** `openrelik-pipeline-audit-doc` on `feature/audit-doc-2026-04`.
**Live inspection targets:** none. Code-only audit. case-1336 is the only
running pre-Phase-4 case and is read-only per memory; cases 2073 / 2075 used
to validate fresh-install state are deleted.
**Production target:** the install pattern that lands on a fresh
greenfield case LXC — findings framed as "what install.sh + app.py should do
differently before the next per-case bring-up."

---

## TL;DR

The repo is the spine of the per-case stack and has absorbed most of the
hardening in the last sprint — silent-corruption bugs from the original
idempotency pass are closed (#38 OR API key, #47 Plaso restart no-op, #50
TS-worker injection, #54 VR `tee -a`), per-user sketch ACLs are reconciled
(#48), folder sharing is correct (#49), and digest-pinned image pre-pull
landed (#68). What hasn't been hardened is the **pipeline runtime itself**:
`app.py` runs Flask routes that accept multipart file uploads with no
authentication, no input sanitisation, and as root inside the container.

Three findings rise above the rest:

- **Blocker chain — pipeline runtime is unauthenticated, path-traversable,
  and root.** P-08 (no auth on `/api/*`), P-09 (`os.path.join("/tmp",
  request.files["file"].filename)` with no `secure_filename()`), and P-10
  (no `USER` directive in the Dockerfile) form a single chain. Each is
  Important alone; the chain is Blocker-grade because any single OVN ACL
  miss in microcloud (X-01 in the cross-repo audit) turns it into per-case
  RCE plus the ability to drop poisoned files into the shared
  `/opt/openrelik/data` volume that workers process as evidence. Each item
  can be fixed independently — fixing any one breaks the chain. P-09
  (`secure_filename()`) is the smallest change.
- **Important — `install.sh` is 2066 lines with zero test coverage.** Four
  silent-corruption bugs in this audit window (#38, #47, #50, #54) all came
  from this style. PR #68 closed the last known instance; the next one
  will not be caught until manual case validation. X-08 is the cross-cutting
  driver.
- **Important — supply-chain visibility is partial.** `scan-images.yml` runs
  weekly Trivy with `FAIL_ON_HIGH=true` (good) but `UPLOAD_SARIF=false`
  (results don't surface in the GitHub Security tab). MEDIUM CVEs accumulate
  silently (X-06).

The other ~10 findings are pre-Phase-4 case-1336 residue (P-01, P-03), known
deliberate decisions kept as findings for completeness (P-04 secret rotation),
or cosmetic.

---

## 1. Inventory — what was checked

### 1.1 Repo files walked end-to-end

- Root: `README.md`, `Dockerfile`, `docker-compose.yml`, `requirements.txt`,
  `app.py`, `config.env.example`.
- `install.sh` (2066 lines) — orchestration spine, walked end-to-end with
  attention to compose surgery, sed substitution, DB patching, and the
  per-service bring-up phases.
- `scripts/`:
  - `audit/__init__.py`, `audit/cypfer_ai_audit.py`, `audit/test_cypfer_ai_audit.py`
    (the only test file across all four repos in this audit family).
  - `roster/or-apply.sh` (255 lines), `roster/ts-apply.sh` (200 lines),
    `roster/vr-apply.sh` (125 lines) — RBAC reconcilers, load-bearing for
    chain-of-custody.
  - `vault.py` — Azure KV secret retrieval.
  - `mirror-images.sh`, `update-digests.sh`.
  - `azure.cfg.example`.
- `velociraptor/` — five custom server-artifacts that POST to
  `openrelik-pipeline:5000` (`Server.Utils.TriagePlasoOpenRelik.yaml` and
  variants).
- `authentik-sync/authentik-sync.sh` — drift reconciliation.
- `.github/workflows/`: `build-and-push.yml`, `enforce-dev-to-main.yml`,
  `scan-images.yml`, `zip-artifacts.yaml`.

### 1.2 Static security tooling

- `bandit 1.9.4` — full Python tree, severity ≥ Medium.
  - Pipeline: 1 High, 6 Medium, 37 Low. High = `app.run(debug=True)` under
    `__main__` (P-12). Mediums = six `os.path.join("/tmp", ...)` writes
    (P-09).
- Hand-scan: `shell=True`, `verify=False`, `pickle.loads`, `yaml.load`,
  `eval`, `exec`, `os.system`, `os.popen`, hardcoded high-entropy secrets.
  All clean except as noted in §2.
- Attack-surface inventory: every `@app.route(...)`, every listening port in
  `docker-compose.yml`, every `subprocess` / `docker_exec` call site.

### 1.3 Memory consulted

`project_post_phase4b_auth.md`, `project_vote_authentik_token_inline.md`,
`feedback_case_1336_handle_with_care.md`, `project_grant_revoke_roster_applier_gap.md`,
`feedback_pr_target_dev.md`, `feedback_dev_to_main_pr_required.md`,
`reference_ts_or_api_auth.md`, `feedback_loki_self_alert_filter.md`.

### 1.4 Parallel sessions

`git worktree list` showed 6 active pipeline worktrees besides this one
(`feature/llm-ai-user-password-race`, `fix/llm-tsctl-shell-repl-parse`,
`fix/llm-source-case-env`, `fix/llm-cd-and-recreate`,
`fix/llm-phase3-after-tsapply`, plus the network-normalizer install-sh
branch). All AI integration arc — coordinated via memory. No overlap with
audit findings.

### 1.5 Out-of-band reference

`session handoff files/AUDIT_PREPROD.md` is the cross-repo audit-preprod
artefact. This doc is the per-repo, fix-PR-organised version of the pipeline
slice plus the cross-cutting items the pipeline owns.

---

## 2. Findings — ranked by severity

Severities:

- **Blocker** — must be fixed before prod cutover; affects correctness or
  exposes a chain that becomes critical under a single failure of an external
  control.
- **Important** — should be fixed before prod cutover; has compensating
  controls today but the next operator inherits a sharp edge.
- **Cosmetic** — clean-up, not a blocker. Most are pre-Phase-4 residue or
  documented limitations kept for completeness.

### 2.1 Blockers

#### B1. Unauthenticated ingestion + path traversal + root container — chained RCE if X-01 leaks

Three findings form a single chain. Each is Important alone; the chain is
Blocker-grade.

**B1.a — `/api/*` ingestion endpoints have no authentication.**
[app.py:1490](../../app.py#L1490), 1535, 1569, 1663, 1745, 1791. Six
`@app.route(...)` POST endpoints accept multipart file uploads. No
`before_request`, no decorator-based auth, no API-key check, no source-IP
allowlist. The only `API_KEY` ([app.py:20](../../app.py#L20)) is for
*outgoing* calls to OpenRelik.

Trust model today: only VR server-artifacts call these — and they do, over
the docker-compose internal network as `openrelik-pipeline:5000`. The five
VR server-artifact YAMLs in
[velociraptor/Server.Utils.Triage*.yaml](../../velociraptor/) confirm the
intended caller path.

But [docker-compose.yml:14](../../docker-compose.yml#L14) binds
`"0.0.0.0:5000:5000"` — exposed on every LXC interface. install.sh prints
`Pipeline: http://${IP_ADDRESS}:5000` to the operator. Anything reaching
the LXC IP on :5000 is accepted.

**B1.b — Path traversal in upload routes.**
[app.py:1501, 1546, 1628, 1713, 1764, 1802](../../app.py#L1501).

```python
file = request.files["file"]
filename = file.filename
file_path = os.path.join("/tmp", filename)
file.save(file_path)
```

In Python, `os.path.join("/tmp", "/etc/cron.d/x")` returns `"/etc/cron.d/x"` —
the absolute right-hand path absorbs the left. `"../app/app.py"` is also
walkable. There is no `werkzeug.utils.secure_filename()` anywhere in the
file. Bandit flagged the same locations as B108
(`hardcoded_tmp_directory`); the real issue is the unsanitised filename.

**B1.c — Pipeline container runs as root.**
[Dockerfile](../../Dockerfile) goes `FROM python:3.12-slim` and never
demotes. Gunicorn inherits root. No `USER` directive anywhere.

**Effect of the chain.** An attacker reaching `:5000` (B1.a) writes a
controllable container path (B1.b) as root (B1.c), hitting `/app/app.py` or
`/usr/local/bin/python3.12`. With `restart: always`, a poisoned binary
survives a crash; only `docker compose pull` clears it. The pipeline
container does **not** mount `/var/run/docker.sock` (only configures do —
P-02), so this isn't a host escape, but it is per-case RCE plus the ability
to drop poisoned files into the shared `/opt/openrelik/data` volume that OR
workers process as evidence.

**Compensating control today.** The chain is gated by **X-01** in the MC
audit (OVN ACLs keep `:5000` unreachable from outside the case LXC).
Severity for the chain is currently 🟠; promote to 🔴 the moment X-01
leaks. Defense-in-depth says fix here regardless.

**Fix shape.** Each item can be fixed independently — fixing any one
breaks the chain. Smallest first:

- **B1.b (P-09).** One import + one call per route:
  `from werkzeug.utils import secure_filename` then
  `file_path = os.path.join("/tmp", secure_filename(filename))`. Better:
  per-request `tempfile.mkdtemp()` so concurrent requests don't collide.
  ~10 lines across six routes.
- **B1.c (P-10).** One line in the Dockerfile:
  `RUN useradd -r -u 1000 cypfer && chown -R cypfer /app` then
  `USER cypfer` before the `CMD`. Verify gunicorn still binds :5000 (it
  will — non-privileged port).
- **B1.a (P-08).** Auth guard sourced from Azure KV at install time. Token
  pulled by `vault.py` into `config.env`, materialised into
  `compose.yml` via the same sed pattern as `OPENRELIK_API_KEY`, checked
  by a Flask `before_request` decorator. The five VR server-artifacts need
  the token added to their POST headers — single template change in
  `velociraptor/*.yaml`.

R1 / R2 / R3 in §4 sequence these.

### 2.2 Important

#### I1. Pre-Phase-4 case-1336 has placeholder secrets in compose

[install.sh] pre-`#38` template had `TIMESKETCH_PASSWORD=${TIMESKETCH_PASSWORD}`
which evaporated when `config.env` was deleted post-install. Fixed for new
installs by sed-substituting the literal at install time. Cases installed
before #38 (case-1336) still have placeholder strings in their compose
files; surviving restarts depends on the env still being live in the shell.

**Effect.** A clean restart of case-1336's stack with the operator no longer
holding `TIMESKETCH_PASSWORD` in their shell env strips Timesketch's local
auth — `admin` can't log in, and `LOCAL_AUTH_ALLOWED_USERS = ['admin']` means
no fallback. Workflows from VR → pipeline → OR also break (similar pattern
on `OPENRELIK_API_KEY`).

**Fix shape.** Either (a) rotate case-1336 secrets and re-materialise them
into compose, or (b) document acceptance and live with it until case-1336
is closed. Per memory `feedback_case_1336_handle_with_care.md` any mutation
needs explicit per-session approval, so this is a decision item, not an
auto-fix. Folded into R4.

#### I2. Configure containers run with `/var/run/docker.sock` and `/opt/openrelik` mounted

Necessary for compose surgery (worker injection, OIDC config patching, DB
patching) but a privilege-escalation surface — a compromised configure
image gets full host docker control. Mitigated by short-lived
`docker run --rm` lifetime (seconds-to-minutes), but the trust requirement
for the four GHCR images
(`ghcr.io/cypfer-inc/openrelik-{pipeline,or-config,ts-config,vr-config}`)
is real.

**Fix shape.** Two layers of defense:

1. **Sigstore signing on the four CYPFER images.** Verify on pull in
   install.sh. Closes the supply-chain compromise surface for our own
   builds.
2. **Document the trust requirement** in README so the next operator
   understands why we can't just swap GHCR for a public registry.

Tied to X-02 (image supply chain). R10 in §4.

#### I3. OpenRelik API key empty on case-1336

Pre-`#38`/`#47` install captured an empty value; restarts since preserve it.
Pipeline container boots fine but VR → pipeline → OR auto-handoff fails
silently. UI workflows from the OR side are unaffected. Live patch ready,
shelved per Stu.

**Fix shape.** 30-min patch when picked up: rotate `OPENRELIK_API_KEY` in
KV, sed-replace in case-1336's compose, `docker compose up -d
openrelik-pipeline`. Same access-restriction as I1 — needs explicit go-ahead
per session. Folded into R4.

#### I4. install.sh has zero test coverage on a 2066-line surface

Cross-cutting X-08 in the audit-preprod artefact. The four merged
silent-corruption bugs (#38, #47, #50, #54) match the failure mode unit
tests would catch:

- **#38 OR API key empty** — a test that runs the API-key capture function
  with a known stdout/stderr fixture and asserts the captured value
  catches this in milliseconds.
- **#47 Plaso restart no-op** — a test that mocks `docker compose` and
  asserts the right `-f` flag is passed catches this.
- **#50 TS worker injection silent failure** — a test that asserts the
  rendered compose file has `worker-timesketch` in the `services:` block
  catches this.
- **#54 VR `tee -a` accumulator** — a test that runs the compose-rewrite
  function twice and asserts the file is identical after the second run
  catches this.

Compensating control today: manual case-2073 / 2075 validation post-merge.
Doesn't scale, doesn't gate PRs.

**Fix shape.** R12 in §4. Targeted bats tests on install.sh + pytest on
app.py routes. Don't try to test the whole 2066 lines — pick the five
functions that mutate compose / env / DB and snapshot their output.

#### I5. `install.sh` is monolithic (2066 lines)

Mixes orchestration + sed surgery + DB patching + role assignment + service
bring-up + secret materialisation. The silent-corruption bugs in I4 are a
direct symptom — there is no unit of code small enough to reason about in
isolation. PR #68 reduced drift on one of the remaining patterns (digest
pre-pull); the rest haven't been touched.

**Effect.** Future-self productivity tax. New per-case install behaviour
either lands in this file or doesn't land at all. Bug surface scales with
linear file growth.

**Fix shape.** Decompose into testable phases: `lib/secrets.sh`,
`lib/compose.sh`, `lib/services.sh`, with `install.sh` as a thin
orchestrator. Done incrementally — extract the most-bug-prone function
first (compose rewrite), test it, then the next. Multi-PR arc, not a
single PR. R13 in §4.

#### I6. Cwd-dependent docker compose calls

`cd /opt/openrelik-pipeline` earlier in the install flow + relative
`docker-compose.yml` references caused #47 (Plaso restart no-op for an
unknown duration) and #50 (TS-worker injection silently failing). Both
fixed via absolute `-f` paths with validators that abort loudly. Pattern
audit recommended for any other `docker compose` calls in install.sh.

**Fix shape.** `grep -nE 'docker[ -]compose' install.sh | grep -v "\-f /"`
on a quiet hour to catch the remaining relative-path call sites. R14.

#### I7. Trivy SARIF upload disabled — no Security-tab visibility

[.github/workflows/scan-images.yml](../../.github/workflows/scan-images.yml#L48)
sets `UPLOAD_SARIF: "false"` with the comment *"Set to 'true' only if
GitHub Advanced Security is enabled"*. Effect: Trivy CRITICAL/HIGH
findings gate CI (good — `FAIL_ON_HIGH: "true"`) but **don't surface in
the GitHub Security tab** for a maintainer dashboard. Reviewers must read
Actions logs.

**Fix shape.** Two-stage:

1. Confirm whether the repo has GHAS enabled (org admin question).
2. If yes, flip to `"true"`. If no, keep as is and add a workflow step
   that surfaces a markdown summary in the Actions UI so maintainers
   don't have to dig through raw logs.

R7 in §4.

#### I8. MEDIUM CVE accumulation policy is undefined

`scan-images.yml` fails the build on HIGH+CRITICAL, lets MEDIUM through.
No documented review cadence; MEDIUM CVEs accumulate silently across
weekly scans.

**Effect.** Eventually an old-MEDIUM count escalates to a HIGH on rebase
and the build fails out-of-context. Or: a MEDIUM that should have been
patched (e.g. a known-exploit-published CVE that bandit / NVD scored as
MEDIUM) sits in prod.

**Fix shape.** Monthly review cadence: parse Trivy's MEDIUM list, triage,
either patch or document acceptance with an expiry date. R8 in §4.

### 2.3 Cosmetic

#### C1. `OPENRELIK_ADMIN_PASSWORD` and `TIMESKETCH_PASSWORD` are 6-char shared secrets per env

Single shared password per dev/prod environment, sourced from Azure KV at
install time, hardcoded literally into compose post-install. Rotation
requires per-case manual sed + container recreate (we documented this on
1336). No automated rotation.

**Effect.** Low — secrets are network-internal to each case container's
compose stack. The leak surface is install-time only (deleted on success).

**Fix shape.** R15 — secret rotation runbook + per-case rotation script
that does the sed + recreate + verification.

#### C2. Hardcoded `/tmp` paths in app.py (subset of B1.b)

Six `os.path.join("/tmp", filename)` sites. Even after `secure_filename()`
fixes B1.b, `/tmp` is shared with anything else running in the container.
Better: `tempfile.mkdtemp()` per-request, cleaned up on return.

**Fix shape.** Folded into R1 (B1.b fix).

#### C3. `app.run(host="localhost", debug=True)` under `__main__`

[app.py:1828](../../app.py#L1828). Production runs `gunicorn` per the
Dockerfile, so this branch never fires in prod. Bandit's only High finding
(B201 flask_debug_true) — keeps surfacing in scans until removed.

**Fix shape.** Either delete (preferred — gunicorn is the canonical entry)
or guard with `os.getenv("FLASK_DEBUG")`. R16 in §4.

#### C4. `pin_compose_image_digest` only pins 4 of the OR images

server, ui, mediator, worker-plaso. Other workers (extraction, strings,
grep, hayabusa, eztools, evtxecmd, kstrike, dissect, volatility,
yara-scan, capa, bulkextractor, analyzer-config, llm-summary) are
tag-pinned by upstream and not re-pinned to digests.

**Effect.** Low — upstream tags don't move under us in practice, but a
supply-chain compromise of a tag would land. Tier-4 community workers
(see openrelik-or-config audit O-03) have the smallest maintainer
review surface and the largest blast radius.

**Fix shape.** Extend `pin_compose_image_digest` to cover all worker
images. R17 in §4.

#### C5. `config.env.example` and `scan-images.yml IMAGE_MAP` partially overlap

Same digest names referenced in both, kept in sync by hand. Drift risk.

**Fix shape.** Single source-of-truth — `config.env.example` reads as the
canonical map; `scan-images.yml` parses it instead of restating. R18.

---

## 3. Cross-cutting concerns the pipeline owns

These span multiple repos but the canonical home is here.

### 3.1 Image supply chain (X-02)

4 CYPFER + 16 third-party images per case. CYPFER: pipeline + 3
configures. Third-party: 8 official OR + 8 community workers + TS + VR +
nginx + postgres + redis + opensearch + prometheus + promtail. Trivy
weekly CVE scan covers them; **SBOM generation is not in place**.

**Recommended:** Sigstore signing on the four CYPFER images (verify on
pull in install.sh) + SBOM artefacts on every CYPFER build. Decide
policy on the third-party images: trust-on-first-use vs vendored
SBOM cache.

R10 in §4.

### 3.2 Audit log retention (X-04)

90 days in Loki (PR #89, bumped from 7d). For chain-of-custody on a
forensic platform, regulatory expectation may exceed 90d (SOC 2: 1 year
typical).

**Recommended:** Verify with compliance before prod cutover. If retention
needs to grow, the per-class retention design in
`microcloud/docs/audit-unification.md` (audit class indefinite, access /
ops 90d) is the path.

R11 in §4.

### 3.3 Egress allow-list (X-05)

No formal allow-list for case containers. Outbound destinations include
`apt-get update` (Debian + docker repos), GHCR pulls, Authentik OIDC
discovery, `extensions.duckdb.org`, GitHub raw (deploy scripts), the
registry mirror. Wide.

**Recommended:** Allow-list the production destinations explicitly in
microcloud's egress firewall (out-of-scope here, in scope for MC audit).
Document the canonical list in this repo's README so the next operator
knows what's expected.

R19 in §4.

### 3.4 Trivy gate review cadence (X-06)

See I8. MEDIUM CVEs accumulate silently. Recommend monthly review.

### 3.5 Test coverage (X-08)

Across all four repos in the per-case stack: 1 test file (14 cases)
covering ~183 of ~8,000 LOC. The pipeline slice is the highest-risk
untested surface — `install.sh` (2066 LOC) plus `app.py` (1828 LOC) plus
the three roster appliers (580 LOC combined).

**Recommended:** Targeted bats / pytest investment matched to bug
surface, not blanket coverage. Five functions to test first:

1. **install.sh compose-rewrite** — the function that injects
   `worker-timesketch` (#50) and the function that pre-pulls digest-pinned
   images (#68). Snapshot tests: feed a known input compose, byte-compare
   the output.
2. **install.sh OR-API-key capture** — fixture-based test with known
   stdout/stderr (#38).
3. **install.sh Plaso restart** — assert the `-f` flag is the absolute
   path (#47).
4. **install.sh VR compose `tee` rewrite** — run twice, assert idempotent
   (#54).
5. **app.py route handlers** — pytest with `werkzeug.test.Client`,
   assert auth gate (post-B1.a) and `secure_filename()` reject for
   `../etc/passwd`-style payloads (post-B1.b).

R12 in §4.

---

## 4. Production-readiness gaps

Categories where docs / process / automation are missing.

### 4.1 Backup of in-flight case state

Cases are intended to be ephemeral; final evidence ships out via TS
export. **Loss of an active case container = loss of in-flight
investigation.** Out of scope for this repo (Ceph replication owned by
microcloud) but worth flagging at audit level: there is no documented
RPO/RTO for an active case.

R20 in §4.

### 4.2 Pipeline auth-token rotation

Once B1.a (P-08) lands, the pipeline auth token is a new long-lived
secret. Add to the secret-rotation inventory in MC audit §3.3.

### 4.3 Authentication on the operator-facing `Pipeline:` URL

install.sh prints `Pipeline: http://${IP_ADDRESS}:5000` to the operator
on success. Today it's plain HTTP, no auth. Even after B1.a lands, the
operator-facing URL will need the bearer token visible.

**Recommended:** Print the token alongside the URL in install.sh's final
summary block. R21.

---

## 5. Recommended fix PRs (priority order)

Each is scoped to a single session.

### P0 — Blockers

**R1.** `fix(app): secure_filename() + per-request tempdir on /api/* uploads`.
See B1.b (P-09). One import + replacement of six `os.path.join("/tmp", ...)`
sites with `tempfile.mkdtemp()` + `secure_filename()`. Smallest of the
three chain-breakers. **Land first.**

**R2.** `fix(docker): non-root USER in pipeline Dockerfile`. See B1.c
(P-10). One `RUN useradd` + one `USER cypfer`. Verify gunicorn binds
:5000 still works. Single PR.

**R3.** `feat(app): bearer-token auth on /api/* (token from Azure KV)`.
See B1.a (P-08). Largest chain-breaker. Token sourced via `vault.py` at
install time, sed-substituted into compose, checked by Flask
`before_request`. Five VR server-artifacts need the token in their POST
headers — same template change pattern as `OPENRELIK_API_KEY`. Compose
+ install.sh + app.py + 5×velociraptor YAMLs.

### P1 — Important

**R4.** `chore(case-1336): rotate placeholder secrets + empty OR API
key`. See I1, I3. **Requires explicit per-session go-ahead** per memory
`feedback_case_1336_handle_with_care.md`. Decision PR — rotate or
document acceptance.

**R5.** `docs(README): document configure-container trust model`. See
I2. Section in README explaining why `/var/run/docker.sock` mount is
necessary, what the four GHCR images can do, and the supply-chain
boundary.

**R6.** `feat(supply-chain): Sigstore sign the four CYPFER images +
verify on pull in install.sh`. See I2 + X-02. Two-stage rollout — sign
first (cosmetic until verify lands), then verify. Single workflow change
+ install.sh patch.

**R7.** `ci: enable SARIF upload OR add markdown-summary fallback in
scan-images.yml`. See I7. Confirm GHAS status with Stu before flipping.

**R8.** `docs(README): document monthly MEDIUM CVE review cadence`.
See I8. Single section + a `MEDIUM_CVES.md` file format for the monthly
triage notes.

**R9.** `chore(install.sh): audit remaining `docker compose` call sites
for relative-path drift`. See I6. Run the grep, fix any survivors with
absolute `-f` paths + abort-loudly validators.

**R10.** `feat(supply-chain): SBOM generation on every CYPFER image
build`. See X-02. cosign + syft in build-and-push.yml; SBOM uploaded as
release artefact.

**R11.** `decision: confirm 90d Loki retention vs compliance`. See X-04.
Out-of-band conversation; this PR captures the decision in the README.

**R12.** `test: bats + pytest coverage on the five highest-bug-surface
functions`. See I4 + X-08. Five test files, one per the §3.5 list.
Add a `test:` job to `build-and-push.yml`. Don't try for whole-file
coverage.

**R13.** `refactor(install.sh): extract lib/compose.sh from install.sh`.
See I5. First decomposition step — extract the compose-rewrite functions
so R12-1 has a unit-testable target. Multi-PR arc; this is just step 1.

### P2 — Cosmetic

**R14.** `chore(docs): document the `-f /opt/openrelik-pipeline/...`
absolute-path pattern as the standard`. See I6. README addendum.

**R15.** `feat(secrets): per-case rotation script for ADMIN/TS
passwords`. See C1. Sed + recreate + verify, written as a
`scripts/rotate-case-secrets.sh`.

**R16.** `chore(app): remove dead `app.run(debug=True)` block`. See C3.
One-line delete or env-guard.

**R17.** `chore(install.sh): extend `pin_compose_image_digest` to all
workers`. See C4. List expansion, no logic change.

**R18.** `chore(scan-images): parse config.env.example IMAGE_MAP instead
of restating`. See C5. Drift-elimination.

### P3 — Production-readiness gap closures

**R19.** `docs(README): document expected egress destinations`. See X-05.
Pairs with the MC audit's egress allow-list work.

**R20.** `runbook: in-flight case backup + recovery`. See §4.1. New
file `docs/runbooks/case-recovery.md`. Pairs with MC audit's R17
(Backup / DR).

**R21.** `feat(install.sh): print pipeline auth token in final summary
block`. See §4.3. Single line in the install summary, post-R3.

---

## 6. Out of scope for this audit

- **`openrelik-or-config`, `openrelik-ts-config`, `openrelik-vr-config`**.
  Audited separately under `docs/audit/2026-04-{or,ts,vr}-config-audit.md`
  in their respective repos.
- **`openrelik-worker-*`** (chainsaw, llm-summary, network-normalizer,
  and the 13 third-party workers). Worker fleet audit is a separate pass.
- **microcloud / nginx / Cloudflare / Authentik / LGTM**. Covered in
  `microcloud/docs/audit/2026-04-mc-infra-audit.md`. X-01 (OVN ACLs),
  X-03 (DR), and the cross-cutting microcloud findings live there.
- **case-1336 mutation.** Read-only inspection respected throughout.
  Per memory `feedback_case_1336_handle_with_care.md`, any mutation
  (rotate / regenerate / patch) requires explicit per-session approval.
- **vote-cli / vote-webapp.** Out of scope; covered by the microcloud
  audit (B1 there is the consultant→investigator rename).
- **AI integration v1.** In-flight via the AI worker session arc;
  audited as part of the `openrelik-worker-llm-summary` repo when that
  matures.

---

## 7. Methodology notes

- All inspection was read-only. No mutations to live state, no fixes
  applied, no live config files edited.
- Static analysis: `bandit 1.9.4` against the Python tree. Hand-grep for
  patterns bandit doesn't model well (multi-step path-traversal chains,
  YAML loader safety, hardcoded secrets).
- Attack-surface inventory: every `@app.route(...)`, every
  `subprocess.run(...)` / `docker_exec(...)` call site, every
  `volumes:` mount in compose, every listening port, every outbound
  HTTP/gRPC destination.
- Memory was consulted for context but not trusted for current state —
  every memory-derived claim was verified against `origin/dev` HEAD or
  the relevant repo's audit artefact.
- `git worktree list` confirmed parallel sessions; their branches were
  not opened or merged.

---

## 8. What this PR changes

This file only. No code, no config, no live infrastructure changes. Each
item in §5 will land in its own follow-up PR.
