#!/usr/bin/env bash
# Which Soty (dtm_app) for Linux desktop on Ubuntu.
# Run me as root:  sudo scripts/linux-build-setup.sh
set -euo pipefail

echo "== Linux desktop build toolchain for Flutter 3.32 =="
apt-get update
apt-get install -y \
  clang \
  cmake \
  ninja-build \
  pkg-config \
  libgtk-3-dev \
  liblzma-dev

echo "== verify =="
clang --version | head -1
cmake --version | head -1
ninja --version
pkg-config --exists gtk+-3.0 && echo "GTK3 dev: OK"