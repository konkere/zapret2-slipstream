#!/bin/sh
# zapret2-slipstream.sh — автоподбор рабочей стратегии zapret2 через blockcheck2.
# Прогон 1: blockcheck TLS1.3 — обрыв после WANT_TLS рабочих или по таймауту.
# Прогон 2: blockcheck TLS1.2 — обрыв после WANT_TLS рабочих или по таймауту.
# Прогон 3: blockcheck QUIC   — обрыв после WANT_QUIC рабочих или по таймауту.
#
# Выбор TLS-стратегии (профиль в nfqws2 один, 1.2/1.3 не делятся фильтром):
#   1) ОБЩАЯ — работает и для 1.3, и для 1.2 (приоритет, максимум стабильности)
#   2) иначе первая рабочая 1.3
#   3) иначе первая рабочая 1.2
# Собирает NFQWS2_OPT, вносит в конфиг (с бэкапом), рестартит zapret2,
# шлёт уведомления в Telegram через SOCKS5. Запас и статус 1.2 — в телеграм.
#
# Запуск:
#   sudo ./zapret2-slipstream.sh                    # вывод в терминал
#   sudo ./zapret2-slipstream.sh --dry              # показать, не вносить
#   sudo ./zapret2-slipstream.sh --cron             # тихо в лог-файл + телеграм
#   sudo ./zapret2-slipstream.sh --want-tls 20      # собрать 20 рабочих TLS (шанс общей выше)
#   sudo ./zapret2-slipstream.sh --want-tls 0       # полный перебор TLS (может быть ОЧЕНЬ долго!)
#   sudo ./zapret2-slipstream.sh --timeout-tls 600  # ограничить TLS-прогон 10 мин
#   sudo ./zapret2-slipstream.sh --timeout-quic 300 # ограничить QUIC-прогон 5 мин
# Дефолты: WANT_TLS=3, таймаут 5 мин на каждый прогон (безопасно и быстро).
#
# crontab:
#   30 5 * * * /opt/zapret2/zapret2-slipstream.sh --cron >/dev/null 2>&1

set -u

# ============ НАСТРОЙКИ ============
# Значения ниже — ДЕФОЛТЫ. Переопределяются из /etc/zapret2-slipstream/.env
# (и из файла, указанного через --env ПОВЕРХ дефолтного). Лимиты (WANT_*/TIMEOUT_*)
# в .env не выносятся — они управляются флагами командной строки.

# --- выносятся в .env ---
ZAPRET_DIR="/opt/zapret2"
SERVICE="zapret2"
DOMAINS="www.youtube.com"
LOGFILE="/var/log/zapret2-slipstream.log"
BOT_ID=""              # токен Telegram-бота (пусто = уведомления выключены)
CHAT_ID=""             # id чата
SOCKS5=""              # socks5 для Telegram (host:port или user:pass@host:port)

# --- НЕ выносятся (управляются флагами) ---
WANT_QUIC=3            # сколько рабочих QUIC собирать до обрыва
WANT_TLS=3             # сколько рабочих TLS собирать до обрыва (0 = полный перебор).
                       # По умолчанию 3 — быстро и безопасно. Для поиска ОБЩЕЙ 1.2/1.3
                       # можно поднять (--want-tls 20), но перебор станет длиннее.
POLL_SEC=3
TIMEOUT_TLS=300        # TLS: 5 мин на каждый прогон (1.3 и 1.2 отдельно)
TIMEOUT_QUIC=300       # QUIC: 5 мин

# Уровень перебора blockcheck (передаётся как SCANLEVEL):
#   quick    — обрывать после первой же неудачи (самый поверхностный);
#   standard — обычное «исследование» DPI (дефолт blockcheck, перебор НЕПОЛНЫЙ);
#   force    — перебрать МАКСИМУМ стратегий (нужен для надёжного поиска ОБЩЕЙ 1.2+1.3,
#              но заметно дольше — сам blockcheck рекомендует force для intersection).
# Переопределяется параметром --scan-level.
SCANLEVEL=standard

# Путь к дефолтному env-файлу (переопределяется переменной AUTOSTRAT_ENV=... перед запуском).
DEFAULT_ENV="${AUTOSTRAT_ENV:-/etc/zapret2-slipstream/.env}"
# ============ КОНЕЦ НАСТРОЕК ============

