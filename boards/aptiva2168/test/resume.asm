; DOS test: back from CPU-only resets by the CMOS shutdown code (0Fh) and the far pointer at 40h:67h, the 286 way out
; of protected mode: 0Ah (jump) through port 92h, 05h (EOI, jump) through the 8042, 06h (the IBM BIOS's jump) through
; port 92h. Each return prints RESUME-<code>-OK and CMOS 0Fh, which the BIOS must have cleared.
org 100h
%macro reset_to 3                       ; shutdown code, return label, 92 or 64
        cli
        mov [stack], sp
        xor ax, ax
        mov es, ax
        mov word [es:467h], %2
        mov [es:469h], cs
        mov al, 8Fh
        out 70h, al
        mov al, %1
        out 71h, al
%if %3 == 92
        in al, 92h
        and al, 0FEh
        out 92h, al
        or al, 1
        out 92h, al
%else
        mov al, 0FEh
        out 64h, al
%endif
%%halt: hlt
        jmp %%halt
%2:     mov ax, cs
        mov ds, ax
        mov es, ax
        mov ss, ax
        mov sp, [stack]
        sti
        mov dx, ok%1
        call print
%endmacro

        reset_to 0Ah, back0a, 92
        reset_to 05h, back05, 64
        reset_to 06h, back06, 92
        ret

print:  mov ah, 9                       ; the message at DX, then CMOS 0Fh in hex
        int 21h
        mov al, 8Fh
        out 70h, al
        in al, 71h
        mov bl, al
        shr al, 4
        call digit
        mov al, bl
        call digit
        mov dx, crlf
        mov ah, 9
        int 21h
        ret
digit:  and al, 0Fh
        add al, '0'
        cmp al, '9'
        jbe .out
        add al, 'A' - '9' - 1
.out:   mov dl, al
        mov ah, 2
        int 21h
        ret

stack:  dw 0
ok0Ah:  db 'RESUME-0A-OK 0Fh=$'
ok05h:  db 'RESUME-05-OK 0Fh=$'
ok06h:  db 'RESUME-06-OK 0Fh=$'
crlf:   db 13, 10, '$'
