#!/usr/bin/env bash
# Standalone installer and updater for iNiR Files.
# Installs into ${XDG_DATA_HOME:-~/.local/share}/inir/files/<version> with an atomic `current` link (the same layout
# `inir update` manages), verifies SHA-256, and links ~/.local/bin/inir-files and the .desktop entry.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/snowarch/inir-files/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/snowarch/inir-files/main/install.sh | bash -s -- --default
set -euo pipefail

REPO="${INIR_FILES_REPO:-snowarch/inir-files}"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
BIN_DIR="${HOME}/.local/bin"
BASE="${DATA_HOME}/inir/files"
SET_DEFAULT=false
VERSION="${INIR_FILES_VERSION:-}"

for arg in "$@"; do
    case "$arg" in
        --default) SET_DEFAULT=true ;;
        --version=*) VERSION="${arg#--version=}" ;;
        -h|--help)
            cat <<'EOF'
Usage: install.sh [--default] [--version=X.Y.Z]
  --default         Also set iNiR Files as the default file manager (xdg-mime + D-Bus FileManager1)
  --version=X.Y.Z   Install a specific release version instead of the latest
EOF
            exit 0
            ;;
        *) echo "install.sh: unknown option: $arg" >&2; exit 1 ;;
    esac
done

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64|aarch64) ;;
    *) echo "install.sh: unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

for cmd in curl tar sha256sum; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "install.sh: $cmd is required" >&2; exit 1; }
done

if [ -z "$VERSION" ]; then
    VERSION="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\([^"]*\)".*/\1/p' | head -n 1)"
fi
[ -n "$VERSION" ] || { echo "install.sh: could not determine latest release version" >&2; exit 1; }

FILE="inir-files-${VERSION}-${ARCH}.tar.gz"
URL="https://github.com/${REPO}/releases/download/v${VERSION}/${FILE}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading iNiR Files v${VERSION} (${ARCH})..."
curl -fsSL --retry 2 -o "$TMP/$FILE" "$URL"
curl -fsSL --retry 2 -o "$TMP/${FILE}.sha256" "${URL}.sha256"

EXPECTED="$(awk '{print $1}' "$TMP/${FILE}.sha256")"
ACTUAL="$(sha256sum "$TMP/$FILE" | awk '{print $1}')"
if [ -z "$EXPECTED" ] || [ "$EXPECTED" != "$ACTUAL" ]; then
    echo "install.sh: checksum mismatch for $FILE" >&2
    exit 1
fi

DIR="${BASE}/${VERSION}"
mkdir -p "$BASE"
rm -rf "${DIR}.new"
mkdir -p "${DIR}.new"
tar -xzf "$TMP/$FILE" -C "${DIR}.new" --strip-components=1 --no-same-owner
printf '%s\n' "$ACTUAL" > "${DIR}.new/.sha256"
rm -rf "$DIR"
mv "${DIR}.new" "$DIR"

PREV="$(readlink "${BASE}/current" 2>/dev/null || true)"
PREV="${PREV##*/}"
ln -sfn "$VERSION" "${BASE}/current"
for old in "${BASE}"/*/; do
    [ -d "$old" ] || continue
    old="${old%/}"
    name="$(basename "$old")"
    if [ "$name" != "$VERSION" ] && [ "$name" != "$PREV" ] && [ "$name" != "current" ]; then
        rm -rf "$old"
    fi
done

mkdir -p "$BIN_DIR" "${DATA_HOME}/applications"
if [ ! -e "${BIN_DIR}/inir-files" ] && [ ! -L "${BIN_DIR}/inir-files" ] \
    || [ "$(readlink "${BIN_DIR}/inir-files" 2>/dev/null || true)" = "${BASE}/current/bin/inir-files" ]; then
    ln -sfn "${BASE}/current/bin/inir-files" "${BIN_DIR}/inir-files"
fi
install -Dm644 "${BASE}/current/share/applications/inir-files.desktop" "${DATA_HOME}/applications/inir-files.desktop"

if [ "$SET_DEFAULT" = true ]; then
    mkdir -p "${DATA_HOME}/dbus-1/services"
    # Named after the bus name, as D-Bus wants a session file; the user's directory comes ahead of /usr/share.
    sed "s|^Exec=.*|Exec=${BIN_DIR}/inir-files --service|" \
        "${BASE}/current/share/dbus-1/services/inir-files.FileManager1.service" \
        > "${DATA_HOME}/dbus-1/services/org.freedesktop.FileManager1.service"
    chmod 644 "${DATA_HOME}/dbus-1/services/org.freedesktop.FileManager1.service"
    rm -f "${DATA_HOME}/dbus-1/services/inir-files.FileManager1.service"
    if command -v xdg-mime >/dev/null 2>&1; then
        mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}"
        xdg-mime default inir-files.desktop inode/directory || true
    fi
fi

echo "Installed iNiR Files v${VERSION} -> ${BIN_DIR}/inir-files"
if ! command -v inir-files >/dev/null 2>&1; then
    echo "Note: add ${BIN_DIR} to your PATH to run 'inir-files' from a shell."
fi
