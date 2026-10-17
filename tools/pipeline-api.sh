#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# tools/pipeline-api.sh - CLI Client & Daemon Manager for pipeline-server.mjs
#
# Provides zero-rate-limit local REST API queries and mutations for agents:
#   - Auto-starts tools/pipeline-server.mjs in background if not running.
#   - Replaces direct `gh issue view`, `gh issue edit`, `gh issue comment`,
#     `gh pr checks`, and `gh pr review` with cached/batched local REST calls.
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${ROOT_DIR}/.project-config.json"

PORT="${GH_PIPELINE_PORT:-4100}"
HOST="${GH_PIPELINE_HOST:-127.0.0.1}"
if [[ -f "$CONFIG_FILE" ]] && [[ -z "${GH_PIPELINE_PORT:-}" ]]; then
  CFG_PORT=$(node -e "try{const d=JSON.parse(require('fs').readFileSync('$CONFIG_FILE','utf8'));if(d.proxyPort)console.log(d.proxyPort);}catch{}" 2>/dev/null || true)
  PORT="${CFG_PORT:-$PORT}"
fi

BASE_URL="http://${HOST}:${PORT}"
PID_FILE="/tmp/gh-pipeline-server-${PORT}.pid"
LOG_FILE="/tmp/gh-pipeline-server-${PORT}.log"

usage() {
  cat <<'EOF'
Usage:
  tools/pipeline-api.sh <COMMAND> [ARGS...]

Daemon Management:
  start                                     Start local REST proxy server in background
  stop                                      Stop background proxy server
  status                                    Query proxy /health endpoint and rate-limit stats
  ensure                                    Ensure proxy server is running (auto-starts if down)

Agent Query & Mutation Commands (Zero GraphQL Rate-Limit Burn):
  issue <ISSUE_NUM>                         Get full hydrated issue context (body, comments, linked PR, CI checks)
  edit-issue <ISSUE_NUM> [--title "<T>"] [--body "<B>" | --body-file -]
                                            Update issue title and/or body via REST queue
  comment-issue <ISSUE_NUM> [--body "<B>" | --body-file -]
                                            Post issue comment via paced REST queue
  transition <ISSUE_NUM> [--status "<S>"] [--attention "<A>"] [--comment "<C>"] [--reset-bounces]
                                            Atomically transition board state + circuit breaker + instant wakeup
  checks <PR_NUM> [--wait]                  Get or wait for PR CI checks via ETag-cached REST (0 GraphQL pts)
  comment-pr <PR_NUM> [--body "<B>" | --body-file -]
                                            Post PR comment via paced REST queue
  review-pr <PR_NUM> (--approve | --request-changes | --comment) [--body "<B>" | --body-file -]
                                            Submit PR review via paced REST queue
EOF
  exit "${1:-0}"
}

is_running() {
  curl -fsS --max-time 2 "${BASE_URL}/health" >/dev/null 2>&1
}

ensure_server() {
  if is_running; then
    return 0
  fi
  nohup node "${SCRIPT_DIR}/pipeline-server.mjs" >"$LOG_FILE" 2>&1 &
  local pid=$!
  echo "$pid" >"$PID_FILE"
  for _ in {1..25}; do
    if is_running; then
      return 0
    fi
    sleep 0.1
  done
  echo "Error: Failed to start pipeline-server.mjs on ${BASE_URL} (see ${LOG_FILE})" >&2
  return 1
}

stop_server() {
  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid=$(cat "$PID_FILE" 2>/dev/null || true)
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      sleep 0.2
    fi
    rm -f "$PID_FILE"
  fi
  pkill -f "pipeline-server.mjs" 2>/dev/null || true
  echo "[pipeline-api] Server stopped."
}

read_body_arg() {
  local body_val="$1"
  local body_file="$2"
  if [[ -n "$body_file" ]]; then
    if [[ "$body_file" == "-" ]]; then
      cat
    else
      cat "$body_file"
    fi
  else
    printf "%s" "$body_val"
  fi
}

CMD="${1:-}"
if [[ -z "$CMD" ]] || [[ "$CMD" == "-h" ]] || [[ "$CMD" == "--help" ]]; then
  usage 0
fi
shift

