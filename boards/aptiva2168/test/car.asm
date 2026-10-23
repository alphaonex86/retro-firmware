; Cache-as-RAM probe ROM for the emulated Aptiva 2168 (car.sh): 128 KiB, real mode, no stack, no RAM but the probes.
; The 8 KiB range 20000h-21FFFh is read into the P54C's L1 data cache (2-way, 32-byte lines, 128 sets) with
; CR0.CD = NW = 0, then CD = NW = 1 keeps it; 82C557M 13h = 88h leaves no DRAM decoded (00h = 0, the reset default,
; is 2 MB of DRAM). Each check sends its POST code when it passes; a failure sends EEh, then the check's code, and halts.
;   01 DRAM answers: 20000h-23FFFh hold their marker (address ^ D0000000h)
;   02 CAR self-test with no DRAM decoded: each dword its address ^ 5A5A5A5Ah
;   03 a write outside the CAR lines is lost: it reads FFFFFFFFh
;   04 INVD drops the CAR lines (write-through: 08h bit 1 = 0): DRAM still holds the marker
;   05 more than 8 KiB evicts the least recently used way: 20000h read again, then 22000h and 22020h, evict 21000h
;      and 20020h; a code fetch from 22040h (set 2) evicts nothing
;   06 INVD loses Modified lines (write-back, 08h bit 1 = 1)
;   07 WBINVD writes Modified lines back
;   08 WBINVD drops write-through lines without writing them
;   09 KEN#: no line fills in a non-cacheable DRAM hole (09h hole A, 512 KB at 0)
bits 16
org 0

%define MARKER 0xd0000000

%macro post 1
    mov al, %1
    out 0x80, al
%endmacro

%macro sysc 2   ; 82C557M index, value
    mov al, %1
    out 0x22, al
    mov al, %2
    out 0x24, al
%endmacro

%macro cache_fill 0   ; INVD, CD = NW = 0, read the 8 KiB range
    mov eax, cr0
    and eax, ~0x60000000
    invd
    mov cr0, eax
    xor si, si
    mov cx, 0x800
    rep lodsd
%endmacro

%macro car_on 0   ; CD = NW = 1
    mov eax, cr0
    or eax, 0x60000000
    mov cr0, eax
%endmacro

%macro fill 3   ; DS offset, bytes, pattern: each dword its linear address ^ pattern
    mov di, %1
%%next:
    movzx eax, di
    add eax, 0x20000
    xor eax, %3
    mov [di], eax
    add di, 4
    cmp di, %1 + %2
    jne %%next
%endmacro

%macro check 4   ; DS offset, bytes, pattern, POST code of the check
    mov di, %1
    mov bl, %4
%%next:
    movzx eax, di
    add eax, 0x20000
    xor eax, %3
    cmp [di], eax
    jne fail
    add di, 4
    cmp di, %1 + %2
    jne %%next
%endmacro

%macro expect 3   ; DS offset, dword, POST code of the check
    mov bl, %3
    cmp dword [%1], %2
    jne fail
%endmacro

    times 0x10000 db 0xff   ; F000:0000 from here

start:
    cli
    cld
    mov ax, 0x2000
    mov ds, ax
    fill 0, 0x4000, MARKER
    mov byte [0x2040], 0xea         ; at 22040h: jmp far F000:back
    mov word [0x2041], back - 0x10000
    mov word [0x2043], 0xf000
    check 0, 0x2000, MARKER, 0x01
    post 0x01

    cache_fill
    car_on
    sysc 0x13, 0x88
    fill 0, 0x2000, 0x5a5a5a5a
    check 0, 0x2000, 0x5a5a5a5a, 0x02
    post 0x02

    mov dword [0x3000], 0x12345678
    expect 0x3000, 0xffffffff, 0x03
    post 0x03

    sysc 0x13, 0x00
    invd
    check 0, 0x2000, MARKER, 0x04
    post 0x04

    cache_fill
    mov eax, [0x0000]
    mov eax, [0x2000]
    mov eax, [0x2020]
    jmp 0x2204:0x0000
back:
    car_on
    sysc 0x13, 0x88
    expect 0x0000, 0x20000 ^ MARKER, 0x05
    expect 0x1000, 0xffffffff, 0x05
    expect 0x2000, 0x22000 ^ MARKER, 0x05
    expect 0x0020, 0xffffffff, 0x05
    expect 0x1020, 0x21020 ^ MARKER, 0x05
    expect 0x2020, 0x22020 ^ MARKER, 0x05
    expect 0x0040, 0x20040 ^ MARKER, 0x05
    expect 0x1040, 0x21040 ^ MARKER, 0x05
    post 0x05

    sysc 0x13, 0x00
    sysc 0x08, 0x02
    cache_fill
    car_on
    fill 0, 0x2000, 0xa5a5a5a5
    invd
    check 0, 0x2000, MARKER, 0x06
    post 0x06

    cache_fill
    car_on
    fill 0, 0x2000, 0xa5a5a5a5
    wbinvd
    check 0, 0x2000, 0xa5a5a5a5, 0x07
    post 0x07

    sysc 0x08, 0x00
    cache_fill
    car_on
    fill 0, 0x2000, 0x3c3c3c3c
    wbinvd
    check 0, 0x2000, 0xa5a5a5a5, 0x08
    post 0x08

    sysc 0x09, 0x02
    cache_fill
    car_on
    sysc 0x13, 0x88
    expect 0x0000, 0xffffffff, 0x09
    expect 0x1fe0, 0xffffffff, 0x09
    post 0x09
halt:
    hlt
    jmp halt

fail:
    post 0xee
    mov al, bl
    out 0x80, al
    jmp halt

    times 0x1fff0 - ($ - $$) db 0xff
    jmp 0xf000:(start - 0x10000)
    times 0x20000 - ($ - $$) db 0xff
