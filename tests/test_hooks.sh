#!/usr/bin/env bash
# Clabotch Hook 疎通テスト
# 使い方: bash tests/test_hooks.sh
#
# すべての hook 呼び出しは隔離された TMPDIR で実行する（clabotch_lib.sh が
# TMPDIR から socket / registry パスを導出するため）。これにより:
#   - 起動中の実アプリの socket に誤送信しない
#   - 実 registry を汚染しない
# ペイロード検証は nc の Unix socket リスナーで 1 接続分をキャプチャして行う。
# set -e は使わない（テスト内で exit 1 を期待するため）
set -uo pipefail

HOOKS_DIR="$(cd "$(dirname "$0")/../hooks" && pwd)"
PASS=0
FAIL=0
TOTAL=0

# ── 隔離環境 ────────────────────────────────────────────────────────────
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
SOCK="${TEST_TMP}/clabotch/hook.sock"
REGISTRY="${TEST_TMP}/clabotch_sessions"
mkdir -p "${TEST_TMP}/clabotch"

# hook を隔離 TMPDIR で実行する（socket 有無はテスト側で制御）
run_hook() {
  local script="$1"
  TMPDIR="${TEST_TMP}/" bash "$HOOKS_DIR/$script"
}

# nc リスナーで 1 接続分をキャプチャしながら hook を実行する。
# 引数: script stdin_json capture_file
# 戻り値: hook の exit code
run_hook_captured() {
  local script="$1" stdin_json="$2" capture="$3"
  rm -f "$SOCK"
  : > "$capture"
  nc -l -U "$SOCK" > "$capture" &
  local nc_pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -S "$SOCK" ]] && break
    sleep 0.1
  done
  echo "$stdin_json" | run_hook "$script" >/dev/null 2>&1
  local rc=$?
  # listener の自然終了（EOF）を最大3秒ポーリングで待つ。途中で kill すると
  # stdio バッファが失われ capture が欠落するため、kill は最終手段のみ。
  # 注意: watchdog をバックグラウンドサブシェルで作ってはいけない。fork 直後
  # （trap リセット前）に kill されると親の EXIT trap を実行し TEST_TMP が消える。
  local i
  for i in $(seq 1 30); do
    kill -0 "$nc_pid" 2>/dev/null || break
    sleep 0.1
  done
  kill "$nc_pid" 2>/dev/null || true
  wait "$nc_pid" 2>/dev/null || true
  rm -f "$SOCK"
  return "$rc"
}

assert_exit() {
  local name="$1" exit_code="$2" expected="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$exit_code" -eq "$expected" ]]; then
    echo "  PASS: $name (exit=$exit_code)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name (exit=$exit_code, expected=$expected)"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local name="$1" output="$2" pattern="$3"
  TOTAL=$((TOTAL + 1))
  if echo "$output" | grep -q "$pattern"; then
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name (pattern '$pattern' not found in output)"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local name="$1" output="$2" pattern="$3"
  TOTAL=$((TOTAL + 1))
  if echo "$output" | grep -q "$pattern"; then
    echo "  FAIL: $name (pattern '$pattern' unexpectedly found)"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  fi
}

assert_true() {
  local name="$1" cond="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$cond" == "true" ]]; then
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name"
    FAIL=$((FAIL + 1))
  fi
}

VALID_JSON='{"session_id":"test-session-001","tool_name":"Read"}'
NO_SID_JSON='{"tool_name":"Bash"}'

echo "=== Clabotch Hook 疎通テスト ==="
echo "隔離 TMPDIR: $TEST_TMP"
echo ""

# ────────────────────────────────────────────────────────────────────────
echo "[1] jq 存在確認"
TOTAL=$((TOTAL + 1))
if command -v jq &>/dev/null; then
  echo "  PASS: jq が利用可能 ($(which jq))"
  PASS=$((PASS + 1))
