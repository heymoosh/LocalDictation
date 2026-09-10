#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/release-smoke-test.sh"

release_verify_inputs() {
  python3 - "$1" "$2" <<'PY'
import hashlib, pathlib, re, sys
directory, manifest = map(pathlib.Path, sys.argv[1:])
expected = {'arm64/whisper-cli', 'x86_64/whisper-cli', 'ggml-tiny.en.bin'}
if not directory.is_dir() or directory.is_symlink():
    sys.exit('Input directory is missing or a symlink')
if not manifest.is_file() or manifest.is_symlink():
    sys.exit('Checksum manifest is missing or a symlink')
actual = set()
for path in directory.rglob('*'):
    name = path.relative_to(directory).as_posix()
    if path.is_symlink() or not (path.is_file() or (path.is_dir() and name in {'arm64', 'x86_64'})):
        sys.exit('Unexpected input path: ' + name)
    if path.is_file(): actual.add(name)
if actual != expected:
    sys.exit('Input files must be exactly %s; found %s' % (sorted(expected), sorted(actual)))
lines = manifest.read_text().splitlines()
if len(lines) != 3:
    sys.exit('Manifest must contain exactly three SHA-256 lines')
seen = set()
for line in lines:
    match = re.fullmatch(r'([0-9a-fA-F]{64})  (.+)', line)
    if not match or match[2] not in expected or match[2] in seen:
        sys.exit('Malformed/duplicate/unexpected input manifest entry')
    name = match[2]
    seen.add(name)
    path = directory / name
    if path.stat().st_size == 0: sys.exit('Empty input: ' + name)
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''): h.update(chunk)
    if h.hexdigest() != match[1].lower(): sys.exit('Input checksum mismatch: ' + name)
    print('PASS pinned input: ' + name + ': ' + h.hexdigest())
PY
}

release_write_artifact_sums() (
  cd "$1"
  stem="LocalDictation-$(release_version)"
  shasum -a 256 "$stem.dmg" "$stem.zip" > "$stem-SHA256SUMS.txt"
)

release_package_artifacts() (
  artifacts="$1"; scratch="$2"
  stem="LocalDictation-$(release_version)"
  stage="$(mktemp -d "$scratch/dmg-stage.XXXXXX")"
  trap 'rm -rf "$stage"' EXIT
  ditto "$artifacts/LocalDictation.app" "$stage/LocalDictation.app"
  ln -s /Applications "$stage/Applications"
  hdiutil create -volname 'Local Dictation' -srcfolder "$stage" -format UDZO \
    -fs HFS+ "$artifacts/$stem.dmg"
  ditto -c -k --keepParent --norsrc --noextattr \
    "$artifacts/LocalDictation.app" "$artifacts/$stem.zip"
  release_write_artifact_sums "$artifacts"
)

release_self_test() (
  work="$(mktemp -d "${TMPDIR:-/tmp}/localdictation-release-fixture.XXXXXX")"
  trap 'rm -rf "$work"' EXIT
  echo 'SELF-TEST: synthetic input bytes only; NOT a shippable runtime/model or release.'
  mkdir -p "$work/inputs/arm64" "$work/inputs/x86_64"
  printf 'synthetic arm64\n' > "$work/inputs/arm64/whisper-cli"
  printf 'synthetic x86_64\n' > "$work/inputs/x86_64/whisper-cli"
  printf 'synthetic model\n' > "$work/inputs/ggml-tiny.en.bin"
  (cd "$work/inputs"; shasum -a 256 arm64/whisper-cli x86_64/whisper-cli ggml-tiny.en.bin) > "$work/pinned.sha256"
  release_verify_inputs "$work/inputs" "$work/pinned.sha256"
  release_expect_failure 'unknown argument' bash "$RELEASE_ROOT/scripts/release.sh" --unknown
  release_expect_failure 'missing argument' bash "$RELEASE_ROOT/scripts/release.sh" --inputs
  release_expect_failure 'duplicate argument' bash "$RELEASE_ROOT/scripts/release.sh" --inputs a --inputs b
  release_expect_failure 'missing manifest' release_verify_inputs "$work/inputs" "$work/missing"
  printf 'tamper\n' >> "$work/inputs/arm64/whisper-cli"
  release_expect_failure 'checksum mismatch before build/output' bash "$RELEASE_ROOT/scripts/release.sh" \
    --inputs "$work/inputs" --manifest "$work/pinned.sha256" --scratch "$work/scratch" --output "$work/output"
  [[ ! -e "$work/output" && ! -e "$work/scratch" ]] || release_fail 'Rejected inputs created output/scratch.'
  printf 'synthetic arm64\n' > "$work/inputs/arm64/whisper-cli"
  printf 'extra\n' > "$work/inputs/extra"
  release_expect_failure 'extra input' release_verify_inputs "$work/inputs" "$work/pinned.sha256"
  rm "$work/inputs/extra"
  mv "$work/inputs/ggml-tiny.en.bin" "$work/model"
  release_expect_failure 'missing input' release_verify_inputs "$work/inputs" "$work/pinned.sha256"
  mv "$work/model" "$work/inputs/ggml-tiny.en.bin"
  cp "$work/pinned.sha256" "$work/bad.sha256"
  head -n 1 "$work/pinned.sha256" >> "$work/bad.sha256"
  release_expect_failure 'extra manifest entry' release_verify_inputs "$work/inputs" "$work/bad.sha256"
  head -n 1 "$work/pinned.sha256" > "$work/bad.sha256"
  head -n 1 "$work/pinned.sha256" >> "$work/bad.sha256"
  tail -n 1 "$work/pinned.sha256" >> "$work/bad.sha256"
  release_expect_failure 'duplicate manifest entry' release_verify_inputs "$work/inputs" "$work/bad.sha256"
  release_expect_failure 'in-repository output' release_external_path "$RELEASE_ROOT/dist/release"
  release_expect_failure 'non-Mach-O fixture rejected' release_archs "$work/inputs/arm64/whisper-cli" arm64
  echo 'PASS release input/argument self-test; fixture files removed on exit'
)

