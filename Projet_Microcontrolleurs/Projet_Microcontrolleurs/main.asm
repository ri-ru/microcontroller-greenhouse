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
.equ	rc5_last_tog	= 0x0265	; dernier bit toggle (filtre auto-repeat RC5)
.equ	lcd_dirty	= 0x0266	; flag: 1 = ligne 2 LCD doit etre redessinee

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

	; --- ecran d'accueil (3s avant que Timer0/RC5 ne reprennent la main) ---
	rcall	LCD_home
	PRINTF	LCD
.db	"Hello gardener!",0
	WAIT_MS	3000
	rcall	LCD_clear

	; etat initial
	STI	mode_var,    MODE_NORMAL
	STI	target_temp, 25
	STI	window_open, 0
	STI	rc5_cmd,     0
	STI	rc5_new,     0
	STI	rc5_last_tog, 0xff		; valeur impossible -> 1ere pression valide
	STI	lcd_dirty,   1			; forcer 1er affichage

	; INT7: front descendant sur PE7
	OUTEI	EICRB, (1<<ISC71)
	OUTI	EIFR,  (1<<INTF7)		; effacer flag eventuel
	OUTI	EIMSK, (1<<INT7)		; activer INT7

	; Timer0: source asynchrone, interruption overflow active (ordre R)
	; TCCR0=5 -> prescaler 128 -> 32768/128/256 = 1 Hz (overflow ~1s)
	OUTI	TIMSK, (1<<TOIE0)		; Timer0 overflow IE
	OUTI	ASSR,  (1<<AS0)
	OUTI	TCCR0, 5
	sei

	; premiere conversion DS18B20 (declenche la suivante depuis l'ISR)
	; (la consigne b3:b2 est rechargee depuis target_temp dans l'ISR)
	rcall	wire1_reset
	CA	wire1_write, skipROM
	CA	wire1_write, convertT

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
	_JK	w, MODE_NORMAL, do_normal
	_JK	w, MODE_SET,    do_set
	_JK	w, MODE_SLEEP,  do_sleep
	ret

; --- NORMAL : RC5 peut declencher SET, SLEEP, open/close manuel ---
do_normal:
	lds	w, rc5_new
	tst	w
	breq	dn_end
	lds	a0, rc5_cmd
	STI	rc5_new, 0
	_JK	a0, KEY_SET,   to_set
	_JK	a0, KEY_POWER, to_sleep
	_JK	a0, KEY_OPEN,  open_window
	_JK	a0, KEY_CLOSE, close_window
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
	_JK	a0, KEY_POWER, to_sleep		; POWER en SET -> SLEEP
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

; === transitions de mode ===
to_normal:
	STI	mode_var, MODE_NORMAL
	STI	lcd_dirty, 1
	ret
to_set:
	STI	mode_var, MODE_SET
	STI	lcd_dirty, 1
	ret
to_sleep:
	STI	mode_var, MODE_SLEEP
	rjmp	close_window		; force fermeture en entrant en sleep (set aussi lcd_dirty)

; === reglage de la consigne (5..40 degC) ===
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

; === window control - stubs pour R ===
; TODO R: bouger le servo en position ouverte (M4, PORTB pin SERVO1)
open_window:
	STI	window_open, 1
	STI	lcd_dirty, 1
	ret
; TODO R: bouger le servo en position fermee
close_window:
	STI	window_open, 0
	STI	lcd_dirty, 1
	ret

; ==============================================================
;  overflow0 : ISR Timer0 (lecture temperature DS18B20)
; --------------------------------------------------------------
;  - lit la temperature (R: code de wire1_temp2.asm intact)
;  - affiche "temp=XX.YY C" sur la ligne 1 du LCD
;  - declenche la conversion suivante
;  - controle de la fenetre par seuil (skip en SLEEP) :
;      temp >= consigne -> open_window  (si pas deja ouverte)
;      temp <  consigne -> close_window (si pas deja fermee)
;  - consigne rechargee a chaque overflow depuis target_temp (SRAM)
;    -> b3:b2 = target_temp * 16  (format DS18B20, 1/16 degC)
; ==============================================================
overflow0:
	in	_sreg, SREG
	push	w
	push	u
	push	char			; r0 (PRINTF)
	push	e0			; r4 (PRINTF)
	push	e1			; r5 (PRINTF)
	push	c0			; r8 (swap LSB)
	push	a0
	push	a1
	push	a2
	push	a3
	push	b0
	push	b1
	push	b2
	push	b3
	push	xl
	push	xh
	push	yl
	push	yh
	push	zl
	push	zh

	; --- lecture temperature DS18B20 et affichage (code R) ---
	rcall	LCD_home			; ligne 1
	rcall	wire1_reset
	CA	wire1_write, skipROM
	CA	wire1_write, readScratchpad
	rcall	wire1_read			; LSB -> a0
	mov	c0, a0
	rcall	wire1_read			; MSB -> a0
	mov	a1, a0
	mov	a0, c0				; a1:a0 = temperature (format DS18B20)
	PRINTF	LCD
.db	"Temp: ",FFRAC2+FSIGN,a,4,$22," C  ",CR,0
	rcall	wire1_reset			; lance la prochaine conversion
	CA	wire1_write, skipROM
	CA	wire1_write, convertT

	; --- controle fenetre par seuil (skip en SLEEP) ---
	lds	w, mode_var
	cpi	w, MODE_SLEEP
	breq	ov_done

	; recharger la consigne: b3:b2 = target_temp * 16 (format DS18B20)
	lds	w, target_temp
	ldi	b3, 0
	mov	b2, w
	lsl	b2
	rol	b3
	lsl	b2
	rol	b3
	lsl	b2
	rol	b3
	lsl	b2
	rol	b3				; b3:b2 = target_temp << 4

	; comparer temp (a1:a0) a la consigne (b3:b2)
	mov	b0, a0
	mov	b1, a1
	sub	b0, b2
	sbc	b1, b3				; b1:b0 = temp - consigne (signe)
	brmi	ov_close			; N=1 -> temp < consigne

	; temp >= consigne : ouvrir si pas deja
	lds	w, window_open
	tst	w
	brne	ov_done
	rcall	open_window
	rjmp	ov_done

ov_close:
	lds	w, window_open
	tst	w
	breq	ov_done
	rcall	close_window

ov_done:
	pop	zh
	pop	zl
	pop	yh
	pop	yl
	pop	xh
	pop	xl
	pop	b3
	pop	b2
	pop	b1
	pop	b0
	pop	a3
	pop	a2
	pop	a1
	pop	a0
	pop	c0
	pop	e1
	pop	e0
	pop	char
	pop	u
	pop	w
	out	SREG, _sreg
	reti

; === LCD refresh ===
;  Ligne 1 = "temp=XX.YY C" -- ecrite par overflow0 (~1 fois/s).
;  Ligne 2 = etat (mode/consigne/fenetre) -- ecrite ici, seulement
;  quand un changement d'etat a leve lcd_dirty.
lcd_refresh:
	lds	w, lcd_dirty
	tst	w
	breq	lr_skip
	STI	lcd_dirty, 0
	lds	w, mode_var
	_JK	w, MODE_NORMAL, show_normal
	_JK	w, MODE_SET,    show_set
	_JK	w, MODE_SLEEP,  show_sleep
lr_skip:
	ret

show_normal:
	rcall	LCD_lf
	lds	w, window_open
	tst	w
	brne	show_normal_open
	PRINTF	LCD
.db	"Set:",FDEC|FDIG2,low(target_temp),"C Closed  ",0
	ret
show_normal_open:
	PRINTF	LCD
.db	"Set:",FDEC|FDIG2,low(target_temp),"C Open    ",0
	ret

show_set:
	rcall	LCD_lf
	PRINTF	LCD
.db	"Set:",FDEC|FDIG2,low(target_temp),"C <EDIT>  ",0
	ret

show_sleep:
	rcall	LCD_lf
	PRINTF	LCD
.db	"Sleeping...     ",0
	ret
