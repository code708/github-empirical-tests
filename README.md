# GitHub Empirical Tests

This repository is used to empirically verify the behavior of GitHub features such as Workflows, Actions, and Merge Queue, since some behaviors are not explicitly documented.

## Purpose

GitHub's documentation doesn't always cover every edge case or subtle behavior of its features. This repo serves as a testing ground to:

- Set up real workflows and actions to observe their actual behavior
- Document findings that aren't covered in official docs
- Provide reproducible examples that confirm or clarify undocumented behavior

## How to Use This Repo

1. **Create an experiment branch** for the behavior you want to test.
2. **Document the experiment design** in `DESIGN.md` to guide the implementation and execution of tests.
3. **Run the tests** and document the findings in `RESULTS.md`.

For details about creating branches refer to [CONTRIBUTING.md](CONTRIBUTING.md#git-branching-model).

## Topics of Interest

- GitHub Actions trigger conditions and event behavior
- Workflow concurrency and ordering
- Merge Queue behavior and requirements
- Reusable workflows and composite actions
- Permissions and token scoping
- AI agent contribution