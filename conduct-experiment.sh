#!/usr/bin/env bash
set -euo pipefail

# ─── Constants ───────────────────────────────────────────────────────────────

MAIN_BRANCH="workflow/dispatch-timing/main"
POLL_INTERVAL=1        # seconds between API polls
POLL_TIMEOUT=120       # seconds before declaring a trial timed out
INTER_CONDITION_DELAY=10  # seconds between conditions
DEFAULT_SAMPLE_SIZE=10

SMALL_SIZE=100         # bytes
MEDIUM_SIZE=10000      # bytes
LARGE_SIZE=100000      # bytes

# ─── Condition table ─────────────────────────────────────────────────────────
# Format: "name|amount|size|delay|concurrent"

CONDITIONS=(
  "Baseline|1|small|5|0"
  "Medium files|1|medium|5|0"
  "Large files|1|large|5|0"
  "5 files|5|small|5|0"
  "10 files|10|small|5|0"
  "50 files|50|small|5|0"
  "5 concurrent|1|small|5|5"
  "10 concurrent|1|small|5|10"
  "Fast push (1s)|1|small|1|0"
  "Rapid push (0s)|1|small|0|0"
  "medium×5|5|medium|10|0"
  "medium×10|10|medium|10|0"
  "medium×50|50|medium|10|0"
  "large×5|5|large|10|0"
  "large×10|10|large|10|0"
  "large×50|50|large|10|0"
  "medium×10+5c|10|medium|10|5"
  "medium×10+10c|10|medium|10|10"
  "medium×50+5c|50|medium|10|5"
  "medium×50+10c|50|medium|10|10"
  "medium×10+1s|10|medium|1|0"
  "medium×10+0s|10|medium|0|0"
  "medium×50+1s|50|medium|1|0"
  "medium×50+0s|50|medium|0|0"
)

# ─── Parse arguments ─────────────────────────────────────────────────────────

SAMPLE_SIZE="$DEFAULT_SAMPLE_SIZE"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--sample-size)
      SAMPLE_SIZE="$2"
      shift 2
      ;;
    *)
      echo "Usage: $0 [-n N]" >&2
      exit 1
      ;;
  esac
done

if ! [[ "$SAMPLE_SIZE" =~ ^[0-9]+$ ]] || [[ "$SAMPLE_SIZE" -lt 1 ]]; then
  echo "Error: sample size must be a positive integer" >&2
  exit 1
fi

# ─── Derive repo info ───────────────────────────────────────────────────────

REMOTE_URL=$(git remote get-url origin)
if [[ "$REMOTE_URL" =~ github\.com[:/]([^/]+)/([^/.]+) ]]; then
  OWNER="${BASH_REMATCH[1]}"
  REPO="${BASH_REMATCH[2]}"
else
  echo "Error: cannot parse owner/repo from remote URL: $REMOTE_URL" >&2
  exit 1
fi

RUN_BRANCH="workflow/dispatch-timing/run-N=${SAMPLE_SIZE}"
RUNS_DIR="runs"
PAYLOADS_DIR="${RUNS_DIR}/payloads"
CSV_FILE="${RUNS_DIR}/N=${SAMPLE_SIZE}_results.csv"
LOG_FILE="${RUNS_DIR}/N=${SAMPLE_SIZE}_log.txt"

# ─── Helper functions ────────────────────────────────────────────────────────

epoch_ms() {
  python3 -c "import time; print(int(time.time() * 1000))"
}

iso_to_epoch_ms() {
  python3 -c "
from datetime import datetime, timezone
dt = datetime.fromisoformat('$1'.replace('Z', '+00:00'))
print(int(dt.timestamp() * 1000))
"
}

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

generate_content() {
  local size_bytes="$1"
  python3 -c "
import random, string
print(''.join(random.choices(string.ascii_letters + string.digits, k=$size_bytes)))
"
}

size_to_bytes() {
  case "$1" in
    small)  echo "$SMALL_SIZE" ;;
    medium) echo "$MEDIUM_SIZE" ;;
    large)  echo "$LARGE_SIZE" ;;
  esac
}

check_rate_limit() {
  local remaining
  remaining=$(gh api -i /rate_limit 2>/dev/null | grep -i "x-ratelimit-remaining:" | awk '{print $2}' | tr -d '\r')
  if [[ -n "$remaining" ]] && [[ "$remaining" -lt 100 ]]; then
    log "WARNING: Rate limit low — ${remaining} requests remaining"
    echo "WARNING: Rate limit low (${remaining} remaining), sleeping 60s" >&2
    sleep 60
  fi
}

# ─── Preflight checks ───────────────────────────────────────────────────────

