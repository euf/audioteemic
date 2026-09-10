#!/usr/bin/env python3
"""Fetch Google Calendar ICS → wiki/meta/calendar-upcoming.md (next 14 days).

Цель: .md-копия, которая 1:1 отражает точку истины, видимую глазами в календаре.

Разбор ICS отдан bulletproof-стеку `icalendar` + `recurring_ical_events` (вместо прежнего
самописного regex-парсинга): они корректно разворачивают RRULE / RDATE / EXDATE и переносы
отдельных occurrence'ов (RECURRENCE-ID) в реальные даты окна, с учётом таймзон. Это чинит
класс багов, из-за которых из .md пропадали/дублировались повторяющиеся встречи.

Зависимости живут в изолированном venv (~/.config/calendar-sync/venv-X.Y, по minor-версии Python). Скрипт сам создаёт
его при первом запуске и подкладывает site-packages в sys.path ТЕКУЩЕГО интерпретатора —
поэтому работает и как самостоятельный запуск (SessionStart-хук), и при импорте как модуля
(scripts/record/calendar-title.py делает fetch_events() в своём процессе). Голый `python3`
у всех вызывающих продолжает работать без изменений.

SessionStart синхронный: venv/pip-install несут timeout=_PIP_TIMEOUT (найдено 02.09.2026 —
без него офлайн-машина или недоступный PyPI подвешивали `pip install` на неопределённое
время, и с ним старт сессии целиком). Ошибка/таймаут долетает как RuntimeError до main(),
который уже ловит любое исключение из fetch_events() и тихо завершается с сообщением —
старт сессии не блокируется.

Таймзоны: всё приводится к локальному кипрскому времени (Asia/Nicosia), DST-aware
(EET/EEST). All-day и «суточные» события (00:00→00:00 следующего дня, как «No meetings
day») показываются как all-day-баннер на каждый охваченный день.

Источник — приватный ICS-URL (Google → «Секретный адрес в формате iCal»), лежит вне репо в
~/.config/calendar-sync/ics_url. Файл может содержать НЕСКОЛЬКО URL (по одному в строке) —
тогда все календари сливаются в одну ленту (# и пустые строки игнорируются).
"""

import subprocess
import sys
import urllib.request
import os
from datetime import date, datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

LOCAL_TZ = ZoneInfo("Asia/Nicosia")  # DST-aware; EET (UTC+2) зимой, EEST (UTC+3) летом
UTC      = ZoneInfo("UTC")

VAULT_DIR = Path(__file__).resolve().parent.parent
OUTPUT = VAULT_DIR / "wiki" / "meta" / "calendar-upcoming.md"
DAYS = 14
# Свой юзернейм (до @) — чтобы не считать себя участником и видеть свой PARTSTAT.
# Не константой в коде: этот файл синхронизируется в публичный снимок рекордера
# (scripts/record/sync-to-audiotee.sh → github.com/euf/audioteemic), а туда
# рабочий хэндл уезжать не должен. Пусто — просто никого не отфильтруем.
_SELF_FILE = Path.home() / ".config" / "calendar-sync" / "self"
SELF = (os.environ.get("CALENDAR_SELF")
        or (_SELF_FILE.read_text().strip().lower() if _SELF_FILE.exists() else ""))
MAX_ATTENDEES = 8

# --- Приватный ICS-URL (секрет, вне репо) — одна или несколько строк -----------------
_ICS_URL_FILE = Path.home() / ".config" / "calendar-sync" / "ics_url"

# --- Изолированный venv c icalendar + recurring_ical_events --------------------------
# Каталог venv ключуется minor-версией Python: один общий каталог делили
# /usr/bin/python3 (3.9, минимальный PATH под launchd) и brew-python (3.14) — при этом
# `venv/bin/python3` остаётся симлинком на того, кто создал каталог первым, и `bin/pip`
# второго интерпретатора молча ставит пакеты не в свой lib/pythonX.Y (07.09.2026 так
# пропали названия встреч из календаря в именах записей).
_VENV_DIR = (Path.home() / ".config" / "calendar-sync" /
             f"venv-{sys.version_info.major}.{sys.version_info.minor}")
_VENV_PKGS = ["icalendar", "recurring_ical_events", "python-dateutil", "tzdata"]
# SessionStart синхронный: без таймаута офлайн-машина (или недоступный PyPI)
# подвешивает venv/pip-install на неопределённое время и с ним — старт сессии
# целиком (найдено 02.09.2026). `--timeout` бьёт таймаут pip'а изнутри,
# subprocess-таймаут — страховка на случай, если и это не сработает (прокси-хэнг
# и т.п.). main() уже ловит любое исключение отсюда и молча завершается (см. ниже) —
# TimeoutExpired только должен долетать быстро, а не через минуты ретраев pip.
_PIP_TIMEOUT = 20


