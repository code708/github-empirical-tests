# Contribution Guidelines for This Project

## AI Agents and MCP

### Using Claude's GitHub MCP

Claude Code uses the [Model Context Protocol](https://modelcontextprotocol.io/) to interact with GitHub.

This project currently relies on a [workaround](https://github.com/anthropics/claude-code/issues/3433) to connect to GitHub. An repository-level `.mcp.json` is required by each developer to provide their own credentials, as it's git-ignored for this same reason.

#### Steps

1. **Create a fine-grained GitHub Personal Access Token (PAT)** with the scopes needed for your work. Go to [token management page](https://github.com/settings/personal-access-tokens).

   > _For more information see the [GitHub docs](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)_.

2. **Store the token in a password manager** for secure storage and retrieval.
   1. **On MacOS** it's recommended to use the Keychain CLI with a unique service name.

      ```sh
      security add-generic-password -a "$USER" -s "YOUR_PAT_NAME" -w
      ```

      > **TIP**: passing `-w` without a value will prompt you for secure input of your PAT in the terminal.

3. **Create `.mcp.json`** in the project root.

   ```json
   {
   	"mcpServers": {
   		"github": {
   			"command": "sh",
   			"args": ["-c", "GITHUB_PERSONAL_ACCESS_TOKEN=<MCP_LAUNCH_COMMAND>"]
   		}
   	}
   }
   ```

   > Replace the <MCP_LAUNCH_COMMAND> with the appropriate shell command invoking your password manager.
   1. **Using MacOS Keychain**  
      Launch the official `@modelcontextprotocol/server-github` MCP server, injecting the PAT from the Keychain at runtime.
      ```sh
      $(security find-generic-password -a \"$USER\" -s \"YOUR_PAT_NAME\" -w) exec npx -y @modelcontextprotocol/server-github
      ```

4. **(Re-)start Claude Code** in the project directory. It will detect `.mcp.json` and prompt you to approve the MCP server. After approval the GitHub tools (issues, PRs, etc.) will be available.

## Git Branching Model

This repo does not track issues.

### Branch Types

**Permanent branches:**

- **`main`** (default branch) — the concept behind this repo, it's configurations and documentation is developed on this branch.

**Experiment branches** (verifying GitHub behaviors):

- **`<use-case>/<experiment>/main`** (setup, execution and documentation) — permanent, branched from `main`, describes a particular experiment, serves as the execution target and result documentation.
- **`<use-case>/<experiment>/*`** (auxiliary branches) — permanent, branched from `<experiment>/main`, created as needed by the experiment design, e.g. to observe  merge behavior.

### Branch Protection Rules


> `<use-case>` names are defined [below](#allowed-use-cases).  
> `<experiment>` names can be chosen freely.

- `main`: Direct pushes and force pushes allowed, renaming not allowed, deletion not allowed.
- `<use-case>/<experiment>/main` and `<use-case>/<experiment>/*`: Developers may create branches,direct pushes and force pushes allowed, renaming allowed, deletion not allowed.
- `*`: The creation of any branch not prefixed with an use case is prohibited. 

#### Allowed Use Cases

- _merge-queue_
- _workflow_

> Use cases represent github features or an orchestration of such. Add new use cases as they emerge over time

## Development Workflow

### Implementing a Repository Enhancement

There is no formal process. Changes to the configuration and documentation on `main` can be made directly and without PRs. Since experiment branches keep an isolated scope of files, they can simply be rebased onto an updated `main` without conflict. 

## Committing Changes

### Scoping and Sizing Commits

One commit should represent a single logical change. If possible keep changes scoped to a single domain or logical unit. Keep commits as small as possible, but as large as necessary. Write a conventional commit message for every commit.

### Bumping the Version

Do not update the version in `package.json` manually. A CI workflow automatically computes and bumps the version on PRs targeting `integration`, based on the commit types in the PR.

### Writing Commit Messages

Experimentation should be fast and simple, though well documented. Therefore, the repo does not follow a full-fledged strict convention. Still it encourages clear and consistent commit messages that facilitate understanding the history and purpose of changes.

For this reason commit messages follow a subset of the **Conventional Commits** [specification](https://www.conventionalcommits.org/en/v1.0.0/):

```text
<type>[optional scope]: <description>

[optional body]
```

#### Commit Types

Use the following custom types:

- **chore**: A configuration, dependency update, or maintenance task that doesn't affect experiment design
- **docs**: A pure documentation change
- **style**: A code style change, not affecting behavior (formatting, semicolons, reordering statements, etc.)
- **refac**: A code refactoring, not affecting behavior (e.g. renaming variables, extracting functions, changing patterns, etc.)
- **test**: A change affecting the experiment design and execution
- **perf**: An improvement in experiment performance, not affecting design

#### Scopes

Allowed scopes are:

- **config**: Changes to the configuration of either the repository or an experiment.
- **repo**: Changes to the concept and framework of how to implement experiments in this repository.
- **design**: Changes to an experiment's design, including hypotheses, metrics and analysis.
- **exec**: Changes affecting experiment execution, including tools and implementation.

Guidelines for scopes:

- Keep scopes consistent with the repository structure
- only use allowed scopes
- Add as new domains or modules are introduced
- `test`, `perf` and `refac` commits must not use the `repo` scope
- `style`, `refac` and `perf` commits must not use the `design` scope
- Always use a scope for `test` commits
- A scoped commit must only contain changes (files or lines) that belong to the specified scope

#### Breaking Changes

There are no breaking changes as there is no deliverable artifact and no consumer of such.

#### Description

Guidelines for the description:

- **Uppercase allowed** — Always start with a capital letter and use uppercase where it serves clarity (e.g. acronyms, proper nouns, etc.)
- **Imperative mood** — Use "Add support for..." not "Added..." or "Adds..."
- **Be concise** — The total length of type, scope, and description must not exceed 80 characters
- **Avoid redundancy** — Don't use words redundant to the type or scope (e.g. "Fix" in a `*fix` commit, etc.)

#### Body

Guidelines for the body:

- **Explain why, not what** — The diff shows what changed; explain the reasoning, context, or problem being solved
- **Wrap at 80 characters** — Wrap lines so they don't exceed 80 characters, but don't cut words, unless it's longer than 80 characters itself
- **Be concise** — A few sentences typically suffice; use bullet points only for multiple related changes
- **Imperative mood** — Use "Add support for..." not "Added..." or "Adds..."
- **One concern per paragraph** — Group related points; separate unrelated ones with blank lines

#### Footers

The use of footers is omitted for the sake of simplicity.