# читает env-файл, переопределяя разрешённые переменные. $1 = путь к файлу.
load_env() {
  _envf="$1"
  [ -f "$_envf" ] || return 1
  while IFS= read -r _line; do
    case "$_line" in
      BOT_ID=*|CHAT_ID=*|SOCKS5=*|ZAPRET_DIR=*|SERVICE=*|DOMAINS=*|LOGFILE=*)
        _key=${_line%%=*}
        _val=${_line#*=}
        # снять обрамляющие кавычки, если есть
        _val=$(printf '%s' "$_val" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//")
        eval "$_key=\$_val"
        ;;
    esac
  done < "$_envf"
  return 0
}

# создаёт дефолтный env-файл с текущими дефолтами (вызывается, если файла нет). $1 = путь.
create_default_env() {
  _envf="$1"
  _dir=$(dirname "$_envf")
  mkdir -p "$_dir" 2>/dev/null || return 1
  cat > "$_envf" <<ENVEOF
# Настройки zapret2-slipstream. Переменные VAR="значение".
# Строки-комментарии (начинаются с #) и пустые — игнорируются.
# Inline-комментарии после значения НЕ поддерживаются (пиши коммент отдельной строкой).

# --- Telegram (пусто = уведомления выключены) ---
BOT_ID=""
CHAT_ID=""
# SOCKS5 для отправки в Telegram (host:port или user:pass@host:port).
# Нужен, если Telegram у провайдера заблокирован: укажите прокси, через который он доступен.
# Если Telegram открывается напрямую — оставьте пустым.
SOCKS5=""

# --- пути и цель ---
ZAPRET_DIR="$ZAPRET_DIR"
SERVICE="$SERVICE"
DOMAINS="$DOMAINS"
LOGFILE="$LOGFILE"
ENVEOF
  chmod 600 "$_envf" 2>/dev/null
  return 0
}

HTTP_FILTER="--filter-tcp=80 --filter-l7=http"
HTTP_PAYLOAD="--payload=http_req"
TLS_FILTER="--filter-tcp=443 --filter-l7=tls"
TLS_PAYLOAD="--payload=tls_client_hello"
QUIC_FILTER="--filter-udp=443 --filter-l7=quic"
QUIC_PAYLOAD="--payload=quic_initial"

usage() {
  cat <<'USAGE'
zapret2-slipstream.sh — автоподбор рабочей стратегии zapret2 через blockcheck2.

Гоняет blockcheck по трём протоколам (TLS1.3, TLS1.2, QUIC), выбирает рабочие
стратегии, для TLS предпочитает ОБЩУЮ (работает и для 1.2, и для 1.3), собирает
NFQWS2_OPT, вносит в конфиг (с бэкапом) и перезапускает zapret2.
Уведомления — в Telegram через SOCKS5 (настройки в /etc/zapret2-slipstream/.env).

ИСПОЛЬЗОВАНИЕ:
  sudo zapret2-slipstream.sh [ПАРАМЕТРЫ]

ПАРАМЕТРЫ:
  --dry                 Только показать найденный NFQWS2_OPT, НЕ вносить в конфиг
                        и не перезапускать сервис. Безопасный тестовый режим.

  --cron                Тихий режим для crontab: вывод в лог-файл
                        (/var/log/zapret2-slipstream.log), без интерактива.
                        Статус приходит в Telegram.

  --want-tls N          Сколько рабочих TLS-стратегий собрать до обрыва прогона.
                        N=0 — полный перебор (может быть ОЧЕНЬ долго при мягком DPI:
                        сотни стратегий, десятки минут). Чем больше N, тем выше шанс
                        найти ОБЩУЮ для 1.2+1.3. По умолчанию: 3.

  --want-quic N         Сколько рабочих QUIC-стратегий собрать до обрыва прогона.
                        N=1 — оборвать на первой же найденной (самый быстрый прогон).
                        N=0 — полный перебор. По умолчанию: 3.

  --timeout-tls СЕК     Таймаут на КАЖДЫЙ TLS-прогон (1.3 и 1.2 отдельно), секунды.
                        0 — без таймаута (ждать до конца перебора). По умолчанию: 300.

  --timeout-quic СЕК    Таймаут на QUIC-прогон, секунды. 0 — без таймаута.
                        По умолчанию: 300.

  --scan-level УРОВЕНЬ   Глубина перебора blockcheck: quick | standard | force.
                        quick    — рвать после первой неудачи (поверхностно);
                        standard — обычный перебор (дефолт, но НЕПОЛНЫЙ);
                        force    — перебрать максимум стратегий (нужен для надёжного
                                   поиска ОБЩЕЙ 1.2+1.3, но дольше). По умолчанию: standard.

  --env ПУТЬ            Прочитать дополнительный env-файл ПОВЕРХ дефолтного
                        (/etc/zapret2-slipstream/.env). Переопределяет совпадающие
                        переменные. Если файла по ПУТИ нет — он будет создан с дефолтами.

  --no-tg               Не слать уведомления в Telegram (для этого запуска).
                        Удобно с --dry: частые тестовые прогоны без спама в чат.

  -h, --help            Показать эту справку и выйти.

НАСТРОЙКИ (env-файл):
  Дефолтный: /etc/zapret2-slipstream/.env — СОЗДАЁТСЯ автоматически при первом
  запуске, если его нет. Переопределить путь: AUTOSTRAT_ENV=... перед запуском.
  Порядок применения: дефолты в скрипте → дефолтный .env → файл из --env.
  Выносимые в .env переменные:
      BOT_ID, CHAT_ID, SOCKS5   — Telegram (пусто = уведомления выключены)
      ZAPRET_DIR                — каталог zapret2 (по умолч. /opt/zapret2)
      SERVICE                   — имя systemd-сервиса (по умолч. zapret2)
      DOMAINS                   — домен(ы) для blockcheck (по умолч. www.youtube.com)
      LOGFILE                   — лог для --cron
  Лимиты (WANT_*/TIMEOUT_*) в .env НЕ выносятся — управляются флагами выше.
  Формат: VAR="значение". Комментарии — отдельной строкой (# ...), НЕ в конце строки.
  SOCKS5 нужен, если Telegram у провайдера заблокирован (прокси, через который он доступен).

ПРИМЕРЫ:
  sudo zapret2-slipstream.sh                       # дефолт: 3 находки, 5 мин/прогон
  sudo zapret2-slipstream.sh --dry                 # проверить, не трогая конфиг
  sudo zapret2-slipstream.sh --dry --no-tg         # тихий тест: без уведомлений в Telegram
  sudo zapret2-slipstream.sh --want-tls 20         # больше находок → выше шанс общей
  sudo zapret2-slipstream.sh --want-tls 1 --want-quic 1   # самый быстрый: первые найденные
  sudo zapret2-slipstream.sh --want-tls 0 --timeout-tls 900   # полный перебор, но не дольше 15 мин
  sudo zapret2-slipstream.sh --scan-level force --want-tls 0 --want-quic 0  # макс. перебор (долго!)
  sudo zapret2-slipstream.sh --env /home/user/my.env          # доп. настройки поверх дефолтных
  sudo zapret2-slipstream.sh --cron                # для crontab

ПОВЕДЕНИЕ ПРИ РАЗНЫХ РЕЗУЛЬТАТАХ:
  • нашлись обе (TLS+QUIC)      — собирает и применяет новый конфиг
  • нашлась только одна         — для второй берёт ПРЕЖНЮЮ из .current-strat
  • оба протокола идут «напрямую»  — конфиг НЕ трогает (блокировка временно снята)
  • ничего не найдено           — конфиг НЕ трогает, прежняя стратегия сохранена

Прерывание (Ctrl+C) безопасно: конфиг не изменяется, zapret2 поднимается обратно.
USAGE
}

# --help / -h обрабатываем ДО любых действий (не запускаем blockcheck, не трогаем сервис,
# не создаём env-файл)
for a in "$@"; do
  case "$a" in
    -h|--help) usage; exit 0 ;;
  esac
done

# --- работа с env (ПОСЛЕ --help, чтобы справка не создавала файлов) ---
# ранний парсинг --env (нужно прочитать env ДО остальной логики)
EXTRA_ENV=""
_prev=""
for a in "$@"; do
  if [ "$_prev" = "--env" ]; then EXTRA_ENV="$a"; _prev=""; continue; fi
  [ "$a" = "--env" ] && _prev="--env"
done

# 1) дефолтный env: если нет — создаём (только для дефолтного пути), потом читаем
if [ ! -f "$DEFAULT_ENV" ]; then
  if create_default_env "$DEFAULT_ENV"; then
    echo ">>> Создан дефолтный env-файл: $DEFAULT_ENV (заполни BOT_ID/CHAT_ID/SOCKS5 при желании)"
  fi
fi
load_env "$DEFAULT_ENV"

# 2) --env поверх дефолтного (переопределяет). Если указан, но файла нет — создаём и его.
if [ -n "$EXTRA_ENV" ]; then
  if [ ! -f "$EXTRA_ENV" ]; then
    if create_default_env "$EXTRA_ENV"; then
      echo ">>> Создан env-файл по --env: $EXTRA_ENV"
    fi
  fi
  load_env "$EXTRA_ENV" && echo ">>> Применён доп. env: $EXTRA_ENV"
fi

# CONFIG/BLOCKCHECK зависят от ZAPRET_DIR — вычисляем ПОСЛЕ чтения env
CONFIG="$ZAPRET_DIR/config"
BLOCKCHECK="$ZAPRET_DIR/blockcheck2.sh"

DRY=0; CRON=0; NO_TG=0
_prev=""
for a in "$@"; do
  case "$_prev" in
    --timeout-tls)  TIMEOUT_TLS="$a";  _prev=""; continue ;;
    --timeout-quic) TIMEOUT_QUIC="$a"; _prev=""; continue ;;
    --want-tls)     WANT_TLS="$a";     _prev=""; continue ;;
    --want-quic)    WANT_QUIC="$a";    _prev=""; continue ;;
    --scan-level)
      case "$a" in
        quick|standard|force) SCANLEVEL="$a" ;;
        *) echo "!!! --scan-level: допустимо quick|standard|force (получено: $a)" >&2; exit 2 ;;
      esac
      _prev=""; continue ;;
    --env)          _prev=""; continue ;;  # значение уже прочитано ранним парсером
  esac
  case "$a" in
    --dry)   DRY=1 ;;
    --cron)  CRON=1 ;;
    --no-tg) NO_TG=1 ;;
    --timeout-tls|--timeout-quic|--want-tls|--want-quic|--scan-level|--env) _prev="$a" ;;
  esac
