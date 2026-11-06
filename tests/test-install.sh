#!/usr/bin/env bash
# Unit tests for the installer's decisions and first-boot handoff. Nothing here
# touches a disk: the install flow itself is tested in a VM.
# Usage: test-install.sh [install.sh] [first-boot.sh]
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
INSTALL=${1:-$HERE/../install.sh}
FIRST_BOOT=${2:-$HERE/../first-boot.sh}
PASS=0
FAIL=0

check() {
  if [[ "$2" == "$3" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $1 (expected '$3', got '$2')"
  fi
}

ok() {
  local name=$1
  shift
  if "$@"; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1))
    echo "FAIL: $name"
  fi
}

not_ok() {
  local name=$1
  shift
  if "$@"; then
    FAIL=$((FAIL + 1))
    echo "FAIL: $name"
  else PASS=$((PASS + 1)); fi
}

contains() {
  if grep -qF -- "$3" <<<"$2"; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1))
    echo "FAIL: $1 (missing '$3')"
  fi
}

lacks() {
  if grep -qF -- "$3" <<<"$2"; then
    FAIL=$((FAIL + 1))
    echo "FAIL: $1 (unexpected '$3')"
  else PASS=$((PASS + 1)); fi
}

# shellcheck source=/dev/null
source "$INSTALL"
set +e

# Usernames: required, no fixed name, dotted names allowed.
ok "plain username" validate_username alex
ok "dotted username" validate_username a.sergi
ok "underscore start" validate_username _svc
not_ok "empty username" validate_username ""
not_ok "root refused" validate_username root
not_ok "uppercase refused" validate_username Alex
not_ok "digit start refused" validate_username 1alex
not_ok "space refused" validate_username "a b"
not_ok "too long refused" validate_username "$(printf 'a%.0s' {1..33})"
not_ok "quote refused, would break Nix" validate_username 'a"b'

# Hostnames: any valid name.
ok "default hostname" validate_hostname nixos
ok "hyphen hostname" validate_hostname my-laptop
ok "single character hostname" validate_hostname x
not_ok "leading hyphen" validate_hostname -bad
not_ok "trailing hyphen" validate_hostname bad-
not_ok "dot refused" validate_hostname a.b
not_ok "empty refused" validate_hostname ""

# Partition names across disk types.
check "sata" "$(part_path /dev/sda 1)" /dev/sda1
check "virtio" "$(part_path /dev/vda 2)" /dev/vda2
check "nvme" "$(part_path /dev/nvme0n1 2)" /dev/nvme0n1p2
check "emmc" "$(part_path /dev/mmcblk0 1)" /dev/mmcblk0p1

# Build limits follow the machine, and always stay usable.
check "8 GiB, 8 threads" "$(build_limits 8 8)" "2 4"
check "32 GiB, 16 threads" "$(build_limits 32 16)" "8 2"
check "tiny machine" "$(build_limits 2 2)" "1 2"
check "more RAM than threads" "$(build_limits 64 4)" "4 1"

# Swap must leave room for the system.
ok "fits" swap_fits 120 16
not_ok "too big" swap_fits 30 16
ok "exactly fits" swap_fits 30 9
not_ok "one over" swap_fits 30 10

# The suggestion follows the detected machine.
check "RAM plus 10%" "$(suggest_swap_size 32 500)" 35
check "at least 1 GiB of margin" "$(suggest_swap_size 4 500)" 5
check "capped so the system still fits" "$(suggest_swap_size 32 40)" 19
check "no room at all" "$(suggest_swap_size 32 21)" 0
check "never negative" "$(suggest_swap_size 32 10)" 0
ok "a capped suggestion fits" swap_fits 40 "$(suggest_swap_size 32 40)"

# Whatever the policy, every result must be a usable, editable number.
for machine in "4 30" "8 60" "16 120" "32 500" "64 1000" "128 256"; do
  read -r ram disk <<<"$machine"
  got=$(suggest_swap_size "$ram" "$disk" 2>/dev/null)
  ok "suggestion for ${ram} GiB RAM, ${disk} GiB disk is a positive number" \
    bash -c '[[ "$1" =~ ^[0-9]+$ ]] && (($1 > 0))' _ "$got"
done

# Only disks that can hold a system are offered, and never the installer's own.
findmnt() { echo /dev/sdb1; }
lsblk() {
  if [[ "$*" == *PKNAME* ]]; then
    echo /dev/sdb
    return
  fi
  printf '%s\n' \
    '/dev/fd0 4096 disk' \
    '/dev/sr0 1500000000 rom QEMU DVD' \
    '/dev/sda 64424509440 disk' \
    '/dev/sdb 128849018880 disk Installer Stick' \
    '/dev/sdc 2147483648 disk Card Reader' \
    '/dev/nvme0n1 512110190592 disk Fast SSD'
}
DISKS=$(list_disks)
check "offered disks" "$(cut -d' ' -f1 <<<"$DISKS" | tr '\n' ' ')" "/dev/sda /dev/nvme0n1 "
contains "shows size and model" "$DISKS" "/dev/nvme0n1  476 GiB  Fast SSD"
contains "names a missing model" "$DISKS" "/dev/sda  60 GiB  unknown model"
unset -f findmnt lsblk

