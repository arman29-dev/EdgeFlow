#!/bin/bash
# Runs the automated unit tests (pure logic: settings, gesture engine, media gate, haptics). No hardware needed.
set -euo pipefail
cd "$(dirname "$0")/.."
swift test
