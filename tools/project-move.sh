#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# GitHub Project Item Mover for Automated Agent Workflows
# Moves an issue / project item to a new Status column and/or Attention swimlane.
#
# Rate-Limit Optimizations:
#   - Caches Project ID & Field/Option definitions in /tmp/gh-project-metadata-<owner>-<num>.json
#     (TTL: 24h) to avoid repeated GraphQL calls on each move.
#   - Leverages local item cache for issue ID lookup when available.
#   - Invalidates /tmp/gh-project-cache-<owner>-<num>.json upon successful move
#     so polling agents immediately detect state transitions.
# -----------------------------------------------------------------------------

usage() {
  cat <<'EOF'
Usage:
  tools/project-move.sh <ISSUE_NUMBER_OR_ITEM_ID> [--status "<STATUS>"] [--attention "<ATTENTION>"]

Examples:
  tools/project-move.sh 42 --status "Senior Dev"
  tools/project-move.sh 42 --attention "Needs Decision"
  tools/project-move.sh 42 --status "Architect" --attention "Standard"

Options:
  -s, --status         Target column name (e.g. "PM", "Senior Dev", "Architect", "Implementer", "Code Review", "QA", "Done" or role aliases like "role-implementer")
  -a, --attention      Target attention name (e.g. "Standard", "Needs Decision", supports aliases like "needs-decision")
  -p, --project        Project number (default from .project-config.json or $GH_PROJECT_NUMBER)
  -o, --owner          Project owner (default from .project-config.json or $GH_PROJECT_OWNER)
  --max-bounces        Max backward transitions before circuit breaker escalates to 'Needs Decision' (default: 3)
  --reset-bounces      Reset backward transition bounce counter for this issue
  -h, --help           Show this help message
EOF
  exit "${1:-0}"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${ROOT_DIR}/.project-config.json"

TARGET_REF=""
TARGET_STATUS=""
TARGET_ATTENTION=""
PROJECT_NUMBER=""
PROJECT_OWNER=""
STATUS_FIELD="Status"
ATTENTION_FIELD="Attention"
MAX_BOUNCES="${GH_PROJECT_MAX_BOUNCES:-3}"
RESET_BOUNCES=0

# Load defaults from config file if available
if [[ -f "$CONFIG_FILE" ]]; then
  CFG_OWNER=$(python3 -c "import json; d=json.load(open('$CONFIG_FILE')); print(d.get('owner', ''))" 2>/dev/null || true)
  CFG_NUM=$(python3 -c "import json; d=json.load(open('$CONFIG_FILE')); print(d.get('projectNumber', ''))" 2>/dev/null || true)
  CFG_SF=$(python3 -c "import json; d=json.load(open('$CONFIG_FILE')); print(d.get('statusFieldName', 'Status'))" 2>/dev/null || true)
  CFG_AF=$(python3 -c "import json; d=json.load(open('$CONFIG_FILE')); print(d.get('attentionFieldName', 'Attention'))" 2>/dev/null || true)
  PROJECT_OWNER="${CFG_OWNER:-}"
  PROJECT_NUMBER="${CFG_NUM:-}"
  STATUS_FIELD="${CFG_SF:-Status}"
  ATTENTION_FIELD="${CFG_AF:-Attention}"
fi

# Environment variable overrides
PROJECT_OWNER="${GH_PROJECT_OWNER:-$PROJECT_OWNER}"
PROJECT_NUMBER="${GH_PROJECT_NUMBER:-$PROJECT_NUMBER}"
STATUS_FIELD="${GH_PROJECT_STATUS_FIELD:-$STATUS_FIELD}"
ATTENTION_FIELD="${GH_PROJECT_ATTENTION_FIELD:-$ATTENTION_FIELD}"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage 0
      ;;
    -s|--status)
      TARGET_STATUS="$2"
      shift 2
      ;;
    -a|--attention)
      TARGET_ATTENTION="$2"
      shift 2
      ;;
    -p|--project)
      PROJECT_NUMBER="$2"
      shift 2
      ;;
    -o|--owner)
      PROJECT_OWNER="$2"
      shift 2
      ;;
    --max-bounces)
      MAX_BOUNCES="$2"
      shift 2
      ;;
    --reset-bounces)
      RESET_BOUNCES=1
      shift
      ;;
    *)
      if [[ -z "$TARGET_REF" ]]; then
        TARGET_REF="$1"
      fi
      shift
      ;;
  esac
