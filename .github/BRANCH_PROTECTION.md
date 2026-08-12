# GitHub Ruleset for `main`

Repository administrators must configure a branch ruleset targeting the default branch `main`. This file is the binding configuration reference; committing it does not activate the GitHub settings automatically.

## Required rules

Configure the `main` ruleset with these requirements:

- Block branch deletion.
- Block force pushes.
- Require a pull request before merging.
- Require all review conversations to be resolved.
- Require status checks to pass before merging.
- Require the branch to be up to date before merging, or enable the GitHub merge queue.
- Require linear history.
- Do not allow bypasses for routine maintainer work. Reserve any emergency bypass for repository administrators and audit its use.

When more than one active maintainer works on the repository, require at least one approval and dismiss stale approvals after material new changes. Enable code-owner review after a `CODEOWNERS` file with real owners has been added.

## Required status checks

Require this check immediately:

```text
Policy / validate
```

After each of these checks has run reliably on pull requests, make it required:

```text
Swift / test
Swift / release-build
```

The workflows in [`workflows/pr-policy.yml`](workflows/pr-policy.yml) and [`workflows/swift.yml`](workflows/swift.yml) supply these checks. When application tooling is added, also require its build, automated test, lint, type-check, and security checks. A new check should first run reliably on pull requests before administrators make it required.

## Merge and branch settings

In the repository pull-request settings:

- Enable **Squash merging**.
- Disable merge commits.
- Disable rebase merging.
- Enable automatic deletion of head branches.
- Use the pull-request title as the squash commit subject and retain the issue or pull-request reference.

## Verification after configuration

Open a draft pull request from a conforming branch and confirm that `Policy / validate` appears. Then verify all four controls:

1. A non-conforming pull-request title fails the check.
2. A non-conforming branch name fails the check.
3. A conforming title and branch pass the check.
4. GitHub prevents merging while a required check is failing or a conversation is unresolved.

Re-run this verification whenever repository rulesets, merge methods, or required workflows change.
