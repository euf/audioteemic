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
import subprocess
import sys
from datetime import datetime, timedelta
from pathlib import Path

VAULT = Path(__file__).resolve().parent.parent.parent
FELLOW = VAULT / "Fellow"
TRANSCRIBED = VAULT / "Transcribed"   # локальные транскрипты (transcribe1x1.py) — тоже покрытие
SLACK = timedelta(minutes=10)
MIN_AGE = timedelta(hours=1)      # «прошло больше часа с окончания»
MIN_DURATION = 120                # короче — вероятно ложный старт/обрывок, не реальная встреча

# Названия встреч, которые НЕ надо товарить в Fellow (личное/мусор). Матч по НАЗВАНИЮ
# (часть имени файла после «(NNm) »), case-insensitive, exact — НЕ по сырой подстроке
# (подстрока «1» жила бы в каждой дате/длительности). Расширяй список по мере надобности.
IGNORE_TITLES = {"спорт", "1"}

def duration_sec(path: Path) -> float | None:
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1", str(path)],
            capture_output=True, text=True, timeout=10,
        )
        return float(out.stdout.strip())
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None

def fmt_duration(sec: float | None) -> str:
    if sec is None:
        return "?"
    m = round(sec / 60)
    return f"{m} мин" if m >= 1 else f"{int(sec)} сек"

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
    m = re.match(r"(\d{4})-(\d{2})-(\d{2})[,\s]+(\d{2})-(\d{2})", name)
    if not m:
        return None
    y, mo, d, h, mi = map(int, m.groups())
    try:
        return datetime(y, mo, d, h, mi)
    except ValueError:
        return None

def meeting_title(name: str) -> str:
    """Название встречи = часть имени после «(NNm) » (без расширения). Fallback — весь stem."""
    stem = name.rsplit(".", 1)[0]
    m = re.search(r"\)\s*(.+)$", stem)
    return (m.group(1) if m else stem).strip()

# 1-1 = имя оканчивается на «EF × f.lastname» (один хэндл после EF ×). Такое надёжно
# диаризуется локально по каналам (transcribe1x1.py). Всё остальное (групповые, встречи
# с названием) — локальная диаризация не гарантирована → путь в вики через заливку в Fellow.
# Матч по КОНЦУ имени (а не meeting_title): у старых записей нет «(Nm)», и title = весь stem.
ONE_ON_ONE_RE = re.compile(r"EF\s*[×xX]\s*[A-Za-zА-Яа-я][\w.\-]*\s*$")

def is_one_on_one(name: str) -> bool:
    return bool(ONE_ON_ONE_RE.search(name.rsplit(".", 1)[0]))

def fellow_windows():
    """Из Fellow-заметок: (окна [start,end], множество title'ов lower-strip).

    Матч по времени хрупок при ручной заливке — Fellow ставит своё время детекции,
    оно дрейфует от часов рекордера (кейс 24.07 EF×Игошева: title совпадал, а start/end
    съехали на +84 мин → окна не перекрылись). Поэтому дополнительно ловим по title:
    у залитой вручную записи Fellow называет заметку именем файла один-в-один.
    """
    windows, titles = [], set()
    if not FELLOW.is_dir():
        return windows, titles
    for p in FELLOW.glob("*.md"):
        try:
            head = p.read_text(encoding="utf-8", errors="replace")[:600]
        except OSError:
            continue
        t = re.search(r'^title:\s*"?(.+?)"?\s*$', head, re.M)
        if t:
            titles.add(t.group(1).strip().lower())
        s = re.search(r'^start:\s*"?(\d{4}-\d{2}-\d{2} \d{2}:\d{2})"?', head, re.M)
        e = re.search(r'^end:\s*"?(\d{4}-\d{2}-\d{2} \d{2}:\d{2})"?', head, re.M)
        if not s:
            continue
        try:
            st = datetime.strptime(s.group(1), "%Y-%m-%d %H:%M")
            en = datetime.strptime(e.group(1), "%Y-%m-%d %H:%M") if e else st + timedelta(hours=1)
        except ValueError:
            continue
        windows.append((st, en))
    return windows, titles