# Prompts must survive `set -e`, as they run in the real installer.
prompt_ok() {
  local name=$1
  shift
  if (set -e; "$@") >/dev/null 2>&1; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1))
    echo "FAIL: $name"
  fi
}
prompt_refused() {
  local name=$1
  shift
  if (set -e; "$@") >/dev/null 2>&1; then
    FAIL=$((FAIL + 1))
    echo "FAIL: $name"
  else PASS=$((PASS + 1)); fi
}

ANSWER_USERNAME=alex ANSWER_PASSWORD=secret prompt_ok "ask_user accepts good answers" ask_user
ANSWER_USERNAME=root ANSWER_PASSWORD=secret prompt_refused "ask_user refuses root" ask_user
ANSWER_USERNAME=alex ANSWER_PASSWORD="" prompt_refused "ask_user refuses an empty password" ask_user
ANSWER_ENCRYPT=yes ANSWER_PASSPHRASE=secret prompt_ok "ask_encryption accepts a passphrase" ask_encryption
ANSWER_ENCRYPT=yes ANSWER_PASSPHRASE="" prompt_refused "ask_encryption refuses an empty passphrase" ask_encryption
ANSWER_ENCRYPT=no prompt_ok "ask_encryption accepts no" ask_encryption
ANSWER_HOSTNAME="" prompt_ok "ask_hostname falls back" ask_hostname
ANSWER_HOSTNAME=-bad prompt_refused "ask_hostname refuses a bad name" ask_hostname
RAM_GIB=8 DISK_GIB=60 ANSWER_HIBERNATE=no prompt_ok "ask_hibernate accepts no" ask_hibernate
RAM_GIB=8 DISK_GIB=60 ANSWER_HIBERNATE=yes ANSWER_SWAP_GIB="" prompt_ok "ask_hibernate takes the suggestion" ask_hibernate
RAM_GIB=8 DISK_GIB=60 ANSWER_HIBERNATE=yes ANSWER_SWAP_GIB=999 prompt_refused "ask_hibernate refuses too much" ask_hibernate

set_machine() {
  HOSTNAME_CHOICE=my-laptop TIMEZONE=Europe/Rome KEYMAP=it JOBS=2 CORES=4
  STATE_VERSION=26.05 FIRMWARE=uefi BOOT_DEVICE=/dev/sda ENCRYPT=no RESUME_UUID=""
  PROFILE="" HARDWARE_REV=abc123 USERNAME=a.sergi DOTFILES_REPO="" DOTFILES_BRANCH=""
  LUKS_UUID=""
}

# machine.nix: plain UEFI.
set_machine
M=$(render_machine_nix)
contains "hostname" "$M" 'networking.hostName = "my-laptop";'
contains "timezone" "$M" 'time.timeZone = "Europe/Rome";'
contains "keymap" "$M" 'console.keyMap = "it";'
contains "zram always on" "$M" 'zramSwap.enable = true;'
contains "build limits" "$M" 'nix.settings.max-jobs = 2;'
contains "state version" "$M" 'system.stateVersion = "26.05";'
contains "uefi loader" "$M" 'boot.loader.systemd-boot.enable = true;'
lacks "no grub on uefi" "$M" 'grub'
lacks "no resume without hibernate" "$M" 'resumeDevice'
lacks "no early console without encryption" "$M" 'earlySetup'
lacks "no profile import when none" "$M" 'nixos-hardware'
lacks "no unlock without encryption" "$M" 'luks'

# machine.nix: BIOS, encrypted, hibernate, hardware profile.
FIRMWARE=bios ENCRYPT=yes RESUME_UUID=1234-abcd PROFILE=some-laptop-model LUKS_UUID=5678-efgh
M=$(render_machine_nix)
contains "unlocks the encrypted disk at boot" "$M" 'boot.initrd.luks.devices."cryptroot".device = "/dev/disk/by-uuid/5678-efgh";'
contains "grub device" "$M" 'boot.loader.grub.device = "/dev/sda";'
lacks "no systemd-boot on bios" "$M" 'systemd-boot'
contains "resume device" "$M" 'boot.resumeDevice = "/dev/disk/by-uuid/1234-abcd";'
contains "layout before passphrase" "$M" 'console.earlySetup = true;'
contains "pinned profile" "$M" '(builtins.getFlake "github:NixOS/nixos-hardware/abc123").nixosModules."some-laptop-model"'

