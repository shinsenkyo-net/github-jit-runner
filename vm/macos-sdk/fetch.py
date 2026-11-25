#!/usr/bin/env python3
"""Fetch the newest macOS SDK from Apple's public software update catalog.

    fetch.py OUT_DIR [PACKAGE]

Picks the newest "Command Line Tools for Xcode" product in the catalog that
ships PACKAGE (default CLTools_macOSNMOS_SDK.pkg, the SDK for the macOS the
tools were released with), checks the package against the catalog's size and
SHA-1, and unpacks it: xar and pbzx here, cpio with bsdtar. The catalog's
Digest is the SHA-1 of the package's compressed xar table of contents, which
holds the SHA-1 of the Payload: both are checked.

Leaves OUT_DIR/MacOSX<version>.sdk, a MacOSX.sdk symlink to it and
OUT_DIR/VERSION, the SDK's own Version from SDKSettings.plist. No login, no
Apple ID; only swscan/swdist/swcdn.apple.com over HTTPS.
Needs python3 and bsdtar (libarchive-tools).
"""
import gzip
import hashlib
import lzma
import os
import plistlib
import re
import shutil
import subprocess
import sys
import struct
import tempfile
import urllib.request
import xml.etree.ElementTree as ET
import zlib

CATALOG = ("https://swscan.apple.com/content/catalogs/others/index-27-26-15-14-13-12-10.16-"
           "10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard."
           "merged-1.sucatalog.gz")
APPLE_HOST = re.compile(r"^https://[a-z0-9.-]+\.apple\.com/")


def log(msg):
    print(f"macos-sdk: {msg}", file=sys.stderr, flush=True)


def get(url):
    if not APPLE_HOST.match(url):
        sys.exit(f"macos-sdk: refusing non-Apple or non-HTTPS URL {url}")
    with urllib.request.urlopen(url, timeout=120) as r:
        return r.read()


def download(url, path, size):
    if not APPLE_HOST.match(url):
        sys.exit(f"macos-sdk: refusing non-Apple or non-HTTPS URL {url}")
    n = 0
    with urllib.request.urlopen(url, timeout=120) as r, open(path, "wb") as f:
        while chunk := r.read(1 << 20):
            n += len(chunk)
            f.write(chunk)
    if n != size:
        sys.exit(f"macos-sdk: {url}: got {n} bytes, catalog says {size}")


def xar_payload(pkg, digest, dst):
    """Check the xar TOC against the catalog digest, then extract and check Payload."""
    with open(pkg, "rb") as f:
        magic, hsize, _, toc_len, _, alg = struct.unpack(">4sHHQQI", f.read(28))
        if magic != b"xar!" or alg != 1:
            sys.exit("macos-sdk: not a xar archive with a SHA-1 table of contents")
        f.seek(hsize)
        ctoc = f.read(toc_len)
        if hashlib.sha1(ctoc).hexdigest() != digest:
            sys.exit("macos-sdk: xar table of contents does not match the catalog digest")
        toc = ET.fromstring(zlib.decompress(ctoc)).find("toc")
        heap = hsize + toc_len
        off, size = int(toc.findtext("checksum/offset")), int(toc.findtext("checksum/size"))
        f.seek(heap + off)
        if f.read(size).hex() != digest:
            sys.exit("macos-sdk: stored xar checksum differs from the table of contents")
        entry = [e for e in toc.findall("file") if e.findtext("name") == "Payload"]
        if len(entry) != 1:
            sys.exit("macos-sdk: expected one top-level Payload in the package")
        data = entry[0].find("data")
        if data.find("encoding").get("style") != "application/octet-stream":
            sys.exit("macos-sdk: unexpected Payload encoding")
        archived = data.find("archived-checksum")
        if archived.get("style") != "sha1":
            sys.exit("macos-sdk: Payload checksum is not SHA-1")
        f.seek(heap + int(data.findtext("offset")))
        left, h = int(data.findtext("length")), hashlib.sha1()
        with open(dst, "wb") as out:
            while left:
                chunk = f.read(min(left, 1 << 20))
                if not chunk:
                    sys.exit("macos-sdk: truncated Payload")
                h.update(chunk)
                out.write(chunk)
                left -= len(chunk)
        if h.hexdigest() != archived.text.strip():
            sys.exit("macos-sdk: Payload does not match its SHA-1 in the table of contents")


