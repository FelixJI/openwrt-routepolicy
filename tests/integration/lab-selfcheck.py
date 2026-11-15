#!/usr/bin/env python3
"""Exercise the lab's HTTP and resume boundaries without starting a VM or namespace."""

import copy
import json
import os
from pathlib import Path
import runpy
import shutil
import signal
import socket
import subprocess
import sys
from tempfile import TemporaryDirectory
from unittest.mock import patch


def check(condition, message):
    if not condition:
        raise AssertionError(message)


def rejects(action, error_type, message):
    try:
        action()
    except error_type as error:
        check(message in str(error), f"expected {message!r}, got {error!r}")
    else:
        raise AssertionError(f"expected refusal: {message}")


def check_http(lab, directory):
    class QuietHandler(lab["ServedHandler"]):
        def log_message(self, *_args):
            pass

    served = directory / "served"
    nested = served / "nested"
    outside = directory / "outside"
    nested.mkdir(parents=True)
    outside.mkdir()
    (nested / "asset.txt").write_bytes(b"test content")
    (outside / "private.txt").write_bytes(b"out of root")
    (served / "file-link").symlink_to(outside / "private.txt")
    (served / "dir-link").symlink_to(outside, target_is_directory=True)
    (served / "index.html").symlink_to(outside / "private.txt")
    os.mkfifo(served / "fifo")

    root_fd = lab["open_directory"](served)

    def request(path, method="GET"):
        client, server = socket.socketpair()
        with client:
            client.settimeout(2)
            with server:
                server.settimeout(2)
                client.sendall(f"{method} {path} HTTP/1.0\r\nHost: lab\r\n\r\n".encode())
                client.shutdown(socket.SHUT_WR)
                QuietHandler(server, ("127.0.0.1", 0), None, root_fd=root_fd)
            headers, body = b"".join(iter(lambda: client.recv(4096), b"")).split(b"\r\n\r\n", 1)
            return int(headers.split(b" ", 2)[1]), body

    def expired(_signum, _frame):
        raise AssertionError("HTTP fixture blocked, including possible FIFO open")

    previous_alarm = signal.signal(signal.SIGALRM, expired)
    try:
        signal.alarm(5)
        check(request("/nested/asset.txt") == (200, b"test content"), "GET did not return the staged file")
        check(request("/nested/asset.txt", "HEAD") == (200, b""), "HEAD returned an error or a body")
        for path in ("/file-link", "/dir-link/private.txt", "/", "/index.html", "/fifo"):
            status, body = request(path)
            check(status == 404 and b"out of root" not in body, f"unexpected response for {path}: {status}")
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous_alarm)
        os.close(root_fd)


