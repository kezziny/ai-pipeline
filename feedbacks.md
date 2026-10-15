# Pipeline Improvement Backlog & Feedbacks (`feedbacks.md`)

This document aggregates architectural refinements, role enhancements, and workflow optimizations collected from real-world usage. These items will be implemented in a coordinated batch.

---

## 1. Pipeline Lifecycle & Gating Improvements

### FB-01: Manual Implementation Gate (`Ready` Column)
- **Problem**: Currently, when `role-architect` approves a plan, the issue moves directly to `Implementer`, immediately triggering coding. There is no human prioritization or budgeting gate before execution begins.
- **Proposed Solution**:
  - Introduce a **`Ready`** column between `Architect` and `Implementer`.
  - Serves as the implementation-ready backlog.
  - `role-architect` approves plans and moves them to `Ready`.
  - Issues remain in `Ready` until a human manually drags them to `Implementer` (or approves execution) to start development.
- **Affected Components**:
  - `role-architect/SKILL.md` (approval output moves to `Ready`)
  - `role-implementer/SKILL.md` (monitors `Implementer` only after human drag)
  - `README.md`, `instruction.md`, `AGENTS.md` (diagrams, columns, setup instructions)
  - `tools/poll-project.sh`, `tools/project-move.sh` (column & alias definitions)

---

### FB-02: Implementer Green PR Checks Gate
- **Problem**: Implementer currently pushes commits and immediately advances status to `Code Review` without waiting for CI / GitHub Actions checks (lint, tests, build) to pass on the PR branch, or without ensuring no merge conflicts with `master`.
- **Proposed Solution**:
  - `role-implementer` must poll PR check runs (`gh pr checks <PR_NUM> --watch` or inspect status checks).
  - Issue must NOT be transitioned to `Code Review` until:
    1. All PR checks are **green** (passing).
    2. Branch is cleanly rebased on latest `origin/master` with **0 merge conflicts**.
  - If a check fails on CI, Implementer must inspect failure logs, fix the code, push new commits, and re-verify before handoff.
- **Affected Components**:
  - `role-implementer/SKILL.md` (mandatory CI checks gate step)
  - `AGENTS.md` (Gate 2 & 3 enforcement)

---

## 2. Reviewer & QA Role Refinements

### FB-03: Reviewer & QA CI Offloading (Check Inspection vs Local Re-runs)
- **Problem**: Currently, `role-code-reviewer` and `role-qa-engineer` mount the worktree and re-run linters and unit tests locally. This duplicates CI effort, slows down pipeline throughput, and burns local compute.
- **Proposed Solution**:
  - `role-code-reviewer` and `role-qa-engineer` first query GitHub PR status checks (`gh pr checks <PR_NUM>`).
  - If any check is red / failing: **immediately reject and route back to `Implementer`** with check failure logs. No further review needed.
  - If checks are green: proceed immediately to role-specific evaluation without re-running standard unit tests/linters locally.
- **Affected Components**:
  - `role-code-reviewer/SKILL.md`
  - `role-qa-engineer/SKILL.md`

---

### FB-04: Redefined QA Responsibilities (Coverage Audit & Live UX / Look-and-Feel)
- **Problem**: QA was previously described as running the test suite. Running tests is already handled by PR checks / CI.
- **Proposed Solution**:
  - Redefine `role-qa-engineer` around two higher-value dimensions:
    1. **Requirements Coverage Validation**: Analyze the implemented test cases against PM functional requirements. Audit whether edge cases, negative flows, and acceptance criteria are actually covered. Suggest missing test scenarios and route back to `Implementer` if coverage is inadequate.
    2. **Interactive UX & Design Consistency Testing**: Launch the running application (e.g. via Playwright), interact with the live UI, and evaluate look-and-feel, visual balance, loading states, empty states, and UX rough edges against `AGENTS.md` design standards. Provide actionable UX critique.
- **Affected Components**:
  - `role-qa-engineer/SKILL.md` (rewrite role focus, checklist, and failure categories)
  - `README.md`, `instruction.md`, `AGENTS.md`

---

