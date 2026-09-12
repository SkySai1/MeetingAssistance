#!/usr/bin/env python3
"""Exercise real CoreAudio devices with local macOS TTS; keep all evidence locally."""
import argparse
import json
import os
from pathlib import Path
import re
import selectors
import signal
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--duration", type=int, default=180)
    parser.add_argument("--mode", choices=["remote", "dual"], default="remote")
    parser.add_argument("--microphone-playback-device", help="Optional physical output for an acoustic microphone test")
    parser.add_argument("--output", default=".build/validation/latest")
    parser.add_argument("--debug-audio", action="store_true")
    parser.add_argument("--ollama-model", help="Enable real AI validation with this model")
    parser.add_argument("--ollama-server", default="http://127.0.0.1:11434")
    args = parser.parse_args()
    if args.duration <= 0:
        parser.error("duration must be positive")
    root = Path(__file__).resolve().parent.parent
    os.chdir(root)
    destination = Path(args.output)
    destination.mkdir(parents=True, exist_ok=True)
    # Use the already-built binary so a long live check does not hold SwiftPM's
    # build lock while independent unit tests or GUI packaging are running.
    command = [str(root / ".build/release/MeetingAssistant"), "--duration", str(args.duration), "--json"]
    if args.mode == "remote":
        command.append("--remote-only")
    if args.debug_audio:
        command += ["--debug-audio-dir", str(destination / "audio")]
    if args.ollama_model:
        command += ["--ollama-model", args.ollama_model, "--ollama-server", args.ollama_server,
                    "--ai-output", str(destination / "ai-state.json")]
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    selector = selectors.DefaultSelector()
    for stream, kind in [(process.stdout, "events"), (process.stderr, "diagnostics")]:
        os.set_blocking(stream.fileno(), False)
        selector.register(stream, selectors.EVENT_READ, kind)
    buffers = {"events": b"", "diagnostics": b""}
    events, diagnostics, errors = [], [], []
    delivery_lags = []
    playback = {"remote": None, "you": None}
    next_you = float("inf")
    speech_cycle_ends = []
    began, capture_began, last_report = time.monotonic(), None, time.monotonic()
    files = {"events": (destination / "transcript.jsonl").open("wb"), "diagnostics": (destination / "diagnostics.log").open("wb")}
    try:
        while selector.get_map():
            now = time.monotonic()
            if now - began > args.duration + 300:
                errors.append("Test exceeded capture duration plus 300 seconds for model loading/draining")
                process.send_signal(signal.SIGINT)
                break
            for key, _ in selector.select(timeout=0.2):
                block = os.read(key.fileobj.fileno(), 65536)
                kind = key.data
                if not block:
                    selector.unregister(key.fileobj)
                    continue
                files[kind].write(block)
                files[kind].flush()
                buffers[kind] += block
                while b"\n" in buffers[kind]:
                    line, buffers[kind] = buffers[kind].split(b"\n", 1)
                    text = line.decode("utf-8", errors="replace")
                    if kind == "events":
                        try:
                            event = json.loads(text)
                            events.append(event)
                            if capture_began is not None:
                                delivery_lags.append(max(0, time.monotonic() - capture_began - event["endTime"]))
                            print(f"[{event['startTime']:8.3f}] {event['source']}: {event['text']}", flush=True)
                        except (ValueError, KeyError) as error:
                            errors.append(f"Invalid finalized event: {error}")
                    else:
                        diagnostics.append(text)
                        if "Transcription started." in text:
                            capture_began = time.monotonic()
                            next_you = capture_began + 5
                            print("Real audio capture ready; starting local test speech.", flush=True)
                        if text.startswith("ERROR:") or "WARNING:" in text:
                            print(text, flush=True)
            active = capture_began is not None and time.monotonic() - capture_began < args.duration - 3
            if active:
                remote = playback["remote"]
                if remote is None or remote.poll() is not None:
                    if remote is not None and remote.returncode != 0:
                        errors.append(f"Remote playback failed: {remote.returncode}")
                        process.send_signal(signal.SIGINT)
                        break
                    if remote is not None:
                        speech_cycle_ends.append(time.monotonic() - capture_began)
                    playback["remote"] = subprocess.Popen(["say", "--audio-device=BlackHole 2ch", "-v", "Milena", "-r", "190", "-f", "Scripts/fixtures/remote-ru.txt"])
                you = playback["you"]
                if args.mode == "dual" and args.microphone_playback_device and time.monotonic() >= next_you and (you is None or you.poll() is not None):
                    if you is not None and you.returncode != 0:
                        errors.append(f"Microphone test playback failed: {you.returncode}")
                        process.send_signal(signal.SIGINT)
                        break
                    playback["you"] = subprocess.Popen(["say", f"--audio-device={args.microphone_playback_device}", "-v", "Milena", "-r", "165",
                        "Проверка локального микрофона. Я подготовлю документ к четвергу. Уточните, пожалуйста, время следующей встречи."])
                    next_you = time.monotonic() + 35
            else:
                for player in playback.values():
                    if player is not None and player.poll() is None:
                        player.terminate()
            if now - last_report > 30:
                level = next((line for line in reversed(diagnostics) if "RSS" in line), "Model loading...")
                print(f"Progress: {len(events)} events | {level}", flush=True)
                last_report = now
        # An aborted playback test still drains the child's pipes, otherwise its
        # final ASR/AI output could fill a pipe and block orderly shutdown.
        process.communicate(timeout=240)
    finally:
        for player in playback.values():
            if player is not None and player.poll() is None:
                player.terminate()
                player.wait(timeout=10)
        if process.poll() is None:
            process.send_signal(signal.SIGINT)
            try:
                process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        for file in files.values():
            file.close()
        selector.close()
    if process.returncode != 0:
        errors.append(f"CLI exited with {process.returncode}")
    times = [event["startTime"] for event in events]
    if times != sorted(times):
        errors.append("Finalized events were not chronological")
    identities = [(e["source"], e["startTime"], e["endTime"], e["text"]) for e in events]
    if len(set(identities)) != len(identities):
        errors.append("Repeated finalized event")
    counts = {source: sum(e["source"] == source for e in events) for source in ["YOU", "REMOTE"]}
    if counts["REMOTE"] == 0 or (args.mode == "dual" and counts["YOU"] == 0):
        errors.append("One of the required sources produced no transcript events")
    if any(line.startswith("ERROR:") or "WARNING:" in line for line in diagnostics):
        errors.append("Diagnostics contain an error or warning")
    cycle_scores = []
    if speech_cycle_ends:
        def words(text):
            return re.findall(r"[a-zа-я0-9]+", text.lower().replace("ё", "е"))
        expected = words((root / "Scripts/fixtures/remote-ru.txt").read_text())
        # Ordered word recall tolerates punctuation/spelling differences but catches
        # entire missing windows that event-count and timing checks would overlook.
        cycle_start = 0
        for cycle_end in speech_cycle_ends:
            actual = words(" ".join(e["text"] for e in events if e["source"] == "REMOTE" and cycle_start <= e["startTime"] < cycle_end))
            row = [0] * (len(actual) + 1)
            for expected_word in expected:
                next_row = [0]
                for index, actual_word in enumerate(actual):
                    next_row.append(row[index] + 1 if expected_word == actual_word else max(row[index + 1], next_row[-1]))
                row = next_row
            coverage = round(row[-1] / max(1, len(expected)), 4)
            precision = round(row[-1] / max(1, len(actual)), 4)
            cycle_scores.append({"start": round(cycle_start, 3), "end": round(cycle_end, 3), "recall": coverage, "precision": precision})
            if coverage < 0.90 or precision < 0.90:
                errors.append(f"Speech cycle {len(cycle_scores)} has low ordered word scores: recall={coverage:.1%}, precision={precision:.1%}")
            cycle_start = cycle_end
    rss = [float(m.group(1)) for line in diagnostics if (m := re.search(r"RSS ([\d.]+) MB", line))]
    lag = [float(m.group(1)) for line in diagnostics if (m := re.search(r"\| lag ([\d.]+)s", line))]
    captures = {m.group(1): float(m.group(2)) for line in diagnostics
                if (m := re.search(r"(YOU|REMOTE) capture stopped: ([\d.]+)s", line))}
    for source in (["REMOTE"] if args.mode == "remote" else ["YOU", "REMOTE"]):
        if captures.get(source, 0) < args.duration - 0.25:
            errors.append(f"{source} did not capture the requested duration")
    callback_lags = [float(m.group(1)) for line in diagnostics
                     if (m := re.search(r"maximum callback-consumer lag ([\d.]+)s", line))]
    queue = [float(m.group(1)) for line in diagnostics if (m := re.search(r"ASR queue ([\d.]+)s", line))]
    def percentile(values, fraction):
        return round(sorted(values)[int((len(values) - 1) * fraction)], 3) if values else None
    report = {"mode": args.mode, "requested_capture_seconds": args.duration, "event_counts": counts,
        "actual_capture_seconds": captures,
        "chronological": times == sorted(times), "exact_duplicate_events": len(identities) - len(set(identities)),
        "rss_mb": {"first": rss[0] if rss else None, "last": rss[-1] if rss else None, "max": max(rss, default=None)},
        "completion_lag_seconds": {"first": lag[0] if lag else None, "last": lag[-1] if lag else None, "max": max(lag, default=None)},
        "delivery_lag_seconds": {"p50": percentile(delivery_lags, 0.50), "p95": percentile(delivery_lags, 0.95), "max": max(delivery_lags, default=None)},
        "max_callback_consumer_lag_seconds": max(callback_lags, default=None),
        "max_sampled_asr_backlog_seconds": max(queue, default=None),
        "first_cycle_ordered_word_recall": cycle_scores[0]["recall"] if cycle_scores else None,
        "first_cycle_ordered_word_precision": cycle_scores[0]["precision"] if cycle_scores else None,
        "full_speech_cycles": cycle_scores,
        "acoustic_microphone_playback": args.microphone_playback_device, "errors": errors}
    if args.ollama_model:
        try:
            ai = json.loads((destination / "ai-state.json").read_text())
            report["ai"] = {key: ai.get(key) for key in ["phase", "processedEvents", "totalEvents", "updates", "protocolComplete", "releaseStatus", "error"]}
            if not ai["protocolComplete"] or ai["processedEvents"] != len(events) or ai["releaseStatus"] != "unloaded":
                errors.append("AI did not process all events, deliver a full protocol, and confirm model unloading")
            (destination / "protocol.md").write_text(ai["protocolText"] + "\n")
        except (OSError, ValueError, KeyError) as error:
            errors.append(f"AI validation output unavailable: {error}")
    (destination / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False, indent=2), flush=True)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
