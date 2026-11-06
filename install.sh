#!/usr/bin/env bash
# A small, friendly NixOS installer: asks a few questions, partitions the chosen
# disk, and installs a plain NixOS. Nothing here is specific to one machine:
# sizes come from what is detected at install time.
#
# Runs as root on the installer ISO. Nothing is touched until the final
# confirmation, so quitting before then is always safe.
#
# ANSWER_<NAME> environment variables answer prompts for automated testing. A
# bad automated answer stops the installer instead of asking again. The tests
# also use ANSWER_EXTRA_MACHINE_NIX, to add a serial console to machine.nix.
set -euo pipefail

DATA_DIR=${INSTALLER_DATA_DIR:-/etc/nixos-installer}
MNT=/mnt
LUKS_NAME=cryptroot
VG_NAME=nixos
BOOT_GIB=1
# Enough for plain NixOS. Dotfiles may need far more. If they don't fit, their
# first-boot rebuild fails and the base system keeps working.
MIN_ROOT_GIB=20

# --- Decisions that don't touch the system (unit tested) ---------------------

validate_username() {
  local name=$1
  [[ "$name" =~ ^[a-z_][a-z0-9_.-]{0,31}$ ]] || return 1
  [[ "$name" != root && "$name" != nobody ]]
}

# Same rule as the networking.hostName option, without the underscore DNS rejects.
validate_hostname() {
  [[ "$1" =~ ^[[:alnum:]]([[:alnum:]-]{0,61}[[:alnum:]])?$ ]]
}

# /dev/sda + 1 -> /dev/sda1, but /dev/nvme0n1 + 1 -> /dev/nvme0n1p1.
part_path() {
  local disk=$1 number=$2
  if [[ "$disk" =~ [0-9]$ ]]; then
    printf '%sp%s\n' "$disk" "$number"
  else
    printf '%s%s\n' "$disk" "$number"
  fi
}

# Prints "max-jobs cores". Each parallel build gets about 4 GiB of RAM, which
# avoids out-of-memory failures, and the CPU threads are shared between them.
build_limits() {
  local ram_gib=$1 threads=$2 jobs cores
  jobs=$((ram_gib / 4))
  ((jobs >= 1)) || jobs=1
  ((jobs <= threads)) || jobs=$threads
  cores=$((threads / jobs))
  printf '%s %s\n' "$jobs" "$cores"
}

# Prints the hibernate swap size to suggest, in whole GiB. It's only a
# suggestion: the user can edit it, and swap_fits still checks the result.
#
# A hibernate image holds whatever is in RAM, compressed. Too small and
# hibernating can fail when memory is full; too large and it wastes disk.
suggest_swap_size() {
  local ram_gib=$1 disk_gib=$2 margin wanted room
  # RAM plus 10% (at least 1 GiB), so hibernating works even with memory full.
  margin=$((ram_gib / 10))
  ((margin >= 1)) || margin=1
  wanted=$((ram_gib + margin))
  # On a small disk, the system's minimum space comes first. 0 means no room.
  room=$((disk_gib - BOOT_GIB - MIN_ROOT_GIB))
  ((wanted <= room)) || wanted=$room
  ((wanted >= 0)) || wanted=0
  printf '%s\n' "$wanted"
}

swap_fits() {
  local disk_gib=$1 swap_gib=$2
  ((disk_gib - BOOT_GIB - swap_gib >= MIN_ROOT_GIB))
}

render_machine_nix() {
  local hardware_import="" boot_lines resume_line="" early_line=""
  if [[ -n "$PROFILE" ]]; then
    hardware_import="  imports = [ (builtins.getFlake \"github:NixOS/nixos-hardware/$HARDWARE_REV\").nixosModules.\"$PROFILE\" ];"$'\n\n'
  fi
  if [[ "$FIRMWARE" == uefi ]]; then
    boot_lines='  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;'
  else
    boot_lines="  boot.loader.grub.enable = true;
  boot.loader.grub.device = \"$BOOT_DEVICE\";"
  fi
  if [[ -n "$RESUME_UUID" ]]; then
    resume_line="  boot.resumeDevice = \"/dev/disk/by-uuid/$RESUME_UUID\";"$'\n'
  fi
  if [[ "$ENCRYPT" == yes ]]; then
    # nixos-generate-config can't see LUKS underneath LVM, so this says it here.
    # earlySetup loads the keyboard layout before the passphrase is asked for.
    early_line="  boot.initrd.luks.devices.\"$LUKS_NAME\".device = \"/dev/disk/by-uuid/$LUKS_UUID\";"$'\n'
    early_line+="  console.earlySetup = true;"$'\n'
  fi
  cat <<EOF
# This machine's settings, written by nixos-installer. Edit freely: your
# dotfiles read this file and never set any of these themselves.
{
${hardware_import}  networking.hostName = "$HOSTNAME_CHOICE";
  time.timeZone = "$TIMEZONE";
  console.keyMap = "$KEYMAP";
${early_line}  zramSwap.enable = true;
${resume_line}  nix.settings.max-jobs = $JOBS;
  nix.settings.cores = $CORES;
$boot_lines
  system.stateVersion = "$STATE_VERSION";
${ANSWER_EXTRA_MACHINE_NIX:-}
}
EOF
}

