; realdump: boots from a FAT12 1.44 MB floppy, reads the board's chipset, Super I/O, CMOS, KBC, BIOS data and memory
; images into RAM, then writes them into the preallocated file DUMP.BIN (cluster 2 on). Layout: README.md.
bits 16
cpu 586
org 0x7c00

PAYLOAD   equ 8                 ; sectors after the boot sector, in the reserved area
BUF_SEG   equ 0x1000            ; dump buffer 10000h-7FFFFh
BUF_END   equ 0x80000
IO_SEG    equ 0x8000            ; one track for the disk, its read-back copy at VERIFY
VERIFY    equ 0x4800
SMAP      equ 0x534d4150

    jmp short boot
    nop
          db 'REALDUMP'
          dw 512
          db 1
rsvd      dw 1 + PAYLOAD
nfats     db 2
rootents  dw 224
          dw 2880
          db 0xf0
fatsz     dw 9
spt       dw 18
heads     dw 2
          dd 0, 0
          db 0, 0, 0x29
          dd 0x21682168
          db 'REALDUMP   ', 'FAT12   '

boot:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7c00
    sti
    cld
    jmp 0:.flat
.flat:
    mov [drive], dl
    mov si, 3
.read:
    mov ax, 0x0200 + PAYLOAD
    mov cx, 2
    xor dh, dh
    mov dl, [drive]
    mov bx, main
    int 0x13
    jnc main
    xor ah, ah
    int 0x13
    dec si
    jnz .read
    mov si, msg_load
fail:                           ; SI = message
    call print
halt:
    sti
.h: hlt
    jmp .h

print:                          ; SI = zero-terminated string
    pusha
.c: lodsb
    test al, al
    jz .d
    mov ah, 0x0e
    mov bx, 7
    int 0x10
    jmp .c
.d: popa
    ret

msg_load  db 'realdump: cannot read the floppy', 13, 10, 0
drive     db 0

    times 510 - ($ - $$) db 0
    dw 0xaa55

main:
    mov si, msg_start
    call print
    mov ax, BUF_SEG
    mov es, ax
    xor di, di
    mov eax, 'RDMP'
    stosd
    xor eax, eax
    stosd                       ; total length, set by finish
    stosd                       ; byte sum of the records, set by finish
    inc ax
    stosd                       ; layout version
    call dump_memory
    call dump_bios
    call dump_e820
    call dump_pnp
    call dump_pci
    call dump_557m
    call dump_cmos
    call dump_sio
    call dump_gpio
    call dump_ports
    call dump_ide
    call dump_cyrix
    call dump_kbc
    mov eax, 'END '
    call rec_begin
    call rec_end
    call finish
    mov si, msg_write
    call print
    call write_dump
    mov si, msg_done
    call print
    mov eax, [total]
    call print_hex
    mov si, msg_bytes
    jmp fail

; ---- output buffer: ES:DI, records "TAG" + u32 length + data

normalize:                      ; ES:DI -> same address with DI < 16
    push ax
    push dx
    mov ax, di
    shr ax, 4
    mov dx, es
    add dx, ax
    mov es, dx
    and di, 15
    pop dx
    pop ax
    ret

out_lin:                        ; EAX = linear address of ES:DI
    push edx
    mov ax, es
    movzx eax, ax
    shl eax, 4
    movzx edx, di
    add eax, edx
    pop edx
    ret

rec_begin:                      ; EAX = tag
    call normalize
    stosd
    mov [rec_len], di
    mov [rec_len + 2], es
    xor eax, eax
    stosd
    call out_lin
    mov [rec_start], eax
    ret

rec_end:
    call out_lin
    sub eax, [rec_start]
    push ds
    push bx
    lds bx, [rec_len]
    mov [bx], eax
    pop bx
    pop ds
    ret

copy_lin:                       ; ESI = source linear, ECX = bytes -> ES:DI; ESI advanced
    push ds
.chunk:
    test ecx, ecx
    jz .done
    call normalize
    mov edx, 0x8000
    cmp ecx, edx
    jae .n
    mov edx, ecx