done

START_TS=$(date +%s)
if [ "$CRON" = "1" ]; then
  exec >>"$LOGFILE" 2>&1
  echo "================ $(date '+%Y-%m-%d %H:%M:%S') cron run ================"
fi

say() { echo "$@"; }
elapsed() { e=$(date +%s); d=$((e-START_TS)); printf '%dм %dс' $((d/60)) $((d%60)); }

tg_enabled() { [ "$NO_TG" != "1" ] && [ -n "$BOT_ID" ] && [ -n "$CHAT_ID" ]; }
tg_send() {
  tg_enabled || return 0
  msg="$1"; socks_opt=""
  [ -n "$SOCKS5" ] && socks_opt="--socks5-hostname $SOCKS5"
  # shellcheck disable=SC2086
  curl -s --max-time 25 $socks_opt \
    "https://api.telegram.org/bot$BOT_ID/sendMessage" \
    --data-urlencode "chat_id=$CHAT_ID" \
    --data-urlencode "parse_mode=HTML" \
    --data-urlencode "disable_web_page_preview=true" \
    --data-urlencode "text=$msg" >/dev/null 2>&1 \
    || say "!!! Telegram: отправка не удалась (проверь SOCKS5/токен)."
}
htmlesc() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

[ "$(id -u)" = "0" ] || { say "Нужен root (sudo)." >&2; exit 1; }
[ -x "$BLOCKCHECK" ] || { say "Не найден $BLOCKCHECK" >&2; exit 1; }
[ -f "$CONFIG" ]     || { say "Не найден $CONFIG" >&2; exit 1; }

TMP="$(mktemp -d)"
BC_PID=""
kill_blockcheck() {
  [ -n "$BC_PID" ] && kill "$BC_PID" 2>/dev/null
  [ -n "$BC_PID" ] && pkill -P "$BC_PID" 2>/dev/null
  BC_PID=""
}
cleanup() { rm -rf "$TMP"; }
on_interrupt() {
  say ""
  say "!!! Прервано пользователем. Конфиг не изменён, поднимаю $SERVICE."
  kill_blockcheck
  systemctl start "$SERVICE" >/dev/null 2>&1
  cleanup
  tg_send "🟠 <b>zapret2-slipstream — прервано</b>
Поиск остановлен вручную. Конфиг не тронут, <code>$SERVICE</code> запущен.
<b>Время:</b> $(elapsed)"
  exit 130
}
trap on_interrupt INT TERM
trap cleanup EXIT

# извлечь рабочие стратегии (строки nfqws2, у которых следующая строка — AVAILABLE)
avail_lines() {  # $1=tag  $2=logfile
  # Парсер вердиктов blockcheck.
  # ВАЖНО: "UNAVAILABLE" содержит подстроку "AVAILABLE", поэтому UNAVAILABLE
  # проверяется ПЕРВЫМ, а успех матчится по полному маркеру "!!!!! AVAILABLE !!!!!".
  # Кандидат = последняя строка nfqws2 с нужным тегом; печатается при успехе.
  awk -v tag="$1" '
    /nfqws2 / && $0 ~ tag { cand=$0; next }
    /UNAVAILABLE/ { cand=""; next }
    /!!!!! AVAILABLE !!!!!/ { if (cand!="") { print cand; cand="" } ; next }
  ' "$2"
}

