#!/usr/bin/env bash
# ============================================================================
#  ____   ___  ____   ___  ____    _____ _____ ____ _   _
# |  _ \ / _ \|  _ \ / _ \|  _ \  |_   _| ____/ ___| | | |
# | | | | | | | |_) | | | | | | |   | | |  _|| |   | |_| |
# | |_| | |_| |  _ <| |_| | |_| |   | | | |__| |___|  _  |
# |____/ \___/|_| \_\\___/|____/    |_| |_____\____|_| |_|
#
#  DOROD TECH · RemnaWave node agent · by vodorod
# ----------------------------------------------------------------------------
#  Единый агент управления нодой. Три режима, определяются автоматически:
#
#   install  — чистый сервер → готовая нода-клон (одна команда, идемпотентно)
#   doctor   — живая нода: диагностика + безопасная починка (dry-run по умолч.)
#   info     — машинный снимок состояния (для оркестратора/инвентаря)
#
#  ПРИНЦИП: источник правды о портах — что РЕАЛЬНО слушает xray (он получил
#  Config Profile от панели). Агент приводит firewall к этой правде, а не к
#  статике. Меняешь порты в панели → агент подстраивает ноду. Как GitOps.
#
#  БЕЗОПАСНОСТЬ на живой ноде: никогда не reset ufw; никогда не закрывает порт,
#  который сейчас слушается; старый порт закрывается ТОЛЬКО когда xray его
#  больше не слушает (т.е. панель уже увела трафик).
# ----------------------------------------------------------------------------
#  Примеры:
#    # чистый сервер (флот, тихо):
#    SECRET_KEY=.. PANEL_IP=.. NODE_PORT=6767 LOCATION=de PROVIDER=kamatera \
#      ./dorod-node.sh install --yes
#
#    # диагностика живой ноды (только показать, ничего не менять):
#    ./dorod-node.sh doctor
#    # ...и починить, что безопасно:
#    ./dorod-node.sh doctor --apply
#
#    # снимок для n8n:
#    ./dorod-node.sh info --json
# ============================================================================
set -euo pipefail

# ---------- параметры (env или дефолты) -------------------------------------
NODE_PORT="${NODE_PORT:-2222}"
NODE_IMAGE="${NODE_IMAGE:-remnawave/node:latest}"
INBOUND_PORTS="${INBOUND_PORTS:-2053 2054 2055 2056}"   # старт-набор для чистой ноды (до 1-го пуша профиля)
PANEL_IP="${PANEL_IP:-}"
SECRET_KEY="${SECRET_KEY:-}"
LOCATION="${LOCATION:-}"       # напр. de / us / nl  — метка локации (для инвентаря)
PROVIDER="${PROVIDER:-}"       # напр. kamatera / hetzner — хостер (для группировки по хостерам)
META_DIR="/etc/dorod"
META_FILE="${META_DIR}/node.env"
NODE_DIR="/opt/remnanode"
COMPOSE="${NODE_DIR}/docker-compose.yml"

# ---------- флаги -----------------------------------------------------------
MODE=""; ASSUME_YES=0; DO_APPLY=0; JSON=0
for a in "$@"; do
  case "$a" in
    install|doctor|info) MODE="$a" ;;
    --yes|-y)   ASSUME_YES=1 ;;
    --apply)    DO_APPLY=1 ;;
    --dry-run)  DO_APPLY=0 ;;
    --json)     JSON=1; ASSUME_YES=1 ;;
    *) echo "неизвестный аргумент: $a" >&2; exit 2 ;;
  esac
done

