# AGENTS.md

## Project: MeetingAssistant

You are implementing a local real-time meeting transcription assistant for macOS.

The final system will:

1. Capture the user's microphone separately.
2. Capture conference/system audio through BlackHole 2ch.
3. Transcribe both sources in real time with WhisperKit.
4. Mark the local microphone stream as `YOU`.
5. Diarize and identify speakers in the remote stream.
6. Maintain a timestamped meeting transcript.
7. Feed finalized transcript events into a local LLM through Ollama.
8. Maintain a live contextual briefing:
   - current topic;
   - facts;
   - decisions;
   - open questions;
   - action items;
   - owners;
   - deadlines;
   - useful clarification questions.

The system must work locally on macOS without requiring cloud transcription.

---

# Current milestone

Do NOT implement the complete system yet.

The current milestone is:

> Capture two live audio sources simultaneously and produce stable real-time WhisperKit transcription for both.

The two sources are:

```text
REMOTE = BlackHole 2ch
YOU    = physical MacBook microphone
```

Expected terminal output:

```text
[00:03.420] REMOTE: Добрый день, коллеги.
[00:05.870] YOU: Добрый день. Давайте начинать.
[00:09.120] REMOTE: Тогда первый вопрос касается релиза.
```

Only finalized / confirmed transcription should eventually be emitted as transcript events.

Do not send unstable partial hypotheses downstream as finalized utterances.

---

# Environment

Target machine:

```text
macOS
Apple Silicon
MacBook Pro M4 Pro
48 GB RAM
```

Audio routing is already configured.

System/conference output is routed through:

```text
Multi-Output Device
├── physical speakers/headphones
└── BlackHole 2ch
```

BlackHole is known to work.

WhisperKit is installed and has already successfully transcribed test WAV files.

The WhisperKit model currently used for testing is:

```text
large-v3-v20240930_626MB
```

Primary language:

```text
Russian
```

Conversations can contain English technical terms.

---

# Important architecture constraint

Never mix the microphone and remote conference audio before transcription.

They must remain two independent logical streams:

```text
                    ┌── WhisperKit ──> YOU
MacBook Microphone ─┤

                    ┌── WhisperKit ──> REMOTE
BlackHole 2ch ──────┤
```

This is intentional.

Because the local microphone is isolated, anything coming from that source can automatically be assigned:

```text
speaker = YOU
```

No speaker recognition is needed for the local microphone.

Speaker diarization will later be applied ONLY to the `REMOTE` stream.

---

# Audio requirements

Prefer native macOS APIs:

```text
CoreAudio
AVFoundation
```

Audio devices must be selected explicitly by device ID.

Do not rely on changing the global macOS default input device.

The application should discover available audio devices and identify at minimum:

```text
BlackHole 2ch
MacBook microphone
```

Do not hardcode numeric AudioDeviceID values because they may change after reboot or reconnection.

Resolve devices by name and retain the resulting AudioDeviceID.

Provide useful diagnostic output when devices are enumerated.

Example:

```text
Audio devices:

[65] MacBook Pro Microphone
[72] BlackHole 2ch
[81] MacBook Pro Speakers

Selected:
YOU    -> 65
REMOTE -> 72
```

If a requested device cannot be found, fail with a clear error.

---

# Audio format

The macOS capture side may operate at the device's native sample rate, typically:

```text
48 kHz
```

Do not unnecessarily force the hardware device itself to 16 kHz.

Perform conversion/resampling only where required by the transcription pipeline.

Internally prefer:

```text
Float32 PCM
mono for ASR
```

Do not introduce lossy codecs anywhere in the live processing pipeline.

---

# Clock and timestamps

Every captured audio stream must use a monotonic timeline.

Transcript events need timestamps relative to meeting start.

Example:

```json
{
  "start": 12.420,
  "end": 15.810,
  "source": "REMOTE",
  "text": "Следующий релиз планируется на пятницу."
}
```

Do not use wall-clock time as the primary synchronization mechanism between audio streams.

Use a monotonic clock.

The eventual system must allow transcript events from the two audio sources to be merged chronologically.

---

# WhisperKit

Use WhisperKit as the ASR engine.

Do not invent WhisperKit APIs.

IMPORTANT:

Before implementing an API call:

1. Inspect the actual WhisperKit / argmax-oss-swift source version resolved by Swift Package Manager.
2. Verify the exact public API.
3. Prefer existing public APIs over copying internal WhisperKit implementation.
4. Do not assume examples found in old WhisperKit releases still match the current package.