.n: sub ecx, edx
    push ecx
    push esi
    mov eax, esi
    shr eax, 4
    mov ds, ax
    and si, 15
    mov cx, dx
    rep movsb
    pop esi
    pop ecx
    add esi, edx
    jmp .chunk
.done:
    pop ds
    ret

rec_copy:                       ; EAX = tag, ESI = source linear, ECX = bytes
    call rec_begin
    call copy_lin
    jmp rec_end

idx_dump:                       ; DX = index port, SI = data port, BL = first index, BH = OR mask, CX = count
    mov al, bl
    or al, bh
    out dx, al
    xchg dx, si
    in al, dx
    xchg dx, si
    stosb
    inc bl
    loop idx_dump
    ret

; ---- memory images and BIOS services

dump_memory:
    mov eax, 'IVT '
    xor esi, esi
    mov ecx, 1024
    call rec_copy
    mov eax, 'BDA '
    mov esi, 0x400
    mov ecx, 256
    call rec_copy
    mov eax, 'ROM '
    mov esi, 0xc0000
    mov ecx, 0x40000
    call rec_copy
    mov eax, 'EBDA'
    call rec_begin
    mov ax, [0x40e]
    stosw
    movzx esi, ax
    shl esi, 4
    xor ecx, ecx
    cmp esi, 0x80000            ; no EBDA, or not below 640K
    jb .copy
    cmp esi, 0xa0000
    jae .copy
    mov fs, ax
    mov cl, [fs:0]              ; size in KB
    shl ecx, 10
    mov edx, 0xa0000
    sub edx, esi
    cmp ecx, edx
    jbe .copy
    mov ecx, edx
.copy:
    call copy_lin
    jmp rec_end

dump_bios:
    mov eax, 'BIOS'
    call rec_begin
    int 0x12
    stosw
    int 0x11
    stosw
    push es
    push di
    mov ah, 0x88
    clc
    int 0x15
    pushf
    pop bx
    pop di
    pop es
    xchg ax, bx
    stosw                       ; flags
    xchg ax, bx
    stosw
    push es
    push di
    mov ax, 0xe801
    xor bx, bx
    xor cx, cx
    xor dx, dx
    clc
    int 0x15
    pushf
    pop si
    pop di
    pop es
    xchg ax, si
    stosw                       ; flags
    xchg ax, si
    stosw
    mov ax, bx
    stosw
    mov ax, cx
    stosw
    mov ax, dx
    stosw
    cld
    call rec_end
    mov eax, 'CPU '
    call rec_begin
    pushfd
    pop eax
    mov ebx, eax
    xor eax, 1 << 21            ; CPUID exists when EFLAGS.ID toggles
    push eax
    popfd
    pushfd
    pop eax
    push ebx
    popfd
    xor eax, ebx
    test eax, 1 << 21
    jz .no_cpuid
    mov byte [has_cpuid], 1
    xor eax, eax
    cpuid
    stosd
    mov eax, ebx
    stosd
    mov [vendor], ebx
    mov eax, edx
    stosd
    mov [vendor + 4], edx
    mov eax, ecx
    stosd
    mov [vendor + 8], ecx
    mov eax, 1
    cpuid
    stosd
    mov eax, ebx
    stosd
    mov eax, ecx
    stosd
    mov eax, edx
    stosd
.no_cpuid:
    jmp rec_end

dump_e820:
    mov eax, 'E820'
    call rec_begin
    xor ebx, ebx
    mov bp, 64
.next:
    call normalize
    push es
    push di
    mov eax, 0xe820
    mov edx, SMAP
    mov ecx, 20
    int 0x15
    pop di
    pop es
    cld
    jc .done
    cmp eax, SMAP
    jne .done
    add di, 20
    test ebx, ebx
    jz .done
    dec bp
    jnz .next
.done:
    jmp rec_end

dump_pnp:
    push ds
    mov ax, 0xf000
    mov ds, ax
    xor bx, bx
.scan:
    cmp dword [bx], '$PnP'
    jne .next
    movzx cx, byte [bx + 5]
    cmp cx, 0x21
    jb .next
    cmp cx, 0x40
    ja .next
    mov si, bx
    xor al, al
.sum:
    add al, [si]
    inc si
    loop .sum
    test al, al
    jz .found
