#!/bin/bash
# キットの動作確認。一時ディレクトリを HOME に見立てて実行するので、本物の ~/.claude には触らない。
#   使い方: bash tests/run.sh

set -u

KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
FAILED_NAMES=""

ok()  { PASS=$((PASS+1)); printf '  [成功] %s\n' "$1"; }
ng()  { FAIL=$((FAIL+1)); FAILED_NAMES="${FAILED_NAMES}\n  - $1"; printf '  [失敗] %s\n' "$1"; [ -n "${2:-}" ] && printf '         %s\n' "$2"; }
check() { if eval "$2"; then ok "$1"; else ng "$1" "${3:-}"; fi; }

new_home() { mktemp -d /tmp/kit-test-XXXXXX; }

# 指定イベントに登録された、このキットの command の数
count_cmd() {
  python3 - "$1" "$2" "$3" <<'EOF'
import json, sys
path, event, needle = sys.argv[1:4]
d = json.load(open(path, encoding="utf-8"))
n = 0
for g in d.get("hooks", {}).get(event, []):
    for h in g.get("hooks", []):
        if needle in h.get("command", ""):
            n += 1
print(n)
EOF
}

user_line() {  # $1=本文 $2=追加フィールド(JSON断片、任意)
  python3 - "$1" "${2:-}" <<'EOF'
import json, sys
text, extra = sys.argv[1], sys.argv[2]
e = {"type": "user", "message": {"role": "user", "content": text}}
if extra:
    e.update(json.loads(extra))
print(json.dumps(e, ensure_ascii=False))
EOF
}

assistant_line() {
  python3 - "$1" <<'EOF'
import json, sys
print(json.dumps({"type": "assistant", "message": {"role": "assistant",
      "content": [{"type": "text", "text": sys.argv[1]}]}}, ensure_ascii=False))
EOF
}

run_stop() {  # $1=HOME $2=session_id $3=transcript $4=stop_hook_active(true/false)
  printf '{"session_id":"%s","transcript_path":"%s","stop_hook_active":%s}' "$2" "$3" "${4:-false}" \
    | HOME="$1" python3 "$1/.claude/hooks/notion-task-catch.py"
}

run_start() {
  printf '{"session_id":"s","source":"startup"}' | HOME="$1" python3 "$1/.claude/hooks/notion-task-sweep-check.py"
}

write_config() {  # $1=HOME $2=JSON
  printf '%s\n' "$2" > "$1/.claude/task-catch.config.json"
}

GOOD_CONFIG='{"notion_task_db":"collection://test-task-db","notion_project_db":"collection://test-project-db","owner_name":"たろう","extra_signals":["ポチる"],"sweep_hours":30}'

# ---------------------------------------------------------------------------
echo "1. 空のHOMEに install.sh"
H1="$(new_home)"
OUT="$(HOME="${H1}" bash "${KIT_DIR}/install.sh" 2>&1)"; RC=$?
check "install.sh が終了コード0で終わる" '[ ${RC} -eq 0 ]' "${OUT}"
check "settings.json が生成される" '[ -f "${H1}/.claude/settings.json" ]'
check "settings.json に Stop が1件登録される" '[ "$(count_cmd "${H1}/.claude/settings.json" Stop notion-task-catch.py)" = 1 ]'
check "settings.json に SessionStart が1件登録される" '[ "$(count_cmd "${H1}/.claude/settings.json" SessionStart notion-task-sweep-check.py)" = 1 ]'
check "CLAUDE.md が生成されルールが入る" 'grep -q "task-catch-kit:begin" "${H1}/.claude/CLAUDE.md"'
check "設定ファイルの雛形が置かれる" '[ -f "${H1}/.claude/task-catch.config.json" ]'
check "hooks 4本がコピーされる" '[ -f "${H1}/.claude/hooks/task_signals.py" ] && [ -f "${H1}/.claude/hooks/notion-task-catch.py" ] && [ -f "${H1}/.claude/hooks/notion-task-sweep-check.py" ] && [ -f "${H1}/.claude/hooks/notion-task-sweep.py" ]'
check "task-sweep スキルがコピーされる" '[ -f "${H1}/.claude/skills/task-sweep/SKILL.md" ]'
check "空のHOMEではバックアップを作らない" '! ls "${H1}/.claude/"*.bak-* >/dev/null 2>&1'

