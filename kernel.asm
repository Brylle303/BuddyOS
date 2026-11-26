[BITS 16]
[ORG 0x8000]

kernel_entry_16:
    cli                     ; Disable interrupts before switching CPU modes
    lgdt [gdt_descriptor]   ; Load Global Descriptor Table

    ; Set PE (Protection Enable) bit in CR0
    mov eax, cr0
    or eax, 1
    mov cr0, eax

    ; Far jump flushes CPU pipeline and loads 32-bit code segment (0x08)
    jmp 0x08:init_32

; --- Minimal Flat 32-Bit GDT ---
gdt_start:
    dq 0x0000000000000000   ; Null descriptor (required)

gdt_code:                   ; Selector 0x08: Base=0, Limit=4GB, Executable/Readable
    dw 0xFFFF, 0x0000
    db 0x00, 10011010b, 11001111b, 0x00

gdt_data:                   ; Selector 0x10: Base=0, Limit=4GB, Read/Write
    dw 0xFFFF, 0x0000
    db 0x00, 10010010b, 11001111b, 0x00
gdt_end:

gdt_descriptor:
    dw gdt_end - gdt_start - 1
    dd gdt_start

; --- 32-Bit Protected Mode Kernel ---
[BITS 32]
init_32:
    mov ax, 0x10            ; Load data segment selector (0x10) into all data segments
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, 0x90000        ; Set stack pointer at 576 KB mark

    call clear_screen

    mov esi, msg_kernel
    mov edi, 0xB8000        ; VGA text-mode buffer address
    mov ah, 0x0A            ; Light green text on black background
.print_vga:
    lodsb
    test al, al
    jz kernel_idle
    mov [edi], ax           ; Write 2 bytes: [ASCII char][color attribute]
    add edi, 2
    jmp .print_vga

kernel_idle:
    hlt                     ; Wait for hardware interrupts (timer/keyboard)
    jmp kernel_idle

clear_screen:
    mov edi, 0xB8000
    mov ecx, 80 * 25        ; 80 columns x 25 rows
    mov ax, 0x0720          ; Space character (0x20) with light-gray attribute (0x07)
    rep stosw
    ret

msg_kernel db "Kernel Online: 32-bit Protected Mode Ready!", 0

; Pad kernel to exactly 1024 bytes (2 sectors) so INT 13h reads cleanly
times 1024 - ($ - $$) db 0