.next:
    add bx, 16
    jnz .scan
    pop ds
    ret
.found:
    movzx ecx, byte [bx + 5]
    mov eax, [bx + 0x0d]        ; real-mode entry offset, segment
    mov dx, [bx + 0x1b]         ; real-mode data segment
    pop ds
    mov [pnp_entry], eax
    mov [pnp_sel], dx
    movzx esi, bx
    add esi, 0xf0000
    mov eax, 'PNPH'
    call rec_copy
    mov eax, 'PNP0'
    call rec_begin
    push es
    push di
    push word [pnp_sel]
    push ds
    push node_size
    push ds
    push num_nodes
    push 0                      ; function 0: number of system device nodes
    call pnp_call
    add sp, 12
    pop di
    pop es
    stosw
    mov al, [num_nodes]
    stosb
    mov ax, [node_size]
    stosw
    call rec_end
    cmp word [pnp_ret], 0
    jne .done
    cmp word [node_size], 0x1000
    ja .done
    mov byte [pnp_node], 0
    mov bp, 256
.node:
    call out_lin
    cmp eax, BUF_END - 0x2000
    jae .done
    mov eax, 'PNPN'
    call rec_begin
    mov al, [pnp_node]
    stosb
    mov bx, di
    stosw                       ; return code, set below
    push bx
    push es
    push di
    push word [pnp_sel]
    push 1                      ; control: current configuration
    push es
    push di
    push ds
    push pnp_node
    push 1                      ; function 1: get system device node
    call pnp_call
    add sp, 14
    pop di
    pop es
    pop bx
    mov [es:bx], ax
    test ax, ax
    jnz .last
    mov cx, [es:di]             ; node size
    cmp cx, [node_size]
    ja .last
    add di, cx
    call rec_end
    cmp byte [pnp_node], 0xff
    je .done
    dec bp
    jnz .node
    ret
.last:
    call rec_end
.done:
    ret

pnp_call:                       ; the arguments are on the stack above the return address; AX = result
    pushad
    push ds
    mov bp, sp
    mov cx, 7                   ; copy up to 7 argument words below our saved state
.arg:
    mov si, cx
    shl si, 1
    push word [bp + 34 + si]
    loop .arg
    call far [cs:pnp_entry]
    add sp, 14
    xor bx, bx
    mov ds, bx
    mov [pnp_ret], ax
    pop ds
    popad
    mov ax, [pnp_ret]
    cld
    ret

; ---- PCI, chipset index registers

pci_rd:                         ; BX = devfn, CL = register -> EAX
    movzx eax, bx
    shl eax, 8
    mov al, cl
    or eax, 0x80000000
    mov dx, 0xcf8
    out dx, eax
    mov dl, 0xfc
    in eax, dx
    ret

dump_pci:
    cli
    mov dx, 0xcf8
    in eax, dx
    push eax
    xor bx, bx
.dev:
    xor cl, cl
    call pci_rd
    cmp ax, 0xffff
    je .next
    mov cl, 0x0c
    call pci_rd
    mov si, 1
    test eax, 1 << 23           ; multi-function
    jz .fns
    mov si, 8
.fns:
    push bx
.fn:
    xor cl, cl
    call pci_rd
    cmp ax, 0xffff
    je .absent
    mov eax, 'PCI '
    call rec_begin
    mov al, bl
    stosb
    xor cl, cl
.reg:
    call pci_rd
    stosd
    add cl, 4
    jnz .reg
    call rec_end
.absent:
    inc bx
    dec si
    jnz .fn
    pop bx
.next:
    add bx, 8
    cmp bx, 256
    jb .dev
    pop eax
    mov dx, 0xcf8
    out dx, eax
    sti
    ret

dump_557m:                      ; 22h index / 24h data, all 256 indexes: no read side effect in the data book
    mov eax, '557M'
    call rec_begin
    cli
    in al, 0x22
    stosb
    push ax
    mov dx, 0x22
    mov si, 0x24
    xor bx, bx
    mov cx, 256
    call idx_dump
    pop ax
    out 0x22, al
    sti
    jmp rec_end

