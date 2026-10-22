#!/usr/bin/env python3
"""Where the bytes of a ROM go, as a directory tree to open with Filelight: one directory per CBFS entry, then per
source file, one file per function or variable. Filelight counts disk blocks (4 KiB here), so each file is 1024 times
the bytes it takes in the ROM, rounded to whole blocks: read Filelight's MiB as KiB of ROM, KiB as bytes.
An entry with an ELF (CBFS-NAME=ELF[,EXTRA@OFFSET...]) is split over its loaded sections and symbols; an EXTRA ELF
adds one symbol per section, at VMA + OFFSET (SeaBIOS's 16-bit code: rom16.o, one section per function, F000h-based); compressed entries (LZMA stages, payload) share
their compressed size in proportion. Bytes no symbol covers: mostly printable -> (strings)/<section>, else the tail of
the symbol before them (asm and 16-bit code have no size) -> <symbol>+tail, or (no symbol)/<section>.
(cbfs header): entry header and alignment. (free): empty CBFS space.
-g NAME=DIR:BYTES (tools/option_sizes.sh): DIR holds the same ELFs built without option NAME; the symbols and strings
they lack go to a top-level directory NAME, BYTES in all (what the option saves in the compressed entry).
usage: rom_size_tree.py [-g NAME=DIR:BYTES ...] ROM CBFSTOOL NM OBJDUMP OUTDIR [CBFS-NAME=ELF[,EXTRA@OFFSET...] ...]"""
import os, re, shutil, subprocess, sys

SCALE, BLOCK = 1024, 4096


def run(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True, check=True).stdout


def cbfs_entries(rom, cbfstool):
    entries = []
    for line in run(cbfstool, rom, 'print').splitlines():
        m = re.match(r'(\S+)\s+(0x[0-9a-f]+)\s+.+?\s+(\d+)\s+\S+', line)
        if m and m.group(1) != 'Name':
            entries.append({'name': m.group(1), 'offset': int(m.group(2), 16), 'size': int(m.group(3))})
    end = os.path.getsize(rom)
    for e, nxt in zip(entries, entries[1:] + [None]):
        e['total'] = (nxt['offset'] if nxt else end) - e['offset']
    return entries


def loaded_sections(elf, objdump):
    """-> [(name, vma, size, file offset)] of the sections with contents in memory"""
    lines = run(objdump, '-h', elf).splitlines()
    sections = []
    for line, flags in zip(lines, lines[1:]):
        m = re.match(r'\s*\d+\s+(\S+)\s+([0-9a-f]+)\s+([0-9a-f]+)\s+[0-9a-f]+\s+([0-9a-f]+)', line)
        if m and 'ALLOC' in flags and 'CONTENTS' in flags and not m.group(1).startswith('.debug') and int(m.group(2), 16):
            sections.append((m.group(1), int(m.group(3), 16), int(m.group(2), 16), int(m.group(4), 16)))
    return sections


def symbols(elf, extras, nm, objdump):
    """-> [(address, size, name, source path)]"""
    syms, seen = [], set()
    for extra in extras:   # one symbol per section of another ELF of the same code
        path, offset = extra.split('@')
        secs = loaded_sections(path, objdump)
        files = run(objdump.replace('objdump', 'addr2line'), '-e', path, *[hex(v) for _, v, _, _ in secs]).split()
        for (name, vma, size, _), f in zip(secs, files):
            seen.add(f'{vma + int(offset, 0):08x}')
            syms.append((vma + int(offset, 0), size, re.sub(r'^\.(text|data|rodata)\.', '', name),
                         os.path.normpath(f.rsplit(':', 1)[0]) if not f.startswith('??') else '(no source)'))
    for line in run(nm, '-S', '-l', '--defined-only', elf).splitlines():
        m = re.match(r'([0-9a-f]+) ([0-9a-f]+) [A-Za-z] (\S+)(?:\t(\S+?):\d+)?$', line)
        if m and m.group(1) not in seen:   # aliases counted once
            seen.add(m.group(1))
            syms.append((int(m.group(1), 16), int(m.group(2), 16), m.group(3), os.path.normpath(m.group(4) or '(no source)')))
    return syms


def option_group(elf, extras, nm, objdump, arg):
    """NAME=DIR:BYTES -> (name, bytes, symbol names and strings of the ELF built without it)"""
    name, rest = arg.split('=', 1)
    path, nbytes = rest.rsplit(':', 1)
    off = lambda f: os.path.join(path, os.path.basename(f))
    names = {s[2] for s in symbols(off(elf), [off(x.split('@')[0]) + '@' + x.split('@')[1] for x in extras], nm, objdump)}
    data = open(off(elf), 'rb').read()
    strings = set()
    for _, _, size, at in loaded_sections(off(elf), objdump):
        strings.update(data[at:at + size].split(b'\0'))
    return name, int(nbytes), names, strings


