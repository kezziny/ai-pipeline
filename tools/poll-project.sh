#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# GitHub Project Poller for Automated Agent Workflows
# Polls a GitHub Projects v2 board until an open item with the specified
# status and attention values is found.
# Exits with status 0 upon match so background agent tasks wake up reactively.
# -----------------------------------------------------------------------------

usage() {
  cat <<'EOF'
Usage:
  tools/poll-project.sh --status "<STATUS>" [--attention "<ATTENTION>"] [--interval 10]
  tools/poll-project.sh "<STATUS>" [INTERVAL_SECONDS]

Options:
  -s, --status      Target column/status (e.g. "PM", "Senior Dev", "Architect", "Implementer", "Code Review", "QA")
  -a, --attention   Target attention swimlane (default: "Standard")
  -i, --interval    Polling interval in seconds (default: 10)
  -p, --project     Project number (default from .project-config.json or $GH_PROJECT_NUMBER)
  -o, --owner       Project owner (default from .project-config.json or $GH_PROJECT_OWNER)
  -h, --help        Show this help message
EOF
  exit "${1:-0}"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${ROOT_DIR}/.project-config.json"

TARGET_STATUS=""
TARGET_ATTENTION="Standard"
POLL_INTERVAL=10
PROJECT_NUMBER=""
PROJECT_OWNER=""
STATUS_FIELD="Status"
ATTENTION_FIELD="Attention"

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
    -i|--interval)
      POLL_INTERVAL="$2"
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
    *)
      if [[ -z "$TARGET_STATUS" ]]; then
        TARGET_STATUS="$1"
      elif [[ -z "${2:-}" ]] && [[ "$1" =~ ^[0-9]+$ ]]; then
        POLL_INTERVAL="$1"
      fi
      shift
      ;;
  esac
done

if [[ -z "$TARGET_STATUS" ]]; then
  echo "Error: Missing required parameter: --status" >&2
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

trap 'echo ""; echo "[poll-project] Polling aborted."; exit 130' INT TERM

echo "[poll-project] Watching Project #${PROJECT_NUMBER} (${PROJECT_OWNER}) for items with Status='${TARGET_STATUS}' and Attention='${TARGET_ATTENTION}' (interval: ${POLL_INTERVAL}s)..."

while true; do
  FOUND=$(
    python3 - <<PYEOF
import subprocess, json, sys

cmd = [
    "${GH_CMD}", "project", "item-list", "${PROJECT_NUMBER}",
    "--owner", "${PROJECT_OWNER}",
    "--format", "json"
]

try:
    res = subprocess.run(cmd, capture_output=True, text=True, check=True)
    data = json.loads(res.stdout)
except Exception:
    sys.exit(0)

target_status = "${TARGET_STATUS}".strip().lower()
target_attention = "${TARGET_ATTENTION}".strip().lower()
status_field = "${STATUS_FIELD}".strip().lower()
attention_field = "${ATTENTION_FIELD}".strip().lower()

for item in data.get("items", []):
    item_status = ""
    item_attention = ""

    # Look for status and attention in top-level or fields
    for k, v in item.items():
        lk = k.strip().lower()
        if lk == status_field or lk == "status":
            item_status = str(v).strip().lower() if v is not None else ""
        elif lk == attention_field or lk == "attention":
            item_attention = str(v).strip().lower() if v is not None else ""

    # If attention field is not set on item, treat as "standard"
    if not item_attention:
        item_attention = "standard"

    if item_status == target_status and item_attention == target_attention:
        content = item.get("content", {})
        num = content.get("number")
        title = content.get("title", "")
        url = content.get("url", "")
        item_id = item.get("id", "")
        if num is not None:
            print(f"{num}\t{title}\t{url}\t{item_id}")
            sys.exit(0)
PYEOF
  )

  if [[ -n "$FOUND" ]]; then
    ISSUE_NUM=$(echo "$FOUND" | cut -f1)
    ISSUE_TITLE=$(echo "$FOUND" | cut -f2)
    ISSUE_URL=$(echo "$FOUND" | cut -f3)
    ITEM_ID=$(echo "$FOUND" | cut -f4)

    echo ""
    echo "[poll-project] MATCH FOUND!"
    echo "  Issue   : #${ISSUE_NUM} - ${ISSUE_TITLE}"
    echo "  Status  : ${TARGET_STATUS}"
    echo "  Attention: ${TARGET_ATTENTION}"
    echo "  Item ID : ${ITEM_ID}"
    echo "  URL     : ${ISSUE_URL}"
    echo ""
    exit 0
  fi

  sleep "$POLL_INTERVAL"
done
