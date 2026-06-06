; file	main.asm   target ATmega128L-4MHz-STK300
; purpose serre: state-machine (NORMAL / SET / SLEEP), boucle principale,
;         vector table. RC5 decode dans ir_rc5.asm, temperature dans
;         thermo.asm, servo (fenetre) dans servo.asm, affichage dans
;         display.asm.

.include "macros.asm"
.include "definitions.asm"

; === mode codes ===
.equ	MODE_NORMAL	= 0
.equ	MODE_SET	= 1
.equ	MODE_SLEEP	= 2
.equ	MODE_HISTORY	= 3

; === SRAM state (printf-compatible range 0x0260..0x02ff) ===
.equ	mode_var	= 0x0260
.equ	target_temp	= 0x0261	; consigne en degC
.equ	window_open	= 0x0262	; 0=closed, 1=open
.equ	rc5_cmd		= 0x0263	; derniere commande RC5
.equ	rc5_new		= 0x0264	; flag: 1 = nouvelle commande à traiter
.equ	rc5_last_tog	= 0x0265	; dernier bit toggle (filtre auto-repeat RC5)
.equ	lcd_dirty	= 0x0266	; flag: 1 = ligne haut du LCD doit etre redessinee
.equ	min_temp	= 0x0267	; mirror SRAM du min EEPROM (16-bit signe)
.equ	max_temp	= 0x0269	; mirror SRAM du max EEPROM (16-bit signe)
.equ	convertT_ended	= 0x026b	; flag: Timer0 leve, main loop appelle readT

; === RC5 button codes (Vivanco UR Z2, releves le 2026-05-25) ===
; bouton    code   usage
; ------    ----   -----
; 0..9      00..09 unused
; -/--      0x0a   unused
; POWER     0x0c   toggle SLEEP
; MUTE      0x0d   unused
; CH+       0x20   UP    (consigne)
; CH-       0x21   DOWN  (consigne)
; GUIDE     0x22   HISTORY mode (enter or escape it)
; AV        0x38   SET (enter or escape it)
; SET/TV/DVB/FAV : pas d'emission RC5 (boutons de config remote)
.equ	KEY_SET		= 0x38		
.equ	KEY_UP		= 0x20		
.equ	KEY_DOWN	= 0x21		
.equ	KEY_POWER	= 0x0c	
.equ	KEY_HIST	= 0x22

; === interrupt vector table ===
.org	0
	jmp	reset
.org	INT7addr
	rjmp	rc5_isr			; RC5 dans ir_rc5.asm
.org	OVF0addr
	rjmp	overflow0		; dans thermo.asm
.org	0x30

overflow0:
	STI	convertT_ended, 1
	reti
; --- librairies (incluses ici pour que PRINTF/LCD_* soient definis
;     avant reset, qui les utilise pour l'ecran d'accueil) ---
.include "lcd.asm"
.include "printf.asm"
.include "wire1.asm"
.include "ir_rc5.asm"
.include "servo.asm"
.include "eeprom.asm"
.include "thermo.asm"
.include "display.asm"

reset:
	LDSP	RAMEND
	in	w, MCUCR			; enable external SRAM (LCD)
	sbr	w, (1<<SRE)+(1<<SRW10)
	out	MCUCR, w

	cbi	DDRE,  IR			; PE7 en entree (recepteur IR)
	cbi	PORTE, IR
	OUTEI	DDRF,  (1<<SERVO1)		; PF4 en sortie
	OUTEI	PORTF, 0

	rcall	wire1_init
	rcall	LCD_init
	rcall	history_init			; charger min/max EEPROM -> SRAM (ou init 1er boot)

	; --- ecran d'accueil ---
	rcall	do_splash

	; etat initial
	STI	mode_var,    MODE_NORMAL
	STI	target_temp, 25
	STI	window_open, 0
	STI	rc5_cmd,     0
	STI	rc5_new,     0
	STI	rc5_last_tog, 0xff		; valeur imposible pour s'assurer que la première commande set rc5_new
	STI	lcd_dirty,   1			
	STI	convertT_ended, 0		

	; INT7: front descendant sur PE7
	OUTEI	EICRB, (1<<ISC71)
	OUTI	EIFR,  (1<<INTF7)
	OUTI	EIMSK, (1<<INT7)		; activer INT7

	
	
	OUTI	TIMSK, (1<<TOIE0)		; Timer0 overflow IE
	OUTI	ASSR,  (1<<AS0)			; Timer0: source asynchrone 32kHz
	OUTI	TCCR0, 5				; CS0x=5 -> prescaler 128 -> 32768/128/256 = 1 Hz
	sei
	rcall	wire1_reset
	CA	wire1_write, skipROM
	CA	wire1_write, convertT

	rjmp	main