dump_gpio:                      ; FDC37C93x run-mode GP index/data at EAh/EBh: only when its CR03 enables them there
    mov eax, 'GPIO'
    call rec_begin
    mov al, [sio_cr03]
    stosb
    and al, 0x83
    cmp al, 0x83
    jne rec_end
    cli
    in al, 0xea
    stosb
    push ax
    mov dx, 0xea
    mov si, 0xeb
    xor bx, bx
    mov cx, 256
    call idx_dump
    pop ax
    out 0xea, al
    sti
    jmp rec_end

; ---- CMOS, Super I/O and its GPIO, legacy ports, IDE, KBC

cmos_bank:                      ; DX = index port, SI = data port; 128 bytes, NMI bit (70h) as found
    mov bh, [cmos_70]
    and bh, 0x80
    xor bl, bl
    mov cx, 128
    call idx_dump
    mov al, [cmos_70]
    out 0x70, al
    ret

dump_cmos:
    cli
    in al, 0x70
    mov [cmos_70], al
    mov eax, 'CMS0'
    call rec_begin
    mov al, [cmos_70]
    stosb
    mov dx, 0x70
    mov si, 0x71
    call cmos_bank
    call rec_end
    mov eax, 'CMS2'
    call rec_begin
    mov dx, 0x72
    mov si, 0x73
    call cmos_bank
    sti
    jmp rec_end

sio_enter:                      ; DX = config port -> CF = 0, interrupts off, in config mode, when a chip answers
    cli
    mov al, 0x55
    out dx, al
    out dx, al
    mov al, 0x20
    out dx, al
    inc dx
    in al, dx
    dec dx
    mov [sio_id], al
    cmp al, 0xff
    clc
    jne .ok
    mov al, 0xaa
    out dx, al
    sti
    stc
.ok:
    ret

sio_reg:                        ; DX = config port, AH = register, AL = value
    xchg al, ah
    out dx, al
    xchg al, ah
    inc dx
    out dx, al
    dec dx
    ret

dump_sio:
    mov dx, 0x370               ; the board straps the FDC37C93x configuration port at 370h
    call sio_enter
    jnc .found
    xor dx, dx
.found:
    mov eax, 'SIO '
    call rec_begin
    mov ax, dx
    stosw
    test dx, dx
    jz rec_end
    mov si, dx
    inc si
    mov al, 0x07
    out dx, al
    inc dx
    in al, dx
    dec dx
    mov [sio_ld], al
    mov al, 0x03
    out dx, al
    inc dx
    in al, dx
    dec dx
    mov [sio_cr03], al
    xor bx, bx
    mov cx, 0x30
    call idx_dump
    mov byte [cur_ld], 0
.ld:
    mov ax, 0x0700
    mov al, [cur_ld]
    call sio_reg
    mov bl, 0x30
.reg:
    mov al, 0xff
    cmp bl, 0xaa                ; AAh written to the index port exits the configuration mode: skipped
    je .store
    cmp bl, 0xf5                ; LD6 F5h, Read EEPROM Data: a read advances the EEPROM pointer, skipped
    jne .read
    cmp byte [cur_ld], 6
    je .store
.read:
    mov al, bl
    out dx, al
    inc dx
    in al, dx
    dec dx
.store:
    stosb
    inc bl
    jnz .reg
    inc byte [cur_ld]
    cmp byte [cur_ld], 10
    jb .ld
    call rec_end
    cmp byte [sio_id], 0x02     ; FDC37C93x: LD6 F0h bit 7 maps the upper 128 bytes at 70h/71h
    jne .exit
    mov ax, 0x0706
    call sio_reg
    mov al, 0xf0
    out dx, al
    inc dx
    in al, dx
    dec dx
    mov [rtc_mode], al
    or al, 0x80
    mov ah, 0xf0
    call sio_reg
    mov eax, 'CMS1'
    call rec_begin
    push dx
    push si
    mov dx, 0x70
    mov si, 0x71
    call cmos_bank
    pop si
    pop dx
    call rec_end
    mov ah, 0xf0
    mov al, [rtc_mode]
    call sio_reg
.exit:
    mov ah, 0x07
    mov al, [sio_ld]
    call sio_reg
    mov al, 0xaa
    out dx, al
    sti
    ret