else
  echo "  FAIL: jq が見つからない（brew install jq が必要）"
  FAIL=$((FAIL + 1))
  echo "jq がないためテスト中断。"
  exit 1
fi

# ────────────────────────────────────────────────────────────────────────
echo ""
echo "[2] session_id 欠損時の drop-and-log テスト"

for script in clabotch_pre_tool.sh clabotch_post_tool.sh clabotch_post_tool_failure.sh clabotch_stop.sh; do
  OUTPUT=$(echo "$NO_SID_JSON" | run_hook "$script" 2>&1) || EC=$?
  EC=${EC:-0}
  assert_exit "$script: session_id 欠損 → exit 1" "$EC" 1
  assert_contains "$script: drop-and-log メッセージ" "$OUTPUT" "session_id missing"
  unset EC
done

# ────────────────────────────────────────────────────────────────────────
echo ""
echo "[3] 正常 JSON でスクリプトが落ちないこと（socket 不在）"

for script in clabotch_pre_tool.sh clabotch_post_tool.sh clabotch_post_tool_failure.sh clabotch_stop.sh; do
  echo "$VALID_JSON" | run_hook "$script" >/dev/null 2>&1 || EC=$?
  EC=${EC:-0}
  assert_exit "$script: 正常 JSON → exit 0" "$EC" 0
  unset EC
done
rm -rf "$REGISTRY"

# ────────────────────────────────────────────────────────────────────────
echo ""
echo "[4] socket 不在時のハング確認（各スクリプト5秒以内に完了）"

for script in clabotch_pre_tool.sh clabotch_post_tool.sh clabotch_post_tool_failure.sh clabotch_stop.sh; do
  START_T=$(date +%s)
  echo "$VALID_JSON" | run_hook "$script" >/dev/null 2>&1 || true
  END_T=$(date +%s)
  ELAPSED=$((END_T - START_T))
  TOTAL=$((TOTAL + 1))
  # ハング（nc の無限待ち）検出が目的。CI ランナーの遅い jq/uuidgen 起動を許容して 5 秒。
  if [[ "$ELAPSED" -lt 5 ]]; then
    echo "  PASS: $script: ${ELAPSED}秒で完了"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $script: ${ELAPSED}秒（タイムアウト）"
    FAIL=$((FAIL + 1))
  fi
done
rm -rf "$REGISTRY"

# ────────────────────────────────────────────────────────────────────────
echo ""
echo "[5] clabotch_lib.sh 関数単体テスト"

# json_escape
ESCAPED=$(source "$HOOKS_DIR/clabotch_lib.sh" && json_escape 'hello "world"')
TOTAL=$((TOTAL + 1))
if [[ "$ESCAPED" == '"hello \"world\""' ]]; then
  echo "  PASS: json_escape"
  PASS=$((PASS + 1))
else
  echo "  FAIL: json_escape result='$ESCAPED'"
  FAIL=$((FAIL + 1))
fi

# json_escape（改行入り → 単一 JSON 文字列。-Rs でないと複数文字列に分割され NDJSON が壊れる）
ESCAPED=$(source "$HOOKS_DIR/clabotch_lib.sh" && json_escape $'multi\nline')
TOTAL=$((TOTAL + 1))
if [[ "$ESCAPED" == '"multi\nline"' ]]; then
  echo "  PASS: json_escape 改行入り → 単一文字列"
  PASS=$((PASS + 1))
else
  echo "  FAIL: json_escape 改行入り result='$ESCAPED'"
  FAIL=$((FAIL + 1))
fi

# resolve_session_id（正常）
SID=$(source "$HOOKS_DIR/clabotch_lib.sh" && resolve_session_id '{"session_id":"abc-123"}')
assert_contains "resolve_session_id 正常" "$SID" "abc-123"

# resolve_session_id（欠損 → 空文字列）
SID=$(source "$HOOKS_DIR/clabotch_lib.sh" && resolve_session_id '{"tool_name":"Bash"}')
TOTAL=$((TOTAL + 1))
if [[ -z "$SID" ]]; then
  echo "  PASS: resolve_session_id 欠損 → 空文字列"
  PASS=$((PASS + 1))