If `AudioStreamTranscriber`, `AudioProcessor`, `WhisperKit`, or device-selection APIs differ from expectations, adapt to the actual resolved version.

Do not silently work around API incompatibilities.

Document significant compatibility decisions in code comments.

---

# Streaming transcription behavior

The live transcription pipeline should distinguish between:

```text
partial / unconfirmed
confirmed / finalized
```

Partial text may be displayed for diagnostics.

Only confirmed/finalized text should become permanent transcript events.

Avoid emitting the same finalized segment multiple times.

Each emitted transcript event must have at least:

```swift
source
startTime
endTime
text
```

Suggested logical model:

```swift
enum AudioSource {
    case you
    case remote
}

struct TranscriptEvent {
    let source: AudioSource
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
}
```

Exact implementation may differ if there is a good reason.

---

# Concurrency

The microphone and BlackHole pipelines must run concurrently.

Do not serialize them such that transcription of one source blocks capture of the other.

Prefer modern Swift concurrency:

```text
async/await
Task
Actor
AsyncStream
```

where appropriate.

Avoid unnecessarily complex concurrency abstractions.

Protect mutable shared transcript state from data races.

The audio callback itself must remain lightweight.

Do not perform expensive model inference directly inside a realtime CoreAudio callback.

---

# Backpressure

The capture layer must remain stable if transcription briefly runs slower than realtime.

Use bounded buffering where appropriate.

Do not allow unlimited memory growth.

If the pipeline cannot keep up, report this clearly in logs.

Do not silently discard large amounts of audio.

---

# Logging

For now the application is a CLI tool.

Logs should make troubleshooting simple.

Recommended startup diagnostics:

```text
MeetingAssistant starting...

Finding audio devices...
YOU    -> MacBook Pro Microphone [65]
REMOTE -> BlackHole 2ch [72]

Loading WhisperKit...
Model: large-v3-v20240930_626MB
Language: ru

Starting audio capture...
YOU stream ready
REMOTE stream ready

Transcription started.
```

Transcript output should remain visually distinct from diagnostic logs.

Example:

```text
[00:14.220] [YOU]    Когда будет готов документ?
[00:17.830] [REMOTE] Ориентировочно в пятницу.
```

---

# Project structure

Prefer a small modular structure such as:

```text
MeetingAssistant/
├── Package.swift
├── AGENTS.md
└── Sources/
    └── MeetingAssistant/
        ├── main.swift
        ├── Audio/
        │   ├── AudioDeviceManager.swift
        │   ├── AudioCapture.swift
        │   └── AudioSource.swift
        ├── Transcription/
        │   ├── WhisperTranscriber.swift
        │   └── TranscriptEvent.swift
        └── Meeting/
            └── MeetingSession.swift
```

Do not create abstractions merely for architectural appearance.

Keep the project easy to understand and debug.

---

# Implementation order

Work incrementally.

## Phase 1 — Audio device discovery

Implement enumeration of macOS audio devices.

Acceptance criteria:

```text
swift run
```

shows BlackHole and the microphone and resolves their IDs.

Do not continue until this works.

---

## Phase 2 — Dual audio capture

Open both devices simultaneously.

Capture:

```text
YOU
REMOTE
```

independently.

For debugging, optionally calculate RMS/peak levels.

Example:

```text
YOU    level: -27 dB
REMOTE level: -14 dB
```

Acceptance criteria:

- speaking into the microphone changes only the YOU level significantly;
- playing system audio changes the REMOTE level;
- both streams can run simultaneously for several minutes;
- there are no obvious dropouts or audio-buffer errors.

---

## Phase 3 — Single-stream live WhisperKit

Connect ONE live source to WhisperKit first.

Start with:

```text
REMOTE / BlackHole
```

Acceptance criteria:

- system audio produces live Russian transcription;
- continuous speech works for several minutes;
- finalized segments are emitted without excessive duplicates.

---

## Phase 4 — Dual live WhisperKit

Connect both sources.

Acceptance criteria:

```text
REMOTE -> WhisperKit
YOU    -> WhisperKit
```

run simultaneously.

Terminal should produce chronologically timestamped output.

Example:

```text
[00:05.100] [REMOTE] Коллеги, всем добрый день.
[00:08.320] [YOU] Добрый день.
[00:10.870] [REMOTE] Давайте начнем.
```

---

## Phase 5 — Stability

Run a longer test.

Target:

```text
30–60 minutes
```

Check:

- memory does not continuously grow;
- no growing transcription delay;
- no repeated finalized segments;
- no dropped audio caused by blocked callbacks;
- both streams remain synchronized sufficiently for meeting transcription.

