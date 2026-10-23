; DOS test of the shadow RAM after POST: the ISA option ROM at D800:0 is visible, and its block, the VGA BIOS
; (C000:0), the E and F segments are read-only (a write to their first byte does not change it).
org 100h
        mov ax, 0D800h
        mov es, ax
        mov dx, no_rom
        cmp word [es:0], 0AA55h
        jne print
        mov si, segs
next:   lodsw
        or ax, ax
        jz pass
        mov es, ax
        mov dx, si
        mov al, [es:0]
        not byte [es:0]
        cmp al, [es:0]
        mov [es:0], al
        jne writable
        add si, 5
        jmp next
pass:   mov dx, ok
        jmp print
writable:
        push dx
        mov dx, wr
        mov ah, 9
        int 21h
        pop dx
print:  mov ah, 9
        int 21h
        ret
segs:   dw 0D800h
        db 'D800$'
        dw 0C000h
        db 'C000$'
        dw 0E000h
        db 'E000$'
        dw 0F000h
        db 'F000$'
        dw 0
wr:     db 'SHADOW-FAIL: writable $'
ok:     db 'SHADOW-OK', 13, 10, '$'
no_rom: db 'SHADOW-FAIL: no ROM at D800', 13, 10, '$'