else
  echo "  FAIL: resolve_session_id 欠損で '$SID' が返った"
  FAIL=$((FAIL + 1))
fi

# resolve_session_id（CLAUDE_SESSION_ID 環境変数 fallback）
SID=$(CLAUDE_SESSION_ID="env-fb-id" bash -c 'source "'"$HOOKS_DIR"'/clabotch_lib.sh" && resolve_session_id "{}"')
assert_contains "resolve_session_id 環境変数 fallback" "$SID" "env-fb-id"

# resolve_tool_name
TNAME=$(source "$HOOKS_DIR/clabotch_lib.sh" && resolve_tool_name '{"tool_name":"Write"}')
assert_contains "resolve_tool_name 正常" "$TNAME" "Write"

# resolve_tool_name（欠損 → "unknown"）
TNAME=$(source "$HOOKS_DIR/clabotch_lib.sh" && resolve_tool_name '{}')
assert_contains "resolve_tool_name 欠損 → unknown" "$TNAME" "unknown"

# ────────────────────────────────────────────────────────────────────────
echo ""
echo "[6] pre_tool: 冪等 session_start + marker セマンティクス"

TEST_SID="pre-tool-sid-001"
CAPTURE="${TEST_TMP}/capture_pre1.ndjson"

# socket 不在時は marker を作らない
rm -rf "$REGISTRY"
echo "{\"session_id\":\"$TEST_SID\",\"tool_name\":\"Bash\"}" | run_hook clabotch_pre_tool.sh >/dev/null 2>&1 || true
assert_true "socket 不在時に marker が作成されない" "$([[ ! -f "$REGISTRY/$TEST_SID" ]] && echo true || echo false)"

# 初回送信: session_start + tool_start が同一接続で届く + marker 作成
run_hook_captured clabotch_pre_tool.sh "{\"session_id\":\"$TEST_SID\",\"tool_name\":\"Bash\"}" "$CAPTURE"
assert_contains "初回 pre_tool: session_start 送信" "$(cat "$CAPTURE")" '"event":"session_start"'
assert_contains "初回 pre_tool: tool_start 送信" "$(cat "$CAPTURE")" '"event":"tool_start"'
assert_true "初回 pre_tool: session_start が tool_start より先" \
  "$([[ $(grep -n '"event":"session_start"' "$CAPTURE" | head -1 | cut -d: -f1) -lt $(grep -n '"event":"tool_start"' "$CAPTURE" | head -1 | cut -d: -f1) ]] && echo true || echo false)"
assert_true "初回 pre_tool: marker 作成" "$([[ -f "$REGISTRY/$TEST_SID" ]] && echo true || echo false)"
FIRST_EPOCH=$(cat "$REGISTRY/$TEST_SID")

# 2回目送信: marker があっても session_start を再送する（reap/アプリ再起動後の再同期）
sleep 1
CAPTURE2="${TEST_TMP}/capture_pre2.ndjson"
run_hook_captured clabotch_pre_tool.sh "{\"session_id\":\"$TEST_SID\",\"tool_name\":\"Read\"}" "$CAPTURE2"
assert_contains "2回目 pre_tool: session_start 再送（冪等）" "$(cat "$CAPTURE2")" '"event":"session_start"'
assert_contains "2回目 pre_tool: tool_start 送信" "$(cat "$CAPTURE2")" '"event":"tool_start"'
assert_true "2回目 pre_tool: marker の初回時刻は保持" \
  "$([[ "$(cat "$REGISTRY/$TEST_SID")" == "$FIRST_EPOCH" ]] && echo true || echo false)"

# ────────────────────────────────────────────────────────────────────────
echo ""
echo "[6b] post_tool / post_tool_failure: 冪等 session_start + tool_end"

