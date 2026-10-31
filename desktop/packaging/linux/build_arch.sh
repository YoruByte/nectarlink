#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds an Arch Linux package (.pkg.tar.zst) for NectarLink Desktop:
#   dist/nectarlink-<version>-1-<arch>.pkg.tar.zst
# Installable with: sudo pacman -U <package>.pkg.tar.zst

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

VERSION="${VERSION:-$(awk -F'"' '/^version[[:space:]]*=[[:space:]]*"/ { print $2; exit }' "${REPO_ROOT}/Cargo.toml")}"
if [[ -z "${VERSION}" ]]; then
    echo "error: could not determine version from ${REPO_ROOT}/Cargo.toml" >&2
    exit 1
fi

ARCH="${ARCH:-$(uname -m)}"
case "${ARCH}" in
    x86_64|amd64) PKG_ARCH="x86_64" ;;
    aarch64|arm64) PKG_ARCH="aarch64" ;;
    *) echo "error: unsupported architecture ${ARCH}" >&2; exit 1 ;;
esac

# Locate Qt 6 qmake if available
if [[ -z "${QMAKE:-}" ]]; then
    if [[ -n "${QT_ROOT_DIR:-}" && -x "${QT_ROOT_DIR}/bin/qmake" ]]; then
        export QMAKE="${QT_ROOT_DIR}/bin/qmake"
    elif [[ -x "${REPO_ROOT}/.qt6-sysroot/6.12.0/gcc_64/bin/qmake" ]]; then
        export QMAKE="${REPO_ROOT}/.qt6-sysroot/6.12.0/gcc_64/bin/qmake"
    elif command -v qmake6 >/dev/null 2>&1; then
        export QMAKE="$(command -v qmake6)"
    elif command -v qmake >/dev/null 2>&1; then
        export QMAKE="$(command -v qmake)"
    fi
fi

BIN_PATH="${BIN_PATH:-${REPO_ROOT}/target/release/nectarlink-desktop}"
if [[ ! -f "${BIN_PATH}" ]]; then
    echo "Building nectarlink-desktop (release)..."
    (cd "${REPO_ROOT}" && cargo build --release -p nectarlink-desktop)
fi

STAGE_DIR="$(mktemp -d -t nectarlink_arch_XXXXXX)"
trap 'rm -rf "${STAGE_DIR}"' EXIT

PKG_ROOT="${STAGE_DIR}/pkg"
mkdir -p \
    "${PKG_ROOT}/usr/bin" \
    "${PKG_ROOT}/usr/lib/nectarlink" \
    "${PKG_ROOT}/usr/share/nectarlink" \
    "${PKG_ROOT}/usr/share/applications" \
    "${PKG_ROOT}/usr/share/metainfo" \
    "${PKG_ROOT}/usr/share/icons/hicolor/256x256/apps" \
    "${PKG_ROOT}/usr/share/icons/hicolor/512x512/apps" \
    "${PKG_ROOT}/usr/share/icons/hicolor/scalable/apps"

install -m 0755 "${BIN_PATH}" "${PKG_ROOT}/usr/lib/nectarlink/nectarlink-desktop"
for adapter in "$(dirname "${BIN_PATH}")"/libnectarlink-video-ffmpeg*.so; do
    [[ ! -f "${adapter}" ]] || install -m 0755 "${adapter}" "${PKG_ROOT}/usr/lib/nectarlink/"
done

cat > "${PKG_ROOT}/usr/bin/nectarlink-desktop" <<'EOF'
#!/usr/bin/env sh
if [ -d /usr/lib/nectarlink/lib ]; then
    export LD_LIBRARY_PATH="/usr/lib/nectarlink/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
    export QT_PLUGIN_PATH="/usr/lib/nectarlink/plugins${QT_PLUGIN_PATH:+:${QT_PLUGIN_PATH}}"
    export QML2_IMPORT_PATH="/usr/lib/nectarlink/qml${QML2_IMPORT_PATH:+:${QML2_IMPORT_PATH}}"
fi
exec /usr/lib/nectarlink/nectarlink-desktop "$@"
EOF
chmod 0755 "${PKG_ROOT}/usr/bin/nectarlink-desktop"

for qm in "$(dirname "${BIN_PATH}")"/nectarlink_*.qm; do
    if [[ -f "${qm}" ]]; then
        install -m 0644 "${qm}" "${PKG_ROOT}/usr/share/nectarlink/$(basename "${qm}")"
    fi
done

install -m 0644 "${SCRIPT_DIR}/nectarlink.desktop" "${PKG_ROOT}/usr/share/applications/nectarlink.desktop"
install -m 0644 "${SCRIPT_DIR}/org.nectarlink.desktop.metainfo.xml" "${PKG_ROOT}/usr/share/metainfo/org.nectarlink.desktop.metainfo.xml"

if [[ -f "${REPO_ROOT}/assets/brand/icon-512.png" ]]; then
    install -m 0644 "${REPO_ROOT}/assets/brand/icon-512.png" "${PKG_ROOT}/usr/share/icons/hicolor/512x512/apps/nectarlink.png"
    install -m 0644 "${REPO_ROOT}/assets/brand/icon-512.png" "${PKG_ROOT}/usr/share/icons/hicolor/256x256/apps/nectarlink.png"