# Запускает blockcheck для одного протокола, следит за логом, обрывает после WANT рабочих.
# $1 = "tls" | "quic"
# пишет результат в глобальные: RUN_LOG, RUN_TAG, RUN_NOBP, RUN_TIMED_OUT
run_protocol() {
  proto="$1"
  RUN_LOG="$TMP/bc-$proto.log"
  RUN_TIMED_OUT=0
  RUN_NOBP=0
  if [ "$proto" = "tls13" ]; then
    RUN_TAG="curl_test_https_tls13"
    EN_TLS12=0; EN_TLS13=1; EN_HTTP3=0
    CT_TLS12=0; CT_TLS13=1; CT_QUIC=0
  elif [ "$proto" = "tls12" ]; then
    RUN_TAG="curl_test_https_tls12"
    EN_TLS12=1; EN_TLS13=0; EN_HTTP3=0
    CT_TLS12=1; CT_TLS13=0; CT_QUIC=0
  else
    RUN_TAG="curl_test_http3"
    EN_TLS12=0; EN_TLS13=0; EN_HTTP3=1
    CT_TLS12=0; CT_TLS13=0; CT_QUIC=1
  fi

  # режим остановки: QUIC обрывается после WANT_QUIC; TLS — после WANT_TLS (0 = до конца).
  case "$proto" in
    quic) _want="$WANT_QUIC"; _tmo="$TIMEOUT_QUIC" ;;
    *)    _want="$WANT_TLS";  _tmo="$TIMEOUT_TLS"   ;;  # tls*: 0 → без обрыва по числу
  esac

  if [ "$_want" -gt 0 ]; then
    say ">>> Прогон [$proto]: ищу до $_want рабочих$( [ "$_tmo" -gt 0 ] && printf ' (таймаут %d мин)' $((_tmo/60)) )…"
  else
    say ">>> Прогон [$proto]: полный перебор$( [ "$_tmo" -gt 0 ] && printf ', таймаут %d мин' $((_tmo/60)) || printf ' (до конца, без таймаута)' )…"
  fi
  DOMAINS="$DOMAINS" \
  IPV=4 \
  SCANLEVEL="$SCANLEVEL" \
  ENABLE_HTTP=0 ENABLE_HTTPS_TLS12=$EN_TLS12 ENABLE_HTTPS_TLS13=$EN_TLS13 ENABLE_HTTP3=$EN_HTTP3 \
  CURL_TEST_HTTP=0 CURL_TEST_HTTPS_TLS12=$CT_TLS12 CURL_TEST_HTTPS_TLS13=$CT_TLS13 CURL_TEST_QUIC=$CT_QUIC \
  BATCH=1 PARALLEL=1 \
    "$BLOCKCHECK" >"$RUN_LOG" 2>&1 &
  BC_PID=$!

  run_start=$(date +%s)
  while :; do
    if ! kill -0 "$BC_PID" 2>/dev/null; then
      say "    [$proto] blockcheck завершился сам."
      break
    fi
    if grep -qiE "$RUN_TAG.*working without bypass" "$RUN_LOG" 2>/dev/null; then
      say "    [$proto] проходит напрямую."
      RUN_NOBP=1
      kill_blockcheck
      break
    fi
    n=$(avail_lines "$RUN_TAG" "$RUN_LOG" 2>/dev/null | wc -l)
    # обрыв по количеству — только если _want>0 (QUIC)
    if [ "$_want" -gt 0 ] && [ "$n" -ge "$_want" ]; then
      say "    [$proto] найдено $n — обрываю."
      kill_blockcheck
      break
    fi
    now=$(date +%s); el=$((now-run_start))
    _raw="$(tail -1 "$RUN_LOG" 2>/dev/null)"
    # если в строке есть стратегия nfqws2 — показываем только её (после "nfqws2 "),
    # иначе показываем служебную строку как есть (без префикса "- " и без обрезки)
    case "$_raw" in
      *"nfqws2 "*) last="nfqws2 $(printf '%s' "$_raw" | sed 's/.*nfqws2 //')" ;;
      *)           last="$(printf '%s' "$_raw" | sed 's/^[[:space:]]*-[[:space:]]*//')" ;;
    esac
    say "    [$proto ${el}с] найдено=$n | $last"
    # таймаут — только если _tmo>0
    if [ "$_tmo" -gt 0 ] && [ "$el" -ge "$_tmo" ]; then
      RUN_TIMED_OUT=1
      say "    [$proto] !!! таймаут — обрываю."
      kill_blockcheck
      break
    fi
    sleep "$POLL_SEC"
  done
  wait "$BC_PID" 2>/dev/null
  BC_PID=""
  # подчистить таблицу blockcheck, если осталась после kill
  nft list tables 2>/dev/null | grep -q 'blockcheck' && nft delete table inet blockcheck 2>/dev/null
}

# ---------- начало ----------
say ">>> Останавливаю $SERVICE, чищу conntrack..."
systemctl stop "$SERVICE" 2>/dev/null
conntrack -F >/dev/null 2>&1

# человекочитаемое описание лимитов для отчёта
fmt_want() { [ "$1" -eq 0 ] && printf 'полный перебор' || printf '%s шт' "$1"; }
fmt_tmo()  { [ "$1" -eq 0 ] && printf 'без таймаута'    || printf '%d мин' $(($1/60)); }
LIMITS_MSG="TLS: $(fmt_want "$WANT_TLS") / $(fmt_tmo "$TIMEOUT_TLS")  •  QUIC: $(fmt_want "$WANT_QUIC") / $(fmt_tmo "$TIMEOUT_QUIC")  •  scan: $SCANLEVEL"

# заголовок стартового сообщения: для --dry явно помечаем тест
if [ "$DRY" = "1" ]; then
  START_TITLE="🔻 <b>zapret2-slipstream</b> 🧪 <b>DRY (тест, конфиг НЕ изменится)</b>"
else
  START_TITLE="🔻 <b>zapret2-slipstream</b>"