# ---------------------------------------------------------------------------
echo "2. 既存の hooks がある settings.json に install.sh を2回"
H2="$(new_home)"
mkdir -p "${H2}/.claude"
cat > "${H2}/.claude/settings.json" <<'EOF'
{
  "model": "opus",
  "permissions": {"allow": ["Bash(ls:*)"]},
  "hooks": {
    "Stop": [
      {"hooks": [{"type": "command", "command": "echo other-stop-hook"}]},
      {"hooks": [{"type": "command", "command": "python3 ~/.claude/hooks/notion-task-catch.py 2>/dev/null || true", "timeout": 15}]}
    ],
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "echo pre-tool"}]}
    ]
  }
}
EOF
printf '# 既存のメモ\n\n自分のルール\n' > "${H2}/.claude/CLAUDE.md"
printf '{"notion_task_db":"collection://keep-me"}\n' > "${H2}/.claude/task-catch.config.json"
HOME="${H2}" bash "${KIT_DIR}/install.sh" >/dev/null 2>&1; RC1=$?
sleep 1
HOME="${H2}" bash "${KIT_DIR}/install.sh" >/dev/null 2>&1; RC2=$?
S2="${H2}/.claude/settings.json"
check "2回とも終了コード0" '[ ${RC1} -eq 0 ] && [ ${RC2} -eq 0 ]'
check "Stop が二重登録されない（1件）" '[ "$(count_cmd "${S2}" Stop notion-task-catch.py)" = 1 ]'
check "SessionStart が二重登録されない（1件）" '[ "$(count_cmd "${S2}" SessionStart notion-task-sweep-check.py)" = 1 ]'
check "既存の Stop hook が残る" '[ "$(count_cmd "${S2}" Stop other-stop-hook)" = 1 ]'
check "既存の PreToolUse hook が残る" '[ "$(count_cmd "${S2}" PreToolUse pre-tool)" = 1 ]'
check "hooks 以外の設定（model / permissions）が残る" 'python3 -c "import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if d[\"model\"]==\"opus\" and d[\"permissions\"][\"allow\"]==[\"Bash(ls:*)\"] else 1)" "${S2}"'
check "CLAUDE.md の追記は1回だけ" '[ "$(grep -c "task-catch-kit:begin" "${H2}/.claude/CLAUDE.md")" = 1 ]'
check "CLAUDE.md の既存の中身が残る" 'grep -q "自分のルール" "${H2}/.claude/CLAUDE.md"'
check "既存の設定ファイルは上書きされない" 'grep -q "keep-me" "${H2}/.claude/task-catch.config.json"'
check "settings.json と CLAUDE.md のバックアップが作られる" 'ls "${S2}".bak-* >/dev/null 2>&1 && ls "${H2}/.claude/CLAUDE.md".bak-* >/dev/null 2>&1'

# ---------------------------------------------------------------------------
echo "3. 壊れた settings.json"
H3="$(new_home)"
mkdir -p "${H3}/.claude"
printf '{ "hooks": [ broken\n' > "${H3}/.claude/settings.json"
BEFORE="$(cat "${H3}/.claude/settings.json")"
HOME="${H3}" bash "${KIT_DIR}/install.sh" >/dev/null 2>&1; RC=$?
check "install.sh がエラーで止まる" '[ ${RC} -ne 0 ]'
check "壊れた settings.json を書き換えない" '[ "$(cat "${H3}/.claude/settings.json")" = "${BEFORE}" ]'
check "途中まで入れたりしない（hooks がコピーされていない）" '[ ! -e "${H3}/.claude/hooks/notion-task-catch.py" ]'

# ---------------------------------------------------------------------------
echo "4. Stop hook"
H="${H1}"
write_config "${H}" "${GOOD_CONFIG}"
T="${H}/transcript-a.jsonl"
{ user_line "資料の件、来週までに送るね"; assistant_line "了解しました"; } > "${T}"

OUT="$(run_stop "${H}" t1 "${T}")"
check "(a) タスクらしき発言＋Notion書き込みなし → decision: block" 'printf "%s" "${OUT}" | python3 -c "import json,sys;d=json.load(sys.stdin);sys.exit(0 if d[\"decision\"]==\"block\" else 1)"' "${OUT}"
check "(a) 理由文に設定のDBが入る" 'printf "%s" "${OUT}" | grep -q "collection://test-task-db"'
check "(a) 理由文にプロジェクトDBが入る" 'printf "%s" "${OUT}" | grep -q "collection://test-project-db"'
check "(a) 理由文に owner_name が入る" 'printf "%s" "${OUT}" | grep -q "たろう本人"'