render_configuration_nix() {
  local handoff=""
  if [[ -n "$DOTFILES_REPO" ]]; then
    handoff=$(
      cat <<'NIX'

  # Set up your dotfiles on first login. They take over from this file.
  programs.bash.loginShellInit = ''
    if [ "$(tty)" = /dev/tty1 ] && [ ! -e "$HOME/.local/state/nixos-installer/first-boot-done" ]; then
      bash /etc/nixos/first-boot.sh
    fi
  '';
NIX
    )
  fi
  cat <<EOF
# A plain, usable NixOS, written by nixos-installer.
{ pkgs, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ./machine.nix
  ];

  users.users."$USERNAME" = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "networkmanager"
    ];
  };

  networking.networkmanager.enable = true;
  boot.kernelPackages = pkgs.linuxPackages_latest;
  environment.systemPackages = [ pkgs.git ];
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
$handoff
}
EOF
}

# --- Talking to the user -----------------------------------------------------

has_answer() {
  local var="ANSWER_$1"
  [[ -n "${!var+x}" ]]
}

answer() {
  local var="ANSWER_$1"
  printf '%s\n' "${!var}"
}

ask_input() {
  local name=$1 header=$2 value=${3:-}
  if has_answer "$name"; then
    answer "$name"
  else
    gum input --header "$header" --value "$value" --width 70
  fi
}

ask_secret() {
  local name=$1 header=$2
  if has_answer "$name"; then
    answer "$name"
  else
    gum input --password --header "$header" --width 70
  fi
}

ask_yes_no() {
  local name=$1 question=$2
  if has_answer "$name"; then
    [[ "$(answer "$name")" == yes ]]
  else
    gum confirm --default=false "$question"
  fi
}

# Options come from stdin.
ask_filter() {
  local name=$1 header=$2
  if has_answer "$name"; then
    answer "$name"
  else
    gum filter --limit 1 --header "$header" --height 15
  fi
}

ask_choose() {
  local name=$1 header=$2
  if has_answer "$name"; then
    answer "$name"
  else
    gum choose --header "$header"
  fi
}

reject() {
  local name=$1 message=$2
  echo "$message" >&2
  if has_answer "$name"; then
    exit 1
  fi
}

heading() {
  if command -v gum >/dev/null; then
    gum style --bold --foreground 212 "$*"
  else
    echo "== $*"
  fi
}

# --- Questions ---------------------------------------------------------------

detect_machine() {
  RAM_GIB=$(awk '/^MemTotal:/ { print int(($2 + 1048575) / 1048576) }' /proc/meminfo)
  THREADS=$(nproc)
  if [[ -d /sys/firmware/efi ]]; then
    FIRMWARE=uefi
  else
    FIRMWARE=bios
  fi
  read -r JOBS CORES < <(build_limits "$RAM_GIB" "$THREADS")
  STATE_VERSION=$(nixos-version | cut -c1-5)
}

ensure_network() {
  until curl -fsS --max-time 8 https://cache.nixos.org/nix-cache-info >/dev/null 2>&1; do
    if has_answer NETWORK; then
      echo "No network." >&2
      exit 1
    fi
    echo "No internet connection yet. Installing needs one to download packages."
    gum confirm "Open the network settings?" || exit 1
    nmtui
  done
}

# The disk the installer itself booted from, so it can't be offered as a target.
boot_medium() {
  local source
  source=$(findmnt -no SOURCE /iso 2>/dev/null) || return 0
  lsblk -npo PKNAME "$source" 2>/dev/null | head -n1 || true
}

