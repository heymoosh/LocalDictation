#!/usr/bin/env bash
set -euo pipefail

RELEASE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
release_fail() { echo "ERROR: $*" >&2; exit 1; }

release_external_path() {
  python3 - "$RELEASE_ROOT" "$1" <<'PY'
import os, sys
root, path = map(os.path.realpath, sys.argv[1:])
if os.path.commonpath([root, path]) == root:
    sys.exit('Release inputs, scratch, and output must be outside the repository: ' + path)
if path == '/' or path == os.path.expanduser('~'):
    sys.exit('Provide a dedicated release directory, not a filesystem/home root.')
PY
}

release_archs() {
  local file="$1" expected actual
  shift
  [[ -f "$file" && -x "$file" && ! -L "$file" ]] || release_fail "Missing executable: $file"
  expected="$(printf '%s\n' "$@" | LC_ALL=C sort | tr '\n' ' ')"
  actual="$(lipo -archs "$file" | tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' ')"
  [[ "$actual" == "$expected" ]] || release_fail "Wrong architectures in $file: $actual (expected $expected)"
  echo "PASS architectures: $file: $actual"
}

# Inputs must statically include whisper/ggml and any required Metal resources.
# Non-system dylibs cannot be satisfied by the three-input bundle contract.
release_system_dependencies() {
  local binary="$1" arch listing header commands
  for arch in $(lipo -archs "$binary"); do
    listing="$(otool -arch "$arch" -L "$binary")"
    header="$(otool -arch "$arch" -hv "$binary")"
    commands="$(otool -arch "$arch" -l "$binary")"
    python3 - "$binary" "$arch" "$listing" "$header" "$commands" <<'PY'
import re, sys
if not re.search(r'\bEXECUTE\b', sys.argv[4]):
    sys.exit('Runtime/app must be a Mach-O executable: ' + sys.argv[1])
commands = sys.argv[5]
build = re.search(r'cmd LC_BUILD_VERSION\s+cmdsize \d+\s+platform (\S+)\s+minos (\S+)', commands)
legacy = re.search(r'cmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version (\S+)', commands)
if build:
    if build[1] not in ('1', 'MACOS'): sys.exit('Executable must target macOS')
    version = build[2]
elif legacy:
    version = legacy[1]
else:
    sys.exit('Missing macOS deployment target: ' + sys.argv[1])
parts = tuple(map(int, version.split('.')))
if (parts + (0, 0))[:3] > (14, 0, 0):
    sys.exit('Executable requires macOS newer than 14.0: ' + sys.argv[1] + ': ' + version)
lines = sys.argv[3].splitlines()
if len(lines) < 2:
    sys.exit('Unable to inspect Mach-O dependencies: ' + sys.argv[1])
for line in lines[1:]:
    dependency = line.strip().split(' (compatibility version', 1)[0]
    if not dependency.startswith(('/usr/lib/', '/System/Library/')):
        sys.exit('Non-system dependency in %s (%s): %s' % (*sys.argv[1:3], dependency))
PY
  done
}

release_validate_app() (
  app="$1"
  [[ -d "$app" && ! -L "$app" ]] || release_fail "Missing app: $app"
  python3 - "$app" "$RELEASE_ROOT" <<'PY'
import pathlib, plistlib, sys
app, root = map(pathlib.Path, sys.argv[1:])
for path in app.rglob('*'):
    if path.is_symlink() or not (path.is_file() or path.is_dir()):
        sys.exit('Unexpected link/special file in app: ' + str(path))
with (app / 'Contents/Info.plist').open('rb') as stream:
    info = plistlib.load(stream)
with (root / 'Info.plist').open('rb') as stream:
    expected = plistlib.load(stream)
for key in ('CFBundleIdentifier', 'CFBundleExecutable', 'CFBundlePackageType',
            'CFBundleShortVersionString', 'CFBundleVersion', 'LSMinimumSystemVersion'):
    if info.get(key) != expected.get(key):
        sys.exit('Bundle metadata mismatch: ' + key)
model = app / 'Contents/Resources/ggml-base.en.bin'
if not model.is_file() or model.stat().st_size == 0:
    sys.exit('Missing/empty English model')
notices = app / 'Contents/Resources/THIRD-PARTY-NOTICES.md'
if notices.read_bytes() != (root / 'THIRD-PARTY-NOTICES.md').read_bytes():
    sys.exit('Third-party notices differ from the checked-in notices')
PY
  release_archs "$app/Contents/MacOS/LocalDictation" arm64 x86_64
  release_archs "$app/Contents/Resources/whisper-cli" arm64 x86_64
  release_system_dependencies "$app/Contents/MacOS/LocalDictation"
  release_system_dependencies "$app/Contents/Resources/whisper-cli"
  for signed in "$app/Contents/Resources/whisper-cli" "$app"; do
    codesign --verify --strict --all-architectures "$signed"
    for arch in arm64 x86_64; do
      details="$(codesign --display --arch "$arch" --verbose=4 "$signed" 2>&1)"
      [[ "$details" == *'Signature=adhoc'* ]] || release_fail "Not ad-hoc signed: $signed ($arch)"
    done
  done
  codesign --verify --deep --strict --all-architectures "$app"
  echo "PASS bundle metadata, model presence, exact notices, macOS 14 executable targets, system dependencies, strict ad-hoc signatures: $app"
)

