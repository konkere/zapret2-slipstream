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
# Куда сохранять СЫРЫЕ логи blockcheck2 (bc-tls13.log, bc-tls12.log, bc-quic.log) после прогона.
# Без них разбор «почему QUIC не нашёлся» невозможен: там диагностика IP-блокировок, DNS и т.п.
# Пусто — не сохранять. Перезаписываются при каждом запуске; предыдущие — с суффиксом .prev.
BC_LOG_DIR="/var/lib/zapret2-slipstream"
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
#   standard — обычное «исследование» DPI (дефолт самого blockcheck, перебор НЕПОЛНЫЙ:
#              группы стратегий пропускаются по результатам предыдущих — и для 1.2/1.3
#              и для разных доменов эти пропуски РАЗНЫЕ, списки становятся несопоставимы);
#   force    — перебрать МАКСИМУМ стратегий, без пропусков. Порядок тот же, что в standard,
#              обрыв по --want-* работает как обычно, так что до первых находок время почти
#              то же. Единственный режим, в котором пересечения (1.2+1.3, домены) достоверны —
#              сам blockcheck говорит это про свой intersection. Поэтому дефолт здесь — force.
# Переопределяется параметром --scan-level.
SCANLEVEL=force

# Путь к дефолтному env-файлу (переопределяется переменной AUTOSTRAT_ENV=... перед запуском).
DEFAULT_ENV="${AUTOSTRAT_ENV:-/etc/zapret2-slipstream/.env}"
# ============ КОНЕЦ НАСТРОЕК ============

# читает env-файл, переопределяя разрешённые переменные. $1 = путь к файлу.
load_env() {
  _envf="$1"
  [ -f "$_envf" ] || return 1
  while IFS= read -r _line; do
    case "$_line" in
      BOT_ID=*|CHAT_ID=*|SOCKS5=*|ZAPRET_DIR=*|SERVICE=*|DOMAINS=*|LOGFILE=*|BC_LOG_DIR=*)
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
# Сырые логи blockcheck2 после прогона (пусто — не сохранять)
BC_LOG_DIR="$BC_LOG_DIR"
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
                        standard — перебор с пропусками (дефолт blockcheck; списки для
                                   1.2/1.3 и разных доменов несопоставимы);
                        force    — без пропусков; только в нём пересечение (общая 1.2+1.3,
                                   несколько доменов) достоверно. По умолчанию: force.

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
      DOMAINS                   — домен(ы) для blockcheck через пробел (по умолч. www.youtube.com).
                                  При нескольких — берутся стратегии, рабочие для ВСЕХ
                                  (домены, идущие напрямую, не учитываются); blockcheck гоняется на каждый домен отдельно, таймаут — на домен
      LOGFILE                   — лог для --cron
      BC_LOG_DIR                — куда класть сырые логи blockcheck2 после прогона
                                  (по умолч. /var/lib/zapret2-slipstream; пусто — не сохранять)
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
  sudo zapret2-slipstream.sh --want-tls 0 --want-quic 0     # полный перебор всего (долго!)
  sudo zapret2-slipstream.sh --scan-level standard          # быстрее, но пересечения ненадёжны
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

# число доменов в DOMAINS: при >1 стратегии пересекаются по доменам, blockcheck запускается на каждый отдельно
# shellcheck disable=SC2086
DOMAINS="$(printf '%s\n' $DOMAINS | awk 'NF && !seen[$0]++' | tr '\n' ' ' | sed 's/ $//')"   # дубликаты убрать
NDOM=$(printf '%s\n' $DOMAINS | grep -c .)
[ "$NDOM" -ge 1 ] || { say "DOMAINS пуст — нечего проверять." >&2; exit 1; }

[ "$(id -u)" = "0" ] || { say "Нужен root (sudo)." >&2; exit 1; }
[ -x "$BLOCKCHECK" ] || { say "Не найден $BLOCKCHECK" >&2; exit 1; }
[ -f "$CONFIG" ]     || { say "Не найден $CONFIG" >&2; exit 1; }

