# Agent guide for nixos-installer

Read this before changing anything in this repo. `README.md` explains how to *use* the installer. This guide covers the rules for *changing* it.

## Purpose

A lightweight, friendly NixOS installer. You boot the stick, answer a few questions, and get a plain, working NixOS. If you chose a dotfiles repo, it hands over to that repo on first login.

It owns only the **machine layer**: partitions, encryption, swap, hibernate, hardware configuration, bootloader, hostname, timezone, keyboard layout and the user account. It writes these to `/etc/nixos`. Everything personal belongs to the dotfiles.

The goal behind both repos is one personal setup on any machine, and the two-layer split is described in the dotfiles' [`AGENTS.md`](https://github.com/sclash/dotfiles/blob/quickshell/AGENTS.md). This guide only adds what's specific to the installer.

## Hard rules

### Generic for any machine

- Never hard-code a laptop model, a table of machines, a disk size or a swap size. The installer's first real use was one particular laptop, and that must not show anywhere in the code.
- Sizes come from detection. `suggest_swap_size()` works from the detected RAM and disk, and `build_limits()` from RAM and CPU threads. Both live in `install.sh`.
- Every suggestion stays editable at the prompt, and the result is still checked. For example, `swap_fits()` refuses a swap size that leaves too little room for the system.
- Machine-specific hardware fixes come only from the optional `nixos-hardware` profile the user picks in `ask_hardware_profile()`, at a pinned revision.

### Disks

- Nothing is written until the user types the disk's name at `confirm_wipe()`. Never weaken, skip or pre-fill that confirmation outside the tests.
- `list_disks()` hides the boot stick (`boot_medium()`) and devices too small to hold a system. Keep both exclusions.
- Never run `install.sh`, or any partitioning, formatting or LVM command, on a real machine while developing. Disk work is tested only inside the QEMU VM tests, which write only to their own qcow2 images.

### Independent of the dotfiles

The installer must work with any dotfiles repo, or with none. The whole contract with a dotfiles repo is:

1. It can be cloned over HTTPS without logging in.
2. It provides `nixos/bootstrap.sh`, which `first-boot.sh` runs after cloning.
3. Optionally, it provides `nixos/secrets/template.yaml`, a list of `name: null` lines.

Don't read anything else from a dotfiles repo, or assume a particular user, repo or branch. The values in `settings.nix` are only pre-filled answers. If the contract changes, update `README.md` and both repos together.

### First boot fails soft

- `first-boot.sh` is safe to re-run. It reuses an existing clone, and never replaces an existing age key or secrets file.
- Any failure prints the exact command to retry and leaves a working plain NixOS. Never let it break the login shell or the base system.
- It marks itself done only after `bootstrap.sh` succeeds.

### Secrets

When the dotfiles provide a template, first boot generates the machine's own age key at `~/.config/sops/age/keys.txt`, and encrypts the template to it as `~/.config/sops/secrets.yaml`. Never ask for, print, log or store a real credential, and never share a key between machines.

### Keep it small

- Partition with plain `parted`, `cryptsetup`, `lvm` and `mkfs`, not disko. Partitioning only happens once, and `nixos-generate-config` reads the mounted result.
- The base `configuration.nix` written by `render_configuration_nix()` stays the minimum needed to be usable: the user, NetworkManager, git, age, sops and flakes.
- Anything personal belongs in the dotfiles, not here.

## Map of the code

| File | What it does |
|---|---|
| `install.sh` | The installer: detection, then questions, then partitioning, writing `/etc/nixos` and `nixos-install` |
| `first-boot.sh` | Runs on the first login on tty1: clones the dotfiles, sets up secrets, runs their `bootstrap.sh` |
| `iso.nix`, `flake.nix` | Build the ISO, with the installer auto-starting on tty1 |
| `settings.nix` | Build-time defaults for the dotfiles repo and branch |
| `tests/test-install.sh` | Unit tests with stubbed commands. No disks are involved |
| `tests/vm-test.sh`, `tests/vm_test.py` | Full installs in throwaway QEMU VMs |

## How to work here

- **Ask first.** Never commit, build the ISO or flash a stick without the user's permission. They approve every edit.
- **Scripted answers.** Every prompt can be answered from an `ANSWER_<NAME>` environment variable (`has_answer()` and `answer()` in `install.sh`). The tests use this. Never use it to pre-confirm a wipe outside the tests.
- **Say when a reflash is needed.** Changes to `install.sh`, `first-boot.sh`, `iso.nix` or `settings.nix` only reach new machines after the ISO is rebuilt and reflashed. Say so when proposing them. Dotfiles changes never need a reflash.
- **Explain changes in plain language,** and say what wasn't tested.

## Checks before proposing a commit

```bash
bash tests/test-install.sh
```

For changes to installing, partitioning, `/etc/nixos` output or first boot, also run the VM tests:

```bash
VM_TEST_WORK=<some-dir> tests/vm-test.sh uefi-plain
```

The scenarios are `refusals`, `interactive`, `uefi-plain`, `uefi-luks-hibernate` and `bios-luks`, and running with none runs them all. Each VM uses about 2.5 GiB of RAM and downloads a few GiB. Afterwards, nothing should still be listening on port 9418, the fixture repo's git daemon.

## Where to read more

- `README.md`: building and flashing the stick, what the installer writes, and the dotfiles contract.
- The dotfiles' [`AGENTS.md`](https://github.com/sclash/dotfiles/blob/quickshell/AGENTS.md): the shared philosophy, the dotfiles' rules, and the list of what this installer relies on there.
