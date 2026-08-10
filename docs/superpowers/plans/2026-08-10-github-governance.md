# GitHub Governance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish an enforceable branch, commit, push, pull-request, and merge policy for LinkLoom.

**Architecture:** Keep the human-readable policy in `CONTRIBUTING.md`, the author checklist in the pull-request template, and machine-enforceable naming rules in one dependency-free GitHub Actions workflow. Document the exact repository ruleset separately because GitHub branch protection cannot be configured through files committed to the repository.

**Tech Stack:** Markdown, GitHub Actions YAML, Bash, GitHub repository rulesets

## Global Constraints

- `main` is the only permanent branch and must remain releasable.
- Direct pushes to `main` are forbidden; every change uses a pull request.
- Pull requests use squash merge and Conventional Commit titles.
- Branches use `<type>/<optional-issue>-<slug>` with optional `codex/` prefix.
- Do not invent application build, lint, or test commands before a project toolchain exists.

---

### Task 1: Contributor policy and pull-request template

**Files:**
- Create: `CONTRIBUTING.md`
- Create: `.github/pull_request_template.md`

**Interfaces:**
- Consumes: The agreed GitHub working strategy.
- Produces: The authoritative contributor rules and the checklist completed by every pull-request author.

- [x] **Step 1: Write the contributor policy**

  Define the complete branch lifecycle, Conventional Commit syntax, push safety, pull-request requirements, squash merge policy, exceptions, and hotfix handling.

- [x] **Step 2: Add the pull-request template**

  Add sections for purpose, issue linkage, changes, verification, risk, UI evidence, and a policy checklist.

- [x] **Step 3: Inspect Markdown structure**

  Run: `rg -n '^#|^- \[[ x]\]' CONTRIBUTING.md .github/pull_request_template.md`

  Expected: Headings and checklist items from both files are listed.

### Task 2: Automated policy validation

**Files:**
- Create: `.github/workflows/pr-policy.yml`

**Interfaces:**
- Consumes: Pull-request title and head branch from the GitHub event payload.
- Produces: Required status check `Policy / validate`.

- [x] **Step 1: Implement dependency-free validation**

  Validate a maximum 72-character Conventional Commit title and the documented branch-name pattern in Bash. Permit GitHub Dependabot branches as a narrowly scoped automation exception.

- [x] **Step 2: Validate workflow syntax and policy examples**

  Parse the YAML with an available parser and exercise the regular expressions against valid and invalid examples.

  Expected: YAML parses; valid examples pass; invalid examples fail.

### Task 3: Repository ruleset documentation

**Files:**
- Create: `.github/BRANCH_PROTECTION.md`

**Interfaces:**
- Consumes: Status check name from `.github/workflows/pr-policy.yml`.
- Produces: An administrator checklist for configuring the `main` ruleset in GitHub.

- [x] **Step 1: Document the exact ruleset**

  Require pull requests, successful checks, resolved conversations, linear history, blocked force pushes and deletions, squash-only merges, and automatic branch deletion.

- [x] **Step 2: Document the current CI boundary**

  Require `Policy / validate` now and state that build, test, lint, type-check, and security jobs become required when those project commands are introduced.

- [x] **Step 3: Verify the complete change**

  Run: `git diff --check && git status --short && git diff -- CONTRIBUTING.md .github docs/superpowers/plans/2026-08-10-github-governance.md`

  Expected: No whitespace errors; all intended files are visible and contain only governance changes.