def title(product):
    dist = product.get("Distributions", {}).get("English")
    if not dist:
        return ""
    m = re.search(rb'"SU_TITLE"\s*=\s*"([^"]*)"', get(dist))
    return m.group(1).decode() if m else ""


def newest(package):
    catalog = plistlib.loads(gzip.decompress(get(CATALOG)))
    found = []
    for pid, product in catalog["Products"].items():
        for pkg in product.get("Packages", []):
            if pkg["URL"].rsplit("/", 1)[-1] == package:
                found.append((product["PostDate"], pid, product, pkg))
    for _, pid, product, pkg in sorted(found, key=lambda x: x[0], reverse=True):
        name = title(product)
        if name.startswith("Command Line Tools for Xcode") and "beta" not in name.lower():
            return pid, name, pkg
    sys.exit(f"macos-sdk: no Command Line Tools product ships {package}")


def pbzx(src, dst):
    """Decode Apple's pbzx stream (chunked xz) into a plain cpio archive."""
    with open(src, "rb") as f, open(dst, "wb") as out:
        if f.read(4) != b"pbzx":
            sys.exit("macos-sdk: Payload is not a pbzx stream")
        f.read(8)  # flags
        while header := f.read(16):
            if len(header) != 16:
                sys.exit("macos-sdk: truncated pbzx chunk header")
            length = int.from_bytes(header[8:], "big")
            data = f.read(length)
            if len(data) != length:
                sys.exit("macos-sdk: truncated pbzx chunk")
            out.write(lzma.decompress(data) if data.startswith(b"\xfd7zXZ\x00") else data)


def main():
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    out = os.path.abspath(sys.argv[1])
    package = sys.argv[2] if len(sys.argv) == 3 else "CLTools_macOSNMOS_SDK.pkg"
    pid, name, pkg = newest(package)
    log(f"{name} ({pid}): {package}, {pkg['Size']} bytes, sha1 {pkg['Digest']}")

    work = tempfile.mkdtemp(prefix="macos-sdk-")
    try:
        download(pkg["URL"], f"{work}/sdk.pkg", pkg["Size"])
        xar_payload(f"{work}/sdk.pkg", pkg["Digest"], f"{work}/Payload")
        os.remove(f"{work}/sdk.pkg")
        pbzx(f"{work}/Payload", f"{work}/payload.cpio")
        os.remove(f"{work}/Payload")
        os.mkdir(f"{work}/root")
        subprocess.run(["bsdtar", "-xf", f"{work}/payload.cpio", "-C", f"{work}/root"], check=True)

        sdks = f"{work}/root/Library/Developer/CommandLineTools/SDKs"
        real = [d for d in os.listdir(sdks)
                if re.fullmatch(r"MacOSX[0-9.]+\.sdk", d) and not os.path.islink(f"{sdks}/{d}")]
        if len(real) != 1:
            sys.exit(f"macos-sdk: expected one SDK in the package, found {sorted(os.listdir(sdks))}")
        with open(f"{sdks}/{real[0]}/SDKSettings.plist", "rb") as f:
            version = plistlib.load(f)["Version"]
        if not re.fullmatch(r"[0-9]+(\.[0-9]+){1,2}", version):
            sys.exit(f"macos-sdk: unexpected SDK version {version!r}")

        os.makedirs(out, exist_ok=True)
        target = f"MacOSX{version}.sdk"
        shutil.move(f"{sdks}/{real[0]}", f"{out}/{target}")
        os.symlink(target, f"{out}/MacOSX.sdk")
        with open(f"{out}/VERSION", "w") as f:
            f.write(version + "\n")
        log(f"SDK {version} in {out}/{target}")
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
