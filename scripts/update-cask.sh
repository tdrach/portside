#!/bin/zsh
# Point the Homebrew cask at the current version's DMG. Run after
# `make release` and after the GitHub release exists.
set -euo pipefail
cd "$(dirname "$0")/.."

TAP="${TAP_DIR:-../homebrew-tap}"
VERSION=$(sed -n 's/.*current = "\(.*\)".*/\1/p' Sources/Portside/Version.swift)
DMG="dist/Portside-${VERSION}.dmg"

[[ -f "$DMG" ]] || { echo "ERROR: $DMG not built"; exit 1; }
[[ -d "$TAP/Casks" ]] || { echo "ERROR: tap not found at $TAP"; exit 1; }

SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
sed -i '' \
	-e "s/^  version \".*\"/  version \"${VERSION}\"/" \
	-e "s/^  sha256 \".*\"/  sha256 \"${SHA}\"/" \
	"$TAP/Casks/portside.rb"

cd "$TAP"
git add Casks/portside.rb
git commit -q -m "portside ${VERSION}"
git push origin main
echo "cask → ${VERSION} (${SHA})"
