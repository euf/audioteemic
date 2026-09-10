#!/bin/bash
# record-meeting.sh start|stop|toggle|manual-toggle|status — запись созвона как СТРАХОВКА Fellow.
# free/OSS. Результат — НЕ источник для вики: файлы лежат ВНЕ vault'а, не сканируются
# ingest'ом, whisper автоматом НЕ запускается. Путь в вики — ручной реаплоад в Fellow.
#
# АРХИТЕКТУРА (переписано 12.07 — ОДНОПРОЦЕССНЫЙ со-клок захват): один `audiotee --mic`
# кладёт встроенный микрофон и системный тап в ОДНО приватное агрегатное устройство
# (микрофон = мастер-клок, тап следует за ним) и отдаёт готовый стерео-поток
# [L=микрофон, R=система] f32le@48k в ffmpeg → сразу m4a. На стопе — только переименование.
#
# Почему так (замена прежней схемы «два раздельных рекордера + офлайн-мерж»): те два
# рекордера шли на НЕЗАВИСИМЫХ клоках, и их склейка от нулевого сэмпла копила дрейф —
# замерено до ~4.8с расхождения L/R за 72-мин звонок, плюс ступеньки от сбоев буфера.
# Один агрегат = один клок: оба потока приходят в одном IOProc-колбэке с равным числом
# кадров, поэтому кадр L[i] всегда спарен с R[i] — дрейф исключён по построению
# (провалидировано: frame_delta=0 за 89с, scripts/record/coclock-accept.sh).
#   • L = встроенный микрофон (не отключается → голос не рвётся при свапе AirPods).
#   • R = системный звук (собеседники), тап следует за устройством вывода (AirPods/колонки).
# Разделить постфактум: ffmpeg -i f.m4a -map_channel 0.0.0 you.wav -map_channel 0.0.1 others.wav
#
# ⚠️ Бинарь audiotee ДОЛЖЕН быть подписан стабильной идентичностью (scripts/record/
# sign-audiotee.sh), иначе TCC-грант на запись экрана/системного звука слетает с каждой
# пересборки. Права: Микрофон + «Запись экрана и системного звука» (для launchd — самому
# бинарю по подписи; для терминала — терминал-приложению).
#
# Имя: "YYYY-MM-DD, HH-MM (Nm) <встреча из календаря>.m4a" (calendar-title.py; без совпадения —
# только дата-время-длительность). Дата-время и название фиксируются на СТАРТЕ; длительность (Nm)
# вставляется на СТОПЕ из готового файла (ffprobe — не по настенным часам, см. do_stop).
#
# Триггер: launchd (zoom-meeting-watch.sh, десктопный Zoom) или ручной ⌃⌥⌘R (manual-toggle).
set -uo pipefail

# PATH: launchd и Shortcuts дают МИНИМАЛЬНЫЙ PATH без /opt/homebrew/bin → ffmpeg/audiotee не
# находятся. Фиксим здесь — работает во всех контекстах.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

DIR="$(cd "$(dirname "$0")" && pwd)"
STATE="$HOME/.local/state/meeting-recorder"
ATPID="$STATE/audiotee.pid"; FFPID="$STATE/ffmpeg.pid"
CAP_TMP="$STATE/capture.m4a"     # пишем сюда во время записи, переименуем на стопе
NAMEFILE="$STATE/target-name"    # финальное имя, зафиксированное на старте
STARTED="$STATE/started-at"      # epoch старта записи — watcher считает возраст для предохранителя
HADMEET="$STATE/rec-had-meeting" # был ли Zoom (CptHost) на старте: 0/1 — watcher ротирует на переходе 0→meeting
TSFILE="$STATE/target-ts"        # префикс имени "YYYY-MM-DD, HH-MM" (без (Nm)/title) — для вставки длительности на стопе
LOG="$STATE/latest.log"
AUDIOTEE="${MEETING_REC_AUDIOTEE:-$HOME/.local/bin/audiotee}"
# Уведомления шлём через бандл с иконкой-микрофоном (иначе слева иконка Терминала). Фолбэк — обычный TN.
# Тот же отправитель, что у meeting-toggle: -group вытесняет прежнее уведомление только
# внутри одного bundle-id. Откуда берётся бандл — README, «Где что лежит».
_TN_MIC="$HOME/Library/Application Support/meeting-recorder/Recorder.app/Contents/MacOS/terminal-notifier"
[[ -x "$_TN_MIC" ]] || _TN_MIC="/opt/homebrew/bin/terminal-notifier"
TN="${MEETING_REC_NOTIFIER:-$_TN_MIC}"
MIC_NAME_OVERRIDE="${MEETING_REC_MIC:-}"   # подстрока имени входного устройства; пусто → встроенный

