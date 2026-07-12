#!/usr/bin/env bash
# zoom-meeting-watch.sh — владелец записи созвона (launchd StartInterval ~5с, БЕЗ Hammerspoon).
#
# Модель «желаемое состояние» (переписано 10.07): каждый тик считает
#   desired = (идёт десктопная Zoom-встреча)  ИЛИ  (стоит ручной флаг manual-on)
# и приводит запись к нему: desired && !recording → start; !desired && recording → stop.
#   • Zoom-встреча = pgrep CptHost (процесс встречи; без Accessibility/AppleScript).
#   • manual-on = флаг от хоткея ⌃⌥⌘R (record-meeting.sh manual-toggle флипает + kickstart).
# ВАЖНО: запись стартует ИМЕННО ЗДЕСЬ (в launchd-контексте с AbandonProcessGroup=true в
# плисте) → фоновый ffmpeg переживает завершение тика. Хоткей сам ffmpeg НЕ запускает
# (Shortcuts убивает фоновых детей) — только дёргает флаг. Уведомления шлёт record-meeting.sh.
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"  # launchd даёт минимальный PATH
DIR="$(cd "$(dirname "$0")" && pwd)"
REC="$DIR/record-meeting.sh"
STATE="$HOME/.local/state/meeting-recorder"
LOG="$STATE/latest.log"
ZOOM_PROC="${MEETING_REC_ZOOM_PROC:-CptHost}"   # имя процесса встречи (проверить: pgrep -fl zoom)
mkdir -p "$STATE"

desired() { pgrep -x "$ZOOM_PROC" >/dev/null 2>&1 || [[ -e "$STATE/manual-on" ]]; }
# recording() — INLINE (не спавним record-meeting.sh status каждый тик, только читаем
# pid-файлы + kill -0). Спавним record-meeting.sh лишь на ПЕРЕХОДАХ (start/stop).
# ⚠️ Пути pid-файлов ДОЛЖНЫ зеркалить ATPID/FFPID в record-meeting.sh (со-клок, один процесс
# audiotee + ffmpeg). Раньше тут были mic.pid/sys.pid (двухпроцессная схема) — при переходе
# на со-клок это ломало детект: recording() всегда false → start каждый тик + stop не звался.
alive()     { [[ -n "${1:-}" ]] && kill -0 "$1" 2>/dev/null; }
recording() { alive "$(cat "$STATE/audiotee.pid" 2>/dev/null)" || alive "$(cat "$STATE/ffmpeg.pid" 2>/dev/null)"; }

if desired; then
  recording || "$REC" start >>"$LOG" 2>&1
else
  recording && "$REC" stop >>"$LOG" 2>&1
fi
