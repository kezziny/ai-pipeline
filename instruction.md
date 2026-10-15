# Autonomous Agent Pipeline Setup & Orchestration Guide (`instruction.md`)

This document provides step-by-step instructions for an AI agent to import the multi-agent development pipeline assets into any target repository, configure GitHub Projects v2, and launch all 6 specialized worker roles concurrently as background subagents running reactive polling loops.

---

## 1. Architecture Overview

The pipeline automates end-to-end software delivery across GitHub Projects v2:
```
Backlog (Human Triage)
  └──> PM (role-product-manager)
        └──> Senior Dev (role-senior-developer)
              └──> Architect (role-architect)
                    └──> Ready (Implementation Backlog Buffer)
                          └──> Implementer (role-implementer)
                                └──> Code Review (role-code-reviewer -> Top Swimlane Human Sign-off)
                                      └──> QA (role-qa-engineer -> Playwright UX & Merge)
                                            └──> Done
```
- **Columns (`Status`)**: `Backlog`, `PM`, `Senior Dev`, `Architect`, `Ready`, `Implementer`, `Code Review`, `QA`, `Done`.
- **Swimlanes (`Attention`)**: `Needs Decision` (Top swimlane for human blockers/reviews) vs `Standard` (Autonomous).
- **Reactive Polling & Rate-Limit Protection**: Background workers sleep inside `tools/poll-project.sh` (default interval: 30s). All concurrent subagents share a local cache (`/tmp/gh-project-cache-<owner>-<num>.json` with 25s TTL and file-locking), collapsing 6 agent queries into 1 single API call per cycle and auto-sleeping if GraphQL quota drops below 200 points. State transitions via `tools/project-move.sh` automatically invalidate the cache for instant detection.

---

## 2. Phase 1: Asset Import

If bootstrapping a target repository from `kezziny/ai-pipeline`:

### 2.1 Copy Required Directories & Files
From the `ai-pipeline` template root, copy the following assets into the target project root:
- `.agents/skills/` (all 6 role skills)
- `tools/` (`poll-project.sh`, `project-move.sh`, `verify-roles.sh`, `test-pipeline-tools.sh`, `poll-issues.sh`)
- `AGENTS.md` (repository standards and guardrails)
- `.project-config.example.json`

```bash
# Example shell commands to import from a local clone of ai-pipeline:
cp -r /path/to/ai-pipeline/.agents/skills .agents/skills
cp -r /path/to/ai-pipeline/tools tools
cp /path/to/ai-pipeline/AGENTS.md AGENTS.md
cp /path/to/ai-pipeline/.project-config.example.json .project-config.example.json
chmod +x tools/*.sh
```

### 2.2 Verify Installed Taxonomy & Scripts
Run the automated verification suite to ensure all skills, trigger guards, and CLI tools are intact:
```bash
./tools/verify-roles.sh
```
Expected output: `SUCCESS: All pipeline role specifications passed verification! (Status: 0)`.

---

## 3. Phase 2: GitHub Project & Environment Setup

### 3.1 Verify GitHub CLI Authentication
Ensure `gh` is authenticated and has the `project` scope:
```bash
gh auth status
```
*If `project` scope is missing, refresh token scopes:*
```bash
gh auth refresh -s project
```

### 3.2 Configure Project Board Fields (GitHub Web UI)
1. In the target organization or user account, create a **GitHub Project (v2)** (Board view).
2. Configure the default **`Status`** single-select field with these exact options:
   - `Backlog` *(Default column)*
   - `PM`
   - `Senior Dev`
   - `Architect`
   - `Ready` *(Implementation backlog / manual gate)*
   - `Implementer`
   - `Code Review`
   - `QA`
   - `Done`
3. Add a custom single-select field named **`Attention`** with options:
   - `Needs Decision` *(Color: Red or Orange)*
   - `Standard` *(Color: Gray or Blue)*