main:
	OUTEI	PORTF, 0

	WAIT_US	18000

	rcall	dispatch
	lds	w, convertT_ended
	tst	w
	breq	m_no_temp
	rcall	readT
m_no_temp:
	rcall	lcd_refresh
	OUTEI	PORTF, (1<<SERVO1)
	lds	w, window_open
	tst	w
	breq	m_pulse_close
	WAIT_US	1900
	rjmp	m_pulse_end
m_pulse_close:
	WAIT_US	1520
m_pulse_end:
	OUTEI	PORTF, 0
	rjmp	main

; === mode dispatch ===
dispatch:
	lds	w, mode_var
	_JK	w, MODE_NORMAL,  do_normal
	_JK	w, MODE_SET,     do_set
	_JK	w, MODE_SLEEP,   do_sleep
	_JK	w, MODE_HISTORY, do_history
	ret

; --- NORMAL : RC5 peut declencher SET, SLEEP, open/close manuel, HISTORY ---
do_normal:
	lds	w, rc5_new
	tst	w
	breq	dn_end
	lds	a0, rc5_cmd
	STI	rc5_new, 0
	_JK	a0, KEY_SET,   to_set
	_JK	a0, KEY_POWER, to_sleep
	_JK	a0, KEY_HIST,  to_history
dn_end:
	ret

; --- SET : RC5 ajuste la temperature cible ---
do_set:
	lds	w, rc5_new
	tst	w
	breq	ds_end
	lds	a0, rc5_cmd
	STI	rc5_new, 0
	_JK	a0, KEY_SET,   to_normal
	_JK	a0, KEY_POWER, to_sleep
	_JK	a0, KEY_UP,    target_up
	_JK	a0, KEY_DOWN,  target_down
ds_end:
	ret

; --- SLEEP : seulement POWER reveille, fenetre forcee fermee ---
do_sleep:
	lds	w, rc5_new
	tst	w
	breq	dz_end
	lds	a0, rc5_cmd
	STI	rc5_new, 0
	_JK	a0, KEY_POWER, to_normal
dz_end:
	ret

; --- HISTORY : GUIDE -> escape to NORMAL, POWER -> SLEEP ---
do_history:
	lds	w, rc5_new
	tst	w
	breq	dh_end
	lds	a0, rc5_cmd
	STI	rc5_new, 0
	_JK	a0, KEY_HIST,  to_normal
	_JK	a0, KEY_POWER, to_sleep
dh_end:
	ret

; === transitions de mode ===
to_normal:
	lds	w, mode_var			; w = ancien mode
	cpi	w, MODE_SLEEP
	breq	tn_from_sleep
	cpi	w, MODE_HISTORY
	breq	tn_from_history
	STI	mode_var, MODE_NORMAL
	STI	lcd_dirty, 1
	ret

tn_from_sleep:
	STI	mode_var, MODE_NORMAL
	STI	lcd_dirty, 1
	rcall	do_splash
	ret

tn_from_history:
	STI	mode_var, MODE_NORMAL
	STI	lcd_dirty, 1
	rcall	LCD_clear	
	ret
to_set:
	STI	mode_var, MODE_SET
	STI	lcd_dirty, 1
	ret
to_history:
	STI	mode_var, MODE_HISTORY
	STI	lcd_dirty, 1
	ret
to_sleep: ;closing of the window and goodbye splash for 2 sec then go to sleep
	STI	mode_var, MODE_SLEEP
	rcall	close_window
	rcall	LCD_home
	PRINTF	LCD
.db	"Sleeping...     ",LF,"                ",0
	WAIT_MS	2000
	rcall	LCD_clear
	STI	lcd_dirty, 0
	ret

; === reglage de la consigne de 5 à 40 degC ===
target_up:
	lds	w, target_temp
	cpi	w, 40
	brsh	tu_end
	inc	w
	sts	target_temp, w
	STI	lcd_dirty, 1
tu_end:
	ret
target_down:
	lds	w, target_temp
	cpi	w, 5
	brlo	td_end
	dec	w
	sts	target_temp, w
	STI	lcd_dirty, 1
td_end:
	ret