done

if [[ -z "$TARGET_REF" ]]; then
  echo "Error: Missing target issue number or project item ID" >&2
  usage 1
fi

if [[ -z "$TARGET_STATUS" ]] && [[ -z "$TARGET_ATTENTION" ]] && [[ "$RESET_BOUNCES" -eq 0 ]]; then
  echo "Error: Must specify at least one of --status, --attention, or --reset-bounces" >&2
  usage 1
fi

if [[ -z "$PROJECT_NUMBER" ]] || [[ -z "$PROJECT_OWNER" ]]; then
  echo "Error: PROJECT_NUMBER and PROJECT_OWNER must be defined via flags, env vars, or .project-config.json" >&2
  exit 1
fi

# Detect gh / gh-bot command
GH_CMD="gh"
if command -v gh-bot &>/dev/null; then
  GH_CMD="gh-bot"
elif [[ -x "$HOME/.config/gh/gh-bot" ]]; then
  GH_CMD="$HOME/.config/gh/gh-bot"
fi

# Clean reference (e.g. "#42" -> "42")
TARGET_REF="${TARGET_REF#"#"}"

python3 - <<PYEOF
import subprocess, json, sys, os, time

gh_cmd = "${GH_CMD}"
owner = "${PROJECT_OWNER}"
p_num = "${PROJECT_NUMBER}"
target_ref = "${TARGET_REF}"
target_status = "${TARGET_STATUS}".strip()
target_attention = "${TARGET_ATTENTION}".strip()
status_field_name = "${STATUS_FIELD}".strip().lower()
attention_field_name = "${ATTENTION_FIELD}".strip().lower()
max_bounces = int("${MAX_BOUNCES}")
reset_bounces = int("${RESET_BOUNCES}")

meta_cache_file = f"/tmp/gh-project-metadata-{owner}-{p_num}.json"
items_cache_file = f"/tmp/gh-project-cache-{owner}-{p_num}.json"
bounce_file = f"/tmp/gh-bounce-{owner}-{p_num}-{target_ref}.count"
meta_ttl = 86400  # 24 hours

if reset_bounces == 1:
    if os.path.exists(bounce_file):
        try:
            os.remove(bounce_file)
        except Exception:
            pass
    if not target_status and not target_attention:
        print(f"[project-move] Reset bounce counter for #{target_ref}")
        sys.exit(0)

def run_json(cmd):
    res = subprocess.run(cmd, capture_output=True, text=True, check=True)
    return json.loads(res.stdout)

# 1. Fetch or Load Project Metadata (Project ID & Field List)
metadata = None
if os.path.exists(meta_cache_file):
    try:
        mtime = os.path.getmtime(meta_cache_file)
        if (time.time() - mtime) < meta_ttl:
            with open(meta_cache_file, "r") as f:
                metadata = json.load(f)
    except Exception:
        metadata = None

if not metadata:
    try:
        p_info = run_json([gh_cmd, "project", "view", p_num, "--owner", owner, "--format", "json"])
        project_id = p_info.get("id")
        fields_data = run_json([gh_cmd, "project", "field-list", p_num, "--owner", owner, "--format", "json"])
        fields = fields_data.get("fields", [])
        metadata = {
            "projectId": project_id,
            "fields": fields
        }
        with open(meta_cache_file, "w") as f:
            json.dump(metadata, f)
    except Exception as e:
        sys.stderr.write(f"Error fetching project metadata: {e}\n")
        sys.exit(1)

