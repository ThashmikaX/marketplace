#!/usr/bin/env bash
# Runs one or more test scripts and prints results as pipe-delimited lines.
#
# Usage:
#   KUBECONFIG=<path> KUBECTL_CONTEXT=<ctx> TIMEOUT_SEC=<n> ./run-tests.sh script1.sh [script2.sh ...]
#
# Output per script (one line each):
#   <name>|<exit-code>|<duration-seconds>|<last-output-line>
#
# Environment variables:
#   KUBECONFIG      — path to kubeconfig (required)
#   KUBECTL_CONTEXT — kubectl context name (required)
#   TIMEOUT_SEC     — per-script timeout in seconds (default: 30)

set -uo pipefail

TIMEOUT_SEC="${TIMEOUT_SEC:-30}"

strip_ansi() {
    sed 's/\x1B\[[0-9;]*[mKHF]//g; s/\x1B//g'
}

ms_now() {
    if date +%s%3N &>/dev/null 2>&1; then
        date +%s%3N
    else
        python3 -c "import time; print(int(time.time()*1000))"
    fi
}

for script_path in "$@"; do
    [ -f "$script_path" ] || { echo "$(basename "$script_path")|1|0|file not found"; continue; }

    name=$(basename "$script_path" .sh)
    start=$(ms_now)

    output=$(
        export KUBECONFIG KUBECTL_CONTEXT NO_COLOR=1 TERM=dumb
        timeout "$TIMEOUT_SEC" bash "$script_path" 2>&1
    ) || exit_code=$?
    exit_code=${exit_code:-0}

    end=$(ms_now)
    duration=$(awk "BEGIN {printf \"%.1f\", ($end - $start) / 1000}")
    output=$(printf '%s' "$output" | strip_ansi)

    [ "$exit_code" -eq 124 ] && output="TIMEOUT after ${TIMEOUT_SEC}s"

    last_line=$(printf '%s' "$output" | grep -v '^[[:space:]]*$' | tail -1)
    echo "${name}|${exit_code}|${duration}|${last_line}"
done
