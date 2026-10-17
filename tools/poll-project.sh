#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# GitHub Project Poller for Automated Agent Workflows
# Polls a GitHub Projects v2 board until an open item with the specified
# status and attention values is found.
# Exits with status 0 upon match so background agent tasks wake up reactively.
#
# Rate-Limit Optimizations:
#   - Shared short-lived local cache (/tmp/gh-project-cache-<owner>-<num>.json)
#     with file-locking across concurrent subagent workers (TTL: 25s).
#   - Default interval set to 30s (prevents token exhaustion).
#   - Rate-limit aware backoff if GraphQL quota drops below critical threshold.
# -----------------------------------------------------------------------------

usage() {
  cat <<'EOF'
Usage:
  tools/poll-project.sh --status "<STATUS>" [--attention "<ATTENTION>"] [--interval 30] [--cache-ttl 25]
  tools/poll-project.sh "<STATUS>" [INTERVAL_SECONDS]

Options:
  -s, --status            Target column/status (e.g. "PM", "Senior Dev", "Architect", "Implementer", "Code Review", "QA", "Done" or role aliases like "role-implementer")
  -a, --attention         Target attention swimlane (default: "Standard", supports aliases like "needs-decision")
  -i, --interval          Polling interval in seconds (default: 30)
  -c, --cache-ttl         Cache TTL in seconds (default: 25)
  -p, --project           Project number (default from .project-config.json or $GH_PROJECT_NUMBER)
  -o, --owner             Project owner (default from .project-config.json or $GH_PROJECT_OWNER)
  -q, --compact           Compact single-line match banner (saves LLM tokens)
  --auto-bounce-ci        Auto-bounce issue to Implementer if PR checks are failing (zero-token gatekeeper)
  -h, --help              Show this help message
EOF
  exit "${1:-0}"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${ROOT_DIR}/.project-config.json"

TARGET_STATUS=""
TARGET_ATTENTION="Standard"
POLL_INTERVAL=30
CACHE_TTL=25
PROJECT_NUMBER=""
PROJECT_OWNER=""
STATUS_FIELD="Status"
ATTENTION_FIELD="Attention"
COMPACT=0
AUTO_BOUNCE_CI=0

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
POLL_INTERVAL="${GH_PROJECT_POLL_INTERVAL:-$POLL_INTERVAL}"
CACHE_TTL="${GH_PROJECT_CACHE_TTL:-$CACHE_TTL}"

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
    -c|--cache-ttl)
      CACHE_TTL="$2"
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
    -q|--compact)
      COMPACT=1
      shift
      ;;
      --auto-bounce-ci)
      AUTO_BOUNCE_CI=1
      shift
      ;;
    --no-proxy)
      USE_PROXY=0
      shift
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

USE_PROXY="${USE_PROXY:-${GH_PIPELINE_USE_PROXY:-1}}"
PROXY_PORT="${GH_PIPELINE_PORT:-4100}"
PROXY_HOST="${GH_PIPELINE_HOST:-127.0.0.1}"

trap 'echo ""; echo "[poll-project] Polling aborted."; exit 130' INT TERM

echo "[poll-project] Watching Project #${PROJECT_NUMBER} (${PROJECT_OWNER}) for items with Status='${TARGET_STATUS}' and Attention='${TARGET_ATTENTION}' (interval: ${POLL_INTERVAL}s, cache TTL: ${CACHE_TTL}s)..."

