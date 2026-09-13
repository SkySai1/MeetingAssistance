# MeetingAssistant — карта продукта по файлам

## 1. Карта продукта верхнего уровня

```text
ПОЛЬЗОВАТЕЛЬ
   │
   ▼
┌───────────────────────────────┐
│        SwiftUI GUI            │
│ MeetingAssistantApp           │
└───────────────┬───────────────┘
                │
                ▼
┌───────────────────────────────┐
│      MeetingViewModel         │
│ состояние + управление UI     │
└───────────────┬───────────────┘
                │
                ▼
┌───────────────────────────────┐
│       MeetingSession          │
│ оркестратор одной встречи     │
└───────┬──────────┬────────────┘
        │          │
        ▼          ▼
   AUDIO/ASR      AI
        │          │
        ▼          ▼
 AudioCapture   ContextEngine
        │          │
 AudioResampler   OllamaClient
        │          │
 SpeechChunker    ContextMemory
        │          │
 Whisper          ▼
        │     справка/протокол
        ▼
 TranscriptEvent
        │
        ▼
 TranscriptTimeline
```

Главный архитектурный принцип проекта: **GUI и CLI не реализуют распознавание сами — оба используют общее `MeetingAssistantCore`**. 

---

# 2. Корень проекта — управление продуктом и сборкой

### `.gitignore`

**Роль:** правила того, что не должно попадать в Git.

Сюда относятся временные файлы SwiftPM, результаты сборки, локальные validation-артефакты и прочий машинный мусор.

**На карте продукта:** инфраструктура разработки.

---

### `.vscode/launch.json`

**Роль:** сценарии запуска проекта из VS Code.

Содержит отдельные конфигурации:

- CLI Debug;
- CLI Release;
- GUI Debug;
- GUI Release.

То есть позволяет разработчику запускать оба продукта непосредственно из IDE. 

**На карте:** Developer Experience.

---

### `AGENTS.md`

**Роль:** главный архитектурно-продуктовый контракт для AI-агента/автономной разработки.

Описывает:

- конечную цель MeetingAssistant;
- архитектурные ограничения;
- этапы разработки;
- порядок внедрения функций;
- то, что должно оставаться локальным;
- требования к транскрипции;
- будущую диаризацию и voice profiles;
- роль Ollama.

Фактически это **ТЗ + архитектурные правила + roadmap для агента разработки**. 

**На карте:** Product Vision / Architecture Governance.

---

### `README.md`

**Роль:** пользовательская и эксплуатационная документация текущего продукта.

Описывает:

- что умеет приложение;
- как запустить встречу;
- настройку BlackHole;
- модели Whisper;
- Ollama;
- сборку;
- CLI;
- проверки;
- ограничения.

Это документ про **«как использовать то, что уже существует»**. 

**На карте:** User Documentation.

---

### `PRODUCT_STATUS.md`

**Роль:** снимок текущего состояния продукта.

Содержит:

- уже реализованные функции;
- ограничения;
- подтверждённые проверки;
- текущий milestone;
- дальнейшие этапы.

В отличие от `AGENTS.md`, отвечает прежде всего на вопрос:

> Что MeetingAssistant умеет сейчас и чего ещё не умеет?



**На карте:** Product Status / Backlog.

---

### `OLLAMA_PLAN.md`

**Роль:** детальная спецификация AI-функционала.

Описывает:

- подключение Ollama;
- выбор модели;
- streaming;
- обновляемую контекстную справку;
- память ранних событий;
- решения/поручения/вопросы;
- итоговый протокол;
- выгрузку модели;
- критерии корректности.

Это фактически отдельный **design document подсистемы AI**. 

**На карте:** AI Feature Specification.

---

### `VALIDATION.md`

**Роль:** журнал доказательств того, что продукт действительно работает.

Фиксирует:

- результаты сборок;
- unit-тесты;
- live ASR;
- dual-stream проверки;
- latency;
- RSS;
- recall/precision;
- 30-минутные stability tests;
- GUI validation.

То есть это не план, а **evidence / acceptance report**. 

**На карте:** Quality / Acceptance Evidence.

---

### `LICENSE`

**Роль:** юридические условия распространения исходного кода.

Проект использует **Apache License 2.0**. 

