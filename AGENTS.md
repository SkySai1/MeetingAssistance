# AGENTS.md

## Project: MeetingAssistant

You are implementing a local real-time meeting assistant for macOS.

The final product is a native macOS application that:

1. Captures the user's microphone separately.
2. Captures conference/system audio through BlackHole 2ch.
3. Transcribes both sources in real time with WhisperKit.
4. Marks the local microphone stream as `YOU`.
5. Diarizes the remote stream.
6. Identifies known speakers using stored voice profiles.
7. Maintains a timestamped transcript.
8. Feeds finalized transcript events into a model on the user-configured Ollama server.
9. Maintains a live contextual briefing.
10. Presents all major controls and results through a native SwiftUI graphical interface.
11. Works locally without requiring cloud transcription.

The system should evolve incrementally from a CLI prototype into a native macOS application.

---

# Product goal

The final user experience should be:

```text
Open MeetingAssistant
        ↓
check audio / models
        ↓
Start Meeting
        ↓
live transcript
+
speaker identification
+
context briefing
        ↓
Stop Meeting
        ↓
summary / decisions / actions / transcript
```

The end user should not need to understand:

```text
CoreAudio
WhisperKit internals
FluidAudio internals
speaker embeddings
Ollama API
BlackHole routing details
```

The application should expose only understandable configuration and status.

---

# Current milestone

Do NOT implement the complete system immediately.

Phases 1–6 and the basic Phase 7 GUI have been completed. The 30-minute dual-ASR stability test was accepted; implementation baseline is commit `22b55e0`.

The next milestone, reordered by the user on 2026-09-12, is:

> Configurable Ollama server and model selection, an editable system prompt, streaming meeting context that retains earlier events, a final meeting protocol displayed for copying, and API-driven model unloading after delivery.

Implement this as Phase 8 before diarization, voice profiles, and SQLite. See [OLLAMA_PLAN.md](OLLAMA_PLAN.md) for the implementation sequence and acceptance criteria. This is planned work, not functionality already present in the baseline.

The two sources are:

```text
REMOTE = BlackHole 2ch
YOU    = physical MacBook microphone
```

Preserve the existing dual-stream transcription and CLI output:

```text
[00:03.420] REMOTE: Добрый день, коллеги.
[00:05.870] YOU: Добрый день. Давайте начинать.
[00:09.120] REMOTE: Тогда первый вопрос касается релиза.
```

Only finalized / confirmed transcription should become permanent transcript events.

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

WhisperKit has already successfully transcribed test WAV files.

The WhisperKit model currently used for testing is:

```text
large-v3-v20240930_626MB
```

Primary language:

```text
Russian
```

Conversations may contain English technical terms.

---

# Core architectural rule

The application core MUST NOT depend on the CLI or SwiftUI layer.

Architecture should conceptually be:

```text
                MeetingAssistantCore
                        │
        ┌───────────────┼────────────────┐
        │               │                │
     Audio           Speech           Meeting
        │               │                │
        └───────────────┼────────────────┘
                        │
                 application state
                        │
              ┌─────────┴─────────┐
              │                   │
             CLI                SwiftUI
        development tool      final product
```

The CLI is a diagnostic/development interface.

SwiftUI is the final user-facing interface.

Do not place business logic directly inside SwiftUI views.

Do not make audio/transcription components depend on SwiftUI types.

---

# Important audio architecture constraint

Never mix the microphone and remote conference audio before transcription.

They must remain two independent logical streams:

```text
MacBook Microphone
        ↓
    WhisperKit
        ↓
       YOU


BlackHole 2ch
        ↓
    WhisperKit
        ↓
     REMOTE
```

This is intentional.

Because the local microphone is isolated, anything captured from that source can automatically be assigned:

```text
speaker = YOU
```

No speaker recognition is needed for the local microphone.

Speaker diarization and identification will later be applied ONLY to the `REMOTE` stream.

---

# Audio device handling

Prefer native macOS APIs:

```text
CoreAudio
AVFoundation
```

Audio devices must be selected explicitly by device ID.

Do not rely on changing the global macOS default input device.

The application must discover available audio devices and identify at minimum:

```text
BlackHole 2ch
MacBook microphone
```

Do not hardcode numeric AudioDeviceID values.

Resolve devices by name and retain their AudioDeviceID.

Example diagnostics:

