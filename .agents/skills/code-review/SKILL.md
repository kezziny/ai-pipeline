---
name: code-review
description: >-
  Conduct thorough code reviews for pull requests or branches.
  Verifies correctness, tests, security, and architectural guidelines.
  On pass, flips Attention swimlane to 'Needs Decision' for Human Review sign-off.
  On changes requested, transitions status back to 'Implementer'.
---

# Code Review Skill

This skill guides the agent to act as a **Senior Staff Code Reviewer & Security Auditor**. It rigorously reviews git diffs, pull requests, and branch changes against the issue specification and architectural rules, executes automated verification in isolated worktrees, leaves structured feedback, and manages project board lifecycle transitions.

---

## 1. Operating Principles

1. **Verify Against Specification**: Ensure the implemented code fulfills all Acceptance Criteria from the originating issue.
2. **Architectural & Quality Compliance**:
   - Clean separation of business logic and transport layers.
   - Zero contract duplication across shared packages.
   - Strict input sanitization, security boundary protection, and safe secret handling.
   - Concurrency, memory leak prevention, and proper resource teardown.
   - Rebase-only merge history; no direct pushes to master.
3. **Isolated Worktree Directory**: Never check out PR branches into the main workspace root to run tests or inspections. Always mount and verify the branch inside a temporary worktree (`.worktrees/review-pr-<PR_NUMBER>`).
4. **AI-to-Human Review Handoff**:
   - The AI reviewer runs automated verification and diff analysis while the card is in `Code Review` (`Attention: Standard`).
   - When AI review passes, the agent undrafts the PR, submits an approving review, and flips the card's attention to `Needs Decision` (still in column `Code Review`).
   - The card elevates into the top swimlane for the Human Reviewer to inspect and advance to `QA`.
5. **Bot Identity**: All operations run under the GitHub App bot identity (`No Git Sherlock [bot]`).

---

## 2. Polling for Work

Run `tools/poll-project.sh` as a background task to wait for assigned review items:
```bash
tools/poll-project.sh --status "Code Review" --attention "Standard"
```
When this command terminates with status `0`, an issue in `Code Review` with `Attention: Standard` is ready for automated code review.

---

## 3. Review Workflow & Worktree Verification

### Step 1: Worktree Mount
```bash
WORKTREE_DIR=".worktrees/review-pr-<PR_NUMBER>"
git fetch origin <branch-name>
git worktree add "$WORKTREE_DIR" <branch-name>

# Link shared dependencies if present (e.g. node_modules)
```

### Step 2: Verification Inside Worktree
```bash
cd "$WORKTREE_DIR"

# Run project linters, unit tests, and production build checks
npm test || true
npm run build || true

cd -
```

---

## 4. Review Checklist

### A. Correctness & Architecture
- [ ] Does the implementation match the issue's requirements and acceptance criteria?
- [ ] Are edge cases handled (empty states, network timeouts, invalid inputs)?
- [ ] Are resources cleaned up (listeners, subscriptions, timers)?
- [ ] Are async operations and promises handled with proper error boundaries?

### B. Security & Boundaries
- [ ] Are API inputs validated and sanitized?
- [ ] Are authorization guards applied to internet-facing endpoints?
- [ ] Are secrets, private keys, and environment variables protected from exposure?

### C. Clean Code & Conventions
- [ ] Are types explicit (avoiding unnecessary `any`)?
- [ ] Are logging statements using proper conventions?
- [ ] Is code formatted according to repository style rules?

---

## 5. Review Output Template

Post the structured review report as a comment on the Pull Request:

```markdown
## 🔍 Code Review Report

### 1. Summary
*Brief summary of changes and overall evaluation (Approved / Changes Requested).*

### 2. Architectural & Quality Checks
- [x] Architecture & modularity verified
- [x] Shared contracts & typed interfaces intact
- [x] Logging & security conventions respected

### 3. Automated Verification Results
- **Linter**: Passed
- **Tests**: Passed
- **Build**: Passed

### 4. Findings & Feedback
#### 🔴 Critical / Blocker (if any)
- Description of issue and required fix.

#### 🟡 Suggestions & Improvements (if any)
- Non-blocking suggestion.

### 5. Verdict
**[APPROVED]** / **[CHANGES REQUESTED]**
```

---

## 6. GitHub Project Board Transitions

### Case A: Changes Requested / Fixes Needed
If code flaws, broken tests, or regressions are found:
1. Submit review feedback requesting changes:
   ```bash
   gh pr review <PR_NUMBER> --request-changes -b "<REVIEW_REPORT_MARKDOWN>"
   ```
2. Return project item to `Implementer` with `Attention: Standard`:
   ```bash
   tools/project-move.sh <ISSUE_NUMBER> --status "Implementer" --attention "Standard"
   ```

### Case B: AI Review Approved (Ready for Human Review)
If all verification passes and code meets all architectural standards:
1. Submit approving review comment on PR:
   ```bash
   gh pr review <PR_NUMBER> --approve -b "✅ AI Code Review: Approved. Ready for human review sign-off."
   ```
2. Ensure PR is marked ready for review:
   ```bash
   gh pr ready <PR_NUMBER>
   ```
3. Elevate card to the top swimlane for human review:
   ```bash
   tools/project-move.sh <ISSUE_NUMBER> --status "Code Review" --attention "Needs Decision"
   ```

### Step 3: Cleanup Worktree
```bash
git worktree remove "$WORKTREE_DIR" --force
```
