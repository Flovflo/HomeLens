#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
mkdir -p .build
# Also works with macOS Command Line Tools, which do not ship XCTest.
swiftc -parse-as-library Sources/HomeLensCore/BundledBinaries.swift \
  Sources/HomeLensCore/CameraConfig.swift Sources/HomeLensCore/VideoPipeline.swift \
  Tests/VideoPipelineChecks.swift -o .build/video-pipeline-checks
.build/video-pipeline-checks
node --test Helpers/HomeKitBridge/test/video.test.mjs
if [[ "${1:-}" == "--media" ]]; then
  node Helpers/HomeKitBridge/test/media-integration.mjs
  swiftc -parse-as-library Sources/HomeLensCore/BundledBinaries.swift \
    Sources/HomeLensCore/VideoPipeline.swift Sources/HomeLens/Services/LocalHLSServer.swift \
    Tests/HLSPlaybackChecks.swift -o .build/hls-playback-checks
  .build/hls-playback-checks
fi