```text
Audio devices:

[65] MacBook Pro Microphone
[72] BlackHole 2ch
[81] MacBook Pro Speakers

Selected:
YOU    -> 65
REMOTE -> 72
```

If a required device cannot be found, fail with a clear error.

Never silently substitute another device.

---

# Audio format

The capture side may operate at the device's native sample rate, usually:

```text
48 kHz
```

Do not unnecessarily force hardware to 16 kHz.

Perform resampling only where required.

Internally prefer:

```text
Float32 PCM
mono for ASR
```

Do not introduce lossy codecs in the live pipeline.

---

# Clock and timestamps

Every captured stream must use a monotonic timeline.

Transcript events must contain timestamps relative to meeting start.

Example:

```json
{
  "start": 12.420,
  "end": 15.810,
  "source": "REMOTE",
  "text": "Следующий релиз планируется на пятницу."
}
```

Do not use wall-clock time as the primary synchronization mechanism.

The system must allow events from YOU and REMOTE to be merged chronologically.

---

# WhisperKit

Use WhisperKit as the ASR engine.

Do not invent WhisperKit APIs.

Before implementing an API call:

1. Inspect the actual resolved version of WhisperKit / argmax-oss-swift.
2. Verify the exact public API.
3. Prefer public APIs over copied internal implementation.
4. Do not assume old examples still match the current package.

If APIs differ from expectations, adapt to the resolved source.

Document major compatibility decisions.

---

# Streaming transcription behavior

The pipeline must distinguish:

```text
partial / unconfirmed
confirmed / finalized
```

Partial text may be displayed temporarily.

Only confirmed/finalized text becomes a permanent transcript event.

Avoid duplicate finalized segments.

Each event must have at least:

```swift
source
startTime
endTime
text
```

Suggested model:

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

Exact implementation may differ if justified.

---

# Concurrency

The microphone and BlackHole pipelines must run concurrently.

Do not serialize them.

Prefer:

```text
async/await
Task
Actor
AsyncStream
```

where appropriate.

Protect shared transcript state from data races.

Realtime audio callbacks must remain lightweight.

Do not perform expensive model inference directly inside a CoreAudio callback.

---

# Backpressure

The capture layer must remain stable if transcription is briefly slower than realtime.

Use bounded buffering where appropriate.

Do not allow unlimited memory growth.

If the pipeline falls behind, expose this clearly in logs and later in the UI.

Do not silently discard large amounts of audio.

---

# Logging

During development, the CLI must provide useful diagnostics.

Example startup:

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

Transcript output:

```text
[00:14.220] [YOU]    Когда будет готов документ?
[00:17.830] [REMOTE] Ориентировочно в пятницу.
```

Logging infrastructure should later also feed user-friendly SwiftUI status indicators.

---

# Speaker diarization — later phase

After dual-stream ASR is stable, process only the REMOTE stream with FluidAudio.

Desired conceptual result:

```text
REMOTE speaker_1
REMOTE speaker_2
REMOTE speaker_3
```

Speaker diarization answers:

```text
who spoke when?
```

It does not assign real human identities by itself.

---

# Speaker identification — later phase

Known speakers will have voice profiles.

Conceptual enrollment:

```text
voice samples
    ↓
speaker embeddings
    ↓
profile centroid
    ↓
VoiceProfile("Алексей")
```

During a meeting:

```text
speaker segment
      ↓
embedding
      ↓
compare with profiles
      ↓
speaker identity
```

Do not use the LLM to determine speaker identity.

Speaker identification must remain an audio-model responsibility.

---

# Speaker confidence policy

Do not treat embedding similarity as a calibrated probability.

Store the raw similarity separately.

Suggested model:

```swift
enum SpeakerMatchState {
    case known
    case uncertain
    case unknown
}
```

Transcript events may later contain:

```swift
speakerID: String?
speakerName: String?
speakerSimilarity: Double?
speakerMatchState: SpeakerMatchState
```

Use configurable thresholds:

```text
HIGH_THRESHOLD
LOW_THRESHOLD
```

Decision logic:

```text
similarity >= HIGH_THRESHOLD
    -> known speaker

LOW_THRESHOLD <= similarity < HIGH_THRESHOLD
    -> uncertain speaker

similarity < LOW_THRESHOLD
    -> unknown speaker
```

