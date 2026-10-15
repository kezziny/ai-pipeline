#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# verify-roles.sh - Automated Validation for Pipeline Role Specifications
# Validates:
#   - R1: Role taxonomy, naming, and negative trigger / context guards
#   - R2: Standard 5-section structure, bidirectional routing, continuous engine
#   - R3/R4: Tool references and automated gatekeeping (exit 0 on pass)
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SKILLS_DIR="${ROOT_DIR}/.agents/skills"
VERBOSE=0

# Formatting
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  BLUE='\033[0;34m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  BOLD=''
  NC=''
fi

usage() {
  cat <<EOF
Usage:
  tools/verify-roles.sh [OPTIONS]

Options:
  -d, --dir DIR     Target directory containing role skills (default: <repo-root>/.agents/skills)
  -v, --verbose     Enable verbose reporting
  -h, --help        Show this help message
EOF
  exit "${1:-0}"
}

# Parse CLI options
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage 0
      ;;
    -d|--dir)
      SKILLS_DIR="$2"
      shift 2
      ;;
    -v|--verbose)
      VERBOSE=1
      shift
      ;;
    *)
      echo "Error: Unknown option: $1" >&2
      usage 1
      ;;
  esac
done

ERRORS=0
WARNINGS=0

log_pass() { echo -e "  ${GREEN}✔${NC} $1"; }
log_fail() { echo -e "  ${RED}✖${NC} $1" >&2; ERRORS=$((ERRORS + 1)); }
log_warn() { echo -e "  ${YELLOW}⚠${NC} $1" >&2; WARNINGS=$((WARNINGS + 1)); }
log_info() { echo -e "${BLUE}▶${NC} $1"; }

REQUIRED_ROLES=(
  "role-product-manager"
  "role-senior-developer"
  "role-architect"
  "role-implementer"
  "role-code-reviewer"
  "role-qa-engineer"
)

DEPRECATED_ROLES=(
  "issue-implementer"
  "code-review"
)

echo "================================================================="
echo "Pipeline Role Specification Verification (R4)"
echo "Directory: ${SKILLS_DIR}"
echo "================================================================="

# -----------------------------------------------------------------------------
# Phase 1: Directory Taxonomy & Deprecation Checks
# -----------------------------------------------------------------------------
log_info "Phase 1: Validating Directory Taxonomy..."

if [[ ! -d "$SKILLS_DIR" ]]; then
  log_fail "Skills directory not found at: ${SKILLS_DIR}"
  echo "================================================================="
  echo -e "${RED}FAILURE: Verification failed with ${ERRORS} error(s). (Status: 1)${NC}" >&2
  exit 1
fi

# Check for deprecated role directories
for dep in "${DEPRECATED_ROLES[@]}"; do
  if [[ -d "${SKILLS_DIR}/${dep}" ]]; then
    log_fail "Found deprecated legacy role directory: ${dep}. Must be renamed to standardized role-* format."
  fi
done

# Check required role directories exist
for role in "${REQUIRED_ROLES[@]}"; do
  if [[ -d "${SKILLS_DIR}/${role}" ]]; then
    log_pass "Role directory exists: ${role}"
  else
    log_fail "Missing required role directory: ${role}"
  fi
done

