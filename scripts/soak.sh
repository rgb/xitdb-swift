#!/usr/bin/env bash
#
# The model-based tests on fresh seeds for a while: the soak the gate does
# not pay for.
#
#   scripts/soak.sh [seconds]      default 300
#
# Each of the two suites' soak test runs seeds until the time is spent and
# prints how many it ran and the last seed; a failure prints the shortest
# failing sequence, as a conformance-style script for the engine's suite.

set -euo pipefail
cd "$(dirname "$0")/.."

XITDB_MODEL_SOAK="${1:-300}" swift test --filter "ModelTests/soak|StoreModelTests/soak" 2>&1 | grep -E "soak:|✘|✔ Test run|↳" || true