fi

tg_send "$START_TITLE
<code>$SERVICE</code> остановлен. Поиск стратегий: TLS1.3 → TLS1.2 → QUIC (общая для 1.2+1.3 в приоритете)…
<b>Лимиты:</b> $LIMITS_MSG"

# ---- ПРОГОН 1: TLS 1.3 ----
run_protocol tls13
TLS_LOG="$RUN_LOG"; TLS_NOBP="$RUN_NOBP"; TLS_TO="$RUN_TIMED_OUT"
TLS_ALL="$(avail_lines "curl_test_https_tls13" "$TLS_LOG" | sed -n 's/.*nfqws2 //p')"

# ---- ПРОГОН 2: TLS 1.2 ----
run_protocol tls12
TLS12_LOG="$RUN_LOG"; TLS12_NOBP="$RUN_NOBP"; TLS12_TO="$RUN_TIMED_OUT"
TLS12_ALL="$(avail_lines "curl_test_https_tls12" "$TLS12_LOG" | sed -n 's/.*nfqws2 //p')"

# ---- ПРОГОН 3: QUIC ----
run_protocol quic
QUIC_LOG="$RUN_LOG"; QUIC_NOBP="$RUN_NOBP"; QUIC_TO="$RUN_TIMED_OUT"
QUIC_ALL="$(avail_lines "curl_test_http3" "$QUIC_LOG" | sed -n 's/.*nfqws2 //p')"

strip_payload() { sed -E 's/--payload=[^ ]+ *//g'; }

say ""
say ">>> Разбираю результаты…"

# первая + запас
TLS_FIRST="$(printf '%s\n' "$TLS_ALL"  | sed -n '1p')"
QUIC_FIRST="$(printf '%s\n' "$QUIC_ALL" | sed -n '1p')"
# запас TLS формируется ниже (после выбора: общая ИЛИ раздельно 1.3/1.2)
QUIC_SPARE="$(printf '%s\n' "$QUIC_ALL" | sed -n '2,$p' | sed '/^$/d' | head -1)"

if [ "$TLS_NOBP" = "1" ]; then
  TLS_DESYNC=""; TLS_INFO="проходит напрямую"
elif [ -n "$TLS_FIRST" ]; then
  TLS_DESYNC="$(printf '%s' "$TLS_FIRST" | strip_payload)"; TLS_INFO="$TLS_DESYNC"
else
  TLS_DESYNC=""; TLS_INFO="НЕ НАЙДЕНА (профиль без десинхр.)"
fi
if [ "$QUIC_NOBP" = "1" ]; then
  QUIC_DESYNC=""; QUIC_INFO="проходит напрямую"; QUIC_INFO_TG="проходит напрямую"
elif [ -n "$QUIC_FIRST" ]; then
  QUIC_DESYNC="$(printf '%s' "$QUIC_FIRST" | strip_payload)"; QUIC_INFO="$QUIC_DESYNC"
  QUIC_INFO_TG="<code>$(printf '%s' "$QUIC_DESYNC" | htmlesc)</code>"
else
  QUIC_DESYNC=""; QUIC_INFO="НЕ НАЙДЕНА (профиль без десинхр.)"; QUIC_INFO_TG="НЕ НАЙДЕНА (профиль без десинхр.)"
fi

# ---- выбор TLS-стратегии: приоритет ОБЩЕЙ для 1.2 и 1.3 ----
# nfqws2 не делит 1.2/1.3 по фильтру — профиль один. Поэтому идеально найти стратегию,
# которая работает для ОБОИХ. Логика:
#   1) если есть стратегия в списках рабочих И для 1.3, И для 1.2 → берём её (покрывает оба)
#   2) иначе если есть рабочая 1.3 → берём первую 1.3
#   3) иначе если есть рабочая 1.2 → берём первую 1.2
#   4) иначе пусто (не найдена)

TLS12_FIRST="$(printf '%s\n' "$TLS12_ALL" | sed -n '1p')"

# Собираем ВСЕ общие стратегии (рабочие и для 1.3, и для 1.2), по strip_payload-форме.
# Сохраняем исходные 1.3-строки (с payload). Первая из них станет выбранной,
# остальные общие пойдут в запас.
TLS_COMMON_ALL=""
if [ -n "$TLS_ALL" ] && [ -n "$TLS12_ALL" ]; then
  TLS_COMMON_ALL="$(
    while IFS= read -r _l13; do
      [ -z "$_l13" ] && continue
      _l13_sp="$(printf '%s' "$_l13" | strip_payload)"
      while IFS= read -r _l12; do
        [ -z "$_l12" ] && continue
        _l12_sp="$(printf '%s' "$_l12" | strip_payload)"
        if [ "$_l13_sp" = "$_l12_sp" ]; then
          printf '%s\n' "$_l13"   # исходная строка 1.3 (с payload)
          break
        fi
      done <<EOF12
$TLS12_ALL
EOF12
    done <<EOF13
$TLS_ALL
EOF13
  )"
fi
# первая общая — кандидат в конфиг
TLS_COMMON="$(printf '%s\n' "$TLS_COMMON_ALL" | sed '/^$/d' | sed -n '1p')"

TLS_SRC=""   # откуда взята стратегия (для отчёта)
if [ "$TLS_NOBP" = "1" ] && [ "$TLS12_NOBP" = "1" ]; then
  # оба идут напрямую — TLS не нужен (обработается защитой ниже)
  TLS_DESYNC=""; TLS_INFO="проходит напрямую (оба)"; TLS_INFO_TG="проходит напрямую (оба)"; TLS_SRC="nobp"
elif [ -n "$TLS_COMMON" ]; then
  TLS_DESYNC="$(printf '%s' "$TLS_COMMON" | strip_payload)"
  TLS_INFO="ОБЩАЯ 1.2+1.3: $TLS_DESYNC"
  TLS_INFO_TG="ОБЩАЯ 1.2+1.3: <code>$(printf '%s' "$TLS_DESYNC" | htmlesc)</code>"; TLS_SRC="common"
