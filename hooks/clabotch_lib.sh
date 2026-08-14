#!/usr/bin/env bash
# Clabotch hook helper — v11
# jq が必須依存。起動時に存在確認して早期失敗させる。

# TMPDIR 末尾の / を正規化（macOS は通常 / 付きだが保証はない）
_TMPDIR="${TMPDIR%/}"
SOCK="${_TMPDIR}/clabotch/hook.sock"
SESSION_REGISTRY="${_TMPDIR}/clabotch_sessions"

# ── jq 必須チェック ────────────────────────────────────────────────────────
# jq がなければ非ブロッキングエラー（exit 1）で即終了。
# Claude Code は exit 1 をエラーとして stderr に出力するだけで続行する。
# 修正方法: brew install jq
if ! command -v jq &>/dev/null; then
  echo "[clabotch] ERROR: jq is required. Install with: brew install jq" >&2
  exit 1
fi

generate_uuid() {
  uuidgen | tr '[:upper:]' '[:lower:]'
}

# session_id のバリデーション
# 安全な文字種（英数字、ハイフン、アンダースコア、ドット）のみ許可。
# パストラバーサル（/, ..）と JSON インジェクション（", \, 改行）を防ぐ。
# 不正な値は drop-and-log で呼び元に返す（return 1）。
validate_session_id() {
  local sid="$1"
  # "." / ".." はファイルパスとして特殊なため明示拒否
  if [[ "$sid" == "." || "$sid" == ".." ]]; then
    echo "[clabotch] WARN: session_id is a reserved path name ('$sid'), dropping event" >&2
    return 1
  fi
  if [[ ! "$sid" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
    echo "[clabotch] WARN: session_id contains unsafe characters, dropping event" >&2
    return 1
  fi
  return 0
}

# ソケットが利用可能かチェック（送信前判定用）
is_socket_available() {
  [[ -S "$SOCK" ]]
}

# JSON 文字列エスケープ（v10: jq -R . に変更）
# 出力形式: surrounding " を含む JSON 文字列
#   例) 入力: hello "world"\n → 出力: "hello \"world\"\n"
# printf フォーマット内では %s で受け取る（" は不要）
json_escape() {
  printf '%s' "$1" | jq -R .
}

# stdin JSON を読む（必須: 読まないと EPIPE が発生する）
read_stdin() {
  cat
}

# session_id を stdin JSON から取得する
# jq 必須（fallback なし）。
# session_id が空のとき "unknown" を返さない → 呼び元でガードして drop-and-log する。
# $CLAUDE_SESSION_ID（v2.1.9+）は唯一の合法 fallback。
resolve_session_id() {
  local json="$1"
  local sid
  sid=$(printf '%s' "$json" | jq -r '.session_id // empty')
  # v2.1.9+ 環境変数 fallback（空のときのみ）
  echo "${sid:-${CLAUDE_SESSION_ID:-}}"
}

# tool_name を stdin JSON から取得する
# jq 必須（fallback なし）。
resolve_tool_name() {
  local json="$1"
  printf '%s' "$json" | jq -r '.tool_name // "unknown"'
}

# best-effort 送信
# 戻り値:
#   0 = nc が正常終了（実際に送れた）
#   1 = ソケット不在（Clabotch 未起動）
#   2 = nc が失敗（stale socket / 受信側再起動レース等）
# tool_end / session_done は戻り値を無視して best-effort。
# pre_tool のみ戻り値を見て marker（elapsed_ms 計算用の初回ツール時刻）作成を判断する。
send_json() {
  [[ -S "$SOCK" ]] || return 1
  if nc -w 1 -U "$SOCK" >/dev/null 2>&1; then
    return 0
  else
    return 2
  fi
}
