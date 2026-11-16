"""Resolve a stable release version; only auto mode updates package Makefiles."""
import argparse
import re
import subprocess
from pathlib import Path

VERSION = r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
PACKAGES = ("routepolicy", "luci-app-routepolicy")


def parse_version(value):
    if not re.fullmatch(VERSION, value):
        raise ValueError(f"无效正式版本：{value}")
    return tuple(map(int, value.split(".")))


def resolve(root, mode, tags, tag=""):
    paths = [root / name / "Makefile" for name in PACKAGES]
    texts = [path.read_text(encoding="utf-8") for path in paths]
    versions = []
    for text in texts:
        values = re.findall(r"^PKG_VERSION:=(.+)$", text, re.M)
        if len(values) != 1 or len(re.findall(r"^PKG_RELEASE:=[1-9][0-9]*$", text, re.M)) != 1:
            raise ValueError("包版本或发布序号缺失、重复或非法")
        versions.append(parse_version(values[0]))
    if versions[0] != versions[1]:
        raise ValueError("两个包的 PKG_VERSION 必须一致")
    if tag:
        if not tag.startswith("v") or parse_version(tag[1:]) != versions[0]:
            raise ValueError("tag 必须为 vX.Y.Z 且与两个包版本一致")
        return tag
    if mode not in ("patch", "minor", "major"):
        raise ValueError("必须选择 patch、minor 或 major")
    stable = [parse_version(t[1:]) for t in tags if re.fullmatch("v" + VERSION, t)]
    version = list(max([versions[0], *stable]))
    index = {"major": 0, "minor": 1, "patch": 2}[mode]
    version[index] += 1
    version[index + 1:] = [0] * (2 - index)
    value = ".".join(map(str, version))
    for path, text in zip(paths, texts):
        text = re.sub(r"^PKG_VERSION:=.*$", f"PKG_VERSION:={value}", text, flags=re.M)
        text = re.sub(r"^PKG_RELEASE:=.*$", "PKG_RELEASE:=1", text, flags=re.M)
        path.write_text(text, encoding="utf-8", newline="\n")
    return "v" + value


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", default="patch")
    parser.add_argument("--tag", default="")
    args = parser.parse_args()
    tags = subprocess.check_output(["git", "tag", "--list"], text=True).splitlines()
    try:
        print(resolve(Path.cwd(), args.mode, tags, args.tag))
    except ValueError as error:
        parser.exit(1, f"{error}\n")
