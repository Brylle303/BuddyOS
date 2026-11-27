; memcmd.asm - memory commands for the BuddyOS shell
; Included by kernel.asm after buddy.asm.
bits 32

MAX_NAMES  equ 16
NAME_LEN   equ 8                    ; longest name
ENTRY      equ 20                   ; name[12], address, requested size

%macro PRINT 1
    jmp %%over
%%text: db %1, 0
%%over:
    push esi
    mov esi, %%text
    call kputs
    pop esi
%endmacro

%macro COMMAND 2                    ; word, handler
    mov edi, %%word
    call word_is
    je %2
    jmp %%over
%%word: db %1, 0
%%over:
%endmacro

; mem_command: run the line in cmd_buf if it is a memory command
; out: CF=0 handled | CF=1 not a memory command. Preserves registers.
mem_command:
    pushad
    mov esi, cmd_buf                ; upper-case copy of the line
    mov edi, line
.copy:
    lodsb
    cmp al, 'a'
    jb .store
    cmp al, 'z'
    ja .store
    sub al, 32
.store:
    stosb
    test al, al
    jnz .copy

    mov esi, line
    mov edi, word1
    call next_word                  ; command; ESI -> arguments
    COMMAND "ALLOC", cmd_alloc
    COMMAND "FREE", cmd_free
    COMMAND "FREEADDR", cmd_freeaddr
    COMMAND "LIST", cmd_list
    COMMAND "DUMP", cmd_dump
    COMMAND "RESET", cmd_reset
    COMMAND "HELP", cmd_help
    COMMAND "1", cmd_help
    popad
    stc
    ret

mem_done:                           ; every command ends here
    popad
    clc
    ret

; ---- ALLOC name size ------------------------------------------------
cmd_alloc:
    mov edi, word1
    call next_word                  ; name
    mov edi, word2
    call next_word                  ; size
    cmp byte [word2], 0
    je .usage
    call extra_words
    jne .usage
    cmp byte [word1 + NAME_LEN], 0
    jne .long_name

    call find_name
    jnc .in_use
    call find_empty                 ; EBX = table entry
    jc .table_full

    call parse_size                 ; EAX = bytes
    jc .bad_size
    mov ecx, eax
    call buddy_alloc
    jc .failed

    mov [ebx + 12], eax
    mov [ebx + 16], ecx
    mov esi, word1                  ; copy the name into the entry
    mov edi, ebx
    mov ecx, 12 / 4
    rep movsd

    PRINT "OK: "
    call print_entry
    call buddy_dump
    jmp mem_done

.usage:
    PRINT {"ERROR: usage is ALLOC name size   (e.g. ALLOC A 100K)", 10}
    jmp mem_done
.long_name:
    PRINT {"ERROR: name is longer than 8 characters", 10}
    jmp mem_done
.in_use:
    PRINT {"ERROR: that name is already in use", 10}
    jmp mem_done
.table_full:
    PRINT {"ERROR: name table is full (16 blocks), FREE one first", 10}
    jmp mem_done
.bad_size:
    PRINT {"ERROR: bad size (use a number such as 500, 64K or 1M)", 10}
    jmp mem_done
.failed:
    call print_error
    jmp mem_done

; ---- FREE name ------------------------------------------------------
cmd_free:
    mov edi, word1
    call next_word
    cmp byte [word1], 0
    je .usage
    call extra_words
    jne .usage
    cmp byte [word1 + NAME_LEN], 0
    jne .unknown
    call find_name                  ; EBX = entry
    jc .unknown
    mov eax, [ebx + 12]
    call buddy_free
    jc .failed
    mov byte [ebx], 0               ; forget the name
    PRINT "OK: freed "
    mov esi, word1
    call kputs
    PRINT {10}
    call buddy_dump
    jmp mem_done
.usage:
    PRINT {"ERROR: usage is FREE name", 10}
    jmp mem_done
.unknown:
    PRINT {"ERROR: no allocated block has that name", 10}
    jmp mem_done
.failed:
    call print_error
    jmp mem_done

