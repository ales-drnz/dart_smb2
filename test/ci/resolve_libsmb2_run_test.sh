#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.
#
# Tests .github/scripts/resolve_libsmb2_run.sh on a copy of the real
# hook/build.dart, with the fake gh of test/ci/bin serving the package's
# releases and the libsmb2-scripts Builds.
#
#   bash test/ci/resolve_libsmb2_run_test.sh
set -euo pipefail
source "$(dirname "$0")/harness.sh"
resolve="$repo_root/.github/scripts/resolve_libsmb2_run.sh"

package="$scratch/package"
mkdir -p "$package/hook"

# Pins the package copy to libsmb2-r$1.
pin() {
  sed "s/^const _release = '[^']*';/const _release = 'libsmb2-r$1';/" \
    "$repo_root/hook/build.dart" > "$package/hook/build.dart"
  grep -q "^const _release = 'libsmb2-r$1';" "$package/hook/build.dart"
}

# The package's release libsmb2-r$1, published.
published() { echo "{\"tag_name\": \"libsmb2-r$1\", \"assets\": []}" > "$FAKE_GH/release/libsmb2-r$1.json"; }

# The build.yml runs of libsmb2-scripts, newest first, each given as
# id:branch:event:status:conclusion:release (conclusion null for a run
# going on; release is what _versions.sh builds at the run's commit, sha<id>).
builds() {
  local spec id branch event status conclusion release runs=()
  for spec in "$@"; do
    IFS=: read -r id branch event status conclusion release <<<"$spec"
    [[ "$conclusion" == null ]] || conclusion="\"$conclusion\""
    runs+=("{\"id\":$id,\"head_branch\":\"$branch\",\"event\":\"$event\",\"status\":\"$status\",\"conclusion\":$conclusion,\"head_sha\":\"sha$id\",\"created_at\":\"2026-11-0${#runs[@]}T00:00:00Z\"}")
    echo "$release" > "$FAKE_GH/versions/sha$id"
  done
  local IFS=,
  echo "[${runs[*]}]" > "$FAKE_GH/builds.json"
}

# Runs the resolver as the libsmb2 job does: prints its exit status, keeps
# what it printed on stdout in $FAKE_GH/out and the rest in $FAKE_GH/log.
# Extra environment comes from the arguments (NAME=value).
run() {
  local status=0
  env LIBSMB2_SCRIPTS_RUN= GH_TOKEN=scripts-token RELEASE_TOKEN=workflow-token \
    PACKAGE_ROOT="$package" "$@" "$resolve" > "$FAKE_GH/out" 2> "$FAKE_GH/log" || status=$?
  echo "$status"
}
out() { cat "$FAKE_GH/out"; }
calls() { wc -l < "$FAKE_GH/calls" | tr -d ' '; }
no_warning() { grep -c '::warning::\|::error::' "$FAKE_GH/log" || true; }

# A run given by hand.

new_gh
pin 10
expect_eq "a run given by hand passes" 0 "$(run LIBSMB2_SCRIPTS_RUN=777)"
expect_eq "and is printed as it is" 777 "$(out)"
expect_eq "without asking GitHub" 0 "$(calls)"

# The pin.

new_gh
pin 10
published 10
expect_eq "a published pin passes" 0 "$(run)"
expect_eq "and prints nothing" "" "$(out)"
expect_eq "with no warning" 0 "$(no_warning)"
expect_eq "looked up with the workflow token on the hook's repository" \
  "workflow-token api repos/ales-drnz/dart_smb2/releases/tags/libsmb2-r10 --jq .tag_name" \
  "$(cat "$FAKE_GH/calls")"

# The Build of rN.

new_gh
pin 10
builds 12:wip:workflow_dispatch:completed:success:r10 \
  11:release/0.2.5:push:completed:success:r10 10:release/0.2.5:push:completed:success:r10
expect_eq "the latest push Build of r10 passes" 0 "$(run)"
expect_eq "and is printed" 11 "$(out)"
expect_log "with its branch, commit, date and release" \
  "libsmb2-scripts run 11: release/0.2.5 at sha11, 2026-11-01T00:00:00Z, success, builds r10"
expect_eq "listed with the libsmb2-scripts token" 1 \
  "$(grep -c '^scripts-token api repos/ales-drnz/libsmb2-scripts/actions/workflows/build.yml/runs?event=push' "$FAKE_GH/calls")"
