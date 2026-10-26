#!/usr/bin/env bash
# Soty relay installer for macOS.
#
# The relay host is a Linux x86-64 binary, so macOS runs it in a small Docker
# container (Docker Desktop or Colima). Everything is user-level; if you run
# this script with sudo it drops privileges back to SUDO_USER.
#
#   ./scripts/install-relay-macos.sh
#   ./scripts/install-relay-macos.sh --install-docker       # brew + colima
#   ./scripts/install-relay-macos.sh --port 3100 \
#       --announce wss://relay.example.com/soty-ws
#   ./scripts/install-relay-macos.sh --uninstall [--purge]
#
set -euo pipefail

NAME="soty-host"
PORT=3100
LISTEN="0.0.0.0"
ANNOUNCE=""
VERSION=""
URL=""
DATA="${HOME}/Library/Application Support/Soty/relay"
INSTALL_DOCKER=0
VERIFY=1
NO_SERVICE=0
UNINSTALL=0
PURGE=0
PEER_ARGS=()

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }

usage() {
  cat <<'EOF'
Soty relay installer for macOS (Docker/Colima).

  ./scripts/install-relay-macos.sh
  ./scripts/install-relay-macos.sh --install-docker
  ./scripts/install-relay-macos.sh --port 3100 --announce wss://relay.example.com/soty-ws
  ./scripts/install-relay-macos.sh --uninstall [--purge]

Флаги:
  --port N               порт на macOS (default: 3100)
  --listen ADDR          адрес публикации порта (default: 0.0.0.0)
  --announce URL         публичный ws://…/ws или wss://… для invite
  --peer SPEC            пир федерации, можно повторять
  --seed SPEC            то же, что --peer
  --name NAME            имя контейнера (default: soty-host)
  --version X.Y.Z+N      конкретная версия (default: latest)
  --url URL              прямой URL на dtm_host.bin
  --data-dir PATH        каталог данных
  --install-docker       поставить docker + colima через Homebrew
  --no-verify            не проверять SHA-256 по GitHub API
  --no-service           только скачать и собрать образ
  --uninstall            остановить и удалить контейнер
  --purge                вместе с --uninstall удалить host.db
  -h, --help             эта справка
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    --listen) LISTEN="$2"; shift 2 ;;
    --announce) ANNOUNCE="$2"; shift 2 ;;
    --peer|--seed) PEER_ARGS+=("--peer" "$2"); shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --url) URL="$2"; shift 2 ;;
    --data-dir) DATA="$2"; shift 2 ;;
    --install-docker) INSTALL_DOCKER=1; shift ;;
    --no-verify) VERIFY=0; shift ;;
    --no-service) NO_SERVICE=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --purge) PURGE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "неизвестный флаг: $1 (--help)" ;;
  esac
done

[ "$(uname -s)" = "Darwin" ] || die "этот установщик только для macOS (Linux: install-relay.sh, Windows: install-relay-windows.ps1)"

if [ "$(id -u)" -eq 0 ]; then
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && [ -f "$0" ] && [ -r "$0" ]; then
    exec sudo -u "$SUDO_USER" -H bash "$0" "$@"
  fi
  die "macOS-установка не требует root; запусти без sudo"
fi

ARCH="$(uname -m)"
case "$ARCH" in
  arm64|x86_64) PLATFORM="linux/amd64" ;;
  *) die "неизвестная архитектура: $ARCH" ;;
esac

mkdir -p "$DATA/data" "$DATA/image"

# --- docker ------------------------------------------------------------------
docker_ready() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }

start_docker_daemon() {
  if command -v colima >/dev/null 2>&1; then
    log "запускаю colima"
    colima start
  elif [ -d "/Applications/Docker.app" ]; then
    log "запускаю Docker Desktop"
    open -a Docker
    i=0
    while [ "$i" -lt 60 ]; do
      docker info >/dev/null 2>&1 && return 0
      sleep 2
      i=$((i + 1))
    done
    return 1
  else
    return 1
  fi
}

