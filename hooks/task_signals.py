"""Stop hook と日次スイープで共有する、設定の読み込みとタスクらしさの判定ロジック。"""

import json
import os
import re

CONFIG_PATH = os.path.expanduser("~/.claude/task-catch.config.json")
STATE_DIR = os.path.expanduser("~/.claude/state/notion-task-catch")

DEFAULT_OWNER = "あなた"
DEFAULT_SWEEP_HOURS = 30

# 本人が「後で自分で手を動かす」ことを示唆する言い回し。
# 広めに拾って、実際にタスクかどうかの判断はClaude側に任せる。
TASK_SIGNALS = re.compile(
    r"(あとで|後で|やらないと|しないと|しなきゃ|やらなきゃ|やっとかないと|やっといて"
    r"|忘れ(ない|そう|ずに)|覚えといて|メモしといて|控えといて"
    r"|todo|ToDo|TODO|タスク(に|と|だ|です|化|追加|登録)"
    r"|締切|締め切り|期限|deadline"
    r"|(まで|うち)に(やる|やらな|出す|送る|決める|終わらせ|完成|提出|申込|申し込|予約|連絡)"
    r"|次(は|に)やる|次のステップ|残ってる|残タスク|保留|ペンディング"
    r"|申し込(む|み)|予約(する|しないと|取)|提出(する|しないと)"
    r"|連絡(する|しないと|しとく)|返信(する|しないと)|問い合わせ(る|しないと)"
    r"|買わないと|買っとく|注文(する|しないと)"
    r"|来週|再来週|来月|明日|明後日|今週中|今月中)",
    re.IGNORECASE,
)

# この区間ですでにNotionへ書き込んでいれば、登録済みとみなす
NOTION_WRITE = re.compile(
    r"notion-(create-pages|update-page|create-database|duplicate-page)"
)

_SYSTEM_REMINDER = re.compile(r"<system-reminder>.*?</system-reminder>", re.S)


def load_config():
    """設定を読む。無い・壊れている・必須項目が空なら None を返す。"""
    try:
        with open(CONFIG_PATH, encoding="utf-8") as f:
            raw = json.load(f)
    except (OSError, ValueError):
        return None
    if not isinstance(raw, dict):
        return None

    task_db = raw.get("notion_task_db")
    if not isinstance(task_db, str) or not task_db.strip():
        return None

    project_db = raw.get("notion_project_db")
    if not isinstance(project_db, str):
        project_db = ""

    owner = raw.get("owner_name")
    if not isinstance(owner, str) or not owner.strip():
        owner = DEFAULT_OWNER

    hours = raw.get("sweep_hours")
    if isinstance(hours, bool) or not isinstance(hours, (int, float)) or hours <= 0:
        hours = DEFAULT_SWEEP_HOURS

    extra = []
    patterns = raw.get("extra_signals")
    if isinstance(patterns, list):
        for p in patterns:
            if not isinstance(p, str) or not p:
                continue
            try:
                extra.append(re.compile(p, re.IGNORECASE))
            except re.error:
                # 書き間違えた正規表現は無視して、残りだけ使う
                continue

    return {
        "notion_task_db": task_db.strip(),
        "notion_project_db": project_db.strip(),
        "owner_name": owner.strip(),
        "sweep_hours": int(hours),
        "extra_signals": extra,
    }


def owner_label(cfg):
    """Claude向けの指示文で使う呼び方。既定値のままなら「ユーザー本人」にする。

    指示文の中で「あなた」と書くとClaude自身を指してしまうため。
    """
    owner = cfg["owner_name"]
    if owner == DEFAULT_OWNER:
        return "ユーザー本人"
    return f"{owner}本人"


def has_task_signal(text, cfg):
    if TASK_SIGNALS.search(text):
        return True
    return any(p.search(text) for p in cfg["extra_signals"])


def user_text(entry):
    """ユーザーの生の発言だけを返す。tool_result や system-reminder は除く。"""
    if entry.get("type") != "user":
        return ""
    # isMeta はスキル本文やスラッシュコマンドの注入。isSidechain はサブエージェント側。
    # どちらも本人が打った言葉ではないので拾わない。
    if entry.get("isMeta") or entry.get("isSidechain"):
        return ""
    message = entry.get("message")
    if not isinstance(message, dict):
        return ""
    content = message.get("content")
    if isinstance(content, str):
        text = content
    elif isinstance(content, list):
        text = "\n".join(
            b.get("text", "")
            for b in content
            if isinstance(b, dict) and b.get("type") == "text"
        )
    else:
        return ""
    text = _SYSTEM_REMINDER.sub("", text)
    # フック自身が注入した文面は拾わない
    if "[自動チェック]" in text or "[日次スイープ]" in text:
        return ""
    return text


def parse(line):
    try:
        entry = json.loads(line)
    except ValueError:
        return None
    return entry if isinstance(entry, dict) else None

def config_problem():
    """設定が使えない理由を、人が読める1行で返す（手動実行のときだけ使う）。"""
    try:
        with open(CONFIG_PATH, encoding="utf-8") as f:
            raw = json.load(f)
    except OSError:
        return f"設定ファイルがありません（{CONFIG_PATH}）"
    except ValueError as e:
        return f"設定ファイルの書式が壊れています（{CONFIG_PATH}: {e}）"
    if not isinstance(raw, dict) or not str(raw.get("notion_task_db") or "").strip():
        return f"設定が未完了です（{CONFIG_PATH} の notion_task_db を入れてください）"
    return "設定を読めませんでした"