release_version() {
  python3 - "$RELEASE_ROOT/Info.plist" <<'PY'
import plistlib, re, sys
with open(sys.argv[1], 'rb') as stream:
    version = plistlib.load(stream)['CFBundleShortVersionString']
if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version):
    sys.exit('Release version must be numeric major.minor.patch')
print(version)
PY
}

release_validate_artifacts() (
  artifacts="$1"
  stem="LocalDictation-$(release_version)"
  app="$artifacts/LocalDictation.app"
  dmg="$artifacts/$stem.dmg"
  zip="$artifacts/$stem.zip"
  sums="$artifacts/$stem-SHA256SUMS.txt"
  python3 - "$artifacts" "$stem" <<'PY'
import hashlib, pathlib, re, sys
directory, stem = pathlib.Path(sys.argv[1]), sys.argv[2]
expected = [stem + '.dmg', stem + '.zip']
manifest = directory / (stem + '-SHA256SUMS.txt')
if manifest.is_symlink() or not manifest.is_file():
    sys.exit('Missing checksum manifest')
lines = manifest.read_text().splitlines()
if len(lines) != 2:
    sys.exit('Artifact manifest must contain exactly DMG and ZIP checksums')
seen = set()
for line in lines:
    match = re.fullmatch(r'([0-9a-fA-F]{64})  (.+)', line)
    if not match or match[2] not in expected or match[2] in seen:
        sys.exit('Malformed/duplicate/unexpected artifact checksum entry')
    seen.add(match[2])
    path = directory / match[2]
    if path.is_symlink() or not path.is_file() or path.stat().st_size == 0:
        sys.exit('Missing/empty artifact: ' + str(path))
    with path.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest() if hasattr(hashlib, 'file_digest') else None
        if digest is None:
            h = hashlib.sha256()
            for chunk in iter(lambda: stream.read(1024 * 1024), b''): h.update(chunk)
            digest = h.hexdigest()
    if digest != match[1].lower():
        sys.exit('Artifact checksum mismatch: ' + str(path))
    print('PASS SHA-256: ' + match[2] + ': ' + digest)
PY
  release_validate_app "$app"
  work="$(mktemp -d "${TMPDIR:-/tmp}/localdictation-smoke.XXXXXX")"
  mounted=0
  cleanup() {
    local status=$?
    if [[ "$mounted" == 1 ]]; then
      if ! hdiutil detach "$work/mount"; then
        echo "ERROR: Could not detach $work/mount; retained $work" >&2
        exit 1
      fi
    fi
    rm -rf "$work"
    exit "$status"
  }
  trap cleanup EXIT
  # Inspect before extraction: reject traversal, symlinks and additional roots.
  python3 - "$zip" <<'PY'
import pathlib, stat, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as archive:
    entries = archive.infolist()
    if not entries: sys.exit('Empty ZIP')
    seen = set()
    for entry in entries:
        path = pathlib.PurePosixPath(entry.filename)
        if (path.is_absolute() or '..' in path.parts or not path.parts
            or path.parts[0] != 'LocalDictation.app' or '\\' in entry.filename
            or entry.filename in seen or stat.S_ISLNK(entry.external_attr >> 16)):
            sys.exit('Unsafe or unexpected ZIP entry: ' + entry.filename)
        seen.add(entry.filename)
    if archive.testzip() is not None: sys.exit('ZIP CRC validation failed')
PY
  mkdir "$work/zip" "$work/mount"
  ditto -x -k "$zip" "$work/zip"
  release_validate_app "$work/zip/LocalDictation.app"
  diff -qr "$app" "$work/zip/LocalDictation.app"
  echo 'PASS ZIP: root LocalDictation.app exactly matches assembled app'
  hdiutil verify "$dmg"
  hdiutil attach "$dmg" -readonly -nobrowse -mountpoint "$work/mount"
  mounted=1
  [[ -L "$work/mount/Applications" && "$(readlink "$work/mount/Applications")" == /Applications ]] \
    || release_fail 'DMG is missing the /Applications drag-install link.'
  release_validate_app "$work/mount/LocalDictation.app"
  diff -qr "$app" "$work/mount/LocalDictation.app"
  echo 'PASS DMG: matching app and /Applications link, read-only mount verified'
  echo 'PASS local artifact smoke test (structure/signatures/digests; no transcription or notarization claim)'
)

