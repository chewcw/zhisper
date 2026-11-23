# zhisper

Press a key, talk, let go. Your words land as text in whatever window you were typing in.

`zhisper` is a push-to-talk dictation daemon written in Zig. It captures your microphone through miniaudio, sends the clip to a Whisper-compatible transcription endpoint, and injects the result as real keystrokes — so it works in any application, not just a chat box.

- Hold a key to talk, release to transcribe and type.
- A second key throws the current recording away.
- A third can route a recording to the clipboard instead of typing it.
- Which keys those are is up to you — see [Shortcuts](#shortcuts). There are working defaults if you would rather not pick.
- Runs on **Linux, Windows, and macOS** from the same source.

## Table of contents

- [How it works](#how-it-works)
- [Build](#build)
- [Setup](#setup)
- [Usage](#usage)
- [Configuration](#configuration)
- [Shortcuts](#shortcuts)
- [Environment variables](#environment-variables)
- [Optional text normalization](#optional-text-normalization)
- [Development](#development)
- [Project layout](#project-layout)

## How it works

```mermaid
flowchart TD
    A[hotkey press] --> B[record mic\n16 kHz mono WAV]
    B --> C[hotkey release]
    C --> D{duration >= min_duration_ms?}
    D -- no --> E[drop clip]
    D -- yes --> F[transcribe\nGroq / OpenAI / compatible endpoint]
    F --> G{normalize enabled?}
    G -- yes --> H[normalize pass\nraw transcript to clean text]
    G -- no --> I{sink?}
    H --> I
    I -- typing --> J[type as keystrokes]
    I -- clipboard --> K[copy to clipboard]
```

A single-slot work queue means you never block the hotkey loop: one clip is transcribing while the next one records. The queue holds at most one waiting clip, so memory stays flat no matter how fast you talk, and the oldest waiting clip is dropped (with a notification) rather than growing without bound.

The overlay pill, system tray icon, and desktop notifications all reflect the same three states: **idle**, **recording**, **working**.

## Build

Requires **Zig 0.16.0** — the version is pinned in `build.zig.zon`.

```sh
zig build                # → zig-out/bin/zhisper
zig build test           # all tests (library + exe, in parallel)
zig fmt                  # format (CI expects a clean tree)
```

The first build compiles the vendored C (miniaudio, SDL3, and per-platform tray/notify shims), so it is slow. Later builds are cached.

Cross-compile checks:

```sh
zig build -Dtarget=x86_64-windows
zig build -Dtarget=aarch64-macos
```

## Setup

### 1. Get an API key

| Provider | Env var | Default model | Endpoint |
|---|---|---|---|
| `groq` (default) | `GROQ_API_KEY` | `whisper-large-v3-turbo` | `https://api.groq.com/openai/v1/audio/transcriptions` |
| `openai` | `OPENAI_API_KEY` | `whisper-1` | `https://api.openai.com/v1/audio/transcriptions` |
| `deepgram` | `DEEPGRAM_API_KEY` | `nova-3` | `https://api.deepgram.com/v1/listen` |
| `custom` | `CUSTOM_API_KEY` | *you choose* | *you choose* (`base_url` required) |

With the Deepgram provider, audio is sent over a WebSocket while the recording runs (on Linux and macOS); the transcript is typed once after the hotkey is released. If the stream fails, zhisper falls back to the Deepgram batch endpoint. On Windows the Deepgram path posts the saved WAV to the batch endpoint instead of streaming, because the streaming transport cannot interrupt a blocked read without freeing memory the reader still uses.

Keys are **environment variables only**. Putting `api_key` in the config file is a hard startup error, by design.

Each provider reads only its own variable, so you can export several keys at
once and switch provider without touching the environment. The old shared
variable `ZHISPER_API_KEY` is no longer read.

```sh
export GROQ_API_KEY="gsk_..."
```

### 2. Create a config file

Copy [`config.example.toml`](config.example.toml) to the platform config directory:

| OS | Path |
|---|---|
| Linux | `~/.config/zhisper/config.toml` |
| Windows | `%APPDATA%\zhisper\config.toml` |
| macOS | `~/Library/Application Support/zhisper/config.toml` |

The file is entirely optional — the defaults work out of the box. Every key is documented inline in `config.example.toml`.

### 3. Run it

```sh
zig build run            # from a checkout
./zig-out/bin/zhisper    # an installed binary
```

Hold the record key and talk.

## Usage

```
usage zhisper [options...]

options:
  -h, --help                     print this help and exit
      --provider=<str>           groq|openai|custom|deepgram
      --model=<str>              model (empty = preset)
      --base-url=<str>           base URL (provider=custom only)
      --prompt=<str>             transcription prompt
      --language=<str>           language tag (deepgram; empty = auto)
      --hotkey=<str>             record shortcut (default meta+f9)
      --mode=<str>               hold | toggle
      --cancel=<str>             cancel shortcut (default meta+f8)
      --clipboard=<str>          clipboard shortcut (default meta+f10)
      --search=<str>             search shortcut (default off)
      --key-code=<uint>          deprecated: use --hotkey
      --evdev=<str>              Linux evdev path/name:DEV (empty = auto-scan)
      --device=<str>             mic (empty = default)
      --list-devices             list mics and exit
      --wav-path=<str>           wav output path
      --min-duration-ms=<uint>   drop clips below this length (ms)
      --keep-wav                 keep WAV on error
      --no-keep-wav              don't keep WAV on error
  -v, --verbose                  verbose logging
```

Precedence is **CLI > env > config file > defaults**.

A few things worth knowing:

- **`--list-devices`** prints every capture device the backend can see. Feed the name (or a substring of it) to `[audio] device` or `--device`.
- **`--mode=toggle`** switches to press-to-start / press-to-stop instead of hold-to-talk.
- **Clips under `min_duration_ms`** (default 500) are discarded without an API call. A too-short clip and a silent clip are both reported, so "nothing happened" always has a reason.
- **Trailing newlines are stripped** by default (`daemon.trailing_newline = "strip"`). Whisper output routinely ends in a newline, and emitting that as a real Return can submit a chat message mid-sentence. Set it to `"send"` if you want it.
- **SIGINT / SIGTERM** drain the active job plus one waiting job, then exit. On Windows the process exits abruptly instead.
- **Linux only** — global hotkeys need access to a keyboard device. Either run with permission to read `/dev/input/event*`, or point at a specific one:
  ```sh
  zhisper --evdev=/dev/input/event5     # explicit, stable but breaks if event numbers change
  zhisper --evdev=name:kanata            # by device name, survives reboots (recommended)
  ```

## Configuration

`config.example.toml` is the reference. The shape:

```toml
[transcribe]
provider = "groq"
model = ""
base_url = ""
prompt = ""
language = ""
keyterm = ""

[hotkey]
shortcut = "meta+f9"   # hold to record; release to transcribe
cancel = "meta+f8"     # discard the recording in progress
clipboard = "meta+f10" # record, then put the transcript on the clipboard
search = "off"         # record, then search for the transcript
mode = "hold"          # hold | toggle
evdev = ""             # Linux only, explicit /dev/input/eventN
evdev_name = ""        # Linux only, device name match e.g. "kanata"

[audio]
device = ""              # empty = system default mic

[normalize]
enabled = false

[daemon]
min_duration_ms = 500
wav_path = ""            # empty = platform temp dir
trailing_newline = "strip"
type_delay_ms = 0
keep_wav_on_error = true
overlay = true
tray = false
notify = "errors,clipboard"
verbose = false
```

Notes:

- The config is **strict**. An unrecognized key is a startup error rather than a silent no-op, so a typo tells you immediately instead of doing nothing.
- `daemon.notify` accepts `off`, `errors`, `clipboard`, or `errors,clipboard`. It covers the outcomes that otherwise leave you guessing: too-short clip, silent clip, dropped waiting clip, transcription failure, empty transcript, clipboard failure, and clipboard ready (with a short preview).
- `daemon.overlay` and `daemon.tray` are independent — the tray icon reflects state even when the floating pill is off, and vice versa.
- `daemon.verbose` adds one metadata line per API call (model, payload sizes, status, latency, upstream error body). It never logs keys, audio, or transcripts.

## Tray menu (Linux)

Right-click the tray icon to change a setting. The selection is written to `config.toml` with every comment and every other line left untouched, and it applies immediately, with no restart.

| Menu row | Config key it writes |
|---|---|
| Hotkey mode | `hotkey.mode` |
| Normalize | `normalize.enabled` |
| Styling | `normalize.styling` |
| Structure | `normalize.structure` |
| Context | `normalize.context` |
| Provider | `transcribe.provider`, plus `transcribe.model` and `transcribe.base_url` set to `""` so the new provider's preset applies |
| Overlay | `daemon.overlay` |

- Each provider reads only its own key variable, so export every key you may switch to: `GROQ_API_KEY`, `OPENAI_API_KEY`, `DEEPGRAM_API_KEY`. A provider whose key is absent is greyed out, because the daemon reads the environment only at startup.
- Every other key is still read once at startup. Hand edits to those keys need a restart; only the rows in the table above apply live.
- The menu is Linux-only for now. On Windows and macOS the icon works as before, without a menu.
- The root menu lists the bound shortcuts and cannot change them.

## Shortcuts

A binding is `modifier+key`. `meta` is required, `shift` is optional. `meta` means Super on Linux, Win on Windows, Command on macOS.

`ctrl` and `alt` are rejected on purpose: holding them while the transcript is typed turns letters into control characters or menu accelerators. A config with `ctrl+8` fails at startup and says so.

Key names are portable, so the same config works on Linux and Windows:

| Group | Names |
|---|---|
| Letters | `a`–`z` |
| Digits | `0`–`9` |
| Function keys | `f1`–`f24` |
| Named keys | `space`, `enter` (`return`), `tab`, `esc` (`escape`), `backspace`, `delete` (`del`), `insert`, `home`, `end`, `pageup`, `pagedown`, `left`, `right`, `up`, `down`, `minus`, `equal`, `comma`, `period`, `slash`, `backslash`, `semicolon`, `quote`, `bracketleft`, `bracketright`, `grave` |

The key name is the physical key: `meta+shift+1` is the 1 key with meta and shift, not the `!` character.

A chord fires only while every modifier is down, in any press order, and stops when any of them is released.

| Setting | Default | Meaning |
|---|---|---|
| `shortcut` | `meta+f9` | Press-and-hold to record; release to stop and transcribe |
| `cancel` | `meta+f8` | Discard the recording in progress |
| `clipboard` | `meta+f10` | Record, then put the transcript on the clipboard instead of typing it |
| `search` | `off` | Record, then search for the transcript |
| `mode` | `hold` | `hold` = talk while held, `toggle` = press to start, press to stop |

`""` keeps the default and `"off"` disables an action. With the clipboard on by default, an empty value cannot also mean off.

Defaults changed: a config with no `[hotkey]` section now records on `meta+f9`, cancels on `meta+f8`, and puts the transcript on the clipboard on `meta+f10` instead of typing it. A recording started with `meta+f10` goes to the clipboard, not into the focused app. Search stays off.

The defaults are the old bare keys with a `meta` chord on them, so an upgrade from `key_code = 67` keeps the same key, now with Super/Win.

The old numeric settings (`key_code`, `cancel_key_code`, `clipboard_key_code`, `search_key_code`) still work with no modifier and log a deprecation line. A shortcut string wins over a number for the same action. Numeric codes remain accepted for old configs.

The tray menu shows the bound shortcuts as read-only rows.

## Environment variables

| Variable | Purpose |
|---|---|
| `GROQ_API_KEY` / `OPENAI_API_KEY` | Key for the matching provider |
| `DEEPGRAM_API_KEY` / `CUSTOM_API_KEY` | Key for the Deepgram and custom providers |
| `ZHISPER_LANGUAGE` | Language tag for Deepgram (empty = auto) |
| `ZHISPER_KEYTERM` | Comma-separated terms for Deepgram to boost |
| `ZHISPER_DEBUG` / `ZHISPER_VERBOSE` | Enable debug logging on stdout (errors always log to stderr) |
| `TMPDIR` / `TMP` / `TEMP` | Where the WAV scratch file goes when `wav_path` is empty |

## Optional text normalization

Whisper gives you words, not prose. A second, off-by-default API call rewrites the transcript into clean written text: self-corrections resolved, spoken numbers and dates converted, filler words dropped, punctuation fixed.

```toml
[normalize]
enabled = true
styling = "semi-formal"   # casual | semi-casual | semi-formal | formal
structure = "prose"      # prose | lists
context = "general"      # general | email
```

- The normalizer resolves its own API key in this order: `GROQ_API_KEY`, then `OPENAI_API_KEY`. It never reads or falls back to `DEEPGRAM_API_KEY` or `CUSTOM_API_KEY`.
- This section is **watched at runtime**: flip `enabled` and it takes effect within a second, no restart.
- `base_url` can point at any OpenAI-compatible chat-completions endpoint, so the normalizer can run locally or on a different provider without recompiling.
- The three axes are closed sets; a value outside them is rejected at startup because the prompt format was only trained on these combinations.
- It costs one extra network round trip per recording, and it is **best-effort** — any failure falls back to the raw transcript rather than blocking dictation.

## Development

```sh
zig build test                       # the gate — must pass
RECORD_LIVE=1 zig build test         # opt-in real-mic smoke test
TRANSCRIBE_LIVE=1 zig build test     # opt-in real transcription test
NORMALIZE_LIVE=1 zig build test      # opt-in normalization comparison
ZHISPER_DEBUG=1 ./zig-out/bin/zhisper # debug logs
```

`test.sh` is a local convenience script for a live run against a real device; it is not part of CI.

Every OS-dependent feature follows the same seam: `feature.zig` picks the backend at comptime, the native code lives in `feature_<os>.zig`, shared types live in `feature_types.zig`, and `feature_stub.zig` provides an in-memory fake for tests. New OS-touching code is expected to copy that layout.

**Dependencies** (all fetched by `zig build`, never vendored by hand):

| Package | Used for |
|---|---|
| [miniaudio](src/miniaudio.c) | Microphone capture, device enumeration |
| [SDL3](https://codeberg.org/7Games/zig-sdl3) | Overlay pill rendering |
| [zstbi](https://github.com/zig-gamedev/zstbi) | Image decoding (Linux tray icons) |
| [sam701/zig-toml](https://github.com/sam701/zig-toml) | Config parsing |
| [argz](https://codeberg.org/chocapix/argz) | CLI argument parsing |

## Project layout

```
src/
  main.zig          daemon loop, work queue, signal handling
  root.zig          library entry point + test registration
  cli.zig           argv parsing
  config.zig        TOML config, env/CLI layering, validation
  audio.zig         miniaudio capture, WAV assembly
  wav.zig           WAV header writer
  transcribe.zig    Whisper-compatible transcription request
  normalize.zig     optional clean-written-text pass
  inject*.zig       keystroke injection (per OS)
  clipboard*.zig    clipboard write (per OS)
  hotkey*.zig       global hotkeys (per OS)
  overlay*.zig      floating status pill (SDL3)
  tray*.zig         system tray icon (per OS)
  notify*.zig       desktop notifications (per OS)
  log.zig           scoped logging
```

## License

See the repository for license terms.