OUTDIR="${MEETING_REC_OUTDIR:-}"
if [[ -z "$OUTDIR" ]]; then
  ICLOUD="$HOME/Library/Mobile Documents/com~apple~CloudDocs"
  if [[ -d "$ICLOUD" ]]; then OUTDIR="$ICLOUD/Meeting Recordings"; else OUTDIR="$HOME/Recordings/meeting-backups"; fi
fi
mkdir -p "$OUTDIR" "$STATE"

# notify title subtitle message [execute]. -group: новое заменяет старое; фолбэк на osascript.
notify() {
  if [[ -x "$TN" ]]; then
    local a=(-title "$1" -message "${3:-}" -group meeting-recorder)
    [[ -n "${2:-}" ]] && a+=(-subtitle "$2")
    [[ -n "${4:-}" ]] && a+=(-execute "$4")
    "$TN" "${a[@]}" >/dev/null 2>&1
  else
    osascript -e "display notification \"${3:-}\" with title \"$1\"" >/dev/null 2>&1
  fi
}

# Мгновенно обновить меню-бар SwiftBar (индикатор записи 🔴 в 001-AirPodsPower), не дожидаясь его
# поллинга. Событие, а не polling — дот загорается/гаснет ровно на старте/стопе. Fire-and-forget:
# если SwiftBar не запущен/схема не зарегана — молча ничего (индикатор всё равно догонит поллингом).
swiftbar_refresh() { open "swiftbar://refreshallplugins" >/dev/null 2>&1 || true; }

alive() { [[ -n "${1:-}" ]] && kill -0 "$1" 2>/dev/null; }
is_recording() { alive "$(cat "$ATPID" 2>/dev/null)" || alive "$(cat "$FFPID" 2>/dev/null)"; }

