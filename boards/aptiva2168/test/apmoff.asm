; DOS test: APM power off (INT 15h AX=5307h, all devices, state 3) through the real-mode interface.
; -DIBM: the IBM BIOS's soft off routine itself (runtime F000:5405, it does not return), as its APM needs an SMI.
org 100h
%ifdef IBM
        mov dx, off
        mov ah, 9
        int 21h
        cli
        jmp 0F000h:5405h
%else
        mov ax, 5300h                   ; installation check
        xor bx, bx
        int 15h
        mov dx, absent
        jc print
        mov ax, 5301h                   ; real-mode connect
        xor bx, bx
        int 15h
        mov dx, off
        mov ah, 9
        int 21h
        mov ax, 5307h
        mov bx, 1
        mov cx, 3
        int 15h
        mov dx, back
print:  mov ah, 9
        int 21h
        ret
absent: db 'APM-ABSENT', 13, 10, '$'
back:   db 'APM-OFF-RETURNED', 13, 10, '$'
%endif
off:    db 'APM-OFF', 13, 10, '$'