# Check for unexpected extra directories
for dir in "${SKILLS_DIR}"/*/; do
  [[ -d "$dir" ]] || continue
  dname="$(basename "$dir")"
  found=0
  for req in "${REQUIRED_ROLES[@]}"; do
    if [[ "$dname" == "$req" ]]; then
      found=1
      break
    fi
  done
  if [[ $found -eq 0 ]]; then
    log_warn "Unrecognized directory in skills folder: ${dname}"
  fi
done

# -----------------------------------------------------------------------------
# Phase 2: Role File, Frontmatter & Content Structure Audit
# -----------------------------------------------------------------------------
log_info "Phase 2: Auditing SKILL.md Files and Standard Structure..."

if ! python3 - "${SKILLS_DIR}" "${VERBOSE}" <<'PYEOF'
import os
import sys
import re

skills_dir = sys.argv[1]
verbose = (sys.argv[2] == "1")

required_roles = [
    "role-product-manager",
    "role-senior-developer",
    "role-architect",
    "role-implementer",
    "role-code-reviewer",
    "role-qa-engineer"
]

mandatory_sections = [
    "Core Purpose & Primary Focus",
    "Autonomous Decisions",
    "Human Escalation Triggers",
    "Transition & Routing Rules",
    "Continuous Improvement Engine"
]

RED = '\033[0;31m' if sys.stderr.isatty() and not os.environ.get("NO_COLOR") else ''
GREEN = '\033[0;32m' if sys.stdout.isatty() and not os.environ.get("NO_COLOR") else ''
NC = '\033[0m' if (sys.stdout.isatty() or sys.stderr.isatty()) and not os.environ.get("NO_COLOR") else ''

errors = 0

def fail(role, msg):
    global errors
    print(f"  {RED}✖{NC} [{role}] {msg}", file=sys.stderr)
    errors += 1

def pass_log(role, msg):
    if verbose:
        print(f"  {GREEN}✔{NC} [{role}] {msg}")

for role in required_roles:
    role_dir = os.path.join(skills_dir, role)
    if not os.path.isdir(role_dir):
        # Already logged in Phase 1
        continue

    skill_path = os.path.join(role_dir, "SKILL.md")
    if not os.path.isfile(skill_path):
        fail(role, f"SKILL.md file missing at {skill_path}")
        continue

    size = os.path.getsize(skill_path)
    if size == 0:
        fail(role, "SKILL.md is empty (0 bytes)")
        continue

    try:
        with open(skill_path, "r", encoding="utf-8") as f:
            content = f.read()
    except Exception as e:
        fail(role, f"Failed to read SKILL.md: {e}")
        continue

    # Frontmatter validation
    if not content.startswith("---"):
        fail(role, "Missing opening '---' YAML frontmatter delimiter on line 1")
        continue

    parts = content.split("---", 2)
    if len(parts) < 3:
        fail(role, "Malformed YAML frontmatter: missing closing '---' delimiter")
        continue

    frontmatter = parts[1]
    body = parts[2]

    # Verify 'name:' in frontmatter
    name_match = re.search(r"^\s*name:\s*['\"]?([a-zA-Z0-9_-]+)['\"]?", frontmatter, re.MULTILINE)
    if not name_match:
        fail(role, "Missing 'name' field in YAML frontmatter")
    else:
        declared_name = name_match.group(1).strip()
        if declared_name != role:
            fail(role, f"Frontmatter name '{declared_name}' does not match directory '{role}'")
        else:
            pass_log(role, "Frontmatter name matches directory")

    # Verify 'description:' in frontmatter
    desc_match = re.search(r"^\s*description:\s*(.+)", frontmatter, re.MULTILINE)
    if not desc_match or not desc_match.group(1).strip():
        fail(role, "Missing or empty 'description' field in YAML frontmatter")
    else:
        pass_log(role, "Frontmatter description present")

    # Strict Negative Trigger Guards (R1)
    if role in ("role-implementer", "role-code-reviewer"):
        fm_lower = frontmatter.lower()
        has_negative_trigger = ("do not activate" in fm_lower or "negative trigger" in fm_lower) and "trigger only" in fm_lower
        if not has_negative_trigger:
            fail(role, "Missing mandatory negative trigger guard in YAML frontmatter description ('Trigger ONLY ... DO NOT activate ...')")
        else:
            pass_log(role, "Negative trigger guard verified in frontmatter")

        # Context guard in Markdown body
        has_context_guard = bool(re.search(r"context\s+guard|execution\s+guard|pipeline\s+context\s+guard", body, re.IGNORECASE))
        if not has_context_guard:
            fail(role, "Missing explicit PIPELINE CONTEXT GUARD section in Markdown body")
        else:
            pass_log(role, "Context guard verified in Markdown body")

    # Mandatory 5 Sections (R2)
    for sec in mandatory_sections:
        header_pat = rf"^#+\s*(?:\d+\.\s*)?{re.escape(sec)}"
        if not re.search(header_pat, body, re.MULTILINE | re.IGNORECASE):
            fail(role, f"Missing mandatory section header matching: '## {sec}'")
        else:
            pass_log(role, f"Mandatory section verified: '{sec}'")

    # Structured Tables / Lists in Autonomous Decisions & Human Escalation (R2)
    # Check for Markdown table pipes or list items under Autonomous Decisions
    auto_dec_match = re.search(r"^#{1,2}\s*(?:\d+\.\s*)?Autonomous Decisions(.*?)(?=^#{1,2}\s|\Z)", body, re.MULTILINE | re.DOTALL | re.IGNORECASE)
    if auto_dec_match:
        auto_text = auto_dec_match.group(1).strip()
        if "|" not in auto_text and not re.search(r"^\s*[-*]\s+", auto_text, re.MULTILINE):
            fail(role, "Section 'Autonomous Decisions' lacks concrete structured table or list items")
        else:
            pass_log(role, "Structured content verified in Autonomous Decisions")

    esc_match = re.search(r"^#{1,2}\s*(?:\d+\.\s*)?Human Escalation Triggers(.*?)(?=^#{1,2}\s|\Z)", body, re.MULTILINE | re.DOTALL | re.IGNORECASE)
    if esc_match:
        esc_text = esc_match.group(1).strip()
        if "|" not in esc_text and not re.search(r"^\s*[-*]\s+", esc_text, re.MULTILINE):
            fail(role, "Section 'Human Escalation Triggers' lacks concrete structured table or list items")
        else:
            pass_log(role, "Structured content verified in Human Escalation Triggers")

    # Bidirectional Transitions (R2)
    trans_match = re.search(r"^#{1,2}\s*(?:\d+\.\s*)?Transition & Routing Rules(.*?)(?=^#{1,2}\s|\Z)", body, re.MULTILINE | re.DOTALL | re.IGNORECASE)
    if trans_match:
        trans_text = trans_match.group(1)
        has_forward = bool(re.search(r"forward|next stage", trans_text, re.IGNORECASE))
        has_backward = bool(re.search(r"backward|route back|revision|rework|defect routing|defect", trans_text, re.IGNORECASE))
        if not (has_forward and has_backward):
            missing_dir = []
            if not has_forward:
                missing_dir.append("Forward transitions")
            if not has_backward:
                missing_dir.append("Backward / Defect routing")
            fail(role, f"Transition & Routing Rules must be bidirectional; missing: {', '.join(missing_dir)}")
        else:
            pass_log(role, "Bidirectional transitions verified")

    # Continuous Improvement Engine: AGENTS.md and Self-Refinement (R2)
    ci_match = re.search(r"^#{1,2}\s*(?:\d+\.\s*)?Continuous Improvement Engine(.*?)(?=^#{1,2}\s|\Z)", body, re.MULTILINE | re.DOTALL | re.IGNORECASE)
    if ci_match:
        ci_text = ci_match.group(1)
        if not re.search(r"AGENTS\.md", ci_text):
            fail(role, "Section 'Continuous Improvement Engine' must specify AGENTS.md convention harvesting")
        else:
            pass_log(role, "AGENTS.md harvesting verified in Continuous Improvement Engine")
        if not re.search(r"refinement|self-refinement|update|feedback", ci_text, re.IGNORECASE):
            fail(role, "Section 'Continuous Improvement Engine' must specify skill self-refinement")
        else:
            pass_log(role, "Self-refinement verified in Continuous Improvement Engine")

    # Tool References (R3)
    if not ("poll-project.sh" in body and "project-move.sh" in body):
        missing_tools = []
        if "poll-project.sh" not in body:
            missing_tools.append("tools/poll-project.sh")
        if "project-move.sh" not in body:
            missing_tools.append("tools/project-move.sh")
        fail(role, f"Missing tool reference(s): {', '.join(missing_tools)}")
    else:
        pass_log(role, "Helper tools referenced cleanly")

if not verbose and errors == 0:
    for role in required_roles:
        print(f"  {GREEN}✔{NC} Verified role specification: {role}")

sys.exit(errors)
PYEOF
then
  ((ERRORS++))
fi

echo "================================================================="
if [[ $ERRORS -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}SUCCESS: All pipeline role specifications passed verification! (Status: 0)${NC}"
  exit 0
else
  echo -e "${RED}${BOLD}FAILURE: Verification failed with ${ERRORS} error(s). (Status: 1)${NC}" >&2
  exit 1
fi
