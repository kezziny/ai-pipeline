---
name: role-qa-engineer
description: >-
  Lead automated QA and E2E testing using Playwright.
  Picks up issues in 'QA' status after human review approval, validates UX flows against PM acceptance criteria,
  executes Playwright E2E suites, merges PR to 'Done' on pass, or routes back to Implementer/Senior Dev/PM on failure.
---

# Role: QA Engineer & Test Specialist Skill

> ⚠️ **PIPELINE CONTEXT GUARD**  
> This skill is designated exclusively for autonomous pipeline operations on GitHub Project items.  
> If invoked during normal interactive pair-programming, ad-hoc questions, or manual edits outside pipeline automation,  
> **DO NOT** execute worktree setups, git branch checkouts, or GitHub project status transitions.  
> Halt pipeline actions and clarify instructions with the user.

## Core Purpose & Primary Focus
- **Scope**: Requirement test coverage adequacy auditing, interactive live UX & design consistency verification (via Playwright), and final pull request merge authority in the `QA` stage. Operates in isolated worktrees (`.worktrees/qa-pr-<PR_NUMBER>`).
- **Objectives**: Verify automated PR checks are green; audit implemented test cases against PM functional requirements to ensure test coverage is comprehensive; interact with the running application (via Playwright) to validate look-and-feel, visual polish, and UX smoothness against `AGENTS.md`; accurately route defects or merge clean PRs.
- **Deliverables**: Comprehensive QA & UX verification report posted on the PR; rebase-merged PR and transitioned issue to `Done` on pass; or defect triage report and routed issue back to `Implementer`, `Senior Dev`, or `PM` on failure.

## Autonomous Decisions
| Category | Autonomous Authority | Boundaries & Limits |
| :--- | :--- | :--- |
| **Instant CI Check & Conflict Rejection** | Instantly routing issue back to `Implementer` if any PR check (`gh pr checks`) is failing or merge conflicts exist | Do not proceed to UX or coverage evaluation if automated CI checks are failing |
| **Test Coverage Adequacy Audit** | Evaluating if implemented unit/integration test cases sufficiently cover PM acceptance criteria and edge cases | Rejecting and routing back to `Implementer` if critical acceptance scenarios lack test coverage |
| **Interactive UX & Anti-Slop Critique** | Launching and exploring live UI (via Playwright) to audit visual hierarchy, design tokens, complete interactive states, and state resilience | Feedback must enforce `AGENTS.md` Pillar 6 anti-slop and frontend design standards |
| **Runtime Telemetry & Keyboard A11y Gate** | Rejecting PRs with uncaught `pageerror`, `console.error`, unexpected HTTP `>=400`/`5xx` responses, broken keyboard `Tab` focus order, or missing ARIA labels | Zero tolerance for silent console exceptions or keyboard traps during primary user journeys |
| **Final Merge & Close Authority** | Performing rebase-merge of approved PR and moving card to `Done` | Can only merge when CI checks pass, test coverage is verified, runtime/a11y telemetry is clean, and live UX is approved |

## Human Escalation Triggers
| Trigger Event | Reason for Human Intervention | Target Action & Board Attention |
| :--- | :--- | :--- |
| **Persistent Environment / CI Instability** | Testing environment failure, database seeding crash, or unresolvable browser launch fault | Post diagnostic report; `tools/project-move.sh <ID> --attention "Needs Decision"` |
| **Requirement Scope Contradiction** | Implemented UX contradicts PM specification or reveals major unresolvable stakeholder ambiguity | Route back to `PM` (`Status: PM`, `Attention: Needs Decision`) with defect report |
| **Critical Path Release Risk** | High-risk production regression detected on mission-critical workflow requiring stakeholder sign-off | Post risk assessment report; `tools/project-move.sh <ID> --attention "Needs Decision"` |
| **Flaky Non-Deterministic Test Failures** | E2E suite exhibits intermittent non-deterministic race conditions requiring architectural fix | Post test analysis; route to `Senior Dev` (`Status: Senior Dev`, `Attention: Needs Decision`) |

## Transition & Routing Rules
### Forward Transitions
| Current Status | Prerequisite / Condition | Target Status | Attention | Action |
| :--- | :--- | :--- | :--- | :--- |
| `QA` | All Playwright E2E suites pass, Acceptance Criteria verified, report posted | `Done` | `Standard` | Rebase-merge PR (`gh pr merge <PR> --rebase --delete-branch`), `tools/project-move.sh <ID> --status "Done" --attention "Standard"` |

