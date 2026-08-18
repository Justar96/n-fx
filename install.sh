#!/usr/bin/env bash
set -euo pipefail

readonly REPOSITORY="Justar96/n-fx"
readonly INSTALL_DIR="${N_FX_INSTALL_DIR:-${FX_INSTALL_DIR:-${HOME}/.local/bin}}"

TMP_DIR=""

fail() {
  printf 'n-fx installer: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [ -n "$TMP_DIR" ]; then
    rm -rf -- "$TMP_DIR"
  fi
}
trap cleanup EXIT

detect_platform() {
  local os arch

  case "$(uname -s)" in
    Linux) os="linux" ;;
    Darwin) os="macos" ;;
    *) fail "unsupported operating system: $(uname -s)" ;;
  esac

  case "$(uname -m)" in
    x86_64|amd64) arch="x86_64" ;;
    arm64|aarch64) arch="aarch64" ;;
    *) fail "unsupported architecture: $(uname -m)" ;;
  esac

  printf '%s-%s\n' "$os" "$arch"
}

download() {
  local url="$1" destination="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$destination"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$destination" "$url"
  else
    fail "curl or wget is required"
  fi
}

verify_checksum() {
  local archive="$1" checksum="$2"
  local expected actual
  expected="$(awk 'NR == 1 { print $1 }' "$checksum" | tr 'A-F' 'a-f')"
  if [[ ! "$expected" =~ ^[a-f0-9]{64}$ ]]; then
    fail "release checksum is malformed"
  fi

  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$archive" | awk '{ print $1 }')"
  elif command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 256 "$archive" | awk '{ print $1 }')"
  else
    fail "sha256sum or shasum is required"
  fi

  if [ "$actual" != "$expected" ]; then
    fail "release checksum verification failed"
  fi
}

release_base_url() {
  local requested_version="$1"

  if [ -z "$requested_version" ]; then
    printf 'https://github.com/%s/releases/latest/download\n' "$REPOSITORY"
    return
  fi

  if [[ "$requested_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    requested_version="v${requested_version}"
  fi
  if [[ ! "$requested_version" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    fail "version must look like v0.0.4 or 0.0.4"
  fi

  printf 'https://github.com/%s/releases/download/%s\n' "$REPOSITORY" "$requested_version"
}

main() {
  local platform asset base_url archive checksum staged_binary
  platform="$(detect_platform)"
  asset="fx-${platform}.tar.gz"
  base_url="$(release_base_url "${1:-}")"

  TMP_DIR="$(mktemp -d)"
  archive="$TMP_DIR/$asset"
  checksum="$TMP_DIR/$asset.sha256"

  printf 'downloading n-fx for %s\n' "$platform" >&2
  download "$base_url/$asset" "$archive"
  download "$base_url/$asset.sha256" "$checksum"
  verify_checksum "$archive" "$checksum"

  tar -xzf "$archive" -C "$TMP_DIR" fx
  [ -f "$TMP_DIR/fx" ] || fail "release archive does not contain fx"

  mkdir -p "$INSTALL_DIR"
  staged_binary="$INSTALL_DIR/.n-fx.$$"
  cp "$TMP_DIR/fx" "$staged_binary"
  chmod 755 "$staged_binary"
  mv -f "$staged_binary" "$INSTALL_DIR/fx"

  printf 'installed n-fx %s\n' "$INSTALL_DIR/fx" >&2
  case ":${PATH}:" in
    *":${INSTALL_DIR}:"*) ;;
    *) printf 'add %s to PATH to run fx\n' "$INSTALL_DIR" >&2 ;;
  esac
  printf '%s\n' "$INSTALL_DIR/fx"
}

main "$@"