if ! command -v docker >/dev/null 2>&1; then
  if [ "$INSTALL_DOCKER" -eq 1 ]; then
    command -v brew >/dev/null 2>&1 || die "нет Homebrew. Поставь Docker Desktop или Homebrew: https://brew.sh"
    log "устанавливаю docker и colima через Homebrew"
    brew install docker colima
    colima start
  else
    cat >&2 <<'EOF'
Docker не найден. Варианты:
  1) Docker Desktop: https://www.docker.com/products/docker-desktop/
  2) без admin: brew install docker colima && colima start
     (или повтори этот скрипт с --install-docker)
EOF
    exit 2
  fi
fi

docker info >/dev/null 2>&1 || start_docker_daemon || die "Docker daemon не запущен"

# --- paths -------------------------------------------------------------------
IMAGE="soty-host:local"
DOCKERFILE="$DATA/image/Dockerfile"
BIN="$DATA/image/dtm_host"
LOG="$DATA/host.log"

container_logs() {
  docker logs "$NAME" 2>&1 || true
  [ -f "$LOG" ] && cat "$LOG"
}

uninstall() {
  log "удаляю контейнер $NAME"
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker rmi "$IMAGE" >/dev/null 2>&1 || true
  rm -f "$DATA/image/dtm_host" "$DOCKERFILE"
  if [ "$PURGE" -eq 1 ]; then
    log "удаляю данные: $DATA"
    rm -rf "$DATA"
  else
    echo "    данные сохранены: $DATA (удалить: --purge)"
  fi
  echo "==> удалено"
  exit 0
}

[ "$UNINSTALL" -eq 1 ] && uninstall

# --- download ----------------------------------------------------------------
fetch() {
  local url="$1" dest="$2"
  curl -fL --retry 3 --connect-timeout 15 -o "$dest" "$url"
}

TAG=""
[ -n "$VERSION" ] && TAG="v${VERSION#v}"
if [ -z "$URL" ]; then
  if [ -n "$TAG" ]; then
    ENC_TAG="$(printf '%s' "$TAG" | sed 's/+/%2B/g')"
    URL="https://github.com/slavabars/soty/releases/download/$ENC_TAG/dtm_host.bin"
    API="https://api.github.com/repos/slavabars/soty/releases/tags/$ENC_TAG"
  else
    URL="https://github.com/slavabars/soty/releases/latest/download/dtm_host.bin"
    API="https://api.github.com/repos/slavabars/soty/releases/latest"
  fi
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
log "скачиваю $URL"
fetch "$URL" "$TMP/dtm_host" || die "не удалось скачать бинарник"
[ -s "$TMP/dtm_host" ] || die "скачался пустой файл"
MAGIC="$(head -c 4 "$TMP/dtm_host" | od -An -tx1 | tr -d ' \n')"
[ "$MAGIC" = "7f454c46" ] || die "это не ELF-бинарник Linux (получен не тот файл?)"

if [ "$VERIFY" -eq 1 ]; then
  DIGEST=""
  if [ -n "${API:-}" ]; then
    fetch "$API" "$TMP/release.json" 2>/dev/null || true
    if [ -s "$TMP/release.json" ]; then
      if command -v python3 >/dev/null 2>&1; then
        DIGEST="$(python3 - "$TMP/release.json" <<'PY' 2>/dev/null || true
import json, sys
d = json.load(open(sys.argv[1]))
for a in d.get('assets', []):
    if a.get('name') == 'dtm_host.bin':
        print((a.get('digest') or '').replace('sha256:', ''))
        break