def _venv_site() -> Path:
    return _VENV_DIR / "lib" / f"python{sys.version_info.major}.{sys.version_info.minor}" / "site-packages"


def _ensure_deps() -> None:
    """Гарантировать импортируемость парсер-стека. Пытаемся импортировать напрямую; если
    нет — подкладываем venv (создаём при отсутствии) в sys.path текущего интерпретатора.
    Работает и для __main__, и для importlib-импорта — без переключения интерпретатора."""
    try:
        import icalendar  # noqa: F401
        import recurring_ical_events  # noqa: F401
        return
    except ImportError:
        pass
    site = _venv_site()
    try:
        if not (site / "icalendar").exists():
            # Проверяем пакет, а не каталог: пустой site-packages создаёт сам `venv`,
            # и `site.exists()` навсегда заглушил бы доустановку.
            subprocess.run([sys.executable, "-m", "venv", str(_VENV_DIR)], check=True,
                           timeout=_PIP_TIMEOUT,
                           stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
            pip = _VENV_DIR / "bin" / "pip"
            subprocess.run([str(pip), "install", "--quiet", "--upgrade", "pip",
                            "--timeout", "5"], check=True, timeout=_PIP_TIMEOUT,
                           stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
            subprocess.run([str(pip), "install", "--quiet", "--timeout", "5", *_VENV_PKGS],
                           check=True, timeout=_PIP_TIMEOUT,
                           stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
    except (subprocess.TimeoutExpired, subprocess.CalledProcessError, OSError) as exc:
        raise RuntimeError(f"calendar deps unavailable (офлайн или PyPI недоступен): {exc}") from exc
    sys.path.insert(0, str(site))
    import icalendar  # noqa: F401  — теперь обязан импортироваться (иначе пусть падает наверх)
    import recurring_ical_events  # noqa: F401


def _read_ics_urls() -> list:
    try:
        text = _ICS_URL_FILE.read_text(encoding="utf-8")
    except FileNotFoundError:
        raise SystemExit(
            f"[fetch-calendar] no ICS url: put the private basic.ics URL(s) into {_ICS_URL_FILE} "
            "(one per line for multiple calendars)"
        )
    urls = [ln.strip() for ln in text.splitlines()
            if ln.strip() and not ln.lstrip().startswith("#")]
    if not urls:
        raise SystemExit(f"[fetch-calendar] {_ICS_URL_FILE} is empty")
    return urls


# --- Хелперы разбора компонентов -----------------------------------------------------

def _attendee_list(comp) -> list:
    """Нормализованный список ATTENDEE-объектов (icalendar иногда даёт один, иногда список)."""
    att = comp.get("ATTENDEE")
    if att is None:
        return []
    return list(att) if isinstance(att, list) else [att]


def _addr(att) -> str:
    v = str(att)
    return v[7:] if v.lower().startswith("mailto:") else v


def _self_declined(comp) -> bool:
    """Владелец календаря отклонил встречу → скрываем (как в UI)."""
    for att in _attendee_list(comp):
        if _addr(att).split("@")[0].lower() != SELF:
            continue
        if str(getattr(att, "params", {}).get("PARTSTAT", "")).upper() == "DECLINED":
            return True
    return False


def _attendee_usernames(comp) -> list:
    """Юзернеймы (до @) участников, кроме себя и ресурсов; в порядке фида, без дублей."""
    seen, out = set(), []
    for att in _attendee_list(comp):
        if str(getattr(att, "params", {}).get("CUTYPE", "")).upper() == "RESOURCE":
            continue
        user = _addr(att).split("@")[0].lower()
        if not user or user == SELF or user in seen:
            continue
        seen.add(user)
        out.append(user)
    return out


def _classify(dtstart, dtend):
    """→ (all_day: bool, span_days: int, start_dt|start_date, end_dt|None).

    All-day = либо VALUE=DATE (dtstart — date), либо «суточное» таймед-событие
    (старт локально в 00:00 и длительность кратна суткам, как «No meetings day»)."""
    if not isinstance(dtstart, datetime):  # VALUE=DATE — настоящий all-day
        start_d = dtstart
        end_d = dtend if (dtend and not isinstance(dtend, datetime)) else (dtstart + timedelta(days=1))
        return True, max(1, (end_d - start_d).days), start_d, end_d
    s = dtstart.astimezone(LOCAL_TZ)
    if isinstance(dtend, datetime):
        e = dtend.astimezone(LOCAL_TZ)
        secs = (e - s).total_seconds()
        if s.hour == 0 and s.minute == 0 and secs >= 86400 and secs % 86400 == 0:
            return True, int(secs // 86400), s.date(), e.date()
        return False, 1, s, e
    return False, 1, s, None


def fetch_events() -> list:
    """Список событий на окно DAYS дней, начиная с сегодня, приведённых к локальному TZ.

    Публичный API (используется scripts/record/calendar-title.py). Каждый элемент:
      {date, start_time ('HH:MM'|''), end_time ('HH:MM'|''), summary, attendees, all_day}
    Многодневные/all-day события разворачиваются в отдельную запись на КАЖДЫЙ охваченный
    день окна (start_time/end_time пустые). Отсортировано: all-day сначала, затем по времени.
    """
    _ensure_deps()
    import icalendar
    import recurring_ical_events

    today = date.today()
    cutoff = today + timedelta(days=DAYS)

    occurrences = []
    for url in _read_ics_urls():
        with urllib.request.urlopen(url, timeout=30) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
        cal = icalendar.Calendar.from_ical(raw)
        # between() разворачивает повторы/переносы и отдаёт реальные occurrence'ы окна.
        occurrences.extend(recurring_ical_events.of(cal).between(today, cutoff))

    events = []
    for comp in occurrences:
        if str(comp.get("STATUS", "")).upper() == "CANCELLED":
            continue
        if _self_declined(comp):
            continue

        dtstart = comp.get("DTSTART").dt
        dtend = comp.get("DTEND").dt if comp.get("DTEND") is not None else None
        summary = str(comp.get("SUMMARY", "")).strip()
        attendees = _attendee_usernames(comp)
        # CLASS: отсутствует → PUBLIC (по iCal-спеке). PRIVATE/CONFIDENTIAL = скрыто от
        # внешнего читателя — помечаем в .md, чтобы отличать личные блоки от открытых встреч.
        private = str(comp.get("CLASS", "")).upper() in ("PRIVATE", "CONFIDENTIAL")

        all_day, span_days, start_ref, _end_ref = _classify(dtstart, dtend)

        if all_day:
            first = start_ref if isinstance(start_ref, date) and not isinstance(start_ref, datetime) else start_ref
            for i in range(span_days):
                d = first + timedelta(days=i)
                if today <= d < cutoff:
                    events.append({"date": d, "start_time": "", "end_time": "",
                                   "summary": summary, "attendees": attendees,
                                   "all_day": True, "private": private})
        else:
            d = start_ref.date()
            if today <= d < cutoff:
                events.append({
                    "date": d,
                    "start_time": start_ref.strftime("%H:%M"),
                    "end_time": _end_ref.strftime("%H:%M") if _end_ref else "",
                    "summary": summary,
                    "attendees": attendees,
                    "all_day": False,
                    "private": private,
                })

    # all-day сначала (баннеры сверху), затем по времени старта, затем по названию.
    events.sort(key=lambda e: (e["date"], not e["all_day"], e["start_time"] or "", e["summary"]))
    return events


def _dedup(events: list) -> list:
    """Убрать точные дубли (один физический слот, попавший из >1 календаря)."""
    seen, out = set(), []
    for e in events:
        key = (e["date"], e["start_time"], e["end_time"], e["summary"])
        if key in seen:
            continue
        seen.add(key)
        out.append(e)
    return out


def main():
    today = date.today()
    cutoff = today + timedelta(days=DAYS)

    try:
        events = _dedup(fetch_events())
    except Exception as exc:
        print(f"[fetch-calendar] ERROR: {exc}")
        return

    by_date: dict = {}
    for e in events:
        by_date.setdefault(e["date"], []).append(e)

    out = [
        "---",
        "type: meta",
        f'title: "Calendar — next {DAYS} days"',
        f"updated: {datetime.now().strftime('%Y-%m-%d %H:%M')}",
        "---",
        "",
        f"# Calendar: {today.strftime('%d %b')} – {cutoff.strftime('%d %b %Y')}",
        "",
    ]

    if not events:
        out.append("*No events in next 14 days.*")
    else:
        for d in sorted(by_date):
            out.append(f"## {d.strftime('%a %d %b')}")
            for e in by_date[d]:
                if e["all_day"]:
                    t = "all-day"
                elif e["start_time"] and e["end_time"]:
                    t = f"{e['start_time']}–{e['end_time']}"
                elif e["start_time"]:
                    t = e["start_time"]
                else:
                    t = "all-day"
                names = e["attendees"]
                if names:
                    if len(names) > MAX_ATTENDEES:
                        shown = ", ".join(names[:MAX_ATTENDEES])
                        members = f" · *{shown}, +{len(names) - MAX_ATTENDEES}*"
                    else:
                        members = f" · *{', '.join(names)}*"
                else:
                    members = ""
                flag = " · (private)" if e.get("private") else ""
                out.append(f"- {t} **{e['summary']}**{members}{flag}")
            out.append("")

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text("\n".join(out), encoding="utf-8")
    print(f"[fetch-calendar] written → {OUTPUT.relative_to(VAULT_DIR)}")


if __name__ == "__main__":
    main()
