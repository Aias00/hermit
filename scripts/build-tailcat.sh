#!/usr/bin/env bash
# Build one Tailcat + Tailscale C ABI/runtime. Requires Xcode and Go 1.27.3.
# Generated source, caches and logs stay under ignored build/tailcat.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE="$ROOT/Packages/TailcatSSH"
WORK="$ROOT/build/tailcat"
REVISION=52fbad323e9d352f1febb623e0975368e9a8cbdd
SOURCE_SHA256=7b936da24a60e1619a5f8ee4859c8e5cdaadca0231e66edb9a7ff6f1214c8943
GO_VERSION=go1.27.3
SOURCE="$WORK/combined-source/tailcat-$REVISION"
ARCHIVE="$WORK/native-source/tailcat-$REVISION.tar.gz"
OUTPUT="$PACKAGE/Artifacts/CTailcat.xcframework"

if [[ "${1:-}" == --help ]]; then
  echo "Usage: scripts/build-tailcat.sh"
  echo "Builds iOS 18 arm64, iOS Simulator 18 arm64, and macOS 14 arm64."
  echo "Output: Packages/TailcatSSH/Artifacts/CTailcat.xcframework"
  exit 0
fi
[[ $# == 0 ]] || { echo "Unexpected arguments; use --help." >&2; exit 2; }
[[ "$(uname -s)" == Darwin ]] || { echo "Xcode on macOS is required." >&2; exit 1; }
[[ "$(uname -m)" == arm64 ]] || {
  echo "This build currently supports Apple Silicon hosts and arm64 slices only." >&2; exit 1;
}
for program in go xcrun xcodebuild python3 curl shasum; do
  command -v "$program" >/dev/null || { echo "Missing $program" >&2; exit 1; }
done
export GOTOOLCHAIN="$GO_VERSION"
[[ "$(go env GOVERSION)" == "$GO_VERSION" ]] || { echo "Go $GO_VERSION is required." >&2; exit 1; }
mkdir -p "$WORK/native-source" "$WORK/slices" "$PACKAGE/Artifacts"

if [[ ! -f "$ARCHIVE" ]]; then
  curl --fail --location --retry 3 \
    "https://codeload.github.com/tailscale/tailcat/tar.gz/$REVISION" \
    --output "$ARCHIVE.download"
  mv "$ARCHIVE.download" "$ARCHIVE"
fi
[[ "$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')" == "$SOURCE_SHA256" ]] || {
  echo "Tailcat source checksum mismatch: $ARCHIVE" >&2; exit 1;
}
# A fresh tree makes every source patch explicit and reproducible. Never mutate
# the upstream download or any previously built product while staging.
rm -rf "$SOURCE"
mkdir -p "$SOURCE"
tar -xzf "$ARCHIVE" -C "$SOURCE" --strip-components=1
cmp "$PACKAGE/Native/tailcat.h" "$SOURCE/cmd/libtailcat/tailcat.h"
TAILSCALE_MODULE="$(go -C "$SOURCE" list -m -f '{{.Dir}}' tailscale.com)"
# Go intentionally forbids overlays inside GOMODCACHE. Clone the immutable,
# checksum-verified dependency into disposable build space, then use a relative
# replacement (no developer filesystem paths in embedded Go build metadata).
TAILSCALE_SOURCE="$WORK/combined-source/tailscale"
if [[ -d "$TAILSCALE_SOURCE" ]]; then chmod -R u+w "$TAILSCALE_SOURCE"; fi
rm -rf "$TAILSCALE_SOURCE"
cp -cR "$TAILSCALE_MODULE" "$TAILSCALE_SOURCE"
go -C "$SOURCE" mod edit -replace=tailscale.com=../tailscale
python3 "$PACKAGE/Native/stage-overlay.py" "$SOURCE" "$TAILSCALE_SOURCE"
GO_OVERLAY="$SOURCE/moshpit-overlay.json"
TAGS="$(cat "$PACKAGE/Native/build-tags.txt")"

echo "Testing the combined native runtime"
go -C "$SOURCE" test -overlay="$GO_OVERLAY" -mod=readonly -race -tags="$TAGS" ./internal/capi

build_slice() {
  local name="$1" sdk="$2" goos="$3" target="$4"
  local output="$WORK/slices/$name" sysroot compiler
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  compiler="$(xcrun --sdk "$sdk" --find clang)"
  mkdir -p "$output/Headers"
  cp "$PACKAGE/Native/tailcat.h" "$output/Headers/tailcat.h"
  cp "$PACKAGE/Native/moshpit_tailscale.h" "$output/Headers/moshpit_tailscale.h"
  cp "$PACKAGE/Native/module.modulemap" "$output/Headers/module.modulemap"
  echo "Building Tailcat $name"
  env CGO_ENABLED=1 GOOS="$goos" GOARCH=arm64 CC="$compiler" \
    CGO_CFLAGS="-isysroot $sysroot -target $target" \
    CGO_LDFLAGS="-isysroot $sysroot -target $target" \
    go -C "$SOURCE" build -overlay="$GO_OVERLAY" -mod=readonly -trimpath -buildvcs=false \
      -tags="$TAGS" -ldflags='-s -w' -buildmode=c-archive \
      -o "$output/libtailcat.a" ./cmd/libtailcat
  env CGO_ENABLED=1 GOOS="$goos" GOARCH=arm64 CC="$compiler" \
    CGO_CFLAGS="-isysroot $sysroot -target $target" \
    CGO_LDFLAGS="-isysroot $sysroot -target $target" \
    go -C "$SOURCE" list -overlay="$GO_OVERLAY" -mod=readonly -tags="$TAGS" -deps \
      -f '{{if .Module}}{{.Module.Path}}|{{.Module.Version}}|{{.Module.Dir}}|{{.Dir}}{{end}}' \
      ./cmd/libtailcat > "$output/modules.txt"
  # Every slice must link as a C consumer, rather than only produce an archive.
  "$compiler" -isysroot "$sysroot" -target "$target" \
    -I "$output/Headers" "$SOURCE/cmd/libtailcat/testdata/smoke.c" \
    "$output/libtailcat.a" -framework CoreFoundation -framework Security \
    -framework SystemConfiguration -lresolv \
    -o "$output/c-smoke"
  "$compiler" -isysroot "$sysroot" -target "$target" \
    -I "$output/Headers" "$PACKAGE/Native/tailscale-smoke.c" \
    "$output/libtailcat.a" -framework CoreFoundation -framework Security \
    -framework SystemConfiguration -lresolv -o "$output/tailscale-smoke"
}

build_slice ios-arm64 iphoneos ios arm64-apple-ios18.0
build_slice ios-arm64-simulator iphonesimulator ios arm64-apple-ios18.0-simulator
build_slice macos-arm64 macosx darwin arm64-apple-macos14.0
if [[ "$(uname -m)" == arm64 ]]; then
  "$WORK/slices/macos-arm64/c-smoke"
  "$WORK/slices/macos-arm64/tailscale-smoke"
fi
python3 "$PACKAGE/Native/collect-licenses.py" "$PACKAGE/Native" \
  "$WORK/slices/ios-arm64/modules.txt" \
  "$WORK/slices/ios-arm64-simulator/modules.txt" \
  "$WORK/slices/macos-arm64/modules.txt"
mkdir -p "$ROOT/Moshpit/Resources/ThirdParty"
cp "$PACKAGE/Native/THIRD-PARTY-NOTICES.txt" "$ROOT/Moshpit/Resources/ThirdParty/tailcat-licenses.txt"

# Build to a disposable path so an unsuccessful build leaves the last artifact intact.
STAGING="$WORK/CTailcat.xcframework"
rm -rf "$STAGING"
xcodebuild -create-xcframework \
  -library "$WORK/slices/ios-arm64/libtailcat.a" -headers "$WORK/slices/ios-arm64/Headers" \
  -library "$WORK/slices/ios-arm64-simulator/libtailcat.a" -headers "$WORK/slices/ios-arm64-simulator/Headers" \
  -library "$WORK/slices/macos-arm64/libtailcat.a" -headers "$WORK/slices/macos-arm64/Headers" \
  -output "$STAGING"
rm -rf "$OUTPUT"
mv "$STAGING" "$OUTPUT"
python3 "$PACKAGE/Native/write-build-info.py" "$OUTPUT" "$REVISION" "$SOURCE_SHA256"
echo "Built $OUTPUT"
