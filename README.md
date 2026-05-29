# OmniRun worker for Claude Managed Agents

A self-hosted **worker** that runs [Anthropic Claude Managed Agents][cma]
sessions inside [OmniRun][omnirun] Firecracker microVMs on your own hardware.

**Anthropic runs the agent loop, the model, and skills hosting.** This worker
runs only the tool-call side of each session: it polls Anthropic's work queue,
claims a session, and executes that session's tool calls (`bash` / `read` /
`write` / `edit` / `glob` / `grep`) inside a fresh, VM-isolated OmniRun
microVM on your box. Outputs are written to `/mnt/session/outputs` and
(optionally) copied back to the host. The sandbox is destroyed when the session
ends.

This mirrors the public worker repos that other sandbox providers ship for
Managed Agents (e.g. Modal, Daytona): it is a thin, auditable adapter between
Anthropic's worker protocol and OmniRun's sandbox API.

[cma]: https://docs.anthropic.com/
[omnirun]: https://omnirun.io

## How it works

Managed Agents is a **pull / work-queue** model. You run a worker that polls a
queue, claims a session, downloads its skills into `/workspace/skills/<name>/`,
runs the session's tool calls on a local filesystem, and posts results back.

This repo uses the **container-per-session** pattern. A host-side poller
(`claude-worker`) is a thin supervisor around Anthropic's Go `ant` CLI:

```
ant beta:worker poll --on-work ./scripts/spawn.sh
```

For each claimed session, `ant` invokes `spawn.sh`, which boots a fresh microVM,
runs the worker inside it, waits for completion, optionally pulls outputs, and
deletes the sandbox.

```
Anthropic queue ──poll──> claude-worker (host) ──on-work──> spawn.sh
                                                              │
                                                              ├─ POST /sandboxes  (claude-agent template)
                                                              ├─ POST /sandboxes/{id}/commands  (ant beta:worker run, background)
                                                              ├─ poll  /sandboxes/{id}/commands/{pid}
                                                              ├─ (opt) download /mnt/session/outputs
                                                              └─ DELETE /sandboxes/{id}
```

`claude-worker` itself does almost nothing: it validates the org-level env vars
(so misconfiguration fails fast on the host instead of inside a sandbox),
resolves the spawn script, and execs `ant`. Keeping the work-queue protocol in
`ant` + `spawn.sh` means there is no bespoke Go reimplementation of the (beta,
evolving) worker protocol to maintain.

## What's in this repo

| Path | Role |
|------|------|
| `cmd/claude-worker/main.go` | Host-side poller. Thin supervisor around `ant beta:worker poll`. Stdlib only. |
| `scripts/spawn.sh` | Per-session launcher invoked by `ant`. Creates + tears down one microVM per session. |
| `scripts/build-rootfs-claude-agent.sh` | Builds the `claude-agent` rootfs (bash + pinned `ant` CLI; no Node/npm). |
| `scripts/create-snapshot-claude-agent.sh` | Creates the Firecracker golden snapshot (4 vCPU / 8 GB). |
| `scripts/seed-entropy.c` | Tiny static helper baked into the rootfs to unblock the guest CRNG. |
| `systemd/claude-worker.service` | Systemd unit for running the poller as a managed service. |

## Security model (read this first)

