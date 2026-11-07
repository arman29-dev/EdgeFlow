#!/bin/bash
# Runs the hardware probe (see README). Builds first if needed.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
"$(swift build -c release --show-bin-path)/TrackpadEdgeGestures" --probe
