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
├── build.bat       # Assembles both files, links image, launches QEMU
├── boot.bin        # Assembled bootloader (512 bytes)
├── kernel.bin      # Assembled kernel (1024 bytes)
├── os-image.bin    # Combined bootable disk image (boot.bin + kernel.bin)
└── README.md
```

## Boot Flow

1. BIOS loads the boot sector at `0x7C00`.
2. `boot.asm` reads 2 sectors (the kernel) from disk to `0x0000:0x8000` via `INT 0x13`.
3. `kernel.asm` loads the GDT, sets the `CR0` protection-enable bit, and far-jumps into 32-bit mode.
4. Segment registers and the stack (`0x90000`) are initialized.
5. The VGA text buffer (`0xB8000`) is cleared, the banner is printed, and the CPU halts.

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
- [ ] A20 line enable
- [ ] BIOS E820 physical memory map
- [ ] Buddy memory allocator (split / coalesce / alloc / free)
- [ ] IDT + PIC + exception/IRQ handling
- [ ] Keyboard driver and shell
- [ ] Allocator visualizer

## Team — Deadlockz

1. **Brylle Cortes** — Leader
2. **Aaron James Monte Siat**
3. **Reuel Matthew Arcilla**
4. **Vince Nino Colina**

*Course: CPE 3106*

## License

This project is licensed under the **MIT License**.