**На карте:** Legal.

---

# 3. Swift Package и зависимости

### `Package.swift`

**Роль:** главный manifest сборки.

Определяет три продукта:

```text
MeetingAssistantCore
MeetingAssistant
MeetingAssistantApp
```

И зависимость:

```text
argmax-oss-swift / WhisperKit
```

Также именно здесь проводится архитектурная граница:

```text
Audio
Meeting
Transcription
Context
        ↓
MeetingAssistantCore

CLI.swift
MeetingAssistant.swift
        ↓
MeetingAssistant

MeetingAssistantApp/*
        ↓
MeetingAssistantApp
```



**На карте:** Build Architecture.

---

### `Package.resolved`

**Роль:** lock-файл SwiftPM.

Фиксирует конкретные версии/commit SHA внешних зависимостей.

Нужен для воспроизводимой сборки.

**На карте:** Dependency Management.

---

# 4. macOS application bundle

### `Resources/Info.plist`

**Роль:** метаданные настоящего `.app`.

Определяет:

- executable;
- bundle identifier;
- название приложения;
- версию `0.3.0`;
- минимальную macOS 15;
- описание запроса разрешения на микрофон.



**На карте:** macOS Packaging / Permissions.

---

# 5. AUDIO — получение звука

## `Sources/MeetingAssistant/Audio/AudioSource.swift`

**Роль:** определяет логические источники речи.

```text
YOU    = пользователь
REMOTE = собеседники
```

Это фундаментальная доменная модель проекта. 

**Вход:** нет.  
**Выход:** тип `AudioSource`.

---

## `AudioDeviceManager.swift`

**Роль:** обнаружение и выбор физических/виртуальных CoreAudio-устройств.

Умеет:

- получать список устройств;
- читать input channels;
- читать sample rate;
- узнавать системные default devices;
- искать MacBook microphone;
- искать `BlackHole 2ch`;
- выдавать понятные ошибки.

Здесь же находится базовый `MeetingError`. 

**Вход:** CoreAudio.  
**Выход:** `AudioDevice`.

---

## `AudioCapture.swift`

**Роль:** realtime-захват PCM непосредственно через AUHAL/CoreAudio.

Содержит:

```text
AudioCapture
CaptureRing
CapturedAudio
```

`CaptureRing` служит промежуточным lock-free-ish буфером:

```text
CoreAudio callback
       ↓
CaptureRing
       ↓
MeetingSession
```

Файл максимально близок к железу и realtime audio. 

**Вход:** устройство CoreAudio.  
**Выход:** native PCM packets.

---

## `AudioResampler.swift`

**Роль:** подготовка звука для Whisper.

Преобразует:

```text
native sample rate
например 44.1 / 48 kHz
+
несколько каналов
        ↓
mono Float32 16 kHz
```

При этом сохраняет временную шкалу потока и контролирует clock drift. 

**Вход:** `CapturedAudio`.  
**Выход:** `[Float] @ 16 kHz`.

---

# 6. TRANSCRIPTION — распознавание речи

## `SpeechChunker.swift`

**Роль:** определение речевых фрагментов.

Это **не Whisper и не диаризация**.

Он анализирует уровень сигнала и решает:

```text
тишина
речь
пауза
длинная непрерывная речь
```

Создаёт `SpeechChunk`.

Для длинной речи использует окна с overlap. 

**Вход:** 16 kHz PCM.  
**Выход:** речевые chunks.

---

## `StreamPipeline.swift`

**Роль:** очередь между непрерывным аудиопотоком и Whisper.

Управляет:

```text
SpeechChunker
queue
inFlight chunk
backpressure
lag
```

Не позволяет незаметно выбрасывать звук: при слишком большой очереди возникает явная ошибка. 

**Вход:** PCM.  
**Выход:** chunks для ASR + подтверждённые результаты обратно в timeline.

---

## `LocalWhisperTokenizer.swift`

**Роль:** гарантированно локальная загрузка Whisper tokenizer.

Главная задача:

> если локальный tokenizer сломан или отсутствует — ошибка, а не скрытая загрузка из Hugging Face.

Также реализует корректное разбиение русских и смешанных слов. 

**На карте:** Local-only ASR safety.

