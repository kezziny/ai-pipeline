#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# test-pipeline-tools.sh - Comprehensive Test Suite for Pipeline Tools (M3/F3)
# Tests:
#   1. Live baseline validation (verify-roles.sh -> exit 0)
#   2. CLI options & help flags for all 4 tools
#   3. Zero stale repo references (no da4h/ui)
#   4. Status & Attention alias normalization unit tests
#   5. Adversarial mutant test suite (TC-MUT-1 through TC-MUT-11) in sandbox
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

PASSED=0
FAILED=0

test_pass() { echo -e "  ${GREEN}✔${NC} $1"; PASSED=$((PASSED + 1)); }
test_fail() { echo -e "  ${RED}✖${NC} $1" >&2; FAILED=$((FAILED + 1)); }
suite_header() { echo -e "\n${BLUE}▶ $1${NC}"; }

echo "================================================================="
echo "Pipeline Tooling & Role Verification Test Suite"
echo "Root: ${ROOT_DIR}"
echo "================================================================="

# -----------------------------------------------------------------------------
# Test 1: Live Repository Verification
# -----------------------------------------------------------------------------
suite_header "Test 1: Live Repository Verification (verify-roles.sh)"

if "${SCRIPT_DIR}/verify-roles.sh" >/dev/null; then
  test_pass "verify-roles.sh exits 0 on live repository"
else
  test_fail "verify-roles.sh failed on live repository"
fi

if "${SCRIPT_DIR}/verify-roles.sh" -v >/dev/null; then
  test_pass "verify-roles.sh -v executes cleanly"
else
  test_fail "verify-roles.sh -v failed"
fi

# -----------------------------------------------------------------------------
# Test 2: CLI Options & Help Flags
# -----------------------------------------------------------------------------
suite_header "Test 2: CLI Usage & Help Flags"

for script in "verify-roles.sh" "poll-project.sh" "project-move.sh" "poll-issues.sh"; do
  if "${SCRIPT_DIR}/${script}" --help >/dev/null; then
    test_pass "${script} --help exits 0"
  else
    test_fail "${script} --help failed"
  fi
done

# -----------------------------------------------------------------------------
# Test 3: Stale Reference Audit
# -----------------------------------------------------------------------------
suite_header "Test 3: Stale Repository Reference Sanitization"

if grep -rn --exclude="test-*" "da4h" "${SCRIPT_DIR}" >/dev/null 2>&1; then
  test_fail "Found stale repo reference 'da4h' in production tools"
else
  test_pass "No stale 'da4h' repo references found in production tools"
fi

# -----------------------------------------------------------------------------
# Test 4: Alias Normalization Logic
# -----------------------------------------------------------------------------
suite_header "Test 4: Status & Attention Alias Normalization"

python3 - <<'PYEOF'
STATUS_ALIASES = {
    "role-product-manager": "pm", "product-manager": "pm", "product manager": "pm", "pm": "pm",
    "role-senior-developer": "senior dev", "senior-developer": "senior dev", "senior developer": "senior dev",
    "senior-dev": "senior dev", "senior dev": "senior dev",
    "role-architect": "architect", "architect": "architect",
    "role-implementer": "implementer", "issue-implementer": "implementer", "implementer": "implementer",
    "role-code-reviewer": "code review", "code-reviewer": "code review", "code reviewer": "code review",
    "code-review": "code review", "code review": "code review",
    "role-qa-engineer": "qa", "qa-engineer": "qa", "qa engineer": "qa", "qa": "qa",
    "ready": "ready",
    "done": "done", "backlog": "backlog"
}

ATTENTION_ALIASES = {
    "standard": "standard", "needs decision": "needs decision",
    "needs-decision": "needs decision", "needs_decision": "needs decision", "decision": "needs decision"
}

board_columns = ["Backlog", "PM", "Senior Dev", "Architect", "Ready", "Implementer", "Code Review", "QA", "Done"]
board_attentions = ["Standard", "Needs Decision"]