release_fixture_app() (
  # This intentionally synthetic executable/model only tests packaging mechanics.
  work="$1"
  mkdir -p "$work/inputs/arm64" "$work/inputs/x86_64" \
    "$work/artifacts/LocalDictation.app/Contents/MacOS" \
    "$work/artifacts/LocalDictation.app/Contents/Resources"
  for arch in arm64 x86_64; do
    printf '%s\n' 'int main(void) { return 0; }' | \
      xcrun clang -x c - -arch "$arch" -mmacosx-version-min=14.0 -o "$work/inputs/$arch/whisper-cli"
  done
  printf '%s\n' 'SYNTHETIC PACKAGING FIXTURE; NOT A WHISPER MODEL' > "$work/inputs/ggml-base.en.bin"
  app="$work/artifacts/LocalDictation.app"
  lipo -create "$work/inputs/arm64/whisper-cli" "$work/inputs/x86_64/whisper-cli" \
    -output "$app/Contents/MacOS/LocalDictation"
  cp "$app/Contents/MacOS/LocalDictation" "$app/Contents/Resources/whisper-cli"
  cp "$work/inputs/ggml-base.en.bin" "$app/Contents/Resources/ggml-base.en.bin"
  cp "$RELEASE_ROOT/Info.plist" "$app/Contents/Info.plist"
  cp "$RELEASE_ROOT/THIRD-PARTY-NOTICES.md" "$app/Contents/Resources/THIRD-PARTY-NOTICES.md"
  codesign --force --sign - "$app/Contents/Resources/whisper-cli"
  codesign --force --sign - --identifier local.muxin.LocalDictation "$app"
)

release_expect_failure() {
  local label="$1"; shift
  # A fresh shell preserves errexit inside the checked function. Calling a shell
  # function directly in an if-condition would suppress its internal failures.
  if bash -c 'source "$1"; shift; "$@"' bash "$RELEASE_ROOT/scripts/release.sh" "$@"; then
    release_fail "Negative check unexpectedly succeeded: $label"
  fi
  echo "PASS rejection: $label"
}

