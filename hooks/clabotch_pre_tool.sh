#!/usr/bin/env bash
# PreToolUse: session_start（冪等、毎回）+ tool_start を送る
source "$(dirname "$0")/clabotch_lib.sh"

# ① stdin を必ず読む（EPIPE 防止）
HOOK_JSON=$(read_stdin)
SESSION_ID=$(resolve_session_id "$HOOK_JSON")

# session_id が取れなければ drop-and-log（exit 1 = 非ブロッキングエラー）
# "unknown" を合成しないことで SESSION_REGISTRY への汚染を防ぐ
if [[ -z "$SESSION_ID" ]]; then
  echo "[clabotch] WARN: session_id missing in PreToolUse payload, dropping event" >&2
  exit 1
fi

# session_id の文字種バリデーション（パストラバーサル・JSON インジェクション防止）
if ! validate_session_id "$SESSION_ID"; then
  exit 1
fi

# TOOL_QUOTED: surrounding " 込みの JSON 文字列  例) "Bash"
TOOL_QUOTED=$(json_escape "$(resolve_tool_name "$HOOK_JSON")")
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ② session_start（冪等）+ tool_start を1接続で送信（順序保証）
# session_start は毎回送る。アプリ側は登録済みセッションなら no-op（§14.3 不変条件 4）なので、
# アプリ再起動やセッションタイムアウト（reap）後もこの再送だけで即座に再同期される。
# 1つの nc 接続に NDJSON で連結して送ることで、接続内の serial queue で順序を保証する。
# marker（SESSION_START_FILE）は elapsed_ms 計算用の初回ツール時刻の記録専用。
SESSION_START_FILE="${SESSION_REGISTRY}/${SESSION_ID}"
mkdir -p "$SESSION_REGISTRY"

# NDJSON ペイロードを構築して1接続・1回の write で送信
# （受信側 LineBufferedEventDecoder はチャンク分割を扱えるが、全体で PIPE_BUF 未満の
#   単一 write は防御的に確実で、nc キャプチャによるテストも容易になる）
SS_LINE=$(printf '{"schema_version":"1","event":"session_start","session_id":"%s","event_id":"%s","timestamp":"%s"}' \
  "$SESSION_ID" "$(generate_uuid)" "$NOW")
TS_LINE=$(printf '{"schema_version":"1","event":"tool_start","session_id":"%s","event_id":"%s","timestamp":"%s","tool_name":%s}' \
  "$SESSION_ID" "$(generate_uuid)" "$NOW" "$TOOL_QUOTED")
printf '%s\n%s\n' "$SS_LINE" "$TS_LINE" | send_json
SEND_RC=$?
if [[ "$SEND_RC" -eq 0 && ! -f "$SESSION_START_FILE" ]]; then
  date +%s > "$SESSION_START_FILE"
fi