do_start() {
  is_recording && { echo "already recording"; notify "● Уже пишется" "" "запись созвона уже идёт"; return 0; }
  if [[ ! -x "$AUDIOTEE" ]]; then
    echo "audiotee не найден ($AUDIOTEE) — см. README" | tee -a "$LOG"
    notify "⚠️ Запись НЕ пошла" "" "audiotee не установлен — см. README"; return 1
  fi
  local ts
  ts="$(date '+%Y-%m-%d, %H-%M')"   # "2026-07-14, 11-02" — (Nm) допишется на стопе, когда длительность известна
  echo "=== $(date '+%F %T') start → co-clock ($AUDIOTEE --mic) → $CAP_TMP" >>"$LOG"

  # Один поток: audiotee --mic (L=мик, R=система, залочены на одном клоке) → ffmpeg → m4a.
  # Прямой пайп; PID ffmpeg = $! (последний в пайпе), PID audiotee берём через pgrep.
  # m4a, фрагментированный (empty_moov + frag_duration) → итоговый файл стримабелен и moov
  # не в самом конце. NB: для АУДИО-без-видео ffmpeg всё равно буферизует и пишет на закрытии
  # — файл дописывается на GRACEFUL-стопе (наш путь: воркер/хоткей всегда шлёт SIGINT). Жёсткий
  # краш посреди звонка потеряет запись — приемлемо (норм. завершение всегда через stop).
  # Тап-моно не нужен: audiotee сам сводит R в 1 канал.
  local mic_args=(); [[ -n "$MIC_NAME_OVERRIDE" ]] && mic_args=(--input-name "$MIC_NAME_OVERRIDE")
  rm -f "$CAP_TMP"
  "$AUDIOTEE" --mic ${mic_args[@]+"${mic_args[@]}"} 2>>"$LOG" \
    | ffmpeg -y -hide_banner -loglevel warning -f f32le -ar 48000 -ac 2 -i pipe:0 \
        -c:a aac -b:a 128k -movflags +frag_keyframe+empty_moov -frag_duration 5000000 "$CAP_TMP" >>"$LOG" 2>&1 &
  echo $! > "$FFPID"                                   # последний в пайпе = ffmpeg
  sleep 0.3
  pgrep -n -f 'audiotee --mic' > "$ATPID" 2>/dev/null || true

  sleep 1                      # verify: audiotee жив? (упал бы если тап не всплыл / нет прав)
  if ! alive "$(cat "$ATPID" 2>/dev/null)"; then
    do_cleanup_procs
    echo "FAILED — хвост лога:" >&2; tail -n 8 "$LOG" >&2
    notify "⚠️ Запись НЕ пошла" "" "audiotee упал — права на запись системного звука? см. latest.log"; return 1
  fi
  # метаданные записи для watcher-ротации: возраст (предохранитель) + был ли Zoom на старте
  # (переход 0→meeting = ротация «начался Zoom»). Пишем ПОСЛЕ verify — только для реально живой записи.
  date +%s > "$STARTED"
  local start_reason
  if pgrep -x "${MEETING_REC_ZOOM_PROC:-CptHost}" >/dev/null 2>&1; then echo 1 > "$HADMEET"; start_reason="Zoom"; else echo 0 > "$HADMEET"; start_reason="manual"; fi
  notify "🔴 Recording" "" "$(date '+%Y-%m-%d, %H:%M') — $start_reason"
  swiftbar_refresh   # зажечь 🔴 в меню-баре сразу
  # имя: провизорное (дата-время) сразу; календарь резолвим В ФОНЕ и дописываем название.
  # ts сохраняем отдельно — на стопе по нему вставим "(Nm)" между временем и названием.
  printf '%s\n' "$ts" > "$TSFILE"
  printf '%s\n' "$OUTDIR/${ts}.m4a" > "$NAMEFILE"
  # stderr в лог, а не в /dev/null: пустое название — штатный исход (нет встречи), но и
  # признак поломки (см. 07.09.2026, сломанный venv), различить их можно только по причине.
  ( t="$(/usr/bin/python3 "$DIR/calendar-title.py" 2>>"$LOG" || true)"
    if [[ -n "$t" ]]; then printf '%s\n' "$OUTDIR/${ts} ${t}.m4a" > "$NAMEFILE"
    else echo "$(date '+%F %T') calendar-title: название не определено" >>"$LOG"; fi ) &
  echo "recording (co-clock mic+sys → $CAP_TMP)"
}

do_cleanup_procs() {
  rm -f "$ATPID" "$FFPID" "$STARTED" "$HADMEET"
}