Never automatically assign a known human identity below the high-confidence threshold.

Never automatically update a voice profile from an uncertain match.

Voice profiles may be updated only from:

- manually confirmed assignments;
- or explicitly enabled very-high-confidence samples.

Do not hardcode universal threshold values.

They must be calibrated on real meeting audio.

---

# Speaker correction UX — later GUI phase

The user must be able to correct unknown or incorrect speakers.

Example:

```text
Unknown-3
"Я согласую это с заказчиком."

[ Assign speaker ]
```

The user may choose:

```text
Максим
```

This correction should:

1. update affected transcript events;
2. optionally add confirmed audio embeddings to Максим's voice profile;
3. never silently alter historical identities without user confirmation.

---

# Transcript store

Once live transcription and speaker identification are stable, introduce persistent meeting storage.

Preferred first implementation:

```text
SQLite
```

Store at minimum:

```text
meeting
utterance
speaker
voice profile
context snapshot
```

A transcript event should conceptually contain:

```json
{
  "id": "utt_00482",
  "start": 317.4,
  "end": 322.8,
  "source": "REMOTE",
  "speakerId": "alexey",
  "speakerName": "Алексей",
  "speakerSimilarity": 0.91,
  "text": "Тогда релиз переносим на следующую неделю."
}
```

---

# Ollama integration

Ollama is the next analysis layer (Phase 8), before diarization and persistent meeting storage.

It must NOT receive raw audio.

Pipeline:

```text
audio
  ↓
WhisperKit (YOU + REMOTE; diarization is optional in a later phase)
  ↓
TranscriptEvent
  ↓
User-selected Ollama model
```

The server base URL must be configurable in native application settings. Default:

```text
http://127.0.0.1:11434
```

Support the user's HTTP(S) Ollama server, including a server on another machine. Display where AI processing happens. Audio stays on the Mac; only finalized text and its context are sent to the selected server.

Fetch the available model list from the configured server automatically and let the user choose. Provide refresh and connection status. Do not silently substitute a missing model or download models automatically.

Provide an editable, persisted system prompt with a default and reset action. Use it for both live context and the final protocol. Freeze server, model, and prompt for each meeting; changes apply to the next meeting.

Use verified public APIs: `GET /api/tags`, streaming `POST /api/chat`, `POST /api/generate` with `keep_alive: 0` to unload, and `GET /api/ps` to verify. API references and edge cases are documented in [OLLAMA_PLAN.md](OLLAMA_PLAN.md).

The application must remain useful when Ollama is unavailable.

For example:

```text
Transcription      AVAILABLE
Speaker ID         AVAILABLE
AI Context         UNAVAILABLE
```

Ollama failure must never stop audio capture or transcription.

---

# Context engine

Do not resend the full transcript to the LLM every time.

The application owns the conversation history; keeping a model loaded does not keep a meeting history for subsequent requests. Use incremental structured state with stable source event IDs, retained earlier facts/decisions/actions, a bounded recent excerpt, and all new finalized events:

```text
previous state
+
new finalized events
=
new state
```

Desired structure:

```json
{
  "topic": null,
  "facts": [],
  "decisions": [],
  "openQuestions": [],
  "actions": []
}
```

Schedule updates when finalized events arrive, coalescing them into small batches. An initial proposed interval is 10 seconds, configurable and adapted to generation speed. Skip empty updates and allow only one context request in flight per meeting.

Stream the generated response to the GUI. Distinguish an in-progress draft from the last validated context. Commit state and advance the processed-event cursor only after a complete, valid response. Preserve unprocessed events on errors; never silently lose earlier decisions when shortening context.

Bound queues and context size. Retain a session event journal before SQLite exists; use chunked processing when a meeting exceeds the model's context budget. AI overload may pause analysis with a clear status, but must not stop or block ASR.

Do not invoke the LLM for every token or partial ASR result.

Use finalized events only.

Where possible, retain source event IDs so context items can be traced back to the transcript.

Example:

```json
{
  "decisions": [
    {
      "text": "Перенести релиз на следующую неделю",
      "sourceIds": ["utt_00482"]
    }
  ]
}
```

---

# LLM grounding rule

The LLM must never silently override factual pipeline outputs.

For example:

Bad:

```text
audio layer -> Unknown-2
LLM decides -> "probably Максим"
```

Good:

