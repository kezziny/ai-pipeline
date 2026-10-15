---
name: issue-implementer
description: >-
  Implement features and bugfixes for GitHub issues.
  Picks up issues in 'Implementer' status, manages feature branches and Draft PRs,
  implements code from technical plans, resolves review/QA feedback with comment replies,
  runs quality gates, and transitions status to 'Code Review'.
---

# Issue Implementer Skill

This skill guides the agent to act as an autonomous, detail-oriented **Software Engineer**. It picks up GitHub issues in `Implementer` status on the project board, establishes dedicated feature branches and Draft Pull Requests, implements code strictly according to the issue's `Implementation Plan`, resolves any incoming code review or QA feedback, verifies quality gates, and transitions the issue to `Code Review`.

---

## 1. Operating Principles

1. **Plan-Driven Implementation**: Implement code strictly following the approved `Implementation Plan` section in the issue description. Comply with project architectural rules (`AGENTS.md`).
2. **Isolated Worktree Directory**: Never check out feature branches directly inside the primary repository root. Always create and work inside a dedicated worktree directory (`.worktrees/issue-<ISSUE_NUMBER>`). This prevents parallel coding, review, and test runs from colliding or interfering with each other's checked-out files.
3. **Early Draft PR**: When starting a new feature branch, immediately open a Draft PR (`gh pr create --draft`). This provides visibility and ensures early CI validation.
4. **Mandatory Quality Gates**: Before submitting for review, the implementation MUST pass local checks:
   - Git rebase onto latest `origin/master`.
   - Project linting, unit test suites, and clean builds.
5. **Iterative Review Resolution**: If an issue was returned from code review or QA:
   - Inspect all review comments, QA defect reports, or change requests.
   - Implement the requested fixes as new commits on the existing branch.
   - Reply directly to each review comment with a brief summary of how it was resolved.
6. **Bot Identity**: All GitHub CLI operations run under `No Git Sherlock [bot]`.

---

## 2. Polling for Work

Run `tools/poll-project.sh` as a background task to wait for assigned issues:
```bash
tools/poll-project.sh --status "Implementer" --attention "Standard"
```
When this command terminates with status `0`, an issue in the `Implementer` column is ready for coding or feedback resolution.

---

## 3. Step-by-Step Implementation Workflow

### Step 1: Issue Inspection
Inspect the issue requirements and technical plan:
```bash
gh issue view <ISSUE_NUMBER> --json title,body
```

---

### Step 2: Isolated Worktree & Branch Setup

To enable concurrent work without branch conflicts, operate inside `.worktrees/issue-<ISSUE_NUMBER>`:

1. Fetch latest changes from remote:
   ```bash
   git fetch origin master
   ```
2. Check if a branch or PR already exists for the issue:
   ```bash
   gh pr list --search "<ISSUE_NUMBER>" --json number,headRefName,isDraft,url
   ```
3. **If starting a new branch**:
   ```bash
   WORKTREE_DIR=".worktrees/issue-<ISSUE_NUMBER>"
   BRANCH_NAME="feature/<ISSUE_NUMBER>-<short-slug>"

   # Create isolated worktree branching from origin/master
   git worktree add "$WORKTREE_DIR" -b "$BRANCH_NAME" origin/master

   # If dependencies exist in main repository, link them to avoid redundant installs
   # e.g., ln -s "$(pwd)/node_modules" "$WORKTREE_DIR/node_modules"

   # Create initial commit and open Draft PR
   cd "$WORKTREE_DIR"
   git commit --allow-empty -m "feat(issue-<ISSUE_NUMBER>): start implementation for #<ISSUE_NUMBER>"
   git push -u origin "$BRANCH_NAME"
   gh pr create --draft --title "feat(issue-<ISSUE_NUMBER>): <issue-title>" --body "Closes #<ISSUE_NUMBER>. Initial draft implementation based on issue plan."
   cd -
   ```
4. **If continuing an existing branch (addressing review or QA feedback)**:
   ```bash
   WORKTREE_DIR=".worktrees/issue-<ISSUE_NUMBER>"
   git fetch origin <branch-name>

   # Mount existing branch into isolated worktree
   git worktree add "$WORKTREE_DIR" <branch-name>
   ```

---

### Step 3: Coding & Feedback Resolution

Perform all edits, commits, and tests inside `$WORKTREE_DIR`:
```bash
cd "$WORKTREE_DIR"
```

#### Case A: Fresh Implementation
- Follow the `Files Modified / Created` table and DTO contracts defined in the issue plan.
- Implement business logic, services, and user interfaces.
- Add or update relevant unit test suites.

#### Case B: Addressing Review or QA Feedback
When the issue was moved back to `Implementer` from `Code Review` or `QA`:
1. Read the latest review comments or QA logs from the PR:
   ```bash
   gh pr view <PR_NUMBER> --comments
   ```
2. Address each observation and make the required code corrections.
3. Commit the fixes with a clear message:
   ```bash
   git commit -m "fix(issue-<ISSUE_NUMBER>): address feedback on <topic>"
   ```
4. Reply directly to each review comment on GitHub with a concise summary of the resolution:
   ```bash
   gh pr comment <PR_NUMBER> --body "Fixed in latest commit: <brief summary of changes>."
   ```

---

### Step 4: Quality Gate Verification

Inside `$WORKTREE_DIR`, run verification before handover:

1. **Rebase onto latest master**:
   ```bash
   git fetch origin master && git rebase origin/master
   ```
2. **Run Tests & Build**:
   Execute repository test suites and build commands.
3. **Push verified code**:
   ```bash
   git push origin "$BRANCH_NAME"
   ```
4. Return to repository root:
   ```bash
   cd -
   ```

---

### Step 5: Transition to Code Review & Cleanup Worktree

Once local checks pass and code is pushed:

1. **Ensure PR is Ready for Review (convert from Draft if needed)**:
   ```bash
   gh pr ready <PR_NUMBER>
   ```
2. **Transition Project Board Status**:
   Move item to `Code Review` with `Attention: Standard`:
   ```bash
   tools/project-move.sh <ISSUE_NUMBER> --status "Code Review" --attention "Standard"
   ```
3. Post a handover comment on the issue/PR:
   ```bash
   gh issue comment <ISSUE_NUMBER> --body "Implementation complete and verified. PR #<PR_NUMBER> is ready for code review."
   ```
4. **Remove the Temporary Worktree**:
   ```bash
   git worktree remove "$WORKTREE_DIR" --force
   ```