TMP="$(mktemp -d)"
BC_PID=""

# blockcheck запускаем через setsid в СВОЕЙ группе процессов: тогда сигнал группе
# достаёт не только blockcheck2.sh, но и nfqws2/tpws2, которые он держит в фоне
# (это внуки, до которых pkill -P не добирался — они переезжали к PID 1 и жили дальше).
SETSID=""
command -v setsid >/dev/null 2>&1 && SETSID="setsid"

kill_blockcheck() {
  [ -n "$BC_PID" ] || return 0
  # мягко всей группе — даём blockcheck шанс на собственный cleanup
  kill -s TERM -- "-$BC_PID" 2>/dev/null || kill -s TERM "$BC_PID" 2>/dev/null
  _i=0
  while [ "$_i" -lt 10 ] && kill -0 "$BC_PID" 2>/dev/null; do sleep 0.5; _i=$((_i+1)); done
  # не послушался за 5с — жёстко
  kill -s KILL -- "-$BC_PID" 2>/dev/null; kill -s KILL "$BC_PID" 2>/dev/null
  BC_PID=""
}

# --- зачистка следов blockcheck ---
# blockcheck2 поднимает nfqws2/tpws2 в фоне и создаёт nft-таблицу inet blockcheck<PID>,
# заворачивающую в них трафик к тестовым IP. Если его прибить по таймауту, он не успевает
# убрать за собой: процесс остаётся висеть с тестовой стратегией, а таблица продолжает
# гнать в него ВЕСЬ трафик к www.youtube.com — поверх штатного zapret2, без лимита
# по пакетам. Несколько таких прогонов = несколько наложенных десинков на каждом
# ClientHello. Поэтому чистим сами: после КАЖДОГО прогона, при прерывании и на старте.
#
# Инвариант: $SERVICE остановлен на всё время подбора, поэтому любой живой nfqws2/tpws2
# в этот момент — чужой. Если у тебя есть ДРУГИЕ инстансы nfqws2/tpws2 вне $SERVICE —
# этот скрипт их убьёт; так и задумано, другой надёжной эвристики нет.
STRAYS_PROCS=0
STRAYS_TABLES=0
live_strays() {  # pid живых (не зомби) nfqws2/tpws2 через пробел
  for _p in $(pgrep -x 'nfqws2|tpws2' 2>/dev/null); do
    case "$(ps -o stat= -p "$_p" 2>/dev/null)" in Z*) ;; *) printf '%s ' "$_p" ;; esac
  done
}
sweep_blockcheck() {  # $1 = метка для лога (необязательно)
  _lbl="${1:-}"
  # 1) сначала таблицы — иначе трафик к тестовым IP улетит в очередь без слушателя (= drop)
  _tbl="$(nft list tables 2>/dev/null | awk '$1=="table" && $3 ~ /^blockcheck/ {print $2, $3}')"
  if [ -n "$_tbl" ]; then
    _n=$(printf '%s\n' "$_tbl" | wc -l)
    printf '%s\n' "$_tbl" | while read -r _fam _name; do
      [ -n "$_name" ] && nft delete table "$_fam" "$_name" 2>/dev/null
    done
    STRAYS_TABLES=$((STRAYS_TABLES+_n))
    say "    [sweep$_lbl] удалено nft-таблиц blockcheck*: $_n"
  fi
  # 1б) iptables-режим blockcheck: цепочки blockcheck_{output,input}_<PID> в mangle
  #     (прыжки из OUTPUT/INPUT, внутри NFQUEUE без --queue-bypass → без слушателя = drop)
  #     и вспомогательные правила с комментарием blockcheck_<PID> в filter/raw.
  #     Хук у них OUTPUT, т.е. страдает только трафик самого хоста — но это в т.ч.
  #     наш собственный smoke-test. Чистим для iptables и ip6tables, no-op если пусто.
  for _ipt in iptables ip6tables; do
    command -v "$_ipt" >/dev/null 2>&1 || continue
    command -v "${_ipt}-save" >/dev/null 2>&1 || continue
    _n=0
    # прыжки на цепочки blockcheck_* из OUTPUT/INPUT
    "${_ipt}-save" -t mangle 2>/dev/null | grep -E '^-A (OUTPUT|INPUT) .*-j blockcheck_' | sed 's/^-A /-D /; s/"//g' > "$TMP/ipt.$_ipt"
    while read -r _rule; do
      # shellcheck disable=SC2086
      [ -n "$_rule" ] && "$_ipt" -t mangle $_rule 2>/dev/null
    done < "$TMP/ipt.$_ipt"
    # сами цепочки
    for _ch in $("${_ipt}-save" -t mangle 2>/dev/null | sed -n 's/^:\(blockcheck_[^ ]*\).*/\1/p'); do
      "$_ipt" -t mangle -F "$_ch" 2>/dev/null
      "$_ipt" -t mangle -X "$_ch" 2>/dev/null && _n=$((_n+1))
    done
    # вспомогательные правила по комментарию
    for _tbl in filter raw mangle; do
      "${_ipt}-save" -t "$_tbl" 2>/dev/null | grep -E '^-A .*--comment "?blockcheck_' | sed 's/^-A /-D /; s/"//g' > "$TMP/ipt.$_ipt.$_tbl"
      while read -r _rule; do
        # shellcheck disable=SC2086
        [ -n "$_rule" ] && "$_ipt" -t "$_tbl" $_rule 2>/dev/null && _n=$((_n+1))
      done < "$TMP/ipt.$_ipt.$_tbl"
    done
    if [ "$_n" -gt 0 ]; then
      STRAYS_TABLES=$((STRAYS_TABLES+_n))
      say "    [sweep$_lbl] $_ipt: снято цепочек/правил blockcheck_*: $_n"
    fi
  done
  # 2) потом процессы
  _pids="$(live_strays)"
  if [ -n "$_pids" ]; then
    _n=0
    for _p in $_pids; do kill -s TERM "$_p" 2>/dev/null && _n=$((_n+1)); done
    sleep 1
    for _p in $(live_strays); do kill -s KILL "$_p" 2>/dev/null; done
    STRAYS_PROCS=$((STRAYS_PROCS+_n))
    say "    [sweep$_lbl] убито сиротских nfqws2/tpws2: $_n (pid: $_pids)"
  fi
  # 3) страховка: если после всего что-то осталось — говорим громко
  if [ -n "$(live_strays)" ] || nft list tables 2>/dev/null | grep -q 'blockcheck' \
     || { command -v iptables-save >/dev/null 2>&1 && iptables-save 2>/dev/null | grep -q 'blockcheck_'; }; then
    say "!!! [sweep$_lbl] не удалось вычистить следы blockcheck полностью — проверь вручную:"
    say "!!!   pgrep -a 'nfqws2|tpws2'; nft list tables; iptables-save | grep blockcheck_"
  fi
}
strays_msg() {  # строка для отчёта (пусто, если ничего не чистили)
  [ "$STRAYS_PROCS" -gt 0 ] || [ "$STRAYS_TABLES" -gt 0 ] || return 0
  printf '\n<b>Зачистка blockcheck:</b> процессов %s, правил/таблиц %s' "$STRAYS_PROCS" "$STRAYS_TABLES"
}

