#!/usr/bin/env python3
"""calendar-title.py — наиболее правдоподобное название текущей встречи (для имени записи).

Печатает в stdout filename-safe название события календаря, покрывающего «сейчас», или
пустую строку (тогда record-meeting.sh даёт имя только по дате-времени). Переиспользует
парсер ICS из fetch-calendar.py (один источник, не дублируем сеть/разбор).

Эвристика (по просьбе EF):
  • «джойн с опозданием 10–20 мин — норма» → событие матчится, если сейчас в его окне
    начиная с ~5 мин до старта и заканчивая за 5 мин до конца;
  • «старт за 5 мин до конца — скорее уже следующая встреча» → последние 5 мин окна
    события НЕ засчитываются; среди подходящих берём с самым ПОЗДНИМ стартом (если ты
    в хвосте A, а B уже началась — победит B).
Сеть недоступна / URL нет / нет совпадений → пустая строка (graceful, имя по времени).
"""
from __future__ import annotations  # `Path | None` в сигнатурах — иначе нужен 3.10+

import importlib.util
import os
import re
import sys
sys.dont_write_bytecode = True  # не плодить __pycache__ в vault (флаг ставится до локальных import)
from datetime import datetime, timedelta
from pathlib import Path

DIR = Path(__file__).resolve().parent
EARLY = timedelta(minutes=5)   # можно начать запись за 5 мин до старта
TAIL = timedelta(minutes=5)    # последние 5 мин события не наши (уже следующая)


def _find_fetchcal() -> Path | None:
    """fetch-calendar.py живёт в scripts/ (родитель), не в scripts/record/. Ищем в
    override-переменной, затем рядом, затем на уровень выше. Нет → None (имя по времени)."""
    env = os.environ.get("MEETING_REC_FETCHCAL")
    cands = ([Path(env)] if env else []) + [DIR / "fetch-calendar.py", DIR.parent / "fetch-calendar.py"]
    return next((p for p in cands if p.exists()), None)


def sanitize(s: str) -> str:
    s = re.sub(r'[\\/:*?"<>|]+', " ", s or "")   # запрещённые в имени файла
    s = re.sub(r"\s+", " ", s).strip()
    return s[:60]


def main() -> None:
    fetchcal = _find_fetchcal()
    if fetchcal is None:
        print("[calendar-title] fetch-calendar.py не найден", file=sys.stderr)
        print(""); return                        # → имя по дате-времени
    try:
        spec = importlib.util.spec_from_file_location("fetchcal", fetchcal)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)             # top-level читает ICS_URL; сеть — в fetch_events
        events = mod.fetch_events()
        tz = mod.LOCAL_TZ
    except BaseException as exc:                 # SystemExit тоже (нет ~/.config/…/ics_url на новой машине)
        # stdout — контракт (пустая строка = имя по дате-времени), причину пишем в stderr:
        # немой отказ здесь три недели уносил названия встреч из имён записей (07.09.2026).
        print(f"[calendar-title] {type(exc).__name__}: {exc}", file=sys.stderr)
        print(""); return

    now = datetime.now(tz)
    today = now.date()
    best = None  # (start_dt, summary) — с самым поздним стартом среди подходящих
    for e in events:
        if e.get("date") != today or not e.get("start_time") or not e.get("end_time"):
            continue
        try:
            sh, sm = map(int, e["start_time"].split(":"))
            eh, em = map(int, e["end_time"].split(":"))
        except (ValueError, AttributeError):
            continue
        S = datetime(today.year, today.month, today.day, sh, sm, tzinfo=tz)
        E = datetime(today.year, today.month, today.day, eh, em, tzinfo=tz)
        if E <= S:                                # через полночь — для встреч не бывает, пропускаем
            continue
        if S - EARLY <= now <= E - TAIL:
            if best is None or S > best[0]:
                best = (S, e.get("summary", ""))
    print(sanitize(best[1]) if best and best[1] else "")


if __name__ == "__main__":
    main()