fi
if [[ -f "${REPO_ROOT}/assets/brand/icon.svg" ]]; then
    install -m 0644 "${REPO_ROOT}/assets/brand/icon.svg" "${PKG_ROOT}/usr/share/icons/hicolor/scalable/apps/nectarlink.svg"
fi

# Bundle Qt runtime if non-system Qt is used
bundle_qt_runtime_if_needed() {
    local qmake_bin="${QMAKE:-}"
    if [[ -z "${qmake_bin}" || ! -x "${qmake_bin}" ]]; then
        return 0
    fi
    local qt_libs qt_plugins qt_qml
    qt_libs="$("${qmake_bin}" -query QT_INSTALL_LIBS 2>/dev/null || true)"
    qt_plugins="$("${qmake_bin}" -query QT_INSTALL_PLUGINS 2>/dev/null || true)"
    qt_qml="$("${qmake_bin}" -query QT_INSTALL_QML 2>/dev/null || true)"
    if [[ -z "${qt_libs}" || "${qt_libs}" == /usr/* ]]; then
        return 0
    fi

    echo "Bundling private Qt runtime from ${qt_libs} into /usr/lib/nectarlink..."
    local dest="${PKG_ROOT}/usr/lib/nectarlink"
    mkdir -p "${dest}/lib" "${dest}/plugins" "${dest}/qml"

    local pattern
    for pattern in \
        "libQt6Core.so*" \
        "libQt6Gui.so*" \
        "libQt6Widgets.so*" \
        "libQt6Qml*.so*" \
        "libQt6Quick*.so*" \
        "libQt6Network.so*" \
        "libQt6OpenGL.so*" \
        "libQt6Svg.so*" \
        "libQt6DBus.so*" \
        "libQt6XcbQpa.so*" \
        "libQt6WaylandClient.so*" \
        "libQt6WaylandEglClientHwIntegration.so*" \
        "libQt6WlShellIntegration.so*" \
        "libQt6ShaderTools.so*" \
        "libicui18n.so*" \
        "libicuuc.so*" \
        "libicudata.so*"
    do
        compgen -G "${qt_libs}/${pattern}" >/dev/null && cp -a "${qt_libs}"/${pattern} "${dest}/lib/" || true
    done

    if [[ -n "${qt_plugins}" && -d "${qt_plugins}" ]]; then
        local plug_dir
        for plug_dir in \
            platforms \
            platformthemes \
            wayland-decoration-client \
            wayland-graphics-integration-client \
            wayland-shell-integration \
            xcbglintegrations \
            imageformats \
            iconengines
        do
            if [[ -d "${qt_plugins}/${plug_dir}" ]]; then
                mkdir -p "${dest}/plugins/${plug_dir}"
                cp -a "${qt_plugins}/${plug_dir}"/* "${dest}/plugins/${plug_dir}/"
            fi
        done
    fi

    if [[ -n "${qt_qml}" && -d "${qt_qml}" ]]; then
        local qml_dir
        for qml_dir in \
            QtQuick \
            QtQml
        do
            if [[ -d "${qt_qml}/${qml_dir}" ]]; then
                mkdir -p "${dest}/qml/${qml_dir}"
                cp -a "${qt_qml}/${qml_dir}"/* "${dest}/qml/${qml_dir}/"
            fi
        done
    fi
}

bundle_qt_runtime_if_needed

# Calculate installed size
INSTALLED_SIZE="$(du -sb "${PKG_ROOT}" | awk '{print $1}')"

# Generate .PKGINFO for pacman
cat > "${PKG_ROOT}/.PKGINFO" <<EOF
pkgname = nectarlink-bin
pkgver = ${VERSION}-1
pkgdesc = Your Android phone and your PC, working as one.
url = https://github.com/YoruByte/nectarlink
builddate = $(date +%s)
packager = YoruByte <308026171+YoruByte@users.noreply.github.com>
size = ${INSTALLED_SIZE}
arch = ${PKG_ARCH}
license = GPL-3.0-or-later
depend = hicolor-icon-theme
depend = desktop-file-utils
depend = libx11
depend = wayland
depend = libxkbcommon
depend = dbus
depend = fontconfig
depend = freetype2
depend = libglvnd
depend = ffmpeg
provides = nectarlink
conflict = nectarlink
EOF

OUT_DIR="${OUT_DIR:-${REPO_ROOT}/dist}"
mkdir -p "${OUT_DIR}"
OUT_PKG="${OUT_DIR}/nectarlink-${VERSION}-1-${PKG_ARCH}.pkg.tar.zst"

# Build pacman package archive
(
    cd "${PKG_ROOT}"
    if command -v bsdtar >/dev/null 2>&1; then
        bsdtar -czf .MTREE --format=mtree \
            --options='!all,use-set,type,uid,gid,mode,time,size,md5,sha256,link' \
            * .PKGINFO
    fi

    # Pack files with root owner
    tar --sort=name --owner=0 --group=0 --numeric-owner -cf - .PKGINFO $([ -f .MTREE ] && echo .MTREE) usr \
        | zstd -c -T0 -19 > "${OUT_PKG}"
)

echo "Built ${OUT_PKG}"
