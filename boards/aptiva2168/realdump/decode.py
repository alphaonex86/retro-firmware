#!/usr/bin/env python3
"""Print a realdump DUMP.BIN (or the whole floppy image) as text; -x DIR also writes each record's raw data there.
usage: decode.py [-x DIR] DUMP.BIN|floppy.img"""
import struct
import sys
from pathlib import Path


def load(path):
    data = Path(path).read_bytes()
    if data[:4] != b'RDMP' and len(data) >= 1474560:   # a floppy image: DUMP.BIN starts at cluster 2
        reserved, fats, root_entries = struct.unpack_from('<HBH', data, 14)
        fat_sectors = struct.unpack_from('<H', data, 22)[0]
        root = (reserved + fats * fat_sectors) * 512
        data = data[root + root_entries * 32:]
    if data[:4] != b'RDMP':
        sys.exit('not a realdump dump (no RDMP header): the program did not run, or failed')
    total, checksum, version = struct.unpack_from('<III', data, 4)
    body = data[16:total]
    status = 'OK' if sum(body) & 0xffffffff == checksum else 'BAD'
    print(f'realdump layout {version}, {total} bytes, byte sum {checksum:08X} {status}')
    records, pos = [], 16
    while pos < total:
        tag, length = data[pos:pos + 4].decode('ascii'), struct.unpack_from('<I', data, pos + 4)[0]
        records.append((tag.strip(), data[pos + 8:pos + 8 + length]))
        pos += 8 + length
    return records


def hexdump(data, base=0, width=16):
    for i in range(0, len(data), width):
        print(f'  {base + i:04X}: ' + ' '.join(f'{b:02X}' for b in data[i:i + width]))


def eisa_id(raw):
    v = struct.unpack('>I', raw)[0]
    return ''.join(chr(64 + (v >> s & 31)) for s in (26, 21, 16)) + f'{v & 0xffff:04X}'


def rom_summary(rom):
    for off in range(0, len(rom), 2048):
        if rom[off:off + 2] == b'\x55\xaa' and rom[off + 2]:
            print(f'  option ROM at {0xC0000 + off:05X}, {rom[off + 2] * 512} bytes')
    for sig in (b'$PnP', b'_32_', b'$PIR', b'_MP_', b'_SM_', b'RSD PTR ', b'PCIR'):
        hits = [0xC0000 + i for i in range(0, len(rom), 16 if sig != b'PCIR' else 1) if rom[i:i + len(sig)] == sig]
        if hits:
            print(f'  {sig.decode():8} at ' + ' '.join(f'{h:05X}' for h in hits[:8]))


