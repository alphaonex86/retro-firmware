# retro-firmware — open BIOSes for old PC boards, and the 86Box fork that tests them

One coreboot + SeaBIOS firmware for several boards, and one 86Box fork that emulates each of them closely enough to
run both our firmware and the board's original BIOS. Hardware specifics are selected per board; what is not
specific (setup utility, USB, PXE, ATA/LBA48, optional AT keyboard, POST codes, tests) is shared.

| Board | CPU / chipset | Firmware here | 86Box machine |
|---|---|---|---|
| [Biostar MB-8433UUD-A](boards/mb8433uud/README.md) | 486/Am5x86, UMC UM8881F + UM8886BF | mb-8433UUD (coreboot + SeaBIOS), flashed on the real board | `84xxuuda` |
| [IBM Aptiva A90 (2168)](boards/aptiva2168/README.md) | Pentium P54C, OPTi Viper-M | not started (the IBM BIOS runs in 86Box) | `aptiva2168` |

## Layout

- Submodules, each a fork with our commits on branch `retro` over the pinned upstream: `86box` (86Box v6.0),
  `coreboot` (pc2005cz/coreboot_486), `seabios` (pc2005cz/seabios_486), `ipxe`. Their origins are the bare
  repositories in `/mnt/data/perso/retro/git/`. Change them there with commits, then commit the new submodule
  pointer here.
- `boards/<board>/`: everything about one board: `firmware.sh` (its build recipe: coreboot mainboard, config, flash
  layout), `run_86box.sh` (its VM), `test/`, its documents and release scripts.
- Shared: `build.sh [board]`, `build_86box.sh`, `fetch_sources.sh`, `seabios.config`, `tools/`, `test/` (`lib.sh`, and
  the MB-8433UUD-A tests), `test/run_all.sh` (every test of every board).

## Use

- `git submodule update --init` (or any build: `fetch_sources.sh` does it), then `./build.sh [board]` → `out/`.
- `test/run_all.sh`: builds what is missing and runs all tests in parallel, one 86Box per core.
- Where the bytes of a ROM go: `tools/filelight.sh [rom]` opens Filelight on a tree made in RAM (`/dev/shm`, removed
  when Filelight closes): CBFS entry, source file, function or variable, each file 1024 times its bytes in the ROM
  (Filelight counts 4 KiB disk blocks): its MiB are KiB of ROM.
- `boards/<board>/run_86box.sh [rom]`: the board in the 86Box fork (Qt GUI).

Licenses: the scripts, tests and documents here GPL-3.0 (`LICENSE`); the forks keep their projects' licenses
(coreboot GPL-2.0, SeaBIOS LGPL-3.0, 86Box GPL-2.0-or-later, iPXE GPL-2.0). No BIOS image or ROM is distributed.
