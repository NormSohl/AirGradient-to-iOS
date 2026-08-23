#!/bin/sh
# Compiles the model layer together with Tests.swift for macOS and runs it.
# No simulator, no scheme, no test target — see the note at the top of main.swift.
set -e
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
xcrun swiftc -O -o "$OUT/tests" \
  AirGradientMonitor/Models/Reading.swift \
  AirGradientMonitor/Models/Monitor.swift \
  AirGradientMonitor/Models/Metric.swift \
  AirGradientMonitor/Models/SeriesShaping.swift \
  AirGradientMonitor/Models/DemoSource.swift \
  AirGradientMonitor/Networking/AirGradientClient.swift \
  AirGradientMonitor/Store/HistoryStore.swift \
  Tests/main.swift
"$OUT/tests"
