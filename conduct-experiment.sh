#!/usr/bin/env bash
set -euo pipefail

REPO="code708/github-empirical-tests"
BASE="merge-queue/wait-for-post-merge-workflow-to-finish/run"
PREFIX="merge-queue/wait-for-post-merge-workflow-to-finish"
MAIN_BRANCH="${PREFIX}/main"
RUN_ID="merge-queue-wait-for-post-merge-workflow-to-finish-$(date +%Y-%m-%dT%H%M%S)"

log() { printf "[%s] %s\n" "$(date +%H:%M:%S)" "$*" >&2; }

cleanup() {
  log "Cleaning up: closing open PRs"
  for n in 1 2 3 4; do
    gh pr list --repo "${REPO}" --base "${BASE}" --head "${PREFIX}/pr-${n}" --state open --json url --jq '.[].url' \
      | while read -r url; do
        log "  Closing ${url}"
        gh pr close "${url}" --repo "${REPO}" 2>/dev/null || true
      done
  done
}
trap cleanup EXIT

create_pr() {
  local n=$1
  local branch="${PREFIX}/pr-${n}"

  log "Pushing test file to ${branch}"
  gh api "repos/${REPO}/contents/test-pr-${n}.txt" \
    -X PUT \
    -f "message=test: Add test file for PR-${n}" \
    -f "content=$(printf 'Test file for PR-%d\n' "$n" | base64 | tr -d '\n')" \
    -f "branch=${branch}" --silent

  log "Creating pull request for PR-${n}"
  gh pr create --repo "${REPO}" --base "${BASE}" --head "${branch}" \
    --title "Merge Queue - Wait for post-merge workflow to finish PR-${n}" --body "Trivial change to cause a version bump"
}

wait_for_ci() {
  local pr=$1
  log "Waiting for CI on ${pr}"

  while true; do
    STATUS=$(gh pr checks "${pr}" --repo "${REPO}" --json state --jq '.[].state' 2>/dev/null || echo "PENDING")
    case "$STATUS" in
      SUCCESS) break ;;
      FAILURE) log "CI failed on ${pr}"; return 1 ;;
    esac

    sleep 2
  done
  log "CI passed on ${pr}"
}

enqueue() {
  local pr=$1
  log "Enqueuing ${pr}"
  gh pr merge "${pr}" --repo "${REPO}" --auto --rebase
  log "Enqueued ${pr}"
}

wait_for_merge() {
  local pr=$1
  log "Waiting for ${pr} to merge"
  while [ "$(gh pr view "${pr}" --repo "${REPO}" --json state --jq '.state')" != "MERGED" ]; do
    sleep 5
  done
  log "Merged: ${pr}"
}

wait_for_version() {
  local expected=$1
  local timeout=60
  local elapsed=0
  log "Waiting for VERSION to reach ${expected}"
  while [ $elapsed -lt $timeout ]; do
    local actual
    actual=$(gh api "repos/${REPO}/contents/VERSION?ref=${BASE}" \
      --jq '.content' | base64 -d | tr -d '\n')
    if [ "$actual" = "$expected" ]; then
      log "VERSION is ${actual}"
      return 0
    fi
    sleep 3
    elapsed=$((elapsed + 3))
  done
  log "Timeout: VERSION did not reach ${expected} within ${timeout}s"
  return 1
}

get_log() {
  gh api "repos/${REPO}/commits?sha=${BASE}&per_page=10" \
    --jq '.[].commit.message | split("\n")[0]'
}

# ── Reset ──

log "══ Reset ══"

log "Closing open PRs targeting ${BASE}"
gh pr list --repo "${REPO}" --base "${BASE}" --state open --json url --jq '.[].url' \
  | while read -r url; do
    log "Closing ${url}"
    gh pr close "${url}" --repo "${REPO}" 2>/dev/null || true
  done

log "Disabling version-bump workflow"
gh workflow disable version-bump.yml --repo "${REPO}" 2>/dev/null || true

MAIN_SHA=$(gh api "repos/${REPO}/git/ref/heads/${MAIN_BRANCH}" --jq '.object.sha')

