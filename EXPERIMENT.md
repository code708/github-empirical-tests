# Dispatch Timing Experiment

## Problem Statement

GitHub doesn't guarantee instant workflow dispatch — there can be a delay between the trigger event (e.g. push) and the workflow run appearing via the API.

We want to empirically find out what the min and max as well as the average delay is.

Then we want to hypothesize about the factors that influence the delay and design experiments to verify those hypotheses. For example, does the delay depend on the size of the push? Does it depend on the number of concurrent workflow runs in the repository?

## Measurement Approach

### Timestamps & Primary Metric

Both timestamps come from GitHub's server clock — **zero clock skew**.

| Timestamp | Source | Description |
|---|---|---|
| T_pushed | GitHub Events API | `created_at` of the `PushEvent` matching the commit SHA |
| T_dispatched | GitHub Actions API | `created_at` of the workflow run object |

**Primary metric:** `dispatch_delay_ms = T_dispatched - T_pushed`

Since both timestamps originate from GitHub's servers, the measurement is free of local/server clock skew.

### Per-Trial Algorithm

1. Create commit based on current condition's amount and size
2. `git push origin HEAD` (on the run branch)
3. Poll two APIs in parallel until both resolve (or timeout):
   - **Events API**: `GET /repos/{owner}/{repo}/events` → find `PushEvent` matching commit SHA → extract `T_pushed` (`created_at`)
   - **Actions API**: `GET /repos/{owner}/{repo}/actions/runs?head_sha={SHA}` → find workflow run → extract `T_dispatched` (`created_at`)
4. Compute dispatch delay, append row to CSV
5. Sleep inter-trial delay before next trial

### Rate Limit Safety

1s poll interval → max 120 requests/trial → ~3,600 for 30 trials, well within 5,000/hr limit. Script checks `X-RateLimit-Remaining`.

## Conditions & Hypotheses

A single run (`./conduct-experiment.sh -n N`) executes all conditions sequentially with N trials each. The run branch is `workflow/dispatch-timing/run-N=<N>`.

### Factor Definitions

- **amount**: Number of files changed per commit
- **size**: File content size — `small` (~100B), `medium` (~10KB), `large` (~100KB)
- **delay**: Inter-trial sleep in seconds
- **concurrent**: Number of concurrent noop workflow runs triggered before the measured push

### Single-Factor Conditions

| # | Condition | amount | size | delay | concurrent | Hypothesis |
|---|-----------|--------|------|-------|------------|------------|
| 1 | Baseline | 1 | small | 5s | 0 | Reference distribution |
| 2 | Medium files | 1 | medium | 5s | 0 | Minimal effect — GitHub decouples webhooks from object storage |
| 3 | Large files | 1 | large | 5s | 0 | Same as above |
| 4 | 5 files | 5 | small | 5s | 0 | More files per commit shouldn't affect dispatch |
| 5 | 10 files | 10 | small | 5s | 0 | Same as above |
| 6 | 50 files | 50 | small | 5s | 0 | Same as above |
| 7 | 5 concurrent | 1 | small | 5s | 5 | Per-repo queuing may delay dispatch |
| 8 | 10 concurrent | 1 | small | 5s | 10 | Same as above |
| 9 | Fast push (1s) | 1 | small | 1s | 0 | Rapid pushes may queue, increasing delay |
| 10 | Rapid push (0s) | 1 | small | 0s | 0 | Same as above |

### Multi-Factorial Conditions

| # | Condition | amount | size | delay | concurrent | Hypothesis |
|---|-----------|--------|------|-------|------------|------------|
| 11 | medium×5 | 5 | medium | 10s | 0 | Combined size+amount effect |
| 12 | medium×10 | 10 | medium | 10s | 0 | Same as above |
| 13 | medium×50 | 50 | medium | 10s | 0 | Same as above |
| 14 | large×5 | 5 | large | 10s | 0 | Same as above |
| 15 | large×10 | 10 | large | 10s | 0 | Same as above |
| 16 | large×50 | 50 | large | 10s | 0 | Same as above |
| 17 | medium×10+5c | 10 | medium | 10s | 5 | Size+amount+load interaction |
| 18 | medium×10+10c | 10 | medium | 10s | 10 | Same as above |
| 19 | medium×50+5c | 50 | medium | 10s | 5 | Same as above |
| 20 | medium×50+10c | 50 | medium | 10s | 10 | Same as above |
| 21 | medium×10+1s | 10 | medium | 1s | 0 | Size+amount+frequency interaction |
| 22 | medium×10+0s | 10 | medium | 0s | 0 | Same as above |
| 23 | medium×50+1s | 50 | medium | 1s | 0 | Same as above |
| 24 | medium×50+0s | 50 | medium | 0s | 0 | Same as above |

**Total trials per run:** 24 conditions × N. With N=10: 240 trials, ~50 min runtime.

### Statistical Approach

- Per condition: min, max, mean, median, p95, std dev, CV
- Cross-condition: Welch's t-test, Mann-Whitney U, Cohen's d
- Outliers (>3σ) flagged but not removed

## Run Isolation & Branch Lifecycle

- Each run executes on a dedicated branch: `workflow/dispatch-timing/run-N=<N>`
- At startup the script rebases the run branch onto the latest `workflow/dispatch-timing/main`
- If the branch already exists, it is reset to `workflow/dispatch-timing/main` and force-pushed
- After a run completes, results (CSV + analysis) are committed to `workflow/dispatch-timing/main`
- The run branch is a transient workspace; `main` is the source of truth for results

## CSV Schema

```
condition,trial,commit_sha,amount,size,delay,concurrent,pushed_at_iso,pushed_at_epoch_ms,dispatched_at_iso,dispatched_at_epoch_ms,dispatch_delay_ms,run_id,run_status,timeout
```

## Prerequisites

### Local Prerequisites

1. **Install `gh` CLI** — `brew install gh` (macOS) or see https://cli.github.com/
2. **Authenticate `gh`** — `gh auth login` with a token or browser flow
3. **Verify token scopes** — `gh auth status` must show:
   - `actions:read` (to query workflow runs)
   - `contents:write` (to push commits)
   - **Note:** The classic `repo` scope is a superset that includes both. If your token shows `repo`, you're covered.
   - If using a fine-grained PAT: repository access to `github-empirical-tests`, permissions: Actions (read), Contents (read+write)
4. **Install `jq`** — `brew install jq` (macOS) — used for JSON parsing in the script
5. **Install `python3`** — required for epoch-ms timestamps (pre-installed on macOS)
6. **Clone and checkout** — `git clone` the repo, `git checkout workflow/dispatch-timing/main`

### GitHub Repository Settings

1. **GitHub Actions must be enabled** — Settings → Actions → General → "Allow all actions and reusable workflows"
2. **Branch protection** — Ensure `workflow/dispatch-timing/**` branches allow direct pushes (configured per CONTRIBUTING.md)
3. **Workflow files must exist on the branch** — The noop and load workflows must be committed and pushed to `workflow/dispatch-timing/main` before running the experiment

### Verification Checklist

```sh
gh auth status                                              # Confirm auth + scopes
gh api repos/{owner}/{repo}/actions/workflows               # Confirm Actions API access
jq --version                                                # Confirm jq installed
python3 -c "import time; print(int(time.time() * 1000))"   # Confirm python3
git branch --show-current                                   # Should be workflow/dispatch-timing/main
```

## Key Risks

- Workflow YAML must exist on the pushed branch (not just `main`) — satisfied by our design
- Rapid pushes may hit GitHub API rate limits — script checks `X-RateLimit-Remaining` and handles 403/429 gracefully
