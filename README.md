# Local Dictation

A personal macOS menu-bar dictation utility that transcribes English locally.
The first release scope is English-only, using Whisper `tiny.en`. This repository
is preparing for a packaged release; no published or notarized release is claimed.

## Requirements and installation

- macOS 14 or later, on Apple Silicon (arm64) or Intel (x86_64).
- An app and `whisper-cli` built for your Mac's architecture, plus the English
  model `ggml-tiny.en.bin`. The local release command below bundles both architectures.
- A microphone. On Macs without a HyperX or built-in MacBook microphone, choose
  an available input explicitly from the Microphone menu.

For a local source installation, use Swift Package Manager with Xcode's full
macOS toolchain. Run `make check` for the local verification gate, then `make app`
to build and locally ad-hoc sign `LocalDictation.app`. Copy the app to
`/Applications` (or `~/Applications`) and open that installed copy. Configure
external Whisper resources below if the app contains no bundled resources.
An ad-hoc signature is for local use and does not establish notarization.

For a locally generated DMG or ZIP, verify its SHA-256 checksum against the accompanying
checksum file before opening it. Mount the DMG or extract the ZIP, copy
`LocalDictation.app` to Applications, then open it from there. The ad-hoc signed app
is not notarized: macOS may require one-time approval in **System Settings → Privacy
& Security → Open Anyway** after the first launch attempt. Approve only your trusted
local build; the scripts do not disable Gatekeeper.

## Permissions

Enable Local Dictation under **System Settings → Privacy & Security**:

- **Microphone** permits recording speech.
- **Input Monitoring** permits global keyboard and mouse controls.
- **Accessibility** permits automated paste into the active input field.

The menu provides links to these settings and shows hotkey and paste readiness.
Quit and reopen the installed app after changing permissions if necessary.
macOS may ask again after a rebuild. Revoke access in the same settings panels.
Without Accessibility, dictation still copies the result to the clipboard for
manual paste; it does not open a transcript window.

## Controls

- Press right `Option` or the middle mouse button to start recording; press again
  to stop and transcribe. Fallback shortcuts are `Control-Option-Space` and
  `Command-Shift-Space`. The menu also provides **Start Dictation**.
- The result is copied to the clipboard and automatically pasted into the active
  input field when Accessibility is enabled. It remains on the clipboard afterward.
- **Launch at Login** opens Local Dictation automatically when you sign in.
- The Microphone menu defaults to **Automatic (HyperX → MacBook microphone)**.
  It prefers HyperX, then a built-in MacBook microphone, and does not silently
  follow AirPods or another system-default change. Select another input explicitly.
- The status tooltip shows the selected microphone while idle and the active
  microphone while recording. The compact floating indicator shows ready,
  recording, or processing; drag it to reposition it. Its position is remembered.
- **Test Paste into Frontmost App** diagnoses insertion independently of transcription.

## Local processing and data lifetime

Core dictation uses local `whisper-cli` inference. It requires no cloud account,
network connection, API key, or Ollama service once the resources are installed.
The app invokes transcription with English (`-l en`); selecting a different model
is an advanced option and does not add a language-selection feature.

Audio and transcripts are not intentionally retained as a history. Recording uses
a temporary audio file, which is removed after the transcription attempt, including
failure. An interrupted or crashed process can leave temporary data behind; this is
not a secure-erasure guarantee. The transcript remains on the system clipboard and
in the receiving app after paste, subject to those apps' own storage and clipboard
history behavior. Settings such as resource paths and microphone preference persist.

**Toggle Local Cleanup** enables optional local cleanup, such as an advanced-user
Ollama setup. It is off by default and configured separately with **Choose Cleanup
Executable…**. Cleanup receives the transcript when enabled; if it fails, the app
uses the original transcription. Core dictation requires neither cleanup nor its
models. Any explicitly selected external executable controls its own data handling.

## Whisper resources

The executable and model resolve independently, in this order:

1. A readable explicit selection saved as `transcriptionExecutable` or
   `transcriptionModel` in user defaults.
2. A readable bundled `Contents/Resources/whisper-cli` or
   `Contents/Resources/ggml-tiny.en.bin` in the running app.
3. The legacy development/advanced-user locations: `/usr/local/bin/whisper-cli`
   and `~/.content-agents/whisper/ggml-tiny.en.bin`.

An absent or unreadable explicit selection falls through to the bundle, then the
legacy location. If the legacy resource is also missing, dictation reports an error.
A chosen executable can be paired with a bundled model, and vice versa. Readability
selects a candidate; the executable still must run on this Mac and the model must
be valid for it. Nothing is downloaded automatically.