project_id = metadata.get("projectId")
fields = metadata.get("fields", [])

status_field_id = None
status_option_id = None
status_option_name = None
attention_field_id = None
attention_option_id = None
attention_option_name = None

STATUS_ALIASES = {
    "role-product-manager": "pm",
    "product-manager": "pm",
    "product manager": "pm",
    "pm": "pm",
    "role-senior-developer": "senior dev",
    "senior-developer": "senior dev",
    "senior developer": "senior dev",
    "senior-dev": "senior dev",
    "senior dev": "senior dev",
    "role-architect": "architect",
    "architect": "architect",
    "role-implementer": "implementer",
    "issue-implementer": "implementer",
    "implementer": "implementer",
    "role-code-reviewer": "code review",
    "code-reviewer": "code review",
    "code reviewer": "code review",
    "code-review": "code review",
    "code review": "code review",
    "role-qa-engineer": "qa",
    "qa-engineer": "qa",
    "qa engineer": "qa",
    "qa": "qa",
    "ready": "ready",
    "done": "done",
    "backlog": "backlog",
}

STAGE_ORDER = {
    "backlog": 0,
    "pm": 1,
    "senior dev": 2,
    "architect": 3,
    "ready": 4,
    "implementer": 5,
    "code review": 6,
    "qa": 7,
    "done": 8,
}

ATTENTION_ALIASES = {
    "standard": "standard",
    "needs decision": "needs decision",
    "needs-decision": "needs decision",
    "needs_decision": "needs decision",
    "decision": "needs decision",
}

# 2. Locate Item ID & Current Status (Check local items cache first)
item_id = None
current_status_norm = ""
issue_num_str = target_ref if not target_ref.startswith("PVTI_") else ""

def extract_item_info(it):
    it_status = ""
    for k, v in it.items():
        lk = k.strip().lower()
        if lk == status_field_name or lk == "status":
            it_status = str(v).strip().lower() if v is not None else ""
    return it.get("id"), STATUS_ALIASES.get(it_status, it_status), str(it.get("content", {}).get("number", ""))

if os.path.exists(items_cache_file):
    try:
        with open(items_cache_file, "r") as f:
            c_data = json.load(f)
            for it in c_data.get("items", []):
                cid, cstat, cnum = extract_item_info(it)
                if (target_ref.startswith("PVTI_") and cid == target_ref) or (cnum == str(target_ref)):
                    item_id = cid
                    current_status_norm = cstat
                    issue_num_str = cnum or issue_num_str
                    break
    except Exception:
        pass

if not item_id:
    if target_ref.startswith("PVTI_"):
        item_id = target_ref
    else:
        try:
            item_limit = os.environ.get("GH_PROJECT_ITEM_LIMIT", "100")
            items_data = run_json([gh_cmd, "project", "item-list", p_num, "--owner", owner, "--limit", item_limit, "--format", "json"])
            for it in items_data.get("items", []):
                cid, cstat, cnum = extract_item_info(it)
                if cnum == str(target_ref):
                    item_id = cid
                    current_status_norm = cstat
                    issue_num_str = cnum
                    break
        except Exception as e:
            sys.stderr.write(f"Error fetching project items: {e}\n")
            sys.exit(1)

if not item_id:
    sys.stderr.write(f"Error: Could not find project item corresponding to issue #{target_ref}\n")
    sys.exit(1)

target_status_norm = STATUS_ALIASES.get(target_status.lower(), target_status.lower()) if target_status else ""
target_att_norm = ATTENTION_ALIASES.get(target_attention.lower(), target_attention.lower()) if target_attention else ""

# 3. Circuit Breaker Evaluation for Backward Transitions
circuit_breaker_triggered = False
bounce_count = 0
if issue_num_str:
    bounce_file = f"/tmp/gh-bounce-{owner}-{p_num}-{issue_num_str}.count"

