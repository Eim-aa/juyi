#!/usr/bin/env bash
# Record a 30-second demo using macOS screencapture, then transcode with ffmpeg
# when ffmpeg is available.
set -euo pipefail

OUT_DIR="${1:-$HOME/Desktop}"
STAMP="$(date +%Y%m%d-%H%M%S)"
RAW="$OUT_DIR/argos-translator-demo-$STAMP.mov"
MP4="$OUT_DIR/argos-translator-demo-$STAMP.mp4"

mkdir -p "$OUT_DIR"

echo "Recording 30 seconds to: $RAW"
echo "Prepare a text selection, press Option+T during recording, then wait."
/usr/sbin/screencapture -v -V 30 "$RAW"

if command -v ffmpeg >/dev/null 2>&1; then
    ffmpeg -y -i "$RAW" -c:v libx264 -pix_fmt yuv420p -movflags +faststart "$MP4"
    echo "Demo MP4: $MP4"
else
    echo "ffmpeg not found; kept raw recording: $RAW"
    echo "Install ffmpeg with: brew install ffmpeg"
fi
