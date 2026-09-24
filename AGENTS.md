# AGENTS.md — zhisper

Voice-to-text daemon (push-to-talk → mic capture → Groq/OpenAI transcription → keystroke injection).
Zig 0.16.0 (`minimum_zig_version = "0.16.0"` in `build.zig.zon`). Pinned toolchain: `zig version` → `0.16.0`.

## Build / test / run

```sh
zig build              # install to zig-out/bin/zhisper
zig build run          # run daemon (args after -- : zig build run -- --help)
zig build run -- --list-devices
zig build test         # ALL tests (library + exe modules, runs in parallel)
zig fmt                # format before committing (CI expects clean fmt)
zig build -Dtarget=x86_64-windows   # cross-compile check (also try x86_64-macos)
```

- Deps come from `build.zig.zon` hashes (`toml`, `argz`, `sdl3`). Fetch with `zig fetch --save <url>`; never hand-edit hashes.
- `zig-pkg/`, `.zig-cache/`, `zig-out/` are gitignored build artifacts. Never commit them.
- Config: copy `config.example.toml` to OS config dir (see `resolveConfigPath` in `src/main.zig`); secrets are **env-only** (`ZHISPER_API_KEY` / `GROQ_API_KEY` / `OPENAI_API_KEY`). `api_key` in TOML is a hard `error.ApiKeyInFile`.
- Debug logs: `ZHISPER_DEBUG=1` / `ZHISPER_VERBOSE=1` or `--verbose` / `verbose = true`. `test.sh` is a local-only manual run helper, not CI.

## Core rules (user-mandated, non-negotiable)

1. **Library-first: never hand-roll what exists.** Before writing a parser, CLI parser, TOML reader, audio backend, HTTP client, overlay helper, etc. from scratch, research existing C/Zig packages (Zig package index, GitHub/Codeberg, `zig fetch`-able repos, system C libs). Prefer a maintained package; vendor C sources via `build.zig` (`addCSourceFile` / `addIncludePath`) like `src/miniaudio.c` + SDL3 today. Only hand-roll when no suitable library exists — and say so in the PR/commit message.
2. **Cross-platform by default.** Every change must compile and behave on Linux, Windows, and macOS. Use `zig build -Dtarget=<triple>` to verify the other OSes when touching OS-adjacent code. No Linux-only syscalls, paths, env vars, or keycodes in shared code. Use `std.fs.path.sep_str`, `std.Io`, and OS config-dir helpers; never hardcode `/tmp`, `/dev/*`, `HOME`-only, or `\` vs `/`.
3. **OS-native code lives in separate files behind a seam.** Pattern (already established — follow it):
   - `feature.zig` — seam: re-exports types from `feature_types.zig`, picks impl via `comptime switch (builtin.os.tag)`, exposes one stable API.
   - `feature_linux.zig` / `feature_windows.zig` / `feature_macos.zig` — native impls only.
   - `feature_types.zig` — pure-Zig shared types (no OS headers, safe on all targets incl. tests).
   - `feature_stub.zig` — in-memory fake used when `builtin.is_test` is true.
   - Current examples: `hotkey*.zig`, `inject*.zig`, `clipboard*.zig`, `overlay*.zig` (+ `overlay_sdl.zig` backend). New OS-dependent features MUST copy this layout. Shared logic (e.g. `overlayPosPath`, `loadOverlayPos`) may live in the seam only if it branches on `builtin.os.tag` at comptime and has test coverage.

## Seam template (copy-paste)

```zig
const builtin = @import("builtin");
const impl = if (builtin.is_test)
    @import("feature_stub.zig")