while true; do
  # Fast Path: Query Local Node.js REST Proxy (EventEmitter instant wakeup + ETag/Slim GraphQL)
  if [[ "$USE_PROXY" -eq 1 ]] && [[ -x "${SCRIPT_DIR}/pipeline-api.sh" ]]; then
    if "${SCRIPT_DIR}/pipeline-api.sh" ensure >/dev/null 2>&1; then
      ENC_STATUS=$(node -e 'console.log(encodeURIComponent(process.argv[1]))' "$TARGET_STATUS")
      ENC_ATT=$(node -e 'console.log(encodeURIComponent(process.argv[1]))' "$TARGET_ATTENTION")
      POLL_RESP=$(curl -fsS --max-time $((POLL_INTERVAL + 10)) "http://${PROXY_HOST}:${PROXY_PORT}/poll?status=${ENC_STATUS}&attention=${ENC_ATT}&auto_bounce_ci=${AUTO_BOUNCE_CI}&timeout=${POLL_INTERVAL}" 2>/dev/null || true)
      if [[ -n "$POLL_RESP" ]]; then
        PARSED=$(node -e '
          try {
            const d = JSON.parse(process.argv[1]);
            if (d.matched && d.item) {
              console.log(`${d.item.number}\t${d.item.title || ""}\t${d.item.url || ""}\t${d.item.itemId || ""}`);
            }
          } catch {}
        ' "$POLL_RESP" 2>/dev/null || true)
        if [[ -n "$PARSED" ]]; then
          ISSUE_NUM=$(echo "$PARSED" | cut -f1)
          ISSUE_TITLE=$(echo "$PARSED" | cut -f2)
          ISSUE_URL=$(echo "$PARSED" | cut -f3)
          ITEM_ID=$(echo "$PARSED" | cut -f4)
          if [[ "$COMPACT" -eq 1 ]]; then
            echo "[poll-project] MATCH: #${ISSUE_NUM} \"${ISSUE_TITLE}\" (Status: ${TARGET_STATUS}, ID: ${ITEM_ID})"
          else
            echo ""
            echo "[poll-project] MATCH FOUND!"
            echo "  Issue   : #${ISSUE_NUM} - ${ISSUE_TITLE}"
            echo "  Status  : ${TARGET_STATUS}"
            echo "  Attention: ${TARGET_ATTENTION}"
            echo "  Item ID : ${ITEM_ID}"
            echo "  URL     : ${ISSUE_URL}"
            echo ""
          fi
          exit 0
        fi
        continue
      fi
    fi
  fi

  FOUND=$(
    python3 - <<PYEOF
import subprocess, json, sys, os, time, fcntl

gh_cmd = "${GH_CMD}"
owner = "${PROJECT_OWNER}"
p_num = "${PROJECT_NUMBER}"
target_status = "${TARGET_STATUS}".strip().lower()
target_attention = "${TARGET_ATTENTION}".strip().lower()
status_field = "${STATUS_FIELD}".strip().lower()
attention_field = "${ATTENTION_FIELD}".strip().lower()
cache_ttl = int("${CACHE_TTL}")

cache_file = f"/tmp/gh-project-cache-{owner}-{p_num}.json"
lock_file = f"/tmp/gh-project-cache-{owner}-{p_num}.lock"

def check_rate_limit():
    try:
        res = subprocess.run([gh_cmd, "api", "rate_limit"], capture_output=True, text=True)
        if res.returncode == 0:
            rl_data = json.loads(res.stdout)
            gql = rl_data.get("resources", {}).get("graphql", {})
            rem = gql.get("remaining", 5000)
            reset_ts = gql.get("reset", 0)
            if rem < 200:
                wait_sec = max(5, int(reset_ts - time.time()) + 1)
                sys.stderr.write(f"\n[poll-project] WARNING: Rate limit low (remaining: {rem}). Sleeping {wait_sec}s until reset...\n")
                time.sleep(wait_sec)
    except Exception:
        pass

def fetch_project_items():
    # 1. Check if cache is fresh
    if os.path.exists(cache_file):
        try:
            mtime = os.path.getmtime(cache_file)
            if (time.time() - mtime) < cache_ttl:
                with open(cache_file, "r") as f:
                    return json.load(f)
        except Exception:
            pass

    # 2. Acquire lock to refresh cache
    with open(lock_file, "w") as lf:
        try:
            fcntl.flock(lf, fcntl.LOCK_EX)
            # Re-check cache freshness after lock acquisition
            if os.path.exists(cache_file):
                try:
                    mtime = os.path.getmtime(cache_file)
                    if (time.time() - mtime) < cache_ttl:
                        with open(cache_file, "r") as f:
                            return json.load(f)
                except Exception:
                    pass

            item_limit = os.environ.get("GH_PROJECT_ITEM_LIMIT", "100")
            cmd = [
                gh_cmd, "project", "item-list", p_num,
                "--owner", owner,
                "--limit", item_limit,
                "--format", "json"
            ]
            res = subprocess.run(cmd, capture_output=True, text=True)
            if res.returncode != 0:
                if "rate limit" in res.stderr.lower():
                    check_rate_limit()
                sys.exit(0)

            data = json.loads(res.stdout)
            # Write atomically to cache
            temp_cache = f"{cache_file}.tmp.{os.getpid()}"
            with open(temp_cache, "w") as f:
                json.dump(data, f)
            os.replace(temp_cache, cache_file)
            return data
        finally:
            fcntl.flock(lf, fcntl.LOCK_UN)

try:
    data = fetch_project_items()
except Exception:
    sys.exit(0)

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

ATTENTION_ALIASES = {
    "standard": "standard",
    "needs decision": "needs decision",
    "needs-decision": "needs decision",
    "needs_decision": "needs decision",
    "decision": "needs decision",
}

norm_target_status = STATUS_ALIASES.get(target_status, target_status)
norm_target_attention = ATTENTION_ALIASES.get(target_attention, target_attention)

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

    norm_item_status = STATUS_ALIASES.get(item_status, item_status)
    norm_item_attention = ATTENTION_ALIASES.get(item_attention, item_attention)

    match_status = (item_status == target_status or norm_item_status == norm_target_status)
    match_attention = (item_attention == target_attention or norm_item_attention == norm_target_attention)

    if match_status and match_attention:
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

    # Zero-Token Script Gatekeeper: Auto-bounce on merge conflicts or red CI checks, wait on pending CI
    if [[ "$AUTO_BOUNCE_CI" -eq 1 ]]; then
      PR_JSON=$($GH_CMD pr list --search "${ISSUE_NUM}" --state open --json number,mergeable,statusCheckRollup 2>/dev/null || true)
      if [[ -n "$PR_JSON" && "$PR_JSON" != "[]" ]]; then
        PR_META=$(python3 -c "import json, sys; d=json.loads(sys.argv[1]); print(f\"{d[0].get('number', '')}\t{d[0].get('mergeable', '')}\" if d else '')" "$PR_JSON" 2>/dev/null || true)
        PR_NUM=$(echo "$PR_META" | cut -f1)
        PR_MERGEABLE=$(echo "$PR_META" | cut -f2)
        if [[ -n "$PR_NUM" ]]; then
          # 1. Zero-Token Merge Conflict Gatekeeper
          if [[ "$PR_MERGEABLE" == "CONFLICTING" ]]; then
            echo "[poll-project] MERGE CONFLICT DETECTED on PR #${PR_NUM} (Issue #${ISSUE_NUM}). Auto-bouncing to Implementer..."
            $GH_CMD pr comment "$PR_NUM" --body "❌ Merge conflict with base branch detected (\`mergeable: CONFLICTING\`). Bouncing issue back to Implementer to rebase onto latest \`origin/master\`." >/dev/null 2>&1 || true
            "${SCRIPT_DIR}/project-move.sh" "${ISSUE_NUM}" --status "Implementer" --attention "Standard" >/dev/null 2>&1 || true
            CACHE_FILE="/tmp/gh-project-cache-${PROJECT_OWNER}-${PROJECT_NUMBER}.json"
            rm -f "$CACHE_FILE"
            sleep "$POLL_INTERVAL"
            continue
          fi

          # 2. CI Checks Gatekeeper (Auto-bounce on failure, wait on pending)
          CHECKS_OUTPUT=$($GH_CMD pr checks "$PR_NUM" 2>&1 || true)
          if echo "$CHECKS_OUTPUT" | grep -qiE "(fail|error|cancel)"; then
            echo "[poll-project] CI FAILURE DETECTED on PR #${PR_NUM} (Issue #${ISSUE_NUM}). Auto-bouncing to Implementer..."
            $GH_CMD pr comment "$PR_NUM" --body "❌ Automated PR checks failed on CI. Bouncing issue back to Implementer:
\`\`\`
$(echo "$CHECKS_OUTPUT" | head -n 10)
\`\`\`" >/dev/null 2>&1 || true
            "${SCRIPT_DIR}/project-move.sh" "${ISSUE_NUM}" --status "Implementer" --attention "Standard" >/dev/null 2>&1 || true
            # Invalidate items cache so next poll iteration detects state change
            CACHE_FILE="/tmp/gh-project-cache-${PROJECT_OWNER}-${PROJECT_NUMBER}.json"
            rm -f "$CACHE_FILE"
            sleep "$POLL_INTERVAL"
            continue
          elif echo "$CHECKS_OUTPUT" | grep -qiE "(pending|in_progress|queued|waiting)"; then
            echo "[poll-project] CI PENDING on PR #${PR_NUM} (Issue #${ISSUE_NUM}). Waiting for checks to finish before waking agent..."
            sleep "$POLL_INTERVAL"
            continue
          fi
        fi
      fi
    fi

    if [[ "$COMPACT" -eq 1 ]]; then
      echo "[poll-project] MATCH: #${ISSUE_NUM} \"${ISSUE_TITLE}\" (Status: ${TARGET_STATUS}, ID: ${ITEM_ID})"
    else
      echo ""
      echo "[poll-project] MATCH FOUND!"
      echo "  Issue   : #${ISSUE_NUM} - ${ISSUE_TITLE}"
      echo "  Status  : ${TARGET_STATUS}"
      echo "  Attention: ${TARGET_ATTENTION}"
      echo "  Item ID : ${ITEM_ID}"
      echo "  URL     : ${ISSUE_URL}"
      echo ""
    fi
    exit 0
  fi

  sleep "$POLL_INTERVAL"
done
