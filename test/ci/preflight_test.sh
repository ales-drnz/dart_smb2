#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.
#
# Tests .github/scripts/preflight.sh on a copy of the real hook/build.dart,
# pinned to libsmb2-r99, with the fake gh of test/ci/bin serving the
# release and the libsmb2-scripts runs.
#
#   bash test/ci/preflight_test.sh
set -euo pipefail
source "$(dirname "$0")/harness.sh"
preflight="$repo_root/.github/scripts/preflight.sh"

mkdir -p "$scratch/package/hook"
cd "$scratch/package"
sed "s/^const _release = '[^']*';/const _release = 'libsmb2-r99';/" \
  "$repo_root/hook/build.dart" > hook/build.dart
grep -q "^const _release = 'libsmb2-r99';" hook/build.dart
mapfile -t assets < <(grep -oE "^  'libsmb2_[^']+':" hook/build.dart | tr -d "':" | tr -d ' ')
(( ${#assets[@]} >= 9 ))

# The release libsmb2-r99 with these assets.
release() {
  printf '%s\n' "$@" | jq -R '{name: .}' | jq -s '{tag_name: "libsmb2-r99", assets: .}' \
    > "$FAKE_GH/release/libsmb2-r99.json"
}

# Runs the preflight as the libsmb2 job does and prints its exit status.
preflight() { # run, token, fork
  local status=0
  LIBSMB2_SCRIPTS_RUN="$1" LIBSMB2_SCRIPTS_TOKEN="$2" FORK="$3" GH_TOKEN=workflow-token \
    "$preflight" > "$FAKE_GH/log" 2>&1 || status=$?
  echo "$status"
}

new_gh
release "${assets[@]}" COPYING
expect_eq "a published release passes" 0 "$(preflight "" "" "")"
expect_eq "looked up with the workflow token on the hook's repository" \
  "workflow-token api repos/ales-drnz/dart_smb2/releases/tags/libsmb2-r99 --jq .assets[].name" \
  "$(cat "$FAKE_GH/calls")"

new_gh
expect_eq "a release not published stops the run" 1 "$(preflight "" "" "")"
expect_log "and names the way out" "::error::.*libsmb2-r99 is not published.*resolve_libsmb2_run.sh"

new_gh
release "${assets[@]:1}"
expect_eq "a release without one of its assets stops the run" 1 "$(preflight "" "" "")"
expect_log "and names it" "::error::.*has no ${assets[0]}"

new_gh
touch "$FAKE_GH/down"
expect_eq "a release lookup GitHub cannot answer only warns" 0 "$(preflight "" "" "")"
expect_log "with a warning" "::warning::"

# The libsmb2-scripts run 4242, finished with $1.
scripts_run() {
  echo "{\"id\":4242,\"head_sha\":\"abc123\",\"head_branch\":\"release/0.2.5\",\"conclusion\":\"$1\"}" \
    > "$FAKE_GH/run/4242.json"
}

new_gh
scripts_run success
expect_eq "a green libsmb2-scripts run passes" 0 "$(preflight 4242 scripts-token "")"
expect_log "and says which build is under test" "run 4242: release/0.2.5 at abc123"
expect_eq "looked up with LIBSMB2_SCRIPTS_TOKEN, leaving the pinned release alone" \
  "scripts-token api repos/ales-drnz/libsmb2-scripts/actions/runs/4242" \
  "$(cut -d' ' -f1-3 "$FAKE_GH/calls")"

new_gh
scripts_run success
expect_eq "a libsmb2-scripts run without the token stops the run" 1 "$(preflight 4242 "" "")"
expect_log "and names the secret" "::error::LIBSMB2_SCRIPTS_RUN is set but LIBSMB2_SCRIPTS_TOKEN is not"

new_gh
scripts_run success
echo scripts-token > "$FAKE_GH/expired"
expect_eq "an expired token stops the run" 1 "$(preflight 4242 scripts-token "")"
expect_log "and says it expired" "::error::LIBSMB2_SCRIPTS_TOKEN was refused (HTTP 401).*expired"

new_gh
expect_eq "a run the token cannot see stops the run" 1 "$(preflight 4242 scripts-token "")"
expect_log "and says so" "::error::.*run 4242.*HTTP 404"

new_gh
scripts_run failure
expect_eq "a run that failed stops the run" 1 "$(preflight 4242 scripts-token "")"
expect_log "and says so" "::error::libsmb2-scripts run 4242 did not succeed (failure)"

new_gh
touch "$FAKE_GH/down"
expect_eq "a run lookup GitHub cannot answer only warns" 0 \
  "$(preflight 4242 scripts-token "")"
expect_log "with a warning" "::warning::"

new_gh
expect_eq "a fork without the token checks the pinned release" 1 \
  "$(preflight 4242 "" true)"
expect_log "and warns about the fallback" "::warning::No LIBSMB2_SCRIPTS_TOKEN on a fork"

new_gh
release "${assets[@]}"
expect_eq "and passes when it is published" 0 "$(preflight 4242 "" true)"

finish