release_main() (
  if [[ "${1:-}" == --help && $# == 1 ]]; then
    cat <<'USAGE'
Usage: bash scripts/release.sh --inputs DIR --manifest FILE --scratch DIR --output DIR
       bash scripts/release.sh --self-test

Local-only macOS 14+ universal release, ad-hoc signed (not Developer ID/notarized).
DIR must contain exactly: arm64/whisper-cli, x86_64/whisper-cli, ggml-tiny.en.bin.
FILE must contain exactly three lines: 64 hex SHA-256 digits, TWO spaces, then
one of those relative filenames. Keep the manifest separate from the input DIR.
Use independently trusted, pinned hashes. Runtimes must statically include
whisper/ggml and required resources, with only /usr/lib or /System/Library dylibs.
All paths must be outside this checkout. Output must not already exist. Scratch
must be separate from inputs/output; temporary children are removed on exit.
Requires the macOS Swift cross-compilation toolchain, Python 3, and Apple packaging
tools. No downloads or remote commands. Output is exposed only after smoke tests:
LocalDictation.app, LocalDictation-VERSION.dmg, LocalDictation-VERSION.zip,
LocalDictation-VERSION-SHA256SUMS.txt. Self-tests use explicitly synthetic fixtures.
USAGE
    exit 0
  fi
  if [[ "${1:-}" == --self-test && $# == 1 ]]; then release_self_test; exit 0; fi
  inputs= manifest= scratch= output=
  while [[ $# -gt 0 ]]; do
    [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || release_fail "Missing value for $1"
    case "$1" in
      --inputs) [[ -z "$inputs" ]] || release_fail 'Duplicate --inputs'; inputs="$2" ;;
      --manifest) [[ -z "$manifest" ]] || release_fail 'Duplicate --manifest'; manifest="$2" ;;
      --scratch) [[ -z "$scratch" ]] || release_fail 'Duplicate --scratch'; scratch="$2" ;;
      --output) [[ -z "$output" ]] || release_fail 'Duplicate --output'; output="$2" ;;
      *) release_fail "Unknown argument: $1" ;;
    esac
    shift 2
  done
  [[ -n "$inputs" && -n "$manifest" && -n "$scratch" && -n "$output" ]] || \
    release_fail 'Provide --inputs, --manifest, --scratch, and --output (see --help).'
  # Canonical paths make nesting checks and subsequent cd-independent commands safe.
  inputs="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$inputs")"
  manifest="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$manifest")"
  scratch="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$scratch")"
  output="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$output")"
  for path in "$inputs" "$manifest" "$scratch" "$output"; do release_external_path "$path"; done
  python3 - "$inputs" "$scratch" "$output" <<'PY'
import os, sys
paths = sys.argv[1:]
for i, left in enumerate(paths):
    for right in paths[i+1:]:
        if os.path.commonpath([left, right]) in (left, right):
            sys.exit('Inputs, scratch, and output must not overlap')
PY
  [[ ! -e "$output" && ! -L "$output" ]] || release_fail "Output already exists: $output"
  release_verify_inputs "$inputs" "$manifest"
  release_archs "$inputs/arm64/whisper-cli" arm64
  release_archs "$inputs/x86_64/whisper-cli" x86_64
  release_system_dependencies "$inputs/arm64/whisper-cli"
  release_system_dependencies "$inputs/x86_64/whisper-cli"
  mkdir -p "$scratch"
  work="$(mktemp -d "$scratch/localdictation-release.XXXXXX")"
  trap 'rm -rf "$work"' EXIT
  # Build from a verified private snapshot, not mutable caller-owned input files.
  ditto "$inputs" "$work/inputs"
  cp "$manifest" "$work/pinned.sha256"
  release_verify_inputs "$work/inputs" "$work/pinned.sha256"
  mkdir "$work/artifacts"
  bash "$RELEASE_ROOT/scripts/build-app.sh" --universal --inputs "$work/inputs" \
    --scratch "$work/build" --output "$work/artifacts/LocalDictation.app"
  cmp "$work/inputs/ggml-tiny.en.bin" "$work/artifacts/LocalDictation.app/Contents/Resources/ggml-tiny.en.bin"
  release_package_artifacts "$work/artifacts" "$work"
  release_validate_artifacts "$work/artifacts"
  mkdir -p "$(dirname "$output")"
  [[ ! -e "$output" && ! -L "$output" ]] || release_fail 'Output appeared during build; refusing to replace it.'
  mv "$work/artifacts" "$output"
  echo "Release artifacts: $output (ad-hoc signed; not notarized)"
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then release_main "$@"; fi
