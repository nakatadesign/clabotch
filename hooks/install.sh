#!/usr/bin/env bash
# Clabotch hooks インストーラー
#
# 使い方:
#   リポジトリから: bash hooks/install.sh
#   DMG から:       bash "/Volumes/Clabotch 1.0.0/install.sh"
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
elif grep -q "clabotch_pre_tool.sh" "${SETTINGS}"; then
  echo "==> ${SETTINGS} already references Clabotch hooks — left unchanged"
else
  echo "==> ${SETTINGS} already exists — NOT modified."
  echo "    Merge these 4 entries into its \"hooks\" section manually:"
  echo ""
  printf '%s\n' "${HOOKS_JSON}"
fi

echo ""
echo "Done. Restart Claude Code — Clabotch reacts from the next session."
