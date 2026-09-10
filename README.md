# Local Dictation

A personal macOS menu-bar dictation utility that transcribes English locally.
The first release scope is English-only, using Whisper `base.en`. This repository
is preparing for a packaged release; no published or notarized release is claimed.

## Requirements and installation

- macOS 14 or later, on Apple Silicon (arm64) or Intel (x86_64).
- An app and `whisper-cli` built for your Mac's architecture, plus the English
  model `ggml-base.en.bin`. The local release command below bundles both architectures.
  Architecture matters for speed as well as correctness: an x86_64 `whisper-cli`
  running on Apple Silicon under Rosetta transcribes roughly ten times slower than
  the native arm64 build, because it loses both NEON and Metal.
- A microphone. On Macs without a HyperX or built-in MacBook microphone, choose
  an available input explicitly from the Microphone menu.

For a local source installation, use Swift Package Manager with Xcode's full
macOS toolchain. Run `bash scripts/create-signing-identity.sh` once — it creates a
self-signed certificate so macOS keeps the app's granted permissions across
rebuilds; without it every rebuild silently loses them. Run `make check` for the
local verification gate, then `make app`
to build and sign `LocalDictation.app`. Copy the app to
`/Applications` (or `~/Applications`) and open that installed copy. Install `whisper-cli` as described under Whisper resources
below if the app contains no bundled resources.
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

**Settings…** shows the live state of all three and links to each panel.
Quit and reopen the installed app after changing permissions if necessary.
Revoke access in the same settings panels.

macOS ties each grant to the app's code signature. A development build signed
ad-hoc gets a fresh identity on every rebuild, so macOS keeps showing the app as
enabled while denying it — remove and re-add the app, or better, run
`bash scripts/create-signing-identity.sh` and rebuild once.
Without Accessibility, dictation still copies the result to the clipboard for
manual paste; it does not open a transcript window.

## Controls

- Press your shortcut to start recording; press it again to stop and transcribe.
  Out of the box that is right `Option` or the middle mouse button. The first menu
  item follows the same state, reading **Start Dictation** when idle and **Stop
  Dictation** while recording, so the menu alone is enough to run a dictation.
- Set your own under **Settings… → What starts dictation**. **Add Shortcut…**
  records whatever you press next: a modifier key on its own (tap and release), a
  key combination (hold modifiers, then press the key), or an extra mouse button.
  Each saved shortcut has a **Remove** button, and removing all of them is
  allowed — the menu still starts dictation.
- Key combinations keep working without Input Monitoring access, because they are
  also registered as system hot keys whenever the event tap cannot be created.
  Modifier taps and mouse buttons need Input Monitoring.
- The result is copied to the clipboard and automatically pasted into the active
  input field when Accessibility is enabled. It remains on the clipboard afterward.
- A recording that captured no speech inserts nothing. Whisper's own labels for
  sounds it cannot transcribe (`[BLANK_AUDIO]`, `[MUSIC]`, `(wind blowing)`) are
  removed rather than pasted, and a transcript left empty by that removal ends the
  dictation quietly instead of raising an error.
- **Recent Transcripts** lists the last 30 results, newest first. Selecting one
  copies it back to the clipboard; hovering shows its full text and timestamp.
  **Clear History** deletes them.
- **Settings… → Open Local Dictation at login** opens the app when you sign in.
- The Microphone menu defaults to **Automatic (HyperX → MacBook microphone)**.
  It prefers HyperX, then a built-in MacBook microphone, and does not silently
  follow AirPods or another system-default change. Select another input explicitly.
- The status tooltip shows the selected microphone while idle and the active
  microphone while recording. The compact floating indicator shows ready,
  recording, or processing; drag it to reposition it. Its position is remembered.

## Local processing and data lifetime

Core dictation uses local `whisper-cli` inference. It requires no cloud account,
network connection, or API key once the resources are installed.
The app invokes transcription with English (`-l en`) using a single fixed model,
with no model or engine picker to get wrong.

Audio is not retained. Recording uses a temporary audio file, which is removed
after the transcription attempt, including failure. An interrupted or crashed
process can leave temporary data behind; this is not a secure-erasure guarantee.

