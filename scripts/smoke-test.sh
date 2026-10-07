#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v ffmpeg >/dev/null || { echo 'FFmpeg is required for test fixtures.' >&2; exit 1; }
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/kompx-smoke.XXXXXX")"
trap 'rm -rf "$fixture_dir"' EXIT
ffmpeg -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=1920x1080:rate=30' \
  -f lavfi -i 'sine=frequency=440:sample_rate=48000' -t 4 -c:v libx264 -preset ultrafast \
  -crf 12 -c:a aac -shortest "$fixture_dir/video.mp4"
ffmpeg -hide_banner -loglevel error -i "$fixture_dir/video.mp4" -map 0:v -c copy "$fixture_dir/silent.mp4"
ffmpeg -hide_banner -loglevel error -display_rotation 90 -i "$fixture_dir/video.mp4" \
  -map 0 -c copy "$fixture_dir/rotated.mov"
ffmpeg -hide_banner -loglevel error -i "$fixture_dir/video.mp4" -map 0:v -map 0:a -map 0:a \
  -c copy "$fixture_dir/multitrack.mp4"
xcrun swiftc -parse-as-library -O -target "$(uname -m)-apple-macos14.0" \
  "$project_root/Sources/komPX/Models/SharedTypes.swift" \
  "$project_root/Sources/komPX/Services/CompressionPauseController.swift" \
  "$project_root/Sources/komPX/Services/ImageCompressor.swift" \
  "$project_root/Sources/komPX/Services/VideoCompressor.swift" \
  "$project_root/CompressionRuntimeSmoke.swift" -o "$fixture_dir/smoke"
"$fixture_dir/smoke" "$fixture_dir"