- The **org-level environment key** `ANTHROPIC_ENVIRONMENT_KEY` lives on the
  **host only** (in the poller's environment). It is forwarded into each sandbox
  via `envVars` because the worker inside the VM needs it to talk to the queue.
  This is the *environment-scoped* key, not the org API key.
- `ANTHROPIC_API_KEY` (the org API key) is **never** set on the host poller and
  **never** forwarded into a sandbox. Both `cmd/claude-worker` and `spawn.sh`
  hard-refuse to run if `ANTHROPIC_API_KEY` is present in their environment.
- Each sandbox is created with `internet: true` (open egress). Real agents need
  package registries and git, so the worker does not lock egress down by
  default. To restrict it, enable the opt-in SNI egress proxy (see below).

## Honest limitations

These are real constraints today, stated plainly so you can decide whether this
fits your threat model:

- **Egress is open by default.** OmniRun's network controls are: `internet:
  false` (a true L3 air-gap), `internet: true` (full outbound), or an **opt-in
  per-domain SNI proxy**. The worker uses open egress because agents typically
  need package registries and git. To enforce an allowlist, set `sniProxy: true`
  with `allowDomains` in the `spawn.sh` create body — guest TLS/443 is then
  routed through an in-netns SNI-filtering proxy that forwards only matching
  hostnames and drops the rest. It blocks everything not listed (including
  pypi/npm), so enable it only for workloads that don't need them.
- **Memory is not supported.** Anthropic's agent Memory feature is not wired up
  in this worker.
- **No compliance certifications.** This is an open-source adapter. There are no
  SOC 2 / HIPAA / ISO certifications associated with running it, and none are
  claimed.
- **`ant` worker protocol is beta.** The `beta:worker` subcommand and its env
  var contract may change. Pin and test the `ant` version you ship.
- **A few details require on-box confirmation** before a clean end-to-end run —
  see the `TODO(verify-on-box)` notes in `scripts/build-rootfs-claude-agent.sh`
  and `scripts/spawn.sh` (e.g. the `files/list` response shape for output
  download). Note: Anthropic infra (model + skills) uses `api.anthropic.com`
  only — there is no separate skills CDN host to allow-list.

## Prerequisites

- An OmniRun host with Firecracker, LVM (`vg0/thinpool`), the in-VM agent at
  `/opt/omnirun/bin/agent`, and a kernel at `/opt/omnirun/vmlinux`.
- Docker on the build host (for building the rootfs).
- The Anthropic `ant` CLI on the host running the poller.
- An Anthropic account with access to Managed Agents (beta).
- Go 1.26+ to build the poller.

## Quick start

### 1. Create a self-hosted environment + environment key (Anthropic Console)

In the Anthropic Console, create a **self-hosted** Managed Agents environment.
Note its **environment ID** (`env_...`) and generate an **environment key**.
This key is environment-scoped — it is *not* your org API key.

### 2. Build the `claude-agent` template (on the box, as root)

First pin the `ant` CLI version + checksum at the top of
`scripts/build-rootfs-claude-agent.sh`:

```bash
ANT_VERSION="1.10.0"   # bump to the version you want
ANT_SHA256="..."       # from that release's ant_<ver>_checksums.txt
```

To compute the checksum:

```bash
ANT_VERSION=1.10.0
curl -fsSL "https://github.com/anthropics/anthropic-cli/releases/download/v${ANT_VERSION}/ant_${ANT_VERSION}_linux_amd64.tar.gz" -o ant.tgz
sha256sum ant.tgz
```

Then build the rootfs and golden snapshot:

```bash
bash scripts/build-rootfs-claude-agent.sh
bash scripts/create-snapshot-claude-agent.sh
```

This produces the golden LV `/dev/vg0/golden-claude-agent-snap` and snapshot
files in `/opt/omnirun/snapshots/claude-agent/`. The `claude-agent` template
must be registered in your OmniRun deployment so the API accepts
`templateID: "claude-agent"`.

### 3. Configure the poller's environment

Set these in the poller's environment (e.g. the systemd `EnvironmentFile`, or an
operator shell). **Do not** commit them.

```bash
export ANTHROPIC_ENVIRONMENT_KEY=...        # environment key from step 1 (host-only)
export ANTHROPIC_ENVIRONMENT_ID=env_...     # environment ID from step 1
export OMNIRUN_API="http://127.0.0.1:8080"  # local OmniRun API
export OMNIRUN_API_KEY=...                  # X-API-Key for the local OmniRun API

# Optional:
export OMNIRUN_MAX_CONCURRENT=5             # concurrency cap (default 5)
export OMNIRUN_OUTPUTS_DEST=/var/lib/omnirun/agent-outputs   # copy outputs here

# Must NOT be set — the worker refuses to start if it is:
unset ANTHROPIC_API_KEY
```

`ANTHROPIC_SESSION_ID`, `ANTHROPIC_WORK_ID`, and `ANTHROPIC_BASE_URL` are set
**per session by `ant`** and must not be exported globally.

### 4. Run the worker

```bash
go build -o bin/claude-worker ./cmd/claude-worker/
```

Run it from the repo root (so `scripts/spawn.sh` resolves), with `ant` on PATH:

```bash
./bin/claude-worker
# or specify paths explicitly:
./bin/claude-worker -ant /usr/local/bin/ant -spawn /opt/omnirun/scripts/spawn.sh
```

The poller validates the org env vars, refuses to start if `ANTHROPIC_API_KEY`
is present, then execs `ant beta:worker poll --on-work <spawn.sh>`. Each claimed
session triggers `spawn.sh`, which boots a microVM and runs the session inside
it.

### As a systemd service

Install the binary, scripts, and an env file, then enable the unit:

```bash
install -m 0755 bin/claude-worker /opt/omnirun/claude-worker
install -m 0755 scripts/spawn.sh  /opt/omnirun/scripts/spawn.sh
# Put the env vars from step 3 in /opt/omnirun/configs/claude-worker.env
install -m 0644 systemd/claude-worker.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now claude-worker
```

The unit drains in-flight sessions on `SIGTERM` (`TimeoutStopSec=7200`) and will
not start if `ANTHROPIC_API_KEY` is present in the env file.

## Verifying egress behavior

Because per-domain egress is not yet enforced (see limitations), verify what
your setup actually does before trusting it. Create a `claude-agent` sandbox
manually and probe it:

```bash
SID=$(curl -fsS -X POST "$OMNIRUN_API/sandboxes" \
  -H "X-API-Key: $OMNIRUN_API_KEY" -H "Content-Type: application/json" \
  -d '{"templateID":"claude-agent","internet":true}' \
  | jq -r '.sandboxID')

# ant present + filesystem layout:
curl -fsS -X POST "$OMNIRUN_API/sandboxes/$SID/commands" \
  -H "X-API-Key: $OMNIRUN_API_KEY" -H "Content-Type: application/json" \
  -d '{"command":"ant --version && ls -d /workspace /workspace/skills /mnt/session/outputs"}'

# Reach to a non-listed host — observe whether it is actually blocked:
curl -fsS -X POST "$OMNIRUN_API/sandboxes/$SID/commands" \
  -H "X-API-Key: $OMNIRUN_API_KEY" -H "Content-Type: application/json" \
  -d '{"command":"curl -s --max-time 5 -o /dev/null -w %{http_code} https://example.com ; echo EXIT=$?"}'

curl -fsS -X DELETE "$OMNIRUN_API/sandboxes/$SID" -H "X-API-Key: $OMNIRUN_API_KEY"
```

## License

[AGPL-3.0](./LICENSE). Contributions require a DCO sign-off — see
[CONTRIBUTING.md](./CONTRIBUTING.md).
