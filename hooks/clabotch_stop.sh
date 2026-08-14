#!/usr/bin/env bash
# Stop: セッション完了。elapsed_ms を計算して session_done を送る。
source "$(dirname "$0")/clabotch_lib.sh"

# ① stdin を必ず読む
HOOK_JSON=$(read_stdin)
SESSION_ID=$(resolve_session_id "$HOOK_JSON")

if [[ -z "$SESSION_ID" ]]; then
  echo "[clabotch] WARN: session_id missing in Stop payload, dropping event" >&2
  exit 1
fi

if ! validate_session_id "$SESSION_ID"; then
  exit 1
fi

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ② 開始時刻ファイルから elapsed_ms を計算
SESSION_START_FILE="${SESSION_REGISTRY}/${SESSION_ID}"
ELAPSED_MS=0
NEEDS_SESSION_START=false
if [[ -f "$SESSION_START_FILE" ]]; then
  START_EPOCH=$(cat "$SESSION_START_FILE")
  ELAPSED_MS=$(( ($(date +%s) - START_EPOCH) * 1000 ))
  rm -f "$SESSION_START_FILE"
else
  # ツール未使用セッション: PreToolUse が未発火のため SESSION_START_FILE がない。
  # session_start を同時送信して app にセッションを認識させる。
  # app 側の StateMachine が startedAt からフォールバック計算を行う。
  NEEDS_SESSION_START=true
  mkdir -p "$SESSION_REGISTRY"
fi

# ③ session_start（必要時）+ session_done を1接続・1回の write で送信
DONE_LINE=$(printf '{"schema_version":"1","event":"session_done","session_id":"%s","event_id":"%s","timestamp":"%s","elapsed_ms":%d}' \
  "$SESSION_ID" "$(generate_uuid)" "$NOW" "$ELAPSED_MS")
if [[ "$NEEDS_SESSION_START" == "true" ]]; then
  SS_LINE=$(printf '{"schema_version":"1","event":"session_start","session_id":"%s","event_id":"%s","timestamp":"%s"}' \
    "$SESSION_ID" "$(generate_uuid)" "$NOW")
  printf '%s\n%s\n' "$SS_LINE" "$DONE_LINE" | send_json || true
else
  printf '%s\n' "$DONE_LINE" | send_json || true
fi
