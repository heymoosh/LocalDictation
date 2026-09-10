#!/usr/bin/env bash
# Builds the two self-contained `whisper-cli` executables that release.sh expects
# as pinned inputs, from a whisper.cpp source checkout you supply.
#
# Why this exists: an ordinary Homebrew `whisper-cli` links three Homebrew dylibs
# and carries one architecture, so it fails both the system-dependency contract in
# release-smoke-test.sh and the universal requirement in build-app.sh. A bundle
# built around it would break on any Mac without the same Homebrew installation.
# The flags below link whisper and ggml statically and embed the Metal shaders, so
# each executable needs nothing but Apple's own frameworks.
#
# Nothing is downloaded: --source is a checkout you cloned and pinned yourself,
# which keeps provenance with you exactly as release.sh does for its inputs.
#
#   git clone --branch v1.9.3 --depth 1 https://github.com/ggml-org/whisper.cpp DIR
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
  cat <<'USAGE'
Usage: bash scripts/build-whisper-runtime.sh --source DIR --output DIR [--scratch DIR]

Builds arm64 and x86_64 whisper-cli from the whisper.cpp checkout at --source and
writes them to --output as arm64/whisper-cli and x86_64/whisper-cli, the layout
release.sh reads. Output must not already exist; output and scratch must be
outside this repository. Each executable is verified to be single-architecture,
to target macOS 14.0, and to link only Apple system libraries. Output is
unsigned; release.sh signs it while assembling the bundle.
USAGE
}

if [[ "${1:-}" == --help && $# == 1 ]]; then usage; exit 0; fi
# Shared, side-effect-free validation; its CLI runs only when executed.
source "$ROOT_DIR/scripts/release-smoke-test.sh"

source_dir= output= scratch=
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || release_fail "Missing value for $1"
  case "$1" in
    --source) [[ -z "$source_dir" ]] || release_fail 'Duplicate --source'; source_dir="$2" ;;
    --output) [[ -z "$output" ]] || release_fail 'Duplicate --output'; output="$2" ;;
    --scratch) [[ -z "$scratch" ]] || release_fail 'Duplicate --scratch'; scratch="$2" ;;
    *) release_fail "Unknown argument: $1" ;;
  esac
  shift 2
done
[[ -n "$source_dir" && -n "$output" ]] || { usage >&2; exit 2; }

[[ -f "$source_dir/CMakeLists.txt" && -f "$source_dir/examples/cli/cli.cpp" ]] \
  || release_fail "Not a whisper.cpp checkout: $source_dir"
release_external_path "$output"
[[ ! -e "$output" && ! -L "$output" ]] || release_fail "Output must be a new directory: $output"

# The build is driven by cmake, and cmake shells out to xcrun. An x86_64 cmake
# running under Rosetta cannot load the arm64-only xcrun library, so it fails
# before compiling anything. Pick a cmake matching this Mac rather than trusting
# PATH, which on a Mac with both Homebrew prefixes usually finds the wrong one.
host_arch="$(uname -m)"
cmake_bin=
for candidate in "${LOCALDICTATION_CMAKE:-}" /opt/homebrew/bin/cmake \
                 "$(command -v cmake || true)" /usr/local/bin/cmake; do
  [[ -n "$candidate" && -x "$candidate" && ! -d "$candidate" ]] || continue
  [[ " $(lipo -archs "$candidate" 2>/dev/null) " == *" $host_arch "* ]] || continue
  cmake_bin="$candidate"
  break
done
[[ -n "$cmake_bin" ]] || release_fail "No cmake built for $host_arch. Install one (brew install cmake)."

if [[ -n "$scratch" ]]; then
  release_external_path "$scratch"
  mkdir -p "$scratch"
  work="$(mktemp -d "$scratch/whisper-runtime.XXXXXX")"
else
  work="$(mktemp -d)"
fi
trap 'rm -rf "$work"' EXIT

revision="$(git -C "$source_dir" rev-parse HEAD 2>/dev/null || echo 'unknown (not a git checkout)')"
echo "Building whisper-cli from $source_dir at $revision"
echo "Using $cmake_bin"

for arch in arm64 x86_64; do
  # Metal is Apple-silicon only here. Embedding its shaders into the executable
  # is what removes the last non-system file the runtime would otherwise load.
  metal=OFF
  [[ "$arch" == arm64 ]] && metal=ON
  "$cmake_bin" -B "$work/$arch" -S "$source_dir" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_NATIVE=OFF \
    -DGGML_OPENMP=OFF \
    -DGGML_BLAS=OFF \
    -DGGML_CCACHE=OFF \
    -DGGML_METAL="$metal" \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_SERVER=OFF >/dev/null
  "$cmake_bin" --build "$work/$arch" --config Release --target whisper-cli \
    -j "$(sysctl -n hw.ncpu)" >/dev/null
  mkdir -p "$work/out/$arch"
  cp "$work/$arch/bin/whisper-cli" "$work/out/$arch/whisper-cli"
  chmod 755 "$work/out/$arch/whisper-cli"
  # The same gates release.sh applies, run now so a bad build fails here and not
  # after the far slower universal app build.
  release_archs "$work/out/$arch/whisper-cli" "$arch"
  release_system_dependencies "$work/out/$arch/whisper-cli"
  echo "PASS system dependencies: $arch/whisper-cli"
done

mkdir -p "$(dirname "$output")"
mv "$work/out" "$output"
echo
echo "Built $output (unsigned; release.sh signs it)"
echo "Source revision: $revision"
echo
echo "Manifest lines for pinned-inputs.sha256 (add your model's line):"
(cd "$output" && shasum -a 256 arm64/whisper-cli x86_64/whisper-cli)