case "$CMD" in
  start|ensure)
    ensure_server
    echo "[pipeline-api] Server running at ${BASE_URL}"
    ;;
  stop)
    stop_server
    ;;
  status|health)
    ensure_server
    curl -fsS "${BASE_URL}/health"
    echo ""
    ;;
  issue|context)
    ISSUE_NUM="${1:-}"
    [[ -z "$ISSUE_NUM" ]] && { echo "Error: Missing ISSUE_NUM" >&2; exit 1; }
    ISSUE_NUM="${ISSUE_NUM#"#"}"
    ensure_server
    curl -fsS "${BASE_URL}/issues/${ISSUE_NUM}/context"
    echo ""
    ;;
  edit-issue)
    ISSUE_NUM="${1:-}"
    [[ -z "$ISSUE_NUM" ]] && { echo "Error: Missing ISSUE_NUM" >&2; exit 1; }
    ISSUE_NUM="${ISSUE_NUM#"#"}"
    shift
    TITLE=""
    BODY_VAL=""
    BODY_FILE=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -t|--title) TITLE="$2"; shift 2 ;;
        -b|--body) BODY_VAL="$2"; shift 2 ;;
        -F|--body-file) BODY_FILE="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    FINAL_BODY=$(read_body_arg "$BODY_VAL" "$BODY_FILE")
    PAYLOAD=$(node -e '
      const [title, body, hasBody] = process.argv.slice(1);
      const p = {};
      if (title) p.title = title;
      if (hasBody === "1") p.body = body;
      console.log(JSON.stringify(p));
    ' "$TITLE" "$FINAL_BODY" "$([[ -n "$BODY_VAL" || -n "$BODY_FILE" ]] && echo 1 || echo 0)")
    ensure_server
    curl -fsS -X PATCH "${BASE_URL}/issues/${ISSUE_NUM}" -H "Content-Type: application/json" -d "$PAYLOAD"
    echo ""
    ;;
  comment-issue)
    ISSUE_NUM="${1:-}"
    [[ -z "$ISSUE_NUM" ]] && { echo "Error: Missing ISSUE_NUM" >&2; exit 1; }
    ISSUE_NUM="${ISSUE_NUM#"#"}"
    shift
    BODY_VAL=""
    BODY_FILE=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -b|--body) BODY_VAL="$2"; shift 2 ;;
        -F|--body-file) BODY_FILE="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    FINAL_BODY=$(read_body_arg "$BODY_VAL" "$BODY_FILE")
    PAYLOAD=$(node -e 'console.log(JSON.stringify({ body: process.argv[1] }))' "$FINAL_BODY")
    ensure_server
    curl -fsS -X POST "${BASE_URL}/issues/${ISSUE_NUM}/comment" -H "Content-Type: application/json" -d "$PAYLOAD"
    echo ""
    ;;
  transition|move)
    ISSUE_NUM="${1:-}"
    [[ -z "$ISSUE_NUM" ]] && { echo "Error: Missing ISSUE_NUM" >&2; exit 1; }
    ISSUE_NUM="${ISSUE_NUM#"#"}"
    shift
    STATUS_VAL=""
    ATT_VAL=""
    COMMENT_VAL=""
    MAX_BOUNCES=""
    RESET_BOUNCES="0"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -s|--status) STATUS_VAL="$2"; shift 2 ;;
        -a|--attention) ATT_VAL="$2"; shift 2 ;;
        -c|--comment) COMMENT_VAL="$2"; shift 2 ;;
        --max-bounces) MAX_BOUNCES="$2"; shift 2 ;;
        --reset-bounces) RESET_BOUNCES="1"; shift ;;
        *) shift ;;
      esac
    done
    PAYLOAD=$(node -e '
      const [status, attention, comment, maxB, resetB] = process.argv.slice(1);
      const p = {};
      if (status) p.status = status;
      if (attention) p.attention = attention;
      if (comment) p.comment = comment;
      if (maxB) p.max_bounces = Number(maxB);
      if (resetB === "1") p.reset_bounces = true;
      console.log(JSON.stringify(p));
    ' "$STATUS_VAL" "$ATT_VAL" "$COMMENT_VAL" "$MAX_BOUNCES" "$RESET_BOUNCES")
    ensure_server
    curl -fsS -X POST "${BASE_URL}/issues/${ISSUE_NUM}/transition" -H "Content-Type: application/json" -d "$PAYLOAD"
    echo ""
    ;;
  checks)
    PR_NUM="${1:-}"
    [[ -z "$PR_NUM" ]] && { echo "Error: Missing PR_NUM" >&2; exit 1; }
    PR_NUM="${PR_NUM#"#"}"
    shift
    WAIT_FLAG="0"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -w|--wait|--watch) WAIT_FLAG="1"; shift ;;
        *) shift ;;
      esac
    done
    ensure_server
    RES=$(curl -fsS "${BASE_URL}/prs/${PR_NUM}/checks?wait=${WAIT_FLAG}")
    echo "$RES"
    STATE=$(node -e 'const d=JSON.parse(process.argv[1]); console.log(d.checks?.state || "unknown");' "$RES")
    [[ "$STATE" == "failure" ]] && exit 1
    exit 0
    ;;
  comment-pr)
    PR_NUM="${1:-}"
    [[ -z "$PR_NUM" ]] && { echo "Error: Missing PR_NUM" >&2; exit 1; }
    PR_NUM="${PR_NUM#"#"}"
    shift
    BODY_VAL=""
    BODY_FILE=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -b|--body) BODY_VAL="$2"; shift 2 ;;
        -F|--body-file) BODY_FILE="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    FINAL_BODY=$(read_body_arg "$BODY_VAL" "$BODY_FILE")
    PAYLOAD=$(node -e 'console.log(JSON.stringify({ body: process.argv[1] }))' "$FINAL_BODY")
    ensure_server
    curl -fsS -X POST "${BASE_URL}/prs/${PR_NUM}/comment" -H "Content-Type: application/json" -d "$PAYLOAD"
    echo ""
    ;;
  review-pr)
    PR_NUM="${1:-}"
    [[ -z "$PR_NUM" ]] && { echo "Error: Missing PR_NUM" >&2; exit 1; }
    PR_NUM="${PR_NUM#"#"}"
    shift
    EVENT="COMMENT"
    BODY_VAL=""
    BODY_FILE=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --approve) EVENT="APPROVE"; shift ;;
        --request-changes) EVENT="REQUEST_CHANGES"; shift ;;
        --comment) EVENT="COMMENT"; shift ;;
        -b|--body) BODY_VAL="$2"; shift 2 ;;
        -F|--body-file) BODY_FILE="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    FINAL_BODY=$(read_body_arg "$BODY_VAL" "$BODY_FILE")
    PAYLOAD=$(node -e 'console.log(JSON.stringify({ event: process.argv[1], body: process.argv[2] }))' "$EVENT" "$FINAL_BODY")
    ensure_server
    curl -fsS -X POST "${BASE_URL}/prs/${PR_NUM}/review" -H "Content-Type: application/json" -d "$PAYLOAD"
    echo ""
    ;;
  *)
    echo "Error: Unknown command '$CMD'" >&2
    usage 1
    ;;
esac
