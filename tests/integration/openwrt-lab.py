#!/usr/bin/env python3
"""Run two clean OpenWrt guests in a private Linux network namespace."""

import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import socket
import stat
import subprocess
import sys
import time
import uuid


SCRIPT = Path(__file__).resolve()
ROLES = ("dut", "client")
LAB_ADDRESSES = ("198.18.0.1", "203.0.114.1", "203.0.114.17", "203.0.115.18", "203.0.115.19")
BOOT_ID = Path("/proc/sys/kernel/random/boot_id")
STATE = "evidence/isolation.json"
BASE_ATTESTATION = "caller attested official checksum verification"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def safe_path(raw):
    path = Path(raw)
    require(path.is_absolute() and path != Path("/") and
            not any(ord(c) < 32 or c == "," for c in raw),
            f"expected a safe absolute path without commas: {raw!r}")
    require(path.resolve() == path, f"noncanonical path or symlink: {path}")
    require(path.parts[1] not in {
        "dev", "proc", "sys", "run", "boot", "etc", "usr", "bin", "sbin", "lib", "lib64",
    }, f"system path is not a lab input: {path}")
    return path


def netns(pid):
    return os.readlink(f"/proc/{pid}/ns/net")


def run(args, **kwargs):
    return subprocess.run(args, check=True, timeout=20, **kwargs)


def network(ip, host):
    namespace = netns("self")
    require(namespace != host, "refusing to use the host namespace")
    links = json.loads(run([ip, "-j", "addr"], capture_output=True).stdout)
    routes = [route for family in ("-4", "-6") for route in json.loads(
        run([ip, family, "-j", "route", "show", "table", "all"], capture_output=True).stdout)]
    require([link["ifname"] for link in links] == ["lo"] and
            not any(route.get("dst") == "default" for route in routes),
            "expected only loopback and no default route")
    return links, routes


def open_directory(path, *, dir_fd=None):
    return os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=dir_fd)


class ServedHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, root_fd):
        self.root_fd = root_fd
        super().__init__(*args, directory="/")

    def send_head(self):
        path = self.translate_path(self.path)
        if path.endswith("/"):
            self.send_error(404, "File not found")
            return None
        parts = Path(path).parts[1:]
        directory = os.dup(self.root_fd)
        try:
            # Resolve each component from an open directory, without following links.
            for parent in parts[:-1]:
                next_directory = open_directory(parent, dir_fd=directory)
                os.close(directory)
                directory = next_directory
            fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        except (OSError, ValueError):
            self.send_error(404, "File not found")
            return None
        finally:
            os.close(directory)

        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode):
                self.send_error(404, "File not found")
                return None
            self.send_response(200)
            self.send_header("Content-Type", self.guess_type(path))
            self.send_header("Content-Length", str(info.st_size))
            self.send_header("Last-Modified", self.date_time_string(info.st_mtime))
            self.end_headers()
            stream = os.fdopen(fd, "rb")
            fd = None
            return stream
        finally:
            if fd is not None:
                os.close(fd)


def serve_inputs(directory, host, ip):
    require(os.geteuid() != 0, "refusing to serve test inputs as root")
    network(ip, host)
    root_fd = open_directory(safe_path(directory))
    try:
        with ThreadingHTTPServer(("127.0.0.1", 21799), partial(ServedHandler, root_fd=root_fd)) as server:
            server.serve_forever()
    finally:
        os.close(root_fd)


def process_start(pid):
    return Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[19]


def identity(pid):
    proc = Path("/proc") / str(pid)
    return {"pid": pid, "uid": proc.stat().st_uid, "started": process_start(pid), "netns": netns(pid),
            "argv": [os.fsdecode(arg) for arg in (proc / "cmdline").read_bytes()[:-1].split(b"\0")]}


