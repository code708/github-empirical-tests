# Run merge-queue-wait-for-post-merge-workflow-to-finish-2026-03-30T185443

## Test 1: Validate mechanism

- Result: fail
- Expected VERSION: 1

## Test 2: Serialization

- Result: fail
- VERSION after PR-2: fail
- VERSION after PR-3: fail
- VERSION after PR-4: fail

## Git log

```text
test: Add test file for PR-4
test: Add test file for PR-3
test: Add test file for PR-2
test: Add test file for PR-1
test(exec): Fix runtime issues in experiment script
test(exec): Add EXIT trap to close open PRs on abort
test(exec): Add experiment runner script
test(exec): Implement experiment workflows and VERSION
test(design): Design the experiment
chore(config): Ignore auth script and keep runs/ dir
```

## Observable signals

### CI run counts (merge_group events)

- PR #30: 1 merge_group CI run(s)
- PR #31: 1 merge_group CI run(s)
- PR #32: 1 merge_group CI run(s)
- PR #33: 1 merge_group CI run(s)

### Version-bump workflow conclusions

failure, failure, failure, failure

## Verdict

Rejected — VERSION did not reach expected value
