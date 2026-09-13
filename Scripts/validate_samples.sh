#!/bin/zsh
set -eu
cd -- "${0:A:h:h}"
# Run `zsh Scripts/test.sh` once before this script to build the test executable.
# Each invocation processes one 45-second local excerpt; watchdog is 60 s total.
sample_name="${1:-Simple}"
sample_offset="${2:-0}"
diarizer_name="${3:-sortformer-v2.1}"
[[ "$sample_name" == Simple || "$sample_name" == Hard ]] || { print -u2 'Sample must be Simple or Hard'; exit 2; }
[[ "$sample_offset" == <-> ]] || { print -u2 'Offset must be nonnegative integer seconds'; exit 2; }
mkdir -p .build/validation/samples
export MEETING_TEST_SAMPLE="${sample_name:l}-${sample_offset}"
export MEETING_TEST_DIARIZER="$diarizer_name"
export MEETING_SAMPLE_TEST_FILTER="${4:-shortMeetingSampleDiarization}"
ffmpeg -hide_banner -loglevel error -y -ss "$sample_offset" -i ".samples/$sample_name.mp4" -t 45 -vn -ac 1 -ar 16000 -c:a pcm_f32le ".build/validation/samples/$MEETING_TEST_SAMPLE.wav"
python3 - <<'PY'
import os, signal, subprocess, sys
process = subprocess.Popen(['zsh', 'Scripts/test.sh', '--skip-build', '--filter', os.environ['MEETING_SAMPLE_TEST_FILTER']], start_new_session=True)
try:
    sys.exit(process.wait(timeout=60))
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
    sys.exit('Sample validation exceeded the one-minute budget')
PY