```text
audio layer -> Unknown-2
LLM sees -> Unknown-2
```

Speaker identity can only be corrected by:

```text
speaker matching logic
or
explicit user correction
```

The same principle applies to transcript text.

---

# SwiftUI graphical interface

The final product MUST include a native macOS SwiftUI interface.

Do not build the final product as a web application unless explicitly requested.

The SwiftUI layer must consume state produced by MeetingAssistantCore.

Do not place audio capture, model inference, persistence, or Ollama networking directly in SwiftUI views.

Use observable view models or application state adapters.

---

# Main GUI layout

The primary meeting screen should conceptually contain:

```text
┌─────────────────────────────────────────────────────────────┐
│ MeetingAssistant                     ● 00:43:12    [Stop]  │
├─────────────────────────────┬───────────────────────────────┤
│ LIVE TRANSCRIPT             │ CONTEXT                       │
│                             │                               │
│ Алексей  12:31              │ Current topic                 │
│ Релиз нужно перенести...    │ Перенос релиза                │
│                             │                               │
│ YOU  12:31                  │ Decisions                     │
│ На какую дату?              │ • перенос на след. неделю     │
│                             │                               │
│ Unknown-3  12:32            │ Action items                  │
│ Я уточню у заказчика.       │ • уточнить дату               │
│ [Assign speaker ▼]          │                               │
│                             │ Open questions                │
│                             │ • точная дата релиза          │
├─────────────────────────────┴───────────────────────────────┤
│ Mic ●  BlackHole ●  Whisper ●  Diarization ●  Ollama ●    │
└─────────────────────────────────────────────────────────────┘
```

This is conceptual, not a strict pixel-perfect requirement.

---

# GUI screens

The application roadmap should include at minimum the following screens or panels.

## 1. Start / Home

Purpose:

- system readiness;
- start a meeting;
- select basic sources;
- surface missing dependencies.

Example:

```text
Microphone      MacBook Pro Microphone       ✓
Remote audio    BlackHole 2ch                 ✓
WhisperKit      Ready                         ✓
Diarization     Ready                         ✓
Ollama          qwen3.x                       ✓

[ Start Meeting ]
```

---

## 2. Live Meeting

Main operational screen.

Must show:

- meeting timer;
- Start / Stop / Pause controls;
- live transcript;
- current speaker;
- partial/finalized visual distinction if useful;
- contextual briefing;
- system status;
- speaker correction actions.

---

## 3. Audio Settings

Must allow:

- selecting local microphone;
- selecting BlackHole / remote source;
- seeing live input levels;
- detecting missing BlackHole;
- refreshing the device list.

Show clear level indicators:

```text
YOU       ███████░░░
REMOTE    █████░░░░░
```

Do not expose raw AudioDeviceID values as the primary user interface.

---

## 4. Speaker Profiles

Must allow:

- viewing known speakers;
- creating a speaker profile;
- renaming a profile;
- deleting a profile;
- enrolling new voice samples;
- reviewing profile sample count;
- manually assigning Unknown speakers during or after a meeting.

Potential layout:

```text
Алексей
Samples: 5
Last confirmed: today

Лариса
Samples: 4
Last confirmed: 3 days ago

[ Add speaker ]
```

---

## 5. AI / Ollama Settings

Must show:

```text
Ollama status
server URL
selected model
connection status
context update interval
editable system prompt
```

Automatically retrieve the model list from the configured server and allow selection. Persist settings; provide connection/model refresh and resetting the system prompt. Show model unloading status after a meeting.

Do not require Ollama for transcription.

---

## 6. Meeting History

Later phase.

Show saved meetings:

```text
12 Sep 2026 14:00
Release planning

11 Sep 2026 10:30
UX agency review
```

Opening a meeting should display:

- transcript;
- summary;
- decisions;
- action items;
- participants;
- contextual timeline.

---

# Meeting controls

The final GUI must include:

```text
Start
Pause
Resume
Stop
```

Pause means:

- stop storing/transcribing new meeting audio;
- retain current session state;
- continue when resumed.

Do not use Pause merely as a UI state while still recording audio.

---

# Start Meeting behavior

When the user clicks Start Meeting:

