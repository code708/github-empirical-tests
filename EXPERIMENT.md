# Dispatch Timing Experiment

## Running the Experiment

`./conduct-experiment.sh -n N` runs the full suite of conditions with N trials each.

Results are committed to the run branch and copied to `workflow/dispatch-timing/main`.

### Prerequisites

#### Local Prerequisites

1. **Install `gh` CLI** — `brew install gh` (macOS) or see https://cli.github.com/
2. **Authenticate `gh`** — `gh auth login` with a token or browser flow
3. **Verify token scopes** — `gh auth status` must show:
   - `actions:read` (to query workflow runs)
   - **Note:** The classic `repo` scope is a superset. If your token shows `repo`, you're covered.
   - If using a fine-grained PAT: repository access to `github-empirical-tests`, permissions: Actions (read), Contents (read+write)
4. **Create `gh-auth.sh`** — The script pushes over HTTPS to avoid SSH key prompts (e.g. YubiKey touch) that block unattended execution. Create `gh-auth.sh` in the project root with a `get_token` function that returns your PAT. The same PAT used for `.mcp.json` can be reused. See CONTRIBUTING.md for PAT setup.
   ```sh
   #!/usr/bin/env bash
   get_token() {
     security find-generic-password -a "$USER" -s "YOUR_PAT_NAME" -w
   }
   ```
   The PAT must have `contents:write` scope.
5. **Install `jq`** — `brew install jq` (macOS) — used for JSON parsing in the script
6. **Install `python3`** — required for epoch-ms timestamps (pre-installed on macOS)
7. **Clone and checkout** — `git clone` the repo, `git checkout workflow/dispatch-timing/main`

#### GitHub Repository Settings

1. **GitHub Actions must be enabled** — Settings → Actions → General → "Allow all actions and reusable workflows"
2. **Branch protection** — Ensure `workflow/dispatch-timing/**` branches allow direct pushes (configured per CONTRIBUTING.md)
3. **Workflow files must exist on the branch** — The noop and load workflows must be committed and pushed to `workflow/dispatch-timing/main` before running the experiment

#### Verification Checklist

```sh
gh auth status                                              # Confirm auth + scopes
gh api repos/{owner}/{repo}/actions/workflows               # Confirm Actions API access
source gh-auth.sh && get_token > /dev/null                  # Confirm PAT retrieval
jq --version                                                # Confirm jq installed
python3 -c "import time; print(int(time.time() * 1000))"    # Confirm python3
git branch --show-current                                   # Should be workflow/dispatch-timing/main
```

## Problem Statement

GitHub doesn't guarantee instant workflow dispatch — there can be a delay between the trigger event (e.g. push) and the workflow run appearing via the API.

We want to empirically find out what the min and max as well as the average delay is.

Then we want to hypothesize about the factors that influence the delay and design experiments to verify those hypotheses. For example, does the delay depend on the size of the push? Does it depend on the number of concurrent workflow runs in the repository?

## Measurement Approach

### Timestamps & Primary Metric

Both timestamps come from GitHub's server clock — **zero clock skew**.

| Timestamp    | Source             | Description                                             |
| ------------ | ------------------ | ------------------------------------------------------- |
| T_pushed     | GitHub Events API  | `created_at` of the `PushEvent` matching the commit SHA |
| T_dispatched | GitHub Actions API | `created_at` of the workflow run object                 |

**Primary metric:** `dispatch_delay_ms = T_dispatched - T_pushed`

Since both timestamps originate from GitHub's servers, the measurement is free of local/server clock skew.

### Per-Trial Algorithm

1. Create commit based on current condition's amount and size
2. `git push origin HEAD` (on the run branch)
3. Poll two APIs in parallel until both resolve (or timeout):
   - **Events API**: `GET /repos/{owner}/{repo}/events` → find `PushEvent` matching commit SHA → extract `T_pushed` (`created_at`)
   - **Actions API**: `GET /repos/{owner}/{repo}/actions/runs?head_sha={SHA}` → find workflow run → extract `T_dispatched` (`created_at`)
4. Compute dispatch delay, append row to CSV
5. If sequential (`push_pacing == -1`): wait for noop run to complete. If rapid (`push_pacing >= 0`): sleep `push_pacing` ms (or skip if 0). After the last trial of every condition, wait for the noop run to complete before proceeding.

### Rate Limit Safety

1s poll interval → max 120 requests/trial → ~3,600 for 30 trials, well within 5,000/hr limit. Script checks `X-RateLimit-Remaining`.

## Conditions & Hypotheses

A single run (`./conduct-experiment.sh -n N`) executes all conditions sequentially with N trials each. The run branch is `workflow/dispatch-timing/run-N=<N>`.

### Factor Definitions

- **amount**: Number of files changed per commit
- **size**: File content size — `small` (~100B), `medium` (~10KB), `large` (~100KB)
- **push_pacing**: Controls inter-trial timing — `-1` = sequential (wait for noop run to complete between trials), `≥0` = rapid (sleep this many milliseconds between trials, wait only after the last trial)
- **concurrent**: Number of concurrent load workflow runs triggered before the measured push

