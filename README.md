# LoopCapture

Record a selected area of your Mac with system audio and save an MP4 and an animated GIF.
LoopCapture copies the GIF to your clipboard and opens a looping preview.
Choose **Copy Video** in the preview to share the MP4 with sound.
Microphone capture is disabled.

## Build and launch

Use an Apple Silicon Mac running macOS 15 or later, with Python 3 and the Apple Command Line Tools installed.
Run these commands from the project directory:

```sh
python3 build.py
open build/LoopCapture.app
```

The build signs the app locally and runs four checks covering secondary-display coordinates, saving, overwriting, and preserving drafts after a failed save.
The recorder uses the macOS frameworks already on your Mac.

## Record a clip

1. Press **Command + Shift + Control + 5**.
2. Grant **Screen & System Audio Recording** permission if macOS asks, then quit and reopen LoopCapture.
3. Drag to select an area, or press Return for the whole display.
4. Press **Space** or the same shortcut to stop.

Both files are saved in your macOS screenshot folder, which defaults to the Desktop.
Closing the preview keeps the files.
The GIF is silent and some apps paste it as a still image.
If GIF conversion fails, LoopCapture keeps and copies the MP4.

If the shortcut opens privacy settings again after a rebuild, remove the old LoopCapture entry, add the exact app bundle you just built, enable it, and reopen it.

## Verify audio

Record a short clip while system audio is playing.
With FFmpeg and ffprobe installed, run:

```sh
python3 tests/check_av.py "/path/to/recording.mp4"
```

The check looks for one video track, one audio track, similar start and end times, and audible samples in the first 30 seconds.

## Try the browser paste demo

From the repository root, run `python3 -m http.server 8767 --bind 127.0.0.1` and open [the local demo](http://127.0.0.1:8767/paste-demo.html).
The included `<clip-input>` component accepts pasted, dropped, or selected image and video files.

## License

[Apache License 2.0](LICENSE).
