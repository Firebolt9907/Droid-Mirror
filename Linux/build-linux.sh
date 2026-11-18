#!/usr/bin/env bash
# Builds DroidMirror for Linux into Linux/build and optionally installs it for
# the current user (~/.local). Requirements: BlueZ 5.62+, Rust 1.91+, meson,
# ninja, pkg-config, SDL3, FFmpeg (libavcodec/libavformat/libavutil/libswresample),
# libusb-1.0, D-Bus development headers, Python 3 with PyGObject, GTK 4 and
# libadwaita 1.5+.
#
#   Linux/build-linux.sh            build into Linux/build
#   Linux/build-linux.sh --install  build, then install for this user
#
# Stop any active mirror session before reinstalling: the running helper keeps
# executing its old binary until the session ends.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LINUX="$ROOT/Linux"
OUT="$LINUX/build"
INSTALL=0
[[ "${1:-}" == "--install" ]] && INSTALL=1

# Build quietly by default: lowest CPU/IO priority and a bounded number of jobs.
JOBS="${DROIDMIRROR_BUILD_JOBS:-2}"
export CARGO_BUILD_JOBS="$JOBS"
if [[ -z "${DROIDMIRROR_BUILD_UNTHROTTLED:-}" ]]; then
  renice -n 19 $$ >/dev/null 2>&1 || true
  ionice -c3 -p $$ >/dev/null 2>&1 || true
fi

need() { command -v "$1" >/dev/null || { echo "Missing $1. $2" >&2; exit 1; }; }
need cargo "Install Rust from your distribution or https://rustup.rs."
need pkg-config "Install pkg-config (pkgconf)."
need meson "Install meson (e.g. 'sudo pacman -S meson', 'sudo apt install meson' or 'pipx install meson')."
need ninja "Install ninja."
for lib in sdl3 libavcodec libavformat libavutil libswresample libusb-1.0 dbus-1; do
  pkg-config --exists "$lib" || { echo "Missing development package for $lib." >&2; exit 1; }
done
python3 - <<'PY' || { echo "Install PyGObject with GTK 4 and libadwaita 1.5+ (python-gobject, gtk4, libadwaita)." >&2; exit 1; }
import gi
gi.require_version("Gtk", "4.0"); gi.require_version("Adw", "1")
from gi.repository import Adw
assert (Adw.get_major_version(), Adw.get_minor_version()) >= (1, 5)
PY

mkdir -p "$OUT/resources"

echo "==> Bluetooth helper (BlueZ, Classic L2CAP + authenticated BLE + Iroh direct IP)"
cargo build --release --locked --manifest-path "$LINUX/helper/Cargo.toml"
install -m 755 "$LINUX/helper/target/release/droidmirror-bluetooth" "$OUT/droidmirror-bluetooth.new"
mv -f "$OUT/droidmirror-bluetooth.new" "$OUT/droidmirror-bluetooth"

echo "==> Renderer (DroidMirror's patched scrcpy client)"
CLIENT_BUILD="$OUT/scrcpy"
if [[ ! -f "$CLIENT_BUILD/build.ninja" ]]; then
  meson setup "$CLIENT_BUILD" "$ROOT/scrcpy-5.0" --buildtype=release \
    -Dcompile_server=false -Dportable=true -Dvideotoolbox=false
fi
meson compile -C "$CLIENT_BUILD" -j "$JOBS"
install -m 755 "$CLIENT_BUILD/app/scrcpy" "$OUT/droidmirror-renderer.new"
mv -f "$OUT/droidmirror-renderer.new" "$OUT/droidmirror-renderer"
install -m 644 "$LINUX/data/droidmirror.png" "$OUT/resources/scrcpy.png"
install -m 644 "$ROOT/scrcpy-5.0/app/data/disconnected.png" "$OUT/resources/disconnected.png"

echo "Built $OUT"
if [[ $INSTALL == 0 ]]; then
  echo "Run without installing: PYTHONPATH=$LINUX/app python3 -m droidmirror_linux"
  exit 0
fi

echo "==> Installing for $(id -un)"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
SHARE="$DATA/droidmirror"
BIN="$HOME/.local/bin"
mkdir -p "$SHARE/resources" "$BIN" "$DATA/applications" "$DATA/icons/hicolor/scalable/apps"
# Replace files by rename so a running session keeps its mapped binary intact.
for file in droidmirror-bluetooth droidmirror-renderer; do
  install -m 755 "$OUT/$file" "$SHARE/$file.new" && mv -f "$SHARE/$file.new" "$SHARE/$file"
done
cp -f "$OUT/resources/"* "$SHARE/resources/"
rm -rf "$SHARE/python.new" && cp -r "$LINUX/app" "$SHARE/python.new"
rm -rf "$SHARE/python" && mv "$SHARE/python.new" "$SHARE/python"
cat > "$BIN/droidmirror" <<EOF
#!/bin/sh
export DROIDMIRROR_HOME="$SHARE"
export PYTHONPATH="$SHARE/python\${PYTHONPATH:+:\$PYTHONPATH}"
exec python3 -m droidmirror_linux "\$@"
EOF
chmod 755 "$BIN/droidmirror"
install -m 644 "$LINUX/data/app.droidmirror.linux.svg" "$DATA/icons/hicolor/scalable/apps/app.droidmirror.linux.svg"
sed "s|@BIN@|$BIN/droidmirror|" "$LINUX/data/app.droidmirror.linux.desktop" > "$DATA/applications/app.droidmirror.linux.desktop"
command -v update-desktop-database >/dev/null && update-desktop-database "$DATA/applications" || true
echo "Installed. Launch DroidMirror from your app menu or run: droidmirror"
