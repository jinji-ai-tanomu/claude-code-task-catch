#!/usr/bin/env python3
"""日次スイープ: 直近のセッションログから、タスクらしき本人の発言を洗い出して出力する。

Stop hook がすり抜けた分の回収用。判定はせず候補を出すだけで、
実際にタスクかどうか・既に登録済みかどうかの判断はClaude側が行う。

  usage: notion-task-sweep.py [--hours N]   (既定は設定の sweep_hours、無ければ30)
"""

import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from task_signals import CONFIG_PATH, config_problem, has_task_signal, load_config, parse, user_text  # noqa: E402

PROJECTS_DIR = os.path.expanduser("~/.claude/projects")
MAX_CHARS = 400


def main():
    cfg = load_config()
    if cfg is None:
        print(config_problem())
        return 0

    hours = cfg["sweep_hours"]
    if "--hours" in sys.argv:
        try:
            hours = int(sys.argv[sys.argv.index("--hours") + 1])
        except (IndexError, ValueError):
            pass
    cutoff = time.time() - hours * 3600

    print(f"登録先DB: {cfg['notion_task_db']}")
    if cfg["notion_project_db"]:
        print(f"プロジェクトDB: {cfg['notion_project_db']}")
    print(f"対象: 直近{hours}時間")

    transcripts = []
    for root, _dirs, files in os.walk(PROJECTS_DIR):
        for name in files:
            if not name.endswith(".jsonl"):
                continue
            path = os.path.join(root, name)
            try:
                if os.path.getmtime(path) >= cutoff:
                    transcripts.append(path)
            except OSError:
                pass

    found = 0
    for path in sorted(transcripts, key=os.path.getmtime):
        hits = []
        try:
            with open(path, errors="replace") as f:
                for line in f:
                    entry = parse(line)
                    if entry is None:
                        continue
                    text = user_text(entry).strip()
                    if text and has_task_signal(text, cfg):
                        hits.append(text[:MAX_CHARS])
        except OSError:
            continue
        if not hits:
            continue
        found += len(hits)
        stamp = time.strftime("%m/%d %H:%M", time.localtime(os.path.getmtime(path)))
        print(f"\n## {stamp}  {os.path.basename(os.path.dirname(path))}")
        for h in hits:
            print(f"- {h}")

    if not found:
        print("候補なし")
    return 0


if __name__ == "__main__":
    sys.exit(main())
