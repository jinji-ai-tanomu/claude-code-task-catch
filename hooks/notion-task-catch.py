#!/usr/bin/env python3
"""Stop hook: 会話中に発生した本人のタスクをNotionに取りこぼさず登録させる。

応答が終わるたびに走り、前回チェック地点から今までのユーザー発言だけを見る。
タスクらしき言い回しがあり、かつその区間でNotionへの書き込みが行われていなければ、
decision=block を返してClaudeを続行させ、登録判断をさせる。

ループ防止: 発火したら必ずチェック地点を末尾まで進めるので、同じ区間で二度は鳴らない。
設定ファイル（~/.claude/task-catch.config.json）が無い・壊れているときは何もしない。
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from task_signals import (  # noqa: E402
    NOTION_WRITE,
    STATE_DIR,
    has_task_signal,
    load_config,
    owner_label,
    parse,
    user_text,
)


def build_reason(cfg):
    who = owner_label(cfg)
    lines = [
        f"[自動チェック] このセッションの直近のやりとりに、{who}が後で自分で手を動かす"
        "必要のある事項が含まれている可能性があります。",
        "",
        "やること:",
        f"1. 直近のやりとりを見返し、「{who}が後で着手する必要があるタスク」があるか判断する。",
        "   - この会話の中でClaudeが既に完了させた作業は対象外。",
        "   - 単なる感想・雑談・調査結果の共有も対象外。",
        "2. タスクがある場合のみ、Notionのタスク用DB",
        f"   ({cfg['notion_task_db']}) にページを作成する。",
        "   - タイトルは動詞で終わる一文にする（例:「見積書を取引先に送る」）。",
        "   - 期限が会話中に明示されていた場合だけ日付を入れる。推測で埋めない。",
    ]
    if cfg["notion_project_db"]:
        lines += [
            "   - 該当するプロジェクトが分かればプロジェクトrelationを繋ぐ",
            f"     (プロジェクトDB: {cfg['notion_project_db']})。",
        ]
    lines += [
        "   - 既に同じ内容のタスクがDBにないか、作る前に notion-query-data-sources で確認する。",
        "3. タスクが無い、または既に登録済みなら、「タスクなし」とだけ一言返して終わる。",
        "   余計な説明はしない。",
        "",
        "登録した場合は、登録したタスク名だけを箇条書きで報告すること。",
    ]
    return "\n".join(lines) + "\n"


def load_checkpoint(session_id):
    path = os.path.join(STATE_DIR, f"{session_id}.json")
    try:
        with open(path) as f:
            return int(json.load(f).get("lines", 0))
    except (OSError, ValueError, TypeError, AttributeError):
        return 0


def save_checkpoint(session_id, lines):
    os.makedirs(STATE_DIR, exist_ok=True)
    path = os.path.join(STATE_DIR, f"{session_id}.json")
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"lines": lines}, f)
    os.replace(tmp, path)


def main():
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return 0
    if not isinstance(payload, dict):
        return 0

    # 直前のStop hookで既に続行中なら、二重発火させない
    if payload.get("stop_hook_active"):
        return 0

    cfg = load_config()
    if cfg is None:
        return 0

    session_id = payload.get("session_id")
    transcript = payload.get("transcript_path")
    if not session_id or not transcript or not os.path.exists(transcript):
        return 0
    # セッションIDはファイル名に使うので、パス区切りを含むものは受け付けない
    session_id = str(session_id)
    if os.sep in session_id or session_id.startswith("."):
        return 0

    with open(transcript, errors="replace") as f:
        lines = f.readlines()

    start = load_checkpoint(session_id)
    if start >= len(lines):
        return 0
    window = lines[start:]

    # 何が起きても、この区間は二度と評価しない
    save_checkpoint(session_id, len(lines))

    if NOTION_WRITE.search("".join(window)):
        return 0

    said = []
    for line in window:
        entry = parse(line)
        if entry is None:
            continue
        text = user_text(entry)
        if text.strip():
            said.append(text)

    if not said:
        return 0
    if not has_task_signal("\n".join(said), cfg):
        return 0

    print(json.dumps({"decision": "block", "reason": build_reason(cfg)}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
