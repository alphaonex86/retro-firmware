# retro-firmware — open BIOSes for old PC boards, and the 86Box fork that tests them

One coreboot + SeaBIOS firmware for several boards, and one 86Box fork that emulates each of them closely enough to
run both our firmware and the board's original BIOS. Hardware specifics are selected per board; what is not
specific (setup utility, USB, PXE, ATA/LBA48, optional AT keyboard, POST codes, tests) is shared.

| Board | CPU / chipset | Firmware here | 86Box machine |
|---|---|---|---|
| [Biostar MB-8433UUD-A](boards/mb8433uud/README.md) | 486/Am5x86, UMC UM8881F + UM8886BF | mb-8433UUD (coreboot + SeaBIOS), flashed on the real board | `84xxuuda` |
| [IBM Aptiva A90 (2168)](boards/aptiva2168/README.md) | Pentium P54C, OPTi Viper-M | not started (the IBM BIOS runs in 86Box) | `aptiva2168` |
| [ASUS P3B-F](boards/p3bf/README.md) | Pentium II/III (Slot 1), Intel 440BX | mainline coreboot (asus/p2b) + SeaBIOS, 256 KiB | `p3bf` |

## Layout

- Submodules, each a GitHub fork (one repository per project, one branch per base) with our commits over the
  pinned upstream:

  | Submodule | Fork, branch | Upstream base | Used by |
  |---|---|---|---|
  | `86box` | [alphaonex86/86Box](https://github.com/alphaonex86/86Box) `retro` | 86Box master (after v6.0) | every board (one machine each) |
  | `coreboot-486` | [alphaonex86/coreboot](https://github.com/alphaonex86/coreboot) `retro-486` | pc2005cz/coreboot_486 `486` | 486 boards |
  | `seabios-486` | [alphaonex86/seabios](https://github.com/alphaonex86/seabios) `retro-486` | pc2005cz/seabios_486 `486` | 486 boards |
  | `coreboot-mainline` | [alphaonex86/coreboot](https://github.com/alphaonex86/coreboot) `retro-mainline` | coreboot 26.09 | Slot 1 / Socket 370 boards |
  | `seabios-mainline` | [alphaonex86/seabios](https://github.com/alphaonex86/seabios) `retro-mainline` | SeaBIOS rel-1.17.0 | Slot 1 / Socket 370 boards |
  | `ipxe` | [alphaonex86/ipxe](https://github.com/alphaonex86/ipxe) `retro` | iPXE | network boot |
  | `flashrom` | [alphaonex86/flashrom](https://github.com/alphaonex86/flashrom) `retro` | flashrom v1.7.0 | BIOS update from Linux (`tools/build_flashrom.sh`, `tools/bios-update.sh`) |

  Bases by family: 486 and Socket 7 (128 KiB flash, i586 at most: built for the i486 instruction set, i586 features
  only after CPUID) use the 486 trees, the only coreboot cut to that size and with a cache-as-RAM that needs no MTRR;
  Slot 1 / Socket 370 (256 KiB, P6) use mainline (i686, MTRR cache-as-RAM, the i440BX code and the ASUS P2B family;
  without CPU microcode in CBFS to fit). Each base is a pair `coreboot-<base>` / `seabios-<base>` on branches
  `retro-<base>` of the same forks; the board's `firmware.sh` names its pair (`trees ...`); each coreboot tree has
  its own cross compiler (`tools/build_toolchain.sh <tree>`: mainline needs GCC 15).
  Change a fork with commits in its submodule, push its branch (pull requests to the upstream go from there), then
  commit the new submodule pointer here. 86box, the coreboot trees, ipxe and flashrom are shallow (only the pinned commit
  is fetched); the seabios trees are not: their version string needs the tags.
- `boards/<board>/`: everything about one board: `firmware.sh` (its build recipe: firmware trees, coreboot mainboard,
  config, flash layout), `run_86box.sh` (its VM), `test/`, its documents and release scripts.
- Shared: `build.sh [board]`, `build_86box.sh`, `fetch_sources.sh`, `seabios.config`, `tools/`, `test/` (`lib.sh`, and
  the MB-8433UUD-A tests), `test/run_all.sh` (every test of every board).

## Use

- `git submodule update --init` (or any build: `fetch_sources.sh` does it), then `./build.sh [board]` → `out/`.
- `test/run_all.sh`: builds what is missing and runs all tests in parallel, one 86Box per core.
- Where the bytes of a ROM go: `tools/filelight.sh [rom]` opens Filelight on a tree made in RAM (`/dev/shm`, removed
  when Filelight closes): CBFS entry, source file, function or variable, each file 1024 times its bytes in the ROM
  (Filelight counts 4 KiB disk blocks): its MiB are KiB of ROM; each CONFIG option that can be cut (the setup tools
  `CONFIG_NEWBIOS_TOOL_*`, existing SeaBIOS options) is a top-level directory of what it saves.
- What each CONFIG option saves, as a table: `tools/option_sizes.sh [rom [option...]]` (one SeaBIOS build per option).
- `boards/<board>/run_86box.sh [rom]`: the board in the 86Box fork (Qt GUI).

Licenses: the scripts, tests and documents here GPL-3.0 (`LICENSE`); the forks keep their projects' licenses
(coreboot GPL-2.0, SeaBIOS LGPL-3.0, 86Box GPL-2.0-or-later, iPXE GPL-2.0). No BIOS image or ROM is distributed.