CAPTURE3="${TEST_TMP}/capture_post.ndjson"
run_hook_captured clabotch_post_tool.sh "{\"session_id\":\"$TEST_SID\",\"tool_name\":\"Bash\"}" "$CAPTURE3"
assert_contains "post_tool: session_start 送信" "$(cat "$CAPTURE3")" '"event":"session_start"'
assert_contains "post_tool: tool_end 送信" "$(cat "$CAPTURE3")" '"event":"tool_end"'
assert_contains "post_tool: is_error=false" "$(cat "$CAPTURE3")" '"is_error":false'

CAPTURE4="${TEST_TMP}/capture_post_fail.ndjson"
run_hook_captured clabotch_post_tool_failure.sh "{\"session_id\":\"$TEST_SID\",\"tool_name\":\"Bash\"}" "$CAPTURE4"
assert_contains "post_tool_failure: session_start 送信" "$(cat "$CAPTURE4")" '"event":"session_start"'
assert_contains "post_tool_failure: is_error=true" "$(cat "$CAPTURE4")" '"is_error":true'

# ────────────────────────────────────────────────────────────────────────
echo ""
echo "[7] stop: elapsed_ms 計算 + marker 削除"

# marker あり: 冪等 session_start + elapsed_ms > 0、marker 削除
CAPTURE5="${TEST_TMP}/capture_stop1.ndjson"
run_hook_captured clabotch_stop.sh "{\"session_id\":\"$TEST_SID\"}" "$CAPTURE5"
assert_contains "stop(marker あり): session_done 送信" "$(cat "$CAPTURE5")" '"event":"session_done"'
assert_contains "stop(marker あり): session_start 同送（冪等・reap 後の再同期）" "$(cat "$CAPTURE5")" '"event":"session_start"'
ELAPSED_VAL=$(grep -o '"elapsed_ms":[0-9-]*' "$CAPTURE5" | cut -d: -f2)
assert_true "stop(marker あり): elapsed_ms > 0（値=${ELAPSED_VAL:-none}）" \
  "$([[ -n "${ELAPSED_VAL}" && "${ELAPSED_VAL}" -gt 0 ]] && echo true || echo false)"
assert_true "stop 後に marker が削除された" "$([[ ! -f "$REGISTRY/$TEST_SID" ]] && echo true || echo false)"

# marker なし（ツール未使用セッション）: session_start + session_done(elapsed_ms=0)
CAPTURE6="${TEST_TMP}/capture_stop2.ndjson"
run_hook_captured clabotch_stop.sh '{"session_id":"no-tool-session"}' "$CAPTURE6"
assert_contains "stop(marker なし): session_start 同時送信" "$(cat "$CAPTURE6")" '"event":"session_start"'
assert_contains "stop(marker なし): elapsed_ms=0" "$(cat "$CAPTURE6")" '"elapsed_ms":0'

# marker が未来時刻（時計逆行）: 負の elapsed_ms は 0 に clamp される
CLOCK_SID="clock-skew-$$"
mkdir -p "$REGISTRY"
echo "$(( $(date +%s) + 1000 ))" > "$REGISTRY/$CLOCK_SID"
CAPTURE7="${TEST_TMP}/capture_stop3.ndjson"
run_hook_captured clabotch_stop.sh "{\"session_id\":\"$CLOCK_SID\"}" "$CAPTURE7"
assert_contains "stop(時計逆行): elapsed_ms は 0 に clamp" "$(cat "$CAPTURE7")" '"elapsed_ms":0'
assert_not_contains "stop(時計逆行): 負の elapsed_ms を送らない" "$(cat "$CAPTURE7")" '"elapsed_ms":-'

# ────────────────────────────────────────────────────────────────────────
echo ""
echo "[8] 不正な session_id のバリデーションテスト"

