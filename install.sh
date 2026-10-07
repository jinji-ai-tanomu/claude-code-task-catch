#!/bin/bash
# タスク取りこぼし防止キットを ~/.claude に入れる。
#   使い方: bash install.sh
# 何度実行しても同じ結果になる（二重登録しない・既存の設定を消さない）。

set -eu

KIT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="${HOME}/.claude"
TS="$(date +%Y%m%d-%H%M%S)"
SETTINGS="${CLAUDE_DIR}/settings.json"
CLAUDE_MD="${CLAUDE_DIR}/CLAUDE.md"
CONFIG="${CLAUDE_DIR}/task-catch.config.json"
HOOK_FILES="task_signals.py notion-task-catch.py notion-task-sweep-check.py notion-task-sweep.py"
SKILLS="task-sweep"
MARKER="task-catch-kit:begin"

say() { printf '%s\n' "$*"; }
fail() { printf 'エラー: %s\n' "$*" >&2; exit 1; }

# --- 前提の確認 -------------------------------------------------------------
if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import sys' >/dev/null 2>&1; then
  fail "python3 が見つかりません。ターミナルで「xcode-select --install」を実行してから、もう一度お試しください。"
fi

mkdir -p "${CLAUDE_DIR}"

if ! python3 "${KIT_DIR}/lib/settings_hooks.py" check "${SETTINGS}"; then
  fail "${SETTINGS} の書式が壊れているため、何も変更せずに止めました。中身を直してから再実行してください。"
fi

say "タスク取りこぼし防止キットを入れます（入れ先: ${CLAUDE_DIR}）"

# --- バックアップ -----------------------------------------------------------
for f in "${SETTINGS}" "${CLAUDE_MD}"; do
  if [ -f "${f}" ]; then
    cp -p "${f}" "${f}.bak-${TS}"
    say "  バックアップ: ${f}.bak-${TS}"
  fi
done

# 中身が違う既存ファイルを上書きする前に、横に退避する
backup_if_differs() {
  if [ -e "$2" ] && ! cmp -s "$1" "$2"; then
    cp -p "$2" "$2.bak-${TS}"
    say "  既存ファイルを退避: $2.bak-${TS}"
  fi
}

# --- hooks ------------------------------------------------------------------
mkdir -p "${CLAUDE_DIR}/hooks"
for name in ${HOOK_FILES}; do
  backup_if_differs "${KIT_DIR}/hooks/${name}" "${CLAUDE_DIR}/hooks/${name}"
  cp "${KIT_DIR}/hooks/${name}" "${CLAUDE_DIR}/hooks/${name}"
  chmod +x "${CLAUDE_DIR}/hooks/${name}"
done
say "  hooks をコピーしました"

# --- skills -----------------------------------------------------------------
for skill in ${SKILLS}; do
  mkdir -p "${CLAUDE_DIR}/skills/${skill}"
  backup_if_differs "${KIT_DIR}/skills/${skill}/SKILL.md" "${CLAUDE_DIR}/skills/${skill}/SKILL.md"
  cp "${KIT_DIR}/skills/${skill}/SKILL.md" "${CLAUDE_DIR}/skills/${skill}/SKILL.md"
done
say "  skills をコピーしました（${SKILLS}）"

# --- settings.json ----------------------------------------------------------
python3 "${KIT_DIR}/lib/settings_hooks.py" add "${SETTINGS}"

# --- CLAUDE.md --------------------------------------------------------------
if [ -f "${CLAUDE_MD}" ] && grep -q "${MARKER}" "${CLAUDE_MD}"; then
  say "  CLAUDE.md には追記済みのため変更なし"
elif [ -f "${CLAUDE_MD}" ] && grep -q "^## 発生したタスクはNotionに載せる" "${CLAUDE_MD}"; then
  say "  CLAUDE.md に同じ見出しのルールが既にあるため追記しませんでした"
else
  if [ -s "${CLAUDE_MD}" ]; then
    printf '\n' >> "${CLAUDE_MD}"
  fi
  cat "${KIT_DIR}/claude-md/task-rule.md" >> "${CLAUDE_MD}"
  say "  CLAUDE.md にルールを追記しました"
fi

# --- 設定ファイル -----------------------------------------------------------
if [ -f "${CONFIG}" ]; then
  say "  設定ファイルは既にあるため変更なし: ${CONFIG}"
else
  cp "${KIT_DIR}/task-catch.config.json" "${CONFIG}"
  say "  設定ファイルの雛形を置きました: ${CONFIG}"
fi

# --- 次にやること -----------------------------------------------------------
if python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
    ok = isinstance(d, dict) and isinstance(d.get("notion_task_db"), str) and d["notion_task_db"].strip()
except Exception:
    ok = False
sys.exit(0 if ok else 1)
' "${CONFIG}"; then
  say ""
  say "完了しました。Claude Code を開き直すと有効になります。"
else
  say ""
  say "完了しました。あと1つだけ作業があります:"
  say "  ${CONFIG} を開き、notion_task_db にタスク用DBの collection URL を入れて保存してください。"
  say "  （入れるまでは、このキットは何もしません。取り方は README.md を参照）"
fi