#### How Concurrent Load Works

Concurrent conditions test whether GitHub Actions dispatches a push-triggered workflow slower when the runner queue is already busy. Before the trial push, the script fires N `workflow_dispatch` requests against the load workflow. Each load run sleeps for a decreasing duration: `sample_size + count - i + 1` seconds, where `i` is the dispatch index. The first-dispatched workflow sleeps longest, keeping all runners busy throughout. This staggers their completion while ensuring they outlive the trial's push and poll cycle. After a 2-second pause for the load workflows to claim runners, the script pushes the trial commit and measures the noop workflow's dispatch latency as usual.

```
Script                              GitHub Actions Runners
  │                                       (idle)
  │
  │─ POST /dispatches (load 1) ────→  load-1: sleep N+C
  │─ POST /dispatches (load 2) ────→  load-2: sleep N+C-1
  │─ POST /dispatches (load C) ────→  load-C: sleep N+1
  │─ sleep 2  (let them claim runners)
  │                                   C runners now busy sleeping
  │
  │─ git commit (trial payload)
  │─ git push ─────────────────────→  PushEvent received by GitHub
  │                                       │
  │                                       ▼
  │                                  noop workflow run created
  │
  │─ poll Events API ──→ pushed_at (T_pushed)
  │─ poll Actions API ──→ dispatched_at (T_dispatched)
  │
  │─ dispatch_delay = T_dispatched - T_pushed
```

### Single-Factor Conditions

| #   | Condition       | amount | size   | push_pacing | concurrent | Hypothesis                                                     |
| --- | --------------- | ------ | ------ | ----------- | ---------- | -------------------------------------------------------------- |
| 1   | Baseline        | 1      | small  | -1          | 0          | Reference distribution                                         |
| 2   | Medium files    | 1      | medium | -1          | 0          | Minimal effect — GitHub decouples webhooks from object storage |
| 3   | Large files     | 1      | large  | -1          | 0          | Same as above                                                  |
| 4   | 5 files         | 5      | small  | -1          | 0          | More files per commit shouldn't affect dispatch                |
| 5   | 10 files        | 10     | small  | -1          | 0          | Same as above                                                  |
| 6   | 50 files        | 50     | small  | -1          | 0          | Same as above                                                  |
| 7   | 5 concurrent    | 1      | small  | -1          | 5          | Per-repo queuing may delay dispatch                            |
| 8   | 10 concurrent   | 1      | small  | -1          | 10         | Same as above                                                  |
| 9   | Fast push (1s)  | 1      | small  | 1000        | 0          | Rapid pushes may queue, increasing delay                       |
| 10  | Rapid push (0s) | 1      | small  | 0           | 0          | Same as above                                                  |

### Multi-Factorial Conditions

| #   | Condition     | amount | size   | push_pacing | concurrent | Hypothesis                        |
| --- | ------------- | ------ | ------ | ----------- | ---------- | --------------------------------- |
| 11  | medium×5      | 5      | medium | -1          | 0          | Combined size+amount effect       |
| 12  | medium×10     | 10     | medium | -1          | 0          | Same as above                     |
| 13  | medium×50     | 50     | medium | -1          | 0          | Same as above                     |
| 14  | large×5       | 5      | large  | -1          | 0          | Same as above                     |
| 15  | large×10      | 10     | large  | -1          | 0          | Same as above                     |
| 16  | large×50      | 50     | large  | -1          | 0          | Same as above                     |
| 17  | medium×10+1s  | 10     | medium | 1000        | 0          | Size+amount+frequency interaction |
| 18  | medium×10+0s  | 10     | medium | 0           | 0          | Same as above                     |
| 19  | medium×50+1s  | 50     | medium | 1000        | 0          | Same as above                     |
| 20  | medium×50+0s  | 50     | medium | 0           | 0          | Same as above                     |

**Total trials per run:** 20 conditions × N. With N=10: 160 trials. Runtime varies — sequential conditions wait for noop completion (~5–15s each), rapid conditions push back-to-back.

### Statistical Approach

- Per condition: min, max, mean, median, p95, std dev, CV
- Cross-condition: Welch's t-test, Mann-Whitney U, Cohen's d
- Outliers (>3σ) flagged but not removed

## Run Isolation & Branch Lifecycle

- Each run executes on a dedicated branch: `workflow/dispatch-timing/run-N=<N>`
- At startup the script rebases the run branch onto the latest `workflow/dispatch-timing/main`
- If the branch already exists, it is reset to `workflow/dispatch-timing/main` and force-pushed
- After a run completes, all artifacts (CSV, log, payloads) are committed to the run branch
- The results CSV is then copied and committed to `workflow/dispatch-timing/main`
- The run branch is a full record of the run; `workflow/dispatch-timing/main` is the source of truth for results

## CSV Schema

```
condition,trial,commit_sha,amount,size,push_pacing,concurrent,pushed_at_iso,pushed_at_epoch_ms,dispatched_at_iso,dispatched_at_epoch_ms,dispatch_delay_ms,run_id,run_status,timeout
```