### FB-06: Code Reviewer Scope Refinement (Feature Fidelity, Code Quality & Anti-Duplication)
- **Problem**: With test and build execution offloaded to PR checks (FB-03), the Code Reviewer's core value must center on human-level engineering discernment rather than mechanical test verification.
- **Proposed Solution**:
  - Focus `role-code-reviewer` explicitly on four core audit pillars:
    1. **Feature Fidelity & Completeness**: Verify the diff strictly implements the requested feature as specified in the PM requirements and approved technical plan (no missing acceptance criteria, no unauthorized feature creep).
    2. **Code Quality & Craftsmanship**: Verify clean code patterns, meaningful naming, maintainability, robust error handling, strong typing (no lazy `any`), and lack of unintended side effects.
    3. **DRY & Anti-Duplication**: Actively audit for redundant logic, copy-pasted helper functions, duplicate DTOs, or reimplementations of existing utility/service capabilities available in the codebase.
    4. **Architectural & Security Integrity**: Verify module boundaries, encapsulation, and that no secrets, leaky abstractions, or security vulnerabilities are introduced.
- **Affected Components**:
  - `role-code-reviewer/SKILL.md` (audit checklist, report template, and evaluation criteria)
  - `README.md`, `instruction.md`, `AGENTS.md`

---

## 3. Specification & Planning Ergonomics

### FB-05: Compact Technical Implementation Plans (Expandable Details)
- **Problem**: Technical implementation plans generated by `role-senior-developer` are excessively verbose, overwhelming the issue description and making architectural review tedious.
- **Proposed Solution**:
  - Restructure the plan template into an **executive, decision-focused format**:
    - **Key Technical Decisions**: 3-5 bullet points on core architectural choices, library selections, and design patterns.
    - **Contract & API Overview**: Concise summary of new/modified endpoints and DTO shapes.
    - **Regression & Risk Highlights**: High-impact areas only.
  - Collapse exhaustive file lists, detailed TypeScript interface dumps, and boilerplate method signatures inside HTML `<details><summary>` expandable blocks:
    ```markdown
    <details>
    <summary>📁 Detailed File Impact & Method Signatures (Click to expand)</summary>

    | Action | File Path | Purpose |
    | :--- | :--- | :--- |
    ...
    </details>
    ```
- **Affected Components**:
  - `role-senior-developer/SKILL.md` (updated plan template and compactness guidelines)
  - `role-architect/SKILL.md` (alignment with compact plan review)

---

## 4. Repository Evolution & Knowledge Harvesting

### FB-07: Closed-Loop AGENTS.md Evolution (Implementer Updates, Reviewer Verifies)
- **Problem**: When `role-product-manager` identifies new conventions or UX rules, it logs them under `## 4. Proposed AGENTS.md Additions` in the issue description. Currently, these proposals sit passively in the issue body and often fail to make it into the codebase's actual `AGENTS.md`.
- **Proposed Solution**:
  - **Implementer Action**: When implementing an issue, `role-implementer` must inspect `## 4. Proposed AGENTS.md Additions` in the issue body. If new conventions are proposed (and not marked `None`), the implementer must edit `AGENTS.md` in the feature branch to incorporate the new guidelines as part of the PR diff.
  - **Reviewer Validation**: `role-code-reviewer` must include an explicit quality gate checking that `AGENTS.md` was updated to reflect the PM requirements. If the PM proposed additions but `AGENTS.md` was not updated (or was updated inaccurately), the reviewer requests changes.
- **Affected Components**:
  - `role-implementer/SKILL.md` (step added to commit `AGENTS.md` updates alongside code)
  - `role-code-reviewer/SKILL.md` (audit checklist updated to enforce `AGENTS.md` update validation)
  - `AGENTS.md` (Section 6 Continuous Improvement Engine updated)

---

## 5. Requirements Scoping & Role Boundaries