Only after this phase succeeds should diarization be added.

---

# Explicitly out of scope for the current milestone

Do NOT yet implement:

```text
FluidAudio
speaker diarization
speaker embeddings
speaker identification
voice profiles
SQLite persistence
Ollama
Qwen
RAG
contextual briefing
meeting summary
action-item extraction
GUI
menu bar application
network APIs
cloud services
```

These belong to later milestones.

Do not introduce them prematurely.

---

# Future architecture

After dual-stream ASR is stable, the intended pipeline becomes:

```text
                              ┌── WhisperKit ─────────────┐
MacBook microphone ───────────┤                           ├── YOU events
                              └───────────────────────────┘


                              ┌── WhisperKit ─────────────┐
BlackHole ────────────────────┤                           ├── text
                              └───────────────────────────┘
                                         +
                              ┌── FluidAudio ─────────────┐
BlackHole ────────────────────┤                           ├── speaker
                              └───────────────────────────┘
                                         │
                                         ▼
                                  Timeline merger
                                         │
                                         ▼
                                   Transcript store
                                         │
                                         ▼
                                    Ollama / Qwen
                                         │
                                         ▼
                              Live contextual briefing
```

---

# Speaker diarization — later phase

The `REMOTE` stream will later be passed through FluidAudio.

Desired conceptual result:

```text
REMOTE speaker_1 -> Алексей
REMOTE speaker_2 -> Лариса
REMOTE speaker_3 -> Unknown-3
```

The application will eventually maintain voice embeddings/profiles so the same person can be recognized across meetings.

Do not implement this yet.

However, avoid architecture choices that would make access to the original REMOTE audio stream difficult later.

---

# Context engine — later phase

Confirmed transcript events will eventually be sent to a local LLM using Ollama.

The LLM must NOT receive the entire meeting transcript on every update.

The intended approach is:

```text
previous structured state
+
new finalized transcript events
=
new structured state
```

Future state example:

```json
{
  "topic": "Перенос релиза",
  "facts": [],
  "decisions": [],
  "open_questions": [],
  "actions": []
}
```

The contextual state will normally be refreshed approximately every 30–60 seconds rather than after every token.

Do not implement this yet.

---

# Privacy

The application is intended for local processing.

Do not introduce:

```text
cloud transcription
remote analytics
telemetry
remote logging
external speech APIs
```

unless explicitly requested.

Audio and transcript data should remain local.

---

# Error handling

Prefer explicit failure to silent fallback.

Examples:

Bad:

```text
BlackHole not found -> silently use default microphone
```

Good:

```text
ERROR: Required audio device "BlackHole 2ch" was not found.

Available input devices:
- MacBook Pro Microphone
- External USB Microphone
```

Never accidentally substitute the microphone for BlackHole or vice versa.

---

# Development rules

After each meaningful change:

```bash
swift build
```

Fix compiler warnings when practical.

Before considering a phase complete:

```bash
swift run
```

and perform the relevant real audio test.

Do not make large unrelated refactors while fixing a small issue.

Keep commits/changes conceptually focused.

If an implementation decision depends on an uncertain macOS or WhisperKit behavior, inspect the corresponding framework/package source instead of guessing.

---

# Documentation

Keep `README.md` updated with:

1. prerequisites;
2. BlackHole setup;
3. Multi-Output Device setup;
4. build command;
5. run command;
6. expected device names;
7. troubleshooting.

Do not duplicate the full internal architecture in README.

`AGENTS.md` is the engineering instruction source.

---

# Definition of Done for current milestone

The current milestone is complete only when all of the following work:

```text
✓ BlackHole is discovered programmatically
✓ MacBook microphone is discovered programmatically
✓ both devices are opened simultaneously
✓ both streams remain separate
✓ both streams can be captured continuously
✓ WhisperKit transcribes REMOTE live
✓ WhisperKit transcribes YOU live
✓ YOU events are tagged YOU
✓ REMOTE events are tagged REMOTE
✓ finalized segments are not repeatedly emitted
✓ events contain timestamps
✓ terminal output merges events chronologically
✓ application runs without changing global macOS input device
✓ several-minute test works without growing delay
```

Do not proceed to speaker diarization until these requirements are satisfied.

---

# Guiding principle

Build the pipeline from the bottom up:

```text
audio correctness
    ↓
stable capture
    ↓
stable transcription
    ↓
speaker diarization
    ↓
speaker identification
    ↓
persistent transcript
    ↓
LLM context
    ↓
user interface
```

If a lower layer is unstable, do not hide the problem with logic in a higher layer.