OUT="$(run_stop "${H}" t1 "${T}")"
check "(b) 同じ区間で2回目 → 何も出ない" '[ -z "${OUT}" ]' "${OUT}"

assistant_line "ほかに何かありますか" >> "${T}"
OUT="$(run_stop "${H}" t1 "${T}")"
check "(b) 区間が進んでも新しいタスク発言が無ければ何も出ない" '[ -z "${OUT}" ]' "${OUT}"

T="${H}/transcript-c.jsonl"
{ user_line "来週までに送る手順をまとめたスキル本文" '{"isMeta":true}'; assistant_line "ok"; } > "${T}"
OUT="$(run_stop "${H}" t-meta "${T}")"
check "(c) isMeta:true の発言だけ → 何も出ない" '[ -z "${OUT}" ]' "${OUT}"

T="${H}/transcript-c2.jsonl"
{ user_line "来週までに送る" '{"isSidechain":true}'; } > "${T}"
OUT="$(run_stop "${H}" t-side "${T}")"
check "(c) isSidechain:true の発言だけ → 何も出ない" '[ -z "${OUT}" ]' "${OUT}"

T="${H}/transcript-sr.jsonl"
{ user_line "<system-reminder>来週までに送る</system-reminder>こんにちは"; } > "${T}"
OUT="$(run_stop "${H}" t-sr "${T}")"
check "system-reminder 内の言い回しは拾わない" '[ -z "${OUT}" ]' "${OUT}"

T="${H}/transcript-w.jsonl"
{ user_line "来週までに送る"; printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"mcp__claude_ai_Notion__notion-create-pages","input":{}}]}}'; } > "${T}"
OUT="$(run_stop "${H}" t-write "${T}")"
check "同じ区間でNotionに書き込み済み → 何も出ない" '[ -z "${OUT}" ]' "${OUT}"

T="${H}/transcript-act.jsonl"
user_line "来週までに送る" > "${T}"
OUT="$(run_stop "${H}" t-active "${T}" true)"
check "stop_hook_active:true → 何も出ない" '[ -z "${OUT}" ]' "${OUT}"

T="${H}/transcript-x.jsonl"
user_line "あの本ポチるわ" > "${T}"
OUT="$(run_stop "${H}" t-extra "${T}")"
check "extra_signals に足した言い回しで発火する" 'printf "%s" "${OUT}" | grep -q "\"block\""' "${OUT}"

T="${H}/transcript-n.jsonl"
user_line "今日はいい天気ですね" > "${T}"
OUT="$(run_stop "${H}" t-none "${T}")"
check "タスクらしくない発言 → 何も出ない" '[ -z "${OUT}" ]' "${OUT}"

T="${H}/transcript-d.jsonl"
user_line "来週までに送る" > "${T}"
rm -f "${H}/.claude/task-catch.config.json"
OUT="$(run_stop "${H}" t-noconf "${T}")"; RC=$?
check "(d) config が無い → 何も出ない（終了コード0）" '[ -z "${OUT}" ] && [ ${RC} -eq 0 ]' "${OUT}"
check "(d) config が無いときはチェック地点も作らない" '[ ! -f "${H}/.claude/state/notion-task-catch/t-noconf.json" ]'

cp "${KIT_DIR}/task-catch.config.json" "${H}/.claude/task-catch.config.json"
OUT="$(run_stop "${H}" t-tmpl "${T}")"
check "雛形のまま（notion_task_db が空） → 何も出ない" '[ -z "${OUT}" ]' "${OUT}"

printf '{ broken' > "${H}/.claude/task-catch.config.json"
OUT="$(run_stop "${H}" t-broken "${T}")"; RC=$?
check "config が壊れている → 何も出ない（終了コード0）" '[ -z "${OUT}" ] && [ ${RC} -eq 0 ]' "${OUT}"

write_config "${H}" '{"notion_task_db":"collection://x"}'
OUT="$(run_stop "${H}" t-default "${T}")"
check "owner_name 未設定なら「ユーザー本人」と書く" 'printf "%s" "${OUT}" | grep -q "ユーザー本人"' "${OUT}"
check "notion_project_db 未設定ならプロジェクトDBの行を出さない" '! printf "%s" "${OUT}" | grep -q "プロジェクトDB"'

