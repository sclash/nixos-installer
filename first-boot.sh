#!/usr/bin/env bash
# Runs on first login to the freshly installed base system: clones the chosen
# dotfiles, gives this machine its own age key and secrets file, and hands over
# to their nixos/bootstrap.sh. On failure the system stays as it is, a working
# NixOS, and you get a normal shell with the next step.
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

# The dotfiles' template lists the credential names, all null, for you to fill
# in. Files already here are kept, so a re-run can't replace a key or real
# credentials.
setup_secrets() {
  local template="$TARGET/nixos/secrets/template.yaml"
  [[ -f "$template" ]] || return 0

  local dir="$HOME/.config/sops"
  local key="$dir/age/keys.txt"
  local secrets="$dir/secrets.yaml"
  local pubkey

  mkdir -p -m 700 "$dir/age"
  if [[ ! -f "$key" ]]; then
    (umask 077 && age-keygen -o "$key") || stop "could not generate an age key"
  fi
  [[ ! -f "$secrets" ]] || return 0

  pubkey=$(age-keygen -y "$key") || stop "could not read $key"
  # sops looks for a .sops.yaml from the current directory, and creating a file
  # fails if it finds one with no matching rule, so create it from its own folder.
  (cd "$dir" && umask 077 && sops encrypt --age "$pubkey" --output "$secrets" "$template") ||
    stop "could not create $secrets"
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

setup_secrets

bash "$TARGET/nixos/bootstrap.sh" || stop "nixos/bootstrap.sh reported a problem (see above)"

mkdir -p "$(dirname "$MARKER")"
touch "$MARKER"