list_disks() {
  local medium name size type model gib
  medium=$(boot_medium)
  lsblk -dnpb -o NAME,SIZE,TYPE,MODEL | while read -r name size type model; do
    [[ "$type" == disk && "$name" != "$medium" ]] || continue
    gib=$((size / 1073741824))
    # Hides what can't hold a system, such as floppy drives and card readers.
    ((gib >= BOOT_GIB + MIN_ROOT_GIB)) || continue
    printf '%s  %s GiB  %s\n' "$name" "$gib" "${model:-unknown model}"
  done
}

ask_keymap() {
  KEYMAP=$(ask_filter KEYMAP "Keyboard layout (type to search)" <"$DATA_DIR/keymaps")
  loadkeys "$KEYMAP" >/dev/null 2>&1 || true
}

ask_disk() {
  local disks choice
  disks=$(list_disks)
  [[ -n "$disks" ]] || {
    echo "No disk of at least $((BOOT_GIB + MIN_ROOT_GIB)) GiB found to install on." >&2
    exit 1
  }
  while :; do
    choice=$(ask_choose DISK "Which disk should NixOS use? ALL its data will be erased." <<<"$disks")
    DISK=${choice%% *}
    if [[ ! -b "$DISK" ]]; then
      reject DISK "$DISK is not a disk."
      continue
    fi
    DISK_GIB=$(($(lsblk -dnb -o SIZE "$DISK") / 1073741824))
    if ((DISK_GIB < BOOT_GIB + MIN_ROOT_GIB)); then
      reject DISK "$DISK is ${DISK_GIB} GiB, and NixOS needs at least $((BOOT_GIB + MIN_ROOT_GIB)) GiB."
      continue
    fi
    return
  done
}

ask_encryption() {
  ENCRYPT=no
  PASSPHRASE=""
  ask_yes_no ENCRYPT "Encrypt the disk? You'll type a passphrase at every boot." || return 0
  ENCRYPT=yes
  local again
  while :; do
    PASSPHRASE=$(ask_secret PASSPHRASE "Disk passphrase")
    again=$(ask_secret PASSPHRASE "Disk passphrase, once more")
    if [[ -z "$PASSPHRASE" ]]; then
      reject PASSPHRASE "The passphrase can't be empty."
    elif [[ "$PASSPHRASE" != "$again" ]]; then
      reject PASSPHRASE "Those didn't match."
    else
      return 0
    fi
  done
}

ask_hibernate() {
  SWAP_GIB=0
  ask_yes_no HIBERNATE "Enable hibernate? It sets aside disk space for a copy of your RAM." || return 0
  local suggestion value
  suggestion=$(suggest_swap_size "$RAM_GIB" "$DISK_GIB")
  while :; do
    value=$(ask_input SWAP_GIB "Hibernate swap in GiB, for ${RAM_GIB} GiB of RAM. 0 turns hibernate off." "$suggestion")
    value=${value:-$suggestion}
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
      reject SWAP_GIB "Please enter a whole number."
    elif ! swap_fits "$DISK_GIB" "$value"; then
      reject SWAP_GIB "${value} GiB leaves too little room: this ${DISK_GIB} GiB disk needs ${MIN_ROOT_GIB} GiB for the system."
    else
      SWAP_GIB=$value
      return
    fi
  done
}

ask_hostname() {
  while :; do
    HOSTNAME_CHOICE=$(ask_input HOSTNAME "Name this machine (Enter keeps nixos)" nixos)
    HOSTNAME_CHOICE=${HOSTNAME_CHOICE:-nixos}
    validate_hostname "$HOSTNAME_CHOICE" && return
    reject HOSTNAME "Use letters, numbers and hyphens, not starting or ending with a hyphen."
  done
}

ask_user() {
  local again
  while :; do
    USERNAME=$(ask_input USERNAME "Your username")
    validate_username "$USERNAME" && break
    reject USERNAME "Start with a lowercase letter or _, then lowercase letters, digits, _ . or -. It can't be root."
  done
  while :; do
    PASSWORD=$(ask_secret PASSWORD "Your password")
    again=$(ask_secret PASSWORD "Your password, once more")
    if [[ -z "$PASSWORD" ]]; then
      reject PASSWORD "The password can't be empty."
    elif [[ "$PASSWORD" != "$again" ]]; then
      reject PASSWORD "Those didn't match."
    else
      return 0
    fi
  done
}

