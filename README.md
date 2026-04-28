# openrelik-pipeline

### Intro
Note: This version of the repository is designed to work with some private repositories that are specific to Cypfer.
Cloned from: https://github.com/Digital-Defense-Institute/openrelik-pipeline

This repository deploys an all-in-one DFIR platform — Timesketch, OpenRelik, Velociraptor, and a Flask glue layer — via Docker Compose. Forensic artefacts (Velociraptor KAPE-format triage zips, EVTX, etc.) POST to a single endpoint, which triggers an OpenRelik workflow that fans out across every analyser worker in parallel and uploads each tool's output to Timesketch as a separately named timeline in the same case sketch.

The recommended entry point is the catchall:

```
POST /api/triage/timesketch
```

…which extracts the upload, then in parallel runs Hayabusa CSV timeline + Chainsaw (Sigma hunt + built-in rules + SRUM) + Plaso log2timeline against whatever's inside, and pipes each output to Timesketch.

Per-tool legacy endpoints (`/api/plaso/timesketch`, `/api/hayabusa/timesketch`) are still present for compatibility but should be considered deprecated for new flows — the catchall is a strict superset.

### Notes

### Known Bugs
* [Timesketch postgres race condition](https://github.com/google/timesketch/issues/3263)

------------------------------

### Step 1 - Install Docker
Follow the official installation instructions to [install Docker Engine](https://docs.docker.com/engine/install/).

### Step 2 - Clone the project and add a config.env file with details
### The detailed file will be provided to you if you are allowed access
```bash
sudo -i
git clone https://github.com/CYPFER-Inc/openrelik-pipeline.git /opt/openrelik-pipeline
```
Copy the config.env file into the /opt/openrelik-pipeline directory

Change the `ENVIRONMENT` to dev (default)

Change `IP_ADDRESS` to your public or IPv4 address if deploying on a cloud server, a VM (the IP of the VM), or WSL (the IP of WSL).

Change the `Credentials` section for passwords

Optionally change the `VR_CONFIG_IMAGE` to point at a feature branch (defaults to :latest)

### Step 3 - Run the install script to deploy Timesketch, OpenRelik, Velociraptor, and the OpenRelik Pipeline
Depending on your connection, this can take 5-10 minutes.
```bash
chmod +x /opt/openrelik-pipeline/install.sh
/opt/openrelik-pipeline/install.sh
```

> [!NOTE]
> Your OpenRelik, Velociraptor, Timesketch usernames are `admin`, and the passwords are what you set above.

### Step 4 - Verify deployment
Verify that all containers are up and running.
```bash
docker ps -a
```

Access the web UIs:
* OpenRelik - http://0.0.0.0:8711
* Velociraptor - https://0.0.0.0:8889
* Timesketch - http://0.0.0.0

Access the pipeline:
* OpenRelik Pipeline - http://0.0.0.0:5000

Again, if deploying elsewhere, or on a VM, or with WSL, use the IP you used for `$IP_ADDRESS`.

------------------------------

## The catchall endpoint: `/api/triage/timesketch`

One POST → one OpenRelik workflow → one fan-out → one Timesketch sketch with one timeline per analyser.

### What it does

```
POST /api/triage/timesketch  (multipart: file=<your.zip>)
```

Builds and runs this workflow against the uploaded archive:

```
extract_archive
  ├── hayabusa csv_timeline           → timesketch upload  (timeline: <name> - Hayabusa)
  ├── chainsaw hunt_evtx              → timesketch upload  (timeline: <name> - Chainsaw Sigma)
  ├── chainsaw builtin_only           → timesketch upload  (timeline: <name> - Chainsaw Built-in)
  ├── chainsaw analyse_srum           → timesketch upload  (timeline: <name> - Chainsaw SRUM)
  └── plaso log2timeline              → timesketch upload  (timeline: <name> - Plaso)
```

Each worker's `compatible_input_types` filter decides whether to process the extracted files or no-op, so the same endpoint handles any triage zip regardless of contents. No per-worker hunts in Velociraptor — one server-event artefact POSTs and the rest is automatic.

### case_id (case-folder routing)

The pipeline resolves `case_id` in this preference order. The first non-empty value wins:

1. **Form field** — `curl -F "case_id=Case-2079" ...`
2. **Query string** — `?case_id=Case-2079`
3. **`CASE_ID` env var on the pipeline container** — set per-deployment by `install.sh` from `/etc/vote-case.env`
4. **None of the above** — falls back to a fresh root folder per zip (legacy behaviour)

When a `case_id` is resolved:

* If a top-level folder named `Case-NNNN` already exists, it's reused
* Otherwise it's created and shared with the built-in `Everyone` group as `Viewer` (admin keeps `Owner`)
* The triage workflow lands inside that folder, named `<filename> Triage Workflow Folder`

The `CASE_ID` env-var path is the right answer for our per-case deployments (each OpenRelik instance lives at `<case-id>-or.dev.cypfer.io` and serves exactly one case). VR clients don't need labels — the pipeline knows its own case from its deployment.

### Examples

```bash
# Per-case auto-routed (case_id derived from CASE_ID env on the host)
curl -X POST http://$HOST:5000/api/triage/timesketch \
  -F "file=@/path/to/triage.zip"

# Explicit case_id via form field (overrides the env var)
curl -X POST http://$HOST:5000/api/triage/timesketch \
  -F "file=@/path/to/triage.zip" \
  -F "case_id=Case-2079"

# Explicit case_id via query string (the path Velociraptor's VQL http_client uses)
curl -X POST "http://$HOST:5000/api/triage/timesketch?case_id=Case-2079" \
  -F "file=@/path/to/triage.zip"
```

### Workers fanned out (and what they accept)

| Worker | Filter | Notes |
|---|---|---|
| `openrelik-worker-extraction` | `*.zip`, `*.tar`, `*.tar.gz`, etc. | Always runs first; downstream tasks read its output |
| `openrelik-worker-hayabusa` | `*.evtx` | Sigma + built-in EVTX detection (fast Rust-based) |
| `openrelik-worker-chainsaw` (`hunt_evtx`) | `*.evtx` | SigmaHQ rules + Chainsaw built-ins; second-opinion to Hayabusa |
| `openrelik-worker-chainsaw` (`builtin_only`) | `*.evtx` | Chainsaw built-in rules only — fast high-confidence pass (AV alerts, log clearing) |
| `openrelik-worker-chainsaw` (`analyse_srum`) | `SRUDB.dat` + `SOFTWARE` (both required) | SRUM database parsing |
| `openrelik-worker-plaso` | many — anything Plaso parses | Catch-all super-timeline |
| `openrelik-worker-timesketch` | `*.timesketch.jsonl`, Plaso `.plaso` | Sink — uploads each upstream's output as a named timeline |

### Legacy single-tool endpoints

Still present, still functional, but the catchall produces a strict superset of their output — prefer the catchall for new flows.

```bash
curl -X POST -F "file=@/path/to/Security.evtx" http://$HOST:5000/api/hayabusa/timesketch
curl -X POST -F "file=@/path/to/triage.zip"   http://$HOST:5000/api/plaso/timesketch
```

------------------------------

## Velociraptor auto-trigger

Server-event artefacts watch for matching client flow completions and POST the resulting zip to the pipeline. For per-case deployments using the catchall, the canonical artefact lives in [openrelik-vr-config](https://github.com/CYPFER-Inc/openrelik-vr-config) at `config/server_artifacts/Custom.Refinery.PC.L2.Server.OpenRelik.yaml` — auto-imported on install. Reference copies of the older per-tool artefacts are in this repo under [`./velociraptor`](./velociraptor) for historical reference.

You can add VR artefacts to a server in two ways:
* In the `View Artifacts` section, click the `Add an Artifact` button and manually paste each one
* Via the Artifact Exchange — click `Server Artifacts` → `New Collection` → `Server.Import.ArtifactExchange` and point it at the artefact zip

By default these artefacts run when their watched artefact completes on an endpoint, zip up the collection, and POST it through the pipeline.

**Adding to the server monitoring table:**
1. Navigate to `Server Events` ![alt text](screenshots/server_events_step-0.png)
2. Click `Update server monitoring table` ![alt text](screenshots/server_events_step-1.png)
3. Choose one or more triage artifacts to run in the background and click Launch ![alt text](screenshots/server_events_step-2.png)
4. The newly installed monitoring artifacts will soon show up in the `Select artifact` dropdown with logs ![alt text](screenshots/server_events_step-3.png)

### Importing Triage Artifacts

The main Velociraptor package no longer includes the necessary triage artifacts by default.

You can download the `Windows.Triage.Targets` artifact from [here](https://triage.velocidex.com/docs/windows.triage.targets/), or simply use the built in `Server.Import.Extras` artifact to automatically download and import the latest version.

**Steps:**

1. Click `Server Artifacts` in the side menu ![alt text](screenshots/server.import.extras_step-0.png)
2. Click `New Collection` ![alt text](screenshots/server.import.extras_step-1.png)
3. Find the `Server.Import.Extras` artifact ![alt text](screenshots/server.import.extras_step-2.png)
4. Leave the default options to import everything, or remove others if you only wish to import the triage artifacts ![alt text](screenshots/server.import.extras_step-3.png)
5. Verify the `Windows.Triage.Targets` artifact is available under `View Artifacts` ![alt text](screenshots/server.import.extras_step-4.png)

------------------------------

## Roadmap

* **HOST_ ingestion pipeline** — the catchall above. Operational.
* **NETWORK_ ingestion pipeline** — separate sibling pipeline for firewall / proxy / cloud-audit / EDR logs. Designed; tracked under the Jira epic *DFIR NETWORK_ ingestion pipeline*. SOF-ELK Logstash configs reused, ECS-shaped output to Timesketch. Tier 1 formats (PAN-OS, FortiGate, Cisco ASA, Linux syslog, Zeek, Suricata, Win DHCP, O365) ship first; Tier 2 (cloud) and Tier 3 (EDR) follow.

> [!IMPORTANT]
> **I strongly recommend deploying OpenRelik and Timesketch with HTTPS** — additional instructions for Timesketch, OpenRelik, and Velociraptor are provided [here](https://github.com/google/timesketch/blob/master/docs/guides/admin/install.md#4-enable-tls-optional), [here](https://github.com/openrelik/openrelik.org/blob/main/content/guides/nginx.md), and [here](https://docs.velociraptor.app/docs/deployment/security/#deployment-signed-by-lets-encrypt). For this proof of concept, we're using HTTP. Modify your configs to reflect HTTPS if you deploy for production use.

## Security Scanning
See [docs/trivy-scanning.md](docs/trivy-scanning.md) for local Trivy scan instructions