def check_resume(lab, directory, qemu_img):
    def image(*args):
        subprocess.run([qemu_img, "create", *map(str, args)], check=True, stdout=subprocess.DEVNULL, timeout=10)

    base, other = directory / "original.raw", directory / "other.raw"
    image("-f", "raw", base, "8M")
    image("-f", "raw", other, "8M")
    work = directory / "lab"
    work.mkdir(mode=0o700)
    for name in ("evidence", "served", "services"):
        (work / name).mkdir(mode=0o700)
    (work / "console.lock").touch()
    disk = work / "dut.qcow2"
    image("-f", "qcow2", "-F", "raw", "-b", base, disk)
    image("-f", "qcow2", "-F", "raw", "-b", base, work / "client.qcow2")

    old_capture = work / "wan.pcap"
    old_capture.write_bytes(b"last run")
    state, marker = work / lab["STATE"], work / "evidence/resume.lock"
    proof = {
        "base": str(base), "base_verification": lab["BASE_ATTESTATION"], "work": str(work),
        "netns": "net:[100]", "host_netns": "net:[90]", "boot_id": lab["BOOT_ID"].read_text().strip(),
    }
    pid_max = int(Path("/proc/sys/kernel/pid_max").read_text())
    recorded_commands = {
        "anchor": ["python3", "_run", str(work)], "served": ["python3", str(work / "served")],
        "services": ["python3", str(work / "services")],
        "dut": ["qemu-system-x86_64", f"file={disk},format=qcow2"],
        "client": ["qemu-system-x86_64", f"file={work / 'client.qcow2'},format=qcow2"],
    }
    for pid, (name, argv) in enumerate(recorded_commands.items(), pid_max + 1):
        proof[name] = {"pid": pid, "started": "123", "uid": os.geteuid(), "netns": proof["netns"], "argv": argv}

    def save(new_proof):
        state.write_text(json.dumps(new_proof), encoding="utf-8")

    def resume():
        lab["resume_lab"](work, proof["host_netns"], "unused-ip", qemu_img, "unused-qemu")

    launch_failure = "simulated QEMU launch failure"
    original_popen = subprocess.Popen

    def reject_guest_spawn(args, *positional, **kwargs):
        if args[0] == qemu_img:
            return original_popen(args, *positional, **kwargs)
        raise OSError(launch_failure)

    # Keep image inspection and the resume state transitions real.
    with original_popen([sys.executable, "-c", "import sys; sys.stdin.buffer.read()"], stdin=subprocess.PIPE) as live:
        try:
            with patch.dict(lab["resume_lab"].__globals__, {"network": lambda *_args: ([], [])}), \
                 patch.object(signal, "signal"), patch.object(subprocess, "Popen", reject_guest_spawn):
                active = copy.deepcopy(proof)
                active["anchor"].update(pid=live.pid, started=lab["process_start"](live.pid))
                save(active)
                rejects(resume, ValueError, "original anchor process is still present")

                foreign = copy.deepcopy(proof)
                foreign["anchor"]["uid"] = os.geteuid() + 1
                save(foreign)
                rejects(resume, ValueError, "invalid original process evidence")

                save(proof)
                original = disk.with_name("original.qcow2")
                disk.rename(original)
                disk.symlink_to(original)
                rejects(resume, ValueError, "expected a private path")
                disk.unlink()
                image("-f", "qcow2", "-F", "raw", "-b", other, disk)
                rejects(resume, ValueError, "does not use just the original raw base")
                disk.unlink()
                original.rename(disk)

                marker.write_bytes(b"existing resume")
                rejects(resume, ValueError, "resume is active or was interrupted")
                check(marker.read_bytes() == b"existing resume", "resume changed an existing marker")
                check(not list(work.glob("run-*")), "a refused resume created a run directory")
                marker.unlink()

                previous = state.read_bytes()
                disks = {path: path.stat() for path in work.glob("*.qcow2")}
                rejects(resume, OSError, launch_failure)
                check(not marker.exists(), "failed launch left a resume marker")
                check(state.read_bytes() == previous, "failed launch replaced the current evidence")
                archives = list(work.glob("run-*/previous-isolation.json"))
                check(len(archives) == 1 and archives[0].read_bytes() == previous, "previous evidence was not preserved")
                check(old_capture.read_bytes() == b"last run", "failed launch overwrote the previous capture")
                for path, old in disks.items():
                    current = path.stat()
                    check((current.st_mtime_ns, current.st_size) == (old.st_mtime_ns, old.st_size),
                          f"failed launch changed {path.name}")
        finally:
            live.stdin.close()


def main():
    if sys.platform != "linux":
        raise SystemExit("lab-selfcheck: run on Linux or WSL")
    qemu_img = shutil.which("qemu-img")
    if not qemu_img:
        raise SystemExit("lab-selfcheck: missing required tool qemu-img")
    lab = runpy.run_path(str(Path(__file__).with_name("openwrt-lab.py")))
    with TemporaryDirectory(prefix="rp-lab-", dir="/tmp") as temporary:
        directory = Path(temporary)
        check_http(lab, directory)
        check_resume(lab, directory, qemu_img)
    print("Lab self-check passed: HTTP file access and resume safeguards")


if __name__ == "__main__":
    main()