def qemu_args(qemu, work, output, role):
    args = [
        qemu, "-no-user-config", "-machine", "pc,accel=tcg", "-m", "512" if role == "dut" else "256",
        "-smp", "1", "-display", "none",
        "-drive", f"file={work / (role + '.qcow2')},format=qcow2",
        "-chardev", f"socket,id=uart,path={output / (role + '.serial')},server=on,wait=off,"
        f"logfile={output / (role + '-uart.log')},logappend=on",
        "-serial", "chardev:uart", "-monitor", f"unix:{output / (role + '.monitor')},server=on,wait=off",
    ]
    if role == "dut":
        nics = (
            ("lan", "socket,id=lan,listen=127.0.0.1:21821", "00:00"),
            ("wan", "user,id=wan,net=10.21.1.0/24,ipv6=off", "00:01"),
            ("policy", "user,id=policy,net=10.21.2.0/24,ipv6=off", "00:02"),
        )
    else:
        nics = (
            ("lan", "socket,id=lan,connect=127.0.0.1:21821", "01:01"),
            ("control", "user,id=control,net=10.21.3.0/24,ipv6=off,"
             "hostfwd=tcp:127.0.0.1:21822-:22", "01:02"),
        )
    for name, backend, mac in nics:
        args += ["-netdev", backend, "-device", f"e1000,netdev={name},mac=52:54:00:21:{mac}"]
        if role == "dut":
            args += ["-object", f"filter-dump,id=cap{name},netdev={name},file={output / (name + '.pcap')}"]
    return args


def listeners():
    rows = Path("/proc/net/tcp").read_text().splitlines()[1:]
    return {row.split()[1] for row in rows if row.split()[3] == "0A"}


def image_info(qemu_img, path):
    return json.loads(run([qemu_img, "info", "--output=json", str(path)], capture_output=True).stdout)


def raw_info(qemu_img, base):
    require(stat.S_ISREG(base.lstat().st_mode), f"base image must be a regular file: {base}")
    image = image_info(qemu_img, base)
    require(image.get("format") == "raw", f"base image is not raw: {base}")
    return image


def owned_path(path, directory=False):
    info = path.lstat()
    correct_type = stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode) and info.st_nlink == 1
    require(correct_type and info.st_uid == os.geteuid() and not info.st_mode & 0o022,
            f"expected a private path owned by the lab user: {path}")


def resumable_base(work, proof, qemu_img):
    require(proof["work"] == str(work) and proof["base_verification"] == BASE_ATTESTATION,
            "existing evidence does not describe this lab and its verified base")
    base = safe_path(proof["base"])
    namespace = proof["netns"]
    require(re.fullmatch(r"net:\[\d+\]", namespace) and namespace != proof["host_netns"],
            "original lab namespace is invalid")
    same_boot = str(uuid.UUID(proof["boot_id"])) == BOOT_ID.read_text().strip()
    records = (("anchor", "_run"), ("served", str(work / "served")), ("services", str(work / "services")))
    records += tuple((role, f"file={work / (role + '.qcow2')},format=qcow2") for role in ROLES)
    require(str(work) in proof["anchor"]["argv"], "original launcher does not match the lab path")
    pids = set()
    for name, arg in records:
        record = proof[name]
        pid = record["pid"]
        require(type(pid) is int and pid > 1 and pid not in pids and
                record["uid"] == os.geteuid() and record["netns"] == namespace and
                isinstance(record["argv"], list) and arg in record["argv"] and record["started"].isdigit(),
                f"invalid original process evidence: {name}")
        pids.add(pid)
        if same_boot:
            try:
                started = process_start(pid)
            except FileNotFoundError:
                continue
            require(started != record["started"], f"original {name} process is still present (PID {pid})")

    image = raw_info(qemu_img, base)
    for role in ROLES:
        disk = work / (role + ".qcow2")
        owned_path(disk)
        overlay = image_info(qemu_img, disk)
        require(overlay.get("format") == "qcow2" and overlay.get("backing-filename") == str(base) and
                overlay.get("full-backing-filename") == str(base) and overlay.get("backing-filename-format") == "raw" and
                overlay.get("virtual-size") == image.get("virtual-size") and
                not overlay.get("format-specific", {}).get("data", {}).get("data-file"),
                f"overlay does not use just the original raw base: {disk}")
    return base