do_stop() {
  local reason="${1:-manual}"   # причина стопа для уведомления (передаёт watcher: Zoom ended / manual off / 4h limit / Zoom started)
  local at ff target
  at="$(cat "$ATPID" 2>/dev/null)"; ff="$(cat "$FFPID" 2>/dev/null)"
  # SIGINT audiotee → закрывает stdout → ffmpeg видит EOF и финализирует m4a.
  if alive "$at"; then kill -INT "$at" 2>/dev/null; else pkill -INT -f 'audiotee --mic' 2>/dev/null; fi
  for _ in 1 2 3 4 5 6; do alive "$at" || break; sleep 0.5; done
  alive "$at" && kill -9 "$at" 2>/dev/null
  pkill -9 -f 'audiotee --mic' 2>/dev/null || true      # добить наш процесс, если завис
  # ждём, пока ffmpeg допишет moov и выйдет; иначе принудительно.
  for _ in 1 2 3 4 5 6 7 8; do alive "$ff" || break; sleep 0.5; done
  alive "$ff" && kill -INT "$ff" 2>/dev/null
  do_cleanup_procs

  local ts_saved; ts_saved="$(cat "$TSFILE" 2>/dev/null || true)"; rm -f "$TSFILE"
  target="$(cat "$NAMEFILE" 2>/dev/null)"; rm -f "$NAMEFILE"
  [[ -z "$target" ]] && target="$OUTDIR/$(date +'%Y-%m-%d, %H-%M').m4a"
  if [[ -s "$CAP_TMP" ]]; then
    # Вставляем реальную длительность "(Nm)" между временем и названием. Берём из ГОТОВОГО файла
    # (ffprobe), а не по настенным часам: audiotee гонит сэмплы только при активном аудио, поэтому
    # wall-clock может быть длиннее реальной записи (см. историю 43ч настенных / 21ч звука).
    local dur_s mins dir stem rest
    dur_s="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$CAP_TMP" 2>/dev/null || true)"
    if [[ -n "$dur_s" ]]; then
      mins="$(awk -v s="$dur_s" 'BEGIN{m=int((s+30)/60); if(m<1)m=1; print m}')"
      dir="$(dirname "$target")"; stem="$(basename "$target" .m4a)"
      if [[ -n "$ts_saved" && "$stem" == "$ts_saved"* ]]; then
        rest="${stem#"$ts_saved"}"                        # "" или " Название встречи"
        target="$dir/${ts_saved} (${mins}m)${rest}.m4a"   # 2026-07-14, 11-02 (56m) EF × a.lvov.m4a
      else
        target="$dir/${stem} (${mins}m).m4a"              # фолбэк (ts не совпал) — дописать в конец
      fi
    fi
    mv -f "$CAP_TMP" "$target"
  else
    echo "STOP: пустой $CAP_TMP — записи нет (хвост лога ниже)" | tee -a "$LOG" >&2; tail -n 6 "$LOG" >&2
  fi
  echo "stopped → $target"
  # уведомление: title = "⏹️ <причина>", subtitle = "дата-время (Nm)", message = название файла.
  local nbase nprefix nname
  nbase="$(basename "$target")"
  nprefix="$ts_saved (${mins:-}m) "                                  # "2026-07-17, 14-30 (56m) "
  nname="${nbase#"$nprefix"}"; [[ "$nname" == "$nbase" ]] && nname="" # префикс не совпал (нет ts/названия) → без строки
  notify "⏹️ ${reason}" "${ts_saved:-$(date '+%Y-%m-%d, %H-%M')} (${mins:-?}m)" "$nname" "open -R \"$target\""
  swiftbar_refresh   # погасить 🔴 в меню-баре сразу
}

case "${1:-}" in
  start)  do_start ;;
  stop)   do_stop "${2:-}" ;;
  toggle) if is_recording; then do_stop; else do_start; fi ;;   # для терминала (не для хоткея!)
  # manual-toggle — для хоткея ⌃⌥⌘R: НЕ держит фоновый процесс (Shortcuts убивает таких
  # детей). Только флипает флаг manual-on + дёргает воркер; сам захват запускает воркер в
  # персистентном launchd-контексте (AbandonProcessGroup) → переживает завершение хоткея.
  manual-toggle)
    if [[ -e "$STATE/manual-on" ]]; then rm -f "$STATE/manual-on"; echo "manual OFF (запись остановится на ближайшем тике)";
    else : > "$STATE/manual-on"; echo "manual ON (запись стартует на ближайшем тике)"; fi
    launchctl kickstart "gui/$(id -u)/com.eugene.zoom-recorder" >/dev/null 2>&1 || true
    ;;
  status) is_recording && echo "recording" || echo "idle" ;;
  *) echo "usage: $0 start|stop|toggle|manual-toggle|status"; exit 2 ;;
esac
