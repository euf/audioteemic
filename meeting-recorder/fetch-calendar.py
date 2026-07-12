#!/usr/bin/env python3
"""Fetch Google Calendar ICS → wiki/meta/calendar-upcoming.md (next 14 days).

Runs at session start via SessionStart hook in .claude/settings.json.
Times ending in Z are UTC → converted to local Cyprus time (Asia/Nicosia),
which is DST-aware: EET (UTC+2) in winter, EEST (UTC+3) in summer.
Times with TZID are already local — shown as-is.
"""

import re
import urllib.request
from datetime import date, datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

LOCAL_TZ = ZoneInfo("Asia/Nicosia")  # DST-aware; replaces a hardcoded UTC+3
UTC      = ZoneInfo("UTC")

# Приватный ICS-URL — секрет, живёт вне репо (поэтому сам скрипт можно коммитить).
_ICS_URL_FILE = Path.home() / ".config" / "calendar-sync" / "ics_url"
try:
    ICS_URL = _ICS_URL_FILE.read_text(encoding="utf-8").strip()
except FileNotFoundError:
    raise SystemExit(
        f"[fetch-calendar] no ICS url: put the private basic.ics URL into {_ICS_URL_FILE}"
    )

VAULT_DIR = Path(__file__).resolve().parent.parent
OUTPUT = VAULT_DIR / "wiki" / "meta" / "calendar-upcoming.md"
DAYS = 14
SELF = "e.faivuzhinskii"
MAX_ATTENDEES = 8


def unfold(text: str) -> str:
    """Unfold ICS line continuations (lines starting with space/tab)."""
    return re.sub(r"\r?\n[ \t]", "", text)


def prop_value(line: str) -> str:
    """Extract value after first colon, ignoring param key."""
    return line.split(":", 1)[1] if ":" in line else ""


def get_prop(lines: list, key: str) -> str:
    for line in lines:
        if line.upper().split(";")[0].split(":")[0] == key:
            return prop_value(line)
    return ""


def parse_date(value: str, raw_line: str = "") -> date | None:
    v = value.strip().rstrip("Z")
    if "VALUE=DATE" in raw_line or (len(v) == 8 and v.isdigit()):
        try:
            return date(int(v[:4]), int(v[4:6]), int(v[6:8]))
        except ValueError:
            return None
    for fmt in ("%Y%m%dT%H%M%S", "%Y%m%dT%H%M"):
        try:
            return datetime.strptime(v, fmt).date()
        except ValueError:
            continue
    return None


def parse_time(value: str, raw_line: str = "") -> str:
    """Return HH:MM string. Z suffix → local Cyprus time (DST-aware). All-day → ''."""
    v = value.strip()
    is_utc = v.endswith("Z")
    v = v.rstrip("Z")
    if "VALUE=DATE" in raw_line or (len(v) == 8 and v.isdigit()):
        return ""
    for fmt in ("%Y%m%dT%H%M%S", "%Y%m%dT%H%M"):
        try:
            dt = datetime.strptime(v, fmt)
            if is_utc:
                dt = dt.replace(tzinfo=UTC).astimezone(LOCAL_TZ)
            return dt.strftime("%H:%M")
        except ValueError:
            continue
    return ""


def self_declined(lines: list) -> bool:
    """Check if the calendar owner declined this event."""
    for line in lines:
        if not line.upper().startswith("ATTENDEE"):
            continue
        m = re.search(r"mailto:([^@]+)@", line, re.IGNORECASE)
        if m and m.group(1).lower() == SELF and "PARTSTAT=DECLINED" in line.upper():
            return True
    return False


def attendee_usernames(lines: list) -> list:
    """Return sorted list of usernames (before @) for non-self, non-resource attendees."""
    usernames = []
    for line in lines:
        if not line.upper().startswith("ATTENDEE"):
            continue
        if "CUTYPE=RESOURCE" in line.upper():
            continue
        m = re.search(r"mailto:([^@]+)@", line, re.IGNORECASE)
        if not m:
            continue
        username = m.group(1).lower()
        if username == SELF:
            continue
        usernames.append(username)
    return usernames


def fetch_events() -> list:
    with urllib.request.urlopen(ICS_URL, timeout=15) as resp:
        raw = resp.read().decode("utf-8", errors="replace")

    content = unfold(raw)
    events = []

    for block in re.findall(r"BEGIN:VEVENT\r?\n(.*?)END:VEVENT", content, re.DOTALL):
        lines = [ln.rstrip("\r") for ln in block.split("\n") if ln.strip()]

        # Skip cancelled or declined events
        if get_prop(lines, "STATUS").upper() == "CANCELLED":
            continue
        if self_declined(lines):
            continue

        dtstart_raw = next((l for l in lines if l.upper().startswith("DTSTART")), "")
        dtend_raw = next((l for l in lines if l.upper().startswith("DTEND")), "")
        dtstart_val = prop_value(dtstart_raw)
        dtend_val = prop_value(dtend_raw)

        start_date = parse_date(dtstart_val, dtstart_raw)
        if not start_date:
            continue

        events.append({
            "date": start_date,
            "start_time": parse_time(dtstart_val, dtstart_raw),
            "end_time": parse_time(dtend_val, dtend_raw),
            "summary": get_prop(lines, "SUMMARY").strip(),
            "attendees": attendee_usernames(lines),
        })

    return sorted(events, key=lambda e: (e["date"], e["start_time"] or ""))


def main():
    today = date.today()
    cutoff = today + timedelta(days=DAYS)

    try:
        events = fetch_events()
    except Exception as exc:
        print(f"[fetch-calendar] ERROR: {exc}")
        return

    upcoming = [e for e in events if today <= e["date"] < cutoff]

    by_date: dict = {}
    for e in upcoming:
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

    if not upcoming:
        out.append("*No events in next 14 days.*")
    else:
        for d in sorted(by_date):
            out.append(f"## {d.strftime('%a %d %b')}")
            for e in by_date[d]:
                if e["start_time"] and e["end_time"]:
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
                out.append(f"- {t} **{e['summary']}**{members}")
            out.append("")

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text("\n".join(out), encoding="utf-8")
    print(f"[fetch-calendar] written → {OUTPUT.relative_to(VAULT_DIR)}")


if __name__ == "__main__":
    main()