---

## `InitialTimestampFilter.swift`

**Роль:** workaround/защита вокруг WhisperKit timestamps.

Ограничивает первый timestamp live-окна, чтобы Whisper не мог перескочить начало фрагмента речи. 

**На карте:** ASR correctness.

---

## `WhisperTranscriber.swift`

**Роль:** главный адаптер приложения к WhisperKit.

Отвечает за:

- поиск локальных моделей;
- проверку large-v3;
- загрузку WhisperKit;
- tokenizer;
- параметры русского распознавания;
- timestamps;
- no-speech filtering;
- преобразование результата Whisper в собственную модель приложения.



**Вход:** `SpeechChunk`.  
**Выход:** `[TranscriptEvent]`.

---

## `TranscriptFinalizer.swift`

**Роль:** превращение нестабильного результата Whisper в **подтверждённый транскрипт**.

Решает одну из сложнейших проблем live-ASR:

```text
окно 1 ───────────────
            окно 2 ───────────────
            ↑ overlap
```

Он:

- сопоставляет повторяющийся контекст;
- удаляет дубль overlap;
- сохраняет новые слова;
- подтверждает только безопасную часть гипотезы.



**На карте:** ASR Finalization.

---

## `TranscriptEvent.swift`

**Роль:** доменная модель финальной реплики.

```text
id
source
startTime
endTime
text
```

В этом же файле находится `TranscriptTimeline`, который объединяет YOU и REMOTE в один хронологический поток и ждёт более медленный источник, когда необходимо сохранить порядок. 

**На карте:** Canonical Transcript.

---

# 7. MEETING — жизненный цикл встречи

## `MeetingClock.swift`

**Роль:** единые монотонные часы встречи.

Переводит macOS host time в секунды от старта MeetingSession. 

**Используется для:** timestamps, latency, elapsed time.

---

## `MeetingState.swift`

**Роль:** общие контракты ядра.

Определяет:

```text
MeetingPhase
AudioMetrics
MeetingCallbacks
MeetingConfiguration
```

То есть здесь находится API между ядром и frontend. 

**На карте:** Core Public Contract.

---

## `MeetingSession.swift`

**Роль:** главный runtime-оркестратор MeetingAssistant.

Именно здесь соединяется:

```text
Audio devices
↓
AudioCapture
↓
AudioResampler
↓
StreamPipeline
↓
WhisperTranscriber
↓
TranscriptTimeline
↓
callbacks
↓
ContextEngine
```

Также управляет:

- start;
- stop;
- загрузкой моделей;
- parallel tasks;
- drain после Stop;
- метриками;
- ошибками;
- завершением AI.



**На карте:** сердце MeetingAssistantCore.

---

# 8. AI / CONTEXT

## `AIState.swift`

**Роль:** модель данных всей AI-функции.

Содержит:

```text
AIConfiguration
AIPhase
ModelReleaseStatus
ContextKind
ContextEntry
ContextBriefing
AIState
```

Определяет четыре вида содержательных пунктов:

```text
fact
decision
question
action
```



**На карте:** AI Domain Model.

---

## `ContextMemory.swift`

**Роль:** долговременная память AI внутри одной встречи.

Содержит три важных механизма:

### `MeetingEventJournal`

Хранит подтверждённые события ASR независимо от скорости Ollama.

### `ContextMemory`

Хранит накопленные:

```text
факты
решения
вопросы
поручения
```

и не позволяет LLM просто «забыть» ранние решения.

### `OllamaModelLease`

Не позволяет старой встрече выгрузить модель, которую уже использует новая.



**На карте:** AI Memory / Integrity.

---

## `OllamaClient.swift`

**Роль:** сетевой клиент Ollama.

Реализует:

```text
GET models
POST chat
streaming NDJSON
structured output schema
unload model
/api/ps verification
timeouts
cancellation
```

Использует ephemeral `URLSession` без cookies и disk cache. 

**На карте:** AI Transport.

---

## `ContextEngine.swift`

**Роль:** главный оркестратор AI.

Параллельно транскрипции:

```text
TranscriptEvent
     ↓
MeetingEventJournal
     ↓
ContextEngine
     ↓
ContextMemory
     ↓
Ollama
     ↓
AIState
```

