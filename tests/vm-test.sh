#!/usr/bin/env bash
# Builds the ISO and runs the end-to-end VM tests. Downloads a few GiB per
# install and uses 2.5 GiB of RAM per VM. Only writes under the work directory.
# Usage: VM_TEST_WORK=DIR tests/vm-test.sh [scenario...]
set -euo pipefail

# A library path from the host session could shadow the libraries QEMU needs.
unset LD_LIBRARY_PATH

REPO=$(cd "$(dirname "$0")/.." && pwd)
FLAKE="path:$REPO"
WORK=${VM_TEST_WORK:-$(mktemp -d)}
if (($# == 0)); then
  set -- refusals interactive uefi-plain uefi-luks-hibernate bios-luks
fi

ISO_DIR=$(nix build --no-link --print-out-paths "$FLAKE#packages.x86_64-linux.iso")/iso
ISO=$(echo "$ISO_DIR"/*.iso)
OVMF=$(nix build --no-link --print-out-paths --inputs-from "$FLAKE" nixpkgs#OVMF.fd)

echo "ISO:  $ISO"
echo "Work: $WORK"
exec nix shell --inputs-from "$FLAKE" nixpkgs#qemu_kvm nixpkgs#python3 nixpkgs#git -c \
  python3 -I "$REPO/tests/vm_test.py" --iso "$ISO" --work "$WORK" \
  --uefi-code "$OVMF/FV/OVMF_CODE.fd" --uefi-vars "$OVMF/FV/OVMF_VARS.fd" "$@"
