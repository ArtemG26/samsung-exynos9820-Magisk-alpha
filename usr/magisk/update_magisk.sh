#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
VER_FILE="$DIR/magisk_version"
ZIP_FILE="$DIR/magisk.zip"

ver="$(cat "$VER_FILE" 2>/dev/null || echo -n 'none')"

pick_url() {
    local req="${1:-}"

    if [ "$req" = "canary" ]; then
        echo "canary|https://github.com/topjohnwu/magisk-files/raw/canary/app-debug.apk"
        return
    fi

    if [ "$req" = "alpha" ]; then
        echo "30700|https://github.com/vvb2060/Magisk/releases/download/30700/app-release.apk"
        return
    fi

    local nver dash
    dash='-'

    if [ -z "$req" ]; then
        nver="$(curl -fsSL https://github.com/topjohnwu/Magisk/releases \
            | grep -m 1 -Poe 'Magisk v[\d.]+' | cut -d ' ' -f 2)"
    else
        nver="$req"
    fi

    if [ "$nver" = "v26.3" ]; then
        dash='.'
    fi

    echo "${nver}|https://github.com/topjohnwu/Magisk/releases/download/${nver}/Magisk${dash}${nver}.apk"
}

cleanup_outputs() {
    rm -f \
        "$DIR/magiskinit" \
        "$DIR/magisk32" "$DIR/magisk64" \
        "$DIR/magisk32.xz" "$DIR/magisk64.xz" \
        "$DIR/stub" "$DIR/stub.xz"
    rm -rf "$DIR/lib" "$DIR/assets" "$DIR/arm"
}

zip_list() {
    unzip -Z1 "$ZIP_FILE"
}

first_match() {
    local pat
    for pat in "$@"; do
        local hit=""
        hit="$(zip_list | grep -E -m 1 "$pat" || true)"
        if [ -n "$hit" ]; then
            echo "$hit"
            return 0
        fi
    done
    return 1
}

extract_raw() {
    local entry="$1"
    local out="$2"
    unzip -p "$ZIP_FILE" "$entry" > "$out"
}

make_xz() {
    local src="$1"
    xz --force --check=crc32 "$src"
}

download_apk() {
    local url="$1"
    curl -fsSL -L -o "$ZIP_FILE" "$url"
}

extract_payloads() {
    local magiskinit_entry=""
    local magisk32_entry=""
    local magisk64_entry=""
    local stub_xz_entry=""
    local stub_apk_entry=""

    # 1) Old legacy layout
    if zip_list | grep -Fxq "arm/magiskinit64"; then
        extract_raw "arm/magiskinit64" "$DIR/magiskinit"
        : > "$DIR/magisk32.xz"
        : > "$DIR/magisk64.xz"
        return 0
    fi

    # 2) magiskinit
    magiskinit_entry="$(first_match \
        '^lib/arm64-v8a/libmagiskinit\.so$' \
        '^lib/armeabi-v7a/libmagiskinit\.so$' \
        '^.*/libmagiskinit\.so$' \
        '^assets/magiskinit$' \
        '^.*/magiskinit64$' \
        '^.*/magiskinit$' || true)"

    [ -n "$magiskinit_entry" ] || {
        echo "ERROR: magiskinit not found in APK" >&2
        return 11
    }

    extract_raw "$magiskinit_entry" "$DIR/magiskinit"

    # 3) Preferred new layout: *.xz payloads
    magisk32_entry="$(first_match \
        '^assets/magisk32\.xz$' \
        '^lib/armeabi-v7a/magisk32\.xz$' \
        '^.*/magisk32\.xz$' \
        '^lib/armeabi-v7a/libmagisk32\.so$' \
        '^.*/libmagisk32\.so$' || true)"

    magisk64_entry="$(first_match \
        '^assets/magisk64\.xz$' \
        '^lib/arm64-v8a/magisk64\.xz$' \
        '^.*/magisk64\.xz$' \
        '^lib/arm64-v8a/libmagisk64\.so$' \
        '^.*/libmagisk64\.so$' || true)"

    stub_xz_entry="$(first_match \
        '^assets/stub\.xz$' \
        '^.*/stub\.xz$' || true)"

    stub_apk_entry="$(first_match \
        '^assets/stub\.apk$' \
        '^.*/stub\.apk$' || true)"

    # 4) magisk32
    if [ -n "$magisk32_entry" ]; then
        case "$magisk32_entry" in
            *.xz)
                extract_raw "$magisk32_entry" "$DIR/magisk32.xz"
                ;;
            *.so)
                extract_raw "$magisk32_entry" "$DIR/magisk32"
                make_xz "$DIR/magisk32"
                mv -f "$DIR/magisk32.xz" "$DIR/magisk32.xz"
                ;;
        esac
    else
        : > "$DIR/magisk32.xz"
    fi

    # 5) magisk64
    if [ -n "$magisk64_entry" ]; then
        case "$magisk64_entry" in
            *.xz)
                extract_raw "$magisk64_entry" "$DIR/magisk64.xz"
                ;;
            *.so)
                extract_raw "$magisk64_entry" "$DIR/magisk64"
                make_xz "$DIR/magisk64"
                mv -f "$DIR/magisk64.xz" "$DIR/magisk64.xz"
                ;;
        esac
    else
        : > "$DIR/magisk64.xz"
    fi

    # 6) stub
    if [ -n "$stub_xz_entry" ]; then
        extract_raw "$stub_xz_entry" "$DIR/stub.xz"
    elif [ -n "$stub_apk_entry" ]; then
        extract_raw "$stub_apk_entry" "$DIR/stub"
        make_xz "$DIR/stub"
        mv -f "$DIR/stub.xz" "$DIR/stub.xz"
    fi
}

main() {
    local req="${1:-}"
    local picked nver magisk_link

    picked="$(pick_url "$req")"
    nver="${picked%%|*}"
    magisk_link="${picked#*|}"

    if [ -n "$nver" ] && { [ "$nver" != "$ver" ] || [ ! -f "$DIR/magiskinit" ] || [ "$req" = "canary" ] || [ "$req" = "alpha" ]; }; then
        echo "Updating Magisk from $ver to $nver"
        echo "Source: $magisk_link"

        cleanup_outputs
        download_apk "$magisk_link"
        extract_payloads

        echo -n "$nver" > "$VER_FILE"
        rm -f "$ZIP_FILE"
        touch "$DIR/initramfs_list"
    else
        echo "Nothing to be done: Magisk version $nver"
    fi
}

main "${1:-}"
