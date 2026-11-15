#!/usr/bin/env python3
"""DNS and HTTP fixtures for an isolated OpenWrt lab, never the host network."""
import argparse
import json
import os
from pathlib import Path
import re
import socket
import struct
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True,
                        help="existing private directory for test logs and blocked-* markers")
    parser.add_argument("--host-netns", required=True,
                        help="network namespace identity recorded by the launcher before unshare")
    args = parser.parse_args()
    directory = args.directory.resolve(strict=True)
    if not directory.is_dir() or args.directory.is_symlink():
        parser.error("a real existing directory is required")
    if not re.fullmatch(r"net:\[\d+\]", args.host_netns):
        parser.error("invalid host namespace identity")
    if os.readlink("/proc/self/ns/net") == args.host_netns:
        parser.error("refusing to listen in the host network namespace")
    links = json.loads(subprocess.check_output(["ip", "-j", "link"]))
    routes = json.loads(subprocess.check_output(["ip", "-j", "route", "show", "table", "all"]))
    if {link["ifname"] for link in links} != {"lo"} or any(
            route.get("dst") == "default" for route in routes):
        parser.error("the lab namespace must have only loopback and no default route")
    lock = threading.Lock()

    def record(name, row):
        with lock, (directory / name).open("a", encoding="utf-8") as stream:
            stream.write(json.dumps(row) + "\n")

    def answer(data, group, peer, transport):
        if len(data) < 12 or struct.unpack("!H", data[4:6])[0] != 1:
            return None
        offset, labels = 12, []
        try:
            while data[offset]:
                length = data[offset]
                offset += 1
                if length > 63 or offset + length >= len(data):
                    return None
                labels.append(data[offset:offset + length].decode("ascii"))
                offset += length
            offset += 1
            qtype, qclass = struct.unpack("!HH", data[offset:offset + 4])
        except (IndexError, UnicodeError, struct.error):
            return None
        end = offset + 4
        name = ".".join(labels).lower()
        known = name.endswith(".lab19.test")
        address = "203.0.114.17" if group == "default" or name == "rules.lab19.test" else "203.0.115.18"
        count = int(known and qtype == 1 and qclass == 1)
        blocked = (directory / ("blocked-" + group)).exists()
        record("dns.jsonl", {"wall": time.time(), "server": group, "transport": transport,
                             "peer": peer, "name": name, "qtype": qtype,
                             "answer": address if count else None, "blocked": blocked})
        if blocked:
            return None
        response = data[:2] + struct.pack("!HHHHH", 0x8580 if known else 0x8183, 1, count, 0, 0) + data[12:end]
        if count:
            response += b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 1200, 4) + socket.inet_aton(address)
        return response

    def udp(server, group):
        while True:
            data, peer = server.recvfrom(4096)
            response = answer(data, group, peer, "udp")
            if response:
                server.sendto(response, peer)

    def receive(client, length):
        data = b""
        while len(data) < length:
            chunk = client.recv(length - len(data))
            if not chunk:
                return None
            data += chunk
        return data

    def tcp(server, group):
        while True:
            client, peer = server.accept()
            with client:
                client.settimeout(4)
                try:
                    size = receive(client, 2)
                    if not size or not 12 <= struct.unpack("!H", size)[0] <= 4096:
                        continue
                    data = receive(client, struct.unpack("!H", size)[0])
                    response = answer(data, group, peer, "tcp") if data else None
                    if response:
                        client.sendall(struct.pack("!H", len(response)) + response)
                except OSError:
                    continue

    class Handler(BaseHTTPRequestHandler):
        timeout = 4

        def do_GET(self):
            row = {"wall": time.time(), "peer": self.client_address,
                   "destination": self.connection.getsockname(), "path": self.path}
            record("business.jsonl", row)
            payload = (json.dumps(row) + "\n").encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

    # Bind every listener before starting threads, so missing lab addresses fail visibly.
    sockets = []
    workers = []
    try:
        for address, group in [("198.18.0.1", "default"), ("203.0.114.1", "policy")]:
            for kind, serve in [(socket.SOCK_DGRAM, udp), (socket.SOCK_STREAM, tcp)]:
                server = socket.socket(socket.AF_INET, kind)
                sockets.append(server)
                server.bind((address, 25353))
                if kind == socket.SOCK_STREAM:
                    server.listen(8)
                workers.append(threading.Thread(target=serve, args=(server, group), daemon=True))
        with HTTPServer(("0.0.0.0", 18080), Handler) as http:
            for worker in workers:
                worker.start()
            print("Isolated DNS TCP/UDP and HTTP fixtures ready", flush=True)
            http.serve_forever()
    finally:
        for server in sockets:
            server.close()


if __name__ == "__main__":
    main()
