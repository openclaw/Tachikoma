#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || $(uname -s) != Darwin ]]; then
  echo "Usage: $0 <destination-directory> (macOS)" >&2
  exit 1
fi

destination=$1
download_dir=$(mktemp -d)
trap 'rm -rf "$download_dir"' EXIT
mkdir -p "$destination"

swiftformat_version=0.63.1
swiftlint_version=0.65.1

install_tool() {
  local name=$1 url=$2 checksum=$3
  local archive="$download_dir/$name.zip"
  curl --fail --location --silent --show-error --retry 3 "$url" -o "$archive"
  printf '%s  %s\n' "$checksum" "$archive" | shasum -a 256 --check
  unzip -q "$archive" -d "$download_dir/$name"
  install -m 755 "$download_dir/$name/$name" "$destination/$name"
  if [[ -f "$download_dir/$name/LICENSE" ]]; then
    install -m 644 "$download_dir/$name/LICENSE" "$destination/LICENSE.$name"
  fi
}

install_tool swiftformat \
  "https://github.com/nicklockwood/SwiftFormat/releases/download/$swiftformat_version/swiftformat.zip" \
  385ef1a263ba28685157b98c5536b9c9105e124518f28b7ef8a2bee4b167eaeb
install_tool swiftlint \
  "https://github.com/realm/SwiftLint/releases/download/$swiftlint_version/portable_swiftlint.zip" \
  c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0

installed_swiftformat=$("$destination/swiftformat" --version)
installed_swiftlint=$("$destination/swiftlint" version)
[[ $installed_swiftformat == "$swiftformat_version" ]]
[[ $installed_swiftlint == "$swiftlint_version" ]]
echo "Installed SwiftFormat $swiftformat_version and SwiftLint $swiftlint_version in $destination"
