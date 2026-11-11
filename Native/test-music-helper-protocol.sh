#!/bin/bash
# The Music helper serves many requests from one process and exits when its
# parent goes away. These cases need no Music session or MediaRemote response.
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d /private/tmp/droidmirror-helper-tests.XXXXXX)
trap 'rm -rf "$work"' EXIT
clang -dynamiclib -fobjc-arc -fblocks -framework Foundation Native/MusicQueueHelper.m -o "$work/helper.dylib"
codesign -s - -f "$work/helper.dylib" 2>/dev/null
run() { /usr/bin/perl -MDynaLoader -e 'DynaLoader::dl_load_file($ARGV[0],0) or die DynaLoader::dl_error()' "$work/helper.dylib"; }

# One response per request, in order, including after invalid input.
long=$(/usr/bin/perl -e 'print "x" x 20000')
output=$(printf '%s\n' 'not json' '[1]' '{"action":"unknown"}' "$long" '{"action":"unknown"}' | run)
lines=$(printf '%s\n' "$output" | wc -l | tr -d ' ')
[[ "$lines" == 5 ]] || { echo "FAIL: expected 5 responses, got $lines: $output"; exit 1; }
[[ $(printf '%s\n' "$output" | grep -c '"available":false') == 5 ]] || { echo "FAIL: unexpected response: $output"; exit 1; }

# It waits for more work rather than exiting after the first request.
fifo="$work/in"; mkfifo "$fifo"
run < "$fifo" > "$work/out" & pid=$!
exec 3> "$fifo"
printf '{"action":"unknown"}\n' >&3
for _ in {1..50}; do [[ -s "$work/out" ]] && break; sleep 0.1; done
[[ -s "$work/out" ]] || { echo "FAIL: no response"; exit 1; }
kill -0 "$pid" || { echo "FAIL: helper exited while its parent still held stdin"; exit 1; }
# Closing stdin, as a dead parent would, ends it.
exec 3>&-
for _ in {1..50}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$pid" 2>/dev/null; then kill "$pid"; echo "FAIL: helper outlived its parent"; exit 1; fi
wait "$pid"
echo "PASS: helper answers each request in order, stays alive between requests and exits on EOF"