def resume_lab(work, host, ip, qemu_img, qemu):
    for folder in (work, work / "evidence", work / "served", work / "services"):
        owned_path(folder, directory=True)
    owned_path(work / "console.lock")
    previous = work / STATE
    owned_path(previous)
    evidence = previous.read_bytes()
    base = resumable_base(work, json.loads(evidence), qemu_img)
    # An interrupted resume can leave unrecorded children. Keep this marker if forcibly killed.
    marker = work / "evidence/resume.lock"
    try:
        marker.touch(mode=0o600, exist_ok=False)
    except FileExistsError as exc:
        raise ValueError(f"resume is active or was interrupted: {marker}") from exc
    try:
        require(previous.read_bytes() == evidence, "lab evidence changed; retry the resume")
        output = work / ("run-" + uuid.uuid4().hex[:8])
        supervise(base, work, host, ip, qemu_img, qemu, output, evidence)
    finally:
        marker.unlink()


def supervise(base, work, host, ip, qemu_img, qemu, output=None, previous=None):
    stopping = False
    children = {}

    def request_stop(_signum, _frame):
        nonlocal stopping
        stopping = True

    def start(name, args):
        with (output / (name + ".log")).open("xb") as log:
            children[name] = subprocess.Popen(
                args, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                start_new_session=True,
            )

    def check_children():
        for name, child in children.items():
            if child.poll() is not None:
                raise ValueError(f"{name} exited ({child.returncode}); see {output / (name + '.log')}")

    def ready(predicate):
        deadline = time.monotonic() + 15
        while not stopping:
            check_children()
            if predicate():
                return True
            require(time.monotonic() < deadline, f"fixture startup timed out; see {output}")
            time.sleep(0.1)
        return False

    for kind in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(kind, request_stop)

    links, routes = network(ip, host)
    output = output or work
    require(len(os.fsencode(output / "client.monitor")) <= 107, "run path is too long for UNIX sockets")
    os.umask(0o077)
    if previous is None:
        raw_info(qemu_img, base)
        if stopping:
            return
        work.mkdir(mode=0o700)
        for name in ("evidence", "served", "services"):
            (work / name).mkdir()
        (work / "console.lock").touch(exist_ok=False)
        for role in ROLES:
            run([qemu_img, "create", "-f", "qcow2", "-F", "raw", "-b", str(base),
                 str(work / (role + ".qcow2"))])
    else:
        output.mkdir(mode=0o700)
        with (output / "previous-isolation.json").open("xb") as archive:
            archive.write(previous)
    if stopping:
        return

    try:
        start("dut", qemu_args(qemu, work, output, "dut"))
        if not ready(lambda: f"0100007F:{21821:04X}" in listeners()):
            return
        start("client", qemu_args(qemu, work, output, "client"))
        start("served", [sys.executable, "-I", str(SCRIPT), "_serve", str(work / "served"), host, ip])
        start("services", [sys.executable, "-I", str(SCRIPT.with_name("controlled-services.py")),
                           "--directory", str(work / "services"), "--host-netns", host])
        expected = {f"0100007F:{port:04X}" for port in (21822, 21799)} | {f"00000000:{18080:04X}"}
        if not ready(lambda: expected <= listeners() and all(
                (output / (role + suffix)).is_socket() for role in ROLES for suffix in (".serial", ".monitor"))):
            return

        proof = {
            "base": str(base), "base_verification": BASE_ATTESTATION, "output": str(output),
            "work": str(work), "boot_id": BOOT_ID.read_text().strip(), "host_netns": host,
            "netns": netns("self"), "links": links, "routes": routes,
            "anchor": identity(os.getpid()),
            **{name: identity(child.pid) for name, child in children.items()},
        }
        current = work / STATE if previous is None else output / "isolation.json"
        with current.open("x", encoding="utf-8") as evidence:
            json.dump(proof, evidence, indent=2)
            evidence.write("\n")
        if previous is not None:
            current.replace(work / STATE)
        print(f"Lab listeners ready: {work / STATE}; wait for guests to boot", flush=True)
        while not stopping:
            check_children()
            time.sleep(0.25)
    finally:
        for child in children.values():
            child.terminate()
        deadline = time.monotonic() + 5
        for child in children.values():
            try:
                child.wait(timeout=max(0, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()


def in_namespace(stage, username, base, work, host, ip, qemu_img, qemu):
    import pwd

    user = pwd.getpwnam(username)
    require(user.pw_uid != 0, "--user must be non-root")
    network(ip, host)
    if stage == "_net":
        require(os.geteuid() == 0, "namespace setup needs root")
        require(netns("self") != netns(1), "refusing to configure the init namespace")
        run([ip, "link", "set", "lo", "up"])
        for address in LAB_ADDRESSES:
            run([ip, "-4", "addr", "add", address + "/32", "dev", "lo"])
        os.initgroups(user.pw_name, user.pw_gid)
        os.setresgid(user.pw_gid, user.pw_gid, user.pw_gid)
        os.setresuid(user.pw_uid, user.pw_uid, user.pw_uid)
        os.environ.update(HOME=user.pw_dir, USER=user.pw_name, LOGNAME=user.pw_name)
        os.execv(sys.executable, [sys.executable, "-I", str(SCRIPT), "_run",
                                 username, base, work, host, ip, qemu_img, qemu])
    require(os.geteuid() == user.pw_uid, "refusing to launch guests as root or the wrong user")
    work = safe_path(work)
    if base:
        supervise(safe_path(base), work, host, ip, qemu_img, qemu)
    else:
        resume_lab(work, host, ip, qemu_img, qemu)


def launch(args):
    import pwd

    require(os.geteuid() == 0, "start and resume need sudo to create a network namespace")
    user = pwd.getpwnam(args.user)
    require(user.pw_uid != 0 and os.environ.get("SUDO_UID", str(user.pw_uid)) == str(user.pw_uid),
            "--user must be the invoking non-root Linux user")
    work = safe_path(args.work_dir)
    base = ""
    if args.action == "start":
        base = safe_path(args.base)
        require(base.is_file(), f"base image must be a regular file: {base}")
        require(not work.exists() and work.parent.is_dir(), "work directory must be new, with an existing parent")
    else:
        require(work.is_dir() and work.stat().st_uid == user.pw_uid, "use a lab directory owned by --user")
    commands = {}
    for tool in ("unshare", "ip", "qemu-img", "qemu-system-x86_64"):
        path = shutil.which(tool)
        require(path and Path(path).is_absolute(), f"missing tool: {tool}")
        commands[tool] = path
    require(SCRIPT.with_name("controlled-services.py").is_file(), "missing controlled-services.py")
    unshare = commands["unshare"]
    os.execv(unshare, [unshare, "--net", "--", sys.executable, "-I", str(SCRIPT), "_net",
                       args.user, str(base), str(work), netns("self"), commands["ip"],
                       commands["qemu-img"], commands["qemu-system-x86_64"]])


def load_proof(raw):
    work = safe_path(raw)
    require(os.geteuid() != 0 and work.stat().st_uid == os.geteuid(),
            "use the lab's non-root owner")
    proof = json.loads((work / STATE).read_text(encoding="utf-8"))
    require(proof["work"] == str(work) and proof["boot_id"] == BOOT_ID.read_text().strip(),
            "lab path or boot ID changed")
    require(proof["netns"] not in (proof["host_netns"], netns("self")), "lab namespace is not isolated")
    return work, proof


def verify_process(proof, role, argv_item):
    record = proof[role]
    require(record["uid"] == os.geteuid() and record["netns"] == proof["netns"] and
            argv_item in record["argv"] and identity(record["pid"]) == record,
            f"{role} PID, namespace or launch arguments changed")


def stop(args):
    work, proof = load_proof(args.work_dir)
    # Pin this PID while verifying it so reuse cannot redirect the signal.
    fd = os.pidfd_open(proof["anchor"]["pid"])
    try:
        verify_process(proof, "anchor", str(work))
        signal.pidfd_send_signal(fd, signal.SIGTERM)
    finally:
        os.close(fd)


def console(args):
    import fcntl

    work, proof = load_proof(args.work_dir)
    require(1 <= args.timeout <= 240, "--timeout must be between 1 and 240 seconds")
    require(bool(args.command) and all(ord(c) >= 32 and ord(c) != 127 for c in args.command),
            "provide a single shell command with no control characters")
    marker = "RP_" + uuid.uuid4().hex
    payload = (f"sh -c {shlex.quote(args.command)}; printf '\\n{marker}:%s\\n' \"$?\"\n").encode()
    require(len(payload) <= 440, "console command is too long; stage a script in served/ instead")
    result = re.compile(rb"\n" + marker.encode() + rb":([0-9]+)\r?\n")
    prompt = re.compile(rb"(?m)^root@[^:\r\n]+:[^\r\n]*# ?$")
    role = args.role
    output = safe_path(proof.get("output", str(work)))
    require(output == work or output.parent == work, "invalid lab runtime directory")
    with (work / "console.lock").open("r") as lock, socket.socket(socket.AF_UNIX) as uart:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        verify_process(proof, "anchor", str(work))
        verify_process(proof, role, f"file={work / (role + '.qcow2')},format=qcow2")
        path = output / (role + ".serial")
        require(any(arg.startswith(f"socket,id=uart,path={path},") for arg in proof[role]["argv"]),
                "serial socket is missing from the recorded QEMU arguments")
        require(stat.S_ISSOCK(path.lstat().st_mode), f"not a serial socket: {path}")
        uart.settimeout(0.25)
        uart.connect(str(path))
        tail = b""
        end = time.monotonic() + 30
        next_enter = 0
        while time.monotonic() < end:
            if time.monotonic() >= next_enter:
                uart.sendall(b"\n")
                next_enter = time.monotonic() + 2
            try:
                data = uart.recv(65536)
            except socket.timeout:
                continue
            require(data, "serial console closed")
            tail = (tail + data)[-4096:]
            if prompt.search(tail):
                break
        else:
            raise ValueError(f"{role} shell prompt unavailable; see {output / (role + '-uart.log')}")
        end = time.monotonic() + args.timeout
        for index in range(0, len(payload), 32):
            uart.sendall(payload[index:index + 32])
            time.sleep(0.02)
        tail = b""
        while time.monotonic() < end:
            try:
                data = uart.recv(65536)
            except socket.timeout:
                continue
            require(data, "serial console closed before command completion")
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()
            if match := result.search(tail + data):
                return int(match[1])
            tail = (tail + data)[-128:]
        raise ValueError("guest command timed out; it may still be running")


def main():
    if len(sys.argv) == 9 and sys.argv[1] in ("_net", "_run") and sys.platform == "linux":
        return in_namespace(*sys.argv[1:])
    if len(sys.argv) == 5 and sys.argv[1] == "_serve" and sys.platform == "linux":
        return serve_inputs(*sys.argv[2:])

    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    start = sub.add_parser("start", help="start a fresh lab in the foreground (sudo)")
    start.add_argument("--base", required=True, help="absolute path to the verified, extracted official raw image")
    start.add_argument("--verified-openwrt-raw", required=True, action="store_true",
                       help="attest that you verified the official image checksum before extracting it")
    resume = sub.add_parser("resume", help="relaunch a stopped lab with its existing disks (sudo)")
    for command in (start, resume):
        command.add_argument("--user", required=True, help="the invoking non-root Linux user")
    send = sub.add_parser("console", help="send one explicit command over a guest's serial console")
    send.add_argument("role", choices=ROLES)
    send.add_argument("command")
    send.add_argument("--timeout", type=int, default=120, help="seconds to wait for command exit (1–240)")
    halt = sub.add_parser("stop", help="stop a running lab and retain the files")
    for subcommand in (start, resume, send, halt):
        subcommand.add_argument("--work-dir", required=True, help="absolute lab directory path")
    args = parser.parse_args()
    require(sys.platform == "linux", "run on Linux or WSL")
    return {"start": launch, "resume": launch, "console": console, "stop": stop}[args.action](args)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as exc:
        raise SystemExit(f"openwrt-lab: {exc}") from None