OUT="$(printf 'not json' | HOME="${H}" python3 "${H}/.claude/hooks/notion-task-catch.py")"; RC=$?
check "標準入力が壊れていても何も出さず終了コード0" '[ -z "${OUT}" ] && [ ${RC} -eq 0 ]'

# ---------------------------------------------------------------------------
echo "5. SessionStart hook と日次スイープ"
write_config "${H}" "${GOOD_CONFIG}"
rm -f "${H}/.claude/state/notion-task-catch/last-sweep"
OUT="$(run_start "${H}")"
check "その日初回はスイープ指示を出す" 'printf "%s" "${OUT}" | grep -q "日次スイープ"' "${OUT}"
check "指示に設定のDBと sweep_hours が入る" 'printf "%s" "${OUT}" | grep -q "collection://test-task-db" && printf "%s" "${OUT}" | grep -q -- "--hours 30"'
mkdir -p "${H}/.claude/state/notion-task-catch" && touch "${H}/.claude/state/notion-task-catch/last-sweep"
OUT="$(run_start "${H}")"
check "スタンプが今日なら何も出ない" '[ -z "${OUT}" ]' "${OUT}"
rm -f "${H}/.claude/state/notion-task-catch/last-sweep" "${H}/.claude/task-catch.config.json"
OUT="$(run_start "${H}")"
check "config が無ければ何も出ない" '[ -z "${OUT}" ]' "${OUT}"

write_config "${H}" "${GOOD_CONFIG}"
mkdir -p "${H}/.claude/projects/-tmp-sample"
{ user_line "見積もりは明日までに出す"; user_line "スキル本文: 来週やる" '{"isMeta":true}'; user_line "こんにちは"; } > "${H}/.claude/projects/-tmp-sample/s1.jsonl"
OUT="$(HOME="${H}" python3 "${H}/.claude/hooks/notion-task-sweep.py")"
check "スイープがタスク候補を出す" 'printf "%s" "${OUT}" | grep -q "見積もりは明日までに出す"' "${OUT}"
check "スイープは isMeta の発言を出さない" '! printf "%s" "${OUT}" | grep -q "スキル本文"'
check "スイープは関係ない発言を出さない" '! printf "%s" "${OUT}" | grep -q "こんにちは"'

# ---------------------------------------------------------------------------
echo "6. uninstall.sh"
HOME="${H2}" bash "${KIT_DIR}/uninstall.sh" >/dev/null 2>&1; RC=$?
check "uninstall.sh が終了コード0で終わる" '[ ${RC} -eq 0 ]'
check "Stop からキットのエントリが消える" '[ "$(count_cmd "${S2}" Stop notion-task-catch.py)" = 0 ]'
check "SessionStart からキットのエントリが消える" '[ "$(count_cmd "${S2}" SessionStart notion-task-sweep-check.py)" = 0 ]'
check "他の Stop / PreToolUse hook は残る" '[ "$(count_cmd "${S2}" Stop other-stop-hook)" = 1 ] && [ "$(count_cmd "${S2}" PreToolUse pre-tool)" = 1 ]'
check "hooks ファイルが消える" '[ ! -e "${H2}/.claude/hooks/notion-task-catch.py" ] && [ ! -e "${H2}/.claude/hooks/task_signals.py" ]'
check "task-sweep スキルが消える" '[ ! -e "${H2}/.claude/skills/task-sweep" ]'
check "設定ファイルは残る（--purge なし）" '[ -f "${H2}/.claude/task-catch.config.json" ]'

HOME="${H1}" bash "${KIT_DIR}/uninstall.sh" >/dev/null 2>&1
check "キットだけ入れていた場合、hooks キーごと消える" 'python3 -c "import json,sys;sys.exit(0 if \"hooks\" not in json.load(open(sys.argv[1])) else 1)" "${H1}/.claude/settings.json"'

# ---------------------------------------------------------------------------
rm -rf "${H1}" "${H2}" "${H3}"
echo ""
echo "結果: 成功 ${PASS} / 失敗 ${FAIL}"
if [ "${FAIL}" -ne 0 ]; then
  printf "失敗した項目:${FAILED_NAMES}\n"
  exit 1
fi