preflight() {
  local fail=0

  if ! command -v gh &>/dev/null; then
    echo "Error: gh CLI not found. Install: brew install gh" >&2
    fail=1
  fi

  if ! command -v jq &>/dev/null; then
    echo "Error: jq not found. Install: brew install jq" >&2
    fail=1
  fi

  if ! command -v python3 &>/dev/null; then
    echo "Error: python3 not found" >&2
    fail=1
  fi

  if ! gh auth status &>/dev/null; then
    echo "Error: gh not authenticated. Run: gh auth login" >&2
    fail=1
  fi

  if [[ "$fail" -eq 1 ]]; then
    exit 1
  fi
}

# ─── Branch setup ────────────────────────────────────────────────────────────

setup_run_branch() {
  log "Setting up run branch: $RUN_BRANCH"

  git fetch origin "$MAIN_BRANCH" 2>/dev/null || true

  if git show-ref --verify --quiet "refs/heads/$RUN_BRANCH"; then
    git checkout "$RUN_BRANCH"
    git reset --hard "origin/$MAIN_BRANCH"
  else
    git checkout -b "$RUN_BRANCH" "origin/$MAIN_BRANCH"
  fi

  git push --force origin "$RUN_BRANCH"
  log "Run branch ready: $RUN_BRANCH"
}

# ─── Concurrent load ────────────────────────────────────────────────────────

trigger_concurrent_load() {
  local count="$1"
  log "Triggering $count concurrent load workflows"
  for ((i = 1; i <= count; i++)); do
    gh api -X POST "/repos/$OWNER/$REPO/actions/workflows/dispatch-timing-load.yml/dispatches" \
      -f ref="$RUN_BRANCH" 2>/dev/null || log "WARNING: Failed to trigger load workflow $i"
  done
  # Brief pause to let workflows start
  sleep 2
}

# ─── Core trial logic ───────────────────────────────────────────────────────

create_trial_commit() {
  local amount="$1"
  local size="$2"
  local condition_num="$3"
  local trial_num="$4"
  local size_bytes
  size_bytes=$(size_to_bytes "$size")

  # Create/update files in a trial-specific directory (gitignored payloads)
  local trial_dir="${PAYLOADS_DIR}/c${condition_num}_t${trial_num}"
  mkdir -p "$trial_dir"

  for ((f = 1; f <= amount; f++)); do
    generate_content "$size_bytes" > "${trial_dir}/file_${f}.txt"
  done

  git add -f "$trial_dir"
  git commit -m "trial: condition=$condition_num trial=$trial_num amount=$amount size=$size" --quiet
}