cases = [
    ("role-implementer", "Implementer"),
    ("issue-implementer", "Implementer"),
    ("implementer", "Implementer"),
    ("role-code-reviewer", "Code Review"),
    ("code-review", "Code Review"),
    ("role-product-manager", "PM"),
    ("pm", "PM"),
    ("role-senior-developer", "Senior Dev"),
    ("senior-dev", "Senior Dev"),
    ("role-architect", "Architect"),
    ("ready", "Ready"),
    ("role-qa-engineer", "QA"),
    ("qa", "QA"),
    ("done", "Done")
]

for role_in, expected_col in cases:
    target_norm = STATUS_ALIASES.get(role_in.lower(), role_in.lower())
    matched = None
    for col in board_columns:
        col_norm = STATUS_ALIASES.get(col.lower(), col.lower())
        if col.lower() == role_in.lower() or col_norm == target_norm:
            matched = col
            break
    assert matched == expected_col, f"Status mismatch: {role_in} -> {matched} != {expected_col}"

att_cases = [
    ("standard", "Standard"),
    ("Standard", "Standard"),
    ("needs decision", "Needs Decision"),
    ("Needs Decision", "Needs Decision"),
    ("needs-decision", "Needs Decision"),
    ("decision", "Needs Decision")
]

for att_in, expected_att in att_cases:
    target_att_norm = ATTENTION_ALIASES.get(att_in.lower(), att_in.lower())
    matched = None
    for att in board_attentions:
        att_norm = ATTENTION_ALIASES.get(att.lower(), att.lower())
        if att.lower() == att_in.lower() or att_norm == target_att_norm:
            matched = att
            break
    assert matched == expected_att, f"Attention mismatch: {att_in} -> {matched} != {expected_att}"
PYEOF

if [[ $? -eq 0 ]]; then
  test_pass "All 13 status alias mapping tests passed"
  test_pass "All 6 attention alias mapping tests passed"
else
  test_fail "Alias normalization logic error"
fi

# -----------------------------------------------------------------------------
# Test 5: Adversarial Mutant Suite (Negative Testing)
# -----------------------------------------------------------------------------
suite_header "Test 5: Adversarial Mutant Test Suite"

TEMP_DIR="$(mktemp -d "/tmp/test_pipeline_mutants.XXXXXX")"
trap 'rm -rf "${TEMP_DIR}"' EXIT

MUTANT_SKILLS="${TEMP_DIR}/skills"
cp -r "${ROOT_DIR}/.agents/skills" "${MUTANT_SKILLS}"

run_mutant() {
  local name="$1"
  local description="$2"
  if "${SCRIPT_DIR}/verify-roles.sh" -d "${MUTANT_SKILLS}" >/dev/null 2>&1; then
    test_fail "${name}: FAILED TO DETECT MUTANT (${description})"
  else
    test_pass "${name}: Successfully detected and rejected (${description})"
  fi
}

reset_skills() {
  rm -rf "${MUTANT_SKILLS}"
  cp -r "${ROOT_DIR}/.agents/skills" "${MUTANT_SKILLS}"
}

# TC-MUT-1: Missing Role Directory
rm -rf "${MUTANT_SKILLS}/role-qa-engineer"
run_mutant "TC-MUT-1" "Missing role-qa-engineer directory"
reset_skills

# TC-MUT-2: Deprecated Legacy Directory
mkdir -p "${MUTANT_SKILLS}/issue-implementer"
run_mutant "TC-MUT-2" "Deprecated issue-implementer directory present"
reset_skills

# TC-MUT-3: Frontmatter Name Mismatch
sed -i "s/name: role-architect/name: wrong-architect/" "${MUTANT_SKILLS}/role-architect/SKILL.md"
run_mutant "TC-MUT-3" "Frontmatter name mismatch in role-architect"
reset_skills

# TC-MUT-4: Missing Negative Trigger Guard
sed -i "s/DO NOT activate/Always activate/" "${MUTANT_SKILLS}/role-implementer/SKILL.md"
run_mutant "TC-MUT-4" "Missing negative trigger guard in role-implementer frontmatter"
reset_skills

