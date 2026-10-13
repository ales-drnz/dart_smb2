#!/usr/bin/env bash
# Runs test_app/integration_test on the iOS simulator $1, with a watchdog.
#
# flutter test sometimes misses the app's VM service URL on an iOS
# simulator and then waits forever after the build
# (https://github.com/flutter/flutter/issues/181771, fix pending in
# https://github.com/flutter/flutter/pull/193142). When no test has started
# GRACE seconds after the build, the attempt is stopped and retried, up to
# 3 attempts. A run that starts and fails still fails the job.
#
# Run from test_app/.
set -uo pipefail

udid=$1
grace=${GRACE:-180}
app=com.alesdrnz.dartSmb2TestApp

attempt() {
  local log pid built=""
  log=$(mktemp)
  (flutter test integration_test -d "$udid" 2>&1 | tee "$log") &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ -z "$built" ] && grep -q "Xcode build done" "$log"; then built=$(date +%s); fi
    # Test progress lines look like "00:01 +3: offline ...", after "+0: loading ...".
    if [ -n "$built" ] && ! grep -E ' \+[0-9]+( ~[0-9]+)?( -[0-9]+)?: ' "$log" | grep -vq ': loading ' &&
      [ $(($(date +%s) - built)) -gt "$grace" ]; then
      echo "::warning::No test started ${grace}s after the build (flutter/flutter#181771): retrying."
      pkill -f "flutter_tools.snapshot test" || true
      pkill -P "$pid" || true
      wait "$pid"
      xcrun simctl terminate "$udid" "$app" 2>/dev/null || true
      return 2
    fi
    sleep 5
  done
  wait "$pid"
}

for n in 1 2 3; do
  echo "::group::Integration tests, attempt $n"
  attempt
  status=$?
  echo "::endgroup::"
  [ "$status" -ne 2 ] && exit "$status"
done
echo "::error::The integration tests never started in 3 attempts."
exit 1
