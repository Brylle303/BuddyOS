; =====================================================================
; buddy.asm - Buddy system allocator (x86 32-bit protected mode, NASM)
;
; Pool      : 2 MB at 0x00100000-0x002FFFFF (A20 must be enabled)
; Blocks    : 64 B (order 0) up to 2 MB (order 15)
; Metadata  : 1 byte per 64 B unit (32 KB) at BUDDY_MAP
;               0          = not the start of a block
;               0x80|order = start of a FREE block
;               0x40|order = start of a USED block
; Free lists: one doubly linked list per order. The links live inside
;             the free blocks: [block+0]=next, [block+4]=prev, 0=none
;
; PUBLIC API (all other registers are preserved)
;   buddy_init   in: -          out: -
;   buddy_alloc  in: EAX=bytes  out: CF=0 EAX=address | CF=1 EAX=error
;   buddy_free   in: EAX=addr   out: CF=0 EAX=0       | CF=1 EAX=error
;   buddy_dump   in: -          out: prints every block
;
; buddy_dump needs these from the kernel (character/string/number in
; AL/ESI/EAX, all registers preserved): kputc, kputs, kputhex, kputdec
; =====================================================================
bits 32

POOL_BASE   equ 0x00100000
POOL_SIZE   equ 0x00200000
MIN_SHIFT   equ 6                   ; 2^6 = 64 bytes
MIN_BLOCK   equ 1 << MIN_SHIFT
MAX_ORDER   equ 15                  ; 64 << 15 = 2 MB
UNITS       equ POOL_SIZE / MIN_BLOCK
BUDDY_MAP   equ 0x00020000          ; 32 KB: 0x20000-0x27FFF

TAG_FREE    equ 0x80
TAG_USED    equ 0x40

ERR_ZERO    equ 1                   ; alloc: size is 0
ERR_TOO_BIG equ 2                   ; alloc: size > 2 MB
ERR_NO_MEM  equ 3                   ; alloc: no block large enough
ERR_BAD_PTR equ 4                   ; free: not the start of a block
ERR_DOUBLE  equ 5                   ; free: block is already free

; ---------------------------------------------------------------------
; buddy_init: whole pool becomes one free block of MAX_ORDER
; ---------------------------------------------------------------------
buddy_init:
    pushad
    pushfd
    cli
    cld
    mov edi, BUDDY_MAP
    mov ecx, UNITS / 4
    xor eax, eax
    rep stosd
    mov edi, free_heads
    mov ecx, MAX_ORDER + 1
    rep stosd
    mov ebx, POOL_BASE
    mov ecx, MAX_ORDER
    call list_push
    popfd
    popad
    ret

; ---------------------------------------------------------------------
; buddy_alloc
; ---------------------------------------------------------------------
buddy_alloc:
    push ebx
    push ecx
    push edx
    push esi
    pushfd                          ; remember the interrupt flag
    cli                             ; lists must not change under us

    test eax, eax
    jz .zero
    cmp eax, POOL_SIZE
    ja .too_big

    ; 1) round up: find smallest order with (64 << order) >= size
    xor ecx, ecx                    ; ECX = order
    mov edx, MIN_BLOCK              ; EDX = block size
.round:
    cmp edx, eax
    jae .search
    shl edx, 1
    inc ecx
    jmp .round

    ; 2) find the first non-empty list at that order or above
.search:
    mov esi, ecx                    ; ESI = wanted order
.next_list:
    cmp dword [free_heads + ecx*4], 0
    jne .found
    inc ecx
    cmp ecx, MAX_ORDER
    jbe .next_list
    mov eax, ERR_NO_MEM
    jmp .fail

.found:
    mov ebx, [free_heads + ecx*4]   ; EBX = block address
    call list_remove

    ; 3) split until the block is the wanted size
.split:
    cmp ecx, esi
    je .take
    dec ecx
    mov edx, MIN_BLOCK
    shl edx, cl                     ; EDX = half size
    push ebx
    add ebx, edx                    ; upper half goes to the free list
    call list_push
    pop ebx                         ; keep splitting the lower half
    jmp .split

    ; 4) mark as used
.take:
    call addr_to_unit               ; EDX = unit index of EBX
    mov al, cl
    or al, TAG_USED
    mov [BUDDY_MAP + edx], al
    mov eax, ebx
    popfd
    clc
    jmp .done

.zero:
    mov eax, ERR_ZERO
    jmp .fail
.too_big:
    mov eax, ERR_TOO_BIG
.fail:
    popfd
    stc
