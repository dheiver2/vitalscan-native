#!/bin/bash
# Roda a suíte de testes do núcleo DSP (sem câmera). Só precisa das CLT.
set -e
PROJ="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)/dsptests"
swiftc -O "$PROJ/Sources/DSP.swift" "$PROJ/Sources/SignalMath.swift" \
       -framework Accelerate "$PROJ/Tests/main.swift" -o "$OUT"
"$OUT"