### FB-08: PM High-Level Focus (No File Details or Implementation Mechanics)
- **Problem**: `role-product-manager` frequently leaks into technical planning by listing specific code files to edit, suggesting code snippets, or prescribing internal implementation mechanics. This duplicates and constrains `role-senior-developer`.
- **Proposed Solution**:
  - Enforce strict high-level functional focus in `role-product-manager/SKILL.md`.
  - Explicitly forbid:
    - Specifying exact code files, directory structures, or file paths.
    - Providing code snippets, API implementations, class/function signatures, or database schemas.
    - Specifying internal software design or framework mechanics.
  - Limit PM deliverables strictly to:
    - Business context & user problem.
    - Scope boundaries (in-scope vs out-of-scope).
    - User-observable behavior, validation rules, error/empty/loading UX states, and testable acceptance criteria.
    - High-level domain/UX conventions for `AGENTS.md`.
- **Affected Components**:
  - `role-product-manager/SKILL.md` (Operating principles, Boundaries table, Minimalist Spec template)

---

### FB-09: PM Synchronizes Issue Title with Feature Name
- **Problem**: Incoming issues often have vague, informal, or placeholder titles. Currently, `role-product-manager` generates a `# [Feature Name]: Specification` top-level header inside the issue body, but leaves the GitHub issue title untouched.
- **Proposed Solution**:
  - `role-product-manager` must autonomously refine and set the GitHub issue title to match the formalized feature name:
    `gh issue edit <ISSUE_NUMBER> --title "<Feature Title>" --body-file -`
  - Ensures clean project board cards and consistent branch naming downstream (`feat/<issue-num>-<slug>`).
- **Affected Components**:
  - `role-product-manager/SKILL.md` (Autonomous Decisions, GitHub Issue Synchronization Procedure)
  - `README.md`, `instruction.md` (PM loop prompts)

---

### FB-10: Architect Proposals for AGENTS.md Conventions
- **Problem**: When `role-architect` identifies architectural guardrails, contract deduplication rules, or modular boundaries during plan review, there was no standardized format in the review comment for proposing additions to `AGENTS.md`. Implementer and Code Reviewer only tracked PM proposals.
- **Proposed Solution**:
  - `role-architect` includes an explicit `#### Proposed AGENTS.md Additions` block in its architecture review comments when reusable patterns or guardrails are identified.
  - `role-architect/SKILL.md` documents `AGENTS.md Harvesting` under Autonomous Decisions and in the approval comment template.
  - `role-implementer` incorporates conventions from both PM spec and Architect comments into `AGENTS.md` in the PR branch.
  - `role-code-reviewer` audits all proposed conventions (PM + Architect) in the PR diff.
- **Affected Components**:
  - `role-architect/SKILL.md` (Autonomous Decisions, Case B Review Template)
  - `role-implementer/SKILL.md` (Step 4 AGENTS.md update scope)
  - `role-code-reviewer/SKILL.md` (Checklist AGENTS.md audit)
  - `AGENTS.md` (Section 6 Continuous Improvement Engine)

---

## 6. Token Conservation & Cost Optimization

### FB-11: Zero-Token Script Gatekeeper (`poll-project.sh --auto-bounce-ci`)
- **Problem**: Reviewer and QA subagents wake up via poller just to inspect failing remote PR checks and immediately bounce to Implementer, burning thousands of LLM input tokens on useless turns.
- **Proposed Solution**:
  - Add `--auto-bounce-ci` to `tools/poll-project.sh`.
  - When polling for review/QA, poller checks `gh pr checks` in pure bash before exiting.
  - If checks are failing, poller auto-comments failure on the PR, moves card back to `Implementer`, and continues polling.
  - 0 LLM tokens burned on broken PRs.
- **Affected Components**: `tools/poll-project.sh`, `README.md`, `instruction.md`

### FB-12: Silent Command Execution for Implementer
- **Problem**: Running unit tests and linters dumps thousands of tokens of passing logs into model context.
- **Proposed Solution**:
  - Run tests and linters in quiet mode: `npm test -- --silent > /dev/null 2>&1 || npm test -- --onlyFailures`.
  - Passing runs output 0 tokens; failures capture only failing assertions.
- **Affected Components**: `.agents/skills/role-implementer/SKILL.md`, `instruction.md`

### FB-13: Diff Windowing & Lockfile Exclusions for Reviewer
- **Problem**: Full `git diff origin/master` dumps thousands of tokens of unchanged context and massive machine-generated lockfiles into model context.
- **Proposed Solution**:
  - Reviewer surveys `git diff --stat origin/master` first (~150 tokens).
  - Reviewer inspects diff with lockfile exclusions: `git diff origin/master -- . ':!*-lock.json' ':!*.lock'`.
