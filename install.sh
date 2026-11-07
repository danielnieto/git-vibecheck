#!/usr/bin/env bash
#
# Link bin/git-vibecheck into ~/.local/bin (or $GIT_VIBECHECK_BIN_DIR) so `git vibecheck`
# works in any terminal. Refuses to shadow or overwrite another git-vibecheck.

set -euo pipefail

src="$(cd "$(dirname "$0")" && pwd)/bin/git-vibecheck"
dir=${GIT_VIBECHECK_BIN_DIR:-$HOME/.local/bin}
dest="$dir/git-vibecheck"

if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]; then
  echo "git-vibecheck is already linked at $dest"
else
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    echo "error: $dest already exists and is not this git-vibecheck; not overwriting it." >&2
    echo "Remove it, or set GIT_VIBECHECK_BIN_DIR to install somewhere else." >&2
    exit 1
  fi
  other=$(command -v git-vibecheck || true)
  if [ -n "$other" ]; then
    echo "error: another git-vibecheck is already on your PATH at $other; not installing over it." >&2
    exit 1
  fi
  mkdir -p "$dir"
  ln -s "$src" "$dest"
  echo "linked $dest -> $src"
fi

case ":$PATH:" in
*":$dir:"*) ;;
*) echo "warning: $dir is not on your PATH; add it to use \`git vibecheck\` in a terminal." >&2 ;;
esac
