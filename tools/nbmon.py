#!/usr/bin/env python3
"""NBMON host tool: drives the COM1 monitor of our SeaBIOS (seabios-486 src/nbmon.c).

The line: a tty (--tty /dev/ttyUSBn, set to 115200 8N1 raw), or for 86Box a file read as it grows and a pipe written
(--rx <vm>/serial.log --tx <vm>/com1.in; --from-start: read the file from its start, else from its end). All traffic
goes to --log (default nbmon.log), "<" in, ">" out.
Subcommands:
  wait [SECONDS]        wait for "NBMON ready", send "nbmon", confirm with "rb 0"
  cmd "<line>"          one monitor command: its data lines on stdout, exit 1 on ERR
  load FILE ADDR        "ld" lines of 128 bytes, then "crc" against the file's CRC32
  call ADDR [ARG]       the payload's lines, then its return value
  boot | reset
  loop SCRIPT [COUNT]   at each "NBMON ready" (after a crash or reset too): enter, run SCRIPT's lines (subcommands
                        as above), COUNT times (default: for ever)
"""
import os
import select
import sys
import termios
import time
import zlib


class Line:
    def __init__(self, tty, rx, tx, log, from_start):
        if tty:
            self.rfd = self.wfd = os.open(tty, os.O_RDWR | os.O_NOCTTY)
            attrs = termios.tcgetattr(self.rfd)
            attrs[0] = attrs[1] = attrs[3] = 0
            attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
            attrs[4] = attrs[5] = termios.B115200
            termios.tcsetattr(self.rfd, termios.TCSANOW, attrs)
            termios.tcflush(self.rfd, termios.TCIFLUSH)
            self.file = False
        else:
            self.rfd = os.open(rx, os.O_RDONLY | os.O_NONBLOCK)
            self.wfd = None   # 86Box makes its pipe when it starts: opened at the first send
            self.tx = tx
            self.file = os.path.isfile(rx)
            if self.file and not from_start:
                os.lseek(self.rfd, 0, os.SEEK_END)
        self.log = open(log, "a")
        self.buf = b""

    def send(self, text):
        self.log.write("> %s\n" % text)
        self.log.flush()
        if self.wfd is None:
            self.wfd = os.open(self.tx, os.O_WRONLY)
        data = (text + "\r").encode()
        for off in range(0, len(data), 8):   # 86Box delivers a byte per bit time: the polled UART needs the pauses
            os.write(self.wfd, data[off:off + 8])
            time.sleep(0.002)

    def read_line(self, timeout):
        """The next non-empty line, or None after timeout seconds (None: wait)."""
        end = None if timeout is None else time.monotonic() + timeout
        while True:
            for sep in (b"\n", b"\r"):
                if sep in self.buf:
                    text, self.buf = self.buf.split(sep, 1)
                    text = text.strip(b"\r\n").decode("ascii", "replace")
                    if text:
                        self.log.write("< %s\n" % text)
                        self.log.flush()
                        return text
            left = None if end is None else end - time.monotonic()
            if left is not None and left <= 0:
                return None
            if self.file:
                data = os.read(self.rfd, 4096)
                if not data:
                    time.sleep(0.01)
            else:
                ready, _, _ = select.select([self.rfd], [], [], left)
                data = os.read(self.rfd, 4096) if ready else b""
            self.buf += data

    def command(self, text, timeout=10):
        """Data lines of one command; raises on ERR or no answer."""
        self.send(text)
        data = []
        while True:
            line = self.read_line(timeout)
            if line is None:
                raise RuntimeError("no answer to %r" % text)
            if line == "OK":
                return data
            if line.startswith("ERR"):
                raise RuntimeError("%s: %s" % (text, line))
            data.append(line)

    def wait_ready(self, timeout):
        while True:
            line = self.read_line(timeout)
            if line is None:
                raise RuntimeError("no NBMON ready")
            if line.startswith("NBMON ready"):
                self.command("nbmon", 3)
                self.command("rb 0")
                return line.split()[2]


def load(line, path, addr):
    blob = open(path, "rb").read()
    for off in range(0, len(blob), 128):
        line.command("ld %x %s" % (addr + off, blob[off:off + 128].hex()))
    crc = int(line.command("crc %x %x" % (addr, len(blob)))[0], 16)
    if crc != zlib.crc32(blob):
        raise RuntimeError("crc %08x, the file's %08x" % (crc, zlib.crc32(blob)))


def run(line, args):
    op = args[0]
    if op == "wait":
        print(line.wait_ready(float(args[1]) if len(args) > 1 else 120))
    elif op == "cmd":
        for text in line.command(" ".join(args[1:])):
            print(text)
    elif op == "load":
        load(line, args[1], int(args[2], 16))
    elif op == "call":
        for text in line.command("call " + " ".join(args[1:]), 60):
            print(text)
    elif op in ("boot", "reset"):
        line.command(op)
    else:
        raise RuntimeError("unknown subcommand " + op)


def main(argv):
    opts = {"--tty": None, "--rx": None, "--tx": None, "--log": "nbmon.log"}
    from_start = False
    while argv and (argv[0] in opts or argv[0] == "--from-start"):
        if argv[0] == "--from-start":
            from_start, argv = True, argv[1:]
        else:
            opts[argv[0]], argv = argv[1], argv[2:]
    if not argv or not (opts["--tty"] or (opts["--rx"] and opts["--tx"])):
        sys.exit(__doc__)
    line = Line(opts["--tty"], opts["--rx"], opts["--tx"], opts["--log"], from_start)
    try:
        if argv[0] == "loop":
            script = [s.split() for s in open(argv[1]) if s.strip() and not s.startswith("#")]
            count = int(argv[2]) if len(argv) > 2 else -1
            while count:
                print("ready " + line.wait_ready(None), flush=True)
                for args in script:
                    run(line, args)
                count -= 1
        else:
            run(line, argv)
    except RuntimeError as err:
        sys.exit("nbmon: %s" % err)


if __name__ == "__main__":
    main(sys.argv[1:])
