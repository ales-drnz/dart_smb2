#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.
#
# Finds the libsmb2-scripts Build that CI should bundle instead of the
# pinned libsmb2 release, and prints its run id, or nothing when the pinned
# release serves. ci.yml's libsmb2 job runs it once for every job.
#
# The release CI needs is the pin, libsmb2-rN (_release in hook/build.dart):
#   - published (on the repository the hook downloads from): nothing to do;
#   - not published: the latest successful Build (build.yml) of
#     libsmb2-scripts started by a push to a release/ branch whose
#     scripts/shared/_versions.sh builds rN (LIBSMB2_RELEASE). Its branches
#     carry the package version (release/0.2.5), not rN, hence the lookup
#     by content. Runs started by hand are never taken. When the latest
#     Build of rN did not succeed, or is still going, the log says so and
#     the previous successful one serves. None is an error.
# A run id given by hand (LIBSMB2_SCRIPTS_RUN) is printed as it is. Without
# a token (a pull request from a fork gets no secrets) the jobs use the
# pinned release, with a warning.
#
# Everything but the run id goes to stderr, so that
#   run="$(.github/scripts/resolve_libsmb2_run.sh)"
# holds the id alone.
#
# Reads from the environment:
#   LIBSMB2_SCRIPTS_RUN  a run id to use as it is, empty to look one up
#   GH_TOKEN             a token with Actions read access on
#                        ales-drnz/libsmb2-scripts (LIBSMB2_SCRIPTS_TOKEN)
#   RELEASE_TOKEN        the token for the release lookup, GH_TOKEN by
#                        default (the workflow's own reads public releases)
#   PACKAGE_ROOT         the dart_smb2 checkout, this script's by default
#
#   .github/scripts/resolve_libsmb2_run.sh
set -euo pipefail

if [[ -n "${LIBSMB2_SCRIPTS_RUN:-}" ]]; then
  echo "libsmb2-scripts run $LIBSMB2_SCRIPTS_RUN, given by hand" >&2
  echo "$LIBSMB2_SCRIPTS_RUN"
  exit 0
fi

scripts_repo=ales-drnz/libsmb2-scripts
root="${PACKAGE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
hook="$root/hook/build.dart"
err="$(mktemp)"
trap 'rm -f "$err"' EXIT

# The HTTP status of the last failed gh call, or nothing for a failure
# that never reached GitHub.
http_status() { sed -n 's/.*(HTTP \([0-9]*\)).*/\1/p' "$err" | tail -n 1; }

tag="$(sed -n "s/^const _release = '\(libsmb2-r[0-9]*\)';/\1/p" "$hook")"
repo="$(sed -n 's#.*https://github\.com/\([^/]*/[^/]*\)/releases/download/.*#\1#p' "$hook" | head -n 1)"
if [[ -z "$tag" || -z "$repo" ]]; then
  echo "::error::$hook has no _release or no release URL." >&2
  exit 1
fi
want="${tag#libsmb2-}"

no_token() {
  echo "::warning::No LIBSMB2_SCRIPTS_TOKEN (a fork pull request gets no secrets): using the pinned libsmb2 release $tag." >&2
  exit 0
}
release_token="${RELEASE_TOKEN:-${GH_TOKEN:-}}"
[[ -n "$release_token" ]] || no_token

if GH_TOKEN="$release_token" gh api "repos/$repo/releases/tags/$tag" \
  --jq .tag_name > /dev/null 2>"$err"; then
  echo "The pinned libsmb2 release $tag is published." >&2
  exit 0
fi
if [[ "$(http_status)" != 404 ]]; then
  # The pinned release serves; the preflight checks it again.
  echo "::warning::Could not look up the libsmb2 release $tag on $repo: $(cat "$err")" >&2
  exit 0
fi
[[ -n "${GH_TOKEN:-}" ]] || no_token
echo "$tag is not published on $repo: looking for the Build of $want." >&2

refused() {
  if [[ "$(http_status)" == 401 ]]; then
    echo "::error::LIBSMB2_SCRIPTS_TOKEN was refused (HTTP 401): it has most likely expired. Renew it, Actions read access on $scripts_repo only." >&2
  else
    echo "::error::$1: $(cat "$err")" >&2
  fi
  exit 1
}

# The Builds started by a push to a release/ branch, newest first. The
# filter checks the event again in case the query ignored it.
builds="$(gh api "repos/$scripts_repo/actions/workflows/build.yml/runs?event=push&per_page=50" \
  --jq '.workflow_runs[]
    | select(.event == "push" and (.head_branch | startswith("release/")))
    | "\(.id) \(.head_sha) \(.head_branch) \(.created_at) \(.status) \(.conclusion)"' \
  2>"$err")" || refused "Could not list the Builds of $scripts_repo"

# The release a commit of libsmb2-scripts builds (LIBSMB2_RELEASE).
release_of() { # sha
  local versions
  versions="$(gh api "repos/$scripts_repo/contents/scripts/shared/_versions.sh?ref=$1" \
    --jq '.content | gsub("\n"; "") | @base64d' 2>"$err")" ||
    refused "Could not read scripts/shared/_versions.sh of $scripts_repo at $1"
  sed -n 's/^export LIBSMB2_RELEASE="${LIBSMB2_RELEASE:-\(r[0-9]*\)}"$/\1/p' <<<"$versions"
}

latest=""
found=""
declare -A seen=()
while read -r id sha branch date status conclusion; do
  [[ -n "$id" ]] || continue
  if [[ -z "${seen[$sha]+x}" ]]; then
    release="$(release_of "$sha")" || exit 1
    seen[$sha]="$release"
  fi
  [[ "${seen[$sha]}" == "$want" ]] || continue
  if [[ -z "$latest" ]]; then
    latest="$id"
    if [[ "$conclusion" != success ]]; then
      [[ "$status" == completed ]] || conclusion="$status"
      echo "The latest Build of $want, run $id ($branch at $sha, $date), is $conclusion: taking the latest successful one." >&2
      continue
    fi
  fi
  if [[ "$conclusion" == success ]]; then
    found="$id $branch $sha $date"
    break
  fi
done <<<"$builds"

if [[ -z "$latest" ]]; then
  echo "::error::$tag is not published and $scripts_repo has no Build of $want started by a push to a release/ branch. Push one there, or give a run by hand (the libsmb2_scripts_run input or the LIBSMB2_SCRIPTS_RUN variable)." >&2
  exit 1
fi
if [[ -z "$found" ]]; then
  echo "::error::$scripts_repo has no successful Build of $want started by a push." >&2
  exit 1
fi
read -r id branch sha date <<<"$found"
echo "libsmb2-scripts run $id: $branch at $sha, $date, success, builds $want" >&2
echo "$id"
