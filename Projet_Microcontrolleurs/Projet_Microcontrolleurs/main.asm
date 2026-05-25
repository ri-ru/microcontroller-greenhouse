; file	main.asm   target ATmega128L-4MHz-STK300
; purpose serre: state-machine skeleton (NORMAL / SET / SLEEP)
;         RC5 remote drives the modes, LCD shows status,
;         servo + temp are R's parts (stubs for now)

.include "macros.asm"
.include "definitions.asm"

; === mode codes ===
.equ	MODE_NORMAL	= 0
.equ	MODE_SET	= 1
.equ	MODE_SLEEP	= 2

; === SRAM state (printf-compatible range 0x0260..0x02ff) ===
.equ	mode_var	= 0x0260
.equ	target_temp	= 0x0261	; consigne en degC
.equ	window_open	= 0x0262	; 0=closed, 1=open
.equ	rc5_cmd		= 0x0263	; last RC5 command byte
.equ	rc5_new		= 0x0264	; flag: 1 = fresh cmd waiting

; === RC5 button codes (placeholders, a calibrer avec le scope) ===
.equ	KEY_SET		= 0x12
.equ	KEY_UP		= 0x20
.equ	KEY_DOWN	= 0x21
.equ	KEY_POWER	= 0x0c
.equ	KEY_OPEN	= 0x10
.equ	KEY_CLOSE	= 0x11

; === reset vector ===
.org	0
	jmp	reset

reset:
	LDSP	RAMEND
	in	w, MCUCR			; enable external SRAM (LCD memory map)
	sbr	w, (1<<SRE)+(1<<SRW10)
	out	MCUCR, w
	rcall	LCD_init

	; etat initial
	STI	mode_var,    MODE_NORMAL
	STI	target_temp, 25
	STI	window_open, 0
	STI	rc5_new,     0
	rjmp	main

.include "lcd.asm"
.include "printf.asm"

; ==============================================================
;  main loop : poll RC5 -> dispatch -> refresh LCD
; ==============================================================
main:
	rcall	poll_rc5
	rcall	dispatch
	rcall	lcd_refresh
	rjmp	main

; === mode dispatch ===
dispatch:
	lds	w, mode_var
	JK	w, MODE_NORMAL, do_normal
	JK	w, MODE_SET,    do_set
	JK	w, MODE_SLEEP,  do_sleep
	ret

; --- NORMAL : RC5 can trigger SET, SLEEP, open/close manuel ---
do_normal:
	lds	w, rc5_new
	tst	w
	breq	dn_end
	lds	a0, rc5_cmd
	STI	rc5_new, 0
	JK	a0, KEY_SET,   to_set
	JK	a0, KEY_POWER, to_sleep
	JK	a0, KEY_OPEN,  open_window
	JK	a0, KEY_CLOSE, close_window
dn_end:
	ret

; --- SET : RC5 ajuste la temperature cible ---
do_set:
	lds	w, rc5_new
	tst	w
	breq	ds_end
	lds	a0, rc5_cmd
	STI	rc5_new, 0
	JK	a0, KEY_SET,  to_normal
	JK	a0, KEY_UP,   target_up
	JK	a0, KEY_DOWN, target_down
ds_end:
	ret

; --- SLEEP : seulement POWER reveille, fenetre forcee fermee ---
do_sleep:
	lds	w, rc5_new
	tst	w
	breq	dz_end
	lds	a0, rc5_cmd
	STI	rc5_new, 0
	JK	a0, KEY_POWER, to_normal
dz_end:
	ret

; === transitions de mode ===
to_normal:
	STI	mode_var, MODE_NORMAL
	ret
to_set:
	STI	mode_var, MODE_SET
	ret
to_sleep:
	STI	mode_var, MODE_SLEEP
	rjmp	close_window		; force fermeture en entrant en sleep

; === reglage de la consigne (5..40 degC) ===
target_up:
	lds	w, target_temp
	cpi	w, 40
	brsh	tu_end
	inc	w
	sts	target_temp, w
tu_end:
	ret
target_down:
	lds	w, target_temp
	cpi	w, 5
	brlo	td_end
	dec	w
	sts	target_temp, w
td_end:
	ret

; === window control - stubs pour R ===
; TODO R: bouger le servo en position ouverte (M4, PORTB pin SERVO1)
open_window:
	STI	window_open, 1
	ret
; TODO R: bouger le servo en position fermee
close_window:
	STI	window_open, 0
	ret

; === RC5 input - stub pour V ===
; TODO V: quand une trame RC5 vient d'etre decodee,
;         stocker l'octet de commande dans rc5_cmd
;         et mettre rc5_new = 1
poll_rc5:
	ret

; === LCD refresh ===
lcd_refresh:
	lds	w, mode_var
	JK	w, MODE_NORMAL, show_normal
	JK	w, MODE_SET,    show_set
	JK	w, MODE_SLEEP,  show_sleep
	ret

show_normal:
	rcall	LCD_home
	PRINTF	LCD
.db	"NORMAL          ",LF,"set=",FDEC,low(target_temp)," win=",FDEC,low(window_open),"   ",0
	ret

show_set:
	rcall	LCD_home
	PRINTF	LCD
.db	"SET MODE        ",LF,"target=",FDEC,low(target_temp)," degC ",0
	ret

show_sleep:
	rcall	LCD_home
	PRINTF	LCD
.db	"SLEEPING        ",LF,"window closed   ",0
	ret