if target_status_norm in ("ready", "done"):
    if os.path.exists(bounce_file):
        try:
            os.remove(bounce_file)
        except Exception:
            pass
elif target_status_norm and current_status_norm:
    cur_idx = STAGE_ORDER.get(current_status_norm, -1)
    tgt_idx = STAGE_ORDER.get(target_status_norm, -1)
    if cur_idx > tgt_idx >= 0:
        try:
            if os.path.exists(bounce_file):
                with open(bounce_file, "r") as bf:
                    bounce_count = int(bf.read().strip() or "0")
        except Exception:
            bounce_count = 0
        bounce_count += 1
        if max_bounces > 0 and bounce_count >= max_bounces:
            circuit_breaker_triggered = True
            target_attention = "Needs Decision"
            target_att_norm = "needs decision"
            try:
                if os.path.exists(bounce_file):
                    os.remove(bounce_file)
            except Exception:
                pass
        else:
            try:
                with open(bounce_file, "w") as bf:
                    bf.write(str(bounce_count))
            except Exception:
                pass

for f in fields:
    fname = f.get("name", "").strip().lower()
    options = f.get("options", [])
    if fname == status_field_name or fname == "status":
        status_field_id = f.get("id")
        if target_status:
            for opt in options:
                opt_name = opt.get("name", "").strip()
                opt_norm = STATUS_ALIASES.get(opt_name.lower(), opt_name.lower())
                if opt_name.lower() == target_status.lower() or opt_norm == target_status_norm:
                    status_option_id = opt.get("id")
                    status_option_name = opt_name
                    break
    elif fname == attention_field_name or fname == "attention":
        attention_field_id = f.get("id")
        if target_attention:
            for opt in options:
                opt_name = opt.get("name", "").strip()
                opt_norm = ATTENTION_ALIASES.get(opt_name.lower(), opt_name.lower())
                if opt_name.lower() == target_attention.lower() or opt_norm == target_att_norm:
                    attention_option_id = opt.get("id")
                    attention_option_name = opt_name
                    break

if target_status and not status_option_id:
    sys.stderr.write(f"Warning: Option '{target_status}' not found in field '{status_field_name}'\n")

if target_attention and not attention_option_id:
    sys.stderr.write(f"Warning: Option '{target_attention}' not found in field '{attention_field_name}'\n")

# 4. Perform Field Updates
updated = []
if target_status and status_field_id and status_option_id:
    cmd = [
        gh_cmd, "project", "item-edit",
        "--id", item_id,
        "--project-id", project_id,
        "--field-id", status_field_id,
        "--single-select-option-id", status_option_id
    ]
    subprocess.run(cmd, check=True)
    updated.append(f"Status -> '{status_option_name or target_status}'")

if target_attention and attention_field_id and attention_option_id:
    cmd = [
        gh_cmd, "project", "item-edit",
        "--id", item_id,
        "--project-id", project_id,
        "--field-id", attention_field_id,
        "--single-select-option-id", attention_option_id
    ]
    subprocess.run(cmd, check=True)
    updated.append(f"Attention -> '{attention_option_name or target_attention}'")

if circuit_breaker_triggered and issue_num_str:
    cb_msg = (
        f"⚠️ **Pipeline Circuit Breaker Triggered**: Issue #{issue_num_str} has been routed backward "
        f"{bounce_count} times (threshold: {max_bounces}). Automatically escalating 'Attention' to "
        f"**Needs Decision** to prevent an infinite agent ping-pong loop."
    )
    subprocess.run([gh_cmd, "issue", "comment", issue_num_str, "--body", cb_msg], capture_output=True)
    updated.append(f"CIRCUIT BREAKER ({bounce_count} bounces -> Needs Decision)")

# 5. Invalidate items cache so pollers immediately see updated item state
if os.path.exists(items_cache_file):
    try:
        os.remove(items_cache_file)
    except Exception:
        pass

print(f"[project-move] Issue #{target_ref} (item {item_id}): " + ", ".join(updated))
PYEOF
