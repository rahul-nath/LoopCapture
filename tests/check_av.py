"""Verify a real capture made while system audio is playing.

Uses already-installed ffprobe/ffmpeg for verification only, never by the app.
"""

import array
import json
from pathlib import Path
import subprocess
import sys


def check(movie: Path) -> None:
    result = subprocess.run(
        ["ffprobe", "-v", "error", "-show_streams", "-of", "json", str(movie)],
        check=True, capture_output=True, text=True,
    )
    streams = json.loads(result.stdout)["streams"]
    video = [s for s in streams if s["codec_type"] == "video"]
    audio = [s for s in streams if s["codec_type"] == "audio"]
    if len(video) != 1 or len(audio) != 1:
        raise ValueError(f"Expected one video and one audio track; got {len(video)} video, {len(audio)} audio")
    starts = [float(s["start_time"]) for s in (video[0], audio[0])]
    durations = [float(s["duration"]) for s in (video[0], audio[0])]
    if min(durations) <= 0:
        raise ValueError("Empty media track")
    ends = [start + duration for start, duration in zip(starts, durations)]
    # AAC priming and final video-frame duration need a small tolerance.
    if abs(starts[0] - starts[1]) > 0.25 or abs(ends[0] - ends[1]) > 0.5:
        raise ValueError(f"Audio/video timelines differ: starts={starts}, ends={ends}")
    result = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(movie), "-map", "0:a:0",
         "-t", "30", "-ac", "1", "-ar", "8000", "-f", "f32le", "pipe:1"],
        check=True, capture_output=True,
    )
    samples = array.array("f", result.stdout)
    if sys.byteorder != "little":
        samples.byteswap()
    rms = (sum(x * x for x in samples) / len(samples)) ** 0.5 if samples else 0
    if rms < 0.0001:
        raise ValueError("Audio is silent; repeat while audible system audio plays in the first 30 seconds")
    print(f"PASS: {video[0]['codec_name']} + {audio[0]['codec_name']} in one MP4; "
          f"start difference={abs(starts[0]-starts[1]):.3f}s, "
          f"end difference={abs(ends[0]-ends[1]):.3f}s, audio RMS={rms:.5f}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: check_av.py /path/to/recording.mp4")
    check(Path(sys.argv[1]))
