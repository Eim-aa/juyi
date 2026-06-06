# docs/

Assets used by the project README.

## demo.gif

The workflow in a real TextEdit window: a sentence is selected, the Option key
is double-tapped, and the Hammerspoon canvas pops up with the Chinese
translation plus the real latency. The committed `demo.gif` is a real screen
recording (cropped to the editor, palette-optimized); `render_demo.py` (below)
is a synthetic fallback for when screen recording isn't available.

To re-record:

```bash
# 1. Open a text file in TextEdit with one line of English
# 2. Start recording (Cmd+Shift+5 → "Record Selected Portion") OR use the CLI:
screencapture -V 8 -C demo.mov

# 3. While it records: select the line, double-tap Option (⌥⌥), wait for the popup
# 4. Convert to gif (palette-optimized, ~720p, ~12 fps):
ffmpeg -y -ss 1.2 -t 6.6 -i demo.mov \
  -vf "crop=1500:920:200:100,fps=12,scale=720:-2:flags=lanczos,split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=5" \
  -loop 0 docs/demo.gif
```

Adjust the `crop=W:H:X:Y` to fit your screen and window position. Keep the GIF
under ~3 MB for fast README loads. Tune `fps` and `scale` if the file grows
too large.

## render_demo.py

A scripted fallback that generates a synthetic 3-frame GIF from Pillow (no
screen recording required). The popup's Chinese text and latency are pulled
live from `POST /translate`. Useful if you can't grant screen-recording
permission to your shell, or want a deterministic frame composition.

```bash
~/.local/share/argos-translator/venv/bin/pip install Pillow  # one-time
~/.local/share/argos-translator/venv/bin/python docs/render_demo.py
```

Pillow is only used by this script — not a runtime dependency.