1. Verify microphone is available.
2. Verify REMOTE source is available.
3. Verify WhisperKit model is ready.
4. Start the meeting monotonic clock.
5. Start both capture pipelines.
6. Start live transcription.
7. If diarization is enabled, start it for REMOTE.
8. If AI is enabled and Ollama is available, start context updates using the meeting's settings snapshot.
9. Transition UI to Live Meeting.

Do not silently start with a missing critical audio source.

---

# Stop Meeting behavior

When the user clicks Stop Meeting:

1. stop audio capture;
2. flush pending finalized ASR;
3. finalize diarization when that later feature is enabled;
4. retain the remaining events in the session journal (persist them once storage exists);
5. stop scheduling live context updates and include all remaining events in final analysis;
6. when AI is enabled, generate a meeting protocol that accounts for earlier events and the final ASR tail;
7. receive the complete protocol, display it, and enable copying in the app;
8. request unloading of the meeting's model through the same Ollama server API, then verify the result;
9. close the session cleanly and keep the available transcript/protocol visible.

Protocol delivery means display inside the app with copying, as clarified by the user; no external messaging is part of this milestone. Unload after full delivery, without waiting for a copy-button click.

Use the API to release the selected model; let Ollama close its runner. Do not terminate the `ollama-server` service or run remote process-killing commands. A shared server may have other requests using that model, so handle delayed or unconfirmed unloading explicitly. Do not let cleanup from an old meeting unload a newer meeting's model.

After cancellation or AI errors, attempt bounded cleanup as well. A failed unload must not remove the generated protocol. Finalization, cancellation, window closing, and retries must have bounded waits and clear status.

---

# Application status model

The GUI should expose component state.

Example:

```swift
enum ComponentStatus {
    case unavailable
    case loading
    case ready
    case degraded
    case failed(String)
}
```

Conceptually track:

```text
microphone
remoteAudio
whisper
diarization
speakerProfiles
ollama
storage
```

This lets the GUI show:

```text
Whisper      ● Ready
BlackHole    ● Ready
Ollama       ○ Offline
```

without embedding system logic inside the view.

---

# Error UX

Do not show only raw Swift errors to the user.

Translate common failures into understandable messages.

Example:

Bad:

```text
kAudioHardwareBadDeviceError -2000
```

Good:

```text
BlackHole 2ch is no longer available.

Check Audio MIDI Setup or reconnect the audio device.
```

Detailed technical information may be available under:

```text
Show details
```

for debugging.

---

# Privacy UI

Audio capture and transcription remain local. AI may run on the user-configured Ollama server, including another machine.

The UI should make this visible.

Example:

```text
Audio processing: This Mac
AI processing: Selected Ollama server
Cloud transcription: Off
```

Do not add telemetry, cloud logging, remote analytics, or remote speech APIs unless explicitly requested.

---

# Application lifecycle

The application should behave like a native macOS application.

Later GUI milestones may add:

```text
menu bar status
dock app
notifications
restore previous window state
```

Do not implement these before the primary meeting workflow is stable.

---

# Proposed project structure

Prefer a modular structure similar to:

```text
MeetingAssistant/
├── Package.swift
├── AGENTS.md
├── README.md
│
├── Sources/
│   ├── MeetingAssistantCore/
│   │   ├── Audio/
│   │   │   ├── AudioDeviceManager.swift
│   │   │   ├── AudioCapture.swift
│   │   │   └── AudioSource.swift
│   │   │
│   │   ├── Transcription/
│   │   │   ├── WhisperTranscriber.swift
│   │   │   └── TranscriptEvent.swift
│   │   │
│   │   ├── Speakers/
│   │   │   ├── SpeakerDiarizer.swift
│   │   │   ├── VoiceProfile.swift
│   │   │   └── SpeakerMatcher.swift
│   │   │
│   │   ├── Meeting/
│   │   │   ├── MeetingSession.swift
│   │   │   └── MeetingState.swift
│   │   │
│   │   ├── Context/
│   │   │   ├── OllamaClient.swift
│   │   │   └── ContextEngine.swift
│   │   │
│   │   └── Storage/
│   │       └── MeetingStore.swift
│   │
│   ├── MeetingAssistantCLI/
│   │   └── main.swift
│   │
│   └── MeetingAssistantApp/
│       ├── MeetingAssistantApp.swift
│       ├── Views/
│       ├── ViewModels/
│       └── Settings/
```

Exact structure may evolve.

Do not create empty abstractions merely to match this tree.

---

# Implementation roadmap

