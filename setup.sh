#!/usr/bin/env bash
set -euo pipefail

RAYLIB_VERSION="5.5"
RAYLIB_URL="https://github.com/raysan5/raylib/releases/download/${RAYLIB_VERSION}/raylib-${RAYLIB_VERSION}_linux_amd64.tar.gz"
LIB_DIR="lib"
RAYLIB_DIR="${LIB_DIR}/raylib-${RAYLIB_VERSION}_linux_amd64"

STB_BASE_URL="https://raw.githubusercontent.com/nothings/stb/refs/heads/master"
STB_IMAGE_RESIZE_URL="${STB_BASE_URL}/stb_image_resize2.h"
STB_IMAGE_URL="${STB_BASE_URL}/stb_image.h"
INCLUDE_DIR="include"

for command in curl tar; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "Error: required command not found: $command" >&2
        exit 1
    fi
done

tmp_dir=$(mktemp -d)
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

mkdir -p "$INCLUDE_DIR" "$LIB_DIR"

if [[ ! -s "${INCLUDE_DIR}/stb_image_resize2.h" ]]; then
    echo "Downloading stb_image_resize2.h..."
    download_file "$STB_IMAGE_RESIZE_URL" "${INCLUDE_DIR}/stb_image_resize2.h"
fi

if [[ ! -s "${INCLUDE_DIR}/stb_image.h" ]]; then
    echo "Downloading stb_image.h..."
    download_file "$STB_IMAGE_URL" "${INCLUDE_DIR}/stb_image.h"
fi

if [[ ! -f "${RAYLIB_DIR}/lib/libraylib.a" ]]; then
    if [[ -e "$RAYLIB_DIR" ]]; then
        echo "Removing incomplete raylib installation: ${RAYLIB_DIR}"
        rm -rf "$RAYLIB_DIR"
    fi

    echo "Downloading raylib ${RAYLIB_VERSION}..."
    raylib_archive="${tmp_dir}/raylib.tar.gz"
    curl --fail --location --retry 3 --retry-delay 1 --retry-connrefused \
        --output "$raylib_archive" "$RAYLIB_URL"
    tar -xzf "$raylib_archive" -C "$LIB_DIR"
fi

if [[ ! -f "${RAYLIB_DIR}/lib/libraylib.a" ]]; then
    echo "Error: raylib static library installation failed" >&2
    exit 1
fi

echo "raylib installed at ${RAYLIB_DIR}"
echo "Setup complete. Build with: zig build -Doptimize=ReleaseSafe"
