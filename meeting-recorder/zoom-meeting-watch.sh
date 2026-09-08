#!/bin/bash
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
MAX_REC_HOURS="${MEETING_REC_MAX_HOURS:-4}"     # предохранитель: одна запись не длиннее N часов → стоп+новый сегмент
mkdir -p "$STATE"

meeting() { pgrep -x "$ZOOM_PROC" >/dev/null 2>&1; }   # идёт десктопная Zoom-встреча
manual()  { [[ -e "$STATE/manual-on" ]]; }             # стоит ручной флаг (⌃⌥⌘R)
desired() { meeting || manual; }
# recording() — INLINE (не спавним record-meeting.sh status каждый тик, только читаем
# pid-файлы + kill -0). Спавним record-meeting.sh лишь на ПЕРЕХОДАХ (start/stop).
# ⚠️ Пути pid-файлов ДОЛЖНЫ зеркалить ATPID/FFPID в record-meeting.sh (со-клок, один процесс
# audiotee + ffmpeg). Раньше тут были mic.pid/sys.pid (двухпроцессная схема) — при переходе
# на со-клок это ломало детект: recording() всегда false → start каждый тик + stop не звался.
alive()     { [[ -n "${1:-}" ]] && kill -0 "$1" 2>/dev/null; }
recording() { alive "$(cat "$STATE/audiotee.pid" 2>/dev/null)" || alive "$(cat "$STATE/ffmpeg.pid" 2>/dev/null)"; }

# --- привод состояния + ротация ------------------------------------------------
# База (как раньше): desired && !recording → start ; !desired && recording → stop.
# Плюс две причины РОТАЦИИ (стоп + сразу новый сегмент) при desired && recording:
#   • предохранитель по длительности: запись старше MAX_REC_HOURS → рвём. Ловит ЛЮБУЮ
#     причину зависания (забытый manual-on, зомби-CptHost, стык встреч) — файл физически
#     не растёт больше порога. Это и есть фикс корневой причины 21-часового блоба.
#   • начался Zoom: запись стартовала без встречи (rec-had-meeting=0), а сейчас CptHost есть
#     → закрываем ручной кусок, Zoom-встречу пишем отдельным файлом.
# Метаданные (started-at, rec-had-meeting) пишет record-meeting.sh на старте; если их нет
# (запись жила до этого апдейта) — инициализируем БЕЗ ротации, чтобы не резать живой файл.
rotate_reason() {
  local started had now age
  started="$(cat "$STATE/started-at" 2>/dev/null || true)"
  had="$(cat "$STATE/rec-had-meeting" 2>/dev/null || true)"
  if [[ -z "$started" ]]; then date +%s > "$STATE/started-at"; return 1; fi
  if [[ -z "$had" ]]; then meeting && echo 1 > "$STATE/rec-had-meeting" || echo 0 > "$STATE/rec-had-meeting"; return 1; fi
  now="$(date +%s)"; age=$(( now - started ))
  (( age > MAX_REC_HOURS*3600 )) && { echo "cap ${age}s > ${MAX_REC_HOURS}h"; return 0; }
  [[ "$had" == 0 ]] && meeting && { echo "zoom-start"; return 0; }
  return 1
}

if desired; then
  if recording; then
    if reason="$(rotate_reason)"; then
      echo "=== $(date '+%F %T') rotate ($reason) → stop+start" >>"$LOG"
      # человекочитаемая причина стопа для уведомления
      case "$reason" in cap*) sr="4h limit" ;; zoom-start) sr="Zoom started" ;; *) sr="rotate" ;; esac
      "$REC" stop  "$sr" >>"$LOG" 2>&1
      "$REC" start >>"$LOG" 2>&1
    fi
  else
    "$REC" start >>"$LOG" 2>&1
  fi
else
  if recording; then
    # причина: если запись была Zoom-встречей (had_meeting=1) — «Zoom ended», иначе снят ручной флаг
    [[ "$(cat "$STATE/rec-had-meeting" 2>/dev/null || echo 0)" == 1 ]] && sr="Zoom ended" || sr="manual off"
    "$REC" stop "$sr" >>"$LOG" 2>&1
  fi
fi
