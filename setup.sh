#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

RAYLIB_VERSION="5.5"
RAYLIB_URL="https://github.com/raysan5/raylib/archive/refs/tags/${RAYLIB_VERSION}.tar.gz"
RAYLIB_DIR="lib/raylib-${RAYLIB_VERSION}"

STB_BASE_URL="https://raw.githubusercontent.com/nothings/stb/refs/heads/master"
STB_IMAGE_RESIZE_URL="${STB_BASE_URL}/stb_image_resize2.h"
STB_IMAGE_URL="${STB_BASE_URL}/stb_image.h"
INCLUDE_DIR="include"

for command in curl tar make cc install; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "Error: required command not found: $command" >&2
        exit 1
    fi
done

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

download_file() {
    local url=$1
    local destination=$2
    local temporary="${tmp_dir}/$(basename "$destination")"

    curl --fail --location --retry 3 --retry-delay 1 --retry-connrefused \
        --output "$temporary" "$url"
    install -m 0644 "$temporary" "$destination"
}

echo "FastTab Development Setup"
echo "========================="

mkdir -p "$INCLUDE_DIR" "$(dirname "$RAYLIB_DIR")"

if [[ ! -s "${INCLUDE_DIR}/stb_image_resize2.h" ]]; then
    echo "Downloading stb_image_resize2.h..."
    download_file "$STB_IMAGE_RESIZE_URL" "${INCLUDE_DIR}/stb_image_resize2.h"
fi

if [[ ! -s "${INCLUDE_DIR}/stb_image.h" ]]; then
    echo "Downloading stb_image.h..."
    download_file "$STB_IMAGE_URL" "${INCLUDE_DIR}/stb_image.h"
fi

if [[ ! -f "${RAYLIB_DIR}/lib/libraylib.a" ]]; then
    rm -rf "$RAYLIB_DIR"

    echo "Building raylib ${RAYLIB_VERSION} for $(uname -m)..."
    raylib_archive="${tmp_dir}/raylib.tar.gz"
    curl --fail --location --retry 3 --retry-delay 1 --retry-connrefused \
        --output "$raylib_archive" "$RAYLIB_URL"
    tar -xzf "$raylib_archive" -C "$tmp_dir"

    raylib_source="${tmp_dir}/raylib-${RAYLIB_VERSION}"
    make -C "${raylib_source}/src" \
        -j"${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}" \
        PLATFORM=PLATFORM_DESKTOP \
        RAYLIB_LIBTYPE=STATIC \
        GRAPHICS=GRAPHICS_API_OPENGL_33

    mkdir -p "${RAYLIB_DIR}/include" "${RAYLIB_DIR}/lib"
    install -m 0644 "${raylib_source}/src/libraylib.a" "${RAYLIB_DIR}/lib/libraylib.a"
    install -m 0644 \
        "${raylib_source}/src/raylib.h" \
        "${raylib_source}/src/raymath.h" \
        "${raylib_source}/src/rlgl.h" \
        "${RAYLIB_DIR}/include/"
fi

if [[ ! -f "${RAYLIB_DIR}/lib/libraylib.a" ]]; then
    echo "Error: raylib static library build failed" >&2
    exit 1
fi

echo "raylib installed at ${RAYLIB_DIR}"
echo "Setup complete. Build with: zig build -Doptimize=ReleaseSafe -Dcpu=baseline"