def show(tag, d, counts):
    counts[tag] = counts.get(tag, 0) + 1
    if tag == 'IVT':
        print('IVT (vector: segment:offset)')
        for i in range(0, 256, 8):
            print(f'  {i:02X}: ' + ' '.join('{1:04X}:{0:04X}'.format(*struct.unpack_from('<HH', d, 4 * v))
                                          for v in range(i, i + 8)))
    elif tag in ('BDA', 'CMS0', 'CMS1', 'CMS2'):
        name = {'BDA': 'BIOS data area 400h', 'CMS0': 'CMOS 00h-7Fh (70h/71h)',
                'CMS1': 'CMOS 80h-FFh (70h/71h, FDC37C93x LD6 F0h bit 7)', 'CMS2': 'CMOS via 72h/73h'}[tag]
        if tag == 'CMS0':
            name += f', port 70h read {d[0]:02X}'
            d = d[1:]
        print(name)
        hexdump(d, 0x400 if tag == 'BDA' else 0x80 if tag == 'CMS1' else 0)
    elif tag == 'EBDA':
        seg = struct.unpack_from('<H', d)[0]
        print(f'EBDA segment {seg:04X}, {len(d) - 2} bytes')
        hexdump(d[2:])
    elif tag == 'ROM':
        print(f'ROM C0000-FFFFF, {len(d)} bytes')
        rom_summary(d)
    elif tag == 'BIOS':
        int12, int11, f88, ax88, fe801, ax, bx, cx, dx = struct.unpack('<9H', d)
        print(f'BIOS: INT 12h {int12} KB, INT 11h equipment {int11:04X}')
        print(f'  INT 15h 88h: CF={f88 & 1} AX={ax88:04X} ({ax88} KB)')
        print(f'  INT 15h E801h: CF={fe801 & 1} AX={ax:04X} BX={bx:04X} CX={cx:04X} DX={dx:04X}')
    elif tag == 'CPU':
        if not d:
            print('CPUID: none')
            return
        maxleaf, b, dd, c, sig, b1, c1, d1 = struct.unpack('<8I', d)
        vendor = struct.pack('<III', b, dd, c).decode('ascii', 'replace')
        print(f'CPUID: {vendor}, max leaf {maxleaf}, signature {sig:08X} (family {sig >> 8 & 15}, '
              f'model {sig >> 4 & 15}, stepping {sig & 15}), EBX {b1:08X} ECX {c1:08X} EDX {d1:08X}')
    elif tag == 'E820':
        print(f'INT 15h E820h: {len(d) // 20} entries' + (' (unsupported)' if not d else ''))
        for i in range(0, len(d), 20):
            base, size, kind = struct.unpack_from('<QQI', d, i)
            print(f'  {base:016X} {size:016X} type {kind}')
    elif tag == 'PNPH':
        ver, length, ctl, cks, evt, roff, rseg, poff, pbase, oem, rdata, pdata = \
            struct.unpack_from('<BBHBIHHHIIHI', d, 4)
        print(f'$PnP header: version {ver >> 4}.{ver & 15}, length {length}, control {ctl:04X}, '
              f'real-mode entry {rseg:04X}:{roff:04X}, data segment {rdata:04X}, protected entry {pbase:X}+{poff:X}, '
              f'OEM ID {oem:08X}')
    elif tag == 'PNP0':
        ret, nodes, size = struct.unpack('<HBH', d)
        print(f'PnP function 00h: return {ret:04X}, {nodes} nodes, max node size {size}')
    elif tag == 'PNPN':
        node, ret = struct.unpack_from('<BH', d)
        if ret or len(d) < 15:
            print(f'PnP node {node:02X}: function 01h return {ret:04X}')
            return
        size, handle = struct.unpack_from('<HB', d, 3)
        dev, typ, attr = d[6:10], d[10:13], struct.unpack_from('<H', d, 13)[0]
        print(f'PnP node {handle:02X}: {eisa_id(dev)}, type {typ[0]:02X}.{typ[1]:02X}.{typ[2]:02X}, '
              f'attributes {attr:04X}, {size} bytes')
        hexdump(d[15:3 + size])
    elif tag == 'PCI':
        devfn, cfg = d[0], d[1:]
        vid, did = struct.unpack_from('<HH', cfg)
        print(f'PCI 00:{devfn >> 3:02X}.{devfn & 7} {vid:04X}:{did:04X} class {cfg[11]:02X}{cfg[10]:02X}{cfg[9]:02X}')
        hexdump(cfg)
    elif tag == '557M':
        print(f'82C557M/558M index registers (22h/24h), port 22h read {d[0]:02X}')
        hexdump(d[1:])
    elif tag == 'GPIO':
        if len(d) == 1:
            print(f'Super I/O GPIO (EAh/EBh): not read, CR03 = {d[0]:02X} (bit 7 clear or base not EAh)')
            return
        print(f'Super I/O GPIO (EAh index / EBh data): CR03 = {d[0]:02X}, port EAh read {d[1]:02X}; '
              f'GP1x (index 1) {d[3]:02X}, GP2x (index 2) {d[4]:02X} (JP2 bus speed on GP21/GP20: '
              + {0: '66 MHz', 2: '60 MHz', 3: '50 MHz'}.get(d[4] & 3, '?') + f'), WDT_CTRL (index 3) {d[5]:02X}; all indexes:')
        hexdump(d[2:])
    elif tag == 'IDE':
        print('IDE status: 1F7h={:02X} 3F6h={:02X} 177h={:02X} 376h={:02X}'.format(*d))
    elif tag == 'CYRX':
        print('Cyrix registers (22h/23h): ' + ' '.join(f'{i:02X}={v:02X}' for i, v in
                                                      zip(list(range(0xC0, 0xD0)) + [0xE8, 0xFE, 0xFF], d)))
    elif tag == 'SIO':
        base = struct.unpack_from('<H', d)[0]
        if not base:
            print('Super I/O: no answer at 370h')
            return
        g = d[2:0x32]
        print(f'Super I/O at {base:03X}h: device ID {g[0x20]:02X}, revision {g[0x21]:02X}, '
              f'logical device on entry {g[7]:02X}; global 00h-2Fh:')
        hexdump(g)
        for ld in range(10):
            regs = d[0x32 + ld * 208:0x32 + (ld + 1) * 208]
            act, io, irq, dma = regs[0], regs[0x30] << 8 | regs[0x31], regs[0x40], regs[0x44]
            print(f'  LD{ld}: active {act:02X}, I/O {io:04X}, IRQ {irq:02X}, DMA {dma:02X}; 30h-FFh'
                  + (' (AAh, F5h not read: FFh)' if ld == 6 else ' (AAh not read: FFh)'))
            hexdump(regs, 0x30)
    elif tag == 'PORT':
        print('Ports: 92h={:02X} 61h={:02X} PIC1 IMR (21h)={:02X} PIC2 IMR (A1h)={:02X}'.format(*d))
        print(f'  IRQ unmasked: {[i for i in range(16) if not (d[2] | d[3] << 8) >> i & 1]}')
    elif tag == 'KBC':
        def cmd(i):
            return f'{d[i]:02X}' if not d[i + 1] else 'timeout'
        print(f'KBC: status {d[0]:02X}, command byte (20h) {cmd(1)}, input port (C0h) {cmd(3)}, '
              f'output port (D0h) {cmd(5)}, status after {d[7]:02X}')
    elif tag == 'END':
        print('END')
    else:
        print(f'unknown record {tag}, {len(d)} bytes')
        hexdump(d)


def main():
    args = sys.argv[1:]
    out = None
    if len(args) == 3 and args[0] == '-x':
        out = Path(args[1])
        args = args[2:]
    if len(args) != 1:
        sys.exit(__doc__)
    counts = {}
    for tag, d in load(args[0]):
        show(tag, d, counts)
        if out:
            out.mkdir(parents=True, exist_ok=True)
            (out / f'{tag.lower()}{counts[tag] - 1 if tag in ("PCI", "PNPN") else ""}.bin').write_bytes(d)


if __name__ == '__main__':
    main()
