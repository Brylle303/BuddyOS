# BuddyOS

> A minimal x86 operating system built from scratch in NASM assembly, designed to
> implement the **buddy memory allocation algorithm**. Built for **CPE 3106**.

![Language](https://img.shields.io/badge/language-x86%20Assembly-blue)
![Assembler](https://img.shields.io/badge/assembler-NASM-orange)
![Emulator](https://img.shields.io/badge/emulator-QEMU-green)
![Mode](https://img.shields.io/badge/mode-32--bit%20Protected-lightgrey)
![License](https://img.shields.io/badge/license-MIT-brightgreen)

## Overview

BuddyOS is an educational operating system written entirely in x86 assembly. It
boots via the BIOS, switches the CPU into **32-bit protected mode**, and initializes
a **VGA text-mode** console. Its end goal is to implement a **buddy memory
allocator** — power-of-two block splitting and coalescing — as the core of its
memory management subsystem.

## Features

- 16-bit real-mode BIOS bootloader that loads the kernel from disk
- Minimal flat GDT and transition to 32-bit protected mode
- A20 line enabled by the bootloader
- Buddy memory allocator: 2 MB pool, 64-byte minimum block, split and coalesce
- Interrupt-driven keyboard input and command shell
- VGA text-mode screen clear and power-on banner
- Simple, dependency-light build pipeline (NASM + QEMU)

## Tech Stack

| Layer        | Technology                                          |
|--------------|-----------------------------------------------------|
| Language     | x86 Assembly (NASM syntax)                          |
| Assembler    | NASM (`nasm -f bin`)                                |
| Emulator     | QEMU (`qemu-system-i386`)                           |
| Build script | Windows Batch (`build.bat`)                         |
| Target       | x86 BIOS, 32-bit protected mode, VGA text mode      |

## Project Structure

```
BuddyOS/
├── boot.asm        # 16-bit real-mode bootloader (loads kernel, jumps to 0x8000)
├── kernel.asm      # 32-bit protected-mode kernel entry (GDT, VGA output)
├── buddy.asm       # Buddy memory allocator
├── memcmd.asm      # Shell commands for the allocator
├── build.bat       # Assembles both files, links image, launches QEMU
├── boot.bin        # Assembled bootloader (512 bytes)
├── kernel.bin      # Assembled kernel (16384 bytes)
├── os-image.bin    # Combined bootable disk image (boot.bin + kernel.bin)
└── README.md
```

## Boot Flow

1. BIOS loads the boot sector at `0x7C00`.
2. `boot.asm` reads 32 sectors (the kernel) to `0x0000:0x8000` via `INT 0x13` and enables A20.
3. `kernel.asm` loads the GDT, sets the `CR0` protection-enable bit, and far-jumps into 32-bit mode.
4. Segment registers and the stack (`0x90000`) are initialized.
5. The screen is cleared, the banner is printed, the allocator, PIC and IDT are set up,
   and the kernel waits for commands.

## Memory Commands

| Command | Action |
|---|---|
| `alloc NAME SIZE` | Allocate (bytes, or with K / M) |
| `free NAME` | Free a named block |
| `freeaddr HEX` | Free by address (tests pointer checks) |
| `list` / `dump` | Show named blocks / the whole pool |
| `reset` | Reinitialize the pool (frees **everything**) |
| `1` or `help` | Show these commands |

### Allocator API

`buddy_alloc`: EAX = bytes, returns EAX = address. `buddy_free`: EAX = address.
CF set means error, with the code in EAX (1 zero size, 2 too big, 3 out of memory,
4 bad pointer, 5 double free). Do not call these from interrupt handlers.

### Memory Map

| Range | Use |
|---|---|
| `0x7C00` | Boot sector |
| `0x8000`-`0xBFFF` | Kernel |
| `0x20000`-`0x27FFF` | Allocator map |
| below `0x90000` | Stack |
| `0x100000`-`0x2FFFFF` | Buddy pool (2 MB) |

## Prerequisites

- [NASM](https://www.nasm.us/) available on `PATH`
- [QEMU](https://www.qemu.org/) with `qemu-system-i386` available on `PATH`
- Windows (for `build.bat`) — or run the NASM commands manually on any OS

## Build & Run

**Windows (automated):**
```bat
build.bat
```

**Manual (cross-platform):**
```bash
nasm -f bin boot.asm   -o boot.bin
nasm -f bin kernel.asm -o kernel.bin
copy /b boot.bin + kernel.bin os-image.bin   # use `cat` on Unix
qemu-system-i386 -drive format=raw,file=os-image.bin
```

## Roadmap

- [x] 16-bit bootloader
- [x] GDT + 32-bit protected mode
- [x] VGA text-mode output
- [x] A20 line enable
- [ ] BIOS E820 physical memory map
- [x] Buddy memory allocator (split / coalesce / alloc / free)
- [ ] IDT + PIC + exception/IRQ handling
- [x] Keyboard driver and shell
- [ ] Allocator visualizer

## Team — Deadlockz

1. **Brylle Cortes** — Leader
2. **Aaron James Monte Siat**
3. **Reuel Matthew Arcilla**
4. **Vince Nino Colina**

*Course: CPE 3106*

## License

This project is licensed under the **MIT License**.