# SERVICE_STOPPED=1 ставится сразу после остановки сервиса. cleanup() на EXIT — страховка
# на ЛЮБОЙ путь выхода (ошибка, exit 1 из проверок, прерывание): если сервис останавливали мы
# и он не поднят — поднять. Иначе неудачный запуск оставляет хост без обхода до ручного вмешательства.
SERVICE_STOPPED=0
cleanup() {
  rm -rf "$TMP"
  if [ "$SERVICE_STOPPED" = 1 ] && ! systemctl is-active --quiet "$SERVICE"; then
    systemctl start "$SERVICE" >/dev/null 2>&1
  fi
}
on_interrupt() {
  # Порядок принципиален. Ctrl+C прилетает всей группе терминала — в т.ч. `tee`, если вывод
  # шёл через него. tee умирает, stdout становится трубой без читателя, и первый же `say`
  # убивает скрипт SIGPIPE'ом до того, как он поднимет сервис. Поэтому: сначала запретить
  # себя убивать (PIPE и повторный Ctrl+C), потом убрать blockcheck и его следы (sweep
  # убивает ВСЕ nfqws2 — значит строго ДО старта сервиса), потом поднять сервис, и только
  # потом разговаривать.
  trap '' PIPE INT TERM
  kill_blockcheck
  sweep_blockcheck " int" 2>/dev/null
  systemctl start "$SERVICE" >/dev/null 2>&1
  _msg="!!! Прервано пользователем. Конфиг не изменён, $SERVICE $(systemctl is-active "$SERVICE" 2>/dev/null)."
  say ""; say "$_msg"
  # если stdout был трубой в tee и tee уже мёртв — скажем хотя бы в терминал напрямую
  [ -w /dev/tty ] && printf '\n%s\n' "$_msg" >/dev/tty 2>/dev/null
  cleanup
  tg_send "🟠 <b>zapret2-slipstream — прервано</b>
Поиск остановлен вручную. Конфиг не тронут, <code>$SERVICE</code> запущен.
<b>Время:</b> $(elapsed)"
  exit 130
}
trap on_interrupt INT TERM
trap cleanup EXIT
# Глобально PIPE НЕ игнорируем: конструкции вида `while … printf … done | head -1` тогда
# начинают сыпать "printf: I/O error" (head вышел, цикл пишет в мёртвую трубу). Защита от
# мёртвого stdout нужна только в обработчике прерывания — там она и стоит.

