# Run merge-queue-wait-for-post-merge-workflow-to-finish-2026-04-02T15-36

## Test 1: Validate mechanism

- Result: pass
- Expected VERSION: 1

## Test 2: Serialization

- Result: pass
- VERSION after PR-2: pass
- VERSION after PR-3: pass
- VERSION after PR-4: pass

## Git log

```text
merge-queue(wait-for-post-merge-workflow): Bump version to 4
test: Add test file for PR-4
merge-queue(wait-for-post-merge-workflow): Bump version to 3
test: Add test file for PR-3
merge-queue(wait-for-post-merge-workflow): Bump version to 2
test: Add test file for PR-2
merge-queue(wait-for-post-merge-workflow): Bump version to 1
test: Add test file for PR-1
test(exec): Add experiment runner script
test(exec): Implement experiment workflows and VERSION
```

## Observable signals

### CI run counts (merge_group events)

- PR #83: 1 merge_group CI run(s)
- PR #84: 1 merge_group CI run(s)
- PR #85: 2 merge_group CI run(s)
- PR #86: 2 merge_group CI run(s)

### Version-bump workflow conclusions

- VERSION 4 (PR #86): success
- VERSION 3 (PR #85): success
- VERSION 2 (PR #84): success
- VERSION 1 (PR #83): success

## Verdict

Confirmed — interleaved history with merge queue invalidation observed