4. Set Board Layout to **Group by: `Attention`** with `Needs Decision` pinned at the top.
5. In Project Settings -> **Workflows** -> Enable **Auto-add to project** for the target repository with defaults: `Status: Backlog`, `Attention: Standard`.

### 3.3 Configure Local Project Configuration
Create `.project-config.json` in the target repository root:
```json
{
  "owner": "<GITHUB_OWNER_OR_ORG>",
  "projectNumber": <PROJECT_NUMBER>,
  "statusFieldName": "Status",
  "attentionFieldName": "Attention"
}
```
*Tip: You can test the configuration by querying the project:*
```bash
./tools/poll-project.sh --status "Backlog" --interval 2
# Press Ctrl+C to abort test
```

---

## 4. Phase 3: Launching Pipeline Roles as Background Subagents

To initiate the autonomous pipeline, the orchestrating AI executes a single `invoke_subagent` call launching all 6 worker subagents concurrently.

### 4.1 Subagent Model Selection Matrix

When delegating roles via `invoke_subagent`, match each role's cognitive demands to the optimal model tier:

| Role | Recommended Model | Cognitive Profile & Justification | Cost/Speed Alternative |
| :--- | :---: | :--- | :---: |
| **`role-product-manager`** | `flash` | **Document structuring & scope triage**: Formulates functional specifications, acceptance criteria, and domain conventions from prompts. `flash` offers fast turnaround and low token usage for structured text work. | `pro` *(if complex user journey analysis)* |
| **`role-senior-developer`** | `pro` | **Multi-file synthesis & API design**: Deep codebase reconnaissance, cross-module DTO design, method signature contracts, and backward-compatibility analysis require deep reasoning. | `inherit` |
| **`role-architect`** | `pro` | **Critical gatekeeping & fault analysis**: Scrutinizes design plans against modular decoupling, concurrency, and leak-free resource lifecycle. Requires highest discernment to detect subtle architectural anti-patterns. | `inherit` |
| **`role-implementer`** | `pro` | **Multi-file code authoring & debugging**: Handles complex TypeScript/Python implementation, git worktree rebase operations, compiler errors, and unit test regressions. `pro` is essential for clean code synthesis. | `inherit` |
| **`role-code-reviewer`** | `pro` | **Adversarial diff audit & security inspection**: Rigorous pull request diff analysis, catching edge cases, memory leaks, security escapes, and architectural regressions. `flash` risks overlooking subtle bugs. | `inherit` |
| **`role-qa-engineer`** | `pro` | **E2E test authoring & UX validation**: Authoring robust Playwright selectors and interpreting complex DOM failure traces requires `pro`. | `flash` *(if only executing pre-built test suites)* |

---

### 4.2 Orchestrator Subagent Dispatch (`invoke_subagent`)

Call the `invoke_subagent` tool with the following payload:

```json
{
  "Subagents": [
    {
      "TypeName": "self",
      "Role": "Product Manager Worker",
      "Model": "flash",
      "Prompt": "You are operating as the autonomous Product Manager (role-product-manager). Read and follow instructions in .agents/skills/role-product-manager/SKILL.md.\n\nYou must run in an infinite autonomous loop:\n1. Run `./tools/poll-project.sh --status \"PM\" --attention \"Standard\"` and wait for completion.\n2. When an issue matches, inspect the issue description and requirements.\n3. Formulate the functional specification (Summary, Scope, Functional Requirements, Proposed AGENTS.md Additions).\n4. Update the issue body via `gh issue edit <NUM> --body-file -`.\n5. If requirements are ambiguous or decisions needed, comment questions and run `./tools/project-move.sh <NUM> --attention \"Needs Decision\"`.\n6. When requirements are fully defined, hand off to Senior Dev: `./tools/project-move.sh <NUM> --status \"Senior Dev\" --attention \"Standard\"`.\n7. Immediately restart loop at Step 1."
    },
    {
      "TypeName": "self",
      "Role": "Senior Developer Worker",
      "Model": "pro",
      "Prompt": "You are operating as the autonomous Senior Developer & Tech Lead (role-senior-developer). Read and follow instructions in .agents/skills/role-senior-developer/SKILL.md.\n\nYou must run in an infinite autonomous loop:\n1. Run `./tools/poll-project.sh --status \"Senior Dev\" --attention \"Standard\"` and wait for completion.\n2. When an issue matches, explore the codebase to maximize existing code reuse (services, DTOs, utilities).\n3. Draft a concrete implementation plan with exact file paths, method signatures, shared contracts, regression blast radius, and unit test strategy.\n4. Append the implementation plan to the GitHub issue body.\n5. If technical trade-offs require human consultation, comment questions and run `./tools/project-move.sh <NUM> --attention \"Needs Decision\"`.\n6. When technical plan is ready, hand off to Architect: `./tools/project-move.sh <NUM> --status \"Architect\" --attention \"Standard\"`.\n7. Immediately restart loop at Step 1."
    },
    {
      "TypeName": "self",
      "Role": "Software Architect Worker",
      "Model": "pro",
      "Prompt": "You are operating as the autonomous Software Architect (role-architect). Read and follow instructions in .agents/skills/role-architect/SKILL.md.\n\nYou must run in an infinite autonomous loop:\n1. Run `./tools/poll-project.sh --status \"Architect\" --attention \"Standard\"` and wait for completion.\n2. When an issue matches, audit the implementation plan against the 4 pillars (Modularity, Data Models & DTOs, Resource Management, Security & Robustness).\n3. If revisions are required, post structured feedback comment and return: `./tools/project-move.sh <NUM> --status \"Senior Dev\" --attention \"Standard\"`.\n4. If fundamental architectural conflict exists, comment and run `./tools/project-move.sh <NUM> --attention \"Needs Decision\"`.\n5. If plan satisfies all gates, post approval comment and hand off to Ready backlog: `./tools/project-move.sh <NUM> --status \"Ready\" --attention \"Standard\"`.\n6. Immediately restart loop at Step 1."
    },
    {
      "TypeName": "self",
      "Role": "Implementer Worker",
      "Model": "pro",
      "Prompt": "You are operating as the autonomous Issue Implementer (role-implementer). Read and follow instructions in .agents/skills/role-implementer/SKILL.md.\n\nYou must run in an infinite autonomous loop:\n1. Run `./tools/poll-project.sh --status \"Implementer\" --attention \"Standard\"` and wait for completion.\n2. When an issue matches, check if branch/PR already exists (`gh pr list --search \"<NUM>\"`). Inspect any existing review or QA comments.\n3. Create or checkout isolated worktree in `.worktrees/issue-<NUM>` on branch `feature/<NUM>-<slug>`.\n4. Implement code and unit tests adhering strictly to the issue plan and AGENTS.md. Apply PM's proposed AGENTS.md conventions in your branch diff. Address all review/QA comments.\n5. Run local quality gates (linting, tests, build) inside the worktree.\n6. Push commits, watch remote PR checks (`gh pr checks <PR_NUM> --watch`), ensure PR is open (`gh pr ready <PR_NUM>`), remove temporary worktree, and advance status: `./tools/project-move.sh <NUM> --status \"Code Review\" --attention \"Standard\"`.\n7. Immediately restart loop at Step 1."
    },
    {
      "TypeName": "self",
      "Role": "Code Reviewer Worker",
      "Model": "pro",
      "Prompt": "You are operating as the autonomous AI Code Reviewer (role-code-reviewer). Read and follow instructions in .agents/skills/role-code-reviewer/SKILL.md.\n\nYou must run in an infinite autonomous loop:\n1. Run `./tools/poll-project.sh --status \"Code Review\" --attention \"Standard\"` and wait for completion.\n2. When an issue matches, check remote PR checks (`gh pr checks <PR_NUM>`). If red, immediately comment failing checks and return to Implementer: `./tools/project-move.sh <NUM> --status \"Implementer\" --attention \"Standard\"`.\n3. If PR checks are green, mount into `.worktrees/review-pr-<PR_NUM>` and audit the diff (spec fidelity to PM acceptance criteria, code craftsmanship, DRY anti-duplication, AGENTS.md additions).\n4. If fixes needed, post review comments on PR and return to Implementer: `./tools/project-move.sh <NUM> --status \"Implementer\" --attention \"Standard\"`.\n5. If code passes all standards, submit approving review (`gh pr review --approve`), undraft PR (`gh pr ready`), cleanup worktree, and elevate to top swimlane for human sign-off: `./tools/project-move.sh <NUM> --status \"Code Review\" --attention \"Needs Decision\"`.\n6. Immediately restart loop at Step 1."
    },
    {
      "TypeName": "self",
      "Role": "QA Engineer Worker",
      "Model": "pro",
      "Prompt": "You are operating as the autonomous Lead QA Engineer (role-qa-engineer). Read and follow instructions in .agents/skills/role-qa-engineer/SKILL.md.\n\nYou must run in an infinite autonomous loop:\n1. Run `./tools/poll-project.sh --status \"QA\" --attention \"Standard\"` and wait for completion.\n2. When an issue matches (signaling human review approval), check remote PR checks (`gh pr checks <PR_NUM>`). If red, immediately reject back to Implementer: `./tools/project-move.sh <NUM> --status \"Implementer\" --attention \"Standard\"`.\n3. Mount PR in isolated worktree `.worktrees/qa-pr-<PR_NUM>`.\n4. Audit test coverage adequacy against PM acceptance criteria, and conduct live interactive Playwright UX testing.\n5. If QA passes: post QA report, merge PR (`gh pr merge <PR_NUM> --rebase --delete-branch`), and move to Done: `./tools/project-move.sh <NUM> --status \"Done\" --attention \"Standard\"`.\n6. If QA fails: post traces/logs on PR, and route back based on defect cause (`Implementer`, `Senior Dev`, or `PM`).\n7. Clean up worktree and immediately restart loop at Step 1."
    }
  ]
}
```

---

## 5. Phase 4: Operational Monitoring & Lifecycle Management

### 5.1 Monitoring Subagents
To inspect active worker subagents and check their state:
- Use `manage_subagents` with `Action: "list"`.
- Each subagent will show either `running` (waiting on `poll-project.sh` or executing a task) or `waiting_for_message`.

### 5.2 Triggering Work & Managing the Backlog
1. Human opens a GitHub Issue -> GitHub Project auto-adds it to **`Backlog`**.
2. When ready, Human drags the issue card from **`Backlog`** to **`PM`** (with `Attention: Standard`).
3. The `Product Manager Worker` wakes up automatically, clarifies requirements, and hands off to `Senior Dev` -> `Architect` -> **`Ready`**.
4. The **`Ready`** column holds implementation-ready tasks as a buffer. When ready to implement, human (or automated dispatch) moves card to **`Implementer`** to initiate coding.

### 5.3 Responding to Human Intervention
1. When an agent requires clarification or human review sign-off, the card moves to **`Attention: Needs Decision`** (top swimlane).
2. Human inspects the issue or PR, answers questions or reviews code:
   - For PM / Dev questions: Human replies in issue comments, drags card back to `Attention: Standard`.
   - For Code Review: Human verifies PR, drags card to column **`QA`** with `Attention: Standard`.
3. The target role immediately detects the change and resumes autonomous processing.

---

## 6. Self-Verification Checklist for AI Orchestrators

Before considering pipeline deployment complete, verify:
- [ ] `./tools/verify-roles.sh` passes with exit code `0`.
- [ ] `./tools/test-pipeline-tools.sh` passes 21/21 checks.
- [ ] `.project-config.json` exists and matches target owner and project number.
- [ ] All 6 subagents are launched via `invoke_subagent` and running background polling.
- [ ] Dragging a test issue from `Backlog` to `PM` wakes up the `Product Manager Worker`.