Отвечает за:

- пакетирование новых фраз;
- context budget;
- обновление справки;
- retry;
- backlog;
- streaming draft;
- финальный протокол;
- отмену;
- выгрузку модели.



**На карте:** AI Application Service.

---

# 9. CLI

## `CLI.swift`

**Роль:** parsing аргументов командной строки.

Поддерживает:

```text
--devices
--capture-only
--remote-only
--model-path
--tokenizer-path
--speech-threshold
--json
--debug-audio-dir
--ollama-server
--ollama-model
--ai-output
--context-interval
...
```

Также переводит CLI options в `MeetingConfiguration`. 

**На карте:** Developer / Diagnostic Frontend.

---

## `MeetingAssistant.swift`

**Роль:** entry point CLI.

```swift
@main
struct MeetingAssistant
```

Он:

- читает Options;
- находит аудиоустройства;
- проверяет permission;
- создаёт `MeetingSession`;
- подключает callbacks;
- печатает transcript;
- обрабатывает SIGINT/SIGTERM.



**На карте:** CLI Application.

---

# 10. GUI — SwiftUI frontend

## `MeetingAssistantApp.swift`

**Роль:** entry point графического приложения.

Создаёт:

```text
MeetingViewModel
MeetingRootView
Window
menus
application lifecycle
```

Также контролирует корректное завершение приложения во время активной AI-обработки. 

**На карте:** GUI Application Entry.

---

## `ViewModels/MeetingViewModel.swift`

**Роль:** главный мост:

```text
MeetingAssistantCore
        ↕
      SwiftUI
```

Хранит состояние GUI:

```text
devices
selected microphone
remote source
phase
metrics
transcript
elapsed
errors
AI state
```

Запускает и останавливает `MeetingSession`, принимает callbacks через `SessionMailbox` и публикует их SwiftUI. 

**На карте:** GUI Application State.

---

## `ViewModels/AISettingsViewModel.swift`

**Роль:** состояние AI-настроек.

Отвечает за:

- enable/disable AI;
- адрес Ollama;
- выбранную модель;
- сохранение настроек;
- загрузку списка моделей;
- connection errors.



**На карте:** AI Settings State.

---

# 11. GUI Views

## `Views/MeetingRootView.swift`

**Роль:** главный экран продукта.

Содержит четыре пользовательских режима:

```text
Подготовка
Настройки аудио
Настройки AI
Встреча
```

Показывает:

- readiness;
- выбор устройств;
- audio meters;
- Start/Stop;
- transcript;
- timer;
- diagnostics.



**На карте:** Main UX.

---

## `Views/AISettingsView.swift`

**Роль:** экран настройки AI.

Позволяет менять:

- Ollama server;
- модель;
- system prompt;
- update interval;
- context size.

Также показывает готовность AI к встрече. 

**На карте:** AI Configuration UX.

---

## `Views/AIContextView.swift`

**Роль:** рабочая AI-панель встречи.

Показывает:

```text
тема
summary
факты
решения
открытые вопросы
поручения
owner
deadline
source references
protocol
AI status
```

Пользователь может перейти от AI-факта обратно к исходной фразе транскрипта. 

**На карте:** AI Assistant UX.

---

# 12. GUI validation

## `GUIValidation.swift`

**Роль:** автоматизированный end-to-end smoke test настоящего GUI.

Через тот же `MeetingViewModel`, которым пользуются кнопки UI, проверяет:

```text
audio test
Start
Stop
double Start protection
YOU + REMOTE ASR
chronology
copy protocol
AI completion
model unload
restart
unchanged macOS audio defaults
```

Использует локальный `/usr/bin/say` для синтеза тестовой речи. 

**На карте:** GUI Acceptance Testing.

---

# 13. Скрипты

## `Scripts/build_app.sh`

**Роль:** упаковка release executable в настоящий `.app`.

```text
swift build
↓
MeetingAssistantApp binary
↓
Info.plist
↓
.app bundle
↓
ad-hoc codesign
```



---

## `Scripts/test.sh`

**Роль:** единая команда запуска automated tests.

Также обходит особенности Swift Testing при установленном только Command Line Tools. 

---

## `Scripts/validate_live.py`

