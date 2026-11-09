<p align="center">
    <img src="Assets/icon.png" width="170" />
</p>
<h1 align="center">JarBox</h1>

JarBox is a J2ME (Java ME) emulator for iOS that runs MIDP 2.0 / CLDC 1.1 games and applications on iPhone and iPad.

Built on top of [miniJVM](https://github.com/niclet/mini_jvm) (a lightweight JVM written in C) with the J2ME API layer ported from [J2ME-Loader](https://github.com/niclet/J2ME-Loader) (Android).

## AI-assisted development

This project was almost entirely built using [Claude Code](https://claude.ai/claude-code) as an experiment in applying LLMs to non-trivial codebases. The emulator involves C, Objective-C, Swift, Java, and OpenGL — spanning ~180k+ lines across multiple languages — and the vast majority of the code, debugging, and integration work was done through conversational interaction with Claude.

## Features

- **MIDlet lifecycle** — load and run J2ME apps from JAR files
- **2D rendering** — software renderer following the MIDP pixel rules; alpha, clipping, all 8 transforms
- **Game API** — GameCanvas, Sprite, TiledLayer, LayerManager
- **3D graphics** — MascotCapsule micro3D (OpenGL ES 2.0) and M3G JSR-184 (OpenGL ES 1.1)
- **Audio** — WAV/MP3 (AVAudioPlayer), MIDI (AVMIDIPlayer + SoundFont), ToneControl
- **Forms UI** — Form with every Item type, List, Alert, TextBox as native UIKit views
- **RMS** — RecordStore persistence via file system
- **Networking** — TCP with timeouts, UDP, server sockets, HTTP/HTTPS; works on IPv6-only networks
- **Input** — J2ME Loader-style keyboard, 8-way joystick, per-brand key codes, editable layouts per game
- **OEM extensions** — Nokia, Siemens, Samsung, Motorola, Vodafone, KDDI, JBlend, SprintPCS, SonyEricsson
- **Per-game settings** — resolution, FPS, scaling, sound, key profiles, JVM heap, compatibility, backups

## Architecture

```
┌─────────────────────────────────────────┐
│         iOS App (Swift / UIKit)         │
│   App list, game screen, virtual keys   │
├─────────────────────────────────────────┤
│        Native Bridge (C / Obj-C)        │
│  Rendering, audio, input, 3D (OpenGL)   │
├─────────────────────────────────────────┤
│       J2ME API (Java, j2me_api.jar)     │
│  MIDP/CLDC classes ported from          │
│  J2ME-Loader with iOS native calls      │
├─────────────────────────────────────────┤
│            miniJVM (C)                  │
│  Bytecode interpreter, GC, threading    │
└─────────────────────────────────────────┘
```

## Building

**Requirements:** macOS with Xcode 26+, JDK 17+ (for compiling Java sources)

1. Build the J2ME API JAR: `bash j2me_api/build.sh`
2. Open `J2MEEmulator.xcodeproj` in Xcode, select a device or simulator, and run.

GitHub Actions builds an unsigned IPA (`build-ipa.yml`) and runs the app in the iOS Simulator with test MIDlets (`simulator-test.yml`).

## Testing

| Tool | Purpose |
|---|---|
| `tools/hostrun` | Runs a real MIDlet on the real JVM and MIDP layer on Windows, scripted, with screenshots |
| `test_midlet/selftest` | Automatic checks: JVM, MIDP, pixel rules, threads, RMS, sockets |
| `test_midlet/demo` | Animated scene and interpreter benchmark |
| `tools/ApiCheck.java` | Compares the API against real MIDP / CLDC stubs, or lists what a game needs |

More in `docs/`: architecture, compatibility table, background behaviour, progress.

## Adding games

Place `.jar` files into the app's Documents directory (accessible via the Files app or Xcode device file transfer). The app scans for JARs on launch and lists them in the library.

## Per-game configuration

Each game row has buttons for play, settings and delete; the ⋯ menu also has rename, backup, restore and clear data.

## License

[Apache License 2.0](LICENSE)

## Acknowledgments

- [J2ME-Loader](https://github.com/niclet/J2ME-Loader) — J2ME API implementation for Android
- [miniJVM](https://github.com/niclet/mini_jvm) — lightweight cross-platform JVM in C
- [gs_instruments.sf2](https://schristiancollins.com/generaluser.php) — General MIDI SoundFont for MIDI playback