- **Affected Components**: `.agents/skills/role-code-reviewer/SKILL.md`, `instruction.md`

### FB-14: Compact Match Banner (`poll-project.sh --compact`)
- **Problem**: Default poller match output prints an 8-line banner into subagent transcript on every wakeup.
- **Proposed Solution**: Add `--compact` (`-q`) flag printing a single-line match summary: `[poll-project] MATCH: #42 "Title" (Status: PM, ID: PVTI_...)`.
- **Affected Components**: `tools/poll-project.sh`, `README.md`, `instruction.md`

### FB-16: Ponytail Anti-Overengineering Reduction Ladder Integration
- **Problem**: Autonomous agents often over-engineer solutions, introducing speculative abstraction layers, gratuitous helper utilities, or new third-party packages when standard libraries or existing code already solve the problem.
- **Proposed Solution**:
  - Incorporate Dietrich Gebert's **Ponytail Reduction Ladder** directly into repository pillars and role skills:
    1. *Does this need to exist?* (YAGNI).
    2. *Is it already in this codebase?* (Reuse existing services/DTOs/utilities).
    3. *Does the standard library handle it?* (Built-in language runtime features).
    4. *Does the native platform/browser handle it?* (Native OS/browser capabilities).
    5. *Is it in an already installed dependency?* (Never add new packages without explicit reason).
    6. *Can it be written in a few clean lines?*
    7. *Only then*: Author minimal code.
  - Enforce in `AGENTS.md` (Pillar 5), `role-senior-developer/SKILL.md` (plan generation), `role-implementer/SKILL.md` (coding), and `role-architect/SKILL.md` (audit criteria).
- **Affected Components**: `AGENTS.md`, `role-senior-developer/SKILL.md`, `role-implementer/SKILL.md`, `role-architect/SKILL.md`

---

## Batch Implementation Tracker

| ID | Title | Priority | Status |
| :--- | :--- | :---: | :---: |
| **FB-01** | Manual Implementation Gate (`Ready` status between Architect & Implementer) | High | ✅ Implemented |
| **FB-02** | Implementer Green PR Checks Gate before Code Review | High | ✅ Implemented |
| **FB-03** | Reviewer & QA CI Offloading (Check status inspection vs local re-runs) | Medium | ✅ Implemented |
| **FB-04** | Redefined QA Responsibilities (Coverage Audit & Live UX / Look-and-Feel) | High | ✅ Implemented |
| **FB-05** | Compact Technical Plans with `<details>` Expandable Blocks | Medium | ✅ Implemented |
| **FB-06** | Code Reviewer Focus: Feature Fidelity, Code Quality & Anti-Duplication | High | ✅ Implemented |
| **FB-07** | Closed-Loop AGENTS.md Evolution (Implementer Updates, Reviewer Verifies) | High | ✅ Implemented |
| **FB-08** | PM High-Level Focus (Strict ban on file paths and technical implementation) | High | ✅ Implemented |
| **FB-09** | PM Synchronizes Issue Title with Feature Name (`gh issue edit --title`) | Medium | ✅ Implemented |
| **FB-10** | Architect AGENTS.md Proposals (Guardrails codified in approval comment) | Medium | ✅ Implemented |
| **FB-11** | Zero-Token Script Gatekeeper (`poll-project.sh --auto-bounce-ci`) | High | ✅ Implemented |
| **FB-12** | Silent Command Execution (`pass = 0 tokens`) for Implementer | High | ✅ Implemented |
| **FB-13** | Diff Windowing & Lockfile Exclusions for Code Reviewer | Medium | ✅ Implemented |
| **FB-14** | Compact Match Banner (`poll-project.sh --compact`) | Medium | ✅ Implemented |
| **FB-15** | Session Context Hygiene & Reset Architecture (`instruction.md`) | High | ✅ Implemented |
| **FB-16** | Ponytail Anti-Overengineering Reduction Ladder Integration | High | ✅ Implemented |