# configuration.nix.
set_machine
C=$(render_configuration_nix)
contains "dotted user quoted" "$C" 'users.users."a.sergi" = {'
contains "sudo for the user" "$C" '"wheel"'
contains "git for bootstrap" "$C" 'pkgs.git'
contains "flakes for bootstrap" "$C" '"flakes"'
lacks "no handoff without dotfiles" "$C" 'first-boot'

DOTFILES_REPO=https://example.org/dots DOTFILES_BRANCH=main
C=$(render_configuration_nix)
contains "handoff on first login" "$C" 'bash /etc/nixos/first-boot.sh'
contains "handoff runs once" "$C" 'first-boot-done'

# Generated files are valid Nix, when nix is around to check.
if command -v nix-instantiate >/dev/null; then
  ok "machine.nix parses" nix-instantiate --parse -E "$(set_machine; FIRMWARE=bios ENCRYPT=yes RESUME_UUID=u PROFILE=p; render_machine_nix)" >/dev/null 2>&1
  ok "configuration.nix parses" nix-instantiate --parse -E "$C" >/dev/null 2>&1
fi

# Nothing machine-specific in the installer itself.
SOURCE=$(<"$INSTALL")
lacks "no model names" "$SOURCE" 'EliteBook'
lacks "no fixed home" "$SOURCE" '/home/asergi'

# --- first-boot.sh, with stubbed commands ------------------------------------

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

first_boot_setup() {
  T=$(mktemp -d -p "$ROOT")
  H="$T/home"
  mkdir -p "$H" "$T/bin"
  printf 'repo=https://example.org/dots\nbranch=main\n' >"$T/source"
  LOG="$T/calls.log"
  touch "$LOG"
  cat >"$T/bin/git" <<'S'
#!/usr/bin/env bash
echo "git $*" >>"$CALLS"
[[ "${GIT_EXIT:-0}" == 0 ]] || exit "$GIT_EXIT"
target="${!#}"
mkdir -p "$target/.git" "$target/nixos"
[[ "${NO_BOOTSTRAP:-}" == 1 ]] || printf 'echo bootstrap-ran >>"$CALLS"\nexit ${BOOTSTRAP_EXIT:-0}\n' >"$target/nixos/bootstrap.sh"
S
  cat >"$T/bin/nm-online" <<'S'
#!/usr/bin/env bash
echo "nm-online" >>"$CALLS"
S
  chmod +x "$T"/bin/*
}

first_boot() {
  OUT=$(env HOME="$H" PATH="$T/bin:$PATH" CALLS="$LOG" DOTFILES_SOURCE_FILE="$T/source" "$@" \
    bash "$FIRST_BOOT" 2>&1 </dev/null)
  RC=$?
}

first_boot_setup
first_boot
check "first boot succeeds" "$RC" 0
contains "clones the chosen branch" "$(<"$LOG")" "git clone --branch main https://example.org/dots $H/dotfiles"
contains "runs bootstrap" "$(<"$LOG")" "bootstrap-ran"
check "marks done" "$([[ -e "$H/.local/state/nixos-installer/first-boot-done" ]] && echo yes || echo no)" yes

# Re-running reuses the clone.
: >"$LOG"
first_boot
check "re-run succeeds" "$RC" 0
lacks "re-run doesn't clone again" "$(<"$LOG")" "git clone"
contains "re-run runs bootstrap" "$(<"$LOG")" "bootstrap-ran"

first_boot_setup
first_boot GIT_EXIT=1
check "clone failure exit" "$RC" 1
contains "clone failure says system is fine" "$OUT" "still plain NixOS"
contains "clone failure gives next step" "$OUT" "bash /etc/nixos/first-boot.sh"
check "clone failure not marked done" "$([[ -e "$H/.local/state/nixos-installer/first-boot-done" ]] && echo yes || echo no)" no

first_boot_setup
first_boot BOOTSTRAP_EXIT=2
check "bootstrap failure exit" "$RC" 1
contains "bootstrap failure explained" "$OUT" "reported a problem"
check "bootstrap failure not marked done" "$([[ -e "$H/.local/state/nixos-installer/first-boot-done" ]] && echo yes || echo no)" no

first_boot_setup
first_boot NO_BOOTSTRAP=1
check "repo without bootstrap exit" "$RC" 1
contains "repo without bootstrap explained" "$OUT" "has no nixos/bootstrap.sh"

if ((FAIL)); then
  echo "FAILED: $FAIL failed, $PASS passed"
  exit 1
fi
echo "OK ($PASS installer tests)"
