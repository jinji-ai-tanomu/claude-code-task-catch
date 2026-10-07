#!/bin/bash
# タスク取りこぼし防止キットを ~/.claude から外す。
#   使い方: bash uninstall.sh            （設定ファイルは残す）
#           bash uninstall.sh --purge    （設定ファイルも消す）

set -eu

KIT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="${HOME}/.claude"
TS="$(date +%Y%m%d-%H%M%S)"
SETTINGS="${CLAUDE_DIR}/settings.json"
CLAUDE_MD="${CLAUDE_DIR}/CLAUDE.md"
CONFIG="${CLAUDE_DIR}/task-catch.config.json"
HOOK_FILES="task_signals.py notion-task-catch.py notion-task-sweep-check.py notion-task-sweep.py"
SKILLS="task-sweep"
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

say() { printf '%s\n' "$*"; }

command -v python3 >/dev/null 2>&1 || { say "エラー: python3 が見つかりません" >&2; exit 1; }

say "タスク取りこぼし防止キットを外します（対象: ${CLAUDE_DIR}）"

# --- settings.json ----------------------------------------------------------
if [ -f "${SETTINGS}" ]; then
  if python3 "${KIT_DIR}/lib/settings_hooks.py" check "${SETTINGS}"; then
    cp -p "${SETTINGS}" "${SETTINGS}.bak-${TS}"
    say "  バックアップ: ${SETTINGS}.bak-${TS}"
    python3 "${KIT_DIR}/lib/settings_hooks.py" remove "${SETTINGS}"
  else
    say "  settings.json の書式が壊れているため触りませんでした。/hooks から手動で外してください"
  fi
fi

# --- ファイル ---------------------------------------------------------------
for name in ${HOOK_FILES}; do
  rm -f "${CLAUDE_DIR}/hooks/${name}"
done
say "  hooks を削除しました"

for skill in ${SKILLS}; do
  rm -f "${CLAUDE_DIR}/skills/${skill}/SKILL.md"
  rmdir "${CLAUDE_DIR}/skills/${skill}" 2>/dev/null || true
done
say "  skills を削除しました（${SKILLS}）"

rm -rf "${CLAUDE_DIR}/state/notion-task-catch"
say "  記録（チェック地点）を削除しました"

if [ "${PURGE}" = 1 ]; then
  rm -f "${CONFIG}"
  say "  設定ファイルを削除しました"
else
  [ -f "${CONFIG}" ] && say "  設定ファイルは残しました: ${CONFIG}（消すなら --purge を付けて再実行）"
fi

# --- CLAUDE.md --------------------------------------------------------------
if [ -f "${CLAUDE_MD}" ] && grep -q "task-catch-kit:begin" "${CLAUDE_MD}"; then
  say ""
  say "最後に1つだけ手作業があります:"
  say "  ${CLAUDE_MD} を開き、"
  say "  「<!-- task-catch-kit:begin -->」から「<!-- task-catch-kit:end -->」までを消して保存してください。"
fi

say ""
say "外し終わりました。Claude Code を開き直すと反映されます。"
