#!/usr/bin/env bash
# Clabotch hooks インストーラー
#
# 使い方:
#   リポジトリから: bash hooks/install.sh
#   DMG から:       bash /Volumes/Clabotch/install.sh
#
# hook スクリプトを ~/.claude/hooks/ にコピーし、~/.claude/settings.json の
# hooks 設定を（新規作成のときのみ）書き込む。既存の settings.json は変更せず、
# マージすべき JSON を表示するだけに留める。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# hooks ディレクトリの解決:
#   DMG ルート（hooks/ が隣にある）→ ./hooks
#   リポジトリ内 hooks/（自身のディレクトリにスクリプトがある）→ 自身のディレクトリ
if [[ -f "${SCRIPT_DIR}/hooks/clabotch_pre_tool.sh" ]]; then
  HOOKS_SRC="${SCRIPT_DIR}/hooks"
elif [[ -f "${SCRIPT_DIR}/clabotch_pre_tool.sh" ]]; then
  HOOKS_SRC="${SCRIPT_DIR}"
else
  echo "ERROR: hook scripts not found next to this installer" >&2
  exit 1
fi

DEST="${HOME}/.claude/hooks"
SETTINGS="${HOME}/.claude/settings.json"

echo "==> Installing Clabotch hooks"
echo "    from: ${HOOKS_SRC}"
echo "    to:   ${DEST}"
mkdir -p "${DEST}"
cp "${HOOKS_SRC}/clabotch_lib.sh" \
   "${HOOKS_SRC}/clabotch_pre_tool.sh" \
   "${HOOKS_SRC}/clabotch_post_tool.sh" \
   "${HOOKS_SRC}/clabotch_post_tool_failure.sh" \
   "${HOOKS_SRC}/clabotch_stop.sh" \
   "${DEST}/"
chmod +x "${DEST}"/clabotch_*.sh

# DMG 由来の quarantine 属性を除去（direct exec がブロックされないように）
xattr -d com.apple.quarantine "${DEST}"/clabotch_*.sh 2>/dev/null || true

if ! command -v jq &>/dev/null; then
  echo "WARN: jq not found — hooks require jq at runtime. Install with: brew install jq"
fi

HOOKS_JSON=$(cat <<'JSON'
    "PreToolUse": [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/clabotch_pre_tool.sh" }] }],
    "PostToolUse": [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/clabotch_post_tool.sh" }] }],
    "PostToolUseFailure": [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/clabotch_post_tool_failure.sh" }] }],
    "Stop": [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/clabotch_stop.sh" }] }]
JSON
)

if [[ ! -f "${SETTINGS}" ]]; then
  mkdir -p "$(dirname "${SETTINGS}")"
  printf '{\n  "hooks": {\n%s\n  }\n}\n' "${HOOKS_JSON}" > "${SETTINGS}"
  echo "==> Created ${SETTINGS} with Clabotch hook entries"
else
  # 4 hook すべての参照を event ごとに個別確認する（部分的な旧設定を「導入済み」と
  # 誤判定しないため）。既存ファイルはどのケースでも変更しない。
  # jq があれば構造検査（正しい event キー配下の command を確認）、なければ grep に
  # フォールバック。hooks は実行時に jq 必須なので通常は構造検査になる。
  # 注意: bash 3.2 は set -u で空配列展開がエラーになるため文字列で蓄積する。

  # 引数: event名 スクリプト名 → 参照があれば 0
  settings_references() {
    local ev="$1" s="$2"
    if command -v jq &>/dev/null; then
      jq -e --arg ev "$ev" --arg s "$s" \
        '[.hooks[$ev] // [] | .[] | .hooks // [] | .[] | .command // "" | select(contains($s))] | length > 0' \
        "${SETTINGS}" >/dev/null 2>&1
    else
      grep -q "$s" "${SETTINGS}"
    fi
  }

  MISSING=""
  settings_references "PreToolUse"         "clabotch_pre_tool.sh"          || MISSING="${MISSING} clabotch_pre_tool.sh"
  settings_references "PostToolUse"        "clabotch_post_tool.sh"         || MISSING="${MISSING} clabotch_post_tool.sh"
  settings_references "PostToolUseFailure" "clabotch_post_tool_failure.sh" || MISSING="${MISSING} clabotch_post_tool_failure.sh"
  settings_references "Stop"               "clabotch_stop.sh"              || MISSING="${MISSING} clabotch_stop.sh"

  if [[ -z "${MISSING}" ]]; then
    echo "==> ${SETTINGS} already references all 4 Clabotch hooks — left unchanged"
  else
    echo "==> ${SETTINGS} exists but is missing:${MISSING}"
    echo "    NOT modified. Merge the missing entries from the 4 below into its \"hooks\" section manually:"
    echo ""
    printf '%s\n' "${HOOKS_JSON}"
  fi
fi

echo ""
echo "Done. Restart Claude Code — Clabotch reacts from the next session."
