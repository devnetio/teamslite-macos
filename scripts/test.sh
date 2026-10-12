#!/bin/bash
# Logic tests (HTML conversion, dates, notification parsing, unread state).
# XCTest isn't available with Command Line Tools only, so this compiles a plain test binary.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
SRC=Sources/TeamsLite
swiftc -o build/logic-tests \
  $SRC/Config.swift $SRC/Auth.swift $SRC/Graph.swift $SRC/Models.swift $SRC/HTML.swift \
  $SRC/Relay.swift $SRC/Notifier.swift $SRC/AppModel.swift $SRC/DemoData.swift $SRC/Transcript.swift $SRC/Images.swift \
  Tests/main.swift
build/logic-tests
