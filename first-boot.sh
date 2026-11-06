#!/usr/bin/env bash
# Runs on first login to the freshly installed base system: clones the chosen
# dotfiles and hands over to their nixos/bootstrap.sh. On failure the system
# stays as it is, a working NixOS, and you get a normal shell with the next step.
set -uo pipefail

SOURCE_FILE=${DOTFILES_SOURCE_FILE:-/etc/nixos/dotfiles-source}
MARKER="$HOME/.local/state/nixos-installer/first-boot-done"
TARGET="$HOME/dotfiles"
RERUN="bash /etc/nixos/first-boot.sh"

stop() {
  echo
  echo "Dotfiles setup stopped: $*"
  echo "Your system is fine and still plain NixOS. Fix the problem, then run:"
  echo "  $RERUN"
  exit 1
}

repo=""
branch=""
while IFS='=' read -r key value; do
  case "$key" in
    repo) repo=$value ;;
    branch) branch=$value ;;
  esac
done <"$SOURCE_FILE"
[[ -n "$repo" && -n "$branch" ]] || stop "$SOURCE_FILE needs repo= and branch= lines"

# A saved Wi-Fi network can take a few seconds to come up after login.
command -v nm-online >/dev/null && nm-online -q -t 30

if [[ ! -d "$TARGET/.git" ]]; then
  GIT_TERMINAL_PROMPT=0 git clone --branch "$branch" "$repo" "$TARGET" ||
    stop "could not clone $repo (branch $branch). Check the network with nmtui."
fi

[[ -f "$TARGET/nixos/bootstrap.sh" ]] || stop "$repo has no nixos/bootstrap.sh"

bash "$TARGET/nixos/bootstrap.sh" || stop "nixos/bootstrap.sh reported a problem (see above)"

mkdir -p "$(dirname "$MARKER")"
touch "$MARKER"
