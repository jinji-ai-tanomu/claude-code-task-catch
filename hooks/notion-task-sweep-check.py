#!/usr/bin/env python3
"""SessionStart hook: その日まだ日次スイープをしていなければ、Claudeに実行させる。

cronではなくセッション開始をトリガーにしているのは、Notion MCPが
対話セッションでしか使えないため。1日1回だけ発火する。
設定ファイル（~/.claude/task-catch.config.json）が無い・壊れているときは何もしない。
"""

import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from task_signals import STATE_DIR, load_config, owner_label  # noqa: E402

STAMP = os.path.join(STATE_DIR, "last-sweep")


def build_instruction(cfg):
    who = owner_label(cfg)
    hours = cfg["sweep_hours"]
    return (
        "[日次スイープ] 本日ぶんのタスク取りこぼしチェックがまだ実行されていません。\n"
        "ユーザーの用件に入る前に、まずこれを片付けてください。\n"
        "\n"
        f"1. `python3 ~/.claude/hooks/notion-task-sweep.py --hours {hours}` を実行する。\n"
        f"   直近{hours}時間のセッションログから、タスクらしき{who}の発言が候補として出てくる。\n"
        f"2. 各候補について、{who}が後で着手する必要がある事項かを判断する。\n"
        "   Claudeがその場で完了させた作業・雑談・調査結果の共有は除外する。\n"
        "3. 残ったものを、Notionのタスク用DB\n"
        f"   ({cfg['notion_task_db']}) の未完了タスクと突き合わせ、\n"
        "   **まだ登録されていないものだけ**をページとして作成する。\n"
        "   `notion-query-data-sources` で既存を確認してから作ること。重複を作らない。\n"
        "4. 完了したら `mkdir -p ~/.claude/state/notion-task-catch && touch ~/.claude/state/notion-task-catch/last-sweep` を実行する。\n"
        "5. 報告は「日次スイープ: 追加N件（タスク名の箇条書き）」または\n"
        "   「日次スイープ: 追加なし」の1ブロックだけ。それ以上は書かない。\n"
        "   そのあと、ユーザーの用件に移る。\n"
    )


def main():
    try:
        json.load(sys.stdin)
    except ValueError:
        pass

    cfg = load_config()
    if cfg is None:
        return 0

    today = time.strftime("%Y-%m-%d")
    try:
        if time.strftime("%Y-%m-%d", time.localtime(os.path.getmtime(STAMP))) == today:
            return 0
    except OSError:
        pass

    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "SessionStart",
                    "additionalContext": build_instruction(cfg),
                }
            },
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