else switch (builtin.os.tag) {
    .linux => @import("feature_linux.zig"),
    .windows => @import("feature_windows.zig"),
    .macos => @import("feature_macos.zig"),
    else => @compileError("feature: unsupported OS"),
};
pub fn setup(...) !void { return impl.setup(...); }
```

- Untaken comptime branches are never analyzed — use this to keep heavy headers (SDL, `linux/input.h`) out of `zig build test` (see `src/overlay.zig` comment).
- `src/root.zig` is the library entry point: every new module needs a `pub const` export there **and** a `refAllDecls` line in its `test` block. Linux-only test imports stay inside `if (builtin.os.tag == .linux)` (Windows/macOS headers don't parse on Linux test runs and vice versa).

## Zig 0.16 specifics (this repo's dialect)

- **Thread `std.Io` explicitly.** Any function doing I/O, sleep, time, files, or subprocess takes `io: std.Io` as a param (`std.testing.io` in tests). Never use removed pre-0.16 APIs (`std.posix.write`, `std.posix.pipe`, old `std.fs` blocking calls).
- **Allocators are explicit.** `std.ArrayList` is unmanaged-style: `var l: std.ArrayList(T) = .empty` + pass allocator per call (`appendSlice(gpa, ...)`, `deinit(gpa)`). Daemon-lifetime memory uses the arena from `main(init: std.process.Init)`; short-lived copies use `gpa.dupe` + documented `freeConfig`-style owner (see `src/config.zig`: `dupeConfig`/`freeConfig` pair — never free `defaultConfig()` literals).
- **Errors, not panics.** Return error unions; `defer`/`errdefer` for cleanup (tmp-file + rename in `audio.setRecording(.stop)` so Whisper never sees a half-file). `catch {}` only for best-effort paths (overlay, log flush). Fail fast with named errors (`error.DeviceNotFound`, `error.CancelEqualsHotkey`) and print actionable hints (list mics on `DeviceNotFound`).
- **C interop.** This codebase still uses `@cImport` (miniaudio, `linux/input.h`, `sys/ioctl.h`) with `.link_libc = true` + `mod.addIncludePath(b.path("src"))` + `addCSourceFile`. One `@cImport` per domain; note upstream `@cImport` is deprecated in favor of `b.addTranslateC` — do not migrate without asking, but new C deps should prefer `addTranslateC` + `linkSystemLibrary` if clean. C callbacks are `callconv(.c)`; foreign-thread callbacks (miniaudio `dataCallback`) must never block on `std.Io` — use `std.atomic` spinlock, never `std.Io.Mutex` there.
- **No `std.os.linux` writes of Zig `std.posix` helpers that don't exist in 0.16** — check `hotkey_linux.zig` for the established raw-syscall + libc-`ioctl` errno pattern before inventing new wrappers.
- **Logging.** `std.log.scoped(.daemon/.hotkey/.inject/.transcribe)` through `src/log.zig`: `.err` always prints to stderr; everything else gated by `ZHISPER_DEBUG`/`ZHISPER_VERBOSE`/config `verbose`. Command output (`--list-devices`) goes to stdout and is never gated.
- **Comments explain WHY, not what.** Follow the existing `// WHY ...` style for non-obvious kernel/ABI quirks (ioctl encoding, evdev scan range, pipe2+NONBLOCK in tests). Keep `cli.zig` `help_text` short — argz scans it at comptime under a branch quota; long docs go in `config.example.toml`.

## Cross-platform checklist (apply to every diff)

- [ ] No new shared-code reference to `/dev/*`, `/sys/*`, `/tmp`, `APPDATA`/`HOME` without a per-OS branch. Config/state paths: Windows `%APPDATA%\zhisper\`, macOS `~/Library/Application Support/zhisper/`, Linux `~/.config/zhisper/` (see `resolveConfigPath`, `overlayPosPath`).
- [ ] POSIX-only APIs (signals, `sigaction`, evdev, `uinput`) guarded by `if (comptime builtin.os.tag != .windows)` so Windows prunes them at comptime.
- [ ] Keycodes/config values documented as OS-native (Linux `KEY_F9=67` ≠ Windows/macOS codes); `0` = disabled convention for optional keys.
- [ ] New dependency builds for all three targets (C sources compile per-target; SDL3 first build is slow — that's expected).
- [ ] `zig build test` passes; if touching audio/hardware paths, note `RECORD_LIVE=1 zig build test` opt-in smoke test.

## Testing conventions

- `zig build test` is the gate. Tests live next to code in `test "..."` blocks.
- Facade tests drive the stub (`stub.reset(); defer stub.reset(); setup(...); pushTestEvent(...); expect...`), never hardware. OS impl tests that need real devices use `/sys` probes with `error.SkipZigTest` fallback or pipe fixtures (see `hotkey_linux.zig` pipe2 tests).
- Fixed `/tmp/zhisper-*-test-*.pos|wav` filenames are OK (single test binary, sequential). Always `defer deleteFile` + `clearRetainingCapacity`/`deinit` to satisfy `std.testing.allocator`.
- New features need: stub unit tests + seam facade test + `refAllDecls` registration in both `src/root.zig` and (if CLI-facing) `src/main.zig`.

## What NOT to do

- Don't add a dependency without updating `build.zig` + `build.zig.zon` together, and don't vendor a C library by copying headers into `src/` without wiring `addIncludePath`/`addCSourceFile`.
- Don't put `std.debug.print` in library code — use scoped `std.log`.
- Don't store structs with borrowed slices beyond the parse arena — copy with `dupeConfig`-style ownership and document who frees.
- Don't use `anytype` or globals to dodge `std.Io`/allocator threading.
