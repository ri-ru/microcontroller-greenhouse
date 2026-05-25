; file	main.asm   target ATmega128L-4MHz-STK300
; purpose serre: state-machine (NORMAL / SET / SLEEP), LCD, RC5 ISR
;         RC5 decode par interruption (INT7 sur PE7),
;         servo et temperature: parties de R (stubs ici)

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
.equ	rc5_cmd		= 0x0263	; derniere commande RC5
.equ	rc5_new		= 0x0264	; flag: 1 = commande fraiche

; === RC5 button codes (Vivanco UR Z2, releves le 2026-05-25) ===
; bouton    code   usage
; ------    ----   -----
; 0..9      00..09 -
; -/--      0x0a   libre
; POWER     0x0c   toggle SLEEP
; MUTE      0x0d   libre
; VOL+      0x10   OPEN  (fenetre)
; VOL-      0x11   CLOSE (fenetre)
; CH+       0x20   UP    (consigne)
; CH-       0x21   DOWN  (consigne)
; GUIDE     0x22   libre
; AV        0x38   SET   (entree/sortie mode SET)
; SET/TV/DVB/FAV : pas d'emission RC5 (boutons de config remote)
.equ	KEY_SET		= 0x38		; AV
.equ	KEY_UP		= 0x20		; CH+
.equ	KEY_DOWN	= 0x21		; CH-
.equ	KEY_POWER	= 0x0c		; POWER
.equ	KEY_OPEN	= 0x10		; VOL+
.equ	KEY_CLOSE	= 0x11		; VOL-

; === interrupt vector table ===
.org	0
	jmp	reset
.org	INT7addr
	rjmp	rc5_isr			; RC5 (V)
.org	OVF0addr
	rjmp	overflow0		; Timer0 overflow -> lecture temperature (R)

reset:
	LDSP	RAMEND
	in	w, MCUCR			; enable external SRAM (LCD)
	sbr	w, (1<<SRE)+(1<<SRW10)
	out	MCUCR, w

	cbi	DDRE,  IR			; PE7 en entree (recepteur IR)
	cbi	PORTE, IR			; pas de pull-up interne

	rcall	wire1_init			; init bus 1-wire (R: capteur DS18B20)
	rcall	LCD_init

	; etat initial
	STI	mode_var,    MODE_NORMAL
	STI	target_temp, 25
	STI	window_open, 0
	STI	rc5_cmd,     0
	STI	rc5_new,     0

	; consigne pour la comparaison de R (b3:b2 = 25 degC en format DS18B20, 1/16e degC)
	ldi	b2, 0b10010000			; 0x0190 = 400 = 25 * 16
	ldi	b3, 0b00000001

	; INT7: front descendant sur PE7
	OUTEI	EICRB, (1<<ISC71)
	OUTI	EIFR,  (1<<INTF7)		; effacer flag eventuel
	OUTI	EIMSK, (1<<INT7)		; activer INT7

	; Timer0: source asynchrone (R), interruption overflow active
	OUTI	ASSR,  (1<<AS0)
	OUTI	TCCR0, 1			; prescaler = 1
	OUTI	TIMSK, (1<<TOIE0)		; Timer0 overflow IE

	; premiere conversion DS18B20 (declenche la suivante depuis l'ISR)
	rcall	wire1_reset
	CA	wire1_write, skipROM
	CA	wire1_write, convertT

	sei
	rjmp	main

.include "lcd.asm"
.include "printf.asm"
.include "wire1.asm"
.include "ir_rc5.asm"

; ==============================================================
;  main loop : dispatch sur le mode -> rafraichir LCD
;  (la commande RC5 est deposee par l'ISR, on lit juste rc5_new)
; ==============================================================
main:
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

; --- NORMAL : RC5 peut declencher SET, SLEEP, open/close manuel ---
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

; ==============================================================
;  overflow0 : ISR Timer0 (lecture temperature DS18B20)
; --------------------------------------------------------------
;  PLACEHOLDER. R: colle ici le corps de ton ISR overflow0 de
;  wire1_temp2.asm. Conventions pour eviter de casser le main loop :
;
;    - b2, b3 = consigne en format DS18B20 (initialises en reset,
;      a ne PAS modifier ni dans l'ISR ni dans le main loop).
;      Pour relire la consigne SRAM (target_temp en degC) :
;        lds w, target_temp ; ldi b3, 0 ; mov b2, w
;        lsl b2 ; rol b3 ; lsl b2 ; rol b3
;        lsl b2 ; rol b3 ; lsl b2 ; rol b3   ; *16 -> format DS18B20
;
;    - L'ISR doit empiler SREG (via _sreg = r1) puis tous les
;      registres modifies par les routines appelees :
;      au minimum r0, w, u, a0..a3, b0, b1, c0, x, y, z.
;
;    - rcall open_window / close_window est OK : ces routines sont
;      definies plus haut et mettent a jour window_open dans la SRAM
;      (a remplacer par la commande servo le moment venu).
; ==============================================================
overflow0:
	in	_sreg, SREG
	; TODO R: pousser les registres, copier le corps de l'ISR de
	;         wire1_temp2.asm, depiler, puis reti.
	out	SREG, _sreg
	reti

; === LCD refresh ===
lcd_refresh:
	lds	w, mode_var
	JK	w, MODE_NORMAL, show_normal
	JK	w, MODE_SET,    show_set
	JK	w, MODE_SLEEP,  show_sleep
	ret

show_normal:
	rcall	LCD_home
	PRINTF	LCD				; DEBUG: 'last=XX' = dernier code RC5 recu (a retirer apres capture)
.db	"NORMAL  last=",FHEX,low(rc5_cmd)," ",LF,"set=",FDEC|FDIG2,low(target_temp)," win=",FDEC,low(window_open),"    ",0
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
