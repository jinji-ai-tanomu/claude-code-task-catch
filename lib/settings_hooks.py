#!/usr/bin/env python3
"""settings.json の hooks に、このキットのエントリを足す／外す。

  usage: settings_hooks.py check  <settings.json>
         settings_hooks.py add    <settings.json>
         settings_hooks.py remove <settings.json>

既存の設定には触らない。同じ command が既にあれば二重登録しない。
終了コード: 0=成功 / 2=settings.json が読めない（壊れている）
"""

import json
import os
import sys

ENTRIES = {
    "SessionStart": {
        "type": "command",
        "command": "python3 ~/.claude/hooks/notion-task-sweep-check.py 2>/dev/null || true",
        "timeout": 10,
    },
    "Stop": {
        "type": "command",
        "command": "python3 ~/.claude/hooks/notion-task-catch.py 2>/dev/null || true",
        "timeout": 15,
        "statusMessage": "タスクの取りこぼしを確認中",
    },
}

# 外すときは、command にこれらのファイル名を含むものを対象にする
SCRIPT_NAMES = ("notion-task-sweep-check.py", "notion-task-catch.py")


def load(path):
    if not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8") as f:
        text = f.read()
    if not text.strip():
        return {}
    data = json.loads(text)
    if not isinstance(data, dict):
        raise ValueError("settings.json の中身がオブジェクトではありません")
    hooks = data.get("hooks")
    if hooks is not None and not isinstance(hooks, dict):
        raise ValueError("settings.json の hooks がオブジェクトではありません")
    return data


def save(path, data):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, path)


def commands_in(groups):
    for group in groups:
        if not isinstance(group, dict):
            continue
        for h in group.get("hooks") or []:
            if isinstance(h, dict) and isinstance(h.get("command"), str):
                yield h["command"]


def add(data):
    hooks = data.setdefault("hooks", {})
    added = []
    for event, entry in ENTRIES.items():
        groups = hooks.get(event)
        if not isinstance(groups, list):
            groups = []
            hooks[event] = groups
        if entry["command"] in set(commands_in(groups)):
            continue
        groups.append({"hooks": [dict(entry)]})
        added.append(event)
    return added


def is_ours(h):
    cmd = h.get("command") if isinstance(h, dict) else None
    return isinstance(cmd, str) and any(name in cmd for name in SCRIPT_NAMES)


def remove(data):
    hooks = data.get("hooks")
    if not isinstance(hooks, dict):
        return 0
    removed = 0
    for event in list(hooks.keys()):
        groups = hooks[event]
        if not isinstance(groups, list):
            continue
        kept_groups = []
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                kept_groups.append(group)
                continue
            kept = [h for h in group["hooks"] if not is_ours(h)]
            removed += len(group["hooks"]) - len(kept)
            if kept:
                group["hooks"] = kept
                kept_groups.append(group)
        if kept_groups:
            hooks[event] = kept_groups
        else:
            del hooks[event]
    if not hooks:
        del data["hooks"]
    return removed


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("check", "add", "remove"):
        print(__doc__, file=sys.stderr)
        return 1
    action, path = sys.argv[1], sys.argv[2]
    try:
        data = load(path)
    except (OSError, ValueError) as e:
        print(f"settings.json を読めませんでした: {e}", file=sys.stderr)
        return 2

    if action == "check":
        return 0
    if action == "add":
        added = add(data)
        save(path, data)
        if added:
            print("  hooks に追加: " + ", ".join(added))
        else:
            print("  hooks は登録済みのため変更なし")
        return 0

    removed = remove(data)
    if removed:
        save(path, data)
        print(f"  hooks から {removed} 件外しました")
    else:
        print("  hooks に該当エントリはありませんでした")
    return 0


if __name__ == "__main__":
    sys.exit(main())