# ---------- окружение вывода (TTY → красиво; иначе → тихо) -------------------
if [ -t 1 ] && [ "$JSON" -eq 0 ]; then TTY=1; else TTY=0; fi
if [ "$TTY" -eq 1 ]; then
  C_RST=$'\e[0m'; C_DIM=$'\e[2m'; C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[36m'; C_BOLD=$'\e[1m'
else
  C_RST=; C_DIM=; C_R=; C_G=; C_Y=; C_B=; C_BOLD=
fi

# JSON-аккумулятор (пары ключ:значение), печатаем в самом конце
declare -a J_KEYS J_VALS
jset(){ J_KEYS+=("$1"); J_VALS+=("$2"); }
json_flush(){
  [ "$JSON" -eq 1 ] || return 0
  local out="{" i
  for i in "${!J_KEYS[@]}"; do
    local v="${J_VALS[$i]}"
    # если значение — число или [..]/{..}, не оборачиваем в кавычки
    if [[ "$v" =~ ^-?[0-9]+$ || "$v" =~ ^\[.*\]$ || "$v" =~ ^\{.*\}$ || "$v" == "true" || "$v" == "false" ]]; then
      out+="\"${J_KEYS[$i]}\":${v}"
    else
      out+="\"${J_KEYS[$i]}\":\"${v}\""
    fi
    [ "$i" -lt $(( ${#J_KEYS[@]} - 1 )) ] && out+=","
  done
  out+="}"; printf '%s\n' "$out"
}

say(){  [ "$TTY" -eq 1 ] && printf '%s\n' "$*"; return 0; }
step(){ [ "$TTY" -eq 1 ] && printf '%s▸ %s%s\n' "$C_B" "$*" "$C_RST"; return 0; }
ok(){   [ "$TTY" -eq 1 ] && printf '  %s✅ %s%s\n' "$C_G" "$*" "$C_RST"; return 0; }
warn(){ [ "$TTY" -eq 1 ] && printf '  %s⚠️  %s%s\n' "$C_Y" "$*" "$C_RST"; return 0; }
bad(){  [ "$TTY" -eq 1 ] && printf '  %s❌ %s%s\n' "$C_R" "$*" "$C_RST"; return 0; }

banner(){
  [ "$TTY" -eq 1 ] || return 0
  printf '%s' "$C_B$C_BOLD"
  cat <<'EOF'
   ╔══════════════════════════════════════════╗
   ║   D O R O D   T E C H                     ║
   ║   node agent · vodorod                    ║
   ╚══════════════════════════════════════════╝
EOF
  printf '%s' "$C_RST"
}

# спиннер вокруг долгой команды (только TTY); в тихом режиме просто выполняет
run_spin(){ # run_spin "подпись" cmd...
  local label="$1"; shift
  if [ "$TTY" -eq 0 ]; then "$@"; return $?; fi
  local sp='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
  "$@" & local pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    i=$(( (i+1) % ${#sp} ))
    printf '\r  %s%s%s %s' "$C_B" "${sp:$i:1}" "$C_RST" "$label"
    sleep 0.1
  done
  wait "$pid"; local rc=$?
  if [ "$rc" -eq 0 ]; then printf '\r  %s✅%s %s\n' "$C_G" "$C_RST" "$label"
  else printf '\r  %s❌%s %s\n' "$C_R" "$C_RST" "$label"; fi
  return $rc
}

confirm(){ # confirm "вопрос"  → 0=да
  [ "$ASSUME_YES" -eq 1 ] && return 0
  [ "$TTY" -eq 0 ] && return 1     # не TTY и не --yes → считаем «нет» (безопасно)
  local ans; printf '  %s%s%s [y/N] ' "$C_BOLD" "$1" "$C_RST"; read -r ans
  [[ "$ans" =~ ^[yYдД] ]]
}

need_root(){ [ "$(id -u)" -eq 0 ] || { echo "нужен root" >&2; exit 1; }; }

# ---------- утилиты состояния ----------------------------------------------
# порты, которые РЕАЛЬНО слушает xray (rw-core). Это «правда» из панели.
live_xray_ports(){
  ss -tlnpH 2>/dev/null | awk '/rw-core|xray/{print $4}' | sed -E 's/.*:([0-9]+)$/\1/' | sort -un
}
# любой TCP-listen (для NODE_PORT/22 проверок)
port_listens(){ ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE ":$1\$"; }
# порты, разрешённые в ufw (просто число/tcp, Anywhere), в нашем управляемом диапазоне
ufw_allowed_inbounds(){
  ufw status 2>/dev/null | awk '/ALLOW/ && $1 ~ /^[0-9]+\/tcp$/ {split($1,a,"/"); print a[1]}' | sort -un
}
container_status(){ docker ps --filter name=remnanode --format '{{.Status}}' 2>/dev/null | head -1; }
compose_node_port(){ [ -f "$COMPOSE" ] && grep -oE 'NODE_PORT=[0-9]+' "$COMPOSE" | cut -d= -f2 | head -1; }
time_synced(){ timedatectl show -p NTPSynchronized --value 2>/dev/null; }

write_meta(){
  mkdir -p "$META_DIR"
  cat >"$META_FILE" <<EOF
# DOROD TECH node metadata (инвентарь для оркестратора)
PROVIDER=${PROVIDER}
LOCATION=${LOCATION}
NODE_PORT=${NODE_PORT}
PANEL_IP=${PANEL_IP}
NODE_IMAGE=${NODE_IMAGE}
EOF
}
load_meta(){ [ -f "$META_FILE" ] && . "$META_FILE" 2>/dev/null || true; }

# ============================================================================
#  INSTALL — чистый сервер → нода-клон
# ============================================================================
cmd_install(){
  need_root
  : "${SECRET_KEY:?нужен SECRET_KEY из панели (одинаковый для всех нод)}"
  : "${PANEL_IP:?нужен PANEL_IP (для firewall NODE_PORT)}"
  banner
  step "INSTALL · location=${LOCATION:-?} provider=${PROVIDER:-?} node_port=${NODE_PORT}"

  step "1/7 пакеты + синхронизация времени (критично для Reality/TLS)"
  export DEBIAN_FRONTEND=noninteractive
  run_spin "apt update+install" bash -c 'apt-get update -qq && apt-get install -y -qq curl ufw chrony jq ca-certificates >/dev/null'
  timedatectl set-ntp true 2>/dev/null || true
  systemctl enable --now chrony 2>/dev/null || systemctl enable --now systemd-timesyncd 2>/dev/null || true

  step "2/7 ядро: BBR + буферы + лимиты файлов"
  cat >/etc/sysctl.d/99-remnanode.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_mtu_probing = 1
fs.file-max = 1048576
net.ipv4.ip_forward = 1
EOF
  sysctl --system >/dev/null; ok "sysctl применён"
  grep -q "remnanode-nofile" /etc/security/limits.d/99-remnanode.conf 2>/dev/null || cat >/etc/security/limits.d/99-remnanode.conf <<'EOF'
# remnanode-nofile
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

  step "3/7 swap (если RAM < 1500MB и swap нет)"
  if [ "$(free -m | awk '/Mem/{print $2}')" -lt 1500 ] && ! swapon --show | grep -q .; then
    fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
    ok "swap 2G создан"
  else ok "swap не требуется / уже есть"; fi

  step "4/7 Docker"
  if ! command -v docker >/dev/null; then run_spin "установка docker" bash -c 'curl -fsSL https://get.docker.com | sh >/dev/null'; else ok "docker уже есть"; fi
  systemctl enable --now docker >/dev/null

  step "5/7 firewall (UFW): 22 всем · NODE_PORT только с панели · инбаунды"
  # на ЧИСТОЙ ноде reset допустим (трафика ещё нет). На живой — этим занимается doctor.
  ufw --force reset >/dev/null
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow 22/tcp >/dev/null
  ufw allow from "$PANEL_IP" to any port "$NODE_PORT" proto tcp >/dev/null
  for p in $INBOUND_PORTS; do ufw allow "${p}/tcp" >/dev/null; done
  ufw --force enable >/dev/null
  ok "ufw: 22, ${NODE_PORT}←${PANEL_IP}, [${INBOUND_PORTS}]"

  step "6/7 remnanode (docker, host-network)"
  mkdir -p "$NODE_DIR"
  cat >"$COMPOSE" <<EOF
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: ${NODE_IMAGE}
    restart: always
    network_mode: host
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      - NODE_PORT=${NODE_PORT}
      - SECRET_KEY=${SECRET_KEY}
EOF
  run_spin "docker compose up -d (тянет образ)" bash -c "cd '$NODE_DIR' && docker compose up -d >/dev/null 2>&1"
  write_meta

  step "7/7 проверка"
  sleep 4
  local cs; cs="$(container_status)"
  [ -n "$cs" ] && ok "контейнер: $cs" || bad "контейнер не запущен (docker logs remnanode)"
  if port_listens "$NODE_PORT"; then ok "NODE_PORT ${NODE_PORT} слушается (панель→нода)"; else warn "NODE_PORT ${NODE_PORT} пока не слушается"; fi
  say ""
  say "${C_DIM}Дальше: 1) в панели Nodes→Add address=<IP> port=${NODE_PORT}, тот же Config Profile."
  say "        2) DNS: ${LOCATION:-<loc>}.3to3.online A <IP> (TTL 60, серое облако).${C_RST}"

  local ip; ip="$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
  jset ok true; jset mode install; jset ip "$ip"; jset node_port "$NODE_PORT"
  jset container "${cs:-down}"; jset provider "$PROVIDER"; jset location "$LOCATION"
  json_flush
}

# ============================================================================
#  DOCTOR — живая нода: диагностика + безопасная починка
# ============================================================================
cmd_doctor(){
  need_root; load_meta
  banner
  local applymode="dry-run"; [ "$DO_APPLY" -eq 1 ] && applymode="apply"
  step "DOCTOR (${applymode}) · location=${LOCATION:-?} provider=${PROVIDER:-?}"

  local issues=0 fixed=0 NOT_IN_SERVICE=0

  # --- 1. контейнер --------------------------------------------------------
  local cs; cs="$(container_status)"
  if [ -n "$cs" ]; then ok "контейнер remnanode: $cs"
  else
    bad "контейнер remnanode не запущен"; issues=$((issues+1))
    if [ -f "$COMPOSE" ] && confirm "поднять контейнер (docker compose up -d)?"; then
      (cd "$NODE_DIR" && docker compose up -d >/dev/null 2>&1) && { ok "поднят"; fixed=$((fixed+1)); sleep 3; cs="$(container_status)"; }
    fi
  fi

  # --- 2. время ------------------------------------------------------------
  if [ "$(time_synced)" = "yes" ]; then ok "время: синхронизировано (NTP)"
  else
    warn "время НЕ синхронизировано (Reality может рваться)"; issues=$((issues+1))
    if confirm "включить NTP?"; then timedatectl set-ntp true 2>/dev/null && { ok "NTP включён"; fixed=$((fixed+1)); }; fi
  fi

  # --- 3. NODE_PORT: compose ↔ ufw ↔ listen --------------------------------
  local np; np="$(compose_node_port)"; np="${np:-$NODE_PORT}"
  if port_listens "$np"; then ok "NODE_PORT ${np}: слушается"
  else warn "NODE_PORT ${np}: не слушается (контейнер?)"; issues=$((issues+1)); fi
  if ufw status 2>/dev/null | grep -qE "\b${np}/tcp\b"; then ok "NODE_PORT ${np}: разрешён в ufw"
  else
    warn "NODE_PORT ${np}: НЕ разрешён в ufw${PANEL_IP:+ (панель $PANEL_IP не достучится)}"; issues=$((issues+1))
    if [ -n "$PANEL_IP" ] && confirm "открыть ${np} с ${PANEL_IP}?"; then
      ufw allow from "$PANEL_IP" to any port "$np" proto tcp >/dev/null && { ok "открыт"; fixed=$((fixed+1)); }
    fi
  fi

  # --- 3.5 СВЯЗЬ С ПАНЕЛЬЮ (главное: без неё нода бесполезна) ---------------
  # 2 признака: (а) панель держит соединение на NODE_PORT (established от PANEL_IP);
  #             (б) xray поднял инбаунды = получил Config Profile от панели.
  local live; live="$(live_xray_ports | tr '\n' ' ')"; live="${live% }"
  local panel_link=0
  if [ -n "$PANEL_IP" ] && ss -tnH state established 2>/dev/null | grep -q "$PANEL_IP"; then panel_link=1; fi
  if [ "$panel_link" -eq 1 ] || [ -n "$live" ]; then
    ok "связь с панелью: ЕСТЬ${live:+ (инбаунды: $live)}"
  else
    bad "связь с панелью: НЕТ — нода установлена, но панель к ней не подключена"
    say "     ${C_DIM}почему: не зарегистрирована в панели (Nodes→Add), либо NODE_PORT ${np} закрыт/не тот, либо панель лежит.${C_RST}"
    issues=$((issues+1)); NOT_IN_SERVICE=1
  fi

  # --- 4. СИНХРОНИЗАЦИЯ ufw С ЖИВЫМ xray (сердце доктора) -------------------
  # правда = порты, которые слушает xray (пришли из Config Profile панели).
  local allowed; allowed="$(ufw_allowed_inbounds | tr '\n' ' ')"; allowed="${allowed% }"
  if [ -z "$live" ]; then
    warn "xray не слушает инбаундов (нода не подключена к панели или профиль пуст)"
    say "     ${C_DIM}ufw трогать не буду — нет достоверной 'правды' о портах.${C_RST}"
  else
    say "     ${C_DIM}xray слушает: ${live}${C_RST}"
    say "     ${C_DIM}ufw разрешает: ${allowed:-—}${C_RST}"
    # 4a. открыть недостающие (xray слушает, ufw закрыл) — БЕЗОПАСНО (открытие)
    local p
    for p in $live; do
      if ! echo " $allowed " | grep -q " $p "; then
        warn "порт ${p}: xray слушает, но ufw закрыт → открыть"
        issues=$((issues+1))
        if [ "$DO_APPLY" -eq 1 ] && confirm "открыть ${p}/tcp?"; then
          ufw allow "${p}/tcp" >/dev/null && { ok "${p} открыт"; fixed=$((fixed+1)); }
        fi
      fi
    done
    # 4b. закрыть лишние (ufw разрешает, xray НЕ слушает) — ТОЛЬКО если не слушается сейчас
    for p in $allowed; do
      [ "$p" = "22" ] && continue
      [ "$p" = "$np" ] && continue
      if ! echo " $live " | grep -q " $p " && ! port_listens "$p"; then
        warn "порт ${p}: открыт в ufw, но xray не слушает (старый/лишний) → закрыть"
        issues=$((issues+1))
        if [ "$DO_APPLY" -eq 1 ] && confirm "закрыть ${p}/tcp? (никто не слушает — безопасно)"; then
          ufw delete allow "${p}/tcp" >/dev/null 2>&1 && { ok "${p} закрыт"; fixed=$((fixed+1)); }
        fi
      fi
    done
  fi

  # --- 5. дрейф метаданных -------------------------------------------------
  [ -f "$META_FILE" ] && ok "инвентарь: ${META_FILE}" || warn "нет ${META_FILE} (запусти install или задай PROVIDER/LOCATION)"

  # --- итог (честный вердикт по состоянию) ---------------------------------
  say ""
  local state
  if [ -z "$(container_status)" ]; then state="dead"; step "диагноз: нода МЁРТВА — контейнер не запущен ❌"
  elif [ "$NOT_IN_SERVICE" -eq 1 ]; then state="not_in_service"; step "диагноз: установлена, но НЕ В СТРОЮ — нет связи с панелью ❌ (зарегистрируй в панели)"
  elif [ "$issues" -eq 0 ]; then state="in_service"; step "диагноз: нода В СТРОЮ, здорова ✅"
  elif [ "$DO_APPLY" -eq 1 ]; then state="in_service"; step "в строю; исправлено ${fixed}/${issues}. Повтори doctor."
  else state="degraded"; step "в строю, но проблем: ${issues}. Запусти --apply чтобы починить."; fi

  jset ok true; jset mode doctor; jset state "$state"; jset issues "$issues"; jset fixed "$fixed"
  jset panel_link "$panel_link"; jset container "${cs:-down}"; jset node_port "${np}"
  jset live_ports "[$(echo "$live" | sed 's/ /,/g')]"
  jset provider "${PROVIDER:-}"; jset location "${LOCATION:-}"
  json_flush
  # для оркестратора: код возврата = кол-во незакрытых проблем (0 = здорова)
  [ "$DO_APPLY" -eq 1 ] && exit 0 || exit "$(( issues > 0 ? 3 : 0 ))"
}

# ============================================================================
#  INFO — машинный снимок (инвентарь для n8n)
# ============================================================================
cmd_info(){
  load_meta
  local cs np live
  cs="$(container_status)"; np="$(compose_node_port)"; np="${np:-$NODE_PORT}"
  live="$(live_xray_ports | tr '\n' ',' | sed 's/,$//')"
  if [ "$JSON" -eq 1 ]; then
    jset mode info; jset container "${cs:-down}"; jset node_port "$np"
    jset live_ports "[${live}]"; jset time_synced "$(time_synced)"
    jset provider "${PROVIDER:-}"; jset location "${LOCATION:-}"
    jset image "${NODE_IMAGE}"
    json_flush
  else
    banner
    printf '  provider ..... %s\n  location ..... %s\n  container .... %s\n  node_port .... %s\n  xray ports ... %s\n  time synced .. %s\n' \
      "${PROVIDER:-?}" "${LOCATION:-?}" "${cs:-down}" "$np" "${live:-—}" "$(time_synced)"
  fi
}

# ============================================================================
#  Автоопределение режима + запуск
# ============================================================================
if [ -z "$MODE" ]; then
  if [ -f "$COMPOSE" ]; then MODE="doctor"; else MODE="install"; fi
fi
case "$MODE" in
  install) cmd_install ;;
  doctor)  cmd_doctor ;;
  info)    cmd_info ;;
esac