dump_ports:
    mov eax, 'PORT'
    call rec_begin
    in al, 0x92
    stosb
    in al, 0x61
    stosb
    in al, 0x21
    stosb
    in al, 0xa1
    stosb
    jmp rec_end

dump_ide:                       ; status and alternate status, primary and secondary channel; no command
    mov eax, 'IDE '
    call rec_begin
    mov dx, 0x1f7
    in al, dx
    stosb
    mov dx, 0x3f6
    in al, dx
    stosb
    mov dx, 0x177
    in al, dx
    stosb
    mov dx, 0x376
    in al, dx
    stosb
    jmp rec_end

dump_cyrix:                     ; Cyrix configuration registers at 22h/23h, only on a Cyrix CPU
    cmp byte [has_cpuid], 0
    je .divide
    cmp dword [vendor + 8], 'tead'  ; CyrixInstead
    jne .done
    cmp dword [vendor], 'Cyri'
    jne .done
    jmp .cyrix
.divide:                        ; no CPUID: a Cyrix leaves the flags unchanged by DIV (the IBM BIOS's test)
    xor ax, ax
    sahf
    mov ax, 5
    mov bl, 2
    div bl
    lahf
    cmp ah, 2
    jne .done
.cyrix:
    mov eax, 'CYRX'
    call rec_begin
    cli
    mov dx, 0x22
    mov si, 0x23
    xor bh, bh
    mov bl, 0xc0
    mov cx, 16
    call idx_dump
    mov bl, 0xe8
    mov cx, 1
    call idx_dump
    mov bl, 0xfe
    mov cx, 2
    call idx_dump
    sti
    call rec_end
.done:
    ret

kbc_cmd:                        ; AL = 8042 command -> AL = its data byte, AH = 0, or AX = 01FFh on timeout
    mov bl, al
    mov cx, 16
.flush:
    in al, 0x64
    test al, 1
    jz .ready
    in al, 0x60
    loop .flush
.ready:
    mov ecx, 1000000
.ibf:
    in al, 0x64
    test al, 2
    jz .send
    dec ecx
    jnz .ibf
    jmp .timeout
.send:
    mov al, bl
    out 0x64, al
    mov ecx, 1000000
.obf:
    in al, 0x64
    test al, 1
    jnz .got
    dec ecx
    jnz .obf
.timeout:
    mov ax, 0x01ff
    ret
.got:
    in al, 0x60
    xor ah, ah
    ret

dump_kbc:
    mov eax, 'KBC '
    call rec_begin
    cli
    in al, 0x64
    stosb
    mov al, 0x20
    call kbc_cmd
    stosw
    mov al, 0xc0
    call kbc_cmd
    stosw
    mov al, 0xd0
    call kbc_cmd
    stosw
    in al, 0x64
    stosb
    sti
    jmp rec_end

; ---- header, then the floppy write

finish:                         ; header total length and byte sum
    call out_lin
    sub eax, BUF_SEG * 16
    mov [total], eax
    lea ecx, [eax - 16]
    mov esi, BUF_SEG * 16 + 16
    push ds
    xor ebx, ebx
.chunk:
    test ecx, ecx
    jz .done
    mov edx, 0x8000
    cmp ecx, edx
    jae .n
    mov edx, ecx
.n: sub ecx, edx
    push ecx
    push esi
    mov eax, esi
    shr eax, 4
    mov ds, ax
    and si, 15
    mov cx, dx
    xor eax, eax
.b: lodsb
    add ebx, eax
    loop .b
    pop esi
    pop ecx
    add esi, edx
    jmp .chunk
.done:
    pop ds
    mov ax, BUF_SEG
    mov fs, ax
    mov eax, [total]
    mov [fs:4], eax
    mov [fs:8], ebx
    ret

disk_io:                        ; AX = LBA, CL = sectors, CH = 2 read / 3 write, ES:BX = buffer -> CF on failure
    mov [dio_lba], ax
    mov [dio_cmd], cx
    mov bp, 3
.try:
    mov ax, [dio_lba]
    xor dx, dx
    div word [spt]
    mov cl, dl
    inc cl
    xor dx, dx
    div word [heads]
    mov ch, al
    shl ah, 6
    or cl, ah
    mov dh, dl
    mov dl, [drive]
    mov al, [dio_cmd]
    mov ah, [dio_cmd + 1]
    int 0x13
    jnc .ok
    xor ah, ah
    mov dl, [drive]
    int 0x13
    dec bp
    jnz .try
    stc
.ok:
    ret

write_dump:
    mov si, msg_drive
    cmp byte [drive], 0x80
    jae fail
    mov al, [nfats]
    xor ah, ah
    mul word [fatsz]
    add ax, [rsvd]
    mov [lba], ax               ; root directory
    mov ax, [rootents]
    shr ax, 4
    add ax, [lba]
    push ax                     ; first data sector = cluster 2
    push word IO_SEG
    pop es
    xor bx, bx
    mov ax, [lba]
    mov cx, 0x0201
    call disk_io
    mov si, msg_disk
    jc fail
    mov si, msg_file            ; DUMP.BIN must be the first root entry, start at cluster 2 and be large enough
    xor di, di
    push si
    mov si, dump_name
    mov cx, 11
    repe cmpsb
    pop si
    jne fail
    cmp word [es:26], 2
    jne fail
    mov eax, [total]
    cmp [es:28], eax
    jb fail
    pop word [lba]
    mov dword [src], BUF_SEG * 16
    add eax, 511
    shr eax, 9
    mov [left], ax
.track:
    mov ax, [lba]
    xor dx, dx
    div word [spt]
    mov ax, [spt]
    sub ax, dx
    cmp ax, [left]
    jbe .count
    mov ax, [left]
.count:
    mov [count], al
    push word IO_SEG
    pop es
    xor di, di
    movzx ecx, ax
    shl ecx, 9
    mov esi, [src]              ; the BIOS may change the upper half of 32-bit registers
    call copy_lin
    mov [src], esi
    push word IO_SEG
    pop es
    xor bx, bx
    mov ax, [lba]
    mov cl, [count]
    mov ch, 3
    call disk_io
    mov si, msg_disk
    jc fail
    mov bx, VERIFY
    mov ax, [lba]
    mov cl, [count]
    mov ch, 2
    call disk_io
    jc fail
    movzx cx, byte [count]
    shl cx, 9
    xor si, si
    mov di, VERIFY
    push ds
    push es
    pop ds
    repe cmpsb
    pop ds
    mov si, msg_verify
    jne fail
    movzx ax, byte [count]
    add [lba], ax
    sub [left], ax
    jnz .track
    ret

print_hex:                      ; EAX
    mov cx, 8
.d: rol eax, 4
    push eax
    and al, 15
    add al, '0'
    cmp al, '9'
    jbe .p
    add al, 7
.p: mov ah, 0x0e
    mov bx, 7
    int 0x10
    pop eax
    loop .d
    ret

msg_start  db 'realdump: reading the hardware', 13, 10, 0
msg_write  db 'realdump: writing DUMP.BIN', 13, 10, 0
msg_done   db 'realdump: done, bytes 0x', 0
msg_bytes  db '. Remove the floppy, power off.', 13, 10, 0
msg_drive  db 'realdump: not booted from a floppy drive', 13, 10, 0
msg_disk   db 'realdump: floppy I/O error', 13, 10, 0
msg_file   db 'realdump: DUMP.BIN missing or not at cluster 2 (rebuild the image)', 13, 10, 0
msg_verify db 'realdump: read-back mismatch', 13, 10, 0
dump_name  db 'DUMP    BIN'

align 4
pnp_entry  dd 0
total      dd 0
vendor     dd 0, 0, 0
has_cpuid  db 0
src        dd 0
rec_start  dd 0
rec_len    dd 0
pnp_sel    dw 0
pnp_ret    dw 0
node_size  dw 0
lba        dw 0
left       dw 0
dio_lba    dw 0
dio_cmd    dw 0
num_nodes  db 0
pnp_node   db 0
count      db 0
cmos_70    db 0
sio_id     db 0
sio_ld     db 0
sio_cr03   db 0
cur_ld     db 0
rtc_mode   db 0

    times (1 + PAYLOAD) * 512 - ($ - $$) db 0
