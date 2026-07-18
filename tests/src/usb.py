"""Build real (MBR-partitioned) USB disk images and attach them to QEMU.

The AmethystOS shell mounts a USB stick the way real firmware presents one: a
512-byte MBR at LBA 0 whose partition table points at a filesystem living
*inside* a partition (not a raw "superfloppy" filesystem at LBA 0). `fs_mount`
in src/kernel/commands_fs.asm walks that partition table, reads each entry's
start LBA, and validates the VBR there. So we build a genuine partitioned disk:

    LBA 0            : MBR + partition table (one bootable primary partition)
    LBA 2048 ..      : the FAT16 / FAT32 / exFAT / NTFS volume itself

and hand it to QEMU as an xHCI (USB3) mass-storage device, matching the OS's
xHCI + USB bulk-only transport stack.

Filesystem creation uses the host toolchain:
    fat16 / fat32 -> mtools `mformat`
    ntfs          -> `mkfs.ntfs`
    exfat         -> `mkfs.exfat` (exfatprogs); auto-fetched without root if
                     it isn't already on PATH (see _ensure_mkexfat).
"""

import os
import shutil
import struct
import subprocess
import sys
import tempfile

SRC_DIR = os.path.dirname(os.path.abspath(__file__))
TESTS_DIR = os.path.dirname(SRC_DIR)
CACHE_DIR = os.path.join(TESTS_DIR, ".cache")

SUPPORTED_FORMATS = ("fat16", "fat32", "exfat", "ntfs")

# First partition starts at the conventional 1 MiB boundary (LBA 2048).
PART_START_LBA = 2048
SECTOR = 512

# MBR partition type bytes the OS is happy to probe (it validates the VBR
# regardless, but real sticks carry sensible types, so we do too).
_PART_TYPE = {
    "fat16": 0x0E,  # FAT16 LBA
    "fat32": 0x0C,  # FAT32 LBA
    "exfat": 0x07,  # exFAT (same id as NTFS/IFS)
    "ntfs": 0x07,   # NTFS
}


def ram_backed_dir():
    """Return a RAM-backed scratch dir (never hits a real disk), or None.

    On Linux/WSL `/dev/shm` is a tmpfs living purely in memory, so an image
    built there is written to and read from RAM only and vanishes when freed.
    Returns None where no such tmpfs is writable (e.g. non-Linux hosts).
    """
    for cand in ("/dev/shm", "/run/shm"):
        if os.path.isdir(cand) and os.access(cand, os.W_OK):
            return cand
    return None


class UsbBuildError(RuntimeError):
    """Raised when a USB image cannot be built (missing tool, format fails)."""


def _run(cmd, **kw):
    """Run a subprocess, raising UsbBuildError with captured output on failure."""
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          text=True, **kw)
    if proc.returncode != 0:
        joined = " ".join(cmd)
        raise UsbBuildError(f"command failed ({proc.returncode}): {joined}\n{proc.stdout}")
    return proc.stdout


def _ensure_mkexfat():
    """Return a path to mkfs.exfat, fetching exfatprogs locally if needed.

    Prefers a system mkfs.exfat/mkexfatfs. If neither is installed, downloads
    the exfatprogs .deb with `apt-get download` (no root required) and unpacks
    just the binary into tests/.cache, caching it for subsequent runs.
    """
    for name in ("mkfs.exfat", "mkexfatfs"):
        found = shutil.which(name)
        if found:
            return found

    cached = os.path.join(CACHE_DIR, "usr", "sbin", "mkfs.exfat")
    if os.path.isfile(cached) and os.access(cached, os.X_OK):
        return cached

    if not shutil.which("apt-get") or not shutil.which("dpkg-deb"):
        raise UsbBuildError(
            "exFAT needs mkfs.exfat and it isn't installed; auto-fetch requires "
            "apt-get + dpkg-deb. Install it with: sudo apt install exfatprogs")

    os.makedirs(CACHE_DIR, exist_ok=True)
    with tempfile.TemporaryDirectory() as td:
        print("[*] fetching exfatprogs (mkfs.exfat) locally, no root needed...")
        _run(["apt-get", "download", "exfatprogs"], cwd=td)
        debs = [f for f in os.listdir(td) if f.endswith(".deb")]
        if not debs:
            raise UsbBuildError("apt-get download produced no .deb for exfatprogs")
        _run(["dpkg-deb", "-x", os.path.join(td, debs[0]), CACHE_DIR])

    if not os.path.isfile(cached):
        raise UsbBuildError(f"unpacked exfatprogs but {cached} is missing")
    os.chmod(cached, 0o755)
    return cached


def _tool_or_die(name, hint):
    path = shutil.which(name)
    if not path:
        raise UsbBuildError(f"required tool {name!r} not found on PATH ({hint})")
    return path