ask_timezone() {
  TIMEZONE=$(ask_filter TIMEZONE "Timezone (type to search)" < <(timedatectl list-timezones))
}

ask_hardware_profile() {
  local model choice
  HARDWARE_REV=$(<"$DATA_DIR/nixos-hardware-rev")
  model=$(cat /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name 2>/dev/null | tr '\n' ' ' || true)
  choice=$(ask_filter PROFILE "Optional hardware fixes for: ${model:-this machine}. Type to search, or pick none." \
    < <(echo none; cat "$DATA_DIR/hardware-profiles"))
  PROFILE=""
  [[ "$choice" == none ]] || PROFILE=$choice
}

ask_dotfiles() {
  while :; do
    DOTFILES_REPO=$(ask_input DOTFILES_REPO "Dotfiles repo to set up after install (empty: plain NixOS)" "$(<"$DATA_DIR/dotfiles-repo")")
    DOTFILES_BRANCH=""
    [[ -n "$DOTFILES_REPO" ]] || return 0
    DOTFILES_BRANCH=$(ask_input DOTFILES_BRANCH "Dotfiles branch" "$(<"$DATA_DIR/dotfiles-branch")")
    # Checked now, while nothing has been erased. No credentials on purpose:
    # first boot clones without any.
    if GIT_TERMINAL_PROMPT=0 git ls-remote --exit-code "$DOTFILES_REPO" "refs/heads/$DOTFILES_BRANCH" >/dev/null 2>&1; then
      return
    fi
    reject DOTFILES_REPO "Can't read branch $DOTFILES_BRANCH of $DOTFILES_REPO without logging in."
  done
}

confirm_wipe() {
  heading "Ready to install"
  cat <<EOF
  Disk:       $DISK (${DISK_GIB} GiB)
  Encryption: $ENCRYPT
  Hibernate:  $( ((SWAP_GIB > 0)) && echo "yes, ${SWAP_GIB} GiB swap" || echo no) (zram is always on)
  Hostname:   $HOSTNAME_CHOICE
  User:       $USERNAME
  Timezone:   $TIMEZONE
  Keyboard:   $KEYMAP
  Hardware:   ${PROFILE:-none}
  Firmware:   $FIRMWARE
  Dotfiles:   ${DOTFILES_REPO:-none} ${DOTFILES_BRANCH}

Currently on $DISK:
EOF
  lsblk -no NAME,SIZE,FSTYPE,LABEL "$DISK" | sed 's/^/  /'
  echo
  local typed
  typed=$(ask_input CONFIRM "Type $DISK to ERASE it and install. Anything else cancels.")
  if [[ "$typed" != "$DISK" ]]; then
    echo "Cancelled. Nothing was changed."
    exit 1
  fi
}

# --- Doing it ----------------------------------------------------------------

# Clears what an earlier attempt left active, so the installer can simply be re-run.
release_disk() {
  local part
  swapoff -a 2>/dev/null || true
  umount -R "$MNT" 2>/dev/null || true
  vgchange -an "$VG_NAME" >/dev/null 2>&1 || true
  cryptsetup close "$LUKS_NAME" 2>/dev/null || true
  while read -r part; do
    [[ "$part" == "$DISK" ]] || wipefs -afq "$part" 2>/dev/null || true
  done < <(lsblk -lnpo NAME "$DISK")
  wipefs -afq "$DISK"
}

partition_disk() {
  local root_start
  parted -s "$DISK" mklabel gpt
  if [[ "$FIRMWARE" == uefi ]]; then
    root_start=1025MiB
    parted -s "$DISK" mkpart ESP fat32 1MiB "$root_start" set 1 esp on mkpart root "$root_start" 100%
    BOOT_PART=$(part_path "$DISK" 1)
    ROOT_PART=$(part_path "$DISK" 2)
  else
    root_start=1026MiB
    parted -s "$DISK" mkpart biosboot 1MiB 2MiB set 1 bios_grub on \
      mkpart boot ext4 2MiB "$root_start" mkpart root "$root_start" 100%
    BOOT_PART=$(part_path "$DISK" 2)
    ROOT_PART=$(part_path "$DISK" 3)
  fi
  udevadm settle
}

