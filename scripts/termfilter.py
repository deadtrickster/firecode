#!/usr/bin/env python3
"""Filter what a guest writes to your terminal.

Anything the guest prints is attacker-controlled text arriving at a program -
your terminal emulator - that executes some of it. The families that matter:

  OSC 52    sets the clipboard. A guest can put whatever it likes on it, and
            on terminals that allow reads, ask for what is on it already.
  OSC 10/11 and other queries make the *terminal* write a reply into the input
            stream. That reply is read by whatever holds the tty - the guest
            while it runs, your shell after it exits.
  DCS/APC/  carry payloads to the terminal, up to and including "define this
  PM/SOS    key to type the following", which survives the session.

Rendering is left alone: CSI (cursor, colour, scrolling) and OSC 0/1/2 (the
window title) pass through, because without them a TUI cannot draw at all.

Two strengths, because the two paths differ. An interactive session is a TUI
and needs the escape sequences it uses to render; an unattended run is a log
and needs none, so nothing but text gets through.

usage: termfilter.py [--strict] < in > out
"""

import sys

ESC = 0x1B


class Filter:
    """Feed it bytes, get back what is safe to show. Sequences split across
    reads are held until they complete, so a filter cannot be walked past by
    breaking one in half."""

    def __init__(self, strict=False):
        self.strict = strict
        self.buf = bytearray()

    def feed(self, data: bytes) -> bytes:
        self.buf += data
        out = bytearray()
        i = 0
        n = len(self.buf)

        while i < n:
            b = self.buf[i]

            if b != ESC:
                # Plain text. In strict mode keep only what a log needs.
                if not self.strict or b in (0x09, 0x0A, 0x0D) or 0x20 <= b < 0x7F or b >= 0x80:
                    out.append(b)
                i += 1
                continue

            # An escape sequence starts here; find where it ends.
            end, kind = self._scan(i, n)
            if end is None:
                break  # incomplete - keep it for the next read
            if kind == "keep" and not self.strict:
                out += self.buf[i:end]
            i = end

        del self.buf[:i]
        return bytes(out)

    def _scan(self, i, n):
        """Returns (index just past the sequence, "keep"|"drop"), or (None, _)
        when the sequence is not all here yet."""
        if i + 1 >= n:
            return None, None
        b1 = self.buf[i + 1]

        # CSI: ESC [ ... final byte in @-~. Cursor movement, colour, erase.
        if b1 == 0x5B:
            j = i + 2
            while j < n and not (0x40 <= self.buf[j] <= 0x7E):
                j += 1
            if j >= n:
                return None, None
            # A request the terminal answers - device attributes, cursor
            # position. The reply goes to whoever holds the tty, which during
            # a session is the guest itself, so this is only worth blocking
            # where no interactive program is running. A TUI genuinely needs
            # these: it is how it works out what the terminal can do, and
            # blocking them is what leaves Enter mis-decoded.
            if self.strict and self.buf[j] in (0x63, 0x6E):  # c, n
                return j + 1, "drop"
            return j + 1, "keep"

        # OSC: ESC ] Ps ; payload (BEL | ESC \)
        if b1 == 0x5D:
            j = i + 2
            ps = bytearray()
            while j < n and self.buf[j] not in (0x3B, 0x07) and self.buf[j] != ESC:
                ps.append(self.buf[j])
                j += 1
            # find the terminator
            k = j
            while k < n:
                if self.buf[k] == 0x07:
                    end = k + 1
                    break
                if self.buf[k] == ESC and k + 1 < n and self.buf[k + 1] == 0x5C:
                    end = k + 2
                    break
                if self.buf[k] == ESC and k + 1 >= n:
                    return None, None
                k += 1
            else:
                return None, None
            try:
                code = int(ps)
            except ValueError:
                code = -1
            # Only the window title. Not 52 (clipboard), not the colour
            # queries, not anything that answers back.
            return end, "keep" if code in (0, 1, 2) else "drop"

        # DCS, SOS, PM, APC: ESC P / X / ^ / _ ... ESC \
        if b1 in (0x50, 0x58, 0x5E, 0x5F):
            k = i + 2
            while k < n:
                if self.buf[k] == ESC and k + 1 < n and self.buf[k + 1] == 0x5C:
                    return k + 2, "drop"
                if self.buf[k] == ESC and k + 1 >= n:
                    return None, None
                k += 1
            return None, None

        # Two-byte escapes: charset selection, keypad mode, RIS.
        if b1 == 0x63:  # ESC c - full reset, wipes the scrollback
            return i + 2, "drop"
        return i + 2, "keep"


def main():
    strict = "--strict" in sys.argv
    f = Filter(strict=strict)
    out = sys.stdout.buffer
    while True:
        chunk = sys.stdin.buffer.read(4096)
        if not chunk:
            break
        out.write(f.feed(chunk))
        out.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