# ---- разбор лога blockcheck с учётом доменов ----
# blockcheck гоняет домены из DOMAINS ПОСЛЕДОВАТЕЛЬНО (все стратегии для первого, потом
# для второго...), а свой блок "* COMMON" печатает только в самом конце — до которого
# при обрыве по количеству мы не доживаем. Поэтому пересечение по доменам считаем сами.
# Формат строк blockcheck (домен есть в каждой):
#   * <tag> ipv4 <dom>                    — начало теста домена
#   - checking without DPI bypass         — затем AVAILABLE/UNAVAILABLE: работает ли напрямую
#   - <tag> ipv4 <dom> : nfqws2 <strat>   — кандидат, следующий вердикт относится к нему
#   !!!!! AVAILABLE !!!!!  /  UNAVAILABLE — вердикт
#   <tag> ipv4 <dom> : working without bypass | test aborted ...  — строки SUMMARY
# ВАЖНО: "UNAVAILABLE" содержит "AVAILABLE", поэтому проверяется первым, а успех — по полному маркеру.
parse_run() {  # $1=tag $2=log → "seen|ok|nobp|abort<TAB>domain<TAB>strategy"
  awk -v tag="$1" '
    $1=="*" && $2==tag                    { dom=$4; st="hdr"; cand=""; print "seen\t" dom "\t"; next }
    $1=="-" && $2==tag && $5==":" && /nfqws2 / {
      dom=$4; cand=$0; sub(/.*nfqws2 /,"",cand); st="cand"; print "seen\t" dom "\t"; next }
    /^- checking without DPI bypass/      { st="nobp"; cand=""; next }
    /UNAVAILABLE/                         { cand=""; if (st=="nobp") st="hdr"; next }
    /!!!!! AVAILABLE !!!!!/ {
      if (st=="nobp")      { print "nobp\t" dom "\t"; st="hdr" }
      else if (cand!="")   { print "ok\t" dom "\t" cand }
      cand=""; next }
    $1==tag && $4==":" && /working without bypass/ { print "nobp\t"  $3 "\t"; next }
    $1==tag && $4==":" && /test aborted/           { print "abort\t" $3 "\t"; next }
  ' "$2" 2>/dev/null
}