def elf_parts(elf, extras, nm, objdump, groups):
    """-> [(source path, name, bytes, group)] covering every loaded byte of the ELF; group: the first of groups whose
    build lacks it, else None"""
    data = open(elf, 'rb').read()
    sections = loaded_sections(elf, objdump)
    syms = symbols(elf, extras, nm, objdump)
    sym_group = lambda n: next((g[0] for g in groups if n not in g[2]), None)
    roots = [s[3] for s in syms if s[3].startswith('/')]
    root = os.path.commonpath(roots) if roots else ''
    rel = lambda f: os.path.relpath(f, root) if f.startswith('/') else f
    parts = []
    for name, vma, size, off in sections:
        cur, prev = vma, None
        def gap(start, end):
            raw = data[off + start - vma:off + end - vma]
            if sum(32 <= b < 127 or b in (0, 10, 13) for b in raw) >= 0.85 * len(raw):
                rest = end - start
                for s in raw.split(b'\0') if groups else []:
                    g = next((g[0] for g in groups if len(s) >= 4 and s not in g[3]), None)
                    if g:
                        parts.append(('(strings)', s[:40].decode('latin-1'), len(s) + 1, g))
                        rest -= len(s) + 1
                parts.append(('(strings)', f'{name}@{start:x}', rest, None))
            elif prev:
                parts.append((rel(prev[3]), prev[2] + '+tail', end - start, sym_group(prev[2])))
            else:
                parts.append(('(no symbol)', f'{name}@{start:x}', end - start, None))
        for s in sorted(s for s in syms if vma <= s[0] < vma + size):
            if s[0] > cur:
                gap(cur, s[0])
            n = min(s[0] + s[1], vma + size) - max(s[0], cur)
            if n > 0:
                parts.append((rel(s[3]), s[2], n, sym_group(s[2])))
                cur, prev = s[0] + s[1], s
        if cur < vma + size:
            gap(cur, vma + size)
    return parts


def write(path, nbytes):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    while os.path.exists(path):
        path += '_'
    with open(path, 'wb') as f:
        for _ in range(int(round(nbytes * SCALE / BLOCK))):
            f.write(b'\0' * BLOCK)


def main():
    args, group_args = sys.argv[1:], []
    while args[:1] == ['-g'] and len(args) > 1:
        group_args.append(args[1])
        args = args[2:]
    if len(args) < 5:
        sys.exit(__doc__)
    rom, cbfstool, nm, objdump, outdir = args[:5]
    elfs = dict(a.split('=', 1) for a in args[5:])
    if os.path.isdir(outdir):
        shutil.rmtree(outdir)
    for e in cbfs_entries(rom, cbfstool):
        name = e['name'].replace('/', '_')
        if e['name'] == '(empty)':
            write(os.path.join(outdir, '(free)', f'{e["offset"]:05x}'), e['total'])
            continue
        write(os.path.join(outdir, name, '(cbfs header)'), e['total'] - e['size'])
        if e['name'] not in elfs:
            write(os.path.join(outdir, name, name), e['size'])
            continue
        elf, *extras = elfs[e['name']].split(',')
        groups = [option_group(elf, extras, nm, objdump, g) for g in group_args] if e['name'] == 'fallback/payload' else []
        parts = elf_parts(elf, extras, nm, objdump, groups)
        loaded = sum(p[2] for p in parts)
        factor = e['size'] / loaded if loaded > e['size'] else 1.0   # compressed: the entry is smaller than its ELF
        # an option's directory holds the bytes it saves; the rest of the entry shares what is left
        raw = {g[0]: sum(p[2] for p in parts if p[3] == g[0]) for g in groups}
        scale = {g[0]: g[1] / raw[g[0]] if raw[g[0]] and g[1] > 0 else factor for g in groups}
        grouped = sum(raw[g] * scale[g] for g in raw)
        rest = loaded - sum(raw.values())
        scale[None] = (e['size'] - grouped) / rest if groups and rest > 0 and e['size'] > grouped else factor
        for src, sym, n, g in parts:
            write(os.path.join(outdir, g or name, src, re.sub(r'[^\w.$+@-]', '_', sym)), n * scale[g])
        write(os.path.join(outdir, name, '(unattributed)'), max(0, e['size'] - sum(p[2] * scale[p[3]] for p in parts)))


main()
