; file	servo.asm   target ATmega128L-4MHz-STK300
; purpose servo control for the greenhouse window
; module M4, P7 servo Futaba S3003, output port: PORTC
;
;  open_window  -> fenetre ouverte (signal PWM ~2ms)
;  close_window -> fenetre fermee  (signal PWM ~1ms)
;
;  Pour l'instant: simples stubs qui mettent a jour la SRAM. R
;  remplit ici l'envoi des impulsions PWM au servo Futaba S3003.

; TODO R: bouger le servo en position ouverte
open_window:
	ldi w, 13
opening:
	OUTEI	PORTF, (0<<SERVO1)
	WAIT_US	18100
	OUTEI	PORTF, (1<<SERVO1)
	WAIT_US 1900
	dec w
	brne opening
	STI	window_open, 1
	STI	lcd_dirty, 1
	ret

; TODO R: bouger le servo en position fermee
close_window:
	ldi w, 13
closing:
	OUTEI	PORTF, (0<<SERVO1)
	WAIT_US	18480
	OUTEI	PORTF, (1<<SERVO1)
	WAIT_US 1520
	dec w
	brne closing
	STI	window_open, 0
	STI	lcd_dirty, 1
	ret
