#!/bin/sh
# Copies the wire contract from a commit of the Hermes desktop/daemon repo
# (ADR-001): the protos, the home and board fixtures, where they came from
# and their checksums.
#
#   scripts/contract/vendor.sh <path to the desktop repo> <commit>
#       vendor; then run scripts/contract/generate-swift.sh and the tests
#   scripts/contract/vendor.sh --check
#       fail if a vendored file was changed by hand since it was vendored
set -eu
cd "$(dirname "$0")/../.."

if [ "${1:-}" = "--check" ]; then
  # The checksums are the lines after "sha256:" in SOURCE, paths relative to contract/.
  sums=$(sed -n '/^sha256:$/,$p' contract/SOURCE | sed 1d)
  [ -n "$sums" ] || { echo "contract/SOURCE has no checksums. Re-vendor with scripts/contract/vendor.sh." >&2; exit 1; }
  listed=$(printf '%s\n' "$sums" | awk '{print $2}' | sort)
  present=$(cd contract && find proto fixtures -type f | sort)
  if [ "$listed" != "$present" ]; then
    echo "contract/ files differ from those listed in contract/SOURCE. Re-vendor instead of editing by hand." >&2
    exit 1
  fi
  if ! (cd contract && printf '%s\n' "$sums" | shasum -a 256 -c --quiet -); then
    echo "A vendored contract file was edited by hand. Change it in the desktop repo and re-vendor." >&2
    exit 1
  fi
  echo "Vendored contract files match contract/SOURCE."
  exit 0
fi

repo=$1
commit=$2
full=$(git -C "$repo" rev-parse "$commit^{commit}")
if ! git -C "$repo" merge-base --is-ancestor "$full" origin/main 2>/dev/null; then
  echo "warning: $full is not on the desktop repo's origin/main; re-vendor from main once it merges." >&2
fi
rm -rf contract/proto contract/fixtures
for path in $(git -C "$repo" ls-tree -r --name-only "$full" proto/); do
  mkdir -p "contract/$(dirname "$path")"
  git -C "$repo" show "$full:$path" > "contract/$path"
done
mkdir -p contract/fixtures/home
for path in $(git -C "$repo" ls-tree --name-only "$full" crates/bus/fixtures/home/); do
  git -C "$repo" show "$full:$path" > "contract/fixtures/home/$(basename "$path")"
done
# The board's golden proto-JSON, its messages and envelopes included.
for path in $(git -C "$repo" ls-tree -r --name-only "$full" crates/bus/fixtures/board/); do
  rel=${path#crates/bus/fixtures/}
  mkdir -p "contract/fixtures/$(dirname "$rel")"
  git -C "$repo" show "$full:$path" > "contract/fixtures/$rel"
done
{
  printf 'proto/ and fixtures/ come from the Hermes repo at\n%s\n' "$full"
  printf '(proto/, crates/bus/fixtures/home/ and crates/bus/fixtures/board/).\n'
  printf 'Refresh with scripts/contract/vendor.sh; never edit these files by hand.\n\nsha256:\n'
  (cd contract && find proto fixtures -type f | sort | xargs shasum -a 256)
} > contract/SOURCE
echo "Vendored the contract from $full."