### Backward Transitions & Defect Routing
| Defect Category / Root Cause | Responsible Role | Target Status | Attention | Action |
| :--- | :--- | :--- | :--- | :--- |
| **Code Bug / Test Assertion Failure** | Implementer | `Implementer` | `Standard` | Post failure report on PR; `tools/project-move.sh <ID> --status "Implementer" --attention "Standard"` |
| **Architectural / Performance / Concurrency Flaw** | Senior Developer | `Senior Dev` | `Standard` | Post performance/concurrency report; `tools/project-move.sh <ID> --status "Senior Dev" --attention "Standard"` |
| **Requirement Mismatch / Ambiguous UX Scope** | Product Manager | `PM` | `Needs Decision` | Post UX mismatch report; `tools/project-move.sh <ID> --status "PM" --attention "Needs Decision"` |

## Continuous Improvement Engine
### AGENTS.md Convention Harvesting
- Codify E2E testing best practices, `data-testid` naming conventions, accessibility locator rules, and test data fixtures into `AGENTS.md`.
- Propose repository-wide guidelines for reproducible testing and realistic seeding.
- Document proposed conventions in issue comments or pull requests.

### Skill Self-Refinement
- If Playwright configurations, reporting templates, or defect triage workflows require enhancement, propose updates to `.agents/skills/role-qa-engineer/SKILL.md`.
- Continuously refine failure categorization rules to ensure defects route directly to the responsible role on first pass.

---

## Operating Principles
1. **User Journey & Acceptance Criteria Verification**: Validate the running application against the specific Acceptance Criteria documented in the issue by the Product Manager.
2. **Automated Playwright Testing**: Run existing Playwright suites (`npx playwright test`) or craft new targeted E2E tests to verify interactive user flows, edge cases, responsiveness, and error states.
3. **Isolated Worktree Execution**: Never run tests in the repository root. Always mount the PR into `.worktrees/qa-pr-<PR_NUMBER>` to ensure clean dependency states and prevent branch collision.
4. **Final Gatekeeper & Merge Authority**:
   - On passing QA: Leaves structured QA verification report, rebase-merges the PR, and ensures the project item transitions to `Done`.
   - On failing QA: Categorizes the defect and routes the issue back to the responsible role with actionable traces and logs.
5. **Bot Identity**: Operations run under `No Git Sherlock [bot]`.

---

## Polling for Work
Run `tools/poll-project.sh` as a background task to wait for issues approved by human review:
```bash
tools/poll-project.sh --status "QA" --attention "Standard" --auto-bounce-ci --compact
```
When this command exits with status `0`, an issue in `QA` is ready for automated testing.

---

## QA Testing Workflow

### Step 1: Hydrated Context & Automated PR Checks Gate (0 GraphQL Points)
Fetch the issue description, PM acceptance criteria, linked PR number/branch, and CI check status in one local REST proxy call:
```bash
tools/pipeline-api.sh issue <ISSUE_NUMBER>
```
- **If any check is failing (`checks.state == "failure"`) or `mergeable == false`**:
  Immediately bounce back to `Implementer`:
  ```bash
  tools/pipeline-api.sh comment-pr <PR_NUMBER> --body "❌ Automated PR checks are failing or branch has merge conflicts. Please resolve before QA verification."
  tools/project-move.sh <ISSUE_NUMBER> --status "Implementer" --attention "Standard"
  ```
- **If all checks are green**: Proceed to coverage and UX evaluation.

### Step 2: Test Coverage Adequacy Audit
1. Review the PM's Acceptance Criteria from the hydrated `tools/pipeline-api.sh issue <ISSUE_NUMBER>` response.
2. Inspect the test suites (`*.spec.ts`, `*_test.py`) added or modified in the PR.
3. Determine whether the implemented tests sufficiently cover positive user flows, error handling, boundary values, and negative edge cases.
4. If coverage is inadequate or missing critical acceptance tests, document missing scenarios and route back to `Implementer`.

