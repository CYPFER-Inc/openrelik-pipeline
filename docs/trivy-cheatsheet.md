# Trivy — Local Scan Cheat Sheet
**Ubuntu · Docker installed · Scanning private GHCR images**

---

## One-time setup — authenticate to GHCR

Run this once. Credentials are saved in `~/.docker/config.json` and persist across reboots.

```bash
echo "YOUR_PAT_TOKEN" | docker login ghcr.io -u YOUR-GITHUB-USERNAME --password-stdin
```

Verify login worked:
```bash
docker pull ghcr.io/cypfer-inc/openrelik-pipeline:latest
```

---

## Pull the image before scanning

Trivy needs the image locally first. Always pull before scanning to ensure you have the latest version.

```bash
docker pull ghcr.io/cypfer-inc/openrelik-pipeline:latest
```

---

## Standard scan — HIGH and CRITICAL only (fixable)

The same settings used in your CI pipeline. Only shows CVEs that have a fix available.

```bash
docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    aquasec/trivy image \
    --severity HIGH,CRITICAL \
    --ignore-unfixed \
    ghcr.io/cypfer-inc/openrelik-pipeline:latest
```

---

## Full scan — all severities including MEDIUM and LOW

Useful for a complete picture. Expect more findings — most will be LOW with no fix available.

```bash
docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    aquasec/trivy image \
    --severity CRITICAL,HIGH,MEDIUM,LOW \
    ghcr.io/cypfer-inc/openrelik-pipeline:latest
```

---

## Scan and save results to a file

Useful for sharing results or keeping a record.

```bash
# Save as plain text table
docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v $(pwd):/output \
    aquasec/trivy image \
    --severity HIGH,CRITICAL \
    --ignore-unfixed \
    --output /output/trivy-results.txt \
    ghcr.io/cypfer-inc/openrelik-pipeline:latest

# Save as JSON (for scripting or importing into other tools)
docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v $(pwd):/output \
    aquasec/trivy image \
    --severity HIGH,CRITICAL \
    --ignore-unfixed \
    --format json \
    --output /output/trivy-results.json \
    ghcr.io/cypfer-inc/openrelik-pipeline:latest
```

Results are saved to your current directory.

---

## Scan a specific digest instead of a tag

Use this when you want to scan an exact build rather than whatever :latest points to.
Get the digest from your GitHub Actions build summary.

```bash
docker pull ghcr.io/cypfer-inc/openrelik-pipeline@sha256:YOUR-DIGEST-HERE

docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    aquasec/trivy image \
    --severity HIGH,CRITICAL \
    --ignore-unfixed \
    ghcr.io/cypfer-inc/openrelik-pipeline@sha256:YOUR-DIGEST-HERE
```

---

## Scan all upstream OpenRelik worker images

Run this to check the upstream images you are digest-pinning for any new CVEs.

```bash
IMAGES=(
    "ghcr.io/openrelik/openrelik-server:latest"
    "ghcr.io/openrelik/openrelik-mediator:latest"
    "ghcr.io/openrelik/openrelik-ui:latest"
    "ghcr.io/openrelik/openrelik-worker-plaso:latest"
    "ghcr.io/openrelik/openrelik-worker-hayabusa:latest"
    "ghcr.io/openrelik/openrelik-worker-timesketch:latest"
    "ghcr.io/openrelik/openrelik-worker-extraction:latest"
    "ghcr.io/openrelik/openrelik-worker-hasher:latest"
    "ghcr.io/openrelik/openrelik-worker-grep:latest"
    "ghcr.io/openrelik/openrelik-worker-strings:latest"
    "redis:7-alpine"
    "postgres:14"
)

for IMAGE in "${IMAGES[@]}"; do
    echo ""
    echo "======================================"
    echo "Scanning: $IMAGE"
    echo "======================================"
    docker pull "$IMAGE" --quiet
    docker run --rm \
        -v /var/run/docker.sock:/var/run/docker.sock \
        aquasec/trivy image \
        --severity HIGH,CRITICAL \
        --ignore-unfixed \
        "$IMAGE"
done
```

---

## Update Trivy's vulnerability database

Trivy downloads the vulnerability database automatically on first run. Force an update if you
have not run a scan recently and want the latest CVE data.

```bash
docker run --rm \
    -v trivy-cache:/root/.cache \
    aquasec/trivy image --download-db-only
```

Then use the cached database in your next scan:

```bash
docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v trivy-cache:/root/.cache \
    aquasec/trivy image \
    --severity HIGH,CRITICAL \
    --ignore-unfixed \
    ghcr.io/cypfer-inc/openrelik-pipeline:latest
```

---

## Understanding the output

```
┌──────────┬───────────────┬──────────┬────────┬───────────────────┬─────────────────┐
│ Library  │ Vulnerability │ Severity │ Status │ Installed Version │  Fixed Version  │
├──────────┼───────────────┼──────────┼────────┼───────────────────┼─────────────────┤
│ libc6    │ CVE-2026-0861 │ HIGH     │ fixed  │ 2.41-12+deb13u1   │ 2.41-12+deb13u2 │
└──────────┴───────────────┴──────────┴────────┴───────────────────┴─────────────────┘
```

| Column | Meaning |
|---|---|
| Library | The package containing the vulnerability |
| Vulnerability | The CVE identifier — search this at nvd.nist.gov for full details |
| Severity | CRITICAL / HIGH / MEDIUM / LOW |
| Status | `fixed` = patch available · `affected` = no fix yet · `will_not_fix` = vendor won't patch |
| Installed Version | What is currently in your image |
| Fixed Version | The version you need to get to — update your base image or add apt-get upgrade |

**Status guide:**
- `fixed` — act on this. Add `apt-get upgrade` to your Dockerfile or update the base image tag
- `affected` / `will_not_fix` — no action possible. Add to `.trivyignore` to suppress if needed

---

## Suppressing known unfixable CVEs with .trivyignore

If a CVE has no fix available and you want to stop it appearing in every scan result,
create a `.trivyignore` file in your current directory:

```bash
# .trivyignore
# Format: one CVE ID per line, with an optional comment
CVE-2023-XXXXX  # no fix available as of 2026-03 — review monthly
CVE-2024-YYYYY  # upstream acknowledged, fix pending
```

Then pass the ignore file to Trivy:

```bash
docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v $(pwd)/.trivyignore:/.trivyignore \
    aquasec/trivy image \
    --ignorefile /.trivyignore \
    --severity HIGH,CRITICAL \
    ghcr.io/cypfer-inc/openrelik-pipeline:latest
```

---

## Troubleshooting

| Error | Fix |
|---|---|
| `Cannot connect to the Docker daemon` | Run `sudo systemctl start docker` then retry |
| `UNAUTHORIZED` or `DENIED` from ghcr.io | Re-run the docker login command with a valid PAT |
| `No such image` | Run `docker pull <image>` first before scanning |
| Scan is very slow | First run downloads the ~90MB vulnerability database — normal, subsequent runs are faster |
| `permission denied` on docker.sock | Run `sudo usermod -aG docker $USER` then `newgrp docker` |