Work incrementally.

## Phase 1 — Audio device discovery

Implement enumeration of macOS audio devices.

Acceptance criteria:

```text
swift run
```

shows BlackHole and microphone and resolves their IDs.

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

Optionally calculate RMS / peak levels.

Acceptance criteria:

- speaking into the microphone changes YOU level;
- playing system audio changes REMOTE level;
- both run simultaneously;
- no obvious buffer failures.

---

## Phase 3 — Single-stream live WhisperKit

Connect REMOTE / BlackHole to WhisperKit.

Acceptance criteria:

- live Russian transcription;
- continuous speech works for several minutes;
- finalized segments are stable;
- no excessive duplication.

---

## Phase 4 — Dual live WhisperKit

Connect both sources.

Acceptance criteria:

```text
REMOTE -> WhisperKit
YOU    -> WhisperKit
```

run simultaneously.

Terminal output is timestamped and chronological.

---

## Phase 5 — ASR stability

Run:

```text
30–60 minute test
```

Check:

- memory does not continuously grow;
- no steadily increasing latency;
- no repeated finalized segments;
- no blocked capture callbacks;
- streams remain sufficiently synchronized.

---

## Phase 6 — Core/UI separation

Before adding the full GUI:

- move reusable business logic into `MeetingAssistantCore`;
- keep CLI as a thin adapter;
- expose observable application/session state;
- make sure core components do not import SwiftUI.

Acceptance criteria:

- the same MeetingSession can be started from CLI or another frontend;
- audio/transcription functionality works without UI code.

---

## Phase 7 — Basic SwiftUI shell

Create native macOS SwiftUI application.

Implement:

```text
Home
Audio Settings
Live Meeting
```

At this stage, reuse existing core functionality.

Do not duplicate transcription logic inside SwiftUI.

Acceptance criteria:

- app launches natively;
- audio devices are shown;
- Start Meeting works;
- Stop Meeting works;
- live transcript appears in GUI;
- YOU and REMOTE are visually distinguishable.

---

## Phase 8 — Ollama context, final protocol, and model lifecycle

This is the next milestone after the accepted basic GUI. Detailed plan: [OLLAMA_PLAN.md](OLLAMA_PLAN.md).

Implement incrementally within this milestone:

1. Configurable server URL, automatic model discovery/selection, connection status, and editable persisted system prompt.
2. Stable event IDs and an in-memory event journal; context that retains earlier facts, decisions, questions, and actions.
3. Bounded sequential context requests and streaming updates displayed beside the transcript.
4. A final protocol after Stop that includes all finalized events, displayed in the app with copying.
5. Model unloading through the API after delivery, verification, and cleanup on errors/cancellation.
6. Live validation of dual-ASR plus AI, early-context retention, final ASR draining, restart, and unloading.

Acceptance criteria:

- user can configure their Ollama server and choose a model obtained from it;
- the chosen system prompt is used for live context and the final protocol;
- early events remain represented across updates, and the GUI displays generation progress;
- final protocol includes early decisions and the last confirmed utterance;
- after delivery, the used model is unloaded on the test server and its service remains available;
- failure or slowness of AI never interrupts audio capture or transcription.

Diarization and SQLite are not prerequisites. At this phase speakers remain YOU/REMOTE, and the result is held in the session until a new meeting or app closure. Copying does not clear the result.

---

## Phase 9 — FluidAudio diarization

Add diarization ONLY to REMOTE.

Acceptance criteria:

```text
REMOTE -> speaker_1
REMOTE -> speaker_2
...
```

with usable timestamps.

Expose diarization state in GUI.

---

## Phase 10 — Voice profiles and identification

Implement:

```text
speaker embeddings
voice profiles
speaker matching
confidence policy
unknown speakers
manual corrections
```

Acceptance criteria:

- known speakers can be enrolled;
- known voices can be matched;
- uncertain voices remain uncertain;
- unknown speakers are not falsely forced to known names;
- user can manually assign speakers in GUI.

---

## Phase 11 — Persistent meeting storage and history

Add SQLite or equivalent local persistence.

Persist:

```text
meetings
transcript events
speakers
voice profiles
context snapshots
final protocols
```

Reuse stable event IDs introduced in Phase 8. GUI should support meeting history, including saved transcripts and AI results.

---

## Phase 12 — Full saved meeting result