def transcribed_sources():
    """Имена аудиофайлов, уже локально транскрибированных (Transcribed/*.md,
    frontmatter `transcribed_from:`). Такая запись покрыта — не нужно ни в Fellow,
    ни повторно распознавать. Матч точный по имени файла (тул пишет его один-в-один."""
    srcs = set()
    if not TRANSCRIBED.is_dir():
        return srcs
    for p in TRANSCRIBED.glob("*.md"):
        try:
            head = p.read_text(encoding="utf-8", errors="replace")[:600]
        except OSError:
            continue
        m = re.search(r'^transcribed_from:\s*"?(.+?)"?\s*$', head, re.M)
        if m:
            srcs.add(m.group(1).strip())
    return srcs


def main():
    session = "--session" in sys.argv
    rec_dir = recordings_dir()
    if not rec_dir:
        return  # recorder не настроен — молчим
    now = datetime.now()
    windows, titles = fellow_windows()
    transcribed = transcribed_sources()
    candidates = []   # реальные встречи без транскрипта
    scraps = []        # <MIN_DURATION — вероятно ложный старт/обрывок
    for f in sorted(rec_dir.glob("*.m4a")):
        if meeting_title(f.name).lower() in IGNORE_TITLES:
            continue                    # личное/мусор — товарить не нужно (см. IGNORE_TITLES)
        try:
            mtime = datetime.fromtimestamp(f.stat().st_mtime)
        except OSError:
            continue
        if now - mtime < MIN_AGE:      # свежая — Fellow ещё может подъехать
            continue
        start = parse_start_from_name(f.name) or mtime
        end = mtime
        stem = f.name.rsplit(".", 1)[0].strip().lower()
        covered = (f.name in transcribed                            # локальный транскрипт (transcribe1x1.py)
                   or stem in titles                                # ручная заливка: title = имя файла
                   or any(ws - SLACK <= end and we + SLACK >= start  # либо пересечение окон
                          for ws, we in windows))
        if covered:
            continue
        dur = duration_sec(f)
        (scraps if dur is not None and dur < MIN_DURATION else candidates).append((f.name, dur))

    # маршрутизация: 1-1 → локальная транскрипция; групповые/прочие → заливка в Fellow
    oneone = [(n, d) for n, d in candidates if is_one_on_one(n)]
    group = [(n, d) for n, d in candidates if not is_one_on_one(n)]

    if session:
        if oneone:
            print(f"[calls] {len(oneone)} непокрыт(ая/ых) 1-1 (>1ч) → распознать локально "
                  f"(transcribe1x1.py → Transcribed/):")
            for name, dur in oneone[:5]:
                print(f'    • {name} ({fmt_duration(dur)})  →  python3 {VAULT}/scripts/record/transcribe1x1.py "{rec_dir}/{name}"')
        if group:
            print(f"[calls] {len(group)} непокрыт(ая/ых) групповы(х)/прочи(х) (>1ч) → залить в Fellow "
                  f"(локальная диаризация не гарантирована):")
            for name, dur in group[:5]:
                print(f"    • {name} ({fmt_duration(dur)})")
        if scraps:
            print(f"[calls] + {len(scraps)} обрывок(ов) <2 мин пропущен(о) как вероятный шум:")
            for name, dur in scraps:
                print(f"    • {name} ({fmt_duration(dur)})")
        return

    if not candidates and not scraps:
        print("Все страховочные записи сверены с Fellow (или папки нет).")
        return
    if oneone:
        print(f"1-1 без транскрипта ({len(oneone)}) — распознать локально (transcribe1x1.py → Transcribed/):")
        for name, dur in oneone:
            print(f'  • {name} ({fmt_duration(dur)})  →  python3 {VAULT}/scripts/record/transcribe1x1.py "{rec_dir}/{name}"')
    if group:
        print(f"Групповые/прочие без транскрипта ({len(group)}) — залить в Fellow руками:")
        for name, dur in group:
            print(f"  • {name} ({fmt_duration(dur)})")
    if scraps:
        print(f"Обрывки <2 мин, вероятно шум (не заливать, можно удалить):")
        for name, dur in scraps:
            print(f"  • {name} ({fmt_duration(dur)})")

if __name__ == "__main__":
    main()
