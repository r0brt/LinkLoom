# Contributing to LinkLoom

This document is the binding Git and GitHub policy for LinkLoom. Exceptions must be explained in the affected pull request and approved by a maintainer.

## Core model

- `main` is the only permanent branch and must always be buildable, testable, and releasable.
- Direct pushes to `main` are not allowed. Every change reaches `main` through a pull request.
- Work happens on short-lived branches with one clearly defined goal.
- Pull requests are merged using **Squash and merge**.
- Force pushes and deletion of `main` are prohibited.

## Branches

Use this format:

```text
<type>/<optional-issue-number>-<short-description>
```

Codex-created branches use the additional `codex/` prefix:

```text
codex/<type>/<optional-issue-number>-<short-description>
```

Allowed branch types are:

| Type | Purpose |
| --- | --- |
| `feat` | New user-facing functionality |
| `fix` | Defect correction |
| `docs` | Documentation only |
| `refactor` | Internal restructuring without a behavior change |
| `test` | Test-only changes |
| `chore` | Maintenance, dependencies, or tooling |
| `hotfix` | Urgent production correction |

Examples:

```text
feat/42-link-preview
fix/57-invalid-url-validation
docs/contribution-guide
codex/chore/71-update-dependencies
```

Branch names use lowercase ASCII letters, digits, and hyphens. Include the GitHub issue number when an issue exists. Keep a branch focused on one outcome, aim to merge it within three working days, and delete it after merge.

Dependabot branches are the only automatic exception to this naming convention.

## Starting work

Start from the current `main` branch:

```bash
git switch main
git pull --ff-only
git switch -c feat/42-link-preview
```

Do not combine unrelated cleanup with the requested change. Open a draft pull request early when feedback or continuous integration is useful.

## Commits

Commit messages follow Conventional Commits:

```text
<type>(<optional-scope>): <imperative summary>
```

Allowed commit types are `feat`, `fix`, `docs`, `refactor`, `test`, `chore`, `build`, `ci`, `perf`, and `revert`.

Examples:

```text
feat(preview): add metadata extraction
fix(validation): reject URLs without a hostname
test(api): cover duplicate link handling
docs: document local development setup
```

Commit rules:

- Keep the complete subject at or below 72 characters.
- Use an imperative summary such as `add`, `prevent`, or `update`.
- Make each commit one understandable unit of change.
- Do not use permanent messages such as `WIP`, `misc`, `changes`, or `fix stuff`.
- Never commit secrets, local credentials, editor state, or unintended generated files.
- Run all checks relevant to the changed area before committing.

Local intermediate commits do not need a curated public history because pull requests are squash-merged. They must still remain understandable enough for review and safe collaboration.

## Pushing safely

Publish the branch early and set its upstream:

```bash
git push -u origin feat/42-link-preview
```

Push after completed work units and before handing work to another contributor. Never use `git push --force`. If rewriting an unpublished or solely owned branch is necessary, use `git push --force-with-lease`. After review begins, avoid rewriting history; if it cannot be avoided, notify reviewers explicitly.

Before final approval, incorporate the current `main` state and resolve conflicts on the working branch. Do not resolve conflicts directly on `main`.

## Pull requests

Every pull request must:

- Have a Conventional Commit title no longer than 72 characters.
- Address one technical or product outcome.
- Link its issue with `Closes #<number>` when an issue exists.
- Explain the motivation and the material changes.
- Report the exact automated and manual verification performed.
- Include screenshots or recordings for visible UI changes.
- Identify migrations, compatibility concerns, security implications, and rollback risks.
- Pass every required status check.
- Resolve all review conversations before merge.

Prefer fewer than 500 changed, non-generated lines. A larger pull request must explain why it cannot reasonably be split.

When the repository has more than one active maintainer, at least one approval from someone other than the author is required. Changes to sensitive areas should additionally require the matching code owner once a `CODEOWNERS` file exists.

## Merge policy

Use **Squash and merge** exclusively. The pull-request title becomes the commit subject on `main`, for example:

```text
feat(preview): add Open Graph metadata extraction (#42)
```

The person merging must confirm that required checks pass, required approvals exist, and conversations are resolved. Delete the source branch automatically after merge. Do not rewrite published `main` history.

If a merged change must be backed out, create a dedicated revert pull request. Do not repair `main` with a force push or by deleting commits.

## Hotfixes

Urgency does not bypass review or CI. Create a `hotfix/<issue>-<description>` branch from `main`, keep the patch minimal, open a pull request, and use the normal squash merge. If an incident requires expedited review, document that fact and the follow-up work in the pull request.

## Required checks

The repository requires `Policy / validate`, `Swift / test`,
`Swift / release-build`, and `Swift / UI smoke` on `main`. `Policy / validate`
enforces pull-request title and branch naming. A future check must first run
reliably on pull requests before administrators make it required. As
application tooling is introduced, its build, test, lint, type-check, and
security jobs must be added to CI and then made required on `main`.

The administrator setup is documented in [`.github/BRANCH_PROTECTION.md`](.github/BRANCH_PROTECTION.md).
