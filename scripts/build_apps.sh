#!/usr/bin/env bash
# Собирает все приложения проекта Soty в build-artifacts/:
#   - dtm_host.app           — релей+трекер хост (dart compile exe)
#   - soty-release.apk       — релизный APK приложения
#   - soty-app-debug.apk     — отладочный APK
#   - soty-app-release.aab   — релизный app bundle
#   - soty_deviceA.apk       — debug-APK для e2e на эмуляторе A (bootstrap хост
#                              и SOTY_ADVERTISE_ADDR вшиты в бинарь)
#   - soty_deviceB.apk       — то же для эмулятора B
#   - soty-linux-x64/        — релизный Linux-десктоп bundle (x86_64)
#   - soty-linux-x64.tar.gz  — тот же bundle, упакованный для переноса
#
# Повторяет рецепт из build-artifacts/README.md. Анализ и тесты прогоняются
# внутри (через dtm_app/scripts/build_all.sh).
#
# Использование:
#   scripts/build_apps.sh                — собрать всё
#   scripts/build_apps.sh --skip-host    — без хоста
#   scripts/build_apps.sh --skip-device  — без device-e2e APK
#   scripts/build_apps.sh --skip-linux   — без Linux desktop bundle
#   scripts/build_apps.sh --device-host '<soty://host...>'   — другой bootstrap
#
# Переменные окружения:
#   SOTY_DEVICE_HOST      bootstrap-ссылка для device APK
#                         (default — продакшн-хост ws://85.198.75.50:3100)
#   SOTY_ADVERTISE_ADDR_A адрес, который A рекламирует в p2p (default .../5012)
#   SOTY_ADVERTISE_ADDR_B то же для B (default .../5011)
#
# Сборка Linux desktop требует dev-заголовков gstreamer (audioplayers_linux).
# На машине без sudo они лежат в локальном префиксе .build-deps/gstprefix —
# скрипт подхватывает его автоматически, если префикс есть.
set -euo pipefail

TOP="$(cd "$(dirname "$0")/.." && pwd)"
DTM_APP="$TOP/dtm_app"
HOST_DIR="$TOP/host"
OUT="$TOP/build-artifacts"

SKIP_HOST=0
SKIP_DEVICE=0
SKIP_LINUX=0
# Продакшн-хост: ws://85.198.75.50:3100/ws с серверным Ed25519 ключом для пина.
DEVICE_HOST="${SOTY_DEVICE_HOST:-ws://85.198.75.50:3100/ws?identity=fad55cc762eda3f6cbc9c6522030ce8ec29e87143c9c78f452038d24143a4e82}"
DEVICE_ADDR_A="${SOTY_ADVERTISE_ADDR_A:-/ip4/10.0.2.2/tcp/5012}"
DEVICE_ADDR_B="${SOTY_ADVERTISE_ADDR_B:-/ip4/10.0.2.2/tcp/5011}"

# JDK 17 — на этом хосте java-21 только JRE, без javac.
export PATH="/home/bars/development/flutter/bin:$PATH"
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64

# Локальный префикс с dev-файлами gstreamer (без sudo в систему их не поставить).
# pkg-config находит заголовки, LIBRARY_PATH — симлинки libgstapp-1.0.so и т.п.,
# без которых линковщик не видит -lgstapp-1.0/-lgstbase-1.0/-lgstreamer-1.0.
GST_PREFIX="$TOP/.build-deps/gstprefix"
if [ -d "$GST_PREFIX/usr/lib/x86_64-linux-gnu/pkgconfig" ]; then
  export PKG_CONFIG_PATH="$GST_PREFIX/usr/lib/x86_64-linux-gnu/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  export LIBRARY_PATH="$GST_PREFIX/usr/lib/x86_64-linux-gnu${LIBRARY_PATH:+:$LIBRARY_PATH}"
fi

# Версия вшивается в билд, а не читается из кода: экран «О приложении»
# показывает ровно то, что было собрано.
SOTY_VERSION="$(awk '/^version:/{print $2; exit}' "$DTM_APP/pubspec.yaml")"
[ -n "$SOTY_VERSION" ] || { echo "не нашёл version: в dtm_app/pubspec.yaml"; exit 2; }

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | sed '/^set -euo/d'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --skip-host) SKIP_HOST=1 ;;
    --skip-device) SKIP_DEVICE=1 ;;
    --skip-linux) SKIP_LINUX=1 ;;
    --device-host) shift; [ "$#" -gt 0 ] || { echo "нужен аргумент для --device-host"; exit 2; }; DEVICE_HOST="$1" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "неизвестная опция: $1"; usage; exit 2 ;;
  esac
  shift
done

mkdir -p "$OUT"

if [ "$SKIP_HOST" -eq 0 ]; then
  echo "== host: dart pub get =="
  (cd "$HOST_DIR" && dart pub get)
  echo "== host: dart compile exe =="
  (cd "$HOST_DIR" && dart compile exe bin/dtm_host.dart -o "$OUT/dtm_host.app")
else
  echo "== host: пропущено (--skip-host) =="
fi

echo "== app: полный регресс (analyze + tests + apk/aab) =="
"$DTM_APP/scripts/build_all.sh"

echo "== app: копирую артефакты в $OUT =="
APKD="$DTM_APP/build/app/outputs/flutter-apk"
cp "$APKD/app-debug.apk"  "$OUT/soty-app-debug.apk"
cp "$APKD/app-release.apk" "$OUT/soty-release.apk"
cp "$DTM_APP/build/app/outputs/bundle/release/app-release.aab" "$OUT/soty-app-release.aab"

if [ "$SKIP_DEVICE" -eq 0 ]; then
  echo "== app: device APK A (bootstrap: $DEVICE_HOST) =="
  (cd "$DTM_APP" && flutter build apk --debug --target-platform android-x64 --no-pub \
    --dart-define=SOTY_BOOTSTRAP_HOST="$DEVICE_HOST" \
    --dart-define=SOTY_ADVERTISE_ADDR="$DEVICE_ADDR_A" \
    --dart-define=SOTY_APP_VERSION="$SOTY_VERSION")
  cp "$APKD/app-debug.apk" "$OUT/soty_deviceA.apk"

  echo "== app: device APK B =="
  (cd "$DTM_APP" && flutter build apk --debug --target-platform android-x64 --no-pub \
    --dart-define=SOTY_BOOTSTRAP_HOST="$DEVICE_HOST" \
    --dart-define=SOTY_ADVERTISE_ADDR="$DEVICE_ADDR_B" \
    --dart-define=SOTY_APP_VERSION="$SOTY_VERSION")
  cp "$APKD/app-debug.apk" "$OUT/soty_deviceB.apk"
else
  echo "== app: device APK пропущены (--skip-device) =="
fi

if [ "$SKIP_LINUX" -eq 0 ]; then
  echo "== app: linux x64 release =="
  (cd "$DTM_APP" && flutter build linux --release --no-pub \
    --dart-define=SOTY_APP_VERSION="$SOTY_VERSION")

  # Копируем bundle целиком (бинарь + lib/ + data/flutter_assets), поэтому
  # сначала чистим каталог: старые файлы иначе переживут новую сборку.
  rm -rf "$OUT/soty-linux-x64" "$OUT/soty-linux-x64.tar.gz"
  cp -r "$DTM_APP/build/linux/x64/release/bundle" "$OUT/soty-linux-x64"
  tar -czf "$OUT/soty-linux-x64.tar.gz" -C "$OUT" soty-linux-x64
else
  echo "== app: linux desktop пропущен (--skip-linux) =="
fi

echo
echo "Артефакты в $OUT:"
ls -la "$OUT"