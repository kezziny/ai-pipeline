# Repository & Agent Conventions (AGENTS.md)

This document defines repository-wide engineering standards, workflow conventions, quality gates, and agent behavior rules for the autonomous multi-agent development pipeline in this repository.

All pipeline roles (`role-product-manager`, `role-senior-developer`, `role-architect`, `role-implementer`, `role-code-reviewer`, `role-qa-engineer`) and human contributors adhere to these standards.

---

## 1. Pipeline Context & Trigger Rules

### Pipeline Status Lifecycle
The canonical GitHub Projects issue lifecycle flows through nine standard columns:
`Backlog` -> `PM` -> `Senior Dev` -> `Architect` -> `Ready` -> `Implementer` -> `Code Review` -> `QA` -> `Done`

- **Ready Column (Implementation Gate)**: Holds architecturally approved issues ready for implementation. Acts as a manual backlog buffer. Implementer agents pick up tasks when moved from `Ready` or when instructed.

### Dedicated Pipeline vs. Interactive Pair-Programming
- **Pipeline Autonomous Operations**: Triggered exclusively through dedicated continuous polling loops or explicit user delegation targeting assigned GitHub Project issues.
- **Normal Interactive Pair-Programming**: When collaborating interactively with human developers on ad-hoc questions, debugging, or manual edits, pipeline roles (especially `role-implementer` and `role-code-reviewer`) **must not** unilaterally create git worktrees, execute automated branch checkouts, or mutate GitHub Project board states.
- If invoked ambiguously outside the pipeline flow, agents halt and request clarification before performing board transitions or workspace mutations.

---

## 2. Git Workflow & Branching Conventions

### Branch Naming Standards
All development occurs on issue-specific feature or fix branches branched from up-to-date `origin/master`:
- Features: `feat/<issue-num>-<slug>` (or `feature/<issue-num>-<slug>`)
  - Example: `feat/42-jwt-auth-middleware`
- Bug Fixes: `fix/<issue-num>-<slug>`
  - Example: `fix/87-null-pointer-session-cleanup`
- Refactoring / Chores: `refactor/<issue-num>-<slug>` or `chore/<issue-num>-<slug>`

### Worktree Isolation Standards
To prevent working tree collisions, uncommitted diff leaks, and branch checkout lockouts:
- **Implementer**: Operate exclusively inside `.worktrees/issue-<issue-num>`.
- **Code Reviewer**: Operate exclusively inside `.worktrees/review-pr-<pr-num>`.
- **QA Engineer**: Operate exclusively inside `.worktrees/qa-pr-<pr-num>`.
- **Cleanup Rule**: Temporary worktrees must be pruned (`git worktree remove --force <path>` followed by `git worktree prune`) once review, testing, or push is concluded. Never leave orphaned worktrees.

---

## 3. Commit Message Standards

Commits must follow the **Conventional Commits** specification with explicit issue number references:

### Format
```
<type>(#<num>): <concise-imperative-description>
# e.g., feat(#<num>): <description>, fix(#<num>): <description>

[optional body with rationale and architectural context]
```

### Types
- `feat`: New feature or user-facing capability.
- `fix`: Bug fix or defect resolution.
- `refactor`: Code change that neither fixes a bug nor adds a feature.
- `test`: Adding missing tests or correcting existing tests.
- `docs`: Documentation changes only (e.g., `README.md`, `AGENTS.md`).
- `chore`: Build scripts, CI configurations, package manager updates.

### Examples
- `feat(#42): implement jwt auth middleware and token validation`
- `fix(#87): handle undefined session timeout in websocket handler`
- `test(#42): add test cases for expired and malformed tokens`
- `docs(#105): synchronize role naming and decision matrix in README`

---

## 4. Architectural Pillars & Code Quality Standards

Every technical implementation must satisfy the **Four Architectural Pillars**:

1. **Modular Separation**:
   - Keep business logic decoupled from presentation and infrastructure adapters.
   - Maintain single responsibility per module; avoid monolith controller or utility files.
   - Avoid circular dependencies and tight coupling across subsystems.