# Рабочие стратегии, общие для ВСЕХ заблокированных доменов (домены, идущие напрямую или
# упавшие с "test aborted", из пересечения исключаются — они ничего не ограничивают).
# Порядок — как у blockcheck для первого домена (он приоритезирует хорошие стратегии).
# При одном домене вырождается в простой список — поведение как раньше.
avail_strats() {  # $1=tag $2=log
  parse_run "$1" "$2" | awk -F'\t' '
    { if (!($2 in dseen)) { dseen[$2]=1; dorder[++nd]=$2 } }
    $1=="nobp" || $1=="abort" { skip[$2]=1; next }
    $1=="ok" { if (!(($2 SUBSEP $3) in have)) { have[$2,$3]=1; if (!($3 in ord)) { ord[$3]=++k; sord[k]=$3 } } }
    END {
      n=0; for (i=1;i<=nd;i++) if (!(dorder[i] in skip)) n++
      if (n==0) exit
      for (i=1;i<=k;i++) { s=sord[i]; c=0
        for (j=1;j<=nd;j++) { d=dorder[j]; if (!(d in skip) && ((d SUBSEP s) in have)) c++ }
        if (c==n) print s }
    }'
}

# Статистика по доменам для цикла опроса: "<seen> <nobp> <abort> <список seen через запятую>"
run_dom_stats() {  # $1=tag $2=log
  parse_run "$1" "$2" | awk -F'\t' '
    { if (!($2 in d)) { d[$2]=1; seen++; lst=(lst=="")?$2:lst "," $2 } }
    $1=="nobp"  { if (!($2 in nb)) { nb[$2]=1; nobp++ } }
    $1=="abort" { if (!($2 in ab)) { ab[$2]=1; abort++ } }
    END { printf "%d %d %d %s\n", seen+0, nobp+0, abort+0, lst }'
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

  if [ "$NDOM" -gt 1 ]; then
    say ">>> Прогон [$proto]: $NDOM доменов по очереди, каждый — до $( [ "$_want" -gt 0 ] && printf '%s общих' "$_want" || printf 'конца' )$( [ "$_tmo" -gt 0 ] && printf ', таймаут %d мин на домен' $((_tmo/60)) )…"
  elif [ "$_want" -gt 0 ]; then
    say ">>> Прогон [$proto]: ищу до $_want рабочих$( [ "$_tmo" -gt 0 ] && printf ' (таймаут %d мин)' $((_tmo/60)) )…"
  else
    say ">>> Прогон [$proto]: полный перебор$( [ "$_tmo" -gt 0 ] && printf ', таймаут %d мин' $((_tmo/60)) || printf ' (до конца, без таймаута)' )…"
  fi

  # blockcheck запускается ОТДЕЛЬНО на каждый домен: снаружи его нельзя «перемотать» на следующий
  # домен, только убить целиком, а значит при одном запуске на все домены первый домен не обрывался
  # бы по количеству и мог съесть весь таймаут. Логи всех доменов копятся в один RUN_LOG —
  # парсер различает домены по строкам blockcheck, пересечение считается по всему файлу.
  : > "$RUN_LOG"
  _idx=0
  for _dom in $DOMAINS; do
    _idx=$((_idx+1))
    # порог обрыва по количеству: первый из нескольких доменов набирает want×2 — запас, из которого
    # следующим доменам будет с чем пересекаться; остальные (и единственный) — want по общим.
    _thr="$_want"
    if [ "$_want" -gt 0 ] && [ "$NDOM" -gt 1 ] && [ "$_idx" -eq 1 ]; then _thr=$((_want*2)); fi
    [ "$NDOM" -gt 1 ] && say "    [$proto] домен $_idx/$NDOM: $_dom$( [ "$_thr" -gt 0 ] && printf ' (до %s %s)' "$_thr" "$( [ "$_idx" -eq 1 ] && printf 'рабочих' || printf 'общих' )" )"

    DOMAINS="$_dom" \
    IPV=4 \
    SCANLEVEL="$SCANLEVEL" \
    ENABLE_HTTP=0 ENABLE_HTTPS_TLS12=$EN_TLS12 ENABLE_HTTPS_TLS13=$EN_TLS13 ENABLE_HTTP3=$EN_HTTP3 \
    CURL_TEST_HTTP=0 CURL_TEST_HTTPS_TLS12=$CT_TLS12 CURL_TEST_HTTPS_TLS13=$CT_TLS13 CURL_TEST_QUIC=$CT_QUIC \
    BATCH=1 PARALLEL=1 \
      $SETSID "$BLOCKCHECK" >>"$RUN_LOG" 2>&1 &
    BC_PID=$!
    # setsid не должен форкаться (мы не лидер группы) → pgid blockcheck == его pid.
    # Если это не так (job control? интерактивный sh?), убийство группой не сработает —
    # тогда вся надежда на sweep_blockcheck. Не молчим об этом.
    if [ -n "$SETSID" ]; then
      _pg="$(ps -o pgid= -p "$BC_PID" 2>/dev/null | tr -d ' ')"
      [ "$_pg" = "$BC_PID" ] || say "    [$proto] !!! blockcheck не в своей группе процессов (pid=$BC_PID pgid=${_pg:-?}) — group-kill не сработает, полагаюсь на sweep"
    fi

    run_start=$(date +%s)
    while :; do
      if ! kill -0 "$BC_PID" 2>/dev/null; then
        say "    [$proto] blockcheck завершился сам."
        break
      fi
      # этот домен проходит напрямую → в пересечении не участвует, дальше его гонять незачем
      if parse_run "$RUN_TAG" "$RUN_LOG" | grep -q "^nobp	$_dom	"; then
        say "    [$proto] $_dom проходит напрямую — исключаю из пересечения."
        kill_blockcheck
        break
      fi
      n=$(avail_strats "$RUN_TAG" "$RUN_LOG" | wc -l)
      # обрыв по количеству — только когда ТЕКУЩИЙ домен уже появился в логе: пока blockcheck
      # стартует, пересечение равно списку предыдущих доменов и порог «пройден» фиктивно
      if [ "$_thr" -gt 0 ] && [ "$n" -ge "$_thr" ] && parse_run "$RUN_TAG" "$RUN_LOG" | grep -q "^seen	$_dom	"; then
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
        # эпилог blockcheck ("Please note this SUMMARY…", "It was designed…") — не прогресс
        "Please note"*|"Understanding how"*|"This knowledge"*|"Blockcheck does"*|"It was designed"*) last="(итоги blockcheck)" ;;
        *)           last="$(printf '%s' "$_raw" | sed 's/^[[:space:]]*-[[:space:]]*//')" ;;
      esac
      # пока текущий домен не появился в логе, n — это список предыдущих доменов; показываем прочерк
      _nshow="$n"
      parse_run "$RUN_TAG" "$RUN_LOG" | grep -q "^seen	$_dom	" || _nshow="—"
      if [ "$NDOM" -gt 1 ]; then
        say "    [$proto ${el}с] дом=$_idx/$NDOM $( [ "$_idx" -eq 1 ] && printf 'найдено' || printf 'общих' )=$_nshow | $last"
      else
        say "    [$proto ${el}с] найдено=$n | $last"
      fi
      # таймаут — на КАЖДЫЙ домен отдельно
      if [ "$_tmo" -gt 0 ] && [ "$el" -ge "$_tmo" ]; then
        RUN_TIMED_OUT=1
        say "    [$proto] !!! таймаут на $_dom — обрываю."
        kill_blockcheck
        break
      fi
      sleep "$POLL_SEC"
    done
    wait "$BC_PID" 2>/dev/null
    BC_PID=""
    # blockcheck прибит или завершился — вычистить всё, что он мог оставить
    sweep_blockcheck " $proto"
  done

  # напрямую проходят ВСЕ домены → протокол не заблокирован
  # shellcheck disable=SC2046
  set -- $(run_dom_stats "$RUN_TAG" "$RUN_LOG")
  if [ "${2:-0}" -gt 0 ] && [ "${2:-0}" -ge "$NDOM" ]; then
    say "    [$proto] проходит напрямую (все домены)."
    RUN_NOBP=1
  fi
  # сохранить сырой лог blockcheck — в нём диагностика (IP block tests, DNS), которой нет в нашем выводе
  if [ -n "$BC_LOG_DIR" ]; then
    mkdir -p "$BC_LOG_DIR" 2>/dev/null
    [ -f "$BC_LOG_DIR/bc-$proto.log" ] && mv -f "$BC_LOG_DIR/bc-$proto.log" "$BC_LOG_DIR/bc-$proto.log.prev" 2>/dev/null
    cp -f "$RUN_LOG" "$BC_LOG_DIR/bc-$proto.log" 2>/dev/null || say "    [$proto] !!! не удалось сохранить сырой лог в $BC_LOG_DIR"
  fi
  # домены, до которых blockcheck не дошёл (таймаут / обрыв / не резолвится) — в пересечении
  # они не участвуют, результат получен без них. Не молчим об этом.
  # shellcheck disable=SC2046
  set -- $(run_dom_stats "$RUN_TAG" "$RUN_LOG")
  if [ "${1:-0}" -lt "$NDOM" ]; then
    _lst=",${4:-},"
    for _d in $DOMAINS; do
      case "$_lst" in *",$_d,"*) ;; *) say "    [$proto] !!! домен $_d в тесте не появился — результат получен БЕЗ него" ;; esac
    done
  fi
  if [ "${3:-0}" -gt 0 ]; then
    say "    [$proto] !!! $3 домен(ов) с 'test aborted' (недоступен/не резолвится?) — исключены из пересечения"
  fi
}