**Роль:** наиболее полноценная автоматизированная live-проверка Core/CLI.

Умеет тестировать:

- реальный CoreAudio;
- REMOTE;
- dual stream;
- локальный TTS;
- chronology;
- duplicates;
- latency;
- RSS;
- ASR backlog;
- recall/precision;
- optional Ollama.

Создаёт отчёты в `.build/validation/...`. 

---

## `Scripts/fixtures/remote-ru.txt`

**Роль:** эталонный русский текст для синтезированной REMOTE-речи.

Используется `validate_live.py` для воспроизводимого ASR-теста и расчёта word recall/precision.

**На карте:** Test Fixture.

---

# 14. Tests

## `Tests/MeetingAssistantTests/MeetingAssistantTests.swift`

**Роль:** базовые unit/integration tests аудио и ASR.

Проверяет:

- выбор устройств;
- resampling;
- SpeechChunker;
- длинную речь;
- timeline;
- backpressure;
- CLI validation;
- локальность tokenizer;
- overlap finalization;
- timestamps.



---

## `MeetingSessionTests.swift`

**Роль:** lifecycle и интеграция Core ↔ GUI.

Проверяет:

- Stop до запуска;
- запрет второго `run`;
- MeetingConfiguration;
- final drain;
- оба источника;
- ошибки output sink;
- `SessionMailbox`;
- ограничение frontend queue.



---

## `OllamaTests.swift`

**Роль:** основной unit-test suite AI-подсистемы.

Проверяет:

- NDJSON;
- context memory;
- сохранение ранних решений;
- отменённые решения;
- journal limits;
- retry;
- cancellation;
- protocol delivery;
- unload;
- model lease.



---

## `OllamaHTTPTests.swift`

**Роль:** тест поведения сетевого слоя в аварийных ситуациях.

В частности:

```text
зависший HTTP stream
cancellation
hard timeout
```



---

## `OllamaLiveTests.swift`

**Роль:** opt-in интеграционный тест с **настоящим Ollama server/model**.

Не запускается в обычном test suite без специальной environment variable.

Проверяет, что AI:

- сохраняет ранние решения;
- видит последние события;
- корректно фиксирует отмену решения;
- формирует полный протокол;
- выгружает модель.



---

# 15. Итоговая карта ответственности

```text
PRODUCT / ROADMAP
├── AGENTS.md
├── PRODUCT_STATUS.md
├── OLLAMA_PLAN.md
└── VALIDATION.md

USER DOCUMENTATION
└── README.md

BUILD / DELIVERY
├── Package.swift
├── Package.resolved
├── Info.plist
└── build_app.sh

AUDIO
├── AudioSource
├── AudioDeviceManager
├── AudioCapture
└── AudioResampler

ASR
├── SpeechChunker
├── StreamPipeline
├── LocalWhisperTokenizer
├── InitialTimestampFilter
├── WhisperTranscriber
├── TranscriptFinalizer
└── TranscriptEvent / TranscriptTimeline

MEETING ORCHESTRATION
├── MeetingClock
├── MeetingState
└── MeetingSession

AI
├── AIState
├── ContextMemory
├── OllamaClient
└── ContextEngine

CLI
├── CLI.swift
└── MeetingAssistant.swift

GUI
├── MeetingAssistantApp.swift
├── MeetingViewModel
├── AISettingsViewModel
├── MeetingRootView
├── AISettingsView
└── AIContextView

QUALITY
├── GUIValidation
├── validate_live.py
├── test.sh
├── remote-ru.txt
└── Tests/*
```

# 16. Самая короткая продуктовая формула

Вся система в одном потоке:

```text
MacBook Mic ──┐
              ├─ AudioCapture
BlackHole ────┘
        ↓
AudioResampler
        ↓
SpeechChunker
        ↓
WhisperTranscriber
        ↓
TranscriptFinalizer
        ↓
TranscriptTimeline
        ↓
TranscriptEvent
        ├──────────────→ SwiftUI transcript
        │
        └→ ContextEngine
                ↓
           ContextMemory
                ↓
             Ollama
                ↓
       briefing + protocol
                ↓
              SwiftUI
```

А `MeetingSession` находится над всей этой конструкцией и управляет её жизненным циклом.