2. **Explicit Data Contracts & DTOs**:
   - Define strongly typed, immutable schemas or DTOs for boundary crossing.
   - Eliminate duplicate or conflicting schema definitions across layers.
   - Validate inputs at perimeter boundaries; trust internal strongly typed structures.

3. **Leak-Free Resource Management**:
   - All files, sockets, database handles, subprocesses, and temporary directories must be deterministically released.
   - Shell scripts must use `trap` handlers to remove temporary files and clean up child processes on exit/error.
   - Applications must implement graceful shutdown signals (`SIGTERM`, `SIGINT`).

4. **Fault Tolerance & Defensive Robustness**:
   - Anticipate boundary failure modes: network drops, timeouts, malformed payloads, rate limits.
   - Use exponential backoff with jitter for retries on transient external calls.
   - Never suppress exceptions silently without logging structured diagnostic context.

---

## 5. Quality Gate Standards (Pre-Review & Pre-Merge)

No PR may be transitioned to `Code Review` or merged to `Done` without passing the essential quality gates:

### Gate 1: Code Formatting & Linting
- Linters and formatters must run with 0 errors and 0 warnings.
- No bypassing lint rules with `# pylint: disable` or `eslint-disable` unless formally justified as an unavoidable false positive.

### Gate 2: Automated Unit & Integration Tests
- All existing repository tests must pass with 0 regressions.
- All new functionality and edge cases must be accompanied by behavior-based tests.
- Tests must be deterministic (no time-sensitive sleeps or external network dependencies).

### Gate 3: Clean Build, Rebase & PR Checks
- Clean build execution (`build`, `compile`, or script packaging) must succeed with exit code 0.
- PR must be rebased cleanly onto latest `origin/master` with 0 merge conflicts.
- **Remote CI PR Checks**: All automated GitHub PR checks must be passing green (`gh pr checks <pr-num>`). Implementer must watch and confirm all green before moving issue to `Code Review`. Reviewer and QA check remote PR status first and bounce back immediately if red.

---

## 6. Continuous Improvement Engine

`AGENTS.md` is a living document. The multi-agent pipeline continuously learns and refines repository standards through the following mechanism:

1. **Harvesting During Execution**:
   - **Product Manager (`role-product-manager`)**: Identifies reusable domain terms, user journey conventions, or product rules during requirements scoping and appends them to issue specifications under `Proposed AGENTS.md Additions`.
   - **Senior Developer (`role-senior-developer`)**: Captures recurring architectural patterns, code reuse standards, and library choices.
   - **Software Architect (`role-architect`)**: Codifies generalizable architectural guardrails, contract deduplication rules, and boundary constraints into `Proposed AGENTS.md Additions` in the architecture review report.
   - **Implementer (`role-implementer`)**: Notes linter nuances, test mock patterns, and environment quirks encountered during coding. In addition, Implementer applies proposed `AGENTS.md` additions (from both PM and Architect) directly to `AGENTS.md` in the feature branch diff.
   - **Code Reviewer (`role-code-reviewer`)**: Documents recurring anti-patterns, style edge cases, and security review rules. Audits and validates that proposed `AGENTS.md` additions are accurately reflected in the PR diff.
   - **QA Engineer (`role-qa-engineer`)**: Contributes reusable Playwright selectors, UX verification patterns, and environment stability practices.

2. **Synthesis & Integration**:
   - Recurring, non-ephemeral proposals from issue comments and PR descriptions are consolidated by human tech leads or designated maintainers.
   - Validated conventions committed to root `AGENTS.md` become immediately authoritative for all subsequent pipeline cycles.

3. **Role Skill Refinements**:
   - When friction or ambiguities arise within specific role workflows, agents document concrete feedback in issue comments.
   - Maintainers update the respective skill files under `.agents/skills/<role-name>/SKILL.md` to keep autonomous operations resilient and self-improving.