log "Resetting branches to ${MAIN_BRANCH}"
for ref in "${BASE}" "${PREFIX}/pr-1" "${PREFIX}/pr-2" "${PREFIX}/pr-3" "${PREFIX}/pr-4"; do
  if gh api "repos/${REPO}/git/ref/heads/${ref}" --silent 2>/dev/null; then
    gh api "repos/${REPO}/git/refs/heads/${ref}" -X PATCH \
      -f "sha=${MAIN_SHA}" -F "force=true" --silent
    log "  Reset ${ref}"
  fi
done

for ref in "${BASE}" "${PREFIX}/pr-1" "${PREFIX}/pr-2" "${PREFIX}/pr-3" "${PREFIX}/pr-4"; do
  if ! gh api "repos/${REPO}/git/ref/heads/${ref}" --silent 2>/dev/null; then
    gh api "repos/${REPO}/git/refs" \
      -f "ref=refs/heads/${ref}" -f "sha=${MAIN_SHA}" --silent
    log "  Created ${ref}"
  fi
done

BUMP_STATE=$(gh workflow view version-bump.yml --repo "${REPO}" --json state --jq '.state' 2>/dev/null || echo "unknown")
if [ "$BUMP_STATE" != "active" ]; then
  log "Enabling version-bump workflow"
  gh workflow enable version-bump.yml --repo "${REPO}"
else
  log "Version-bump workflow already active"
fi

# ── Test 1: Validate mechanism (1 PR) ──

log "══ Test 1: Validate mechanism ══"

TEST1_RESULT="fail"
PR1=$(create_pr 1)
wait_for_ci "$PR1"
enqueue "$PR1"
wait_for_merge "$PR1"
if wait_for_version 1; then
  TEST1_RESULT="pass"
fi

# ── Test 2: Serialization (3 PRs) ──

log "══ Test 2: Serialization (3 PRs) ══"

TEST2_RESULT="fail"
PR2=$(create_pr 2)
PR3=$(create_pr 3)
PR4=$(create_pr 4)

wait_for_ci "$PR2" &
wait_for_ci "$PR3" &
wait_for_ci "$PR4" &
wait

enqueue "$PR2"
enqueue "$PR3"
enqueue "$PR4"

TEST2_V2="fail"
TEST2_V3="fail"
TEST2_V4="fail"

wait_for_merge "$PR2"
if wait_for_version 2; then TEST2_V2="pass"; fi

wait_for_merge "$PR3"
if wait_for_version 3; then TEST2_V3="pass"; fi

wait_for_merge "$PR4"
if wait_for_version 4; then TEST2_V4="pass"; fi

if [ "$TEST2_V2" = "pass" ] && [ "$TEST2_V3" = "pass" ] && [ "$TEST2_V4" = "pass" ]; then
  TEST2_RESULT="pass"
fi

GIT_LOG=$(get_log)

# ── Collect observability signals ──

log "══ Collecting signals ══"

INVALIDATION_OBSERVED=false
CI_RUN_COUNTS=""
MG_BRANCHES=$(gh api "repos/${REPO}/actions/workflows/ci.yml/runs?event=merge_group&per_page=100" \
  --jq '[.workflow_runs[].head_branch]')
for pr_url in "$PR1" "$PR2" "$PR3" "$PR4"; do
  pr_num="${pr_url##*/}"
  COUNT=$(echo "$MG_BRANCHES" | jq "[.[] | select(contains(\"pr-${pr_num}-\"))] | length")
  CI_RUN_COUNTS="${CI_RUN_COUNTS}- PR #${pr_num}: ${COUNT} merge_group CI run(s)\n"
  if [ "$COUNT" -gt 1 ]; then
    INVALIDATION_OBSERVED=true
  fi
  log "PR #${pr_num}: ${COUNT} merge_group CI run(s)"
done

BUMP_RUNS=$(gh api "repos/${REPO}/actions/workflows/version-bump.yml/runs?branch=${BASE}&per_page=4" \
  --jq '.workflow_runs | map({id, conclusion, html_url})')
