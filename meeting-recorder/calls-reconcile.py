#!/usr/bin/env python3
"""calls-reconcile.py — страховочные записи, которым Fellow НЕ дал транскрипт.

Модель: записи созвонов лежат ВНЕ vault'а (iCloud Drive «Meeting Recordings») как
страховка. Обычно Fellow-бот приносит транскрипт сам (→ Fellow/ через sync). Если по
записи транскрипта нет и с её окончания прошёл >1 час — Fellow, вероятно, подвёл →
стоит залить файл в Fellow руками. Этот скрипт находит такие «неотоварённые» записи.

Матчинг: запись [start(из имени файла), end(mtime)] покрыта, если ЕСТЬ Fellow-заметка,
чьё окно [start,end] пересекается с окном записи (±10 мин слака). Fellow-заметки несут
точные `start:`/`end:` во frontmatter — матч точный, не по дате.

Вывод: --session → строка `[calls] …` (или тишина, если чисто); без флага → детали.
Тихо выходит, если папки записей нет (recorder не настроен) — не шумит на чужих машинах.
"""
import os
import re
import sys
from datetime import datetime, timedelta
from pathlib import Path

VAULT = Path(__file__).resolve().parent.parent.parent
FELLOW = VAULT / "Fellow"
SLACK = timedelta(minutes=10)
MIN_AGE = timedelta(hours=1)   # «прошло больше часа с окончания»

def recordings_dir() -> Path | None:
    env = os.environ.get("MEETING_REC_OUTDIR")
    if env:
        p = Path(env)
        return p if p.is_dir() else None
    icloud = Path.home() / "Library/Mobile Documents/com~apple~CloudDocs/Meeting Recordings"
    if icloud.is_dir():
        return icloud
    local = Path.home() / "Recordings/meeting-backups"
    return local if local.is_dir() else None

def parse_start_from_name(name: str):
    m = re.match(r"(\d{4})-(\d{2})-(\d{2}) (\d{2})-(\d{2})", name)
    if not m:
        return None
    y, mo, d, h, mi = map(int, m.groups())
    try:
        return datetime(y, mo, d, h, mi)
    except ValueError:
        return None

def fellow_windows():
    """Список (start, end) из Fellow-заметок (наивное локальное время)."""
    out = []
    if not FELLOW.is_dir():
        return out
    for p in FELLOW.glob("*.md"):
        try:
            head = p.read_text(encoding="utf-8", errors="replace")[:600]
        except OSError:
            continue
        s = re.search(r'^start:\s*"?(\d{4}-\d{2}-\d{2} \d{2}:\d{2})"?', head, re.M)
        e = re.search(r'^end:\s*"?(\d{4}-\d{2}-\d{2} \d{2}:\d{2})"?', head, re.M)
        if not s:
            continue
        try:
            st = datetime.strptime(s.group(1), "%Y-%m-%d %H:%M")
            en = datetime.strptime(e.group(1), "%Y-%m-%d %H:%M") if e else st + timedelta(hours=1)
        except ValueError:
            continue
        out.append((st, en))
    return out

def main():
    session = "--session" in sys.argv
    rec_dir = recordings_dir()
    if not rec_dir:
        return  # recorder не настроен — молчим
    now = datetime.now()
    windows = fellow_windows()
    unreconciled = []
    for f in sorted(rec_dir.glob("*.m4a")):
        try:
            mtime = datetime.fromtimestamp(f.stat().st_mtime)
        except OSError:
            continue
        if now - mtime < MIN_AGE:      # свежая — Fellow ещё может подъехать
            continue
        start = parse_start_from_name(f.name) or mtime
        end = mtime
        covered = any(ws - SLACK <= end and we + SLACK >= start for ws, we in windows)
        if not covered:
            unreconciled.append((f.name, start))

    if session:
        if unreconciled:
            print(f"[calls] {len(unreconciled)} запис(ь/и) без транскрипта Fellow (>1ч) — залить в Fellow?")
            for name, _ in unreconciled[:5]:
                print(f"    • {name}")
        return

    if not unreconciled:
        print("Все страховочные записи сверены с Fellow (или папки нет).")
        return
    print(f"Неотоварённые записи ({len(unreconciled)}) — Fellow не дал транскрипт, залить руками:")
    for name, start in unreconciled:
        print(f"  • {name}")

if __name__ == "__main__":
    main()
