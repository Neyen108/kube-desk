#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/module-cache
swiftc -module-cache-path "$PWD/.build/module-cache" Sources/KubeDesk/Kubernetes.swift Tests/Standalone/Checks.swift -o .build/core-checks
.build/core-checks
swiftc -module-cache-path "$PWD/.build/module-cache" Sources/KubeDesk/Kubernetes.swift Sources/KubeDesk/Store.swift Tests/Standalone/LoadingChecks.swift -o .build/loading-checks
.build/loading-checks
