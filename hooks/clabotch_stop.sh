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
if [[ -f "$SESSION_START_FILE" ]]; then
  START_EPOCH=$(cat "$SESSION_START_FILE")
  ELAPSED_MS=$(( ($(date +%s) - START_EPOCH) * 1000 ))
  # 時計逆行（NTP ステップ等）で負になり得る。負値は parser に破棄されるため 0 に clamp し、
  # app 側の startedAt フォールバック計算に委ねる。
  [[ "$ELAPSED_MS" -lt 0 ]] && ELAPSED_MS=0
  rm -f "$SESSION_START_FILE"
fi

# ③ session_start（冪等、再同期用）+ session_done を1接続・1回の write で送信
# 他 hook と同様に毎回 session_start を同送する: セッション reap やアプリ再起動後の
# Stop でも自セッションとして正規の done 表示になる（登録済みなら no-op）。
# ツール未使用セッション（marker なし, elapsed_ms=0）は app 側が startedAt から計算する。
SS_LINE=$(printf '{"schema_version":"1","event":"session_start","session_id":"%s","event_id":"%s","timestamp":"%s"}' \
  "$SESSION_ID" "$(generate_uuid)" "$NOW")
DONE_LINE=$(printf '{"schema_version":"1","event":"session_done","session_id":"%s","event_id":"%s","timestamp":"%s","elapsed_ms":%d}' \
  "$SESSION_ID" "$(generate_uuid)" "$NOW" "$ELAPSED_MS")
printf '%s\n%s\n' "$SS_LINE" "$DONE_LINE" | send_json || true