; ---- FREEADDR hex : free a raw address, to show pointer checks ------
cmd_freeaddr:
    mov edi, word1
    call next_word
    call extra_words
    jne .usage
    call parse_hex                  ; EAX = address
    jc .usage
    mov ecx, eax
    call buddy_free
    jc .failed
    ; drop any name that pointed at this block
    mov ebx, table
.scan:
    cmp [ebx + 12], ecx
    jne .next
    mov byte [ebx], 0
.next:
    add ebx, ENTRY
    cmp ebx, table + MAX_NAMES * ENTRY
    jb .scan
    PRINT {"OK: freed", 10}
    call buddy_dump
    jmp mem_done
.usage:
    PRINT {"ERROR: usage is FREEADDR hexaddress   (e.g. FREEADDR 100000)", 10}
    jmp mem_done
.failed:
    call print_error
    jmp mem_done

; ---- LIST / DUMP / RESET / HELP -------------------------------------
cmd_list:
    mov ebx, table
    xor ecx, ecx
.next:
    cmp byte [ebx], 0
    je .skip
    call print_entry
    inc ecx
.skip:
    add ebx, ENTRY
    cmp ebx, table + MAX_NAMES * ENTRY
    jb .next
    test ecx, ecx
    jnz mem_done
    PRINT {"(nothing allocated)", 10}
    jmp mem_done

cmd_dump:
    call buddy_dump
    jmp mem_done

cmd_reset:
    call buddy_init
    mov edi, table
    mov ecx, MAX_NAMES * ENTRY / 4
    xor eax, eax
    rep stosd
    PRINT {"OK: everything freed", 10}
    jmp mem_done

cmd_help:
    PRINT {"=== Buddy Memory Management (2 MB) ===", 10}
    PRINT {"ALLOC name size  allocate (size: bytes, or with K / M)", 10}
    PRINT {"FREE name        free a named block", 10}
    PRINT {"FREEADDR hex     free by address (to test bad pointers)", 10}
    PRINT {"LIST             show named blocks", 10}
    PRINT {"DUMP             show the whole pool", 10}
    PRINT {"RESET            free everything", 10}
    PRINT {"Other commands: menu, version, credits", 10}
    jmp mem_done

; ---- output helpers -------------------------------------------------
; print_entry: EBX = table entry
print_entry:
    pushad
    mov esi, ebx
    call kputs
    PRINT " at "
    mov eax, [ebx + 12]
    call kputhex
    PRINT ", asked "
    mov eax, [ebx + 16]
    call print_size
    PRINT ", got "
    mov eax, [ebx + 12]             ; block order is in the buddy map
    sub eax, POOL_BASE
    shr eax, MIN_SHIFT
    mov cl, [BUDDY_MAP + eax]
    and cl, 0x3F
    mov eax, MIN_BLOCK
    shl eax, cl
    call print_size
    PRINT {10}
    popad
    ret

; print_error: EAX = error code from the allocator
print_error:
    pushad
    PRINT "ERROR "
    call kputdec
    PRINT ": "
    mov esi, [errors + eax*4 - 4]
    call kputs
    PRINT {10}
    popad
    ret

errors: dd e1, e2, e3, e4, e5
e1: db "size must be more than 0", 0
e2: db "size is larger than the 2 MB pool", 0
e3: db "out of memory (no free block is large enough)", 0
e4: db "bad pointer (not the start of an allocated block)", 0
e5: db "double free (block is already free)", 0

; ---- name table -----------------------------------------------------
; find_name: look up word1. CF=0 EBX=entry | CF=1 not found
find_name:
    mov ebx, table
.next:
    mov esi, word1
    mov edi, ebx
    mov ecx, 12
    repe cmpsb
    je .found
    add ebx, ENTRY
    cmp ebx, table + MAX_NAMES * ENTRY
    jb .next
    stc
    ret
.found:
    clc
    ret

; find_empty: CF=0 EBX=free entry | CF=1 table full
find_empty:
    mov ebx, table
.next:
    cmp byte [ebx], 0
    je .found
    add ebx, ENTRY
    cmp ebx, table + MAX_NAMES * ENTRY
    jb .next
    stc
    ret