.done:
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; ---------------------------------------------------------------------
; buddy_free
; ---------------------------------------------------------------------
buddy_free:
    push ebx
    push ecx
    push edx
    push esi
    pushfd
    cli

    ; validate: inside pool, 64-byte aligned, start of a block
    mov ebx, eax                    ; EBX = block address
    mov edx, eax
    sub edx, POOL_BASE
    cmp edx, POOL_SIZE              ; unsigned: also catches addr < base
    jae .bad_ptr
    test edx, MIN_BLOCK - 1
    jnz .bad_ptr
    shr edx, MIN_SHIFT
    mov al, [BUDDY_MAP + edx]
    test al, TAG_FREE
    jnz .double
    test al, TAG_USED
    jz .bad_ptr

    movzx ecx, al
    and ecx, 0x3F                   ; ECX = order
    mov byte [BUDDY_MAP + edx], 0

    ; coalesce while the buddy is free AND the same order
.merge:
    cmp ecx, MAX_ORDER
    je .insert
    mov esi, MIN_BLOCK
    shl esi, cl                     ; ESI = block size
    mov edx, ebx
    sub edx, POOL_BASE
    xor edx, esi                    ; buddy offset = offset XOR size
    mov esi, edx
    shr edx, MIN_SHIFT
    mov al, cl
    or al, TAG_FREE
    cmp [BUDDY_MAP + edx], al
    jne .insert

    push ebx
    lea ebx, [esi + POOL_BASE]      ; EBX = buddy address
    call list_remove                ; also clears its map byte
    mov esi, ebx
    pop ebx
    cmp esi, ebx                    ; merged block starts at the lower one
    jae .grown
    mov ebx, esi
.grown:
    inc ecx
    jmp .merge

.insert:
    call list_push
    xor eax, eax
    popfd
    clc
    jmp .done

.bad_ptr:
    mov eax, ERR_BAD_PTR
    jmp .fail
.double:                            ; note: a freed block that has since
    mov eax, ERR_DOUBLE             ; merged upward reports ERR_BAD_PTR
.fail:
    popfd
    stc
.done:
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; ---------------------------------------------------------------------
; Internal helpers
; ---------------------------------------------------------------------
; addr_to_unit: EBX=address -> EDX=unit index
addr_to_unit:
    mov edx, ebx
    sub edx, POOL_BASE
    shr edx, MIN_SHIFT
    ret

; list_push: add block EBX to the free list of order ECX
; clobbers EAX, EDX, flags
list_push:
    mov eax, [free_heads + ecx*4]
    mov [ebx], eax                  ; next = old head
    mov dword [ebx + 4], 0          ; prev = none
    test eax, eax
    jz .no_old
    mov [eax + 4], ebx
.no_old:
    mov [free_heads + ecx*4], ebx
    call addr_to_unit
    mov al, cl
    or al, TAG_FREE
    mov [BUDDY_MAP + edx], al
    ret

; list_remove: unlink block EBX from the free list of order ECX
; clobbers EAX, EDX, flags
list_remove:
    mov eax, [ebx]                  ; next
    mov edx, [ebx + 4]              ; prev
    test edx, edx
    jz .is_head
    mov [edx], eax
    jmp .fix_next
.is_head:
    mov [free_heads + ecx*4], eax
.fix_next:
    test eax, eax
    jz .clear
    mov [eax + 4], edx
.clear:
    call addr_to_unit
    mov byte [BUDDY_MAP + edx], 0
    ret

; ---------------------------------------------------------------------
; buddy_dump: walk the pool in address order and print each block
; ---------------------------------------------------------------------
buddy_dump:
    pushad
    pushfd
    cli
    xor ebx, ebx                    ; EBX = unit index
    xor edi, edi                    ; EDI = total free bytes
.block:
    mov al, [BUDDY_MAP + ebx]
    movzx ecx, al
    and ecx, 0x3F
    mov edx, MIN_BLOCK
    shl edx, cl                     ; EDX = size in bytes

    mov esi, msg_indent
    call kputs
    push eax
    mov eax, ebx
    shl eax, MIN_SHIFT
    add eax, POOL_BASE
    call kputhex
    pop eax

    mov esi, msg_used
    test al, TAG_FREE
    jz .state
    mov esi, msg_free
    add edi, edx
.state:
    call kputs
    mov eax, edx
    call print_size
    mov al, 10
    call kputc

    shr edx, MIN_SHIFT
    add ebx, edx                    ; jump to the next block
    cmp ebx, UNITS
    jb .block

    mov esi, msg_total
    call kputs
    mov eax, edi
    call print_size
    mov al, 10
    call kputc
    popfd
    popad
    ret

; print_size: EAX bytes, shown as KB when it is a whole number of KB
print_size:
    pushad
    mov esi, msg_b
    test eax, 1023
    jnz .out
    shr eax, 10
    mov esi, msg_kb
.out:
    call kputdec
    call kputs
    popad
    ret

msg_indent: db "    ", 0
msg_used:   db "  USED  ", 0
msg_free:   db "  free  ", 0
msg_total:  db "    total free: ", 0
msg_b:      db " B", 0
msg_kb:     db " KB", 0

align 4
free_heads: times MAX_ORDER + 1 dd 0