Use **Choose Whisper Executable…** and **Select Whisper Model → Choose Other Whisper
Model…** for explicit advanced-user paths, including executables installed outside
`/usr/local/bin`. The model menu also lists readable `ggml-*.bin` files in the legacy
model directory and includes the resolved model. **Use Automatic Whisper Resources**
clears both explicit Whisper selections to prefer the bundle again. It does not
change cleanup settings.

## Verification and local packaging

The dependency-free checks exercise explicit, bundled, legacy, and mixed resource
precedence with synthetic URLs and injected readability, plus English model
identity. They need no real executable, model download, microphone, Ollama, or
network:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.swift-cache/clang" swift run --package-path . LocalDictationCoreChecks
```

The retained XCTest target supports full-Xcode development. `make check` also runs
Swift parse checks, plist/script validation, and a release build locally.

To assemble a universal release, first supply trusted, pinned local inputs outside
the checkout. No inputs are downloaded by the scripts. Use the same whisper.cpp
revision/build configuration for both runtime architectures, targeting macOS 14.
Each `whisper-cli` must be standalone: statically link whisper/ggml and embed any
required resources (including Metal shaders if enabled). Only Apple system dylibs
under `/usr/lib/` or `/System/Library/` are accepted; an ordinary Homebrew executable
with external library dependencies does not meet this contract. Supply the upstream
English `ggml-tiny.en.bin` model compatible with that runtime.

The input directory must contain exactly these three files, with no symlinks or
additional files. Keep the checksum manifest alongside, outside that directory:

```text
/absolute/local-release/inputs/arm64/whisper-cli
/absolute/local-release/inputs/x86_64/whisper-cli
/absolute/local-release/inputs/ggml-tiny.en.bin
/absolute/local-release/pinned-inputs.sha256
```

The manifest has exactly three lines. Replace each placeholder with the independently
trusted 64-character SHA-256 digest for that specific pinned input; use two spaces
between digest and relative filename. Hashing an arbitrary downloaded file alone
does not establish its provenance.

```text
<ARM64_RUNTIME_SHA256>  arm64/whisper-cli
<X86_64_RUNTIME_SHA256>  x86_64/whisper-cli
<TINY_EN_MODEL_SHA256>  ggml-tiny.en.bin
```

With a usable Swift toolchain for both architectures, Apple packaging tools, and
Python 3, run from this checkout:

```sh
bash scripts/release.sh \
  --inputs /absolute/local-release/inputs \
  --manifest /absolute/local-release/pinned-inputs.sha256 \
  --scratch /absolute/local-release/scratch \
  --output /absolute/local-release/output-0.1.0
bash scripts/release-smoke-test.sh --artifacts /absolute/local-release/output-0.1.0
```

Input, scratch, and output directories must not overlap. The output directory must
not already exist. The command verifies the input hashes, builds both app
architectures, signs the nested runtime before the app with ad-hoc signatures,
then validates the app and archives before exposing the output directory. Failed
builds remove their temporary scratch children and do not produce a release output.
For version `0.1.0`, the output contains:

```text
LocalDictation.app/
LocalDictation-0.1.0.dmg
LocalDictation-0.1.0.zip
LocalDictation-0.1.0-SHA256SUMS.txt
```

The DMG contains the app and an Applications link for drag installation; the ZIP
has the app at its root. Both include the bundled universal runtime, model, and
checked-in third-party notices. Verify downloaded/copied archives from their
directory with `shasum -a 256 -c LocalDictation-0.1.0-SHA256SUMS.txt`. Smoke tests
check both architectures, resources, signatures, matching archive contents, and
digests. They do not demonstrate Whisper inference accuracy or native execution
on both Mac architectures. Official inputs and real-machine transcription checks
are still required before claiming a shippable release.

`make check-release` exercises argument/input rejection and successful artifact
validation with temporary, explicitly synthetic C executable/model fixtures.
These fixtures are never shippable Whisper inputs. This local test needs permission
to create and mount temporary disk images. There is no hosted CI, publication,
Developer ID signing, notarization, or deployment step.

Keep local recordings, transcripts, models, credentials, and generated artifacts
out of Git. Use the ignored `audio/`, `recordings/`, `transcripts/`, `models/`,
`credentials/`, and `secrets/` directories for arbitrary local filenames; do not
force-add private files. File patterns also cover common audio/model formats,
signing material, and build/package output.

Local Dictation is under the [MIT license](LICENSE). See
[third-party notices](THIRD-PARTY-NOTICES.md) for the upstream Whisper and whisper.cpp
MIT terms and authoritative links.
