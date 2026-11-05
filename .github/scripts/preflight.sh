#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.
#
# The preflight of ci.yml's libsmb2 job: checks, before any test or build
# starts, that the libsmb2 the jobs will bundle can be had. Without it each
# job that runs the build hook fails on its own, minutes in.
#
# With LIBSMB2_SCRIPTS_RUN set, the jobs take that libsmb2-scripts run's
# libraries (.github/actions/libsmb2-from-run): LIBSMB2_SCRIPTS_TOKEN must
# be set, still valid (a fine-grained token expires, and GitHub then
# answers 401) and able to read the run, and the run must be green. A pull
# request from a fork gets no secrets and falls back to the pinned release,
# like the action does. Otherwise the release pinned in hook/build.dart
# must be published with every asset the hook's checksum table names. A
# lookup that fails for want of GitHub only warns: the jobs will try again.
#
# Reads from the environment:
#   LIBSMB2_SCRIPTS_RUN    the run the jobs bundle (resolve_libsmb2_run.sh),
#                          empty for the pinned release
#   LIBSMB2_SCRIPTS_TOKEN  the secret, empty when unset
#   FORK                   "true" on a pull request from a fork
#   GH_TOKEN               the workflow's token, for this repository's releases
#   HOOK                   the build hook, hook/build.dart by default
#
#   .github/scripts/preflight.sh
set -euo pipefail

scripts_repo=ales-drnz/libsmb2-scripts
hook="${HOOK:-hook/build.dart}"
err="$(mktemp)"
trap 'rm -f "$err"' EXIT

# The HTTP status of the last failed gh call, or nothing for a failure
# that never reached GitHub.
http_status() { sed -n 's/.*(HTTP \([0-9]*\)).*/\1/p' "$err" | tail -n 1; }

check_release() {
  local tag repo names missing=()
  tag="$(sed -n "s/^const _release = '\([^']*\)';/\1/p" "$hook")"
  repo="$(sed -n 's#.*https://github\.com/\([^/]*/[^/]*\)/releases/download/.*#\1#p' "$hook" | head -n 1)"
  if [[ -z "$tag" || -z "$repo" ]]; then
    echo "::error::$hook has no _release or no release URL."
    exit 1
  fi
  if ! names="$(gh api "repos/$repo/releases/tags/$tag" --jq '.assets[].name' 2>"$err")"; then
    if [[ "$(http_status)" == 404 ]]; then
      echo "::error::The pinned libsmb2 release $tag is not published on $repo. Until it is, CI takes the libsmb2-scripts Build of it (.github/scripts/resolve_libsmb2_run.sh), which needs LIBSMB2_SCRIPTS_TOKEN, or a run given as LIBSMB2_SCRIPTS_RUN."
      exit 1
    fi
    echo "::warning::Could not look up the pinned libsmb2 release $tag: $(cat "$err")"
    return 0
  fi
  while read -r asset; do
    grep -qxF -- "$asset" <<<"$names" || missing+=("$asset")
  done < <(sed -n '/^const _sha256 = /,/^};/p' "$hook" | sed -n "s/^ *'\([^']*\)':.*/\1/p")
  if (( ${#missing[@]} )); then
    echo "::error::The pinned libsmb2 release $tag has no ${missing[*]}: its upload may not be finished."
    exit 1
  fi
  echo "The pinned libsmb2 release $tag is published with every asset the hook pins."
}

check_run() {
  local run="$LIBSMB2_SCRIPTS_RUN" line sha branch conclusion
  if ! line="$(GH_TOKEN="$LIBSMB2_SCRIPTS_TOKEN" gh api "repos/$scripts_repo/actions/runs/$run" \
    --jq '"\(.head_sha) \(.head_branch) \(.conclusion)"' 2>"$err")"; then
    case "$(http_status)" in
      401)
        echo "::error::LIBSMB2_SCRIPTS_TOKEN was refused (HTTP 401): it has most likely expired. Renew it, Actions read access on $scripts_repo only, and note its new expiry date."
        exit 1
        ;;
      '')
        echo "::warning::Could not look up libsmb2-scripts run $run: $(cat "$err")"
        return 0
        ;;
      *)
        echo "::error::libsmb2-scripts run $run cannot be read with LIBSMB2_SCRIPTS_TOKEN: $(cat "$err")"
        exit 1
        ;;
    esac
  fi
  read -r sha branch conclusion <<<"$line"
  echo "libsmb2-scripts run $run: $branch at $sha, $conclusion"
  if [[ "$conclusion" != success ]]; then
    echo "::error::libsmb2-scripts run $run did not succeed ($conclusion)."
    exit 1
  fi
}

if [[ -n "${LIBSMB2_SCRIPTS_RUN:-}" ]]; then
  if [[ -n "${LIBSMB2_SCRIPTS_TOKEN:-}" ]]; then
    check_run
    exit 0
  fi
  if [[ "${FORK:-}" != true ]]; then
    echo "::error::LIBSMB2_SCRIPTS_RUN is set but LIBSMB2_SCRIPTS_TOKEN is not: add a fine-grained token with Actions read access on $scripts_repo."
    exit 1
  fi
  echo "::warning::No LIBSMB2_SCRIPTS_TOKEN on a fork pull request: the jobs use the pinned libsmb2 release."
fi
check_release