poll_events_api() {
  local sha="$1"
  local deadline="$2"

  while [[ $(epoch_ms) -lt "$deadline" ]]; do
    local response
    response=$(gh api "/repos/$OWNER/$REPO/events" --paginate 2>/dev/null || echo "[]")

    local pushed_at
    pushed_at=$(echo "$response" | jq -r --arg sha "$sha" '
      [.[] | select(.type == "PushEvent" and (.payload.commits // [] | any(.sha == $sha)))]
      | first | .created_at // empty
    ' 2>/dev/null || true)

    if [[ -n "$pushed_at" ]]; then
      echo "$pushed_at"
      return 0
    fi

    sleep "$POLL_INTERVAL"
  done

  return 1
}

poll_actions_api() {
  local sha="$1"
  local deadline="$2"

  while [[ $(epoch_ms) -lt "$deadline" ]]; do
    local response
    response=$(gh api "/repos/$OWNER/$REPO/actions/runs?head_sha=$sha" 2>/dev/null || echo '{"workflow_runs":[]}')

    local run_info
    run_info=$(echo "$response" | jq -r '
      .workflow_runs
      | map(select(.name == "dispatch-timing-noop"))
      | first
      | if . then [.created_at, (.id | tostring), .status] | join("|") else empty end
    ' 2>/dev/null || true)

    if [[ -n "$run_info" ]]; then
      echo "$run_info"
      return 0
    fi

    sleep "$POLL_INTERVAL"
  done

  return 1
}

run_trial() {
  local condition_num="$1"
  local condition_name="$2"
  local trial_num="$3"
  local amount="$4"
  local size="$5"
  local delay="$6"
  local concurrent="$7"

  log "  Trial $trial_num: amount=$amount size=$size delay=${delay}s concurrent=$concurrent"

  # Trigger concurrent load if needed
  if [[ "$concurrent" -gt 0 ]]; then
    trigger_concurrent_load "$concurrent"
  fi

  # Create and push commit
  create_trial_commit "$amount" "$size" "$condition_num" "$trial_num"
  local sha
  sha=$(git rev-parse HEAD)

  git push origin HEAD --quiet 2>/dev/null

  local push_time_ms
  push_time_ms=$(epoch_ms)
  local deadline_ms=$(( push_time_ms + POLL_TIMEOUT * 1000 ))

  # Poll both APIs in parallel using background processes
  local events_file actions_file
  events_file=$(mktemp)
  actions_file=$(mktemp)

  poll_events_api "$sha" "$deadline_ms" > "$events_file" 2>/dev/null &
  local events_pid=$!

  poll_actions_api "$sha" "$deadline_ms" > "$actions_file" 2>/dev/null &
  local actions_pid=$!

  # Wait for both
  local events_ok=0 actions_ok=0
  wait "$events_pid" && events_ok=1 || true
  wait "$actions_pid" && actions_ok=1 || true

  local pushed_at_iso="" dispatched_at_iso="" run_id="" run_status=""
  local pushed_at_epoch_ms="" dispatched_at_epoch_ms="" dispatch_delay_ms=""
  local timed_out="false"

  if [[ "$events_ok" -eq 1 ]]; then
    pushed_at_iso=$(cat "$events_file")
  fi

  if [[ "$actions_ok" -eq 1 ]]; then
    local actions_data
    actions_data=$(cat "$actions_file")
    dispatched_at_iso=$(echo "$actions_data" | cut -d'|' -f1)
    run_id=$(echo "$actions_data" | cut -d'|' -f2)
    run_status=$(echo "$actions_data" | cut -d'|' -f3)
  fi

  rm -f "$events_file" "$actions_file"

  if [[ -n "$pushed_at_iso" ]]; then
    pushed_at_epoch_ms=$(iso_to_epoch_ms "$pushed_at_iso")
  fi

  if [[ -n "$dispatched_at_iso" ]]; then
    dispatched_at_epoch_ms=$(iso_to_epoch_ms "$dispatched_at_iso")
  fi

  if [[ -n "$pushed_at_epoch_ms" ]] && [[ -n "$dispatched_at_epoch_ms" ]]; then
    dispatch_delay_ms=$(( dispatched_at_epoch_ms - pushed_at_epoch_ms ))
  fi

  if [[ "$events_ok" -eq 0 ]] || [[ "$actions_ok" -eq 0 ]]; then
    timed_out="true"
    log "  WARNING: Trial $trial_num timed out (events=$events_ok, actions=$actions_ok)"
  fi

  # Append CSV row
  echo "${condition_num},${trial_num},${sha},${amount},${size},${delay},${concurrent},${pushed_at_iso},${pushed_at_epoch_ms},${dispatched_at_iso},${dispatched_at_epoch_ms},${dispatch_delay_ms},${run_id},${run_status},${timed_out}" >> "$CSV_FILE"

  log "  Trial $trial_num complete: delay=${dispatch_delay_ms}ms timeout=${timed_out}"

  # Inter-trial delay
  if [[ "$delay" -gt 0 ]]; then
    sleep "$delay"
  fi
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
  preflight

  mkdir -p "$RUNS_DIR" "$PAYLOADS_DIR"
  : > "$LOG_FILE"

  local total_trials=$(( ${#CONDITIONS[@]} * SAMPLE_SIZE ))
  echo "Dispatch timing experiment: ${#CONDITIONS[@]} conditions × $SAMPLE_SIZE trials = $total_trials total"

  log "Starting experiment: N=$SAMPLE_SIZE, conditions=${#CONDITIONS[@]}, total_trials=$total_trials"
  log "Repository: $OWNER/$REPO"
  log "Run branch: $RUN_BRANCH"

  setup_run_branch

  # Write CSV header
  echo "condition,trial,commit_sha,amount,size,delay,concurrent,pushed_at_iso,pushed_at_epoch_ms,dispatched_at_iso,dispatched_at_epoch_ms,dispatch_delay_ms,run_id,run_status,timeout" > "$CSV_FILE"

  local condition_num=0
  for cond in "${CONDITIONS[@]}"; do
    condition_num=$((condition_num + 1))

    IFS='|' read -r name amount size delay concurrent <<< "$cond"

    log "Condition $condition_num/$((${#CONDITIONS[@]})): $name (amount=$amount size=$size delay=${delay}s concurrent=$concurrent)"

    check_rate_limit

    for ((trial = 1; trial <= SAMPLE_SIZE; trial++)); do
      run_trial "$condition_num" "$name" "$trial" "$amount" "$size" "$delay" "$concurrent"
    done

    # Pause between conditions
    if [[ "$condition_num" -lt "${#CONDITIONS[@]}" ]]; then
      log "Sleeping ${INTER_CONDITION_DELAY}s between conditions"
      sleep "$INTER_CONDITION_DELAY"
    fi
  done

  log "Experiment complete. Results: $CSV_FILE"

  # Commit results CSV to main branch (log stays on run branch only)
  log "Committing results to $MAIN_BRANCH"
  local csv_abs
  csv_abs=$(realpath "$CSV_FILE")
  git checkout "$MAIN_BRANCH"
  git pull origin "$MAIN_BRANCH" --rebase --quiet 2>/dev/null || true
  mkdir -p "$RUNS_DIR"
  cp "$csv_abs" "$RUNS_DIR/"
  git add "$RUNS_DIR"
  git commit -m "test(exec): Add results for N=$SAMPLE_SIZE run" --quiet || true
  git push origin "$MAIN_BRANCH" --quiet 2>/dev/null || true

  echo "Experiment complete. Results in $CSV_FILE, log in $LOG_FILE"
}

main "$@"