# TC-MUT-5: Missing Context Guard in Body
sed -i "s/PIPELINE CONTEXT GUARD/NORMAL SCRIPT EXECUTION/" "${MUTANT_SKILLS}/role-implementer/SKILL.md"
sed -i "s/pipeline operations/standard operations/" "${MUTANT_SKILLS}/role-implementer/SKILL.md"
run_mutant "TC-MUT-5" "Missing PIPELINE CONTEXT GUARD in role-implementer body"
reset_skills

# TC-MUT-6: Missing Mandatory Section
sed -i "s/## Continuous Improvement Engine/## Miscellaneous Feedback/" "${MUTANT_SKILLS}/role-product-manager/SKILL.md"
run_mutant "TC-MUT-6" "Missing Continuous Improvement Engine section in role-product-manager"
reset_skills

# TC-MUT-7: Truncated / Empty SKILL.md
: > "${MUTANT_SKILLS}/role-senior-developer/SKILL.md"
run_mutant "TC-MUT-7" "Empty SKILL.md in role-senior-developer"
reset_skills

# TC-MUT-8: Missing Backward Transitions
python3 -c '
import re
path = "'"${MUTANT_SKILLS}"'/role-code-reviewer/SKILL.md"
content = open(path).read()
mutated = re.sub(r"### Backward Transitions & Defect Routing.*?(?=## Continuous Improvement Engine)", "", content, flags=re.DOTALL)
open(path, "w").write(mutated)
'
run_mutant "TC-MUT-8" "Missing Backward Transitions in role-code-reviewer"
reset_skills

# TC-MUT-9: Missing Forward Transitions
python3 -c '
import re
path = "'"${MUTANT_SKILLS}"'/role-code-reviewer/SKILL.md"
content = open(path).read()
mutated = re.sub(r"### Forward Transitions.*?(?=### Backward Transitions)", "", content, flags=re.DOTALL)
open(path, "w").write(mutated)
'
run_mutant "TC-MUT-9" "Missing Forward Transitions in role-code-reviewer"
reset_skills

# TC-MUT-10: Missing AGENTS.md Reference
python3 -c '
import re
path = "'"${MUTANT_SKILLS}"'/role-product-manager/SKILL.md"
content = open(path).read()
ci_match = re.search(r"^##\s*Continuous Improvement Engine.*", content, flags=re.DOTALL | re.MULTILINE)
mutated = content[:ci_match.start()] + ci_match.group(0).replace("AGENTS.md", "OTHER.md")
open(path, "w").write(mutated)
'
run_mutant "TC-MUT-10" "Missing AGENTS.md harvesting protocol in role-product-manager"
reset_skills

# TC-MUT-11: Missing Tool Reference
sed -i "s/poll-project.sh/poll-custom.sh/" "${MUTANT_SKILLS}/role-architect/SKILL.md"
run_mutant "TC-MUT-11" "Missing tools/poll-project.sh reference in role-architect"
reset_skills

# TC-MUT-12: Unstructured Autonomous Decisions (Plain prose instead of table/list)
python3 -c '
import re
path = "'"${MUTANT_SKILLS}"'/role-senior-developer/SKILL.md"
content = open(path).read()
mutated = re.sub(r"## Autonomous Decisions\n.*?(?=## Human Escalation Triggers)", "## Autonomous Decisions\nDecisions made as needed.\n\n", content, flags=re.DOTALL)
open(path, "w").write(mutated)
'
run_mutant "TC-MUT-12" "Unstructured Autonomous Decisions (plain prose) in role-senior-developer"
reset_skills

echo "================================================================="
echo -e "Test Results: ${GREEN}${PASSED} passed${NC}, ${RED}${FAILED} failed${NC}"
echo "================================================================="

if [[ $FAILED -eq 0 ]]; then
  echo -e "${GREEN}ALL TESTS PASSED!${NC}"
  exit 0
else
  echo -e "${RED}SOME TESTS FAILED!${NC}" >&2
  exit 1
fi