elif [ -n "$TLS_FIRST" ]; then
  TLS_DESYNC="$(printf '%s' "$TLS_FIRST" | strip_payload)"
  TLS_INFO="только 1.3: $TLS_DESYNC"
  TLS_INFO_TG="только 1.3: <code>$(printf '%s' "$TLS_DESYNC" | htmlesc)</code>"; TLS_SRC="tls13"
elif [ -n "$TLS12_FIRST" ]; then
  TLS_DESYNC="$(printf '%s' "$TLS12_FIRST" | strip_payload)"
  TLS_INFO="только 1.2 (1.3 не найдена): $TLS_DESYNC"
  TLS_INFO_TG="только 1.2 (1.3 не найдена): <code>$(printf '%s' "$TLS_DESYNC" | htmlesc)</code>"; TLS_SRC="tls12"
else
  TLS_DESYNC=""; TLS_INFO="НЕ НАЙДЕНА (профиль без десинхр.)"; TLS_INFO_TG="НЕ НАЙДЕНА (профиль без десинхр.)"; TLS_SRC="none"
fi

say "TLS:    $TLS_INFO"
say "QUIC:   $QUIC_INFO"

# Запас TLS для телеграма (ОГРАНИЧЕН, чтобы сообщение было компактным):
#   • есть ОБЩИЕ  → 1 запасная общая (TLS_SPARE_COMMON, вторая по списку);
#   • общих нет   → раздельно: _spare_tls (1.3) + _spare_12 (1.2), в отдельные блоки.
# ВАЖНО: строки начинаются с "--" — исключаем выбранную ручным сравнением, не grep.
TLS_SPARE_COMMON=""; _spare_tls=""; _spare_12=""
if [ -n "$TLS_COMMON_ALL" ]; then
  # 1 запасная общая (кроме уже применённой)
  TLS_SPARE_COMMON="$(
    printf '%s\n' "$TLS_COMMON_ALL" | sed '/^$/d' | sort -u | \
    while IFS= read -r _line; do
      [ -z "$_line" ] && continue
      _sp="$(printf '%s' "$_line" | strip_payload)"
      [ "$_sp" = "$TLS_DESYNC" ] && continue
      printf '%s\n' "$_line"
    done | head -1
  )"
else
  # 1 запасная TLS 1.3 (вторая рабочая, кроме применённой)
  _spare_tls="$(
    printf '%s\n' "$TLS_ALL" | sed '/^$/d' | \
    while IFS= read -r _line; do
      [ -z "$_line" ] && continue
      [ "$_line" = "$TLS_FIRST" ] && continue
      printf '%s\n' "$_line"
    done | head -1
  )"
  # 1 стратегия для 1.2 (первая), если она отличается от применённой TLS
  _spare_12="$(
    printf '%s\n' "$TLS12_ALL" | sed '/^$/d' | \
    while IFS= read -r _line; do
      [ -z "$_line" ] && continue
      _sp="$(printf '%s' "$_line" | strip_payload)"
      [ "$_sp" = "$TLS_DESYNC" ] && continue
      printf '%s\n' "$_line"
    done | head -1
  )"
fi

# запас QUIC — ограничиваем 1 строкой

# статистика для отчёта
TLS13_CNT=$(printf '%s\n' "$TLS_ALL"  | sed '/^$/d' | wc -l)
TLS12_CNT=$(printf '%s\n' "$TLS12_ALL" | sed '/^$/d' | wc -l)
QUIC_CNT=$(printf '%s\n' "$QUIC_ALL"  | sed '/^$/d' | wc -l)

# ---- диагностика TLS 1.2 для телеграма ----
if [ "$TLS12_NOBP" = "1" ]; then
  TLS12_INFO="проходит напрямую"
elif [ -n "$TLS12_FIRST" ]; then
  TLS12_INFO="$(printf '%s' "$TLS12_FIRST" | strip_payload)"
else
  TLS12_INFO="рабочих не найдено"
fi

# формируем строку статуса 1.2 для телеграма (с учётом выбранного источника)
if [ "$TLS_SRC" = "common" ]; then
  TLS12_TG="✅ выбрана ОБЩАЯ стратегия (работает и для 1.2, и для 1.3)"
elif [ "$TLS12_NOBP" = "1" ]; then
  TLS12_TG="ℹ️ 1.2 проходит напрямую"
elif [ "$TLS_SRC" = "tls12" ]; then
  TLS12_TG="✅ применена стратегия 1.2 (1.3 не нашлась)"
elif [ "$TLS_SRC" = "nobp" ]; then
  TLS12_TG="—"
elif [ -n "$TLS12_FIRST" ]; then
  TLS12_TG="⚠️ общей нет; применена 1.3. Для 1.2 рабочая иная: <code>$(printf '%s' "$TLS12_INFO" | htmlesc)</code> (для 1.2 может не сработать)"
else
  TLS12_TG="⚠️ для 1.2 рабочих стратегий не найдено (для 1.2 может не сработать)"
fi

# найдено рабочих по каждой версии — в отчёт
TLS_STAT="1.3: $TLS13_CNT шт, 1.2: $TLS12_CNT шт, QUIC: $QUIC_CNT шт"

# Файл с последней ПРИМЕНЁННОЙ стратегией (плоский, легко парсится).
# Пишется при успешном внесении; читается, если новая стратегия не найдена.
CURRENT_STRAT="$ZAPRET_DIR/.current-strat"

# прочитать сохранённую desync прежней стратегии. $1 = TLS_DESYNC | QUIC_DESYNC
read_saved_desync() {
  [ -f "$CURRENT_STRAT" ] || return
  _k="$1"
  sed -n "s/^${_k}=//p" "$CURRENT_STRAT" | head -1
}

# Если для протокола новая стратегия НЕ найдена и это НЕ "напрямую" —
# подставляем прежнюю из .current-strat (не теряем рабочую настройку).
TLS_REUSED=0; QUIC_REUSED=0
if [ -z "$TLS_DESYNC" ] && [ "$TLS_NOBP" != "1" ]; then
  _old="$(read_saved_desync TLS_DESYNC)"
  if [ -n "$_old" ]; then
    TLS_DESYNC="$_old"; TLS_REUSED=1
    TLS_INFO="(сохранена прежняя) $_old"
    TLS_INFO_TG="(сохранена прежняя) <code>$(printf '%s' "$_old" | htmlesc)</code>"
    say "TLS: новая не найдена → сохраняю прежнюю: $_old"
  fi