Extend the protocol already implemented in Phase 8 with persisted history and identified participants. After Stop and when reopening a meeting:

generate/display:

```text
full transcript
summary
decisions
action items
open questions
participants
timeline
```

Support export later.

---

## Phase 13 — GUI refinement

Improve:

```text
speaker management
meeting history
settings
error states
loading states
audio meters
confidence display
pause/resume
model management
keyboard shortcuts
```

Only after the core workflow is stable.

---

# Explicitly out of scope for the CURRENT milestone

Do NOT yet implement:

```text
FluidAudio
speaker diarization
speaker embeddings
speaker identification
voice profiles
SQLite
RAG
full SwiftUI UI
menu bar integration
cloud speech services
```

These are not part of the next Ollama milestone. A user-configured Ollama server and native AI settings/live context/protocol UI are explicitly in scope. Do not implement the entire roadmap at once.

---

# Development rules

After meaningful changes:

```bash
swift build
```

Fix compiler warnings when practical.

Before considering a phase complete:

```bash
swift run
```

or launch the SwiftUI target for GUI phases.

Perform the relevant real audio test.

Do not make large unrelated refactors while fixing a focused issue.

If a decision depends on uncertain macOS, WhisperKit, FluidAudio, or Ollama behavior, inspect the real API/source instead of guessing.

---

# README

Keep `README.md` updated with:

1. prerequisites;
2. BlackHole setup;
3. Multi-Output Device setup;
4. build instructions;
5. run instructions;
6. expected devices;
7. current supported features;
8. troubleshooting.

Once the GUI exists, README should describe the normal user workflow instead of assuming CLI usage.

---

# Definition of Done — completed audio/ASR milestone

Preserve the completed audio/ASR baseline criteria:

```text
✓ BlackHole discovered programmatically
✓ MacBook microphone discovered programmatically
✓ both devices opened simultaneously
✓ both streams remain separate
✓ both streams captured continuously
✓ WhisperKit transcribes REMOTE live
✓ WhisperKit transcribes YOU live
✓ YOU events tagged YOU
✓ REMOTE events tagged REMOTE
✓ finalized segments are not duplicated
✓ events contain timestamps
✓ events merge chronologically
✓ application does not change global macOS input device
✓ several-minute test works without growing delay
```

Do not proceed to diarization until this is stable.

---

# Definition of Done — next Ollama milestone

```text
✓ configurable Ollama server URL
✓ automatic model listing and explicit selection
✓ editable saved system prompt
✓ finalized YOU/REMOTE events feed bounded AI processing
✓ streamed context retains earlier events and source links
✓ ASR remains usable when Ollama is unavailable
✓ Stop includes the final ASR tail in the protocol
✓ complete protocol is displayed and can be copied
✓ selected model is unloaded via API after delivery and verified
✓ cancellation/error cleanup does not stop the server service
✓ delayed cleanup cannot unload a newer session's model
```

These are acceptance criteria, not a claim that Phase 8 is already implemented.

---

# Definition of Done — final product

The product is considered functionally complete when:

```text
✓ native SwiftUI macOS application exists
✓ user can select microphone and remote audio source
✓ user can Start / Pause / Resume / Stop a meeting
✓ YOU and REMOTE are captured independently
✓ WhisperKit transcribes both live
✓ REMOTE is diarized
✓ known voices can be identified
✓ uncertain/unknown voices are handled safely
✓ speaker identity can be corrected in GUI
✓ transcript is persisted locally
✓ Ollama can generate live context
✓ Ollama server/model/system prompt can be configured
✓ Ollama failure does not interrupt transcription
✓ decisions and actions link back to transcript sources
✓ meetings can be reopened from history
✓ final transcript and summary are available after Stop
✓ final protocol can be copied and its model unloaded through the API
✓ audio remains local; AI uses only the user-configured server
```

---

# Guiding principle

Build the system from the bottom up:

```text
audio correctness
    ↓
stable capture
    ↓
stable transcription
    ↓
Core/UI separation
    ↓
basic GUI
    ↓
Ollama context / protocol / model unloading
    ↓
speaker diarization
    ↓
speaker identification
    ↓
persistent transcript
and AI results
    ↓
full GUI workflow
```

Never hide instability in a lower layer with logic in a higher layer.

The final product should feel simple even though the internal pipeline is complex.
