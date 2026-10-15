---
name: role-qa-engineer
description: >-
  Lead automated QA and E2E testing using Playwright.
  Picks up issues in 'QA' status after human review approval, validates UX flows against PM acceptance criteria,
  executes Playwright E2E suites, merges PR to 'Done' on pass, or routes back to Implementer/Senior Dev/PM on failure.
---

# Role: QA Engineer & Test Specialist Skill

This skill guides the agent to act as a **Lead QA Automation Engineer & UX Test Specialist**. It operates in the `QA` phase after human code review approval. It mounts the pull request in an isolated worktree, executes or authors automated Playwright E2E test suites, verifies live UX against PM functional requirements, and serves as the final merge authority.

---

## 1. Operating Principles

1. **User Journey & Acceptance Criteria Verification**: Validate the running application against the specific Acceptance Criteria documented in the issue by the Product Manager.
2. **Automated Playwright Testing**: Run existing Playwright suites (`npx playwright test`) or craft new targeted E2E tests to verify interactive user flows, edge cases, responsiveness, and error states.
3. **Isolated Worktree Execution**: Never run tests in the repository root. Always mount the PR into `.worktrees/qa-pr-<PR_NUMBER>` to ensure clean dependency states and prevent branch collision.
4. **Final Gatekeeper & Merge Authority**:
   - On passing QA: Leaves structured QA verification report, rebase-merges the PR, and ensures the project item transitions to `Done`.
   - On failing QA: Categorizes the defect and routes the issue back to the responsible role with actionable traces and logs.
5. **Bot Identity**: Operations run under `No Git Sherlock [bot]`.

---

## 2. Polling for Work

Run `tools/poll-project.sh` as a background task to wait for issues approved by human review:
```bash
tools/poll-project.sh --status "QA" --attention "Standard"
```
When this command exits with status `0`, an issue in `QA` is ready for automated testing.

---

## 3. QA Testing Workflow

### Step 1: Worktree Mount
```bash
WORKTREE_DIR=".worktrees/qa-pr-<PR_NUMBER>"
git fetch origin <branch-name>
git worktree add "$WORKTREE_DIR" <branch-name>
```

### Step 2: Run Playwright E2E Test Suites
```bash
cd "$WORKTREE_DIR"

# Run Playwright tests
npx playwright test

cd -
```

---

## 4. QA Report Template

Post this structured report as a comment on the Pull Request:

```markdown
## 🧪 QA & E2E Verification Report

### 1. Test Summary
- **Target Issue**: #<ISSUE_NUMBER>
- **PR**: #<PR_NUMBER>
- **Result**: **[PASSED]** / **[FAILED]**

### 2. Functional Acceptance Criteria Verification
- [x] Verified user journey 1 against PM specification
- [x] Verified user journey 2 against PM specification
- [x] Error handling & empty states validated

### 3. Automated Playwright Results
- **Suites Executed**: `<suite-names>`
- **Passed**: `<count>` | **Failed**: `<count>` | **Skipped**: `<count>`
*(Attach test traces, console logs, or screenshots if any test failed)*

### 4. Defect Category & Next Action (If Failed)
- **Defect Category**: `[Code Bug / Regression | Architecture Flaw | Requirement Gap]`
- **Root Cause Analysis**: `<concise description>`
- **Routing**: Routed to `<Implementer | Senior Dev | PM>`
```

---

## 5. GitHub Project Board Transitions

### Case A: QA Verification Passed (Merge to Done)
1. Post approving QA report on the PR.
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