fi
if [ -z "$QUIC_DESYNC" ] && [ "$QUIC_NOBP" != "1" ]; then
  _old="$(read_saved_desync QUIC_DESYNC)"
  if [ -n "$_old" ]; then
    QUIC_DESYNC="$_old"; QUIC_REUSED=1
    QUIC_INFO="(сохранена прежняя) $_old"
    QUIC_INFO_TG="(сохранена прежняя) <code>$(printf '%s' "$_old" | htmlesc)</code>"
    say "QUIC:   новая не найдена → сохраняю прежнюю: $_old"
  fi
fi

# защита: оба идут напрямую — конфиг не трогаем
if [ "$TLS_NOBP" = "1" ] && [ "$QUIC_NOBP" = "1" ]; then
  say ""
  say ">>> Оба протокола проходят напрямую — блокировка временно снята. Конфиг НЕ изменяю."
  if [ "$DRY" != "1" ]; then systemctl restart "$SERVICE" >/dev/null 2>&1; conntrack -F >/dev/null 2>&1
  else systemctl start "$SERVICE" >/dev/null 2>&1; fi
  tg_send "ℹ️ <b>zapret2-slipstream — без изменений</b>
Сейчас и TLS, и QUIC проходят напрямую (блокировка снята).
Конфиг не тронут, текущая стратегия сохранена.
<b>Время:</b> $(elapsed)"
  exit 0
fi

# защита: поиск полностью провалился — ни новой стратегии, ни сохранённой прежней,
# и это НЕ "напрямую". (например, DPI режет всё — как при закручивании гаек РКН).
# В этом случае НЕ затираем рабочий конфиг пустышкой.
if [ -z "$TLS_DESYNC" ] && [ -z "$QUIC_DESYNC" ] \
   && [ "$TLS_NOBP" != "1" ] && [ "$QUIC_NOBP" != "1" ]; then
  say ""
  say "!!! Рабочих стратегий не найдено НИ для TLS, НИ для QUIC (и нет сохранённых прежних)."
  say "!!! Похоже, DPI режет всё. Конфиг НЕ трогаю."
  if [ "$DRY" != "1" ]; then systemctl restart "$SERVICE" >/dev/null 2>&1; conntrack -F >/dev/null 2>&1
  else systemctl start "$SERVICE" >/dev/null 2>&1; fi
  tg_send "🔴 <b>zapret2-slipstream — стратегии не найдены</b>
Поиск провалился: ни TLS1.3, ни QUIC рабочих стратегий нет (DPI режет всё).
Конфиг НЕ тронут, прежняя стратегия сохранена.
<b>TLS 1.2:</b> $TLS12_TG
<b>Время:</b> $(elapsed)"
  exit 0
fi

# ---- сборка NFQWS2_OPT ----
NL='
'
NEW_OPT="$NL"
NEW_OPT="$NEW_OPT$HTTP_FILTER$NL"
NEW_OPT="$NEW_OPT$HTTP_PAYLOAD --lua-desync=multisplit:pos=method+2$NL"
NEW_OPT="$NEW_OPT--new $TLS_FILTER$NL"
NEW_OPT="$NEW_OPT$TLS_PAYLOAD $TLS_DESYNC$NL"
NEW_OPT="$NEW_OPT--new $QUIC_FILTER$NL"
NEW_OPT="$NEW_OPT$QUIC_PAYLOAD $QUIC_DESYNC "

say ""
say "================ ПРЕДЛАГАЕМЫЙ NFQWS2_OPT ================"
printf 'NFQWS2_OPT="%s"\n' "$NEW_OPT"
say "========================================================"

# ---- запасные desync для сборки запасного NFQWS2_OPT ----
# TLS: если есть общая — берём запасную общую; иначе запасную 1.3.
if [ -n "$TLS_SPARE_COMMON" ]; then
  _spare_tls_desync="$(printf '%s' "$TLS_SPARE_COMMON" | strip_payload)"
else
  _spare_tls_desync="$(printf '%s' "$_spare_tls" | strip_payload)"
fi
_spare_quic_desync="$(printf '%s' "$QUIC_SPARE" | strip_payload)"

# ---- запасной NFQWS2_OPT (запас TLS + запас QUIC вместе) ----
# Собираем ТОЛЬКО если есть хотя бы одна запасная стратегия (TLS или QUIC).
SPARE_OPT=""
if [ -n "$_spare_tls_desync" ] || [ -n "$_spare_quic_desync" ]; then
  # для профиля берём запасную desync; если запасной нет — используем применённую
  _bt="${_spare_tls_desync:-$TLS_DESYNC}"
  _bq="${_spare_quic_desync:-$QUIC_DESYNC}"
  SPARE_OPT="$NL"
  SPARE_OPT="$SPARE_OPT$HTTP_FILTER$NL"
  SPARE_OPT="$SPARE_OPT$HTTP_PAYLOAD --lua-desync=multisplit:pos=method+2$NL"
  SPARE_OPT="$SPARE_OPT--new $TLS_FILTER$NL"
  SPARE_OPT="$SPARE_OPT$TLS_PAYLOAD $_bt$NL"
  SPARE_OPT="$SPARE_OPT--new $QUIC_FILTER$NL"
  SPARE_OPT="$SPARE_OPT$QUIC_PAYLOAD $_bq "
fi

# ---- сборка блоков запаса для телеграма ----
SPARE_MSG=""
# запас TLS: общая ИЛИ раздельно 1.3 / 1.2
if [ -n "$TLS_SPARE_COMMON" ]; then
  SPARE_MSG="$SPARE_MSG
