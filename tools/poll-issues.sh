#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# GitHub Issue Poller for Automated Agent Workflows
# Polls GitHub repository until an open issue with the specified label is found.
# Exits with status 0 upon match so background agent tasks wake up reactively.
# -----------------------------------------------------------------------------

usage() {
  cat <<'EOF'
Usage:
  tools/poll-issues.sh "<LABEL>" [INTERVAL_SECONDS] [REPO]
  tools/poll-issues.sh --label "<LABEL>" [--interval 10] [--repo da4h/ui]

Arguments:
  LABEL            Label to watch for (e.g. "Requirement", "Implementation plan", "Plan review", "Ready")
  INTERVAL_SECONDS Polling interval in seconds (default: 10)
  REPO             GitHub repository in owner/repo format (default: auto-detected or da4h/ui)

Options:
  -l, --label      Label to watch for
  -i, --interval   Polling interval in seconds (default: 10)
  -r, --repo       Repository (e.g. da4h/ui)
  -h, --help       Show this help message
EOF
  exit "${1:-0}"
}

LABEL=""
POLL_INTERVAL=10
REPO=""

# Parse arguments (supports positional and flagged)
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage 0
      ;;
    -l|--label)
      LABEL="$2"
      shift 2
      ;;
    -i|--interval)
      POLL_INTERVAL="$2"
      shift 2
      ;;
    -r|--repo)
      REPO="$2"
      shift 2
      ;;
    *)
      if [ -z "$LABEL" ]; then
        LABEL="$1"
      elif [ -z "${2:-}" ] && [[ "$1" =~ ^[0-9]+$ ]]; then
        POLL_INTERVAL="$1"
      elif [ -z "$REPO" ]; then
        REPO="$1"
      fi
      shift
      ;;
  esac
done

if [ -z "$LABEL" ]; then
  echo "Error: Missing required parameter: LABEL" >&2
  usage 1
fi

# Detect gh / gh-bot command
GH_CMD="gh"
if command -v gh-bot &>/dev/null; then
  GH_CMD="gh-bot"
elif [ -x "$HOME/.config/gh/gh-bot" ]; then
  GH_CMD="$HOME/.config/gh/gh-bot"
fi

# Auto-detect repo if not specified
if [ -z "$REPO" ]; then
  DETECTED_REPO=$("$GH_CMD" repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
  if [ -n "$DETECTED_REPO" ]; then
    REPO="$DETECTED_REPO"
  else
    REPO="da4h/ui"
  fi
fi

trap 'echo ""; echo "[poll-issues] Polling aborted."; exit 130' INT TERM

echo "[poll-issues] Watching ${REPO} for open issues with label '${LABEL}' (interval: ${POLL_INTERVAL}s)..."

while true; do
  FOUND=$("$GH_CMD" issue list \
    --repo "$REPO" \
    --state open \
    --label "$LABEL" \
    --json number,title,url \
    --jq '.[0] | select(. != null) | "\(.number)\t\(.title)\t\(.url)"' 2>/dev/null || true)

  if [ -n "$FOUND" ]; then
    IFS=$'\t' read -r ISSUE_NUM ISSUE_TITLE ISSUE_URL <<< "$FOUND"
    echo ""
    echo "[poll-issues] MATCH FOUND!"
    echo "Issue #${ISSUE_NUM}: ${ISSUE_TITLE}"
    echo "URL: ${ISSUE_URL}"
    exit 0
  fi

  sleep "$POLL_INTERVAL"
done