.found:
    clc
    ret

; ---- parsing --------------------------------------------------------
; next_word: copy the next word at ESI into the 12-byte buffer EDI
; (zero filled, extra characters dropped). Advances ESI.
next_word:
    push eax
    push ecx
    push edi
    xor eax, eax
    mov ecx, 12
    rep stosb
    pop edi
    push edi
.spaces:
    cmp byte [esi], ' '
    jne .copy
    inc esi
    jmp .spaces
.copy:
    mov al, [esi]
    test al, al
    jz .done
    cmp al, ' '
    je .done
    inc esi
    cmp ecx, 11                     ; keep the final zero
    jae .copy
    mov [edi + ecx], al
    inc ecx
    jmp .copy
.done:
    pop edi
    pop ecx
    pop eax
    ret

; extra_words: ZF=1 if only spaces remain at ESI
extra_words:
    cmp byte [esi], ' '
    jne .check
    inc esi
    jmp extra_words
.check:
    cmp byte [esi], 0
    ret

; word_is: ZF=1 if word1 equals the string at EDI
word_is:
    push esi
    push edi
    mov esi, word1
.next:
    mov al, [esi]
    cmp al, [edi]
    jne .done
    inc esi
    inc edi
    test al, al
    jnz .next
.done:
    pop edi
    pop esi
    ret

; parse_size: word2 = digits [K|M]. CF=0 EAX=bytes | CF=1 invalid
parse_size:
    push ecx
    push edx
    push esi
    mov esi, word2
    xor eax, eax
    cmp byte [word2 + 10], 0        ; too long, may have been cut off
    jne .bad
    cmp byte [esi], '0'
    jb .bad
    cmp byte [esi], '9'
    ja .bad
.digit:
    movzx ecx, byte [esi]
    sub ecx, '0'
    cmp ecx, 9
    ja .suffix
    mov edx, 10
    mul edx
    jc .bad                         ; overflow
    add eax, ecx
    jc .bad
    inc esi
    jmp .digit
.suffix:
    mov cl, 10
    cmp byte [esi], 'K'
    je .scale
    mov cl, 20
    cmp byte [esi], 'M'
    je .scale
    cmp byte [esi], 0
    je .good
    jmp .bad
.scale:
    cmp byte [esi + 1], 0
    jne .bad
    mov edx, 0xFFFFFFFF
    shr edx, cl
    cmp eax, edx
    ja .bad
    shl eax, cl
.good:
    clc
    jmp .out
.bad:
    stc
.out:
    pop esi
    pop edx
    pop ecx
    ret

; parse_hex: word1 = [0X]hexdigits. CF=0 EAX=value | CF=1 invalid
parse_hex:
    push ecx
    push esi
    mov esi, word1
    xor eax, eax
    cmp word [esi], '0X'
    jne .start
    add esi, 2
.start:
    cmp byte [esi], 0
    je .bad
    cmp byte [word1 + 10], 0
    jne .bad
.digit:
    movzx ecx, byte [esi]
    test cl, cl
    jz .good
    sub ecx, '0'
    cmp ecx, 9
    jbe .add
    sub ecx, 'A' - '0'
    cmp ecx, 5
    ja .bad
    add ecx, 10
.add:
    test eax, 0xF0000000
    jnz .bad
    shl eax, 4
    or eax, ecx
    inc esi
    jmp .digit
.good:
    clc
    jmp .out
.bad:
    stc
.out:
    pop esi
    pop ecx
    ret

; ---- console glue for buddy.asm (it expects these names) ------------
kputc:                              ; AL = character
    push eax                        ; putchar changes EAX
    call putchar
    pop eax
    ret
kputs:                              ; ESI = string
    jmp print_string
kputhex:                            ; EAX as 0x########
    push eax
    mov al, '0'
    call putchar
    mov al, 'x'
    call putchar
    pop eax
    jmp print_hex
kputdec:                            ; EAX in decimal
    jmp print_dec

line:  times 64 db 0
word1: times 12 db 0
word2: times 12 db 0
table: times MAX_NAMES * ENTRY db 0
