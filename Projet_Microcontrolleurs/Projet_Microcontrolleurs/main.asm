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
.equ	rc5_new		= 0x0264	; flag: 1 = commande fraiche
.equ	rc5_last_tog	= 0x0265	; dernier bit toggle (filtre auto-repeat RC5)
.equ	lcd_dirty	= 0x0266	; flag: 1 = ligne 2 LCD doit etre redessinee
.equ	min_temp	= 0x0267	; mirror SRAM du min EEPROM (16-bit signe)
.equ	max_temp	= 0x0269	; mirror SRAM du max EEPROM (16-bit signe)
.equ	convertT_ended	= 0x026b	; flag: Timer0 leve, main loop appelle readT

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
.equ	KEY_HIST	= 0x22		; GUIDE -> HISTORY (toggle)

; === interrupt vector table ===
.org	0
	jmp	reset
.org	INT7addr
	rjmp	rc5_isr			; RC5 (V) - dans ir_rc5.asm
.org	OVF0addr
	rjmp	overflow0		; Timer0 -> temperature (R) - dans thermo.asm

; --- librairies (incluses ici pour que PRINTF/LCD_* soient definis
;     avant reset, qui les utilise pour l'ecran d'accueil) ---
.include "lcd.asm"
.include "printf.asm"
.include "wire1.asm"
.include "ir_rc5.asm"
.include "servo.asm"			; open_window / close_window (servo PWM)
.include "eeprom.asm"			; history_init, history_update + driver EEPROM
.include "thermo.asm"			; overflow0 (lecture DS18B20 + seuil)
.include "display.asm"			; lcd_refresh, show_*, do_splash

reset:
	LDSP	RAMEND
	in	w, MCUCR			; enable external SRAM (LCD)
	sbr	w, (1<<SRE)+(1<<SRW10)
	out	MCUCR, w

	cbi	DDRE,  IR			; PE7 en entree (recepteur IR)
	cbi	PORTE, IR			; pas de pull-up interne

	; PORTA/PORTC pris par le bus d'adresse externe (SRE) -> servo sur PORTF.
	; PORTF est en I/O etendu (>0x3F) : sbi/cbi/in/out interdits, on
	; passe par OUTEI (sts) et lds/sts.
	; (note: PF4 = JTAG TCK par defaut, fusible JTAGEN doit etre desactive)
	OUTEI	DDRF,  (1<<SERVO1)		; PF4 en sortie
	OUTEI	PORTF, 0			; idle bas

	rcall	wire1_init			; init bus 1-wire (R: capteur DS18B20)
	rcall	LCD_init
	rcall	history_init			; charger min/max EEPROM -> SRAM (ou init 1er boot)

	; --- ecran d'accueil (2s avant que Timer0/RC5 ne reprennent la main) ---
	rcall	do_splash

	; etat initial
	STI	mode_var,    MODE_NORMAL
	STI	target_temp, 25
	STI	window_open, 0
	STI	rc5_cmd,     0
	STI	rc5_new,     0
	STI	rc5_last_tog, 0xff		; valeur impossible -> 1ere pression valide
	STI	lcd_dirty,   1			; forcer 1er affichage
	STI	convertT_ended, 0		; pas de readT a faire au demarrage

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

; ==============================================================
;  main loop : dispatch sur le mode -> rafraichir LCD
;  (la commande RC5 est deposee par l'ISR, on lit juste rc5_new)
; ==============================================================
; --- TP10-style servo PWM, melangee a la boucle principale ---
; Periode ~20 ms : pin LOW (~18 ms WAIT) -> dispatch/readT/lcd_refresh
; -> pin HIGH (1.52 ou 1.9 ms selon window_open) -> retour pin LOW.
; readT (lecture DS18B20) ne tourne que quand le flag Timer0 est leve,
; donc la plupart des iterations sont rapides et le servo voit ~50 Hz.
main:
	; pin LOW (PF4) -- lds/sts car PORTF est en I/O etendu
	lds	w, PORTF
	andi	w, ~(1<<SERVO1)
	sts	PORTF, w

	WAIT_US	18000				; phase basse, le servo "se repose"

	rcall	dispatch
	lds	w, convertT_ended
	tst	w
	breq	m_no_temp
	rcall	readT
m_no_temp:
	rcall	lcd_refresh

	; pin HIGH (PF4)
	lds	w, PORTF
	ori	w, (1<<SERVO1)
	sts	PORTF, w

	; largeur d'impulsion : 1.9 ms ouvert, 1.52 ms ferme
	lds	w, window_open
	tst	w
	breq	m_pulse_close
	WAIT_US	1900
	rjmp	m_pulse_end
m_pulse_close:
	WAIT_US	1520
m_pulse_end:

	; on remet LOW tout de suite (pas attendre la prochaine iteration)
	lds	w, PORTF
	andi	w, ~(1<<SERVO1)
	sts	PORTF, w

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
	_JK	a0, KEY_OPEN,  open_window
	_JK	a0, KEY_CLOSE, close_window
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

; --- HISTORY : GUIDE (re)sortie vers NORMAL, POWER -> SLEEP ---
do_history:
	lds	w, rc5_new
	tst	w
	breq	dh_end
	lds	a0, rc5_cmd
	STI	rc5_new, 0
	_JK	a0, KEY_HIST,  to_normal	; GUIDE de nouveau -> NORMAL
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
	; vient de SET : juste maj mode + lcd_dirty
	STI	mode_var, MODE_NORMAL
	STI	lcd_dirty, 1
	ret

tn_from_sleep:
	; reveil de SLEEP : refaire le splash (LCD est deja allume, juste vide)
	STI	mode_var, MODE_NORMAL
	STI	lcd_dirty, 1
	OUTI	TIMSK, 0			; suspendre Timer0 le temps du splash
	rcall	do_splash
	OUTI	TIMSK, (1<<TOIE0)		; reactiver Timer0
	ret

tn_from_history:
	; sortie de HISTORY : effacer ligne 2 sinon le "Max: XX" reste affiche
	; jusqu'au prochain tick Timer0 (~1s) - look "fige"
	STI	mode_var, MODE_NORMAL
	STI	lcd_dirty, 1
	rcall	LCD_clear			; ligne 2 vide en attendant le prochain Temp
	ret
to_set:
	STI	mode_var, MODE_SET
	STI	lcd_dirty, 1
	ret
to_history:
	STI	mode_var, MODE_HISTORY
	STI	lcd_dirty, 1
	ret
to_sleep:
	STI	mode_var, MODE_SLEEP
	rcall	close_window		; force fermeture en entrant en sleep

	; ecran d'au revoir 2s, puis on efface l'afficheur
	rcall	LCD_home
	PRINTF	LCD
.db	"Sleeping...     ",LF,"                ",0
	WAIT_MS	2000
	rcall	LCD_clear		; LCD vide (mais toujours allume)
	STI	lcd_dirty, 0		; ne rien redessiner tant qu'on est en SLEEP
	ret

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
