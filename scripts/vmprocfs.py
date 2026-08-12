#!/usr/bin/env python3
"""The guest's /proc, mounted on the host.

A dashboard, a profiler's companion, anything that reads /proc reads *this*
machine's kernel. Point it at a process inside a VM and it silently describes
the wrong machine - the host's load, the host's memory, the host's threads -
and looks perfectly healthy while doing it.

This mounts the guest's /proc somewhere on the host. Reads go over the same
vsock exec channel everything else uses, so nothing new has to run in the
guest and nothing needs root.

Anything the guest does not have falls through to the host's real /proc. That
is what lets an unmodified tool work: /proc/self, /proc/version and the rest
still answer, while the pid you care about comes from the VM.

    vmprocfs.py <uds> <port> <mountpoint> [--ttl 1.0] [--foreground]

Reads are cached for --ttl seconds, per directory rather than per file: a
dashboard walking fifty threads' stat files would otherwise be fifty round
trips per refresh, and one tar of the directory is a single one.
"""

import base64
import errno
import os
import stat
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

try:
    from fuse import FUSE, FuseOSError, Operations
except ImportError:
    sys.exit("vmprocfs: needs fusepy (pip install fusepy)")

HERE = os.path.dirname(os.path.abspath(__file__))
VSOCK_EXEC = os.path.join(HERE, "vsock-exec.py")

# One round trip per directory, and strictly one level deep.
#
# Depth matters more than it looks: /proc recursed into is every process, every
# thread of every process, and /proc/kcore - which advertises itself as the
# size of physical memory. Asking for a directory's whole subtree is fine for
# /proc/<pid>/task and ruinous for /proc, and the caller cannot tell which it
# is asking for. So: names of everything, contents of the plain files sitting
# directly inside, nothing else.
#
# Read with base64 straight off the file rather than staged and tarred: a
# /proc file reports a size of zero, which tar believes and copies nothing of,
# but a plain read returns what is actually there.
# Names only. Listing a directory must never read what is in it: /proc holds a
# few hundred entries, several of them expensive, and `ls` of the mount would
# sit there reading all of them - which it did.
LIST = r'''
set -u
src=%s
[ -d "$src" ] || { echo NOTDIR >&2; exit 4; }
for e in "$src"/*; do
	[ -e "$e" ] || continue
	if [ -d "$e" ]; then printf 'D %%s\n' "${e##*/}"; else printf 'N %%s\n' "${e##*/}"; fi
done
printf 'OK\n'
'''

# Contents, of the file asked for and - when it pays - of its siblings too.
#
# Siblings because of how these files are actually read: a dashboard walking
# fifty threads' stat files wants fifty files from one directory, and asking
# for them one at a time is fifty round trips per refresh. One call covers the
# walk.
#
# Only under a pid, though. The top of /proc holds a few hundred files, some of
# them slow (timer_list, pagetypeinfo) and some enormous, so prefetching them
# to answer a read of /proc/meminfo took longer than the exec timeout - and a
# timeout falls through to the host, which answers the same question about the
# wrong machine. One file is one file up there.
READ = r'''
set -u
src=%s
d=$(dirname "$src")
case "$d" in
*/[0-9]*) group="$d"/* ;;
*) group="" ;;
esac
n=0
for f in "$src" $group; do
	[ -f "$f" ] || continue
	case "$f" in
	*/kcore | */kpagecount | */kpageflags | */pagemap | */mem | */kmsg | */clear_refs) continue ;;
	esac
	sz=$(stat -Lc %%s "$f" 2>/dev/null || echo 0)
	[ "$sz" -gt 1048576 ] && continue
	printf 'F %%s %%s\n' "$f" "$(base64 -w0 <"$f" 2>/dev/null)"
	n=$((n + 1))
	[ "$n" -ge 400 ] && break
done
printf 'OK\n'
'''


class Guest:
    """What the VM says its /proc holds, remembered briefly."""

    def __init__(self, uds, port, ttl):
        self.uds, self.port, self.ttl = uds, port, ttl
        self.lock = threading.Lock()
        self.files = {}      # path -> bytes
        self.dirs = {}       # dir path -> set(names)
        self.subdirs = set()  # paths known to be directories
        self.listed = {}     # dir path -> when it was listed
        self.fetched = {}    # file path -> when it was read
        self.missing = {}    # path -> when it was found to be absent

    def _run(self, script):
        try:
            out = subprocess.run(
                ["python3", VSOCK_EXEC, self.uds, str(self.port), "-", script],
                capture_output=True, timeout=30)
        except (subprocess.SubprocessError, OSError):
            return None
        return out.stdout if out.returncode == 0 else None

    def _fresh(self, path, book):
        now = time.time()
        when = book.get(path)
        return when is not None and now - when < self.ttl

    def listdir(self, path):
        """Names in a guest directory. Never reads their contents."""
        with self.lock:
            if self._fresh(path, self.listed):
                return self.dirs.get(path)
            if self._fresh(path, self.missing):
                return None

        payload = self._run(LIST % shell_quote(path))
        with self.lock:
            self.listed[path] = time.time()
            if not payload or not payload.rstrip().endswith(b"OK"):
                self.missing[path] = time.time()
                return None
            self.missing.pop(path, None)
            names = set()
            for line in payload.splitlines():
                if line[:2] in (b"N ", b"D "):
                    name = line[2:].decode("utf-8", "replace")
                    names.add(name)
                    if line[:2] == b"D ":
                        self.subdirs.add(os.path.join(path, name))
            self.dirs[path] = names
            return names

    def readfile(self, path):
        """Contents of a guest file, its siblings pulled along with it."""
        with self.lock:
            if self._fresh(path, self.fetched):
                return self.files.get(path)
            if self._fresh(path, self.missing):
                return None

        payload = self._run(READ % shell_quote(path))
        now = time.time()
        with self.lock:
            self.fetched[path] = now
            if not payload or not payload.rstrip().endswith(b"OK"):
                self.missing[path] = now
                return None
            for line in payload.splitlines():
                if not line.startswith(b"F "):
                    continue
                rest = line[2:].split(b" ", 1)
                name = rest[0].decode("utf-8", "replace")
                try:
                    self.files[name] = base64.b64decode(
                        rest[1], validate=False) if len(rest) > 1 else b""
                except ValueError:
                    self.files[name] = b""
                # A sibling pulled along is as fresh as the one asked for.
                self.fetched[name] = now
                self.missing.pop(name, None)
            self.missing.pop(path, None)
            return self.files.get(path)