Transcripts are retained, deliberately and locally. The last 30 are written to
`~/Library/Application Support/LocalDictation/history.json` so that a paste which
went to the wrong window is recoverable. The file is owner-read/write only (mode
`600`) inside an owner-only directory (mode `700`), it is never transmitted
anywhere, and **Recent Transcripts → Clear History** deletes it outright. Anything
with access to your user account can read it, so treat it as you would any other
file in your home directory.

The transcript also remains on the system clipboard and in the receiving app after
paste, subject to those apps' own storage and clipboard history behavior. Settings
such as the microphone and trigger preferences persist.

## Whisper resources

The executable and model resolve independently, taking the first readable candidate:

**Executable**

1. A bundled `Contents/Resources/whisper-cli` in the running app.
2. `/opt/homebrew/bin/whisper-cli` — Homebrew's Apple Silicon prefix.
3. `/usr/local/bin/whisper-cli` — Homebrew's Intel prefix, and the correct prefix
   on an Intel Mac.

**Model**

1. A bundled `Contents/Resources/ggml-base.en.bin` in the running app.
2. `~/.content-agents/whisper/ggml-base.en.bin`.

The Apple Silicon prefix is checked before `/usr/local` deliberately. A Mac carrying
both Homebrew installs has a native arm64 engine in `/opt/homebrew` and an x86_64
engine in `/usr/local`; picking the latter costs roughly a 10x slowdown under Rosetta
for identical output. On an Intel Mac `/opt/homebrew` does not exist, so the same
order resolves correctly there.

If nothing is readable, dictation reports an error naming the last candidate.
Readability selects a candidate; the executable still must run on this Mac and the
model must be valid for it. Nothing is downloaded automatically, and there is no
in-app engine or model picker.

At launch the app runs one throwaway transcription on a fifth of a second of silence.
The first Whisper run after an engine or macOS update spends about 17 seconds compiling
Metal shaders; this pays that cost in the background instead of inside your first
dictation.

## Verification and local packaging

The dependency-free checks exercise bundled-versus-installed resource precedence
with synthetic URLs and injected readability, the Apple Silicon prefix ordering,
English model identity, and the trigger-selection rules. They need no real
executable, model download, microphone, or network:

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
English `ggml-base.en.bin` model compatible with that runtime.

`scripts/build-whisper-runtime.sh` produces both runtimes to that contract. Clone
whisper.cpp yourself at a revision you trust — the script downloads nothing — then
build from it:

```sh
git clone --branch v1.9.3 --depth 1 https://github.com/ggml-org/whisper.cpp \
  /absolute/local-release/whisper.cpp
bash scripts/build-whisper-runtime.sh \
  --source /absolute/local-release/whisper.cpp \
  --output /absolute/local-release/inputs \
  --scratch /absolute/local-release/scratch
```

It links whisper and ggml statically, embeds the Metal shaders, and targets macOS
14.0, building arm64 with Metal and x86_64 without it. Each executable is verified
for a single architecture and Apple-only dependencies before it is written, so a
bad build fails there rather than after the much slower universal app build. The
output directory is the `--inputs` directory used below; copy `ggml-base.en.bin`
into it beside the two architecture folders. The script prints the two runtime
lines for the checksum manifest.

`cmake` must itself be built for this Mac. An x86_64 `cmake` running under Rosetta
cannot load the arm64 toolchain and fails before compiling anything, so the script
selects a matching one rather than trusting `PATH`, and reports if none is
installed.

The input directory must contain exactly these three files, with no symlinks or
additional files. Keep the checksum manifest alongside, outside that directory:

```text
/absolute/local-release/inputs/arm64/whisper-cli
/absolute/local-release/inputs/x86_64/whisper-cli
/absolute/local-release/inputs/ggml-base.en.bin
/absolute/local-release/pinned-inputs.sha256
```

The manifest has exactly three lines. Replace each placeholder with the independently
trusted 64-character SHA-256 digest for that specific pinned input; use two spaces
between digest and relative filename. Hashing an arbitrary downloaded file alone
does not establish its provenance.

```text
<ARM64_RUNTIME_SHA256>  arm64/whisper-cli
<X86_64_RUNTIME_SHA256>  x86_64/whisper-cli
<BASE_EN_MODEL_SHA256>  ggml-base.en.bin
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