release_smoke_self_test() (
  source "$RELEASE_ROOT/scripts/release.sh"
  work="$(mktemp -d "${TMPDIR:-/tmp}/localdictation-smoke-fixture.XXXXXX")"
  trap 'rm -rf "$work"' EXIT
  echo 'SELF-TEST: synthetic universal C executables and fake model; NOT shippable Whisper inputs.'
  release_expect_failure 'unknown smoke argument' bash "$RELEASE_ROOT/scripts/release-smoke-test.sh" --unknown
  release_expect_failure 'missing smoke argument' bash "$RELEASE_ROOT/scripts/release-smoke-test.sh" --artifacts
  release_expect_failure 'missing artifacts' release_validate_artifacts "$work/missing"
  release_fixture_app "$work"
  release_package_artifacts "$work/artifacts" "$work"
  release_validate_artifacts "$work/artifacts"
  stem="LocalDictation-$(release_version)"
  cp "$work/artifacts/$stem.zip" "$work/good.zip"
  # Rehash a malformed ZIP so rejection must inspect its structure, not its hash.
  printf 'not a ZIP\n' > "$work/artifacts/$stem.zip"
  release_write_artifact_sums "$work/artifacts"
  release_expect_failure 'malformed ZIP with matching digest' release_validate_artifacts "$work/artifacts"
  cp "$work/good.zip" "$work/artifacts/$stem.zip"
  release_write_artifact_sums "$work/artifacts"
  cp "$work/artifacts/$stem-SHA256SUMS.txt" "$work/good-sums"
  printf 'malformed\n' > "$work/artifacts/$stem-SHA256SUMS.txt"
  release_expect_failure 'malformed checksum file' release_validate_artifacts "$work/artifacts"
  cp "$work/good-sums" "$work/artifacts/$stem-SHA256SUMS.txt"
  printf 'tamper\n' >> "$work/artifacts/$stem.zip"
  release_expect_failure 'archive checksum mismatch' release_validate_artifacts "$work/artifacts"
  cp "$work/inputs/arm64/whisper-cli" "$work/arm64-only"
  release_expect_failure 'missing Intel architecture' release_archs "$work/arm64-only" arm64 x86_64
  printf '%s\n' 'int main(void) { return 0; }' | \
    xcrun clang -x c - -arch arm64 -mmacosx-version-min=15.0 -o "$work/requires-macos15"
  release_expect_failure 'runtime requiring macOS 15' release_system_dependencies "$work/requires-macos15"
  # Synthetic macOS 14 executable with a planted non-system dylib dependency.
  # This exercises the same validator used for both runtime inputs and app bundles.
  printf '%s\n' 'int packaging_fixture_dependency(void) { return 0; }' | \
    xcrun clang -x c - -arch arm64 -mmacosx-version-min=14.0 -dynamiclib \
      -Wl,-install_name,@rpath/libpackaging-fixture.dylib -o "$work/libpackaging-fixture.dylib"
  printf '%s\n' 'int packaging_fixture_dependency(void); int main(void) { return packaging_fixture_dependency(); }' | \
    xcrun clang -x c - -arch arm64 -mmacosx-version-min=14.0 \
      -L"$work" -lpackaging-fixture -o "$work/non-system-dependency"
  release_archs "$work/non-system-dependency" arm64
  dependencies="$(otool -L "$work/non-system-dependency")"
  [[ "$dependencies" == *'@rpath/libpackaging-fixture.dylib'* ]] || release_fail 'Synthetic dylib dependency was not planted.'
  release_expect_failure 'runtime with non-system @rpath dylib' release_system_dependencies "$work/non-system-dependency"
  rm "$work/artifacts/LocalDictation.app/Contents/Resources/ggml-base.en.bin"
  release_expect_failure 'missing bundled model' release_validate_app "$work/artifacts/LocalDictation.app"
  echo 'PASS smoke self-test; fixture files removed on exit'
)

release_smoke_main() {
  case "${1:-}" in
    --help)
      [[ $# == 1 ]] || release_fail '--help takes no other arguments.'
      cat <<'USAGE'
Usage: bash scripts/release-smoke-test.sh --artifacts DIR
       bash scripts/release-smoke-test.sh --self-test

Validate versioned DMG/ZIP/SHA256SUMS, universal LocalDictation.app, resources,
system dylib dependencies, strict ad-hoc signatures, archive contents and digests.
Requires macOS hdiutil/codesign/lipo/ditto and Python 3. Self-test compiles synthetic
universal C fixtures; it does not validate real Whisper inference/model quality.
USAGE
      ;;
    --self-test) [[ $# == 1 ]] || release_fail '--self-test takes no other arguments.'; release_smoke_self_test ;;
    --artifacts) [[ $# == 2 && -n "$2" && "$2" != --* ]] || release_fail 'Provide --artifacts DIR.'; release_validate_artifacts "$2" ;;
    *) release_fail 'Use --artifacts DIR, --self-test, or --help.' ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then release_smoke_main "$@"; fi