<b>Запас TLS (общая 1.2+1.3):</b>
<pre><code class=\"language-bash\">$(printf '%s' "$TLS_SPARE_COMMON" | htmlesc)</code></pre>"
else
  [ -n "$_spare_tls" ] && SPARE_MSG="$SPARE_MSG
<b>Запас 1.3:</b>
<pre><code class=\"language-bash\">$(printf '%s' "$_spare_tls" | htmlesc)</code></pre>"
  [ -n "$_spare_12" ] && SPARE_MSG="$SPARE_MSG
<b>Запас 1.2:</b>
<pre><code class=\"language-bash\">$(printf '%s' "$_spare_12" | htmlesc)</code></pre>"
fi
# запас QUIC
[ -n "$QUIC_SPARE" ] && SPARE_MSG="$SPARE_MSG
<b>Запас QUIC:</b>
<pre><code class=\"language-bash\">$(printf '%s' "$QUIC_SPARE" | htmlesc)</code></pre>"
# запасной NFQWS2_OPT целиком
if [ -n "$SPARE_OPT" ]; then
  _spare_opt_label="запас TLS"
  [ -n "$TLS_SPARE_COMMON" ] && _spare_opt_label="запас TLS (общая)"
  [ -z "$_spare_tls_desync" ] && _spare_opt_label="TLS основной"
  SPARE_MSG="$SPARE_MSG
<b>Запасной NFQWS2_OPT ($_spare_opt_label + запас QUIC):</b>
<pre><code class=\"language-bash\">$(printf '%s' "$SPARE_OPT" | htmlesc)</code></pre>"
fi

# уведомление про таймаут любого прогона
if [ "$TLS_TO" = "1" ] || [ "$TLS12_TO" = "1" ] || [ "$QUIC_TO" = "1" ]; then
  tg_send "⏱ <b>zapret2-slipstream — таймаут прогона</b>
TLS1.3: $TLS_TO, TLS1.2: $TLS12_TO, QUIC: $QUIC_TO (1=таймаут)
Применяю то, что успело найтись.
<b>Время:</b> $(elapsed)"
fi

# ---- dry ----
if [ "$DRY" = "1" ]; then
  say ""; say "Режим --dry: не вношу. Время: $(elapsed)."
  systemctl start "$SERVICE" >/dev/null 2>&1
  OPT_HTML="$(printf '%s' "$NEW_OPT" | htmlesc)"
  tg_send "🟡 <b>zapret2-slipstream (dry)</b>
<b>TLS:</b> $TLS_INFO_TG
<b>TLS 1.2 статус:</b> $TLS12_TG
<b>Найдено рабочих:</b> $TLS_STAT
<b>QUIC:</b> $QUIC_INFO_TG
<b>Время:</b> $(elapsed)

<b>NFQWS2_OPT:</b>
<pre><code class="language-bash">$OPT_HTML</code></pre>$SPARE_MSG"
  exit 0
fi

# ---- бэкап + безопасная запись ----
if [ ! -d "$TMP" ]; then say "!!! temp пропал — без изменений."; systemctl start "$SERVICE"; exit 1; fi
STAMP="$(date +%Y%m%d-%H%M%S)"
cp "$CONFIG" "$CONFIG.bak-$STAMP"
say ">>> Бэкап: $CONFIG.bak-$STAMP"

awk '
  BEGIN{skip=0}
  /^NFQWS2_OPT="/{skip=1; next}
  skip==1{ if ($0 ~ /"[[:space:]]*$/){skip=0}; next }
  {print}
' "$CONFIG" > "$TMP/config.new" || { say "!!! awk не смог записать."; systemctl start "$SERVICE"; exit 1; }
printf 'NFQWS2_OPT="%s"\n' "$NEW_OPT" >> "$TMP/config.new"

if [ ! -s "$TMP/config.new" ] || ! grep -q '^NFQWS2_OPT=' "$TMP/config.new"; then
  say "!!! Собранный конфиг некорректен — НЕ применяю."; systemctl start "$SERVICE"; exit 1
fi
if ! cp "$TMP/config.new" "$CONFIG"; then
  say "!!! Запись не удалась. Восстанавливаю бэкап."
  cp "$CONFIG.bak-$STAMP" "$CONFIG"; systemctl restart "$SERVICE"; exit 1
fi
say ">>> NFQWS2_OPT обновлён в $CONFIG"

say ">>> Перезапуск $SERVICE + сброс conntrack…"
systemctl restart "$SERVICE"
conntrack -F >/dev/null 2>&1
sleep 1

SMOKE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://www.youtube.com 2>/dev/null)"
OPT_HTML="$(printf '%s' "$NEW_OPT" | htmlesc)"

if systemctl is-active --quiet "$SERVICE"; then
  say ">>> Готово. $SERVICE active. youtube: HTTP $SMOKE. Время: $(elapsed)."
  # сохраняем применённые desync-строки для будущего переиспользования
  {
    printf 'TLS_DESYNC=%s\n'  "$TLS_DESYNC"
    printf 'QUIC_DESYNC=%s\n' "$QUIC_DESYNC"
  } > "$CURRENT_STRAT" 2>/dev/null
  tg_send "✅ <b>zapret2-slipstream — применено</b>
<b>TLS:</b> $TLS_INFO_TG
<b>TLS 1.2 статус:</b> $TLS12_TG
<b>Найдено рабочих:</b> $TLS_STAT
<b>QUIC:</b> $QUIC_INFO_TG
<b>youtube:</b> HTTP $SMOKE
<b>Время:</b> $(elapsed)

<b>NFQWS2_OPT:</b>
<pre><code class="language-bash">$OPT_HTML</code></pre>$SPARE_MSG"
else
  say "!!! $SERVICE не поднялся. Откат:"
  say "    sudo cp $CONFIG.bak-$STAMP $CONFIG && sudo systemctl restart $SERVICE"
  tg_send "⛔️ <b>zapret2-slipstream — ОШИБКА</b>
<code>$SERVICE</code> не поднялся.
Откат: <ul><code>cp $CONFIG.bak-$STAMP $CONFIG \&\& systemctl restart $SERVICE</code></ul>
<b>Время:</b> $(elapsed)"
  exit 1
fi