BUMP_CONCLUSIONS=$(echo "$BUMP_RUNS" | gh api --input - --jq 'map(.conclusion) | join(", ")' 2>/dev/null || \
  echo "$BUMP_RUNS" | python3 -c "import sys,json; print(', '.join(r['conclusion'] or 'null' for r in json.load(sys.stdin)))")
BUMP_ALL_SUCCESS=true
if [ -z "$BUMP_CONCLUSIONS" ] || echo "$BUMP_CONCLUSIONS" | grep -qvE '^(success|skipped)(, (success|skipped))*$'; then
  BUMP_ALL_SUCCESS=false
fi
log "Version-bump conclusions: ${BUMP_CONCLUSIONS}"

if [ "$BUMP_ALL_SUCCESS" = false ]; then
  log "Fetching failed version-bump logs..."
  echo "$BUMP_RUNS" | python3 -c "
import sys, json
for run in json.load(sys.stdin):
    if run['conclusion'] not in ('success', 'skipped'):
        print(run['id'])
" | while read -r run_id; do
    FAILED_JOBS=$(gh api "repos/${REPO}/actions/runs/${run_id}/jobs" \
      --jq '.jobs[] | select(.conclusion != "success") | .id' 2>/dev/null || true)
    for job_id in $FAILED_JOBS; do
      log "── Logs for job ${job_id} ──"
      gh api "repos/${REPO}/actions/jobs/${job_id}/logs" 2>&1 | tail -20 | while IFS= read -r line; do
        log "  ${line}"
      done || true
    done
  done
fi

# ── Verify strict interleaving ──

INTERLEAVED=true
EXPECTED_LOG="chore: Bump version to 4
test: Add test file for PR-4
chore: Bump version to 3
test: Add test file for PR-3
chore: Bump version to 2
test: Add test file for PR-2
chore: Bump version to 1
test: Add test file for PR-1"

ACTUAL_LOG=$(echo "$GIT_LOG" | head -8)
if [ "$ACTUAL_LOG" != "$EXPECTED_LOG" ]; then
  INTERLEAVED=false
  log "History is NOT strictly interleaved"
else
  log "History is strictly interleaved"
fi

# ── Determine verdict ──

if [ "$TEST1_RESULT" != "pass" ] || [ "$TEST2_RESULT" != "pass" ]; then
  VERDICT="Rejected — VERSION did not reach expected value"
elif [ "$INTERLEAVED" = false ]; then
  VERDICT="Rejected — history is not interleaved"
elif [ "$BUMP_ALL_SUCCESS" = false ]; then
  VERDICT="Rejected — version-bump workflow failures"
elif [ "$INVALIDATION_OBSERVED" = true ]; then
  VERDICT="Confirmed — interleaved history with merge queue invalidation observed"
else
  VERDICT="Partially confirmed — interleaved history but no invalidation observed (timing-dependent)"
fi

log "Verdict: ${VERDICT}"

# ── Write results ──

log "══ Writing results ══"

RESULTS="# Run ${RUN_ID}

## Test 1: Validate mechanism

- Result: ${TEST1_RESULT}
- Expected VERSION: 1

## Test 2: Serialization

- Result: ${TEST2_RESULT}
- VERSION after PR-2: ${TEST2_V2}
- VERSION after PR-3: ${TEST2_V3}
- VERSION after PR-4: ${TEST2_V4}

## Git log

\`\`\`text
${GIT_LOG}
\`\`\`

## Observable signals

### CI run counts (merge_group events)

$(printf '%b' "$CI_RUN_COUNTS")

### Version-bump workflow conclusions

${BUMP_CONCLUSIONS}

## Verdict

${VERDICT}
"

log "Pushing results to ${MAIN_BRANCH}"
gh api "repos/${REPO}/contents/runs/${RUN_ID}.md" \
  -X PUT \
  -f "message=test(exec): Record run ${RUN_ID} results" \
  -f "content=$(printf '%s' "$RESULTS" | base64 | tr -d '\n')" \
  -f "branch=${MAIN_BRANCH}" --silent

log "══ Experiment complete ══"