# 予約パス名 "." の拒否
OUTPUT=$(echo '{"session_id":".","tool_name":"Bash"}' | run_hook clabotch_pre_tool.sh 2>&1) || EC=$?
EC=${EC:-0}
assert_exit "session_id '.' → exit 1" "$EC" 1
assert_contains "'.' 拒否メッセージ" "$OUTPUT" "reserved path name"
unset EC

# 予約パス名 ".." の拒否
OUTPUT=$(echo '{"session_id":"..","tool_name":"Bash"}' | run_hook clabotch_pre_tool.sh 2>&1) || EC=$?
EC=${EC:-0}
assert_exit "session_id '..' → exit 1" "$EC" 1
assert_contains "'..' 拒否メッセージ" "$OUTPUT" "reserved path name"
unset EC

# パストラバーサル（../）
OUTPUT=$(echo '{"session_id":"../../../etc/passwd","tool_name":"Bash"}' | run_hook clabotch_pre_tool.sh 2>&1) || EC=$?
EC=${EC:-0}
assert_exit "session_id '../../../etc/passwd' → exit 1" "$EC" 1
assert_contains "パストラバーサル検知メッセージ" "$OUTPUT" "unsafe characters"
unset EC

# JSON インジェクション（"）
OUTPUT=$(echo '{"session_id":"abc\"inject","tool_name":"Bash"}' | run_hook clabotch_pre_tool.sh 2>&1) || EC=$?
EC=${EC:-0}
assert_exit "session_id にダブルクォート → exit 1" "$EC" 1
unset EC

# 改行を含む session_id
OUTPUT=$(printf '{"session_id":"abc\\ndef","tool_name":"Bash"}' | run_hook clabotch_pre_tool.sh 2>&1) || EC=$?
EC=${EC:-0}
assert_exit "session_id に改行 → exit 1" "$EC" 1
unset EC

# スラッシュを含む session_id
OUTPUT=$(echo '{"session_id":"abc/def","tool_name":"Bash"}' | run_hook clabotch_pre_tool.sh 2>&1) || EC=$?
EC=${EC:-0}
assert_exit "session_id にスラッシュ → exit 1" "$EC" 1
unset EC

# 正常な UUID 形式はパス
OUTPUT=$(echo '{"session_id":"550e8400-e29b-41d4-a716-446655440000","tool_name":"Bash"}' | run_hook clabotch_pre_tool.sh 2>&1) || EC=$?
EC=${EC:-0}
assert_exit "UUID 形式の session_id → exit 0" "$EC" 0
unset EC

# post_tool / post_tool_failure / stop でもバリデーションが効くこと
for script in clabotch_post_tool.sh clabotch_post_tool_failure.sh clabotch_stop.sh; do
  OUTPUT=$(echo '{"session_id":"../evil","tool_name":"Bash"}' | run_hook "$script" 2>&1) || EC=$?
  EC=${EC:-0}
  assert_exit "$script: 不正 session_id → exit 1" "$EC" 1
  unset EC
done

# ────────────────────────────────────────────────────────────────────────
echo ""
echo "[9] 壊れた stdin JSON のテスト"

# 完全に壊れた JSON
OUTPUT=$(echo 'this is not json at all' | run_hook clabotch_pre_tool.sh 2>&1) || EC=$?
EC=${EC:-0}
assert_exit "壊れた JSON → exit 1（session_id 取得不可）" "$EC" 1
unset EC

# 空の stdin
OUTPUT=$(echo '' | run_hook clabotch_pre_tool.sh 2>&1) || EC=$?
EC=${EC:-0}
assert_exit "空 stdin → exit 1" "$EC" 1
unset EC

# 途中で切れた JSON
OUTPUT=$(echo '{"session_id":"abc' | run_hook clabotch_pre_tool.sh 2>&1) || EC=$?
EC=${EC:-0}
assert_exit "不完全 JSON → exit 1" "$EC" 1
unset EC

# ────────────────────────────────────────────────────────────────────────
echo ""
echo "=== テスト結果: $PASS/$TOTAL passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