def _make_filesystem(fmt, part_path, part_sectors, label):
    """Format a partition-sized scratch file `part_path` as `fmt`."""
    if fmt == "fat32":
        # mtools -F forces FAT32; -c 8 keeps a sane cluster size at these sizes.
        _tool_or_die("mformat", "install mtools")
        _run(["mformat", "-i", part_path, "-F", "-c", "8", "-v", label[:11], "::"])
    elif fmt == "fat16":
        # No -F: let mtools pick FAT16, but force sectors/cluster high enough
        # that the cluster count stays under the 65525 FAT16 ceiling.
        _tool_or_die("mformat", "install mtools")
        _run(["mformat", "-i", part_path, "-c", "8", "-v", label[:11], "::"])
    elif fmt == "ntfs":
        mkntfs = shutil.which("mkfs.ntfs") or _tool_or_die("mkntfs", "install ntfs-3g")
        _run([mkntfs, "-Q", "-F", "-s", str(SECTOR), "-L", label, part_path])
    elif fmt == "exfat":
        mkexfat = _ensure_mkexfat()
        _run([mkexfat, "-L", label, part_path])
    else:
        raise UsbBuildError(f"unknown format {fmt!r}; expected one of {SUPPORTED_FORMATS}")


def _populate(fmt, part_path):
    """Drop a marker file into the fresh volume so `ls`/`cat` in the guest
    have something real to show. Best-effort: exFAT has no host-side copy
    tool without a FUSE mount, so it stays empty."""
    content = "Hello from the AmethystOS test harness!\n"
    if fmt in ("fat16", "fat32"):
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as tf:
            tf.write(content)
            src = tf.name
        try:
            _run(["mcopy", "-i", part_path, src, "::/HELLO.TXT"])
        finally:
            os.remove(src)
    elif fmt == "ntfs":
        ntfscp = shutil.which("ntfscp")
        if not ntfscp:
            return
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as tf:
            tf.write(content)
            src = tf.name
        try:
            _run([ntfscp, "-f", part_path, src, "HELLO.TXT"])
        finally:
            os.remove(src)


def _write_mbr(img_path, disk_sectors, part_type, part_start, part_sectors):
    """Write a one-entry MBR partition table into the first sector of img_path.

    The OS reads only the type byte, start-LBA and length from each 16-byte
    entry, so we fill the LBA fields exactly and give CHS a standard
    "use-LBA" sentinel (0xFE 0xFF 0xFF) rather than computing real geometry.
    """
    entry = bytearray(16)
    entry[0] = 0x80                                    # bootable flag
    entry[1:4] = bytes((0xFE, 0xFF, 0xFF))             # first CHS (LBA sentinel)
    entry[4] = part_type
    entry[5:8] = bytes((0xFE, 0xFF, 0xFF))             # last CHS (LBA sentinel)
    entry[8:12] = struct.pack("<I", part_start)        # start LBA
    entry[12:16] = struct.pack("<I", part_sectors)     # length in sectors

    with open(img_path, "r+b") as f:
        f.seek(446)
        f.write(entry)
        f.seek(510)
        f.write(b"\x55\xaa")


def build_usb_image(fmt, out_path, size_mb=128, label="AMETHYST"):
    """Create a partitioned USB disk image formatted as `fmt`.

    Returns out_path. Raises UsbBuildError on any failure.
    """
    fmt = fmt.lower()
    if fmt not in SUPPORTED_FORMATS:
        raise UsbBuildError(
            f"unsupported --usb format {fmt!r}; choose from {', '.join(SUPPORTED_FORMATS)}")

    disk_sectors = (size_mb * 1024 * 1024) // SECTOR
    part_sectors = disk_sectors - PART_START_LBA
    if part_sectors <= 0:
        raise UsbBuildError(f"--usb-size {size_mb}MB is too small for a partition")

    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)

    # 1) whole zeroed disk
    with open(out_path, "wb") as f:
        f.truncate(disk_sectors * SECTOR)

    # 2) format a partition-sized scratch file, then splice it in at the
    #    partition offset (avoids needing loopback/root to format in place).
    with tempfile.NamedTemporaryFile(prefix="amethyst-usb-", suffix=".part",
                                     delete=False) as pf:
        part_path = pf.name
        pf.truncate(part_sectors * SECTOR)
    try:
        print(f"[*] formatting {size_mb}MB {fmt.upper()} volume...")
        _make_filesystem(fmt, part_path, part_sectors, label)
        _populate(fmt, part_path)
        with open(part_path, "rb") as src, open(out_path, "r+b") as dst:
            dst.seek(PART_START_LBA * SECTOR)
            shutil.copyfileobj(src, dst, length=1024 * 1024)
    finally:
        try:
            os.remove(part_path)
        except OSError:
            pass

    # 3) real MBR partition table pointing at that volume
    _write_mbr(out_path, disk_sectors, _PART_TYPE[fmt], PART_START_LBA, part_sectors)

    print(f"[*] built USB image: {out_path} ({fmt.upper()}, {size_mb}MB)")
    return out_path


def usb_qemu_args(img_path):
    """QEMU args attaching img_path as a real xHCI USB3 mass-storage stick."""
    return [
        "-device", "qemu-xhci,id=xhci",
        "-drive", f"if=none,id=usbstick,format=raw,file={img_path}",
        "-device", "usb-storage,bus=xhci.0,drive=usbstick,removable=on",
    ]
