[BITS 16]
[ORG 0x7C00]
start:
mov [BOOT_DRIVE], dl ; BIOS stores the boot drive ID in DL

; Initialize segment registers and stack cleanly
xor ax, ax
mov ds, ax
mov es, ax
mov ss, ax
mov sp, 0x7C00

; Print bootloader status via BIOS teletype interrupt
mov si, msg_boot
call print_string

; Load kernel (2 sectors = 1024 bytes) from Sector 2 to 0x0000:0x8000
mov ah, 0x02 ; BIOS read sectors function
mov al, 2 ; Number of sectors to read
mov ch, 0 ; Cylinder 0
mov cl, 2 ; Start at Sector 2 (Sector 1 is this bootloader)
mov dh, 0 ; Head 0
mov dl, [BOOT_DRIVE] ; Drive number
mov bx, 0x8000 ; Destination offset (ES:BX = 0x0000:0x8000)
int 0x13 ; Call BIOS disk service
jc disk_error ; Jump if Carry Flag is set (read failed)

; Hand off control to the kernel
jmp 0x0000:0x8000
disk_error:
mov si, msg_err
call print_string
jmp $ ; Halt on error
print_string:
mov ah, 0x0E ; BIOS teletype output
.loop:
lodsb ; Load next char from [DS:SI] into AL
test al, al ; Check for null terminator (0)
jz .done
int 0x10 ; Print character
jmp .loop
.done:
ret
BOOT_DRIVE db 0
msg_boot db "Bootloader: Loading kernel...", 13, 10, 0
msg_err db "Disk read error!", 0

; Pad bootloader to 510 bytes and append the 2-byte BIOS boot signature
times 510 - ($ - $$) db 0
dw 0xAA55