PY
)"
      fi
      if [ -z "$DIGEST" ]; then
        DIGEST="$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"dtm_host.bin"[^}]*"digest"[[:space:]]*:[[:space:]]*"sha256:\([0-9a-f]*\)".*/\1/p' "$TMP/release.json" | head -1)"
      fi
    fi
  fi
  if [ -n "$DIGEST" ]; then
    ACTUAL="$(shasum -a 256 "$TMP/dtm_host" | awk '{print $1}')"
    [ "$ACTUAL" = "$DIGEST" ] || die "SHA-256 не совпал: $ACTUAL != $DIGEST"
    log "SHA-256 подтверждён: $ACTUAL"
  else
    echo "warning: не удалось получить SHA-256 из GitHub API, проверка пропущена" >&2
  fi
fi

# --- build image -------------------------------------------------------------
install -m 0755 "$TMP/dtm_host" "$BIN"
cat > "$DOCKERFILE" <<'EOF'
FROM --platform=linux/amd64 debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends libsqlite3-0 ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY dtm_host /usr/local/bin/dtm_host
ENTRYPOINT ["/usr/local/bin/dtm_host"]
EOF
log "собираю образ $IMAGE"
docker build --platform "$PLATFORM" -t "$IMAGE" "$DATA/image"

DEFAULT_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
ADDR="${ANNOUNCE:-ws://${DEFAULT_IP:-127.0.0.1}:$PORT/ws}"

if [ "$NO_SERVICE" -eq 1 ]; then
  echo "==> образ готов: $IMAGE"
  echo "    запуск вручную:"
  printf '    docker run -d --name %q --restart unless-stopped -p %q --mount type=bind,source=%q,target=/data %q --db /data/host.db --listen 0.0.0.0 --port 3100' \
    "$NAME" "$LISTEN:$PORT:3100" "$DATA/data" "$IMAGE"
  for a in "${PEER_ARGS[@]}"; do printf ' %q' "$a"; done
  echo
  exit 0
fi

# --- run ---------------------------------------------------------------------
docker rm -f "$NAME" >/dev/null 2>&1 || true
RUN_ARGS=(--db /data/host.db --listen 0.0.0.0 --port 3100)
[ -n "$ANNOUNCE" ] && RUN_ARGS+=(--announce "$ANNOUNCE")
RUN_ARGS+=("${PEER_ARGS[@]}")

log "запускаю контейнер $NAME"
docker run -d \
  --name "$NAME" \
  --restart unless-stopped \
  --platform "$PLATFORM" \
  -p "$LISTEN:$PORT:3100" \
  --mount "type=bind,source=$DATA/data,target=/data" \
  "$IMAGE" "${RUN_ARGS[@]}" >/dev/null

# --- invite ------------------------------------------------------------------
ED=""
i=0
while [ "$i" -lt 20 ]; do
  ED="$(container_logs | grep -Eo 'ed25519 [0-9a-f]{64}' | tail -1 | awk '{print $2}' || true)"
  [ -n "$ED" ] && break
  sleep 1
  i=$((i + 1))
done

urlencode() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"
  elif command -v jq >/dev/null 2>&1; then
    jq -rn --arg v "$1" '$v|@uri'
  else
    printf '%s' "$1" | sed 's/:/%3A/g; s#/#%2F#g; s/?/%3F/g; s/&/%26/g; s/=/%3D/g'
  fi
}

INVITE=""
[ -n "$ED" ] && INVITE="soty://host?addr=$(urlencode "$ADDR")&pk=$ED"

echo
echo "==> Soty relay установлен (macOS, Docker)"
echo "    образ     $IMAGE"
echo "    база      $DATA/data/host.db"
echo "    endpoint  $ADDR"
echo "    статус    docker ps --filter name=$NAME"
echo "    лог       docker logs -f $NAME"
echo "    стоп      docker stop $NAME"
if [ -n "$ED" ]; then
  echo "    ed25519   $ED"
  echo
  echo "    invite для клиентов:"
  echo "    $INVITE"
else
  echo "    ed25519   ещё не найден; проверь: docker logs $NAME"
fi
echo
echo "    не удаляй $DATA/data: в нём Ed25519-идентичность и пины клиентов"
