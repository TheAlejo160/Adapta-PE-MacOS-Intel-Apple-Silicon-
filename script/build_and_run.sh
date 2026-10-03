#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK_BUILD="${TMPDIR:-/tmp}/adapta-pe-run"
MODE="${1:-run}"
case "$MODE" in run|--debug|--logs|--telemetry|--verify) ;; *) echo "Uso: $0 [--debug|--logs|--telemetry|--verify]" >&2; exit 2;; esac
pkill -x Adapta-PE 2>/dev/null || true
xcodebuild -project "$TASK_ROOT/Adapta-PE.xcodeproj" -scheme Adapta-PE -configuration Debug -derivedDataPath "$TASK_BUILD" build
APP="$TASK_BUILD/Build/Products/Debug/Adapta-PE.app"
if [[ "$MODE" == --debug ]]; then
    /usr/bin/open -a Xcode "$TASK_ROOT/Adapta-PE.xcodeproj"
    echo 'Proyecto abierto en Xcode. Usa Product > Run para ver la consola.'
    exit 0
fi
/usr/bin/open -n "$APP"
case "$MODE" in
    --logs) /usr/bin/log stream --level info --style compact --predicate 'process == "Adapta-PE"';;
    --telemetry) /usr/bin/log stream --level info --style compact --predicate 'subsystem == "pe.adapta.desktop"';;
    --verify) sleep 1; pgrep -x Adapta-PE >/dev/null;;
esac
