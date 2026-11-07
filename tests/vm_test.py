#!/usr/bin/env python3
"""Runs the installer end to end in throwaway QEMU VMs, driven over the serial
console. Only ever writes to qcow2 images and a fixture repo in the work
directory, never to a real disk.

Usage: vm_test.py --iso FILE --work DIR --uefi-code FILE --uefi-vars FILE SCENARIO...
"""
import argparse
import os
import re
import select
import shlex
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

ANSI = re.compile(r"\x1b(\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b]*(\x07|\x1b\\)|[()*+].|[=>@-Z^_\\])")
FIXTURE_URL = "git://10.0.2.2/fixture"
SERIAL_LINE = 'boot.kernelParams = [ "console=ttyS0,115200" ];'
PASSWORD = "user-pass-1"
PASSPHRASE = "disk-pass-1"
RAM_MIB = 2560


class TestFailure(Exception):
    pass


class VM:
    """A QEMU process with its serial console on stdin and stdout."""

    def __init__(self, cfg, args, log, cdrom=False):
        cmd = [
            "qemu-system-x86_64", "-enable-kvm", "-cpu", "host", "-smp", "4",
            "-m", str(cfg.get("ram", RAM_MIB)), "-display", "none", "-serial", "stdio",
            "-monitor", "none", "-no-reboot",
            "-nic", "user,model=virtio-net-pci",
        ]
        if cfg["firmware"] == "uefi":
            cmd += [
                "-drive", f"if=pflash,format=raw,readonly=on,file={args.uefi_code}",
                "-drive", f"if=pflash,format=raw,file={cfg['vars']}",
            ]
        image = cfg["image"]
        if cfg["bus"] == "virtio":
            cmd += ["-drive", f"file={image},if=virtio,format=qcow2"]
        elif cfg["bus"] == "nvme":
            cmd += ["-drive", f"id=d0,file={image},if=none,format=qcow2",
                    "-device", "nvme,drive=d0,serial=vmtest0"]
        elif cfg["bus"] == "sata":
            cmd += ["-drive", f"id=d0,file={image},if=none,format=qcow2",
                    "-device", "ahci,id=sata0", "-device", "ide-hd,drive=d0,bus=sata0.0"]
        if cdrom:
            cmd += ["-cdrom", args.iso, "-boot", "order=d"]
        self.log = log
        self.buf = ""
        self.pos = 0
        self.pending = ""
        self.proc = subprocess.Popen(
            cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, bufsize=0)
        assert self.proc.stdin and self.proc.stdout
        self.stdin = self.proc.stdin
        self.stdout = self.proc.stdout

    def _pump(self, wait):
        ready, _, _ = select.select([self.stdout], [], [], wait)
        if not ready:
            return True
        data = os.read(self.stdout.fileno(), 65536)
        if not data:
            return False
        text = data.decode("utf-8", "replace")
        self.log.write(text)
        self.log.flush()
        # Serial output arrives a few bytes at a time, so an escape sequence can
        # be cut in half. Hold it back until the rest arrives.
        text = self.pending + text
        self.pending = ""
        start = text.rfind("\x1b")
        if start != -1 and not ANSI.match(text, start) and len(text) - start < 4096:
            self.pending = text[start:]
            text = text[:start]
        self.buf += ANSI.sub("", text).replace("\r", "")
        return True

    def expect(self, pattern, timeout):
        regex = re.compile(pattern, re.M | re.S)
        deadline = time.monotonic() + timeout
        while True:
            match = regex.search(self.buf, self.pos)
            if match:
                self.pos = match.end()
                return match
            if time.monotonic() > deadline:
                raise TestFailure(f"timed out after {timeout}s waiting for {pattern!r}")
            if not self._pump(1) and not regex.search(self.buf, self.pos):
                raise TestFailure(f"VM exited while waiting for {pattern!r}")

    def send(self, line):
        self.stdin.write((line + "\n").encode())

    def run(self, command, timeout=120):
        """Runs a command in the logged-in shell. Returns (exit code, output)."""
        # The empty '' keeps the echoed command line from matching the markers.
        # The extra echo ends lines left open, such as sudo's password prompt.
        self.send(f"echo __BEG''IN__; ( {command} ) 2>&1; rc=$?; echo; echo __END''ED__$rc")
        match = self.expect(r"^__BEGIN__\n(.*?)^__ENDED__(\d+)$", timeout)
        return int(match.group(2)), match.group(1)

    def must(self, command, pattern=None, timeout=120):
        code, out = self.run(command, timeout)
        if code != 0:
            raise TestFailure(f"{command!r} exited {code}:\n{out}")
        if pattern and not re.search(pattern, out, re.M):
            raise TestFailure(f"{command!r} output lacks {pattern!r}:\n{out}")
        print(f"    ok: {command}", flush=True)
        return out

    def wait_for_shell(self, timeout):
        """Keeps asking until a shell answers. Typing sent before a resume is
        lost along with the boot kernel, so one attempt isn't enough."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.send("echo __ALI''VE__")
            try:
                self.expect(r"^__ALIVE__$", 10)
                return
            except TestFailure:
                continue
        raise TestFailure(f"no shell answered within {timeout}s")

    def wait_exit(self, timeout):
        deadline = time.monotonic() + timeout
        while self.proc.poll() is None:
            if time.monotonic() > deadline:
                raise TestFailure(f"VM still running after {timeout}s")
            self._pump(1)

    def kill(self):
        if self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()


def answers(**kw):
    defaults = dict(
        KEYMAP="us", TIMEZONE="UTC", PROFILE="none", DOTFILES_REPO="",
        ENCRYPT="no", HIBERNATE="no", HOSTNAME="", USERNAME="tester",
        PASSWORD=PASSWORD, PASSPHRASE=PASSPHRASE,
        EXTRA_MACHINE_NIX=SERIAL_LINE,
    )
    defaults.update(kw)
    return "\n".join(f"ANSWER_{k}={shlex.quote(str(v))}" for k, v in defaults.items())


def boot_iso(vm, disk):
    vm.expect(r"nixos@nixos", 300)
    vm.send("")
    vm.must("sudo dmesg -n 1")
    vm.must(f"test -b {disk}")


def run_installer(vm, answer_text, timeout=3000):
    vm.send("cat > /tmp/answers <<'ANSWERS_END'")
    for line in answer_text.splitlines():
        vm.send(line)
    vm.send("ANSWERS_END")
    return vm.run("sudo bash -c 'set -a; . /tmp/answers; set +a; exec nixos-installer'", timeout)


def login(vm, user, encrypted):
    if encrypted:
        vm.expect(r"[Pp]assphrase for", 300)
        vm.send(PASSPHRASE)
    vm.expect(r"login: *$", 300)
    vm.send(user)
    vm.expect(r"Password: *$", 60)
    vm.send(PASSWORD)
    time.sleep(3)
    vm.must(f"echo {PASSWORD} | sudo -S dmesg -n 1")


def poweroff(vm):
    vm.send(f"echo {PASSWORD} | sudo -S systemctl poweroff")
    vm.wait_exit(180)


def check_base(vm, cfg):
    """What every installed machine must have, whatever was chosen."""
    vm.must("hostname", rf"^{re.escape(cfg['expect_host'])}$")
    vm.must("id -un", rf"^{re.escape(cfg['user'])}$")
    vm.must(f"echo {PASSWORD} | sudo -S true")
    vm.must("findmnt -no SOURCE /", r"^/dev/mapper/nixos-root")
    vm.must("swapon --noheadings --show=NAME", r"zram")
    vm.must("cat /etc/nixos/machine.nix", rf'hostName = "{re.escape(cfg["expect_host"])}"')
    vm.must("git --version")
    vm.must("nix flake --version")
    vm.must("nmcli -t -f STATE general", r"^connected")
    if cfg["firmware"] == "uefi":
        vm.must("test -d /sys/firmware/efi")
        vm.must(f"echo {PASSWORD} | sudo -S bootctl is-installed", r"yes")
    else:
        vm.must("test ! -d /sys/firmware/efi")
    if cfg["encrypt"]:
        vm.must("lsblk -no TYPE", r"^crypt$")
        vm.must("grep earlySetup /etc/nixos/machine.nix")
    else:
        code, _ = vm.run("lsblk -no TYPE | grep -x crypt")
        if code == 0:
            raise TestFailure("found an encrypted volume on an unencrypted install")


def prepare(name, firmware, bus, size, args):
    image = Path(args.work) / f"{name}.qcow2"
    image.unlink(missing_ok=True)
    subprocess.run(["qemu-img", "create", "-q", "-f", "qcow2", str(image), size], check=True)
    cfg: dict = dict(name=name, firmware=firmware, bus=bus, image=image)
    if firmware == "uefi":
        cfg["vars"] = Path(args.work) / f"{name}.vars.fd"
        shutil.copy(args.uefi_vars, cfg["vars"])
        cfg["vars"].chmod(0o644)
    return cfg


def cleanup(cfg):
    Path(cfg["image"]).unlink(missing_ok=True)
    if "vars" in cfg:
        Path(cfg["vars"]).unlink(missing_ok=True)


def scenario_refusals(args, log):
    """Bad answers stop the installer, and the disk stays completely untouched."""
    cfg = prepare("refusals", "uefi", "virtio", "30G", args)
    vm = VM(cfg, args, log, cdrom=True)
    try:
        boot_iso(vm, "/dev/vda")
        untouched = lambda: vm.must("test -z \"$(sudo wipefs -n /dev/vda)\" && test -z \"$(lsblk -no PTTYPE /dev/vda)\"")
        base = dict(DISK="/dev/vda", CONFIRM="/dev/vda")
        cases = [
            ("unreadable repo", dict(base, DOTFILES_REPO="https://github.com/sclash/this-repo-does-not-exist", DOTFILES_BRANCH="main"), "without logging in"),
            ("swap too large", dict(base, HIBERNATE="yes", SWAP_GIB="999"), "too little room"),
            ("root as username", dict(base, USERNAME="root"), "can't be root"),
            ("bad hostname", dict(base, HOSTNAME="-bad"), "hyphens"),
            ("wrong confirmation", dict(base, CONFIRM="no"), "Nothing was changed"),
        ]
        for label, answer, expected in cases:
            code, out = run_installer(vm, answers(**answer), timeout=240)
            if code == 0:
                raise TestFailure(f"{label}: the installer carried on")
            if expected not in out:
                raise TestFailure(f"{label}: missing {expected!r} in:\n{out}")
            print(f"    ok: {label} refused", flush=True)
            untouched()
    finally:
        vm.kill()
    cleanup(cfg)


def scenario_interactive(args, log):
    """The real prompts, typed key by key, as on a real machine. Stops at the
    wipe confirmation: the install itself is covered by the other scenarios."""
    cfg = prepare("interactive", "uefi", "virtio", "30G", args)
    vm = VM(cfg, args, log, cdrom=True)
    enter = "\r"
    clear_line = "\x15"
    steps = [
        ("Keyboard layout", "us" + enter),
        ("Which disk", enter),
        ("Encrypt the disk", enter),
        ("Enable hibernate", enter),
        ("Name this machine", enter),
        ("Your username", "root" + enter),
        ("can't be root", None),
        ("Your username", "alex" + enter),
        ("Your password", "one" + enter),
        ("once more", "two" + enter),
        ("didn't match", None),
        ("Your password", "same" + enter),
        ("once more", "same" + enter),
        ("Timezone", "Europe/Rome" + enter),
        ("Optional hardware fixes", enter),
        ("Dotfiles repo", clear_line + enter),
        ("Type /dev/vda to ERASE", "no" + enter),
    ]
    try:
        boot_iso(vm, "/dev/vda")
        vm.must("pgrep -t tty1 -f nixos-installer")
        print("    ok: installer started by itself on the screen console", flush=True)
        vm.must("stty rows 40 cols 120")
        vm.send("sudo nixos-installer; echo __INSTALLER_EXIT__$?")
        for text, keys in steps:
            vm.expect(re.escape(text), 60)
            if keys is None:
                print(f"    ok: refused with {text!r}", flush=True)
                continue
            time.sleep(1)
            vm.stdin.write(keys.encode())
            print(f"    ok: prompt {text!r}", flush=True)
        vm.expect(r"Nothing was changed", 30)
        match = vm.expect(r"__INSTALLER_EXIT__(\d+)", 30)
        if match.group(1) != "1":
            raise TestFailure(f"expected exit 1 after cancelling, got {match.group(1)}")
        summary = vm.buf[vm.buf.rfind("Ready to install"):]
        for expected in ("Encryption: no", "Hibernate:  no", "Hostname:   nixos",
                         "User:       alex", "Timezone:   Europe/Rome",
                         "Hardware:   none", "Dotfiles:   none"):
            if expected not in summary:
                raise TestFailure(f"summary lacks {expected!r}:\n{summary}")
        print("    ok: the summary shows what was typed", flush=True)
        vm.must("test -z \"$(sudo wipefs -n /dev/vda)\" && test -z \"$(lsblk -no PTTYPE /dev/vda)\"")
    finally:
        vm.kill()
    cleanup(cfg)


def scenario_uefi_plain(args, log):
    """UEFI, virtio, no encryption, default hostname, dotfiles that fail then recover."""
    cfg = prepare("uefi-plain", "uefi", "virtio", "30G", args)
    cfg.update(user="alex", encrypt=False, expect_host="nixos")
    vm = VM(cfg, args, log, cdrom=True)
    try:
        boot_iso(vm, "/dev/vda")
        code, out = run_installer(vm, answers(
            DISK="/dev/vda", CONFIRM="/dev/vda", USERNAME="alex",
            DOTFILES_REPO=FIXTURE_URL, DOTFILES_BRANCH="main"))
        if code != 0:
            raise TestFailure(f"installer exited {code}:\n{out[-3000:]}")
        vm.send("sudo poweroff")
        vm.wait_exit(180)
    finally:
        vm.kill()
    vm = VM(cfg, args, log)
    try:
        login(vm, "alex", False)
        check_base(vm, cfg)
        code, _ = vm.run("swapon --noheadings --show=NAME | grep -v zram")
        if code == 0:
            raise TestFailure("disk swap exists without hibernate")
        # Broken dotfiles: stops cleanly and the system keeps working.
        code, out = vm.run("bash /etc/nixos/first-boot.sh", 120)
        if code == 0 or "still plain NixOS" not in out:
            raise TestFailure(f"broken dotfiles not reported (exit {code}):\n{out}")
        vm.must("test ! -e ~/.local/state/nixos-installer/first-boot-done")
        vm.must("test -d ~/dotfiles/.git")
        print("    ok: broken dotfiles stop cleanly", flush=True)
        # The machine has its own key and secrets, with the fixture's names as null.
        vm.must("stat -c %a ~/.config/sops/age/keys.txt", r"^600$")
        vm.must("stat -c %a ~/.config/sops/secrets.yaml", r"^600$")
        vm.must("sops -d ~/.config/sops/secrets.yaml", r"first: null\s+second: null")
        vm.must("sha256sum ~/.config/sops/age/keys.txt ~/.config/sops/secrets.yaml > ~/before")
        print("    ok: own age key and secrets, names set to null", flush=True)
        # Fixed: re-running reuses the clone and finishes, keeping both files.
        vm.must("touch ~/fixed")
        vm.must("bash /etc/nixos/first-boot.sh", r"fixture-bootstrap-ran")
        vm.must("test -e ~/.local/state/nixos-installer/first-boot-done")
        vm.must("sha256sum -c ~/before")
        poweroff(vm)
    finally:
        vm.kill()
    # The base system still boots after all of that.
    vm = VM(cfg, args, log)
    try:
        login(vm, "alex", False)
        vm.must("hostname", r"^nixos$")
        poweroff(vm)
    finally:
        vm.kill()
    cleanup(cfg)


def scenario_uefi_encrypted_hibernate(args, log):
    """UEFI, NVMe, LUKS, hibernate sized from detected RAM, no dotfiles. Really resumes."""
    cfg = prepare("uefi-luks-hibernate", "uefi", "nvme", "60G", args)
    cfg.update(user="a.sergi", encrypt=True, expect_host="my-laptop")
    vm = VM(cfg, args, log, cdrom=True)
    try:
        boot_iso(vm, "/dev/nvme0n1")
        code, out = run_installer(vm, answers(
            DISK="/dev/nvme0n1", CONFIRM="/dev/nvme0n1", USERNAME="a.sergi",
            HOSTNAME="my-laptop", ENCRYPT="yes", HIBERNATE="yes", SWAP_GIB=""))
        if code != 0:
            raise TestFailure(f"installer exited {code}:\n{out[-3000:]}")
        vm.send("sudo poweroff")
        vm.wait_exit(180)
    finally:
        vm.kill()
    vm = VM(cfg, args, log)
    try:
        login(vm, "a.sergi", True)
        check_base(vm, cfg)
        vm.must("test ! -e /etc/nixos/first-boot.sh")
        # 2.5 GiB of RAM rounds up to 3, plus the 1 GiB margin.
        vm.must("sudo -n true 2>/dev/null; lsblk -bno NAME,SIZE /dev/nixos/swap", r" 4294967296$")
        vm.must("swapon --noheadings --show=NAME", r"/dev/dm-")
        vm.must("grep resumeDevice /etc/nixos/machine.nix")
        # /dev/shm is RAM: only a real resume can bring this back.
        vm.must("echo still-here > /dev/shm/resume-test")
        vm.send(f"echo {PASSWORD} | sudo -S systemctl hibernate")
        vm.wait_exit(300)
    finally:
        vm.kill()
    vm = VM(cfg, args, log)
    try:
        vm.expect(r"[Pp]assphrase for", 300)
        vm.send(PASSPHRASE)
        vm.expect(r"Resume from hibernation", 120)
        vm.wait_for_shell(300)
        vm.must("cat /dev/shm/resume-test", r"^still-here$")
        print("    ok: session resumed from hibernate", flush=True)
        poweroff(vm)
    finally:
        vm.kill()
    cleanup(cfg)


def scenario_bios_encrypted(args, log):
    """BIOS, SATA, LUKS, and the real dotfiles dry-built on the installed machine."""
    cfg = prepare("bios-luks", "bios", "sata", "60G", args)
    # Evaluating the whole dotfiles flake needs more memory than an install.
    cfg.update(user="sam", encrypt=True, expect_host="old-pc", ram=4096)
    vm = VM(cfg, args, log, cdrom=True)
    try:
        boot_iso(vm, "/dev/sda")
        code, out = run_installer(vm, answers(
            DISK="/dev/sda", CONFIRM="/dev/sda", USERNAME="sam", HOSTNAME="old-pc",
            ENCRYPT="yes", DOTFILES_REPO="https://github.com/sclash/dotfiles",
            DOTFILES_BRANCH="quickshell"))
        if code != 0:
            raise TestFailure(f"installer exited {code}:\n{out[-3000:]}")
        vm.send("sudo poweroff")
        vm.wait_exit(180)
    finally:
        vm.kill()
    vm = VM(cfg, args, log)
    try:
        login(vm, "sam", True)
        check_base(vm, cfg)
        vm.must("grep boot.loader.grub.device /etc/nixos/machine.nix")
        # The real dotfiles on a freshly installed machine: an anonymous clone,
        # then a real dry-build against the machine.nix the installer wrote.
        # --dry-run stops short of downloading the whole system.
        vm.must("git clone -q --branch quickshell https://github.com/sclash/dotfiles ~/dotfiles", timeout=300)
        print("    ok: anonymous GitHub clone worked", flush=True)
        vm.must(
            "bash ~/dotfiles/nixos/bootstrap.sh --dry-run",
            r"DRY-RUN: sudo env SUDO_USER=sam DOTFILES_HOME=/home/sam nixos-rebuild boot",
            timeout=2400)
        print("    ok: the real flake builds against the installer's machine.nix", flush=True)
        poweroff(vm)
    finally:
        vm.kill()
    cleanup(cfg)


SCENARIOS = {
    "refusals": scenario_refusals,
    "interactive": scenario_interactive,
    "uefi-plain": scenario_uefi_plain,
    "uefi-luks-hibernate": scenario_uefi_encrypted_hibernate,
    "bios-luks": scenario_bios_encrypted,
}


def start_fixture(work):
    """A throwaway repo whose bootstrap fails until ~/fixed exists."""
    base = Path(work) / "git"
    shutil.rmtree(base, ignore_errors=True)
    repo = base / "fixture"
    (repo / "nixos").mkdir(parents=True)
    (repo / "nixos" / "bootstrap.sh").write_text(
        '[ -e "$HOME/fixed" ] || { echo "fixture: broken"; exit 1; }\n'
        "echo fixture-bootstrap-ran\n")
    (repo / "nixos" / "secrets").mkdir()
    (repo / "nixos" / "secrets" / "template.yaml").write_text("first: null\nsecond: null\n")
    git = ["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t"]
    subprocess.run(git + ["init", "-q", "-b", "main"], check=True)
    subprocess.run(git + ["add", "."], check=True)
    subprocess.run(git + ["commit", "-qm", "fixture"], check=True)
    # Its own session, so stopping it also stops the git-daemon child it starts.
    daemon = subprocess.Popen(
        ["git", "daemon", "--reuseaddr", "--export-all", "--listen=127.0.0.1",
         "--port=9418", f"--base-path={base}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    # A daemon left over from an earlier run would hold the port and serve its old
    # fixture, so stop here rather than test the wrong repo.
    time.sleep(1)
    if daemon.poll() is not None:
        sys.exit("git daemon could not start: is another one using port 9418?")
    return daemon


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--iso", required=True)
    parser.add_argument("--work", required=True)
    parser.add_argument("--uefi-code", required=True)
    parser.add_argument("--uefi-vars", required=True)
    parser.add_argument("scenarios", nargs="+", choices=list(SCENARIOS))
    args = parser.parse_args()
    Path(args.work).mkdir(parents=True, exist_ok=True)
    daemon = start_fixture(args.work)
    results = {}
    try:
        for name in args.scenarios:
            print(f"== {name}", flush=True)
            started = time.monotonic()
            with open(Path(args.work) / f"{name}.log", "w") as log:
                try:
                    SCENARIOS[name](args, log)
                    results[name] = "PASS"
                except TestFailure as err:
                    results[name] = "FAIL"
                    print(f"    FAILED: {err}", flush=True)
            print(f"   {results[name]} in {int(time.monotonic() - started)}s", flush=True)
    finally:
        os.killpg(daemon.pid, signal.SIGKILL)
    print("\n".join(f"{name}: {result}" for name, result in results.items()))
    sys.exit(0 if all(r == "PASS" for r in results.values()) else 1)


main()