# ---------- начало ----------
say ">>> Останавливаю $SERVICE, чищу conntrack..."
systemctl stop "$SERVICE" 2>/dev/null
SERVICE_STOPPED=1
# дать сервису реально погасить свои nfqws2, прежде чем считать оставшиеся чужими
_i=0; while [ "$_i" -lt 10 ] && systemctl is-active --quiet "$SERVICE"; do sleep 0.5; _i=$((_i+1)); done
conntrack -F >/dev/null 2>&1
# сиротки от ПРОШЛЫХ прогонов (если они есть — они всё это время портили трафик)
sweep_blockcheck " start"

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
<b>Лимиты:</b> $LIMITS_MSG
<b>Домены:</b> $DOMAINS"

# ---- ПРОГОН 1: TLS 1.3 ----
run_protocol tls13
TLS_LOG="$RUN_LOG"; TLS_NOBP="$RUN_NOBP"; TLS_TO="$RUN_TIMED_OUT"
TLS_ALL="$(avail_strats "curl_test_https_tls13" "$TLS_LOG")"

# ---- ПРОГОН 2: TLS 1.2 ----
run_protocol tls12
TLS12_LOG="$RUN_LOG"; TLS12_NOBP="$RUN_NOBP"; TLS12_TO="$RUN_TIMED_OUT"
TLS12_ALL="$(avail_strats "curl_test_https_tls12" "$TLS12_LOG")"

# ---- ПРОГОН 3: QUIC ----
run_protocol quic
QUIC_LOG="$RUN_LOG"; QUIC_NOBP="$RUN_NOBP"; QUIC_TO="$RUN_TIMED_OUT"
QUIC_ALL="$(avail_strats "curl_test_http3" "$QUIC_LOG")"

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
<b>Время:</b> $(elapsed)$(strays_msg)"
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
<pre><code class="language-bash">$OPT_HTML</code></pre>$SPARE_MSG$(strays_msg)"
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
<pre><code class="language-bash">$OPT_HTML</code></pre>$SPARE_MSG$(strays_msg)"
else
  say "!!! $SERVICE не поднялся. Откат:"
  say "    sudo cp $CONFIG.bak-$STAMP $CONFIG && sudo systemctl restart $SERVICE"
  tg_send "⛔️ <b>zapret2-slipstream — ОШИБКА</b>
<code>$SERVICE</code> не поднялся.
Откат: <ul><code>cp $CONFIG.bak-$STAMP $CONFIG \&\& systemctl restart $SERVICE</code></ul>
<b>Время:</b> $(elapsed)"
  exit 1
fi
