# Experiment: Version bump serialization via merge queue

## Hypothesis

A post-merge workflow that pushes a version bump commit via `GITHUB_TOKEN` can produce a strictly interleaved history `[PR → bump → PR → bump → ...]` when the target branch uses a merge queue, because the merge queue detects the base branch ref change and rebuilds subsequent entries against the updated base.

## Background

- `GITHUB_TOKEN` pushes do NOT trigger new workflow runs (GitHub's recursion prevention)
- The merge queue's own merge is not subject to this guard — it produces a regular `push` event that does trigger workflows (e.g. `version-bump.yml`). The recursion block only applies to events caused by another workflow's `GITHUB_TOKEN`.
- However, the merge queue monitors the base branch ref independently of workflow dispatch
- If the base branch ref changes, the merge queue should detect this and rebuild queued entries against the latest base
- This behavior is not explicitly documented by GitHub
- With `max_entries_to_build: 1`, the merge queue processes entries sequentially — it won't start testing the next entry until the current one merges
- The timing gap between "PR merges" and "version bump is pushed" is the critical window — if the merge queue starts the next entry before the bump lands, the bump won't be in the merge group's base
- To close this gap, CI polls for in-flight post-merge workflows before completing (details in ci.yml below)

### Critical paths

If the version-bump workflow hasn't finished by the time the poll times out (60s), the ci job passes anyway, the merge queue merges the next PR, and the bump lands on top afterward — breaking the interleaved history.

But in practice the version-bump job is trivial (checkout, increment a number, push) — it should complete in under 30s. The 4s initial delay + 60s timeout gives a wide margin.

The more realistic risk is the **opposite end**: the version-bump workflow hasn't even been queued yet when the poll starts. GitHub doesn't guarantee instant workflow dispatch — there can be a delay between the push event and the workflow run appearing via the API. That's what the 4s initial delay is for: give GitHub time to register the run before we start checking. The dispatch timing experiment (`workflow/dispatch-timing/main`) measured a worst-case dispatch delay of 3s across 100 trials, so 4s provides margin.

If both of those assumptions hold (GitHub queues the run within 4s, and the bump finishes within 60s), the serialization works. If either fails, the merge queue proceeds without the bump in its base.

## Design

- The CI job runs **twice** per PR: once on `pull_request` (gates the merge button) and once on `merge_group` (gates the actual merge). The poll step only matters in the `merge_group` run — that's the last gate before the PR lands.
- The poll has two failure modes: (1) GitHub hasn't **queued** the version-bump run yet when polling starts (mitigated by the 4s initial delay), or (2) the version-bump takes longer than the 60s timeout. If either occurs, CI passes without the bump in the base, breaking serialization.

### Implementation structure

```text
.github/workflows/
├── ci.yml           # merge_group + pull_request trigger
└── version-bump.yml # push trigger, bumps VERSION file
VERSION              # contains current version number (starts at 0)
```

### Branch protection on the experiment's integration branch

- Require status checks to pass before merging:
  - Required check: **`ci`** — this is the **job name** in `ci.yml` (not the workflow name). GitHub matches status checks by the job name that reports back on the commit/merge group.
  - Configured in: **Settings → Branches → Branch protection rules** for the integration branch. Under "Require status checks to pass before merging", search for and add `ci`.
- Merge queue enabled:
  - Method: **rebase**
  - Max entries to build: **1** (sequential processing)
  - Configured in: same branch protection rule, under "Require merge queue". The merge queue uses the same required status checks — it will wait for the `ci` job to pass on the temporary `gh-readonly-queue/<branch>/...` ref before merging.

### Workflow: `ci.yml`

Triggers on `pull_request` and `merge_group`.

Steps:

1. Checkout
2. Print current VERSION content and HEAD SHA (observability)
3. **Poll step** (merge_group only): wait for the in-progress/queued `version-bump.yml` run matching the integration branch's HEAD SHA to complete before proceeding. Initial 4s delay to let GitHub queue the workflow, then poll every 3s, timeout at 60s. Each poll iteration logs the iteration count and elapsed time.
4. Pass CI check

### Workflow: `version-bump.yml`

Triggers on `push` to integration branch.

Steps:

1. Checkout
2. Read VERSION, increment by 1, commit and push via `GITHUB_TOKEN`
3. Commit message format: `chore: Bump version to <N>`

Permissions: `contents: write`

### Initial state

- VERSION file containing `0` already exists on the integration branch (committed before Test 1)
- Branch protection and merge queue are enabled

## Test procedure

### Test 1 — Validate mechanism (1 PR)

1. Create PR-1 with a trivial change, targeting integration branch
2. Wait for CI, add to merge queue
3. PR merges → version-bump.yml triggers → pushes VERSION=1
4. **Verify:** VERSION on integration branch is `1`

### Test 2 — Serialization (3 PRs)

1. Create PR-2, PR-3, PR-4 with distinct trivial changes
2. Wait for CI on all three, add all to merge queue in order
3. **Expected sequence:**
   - PR-2 merges → bump pushes VERSION=2 → merge queue detects base change → PR-3's merge group includes VERSION=2
   - PR-3 merges → bump pushes VERSION=3 → PR-4's merge group includes VERSION=3
   - PR-4 merges → bump pushes VERSION=4
4. **Verify git log** (newest first):

   ```text
   chore: Bump version to 4    ← version-bump for PR-4
   <PR-4 commit>
   chore: Bump version to 3    ← version-bump for PR-3
   <PR-3 commit>
   chore: Bump version to 2    ← version-bump for PR-2
   <PR-2 commit>
   chore: Bump version to 1    ← version-bump for PR-1 (from Test 1)
   <PR-1 commit>
   ```

## Observable signals

For each merge queue entry, check:

- **Merge queue events** (GitHub UI or API): was the entry invalidated and re-queued?
- **CI run count per PR**: >1 merge_group CI run means invalidation occurred
- **CI logs**: does the VERSION value printed match expectations?
- **version-bump.yml runs**: did each complete successfully (no push failures)?
- **Final git log**: is the history strictly interleaved?

## Success criteria

- **Confirmed:** History is strictly `[PR → bump → PR → bump → ...]` with correct monotonic VERSION values. Each PR's merge group CI log shows the VERSION from the prior bump.
- **Partially confirmed:** History is correct but only because the merge queue naturally waited long enough (no invalidation observed). This means it works but is timing-dependent.
- **Rejected:** PRs merge without the intervening bump, VERSION values are wrong or duplicated, or version-bump pushes fail (non-fast-forward).

## Notes

- The polling step in CI is the key mechanism that ensures the version bump has landed before CI completes. Without it, the merge queue might merge the next PR before the bump is pushed.
- If rejected, alternative approaches: use a PAT instead of GITHUB_TOKEN, use GitHub App token, or combine version bump into the merge queue's CI check itself.