def shell_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"


class VmProc(Operations):
    """Guest first, host underneath.

    Falling through rather than returning ENOENT is the whole point: a tool
    that cannot read /proc/self or /proc/stat does not degrade, it breaks, and
    then the answer to "does this work against a VM" is no for reasons that
    have nothing to do with the VM.
    """

    def __init__(self, guest, under="/proc"):
        self.guest = guest
        self.under = under

    def _guest_path(self, path):
        return os.path.normpath(os.path.join("/proc", path.lstrip("/")))

    def _host_path(self, path):
        return os.path.normpath(os.path.join(self.under, path.lstrip("/")))

    def _attr(self, isdir, size):
        now = time.time()
        return {"st_mode": (stat.S_IFDIR | 0o555) if isdir else (stat.S_IFREG | 0o444),
                "st_nlink": 2 if isdir else 1, "st_size": size,
                "st_mtime": now, "st_ctime": now, "st_atime": now,
                "st_uid": os.getuid(), "st_gid": os.getgid()}

    def getattr(self, path, fh=None):
        gp = self._guest_path(path)
        if gp == "/proc":
            return self._attr(True, 0)

        # The parent's listing answers "does this exist, and is it a
        # directory" for every child at once - one round trip for a walk
        # rather than one per entry.
        parent, name = os.path.dirname(gp), os.path.basename(gp)
        names = self.guest.listdir(parent)
        if names is not None and name in names:
            if gp in self.guest.subdirs:
                return self._attr(True, 0)
            # Size without reading the file. Reading one to answer stat() is a
            # round trip per entry, and `ls` of /proc is several hundred of
            # them - which is minutes, and looks exactly like a hang.
            #
            # Real procfs reports 0 here and the kernel special-cases it; FUSE
            # has no such exception and a 0 makes every read return nothing.
            # So: claim a page, and let read() end the file where the data
            # actually ends. Everything that reads to EOF is happy; only
            # something trusting st_size without reading would be wrong, and
            # on /proc that is wrong anyway.
            return self._attr(False, 4096)
        try:
            st = os.lstat(self._host_path(path))
        except OSError as exc:
            raise FuseOSError(exc.errno or errno.ENOENT)
        return {k: getattr(st, k) for k in (
            "st_mode", "st_nlink", "st_size", "st_mtime", "st_ctime",
            "st_atime", "st_uid", "st_gid")}

    def readdir(self, path, fh):
        gp = self._guest_path(path)
        names = {".", ".."}
        guest_names = self.guest.listdir(gp)
        if guest_names:
            names |= guest_names
        try:
            names |= set(os.listdir(self._host_path(path)))
        except OSError:
            pass
        return sorted(names)

    def read(self, path, size, offset, fh):
        gp = self._guest_path(path)
        data = self.guest.readfile(gp)
        if data is None:
            try:
                with open(self._host_path(path), "rb") as f:
                    f.seek(offset)
                    return f.read(size)
            except OSError as exc:
                raise FuseOSError(exc.errno or errno.ENOENT)
        return data[offset:offset + size]

    def readlink(self, path):
        try:
            return os.readlink(self._host_path(path))
        except OSError as exc:
            raise FuseOSError(exc.errno or errno.ENOENT)

    def open(self, path, flags):
        if flags & (os.O_WRONLY | os.O_RDWR):
            raise FuseOSError(errno.EROFS)
        return 0

    # Read-only, and explicitly so: this describes a machine, it does not
    # configure one.
    def write(self, *a):
        raise FuseOSError(errno.EROFS)

    def truncate(self, *a):
        raise FuseOSError(errno.EROFS)

    def unlink(self, *a):
        raise FuseOSError(errno.EROFS)


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    uds, port, mountpoint = argv[0], int(argv[1]), argv[2]
    ttl = 1.0
    if "--ttl" in argv:
        ttl = float(argv[argv.index("--ttl") + 1])
    foreground = "--foreground" in argv or "-f" in argv

    os.makedirs(mountpoint, exist_ok=True)
    guest = Guest(uds, port, ttl)
    FUSE(VmProc(guest), mountpoint, foreground=foreground, ro=True,
         nothreads=False, allow_other=False)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
