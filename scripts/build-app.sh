#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
  cat <<'USAGE'
Usage: bash scripts/build-app.sh
       bash scripts/build-app.sh --universal --inputs DIR --scratch DIR --output PATH.app

Without arguments, assemble the existing native .build/release/LocalDictation
for local development (make app). Universal mode builds both app architectures,
bundles arm64/whisper-cli, x86_64/whisper-cli, ggml-base.en.bin from DIR,
and signs the runtime before the app. Use release.sh to verify pinned inputs.
Universal output must not exist; output and scratch must be outside the repo.
USAGE
}

if [[ "${1:-}" == --help && $# == 1 ]]; then usage; exit 0; fi
# Shared, side-effect-free bundle validation; its CLI runs only when executed.
source "$ROOT_DIR/scripts/release-smoke-test.sh"

if [[ $# == 0 ]]; then
  [[ -x "$ROOT_DIR/.build/release/LocalDictation" ]] || release_fail 'Run make build first.'
  work="$(mktemp -d "$ROOT_DIR/.build/app.XXXXXX")"
  trap 'rm -rf "$work"' EXIT
  app="$work/LocalDictation.app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$ROOT_DIR/.build/release/LocalDictation" "$app/Contents/MacOS/LocalDictation"
  cp "$ROOT_DIR/Info.plist" "$app/Contents/Info.plist"
  # An ad-hoc signature is identified by a hash of the binary, so macOS drops every
  # granted permission on each rebuild. Sign with the development certificate when
  # it exists; see scripts/create-signing-identity.sh.
  identity="${LOCALDICTATION_SIGN_IDENTITY:-Local Dictation Dev}"
  if ! security find-identity -v -p codesigning | grep -q "\"$identity\""; then
    identity=-
    echo 'Warning: signing ad-hoc; macOS will forget this app'\''s permissions on the next rebuild.' >&2
    echo '         Run: bash scripts/create-signing-identity.sh' >&2
  fi
  codesign --force --sign "$identity" --identifier local.muxin.LocalDictation "$app"
  codesign --verify --strict "$app"
  # Preserve an existing development bundle until the fresh one has verified.
  if [[ -e "$ROOT_DIR/LocalDictation.app" || -L "$ROOT_DIR/LocalDictation.app" ]]; then
    mv "$ROOT_DIR/LocalDictation.app" "$work/previous.app"
  fi
  mv "$app" "$ROOT_DIR/LocalDictation.app"
  echo "Built $ROOT_DIR/LocalDictation.app (native development build)"
  exit 0
fi

[[ "${1:-}" == --universal ]] || { usage >&2; exit 2; }
shift
inputs= scratch= output=
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || release_fail "Missing value for $1"
  case "$1" in
    --inputs) [[ -z "$inputs" ]] || release_fail 'Duplicate --inputs'; inputs="$2" ;;
    --scratch) [[ -z "$scratch" ]] || release_fail 'Duplicate --scratch'; scratch="$2" ;;
    --output) [[ -z "$output" ]] || release_fail 'Duplicate --output'; output="$2" ;;
    *) release_fail "Unknown argument: $1" ;;
  esac
  shift 2
done
[[ -n "$inputs" && -n "$scratch" && -n "$output" ]] || release_fail 'Provide --inputs, --scratch, and --output.'
release_external_path "$scratch"
release_external_path "$output"
[[ "$output" == *.app && ! -e "$output" && ! -L "$output" ]] || release_fail 'Output must be a new .app path.'
release_archs "$inputs/arm64/whisper-cli" arm64
release_archs "$inputs/x86_64/whisper-cli" x86_64
[[ -s "$inputs/ggml-base.en.bin" && -f "$inputs/ggml-base.en.bin" ]] || release_fail 'Missing English model.'
mkdir -p "$scratch"
work="$(mktemp -d "$scratch/build-app.XXXXXX")"
trap 'rm -rf "$work"' EXIT
app="$work/LocalDictation.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
for arch in arm64 x86_64; do
  MACOSX_DEPLOYMENT_TARGET=14.0 CLANG_MODULE_CACHE_PATH="$work/cache-$arch" \
    swift build --package-path "$ROOT_DIR" --scratch-path "$work/$arch" \
      --arch "$arch" -c release --product LocalDictation --disable-automatic-resolution
  bin_dir="$(swift build --package-path "$ROOT_DIR" --scratch-path "$work/$arch" \
    --arch "$arch" -c release --show-bin-path --disable-automatic-resolution)"
  cp "$bin_dir/LocalDictation" "$work/LocalDictation-$arch"
  release_archs "$work/LocalDictation-$arch" "$arch"
done
lipo -create "$work/LocalDictation-arm64" "$work/LocalDictation-x86_64" \
  -output "$app/Contents/MacOS/LocalDictation"
lipo -create "$inputs/arm64/whisper-cli" "$inputs/x86_64/whisper-cli" \
  -output "$app/Contents/Resources/whisper-cli"
chmod 755 "$app/Contents/MacOS/LocalDictation" "$app/Contents/Resources/whisper-cli"
cp "$inputs/ggml-base.en.bin" "$app/Contents/Resources/ggml-base.en.bin"
cp "$ROOT_DIR/THIRD-PARTY-NOTICES.md" "$app/Contents/Resources/THIRD-PARTY-NOTICES.md"
cp "$ROOT_DIR/Info.plist" "$app/Contents/Info.plist"
release_system_dependencies "$app/Contents/MacOS/LocalDictation"
release_system_dependencies "$app/Contents/Resources/whisper-cli"
codesign --force --sign - "$app/Contents/Resources/whisper-cli"
codesign --force --sign - --identifier local.muxin.LocalDictation "$app"
release_validate_app "$app"
mkdir -p "$(dirname "$output")"
mv "$app" "$output"
echo "Built $output (universal, ad-hoc signed; not notarized)"
