#!/usr/bin/env bash
# PostToolUse: 成功時のみ発火。is_error=false 固定。
# duration は $CLAUDE_TOOL_DURATION（ms）で取得。
source "$(dirname "$0")/clabotch_lib.sh"

# ① stdin を必ず読む
HOOK_JSON=$(read_stdin)
SESSION_ID=$(resolve_session_id "$HOOK_JSON")

if [[ -z "$SESSION_ID" ]]; then
  echo "[clabotch] WARN: session_id missing in PostToolUse payload, dropping event" >&2
  exit 1
fi

if ! validate_session_id "$SESSION_ID"; then
  exit 1
fi

TOOL_QUOTED=$(json_escape "$(resolve_tool_name "$HOOK_JSON")")
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ② session_start（冪等、再同期用）+ tool_end を1接続・1回の write で送信
# 長時間ツールの実行中にアプリ側がセッションを reap した場合でも、
# この再送で tool_end が破棄されず再同期される。tool_name は %s（json_escape が " を含む）。
SS_LINE=$(printf '{"schema_version":"1","event":"session_start","session_id":"%s","event_id":"%s","timestamp":"%s"}' \
  "$SESSION_ID" "$(generate_uuid)" "$NOW")
TE_LINE=$(printf '{"schema_version":"1","event":"tool_end","session_id":"%s","event_id":"%s","timestamp":"%s","tool_name":%s,"duration_ms":%s,"is_error":false,"error_message":null}' \
  "$SESSION_ID" "$(generate_uuid)" "$NOW" "$TOOL_QUOTED" \
  "${CLAUDE_TOOL_DURATION:-0}")
printf '%s\n%s\n' "$SS_LINE" "$TE_LINE" | send_json || true
