#!/bin/bash
# watch_tests.sh
# Burnline
#
# Copyright (C) 2026 Challapalli Harshavardhan Reddy
# Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.
#
# Runs a test command, copying its output to a log, and stops it if it prints
# nothing for STALL_SECONDS. A hung suite then fails in minutes, not at the
# job's time limit, and explains itself: before stopping it, this saves a
# stack sample of each test process and the process table beside the log,
# and names the tests that started and never finished.
#
#   watch_tests.sh <log> <command...>
#
# Exits with the command's status, or 124 when it was stopped.

set -uo pipefail

log="$1"; shift
stall="${STALL_SECONDS:-300}"
dir="$(dirname "$log")"
mkdir -p "$dir"
: > "$log"

"$@" > >(tee -a "$log") 2>&1 &
command=$!

# Every process below `$1`, deepest last.
descendants() {
    local child
    for child in $(pgrep -P "$1"); do echo "$child"; descendants "$child"; done
}

last=-1
quiet=0
while kill -0 "$command" 2>/dev/null; do
    sleep 5
    size=$(wc -c < "$log")
    if [ "$size" -ne "$last" ]; then last=$size; quiet=0; continue; fi
    quiet=$((quiet + 5))
    [ "$quiet" -lt "$stall" ] && continue

    {
        echo
        echo "error: the test run printed nothing for $stall seconds and was stopped."
        echo "Tests that started and did not finish:"
        grep -oE '◇ Test (case passing .* to )?"?[^"]+"? started' "$log" \
            | sed -E 's/^◇ Test (case passing .* to )?"?//; s/"? started$//' | sort -u > "$dir/started.txt"
        grep -oE '[✔✘] Test (case passing .* to )?"?[^"]+"? (passed|failed)' "$log" \
            | sed -E 's/^[✔✘] Test (case passing .* to )?"?//; s/"? (passed|failed)$//' | sort -u > "$dir/finished.txt"
        comm -23 "$dir/started.txt" "$dir/finished.txt" | sed 's/^/  /'
    } | tee -a "$log"
    ps -axo pid,ppid,pgid,stat,etime,command > "$dir/hang-processes.txt"
    stuck=$(descendants "$command")
    for pid in $stuck; do
        case "$(ps -o comm= -p "$pid")" in
            *xctest*|*swiftpm-testing-helper*) sample "$pid" 5 -file "$dir/hang-sample-$pid.txt" > /dev/null 2>&1 ;;
        esac
    done
    kill -9 $stuck 2>/dev/null
    kill "$command" 2>/dev/null
    wait "$command" 2>/dev/null
    exit 124
done
wait "$command"