create_volumes() {
  local physical=$ROOT_PART
  if [[ "$ENCRYPT" == yes ]]; then
    printf '%s' "$PASSPHRASE" | cryptsetup luksFormat --batch-mode --type luks2 --key-file=- "$ROOT_PART"
    printf '%s' "$PASSPHRASE" | cryptsetup open --key-file=- "$ROOT_PART" "$LUKS_NAME"
    LUKS_UUID=$(cryptsetup luksUUID "$ROOT_PART")
    physical=/dev/mapper/$LUKS_NAME
  fi
  pvcreate -ff --yes "$physical" >/dev/null
  vgcreate --yes "$VG_NAME" "$physical" >/dev/null
  RESUME_UUID=""
  if ((SWAP_GIB > 0)); then
    lvcreate --yes -L "${SWAP_GIB}G" -n swap "$VG_NAME" >/dev/null
    mkswap -q "/dev/$VG_NAME/swap"
    RESUME_UUID=$(blkid -s UUID -o value "/dev/$VG_NAME/swap")
  fi
  lvcreate --yes -l 100%FREE -n root "$VG_NAME" >/dev/null
}

format_and_mount() {
  mkfs.ext4 -q -F -L nixos "/dev/$VG_NAME/root"
  mount "/dev/$VG_NAME/root" "$MNT"
  mkdir -p "$MNT/boot"
  if [[ "$FIRMWARE" == uefi ]]; then
    mkfs.vfat -F 32 -n BOOT "$BOOT_PART" >/dev/null
    mount -o umask=0077 "$BOOT_PART" "$MNT/boot"
  else
    mkfs.ext4 -q -F -L boot "$BOOT_PART"
    mount "$BOOT_PART" "$MNT/boot"
  fi
  if ((SWAP_GIB > 0)); then
    # Active now so nixos-generate-config records it.
    swapon "/dev/$VG_NAME/swap"
  fi
}

# GRUB is installed to the whole disk, so prefer a name that survives reboots.
stable_disk_path() {
  local link
  for link in /dev/disk/by-id/*; do
    [[ -e "$link" && "$link" != *-part* && "$(readlink -f "$link")" == "$DISK" ]] && {
      printf '%s\n' "$link"
      return
    }
  done
  printf '%s\n' "$DISK"
}

write_configuration() {
  BOOT_DEVICE=$(stable_disk_path)
  nixos-generate-config --root "$MNT"
  render_machine_nix >"$MNT/etc/nixos/machine.nix"
  render_configuration_nix >"$MNT/etc/nixos/configuration.nix"
  if [[ -n "$DOTFILES_REPO" ]]; then
    printf 'repo=%s\nbranch=%s\n' "$DOTFILES_REPO" "$DOTFILES_BRANCH" >"$MNT/etc/nixos/dotfiles-source"
    install -m 755 "$DATA_DIR/first-boot.sh" "$MNT/etc/nixos/first-boot.sh"
  fi
}

# So the first boot can reach the network without asking again.
copy_network_profiles() {
  local dir=/etc/NetworkManager/system-connections
  compgen -G "$dir/*" >/dev/null || return 0
  mkdir -p "$MNT$dir"
  install -m 600 "$dir"/* "$MNT$dir/"
}

install_system() {
  nixos-install --no-root-passwd --root "$MNT"
  printf '%s:%s\n' "$USERNAME" "$PASSWORD" | nixos-enter --root "$MNT" -c chpasswd
}

main() {
  if ((EUID != 0)); then
    exec sudo "$0" "$@"
  fi
  # Never stop without saying why.
  set -E
  trap 'echo "installer: failed at line $LINENO: $BASH_COMMAND" >&2' ERR
  heading "NixOS installer"
  echo "Nothing is changed until you confirm at the end. Ctrl-C quits."
  echo
  detect_machine
  ask_keymap
  ensure_network
  ask_disk
  ask_encryption
  ask_hibernate
  ask_hostname
  ask_user
  ask_timezone
  ask_hardware_profile
  ask_dotfiles
  confirm_wipe

  heading "Preparing $DISK"
  release_disk
  partition_disk
  create_volumes
  format_and_mount

  heading "Installing NixOS (this downloads a lot, and can take a while)"
  write_configuration
  copy_network_profiles
  install_system

  heading "Done"
  echo "Take out the USB stick and reboot."
  if [[ -n "$DOTFILES_REPO" ]]; then
    echo "After you log in, your dotfiles are set up automatically."
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