expect_eq "and the release read from its _versions.sh" 1 \
  "$(grep -c '^scripts-token api repos/ales-drnz/libsmb2-scripts/contents/scripts/shared/_versions.sh?ref=sha11' "$FAKE_GH/calls")"

new_gh
pin 10
builds 13:release/0.2.6:push:completed:success:r11 \
  12:release/0.2.5:push:completed:success:r10 11:release/0.2.4:push:completed:success:r9
expect_eq "Builds of other releases are passed over" "0 12" "$(run) $(out)"

new_gh
pin 10
builds 13:release/0.2.5:push:completed:failure:r10 12:release/0.2.5:push:completed:success:r10
expect_eq "a latest Build that failed passes" 0 "$(run)"
expect_eq "on the previous successful one" 12 "$(out)"
expect_log "and says so" "The latest Build of r10, run 13 (release/0.2.5 at sha13, .*), is failure: taking the latest successful one"

new_gh
pin 10
builds 14:release/0.2.5:push:in_progress:null:r10 12:release/0.2.5:push:completed:success:r10
expect_eq "a latest Build still going gives the previous successful one" "0 12" "$(run) $(out)"
expect_log "and says so" "run 14 .* is in_progress"

new_gh
pin 10
builds 15:release/0.2.5:workflow_dispatch:completed:success:r10 \
  14:wip:push:completed:success:r10 12:release/0.2.5:push:completed:success:r10
expect_eq "Builds started by hand or off release/ branches are passed over" "0 12" "$(run) $(out)"

new_gh
pin 10
builds 15:release/0.2.5:workflow_dispatch:completed:success:r10 14:wip:push:completed:success:r10
expect_eq "with only those, it fails" 1 "$(run)"
expect_eq "printing nothing" "" "$(out)"
expect_log "and says why" "::error::libsmb2-r10 is not published and ales-drnz/libsmb2-scripts has no Build of r10 started by a push"

new_gh
pin 10
expect_eq "no Build at all fails" 1 "$(run)"
expect_log "with the error" "::error::.*no Build of r10"

new_gh
pin 10
builds 13:release/0.2.5:push:completed:failure:r10 12:release/0.2.5:push:completed:cancelled:r10
expect_eq "no successful Build fails" 1 "$(run)"
expect_log "and says so" "::error::ales-drnz/libsmb2-scripts has no successful Build of r10"

new_gh
pin 10
builds 12:release/0.2.5:push:completed:success:r10
rm "$FAKE_GH/versions/sha12"
expect_eq "a commit whose _versions.sh cannot be read fails" 1 "$(run)"
expect_log "and says so" "::error::Could not read scripts/shared/_versions.sh"

# Tokens.

new_gh
pin 10
builds 11:release/0.2.5:push:completed:success:r10
expect_eq "without any token it passes" 0 "$(run GH_TOKEN= RELEASE_TOKEN=)"
expect_eq "printing nothing: the jobs use the pinned release" "" "$(out)"
expect_log "with a warning" "::warning::No LIBSMB2_SCRIPTS_TOKEN .*the pinned libsmb2 release libsmb2-r10"
expect_eq "and no call" 0 "$(calls)"

new_gh
pin 10
published 10
expect_eq "a fork pull request on a published pin passes" "0 " "$(run GH_TOKEN=) $(out)"
expect_eq "without a warning" 0 "$(no_warning)"

new_gh
pin 10
builds 11:release/0.2.5:push:completed:success:r10
expect_eq "a fork pull request needing a Build prints nothing" "0 " "$(run GH_TOKEN=) $(out)"
expect_log "with the warning" "::warning::No LIBSMB2_SCRIPTS_TOKEN"

new_gh
pin 10
builds 11:release/0.2.5:push:completed:success:r10
echo scripts-token > "$FAKE_GH/expired"
expect_eq "an expired token fails" 1 "$(run)"
expect_log "and says so" "::error::LIBSMB2_SCRIPTS_TOKEN was refused (HTTP 401)"

new_gh
pin 10
touch "$FAKE_GH/down"
expect_eq "GitHub out of reach leaves the pinned release" "0 " "$(run) $(out)"
expect_log "with a warning" "::warning::Could not look up the libsmb2 release libsmb2-r10"

finish