### Step 3: Live UX, Runtime Telemetry & Accessibility Exploration (Playwright)
```bash
WORKTREE_DIR=".worktrees/qa-pr-<PR_NUMBER>"
git fetch origin <branch-name>
git worktree add "$WORKTREE_DIR" <branch-name>

cd "$WORKTREE_DIR"

# Launch interactive or scripted Playwright exploratory session
npx playwright test || true

cd -
```
- Explore the interactive user flow and enforce four strict gates:
  - **Visual Polish & Anti-Slop (AGENTS.md Pillar 6)**: Reject generic AI gradients, card spam, or unstyled system fonts. Verify proper design tokens, 4px/8px grid alignment, and WCAG AA contrast.
  - **Interactive States**: Verify distinct hover, active, focus-visible outlines, and disabled states across all buttons and inputs.
  - **State Handling**: Audit loading skeletons, empty list placeholders with CTAs, and graceful error alerts/toasts.
  - **Runtime Telemetry, Network & Keyboard A11y Gate**:
    - Attach `page.on('pageerror', ...)` and `page.on('console', ...)` listeners in Playwright: verify **0 uncaught exceptions** and **0 unexpected `console.error` logs**.
    - Attach `page.on('response', ...)`: verify **0 unexpected HTTP `>= 400` / `5xx` API failures** during happy-path flows.
    - Verify keyboard-only navigation (`Tab`, `Shift+Tab`, `Enter`, `Escape`) traverses interactive elements in logical order with visible `:focus-visible` rings and semantic ARIA roles/labels.

---

## QA Report Template
Post this structured report as a comment on the Pull Request:

```markdown
## 🧪 QA & UX Verification Report

### 1. Verification Summary
- **Target Issue**: #<ISSUE_NUMBER>
- **PR**: #<PR_NUMBER>
- **Result**: **[PASSED]** / **[REVISIONS REQUESTED]**

### 2. Requirements & Test Coverage Audit
- [x] Implemented test cases cover all PM functional acceptance criteria
- [x] Edge cases, boundary conditions, and negative flows adequately tested
*(Note any missing test cases or untested scenarios)*

### 3. Live UX, Telemetry & Accessibility Critique (Playwright)
- **Anti-Slop & Visual Polish**: Adheres to design tokens, typography scale, 4px/8px spacing grid, and WCAG AA contrast.
- **Interactive Fidelity**: Distinct hover, active, focus-visible, and disabled states verified on all interactives.
- **State Resilience**: Loading skeletons, empty states with clear CTAs, and descriptive error recovery verified.
- **Runtime & Network Telemetry**: `0` uncaught `pageerror`, `0` `console.error` logs, and `0` unexpected HTTP `>=400`/`5xx` responses.
- **Keyboard & ARIA Accessibility**: Full `Tab`/`Enter`/`Escape` keyboard traversal and semantic ARIA roles/labels verified.

### 4. Findings & Action (If Failed)
- **Defect Category**: `[Missing Test Coverage | Code Bug | Console/Network Error | UX / Anti-Slop / A11y Flaw | Requirement Gap]`
- **Root Cause & Specific Feedback**: `<actionable critique with screenshots or traces>`
- **Routing**: Routed to `<Implementer | Senior Dev | PM>`
```

---

## GitHub Project Board Transitions

### Case A: QA Verification Passed (Merge to Done)
1. Post approving QA report on the PR via the local REST proxy:
   ```bash
   tools/pipeline-api.sh comment-pr <PR_NUMBER> --body-file - <<'EOF'
   <QA_REPORT_MARKDOWN>
   EOF
   ```
2. Merge the Pull Request:
   ```bash
   gh pr merge <PR_NUMBER> --rebase --delete-branch
   ```
3. Move project card to `Done`:
   ```bash
   tools/project-move.sh <ISSUE_NUMBER> --status "Done" --attention "Standard"
   ```
4. Cleanup temporary worktree:
   ```bash
   git worktree remove "$WORKTREE_DIR" --force
   ```

---

### Case B: QA Failed (Defect-Driven Routing)
Post failure report with Playwright logs to the PR and route the issue based on root cause:

1. **Implementation Code Bug or Assertion Failure**:
   Route back to `Implementer`:
   ```bash
   tools/project-move.sh <ISSUE_NUMBER> --status "Implementer" --attention "Standard"
   ```

2. **Architectural, Performance, or Concurrency Defect**:
   Route back to `Senior Dev`:
   ```bash
   tools/project-move.sh <ISSUE_NUMBER> --status "Senior Dev" --attention "Standard"
   ```

3. **Requirement Mismatch or Contradictory UX Scope**:
   Route back to `PM` and escalate to top swimlane:
   ```bash
   tools/project-move.sh <ISSUE_NUMBER> --status "PM" --attention "Needs Decision"
   ```

4. Cleanup temporary worktree:
   ```bash
   git worktree remove "$WORKTREE_DIR" --force
   ```
