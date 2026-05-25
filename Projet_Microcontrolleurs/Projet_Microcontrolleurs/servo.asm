; file	servo.asm   target ATmega128L-4MHz-STK300
; purpose servo control for the greenhouse window
;         signal sur PORTC bit SERVO1 (= PC4, module M4 / P7, Futaba S3003)
;
;  open_window  -> 13 impulsions PWM ~1.9ms (fenetre ouverte)
;  close_window -> 13 impulsions PWM ~1.5ms (fenetre fermee)
;
;  PWM software, periode 20 ms. Bloque ~260 ms le temps que le servo
;  atteigne la position. Appele depuis readT (boucle principale), pas
;  depuis l'ISR -> INT7 (RC5) reste actif pendant le mouvement.

open_window:
	ldi	w, 13				; 13 periodes de 20 ms
opening:
	P0	PORTC, SERVO1
	WAIT_US	18100
	P1	PORTC, SERVO1
	WAIT_US	1900				; pulse ~1.9 ms -> position ouverte
	dec	w
	brne	opening
	P0	PORTC, SERVO1			; idle bas
	STI	window_open, 1
	STI	lcd_dirty, 1
	ret

close_window:
	ldi	w, 13
closing:
	P0	PORTC, SERVO1
	WAIT_US	18480
	P1	PORTC, SERVO1
	WAIT_US	1520				; pulse ~1.52 ms -> position fermee
	dec	w
	brne	closing
	P0	PORTC, SERVO1			; idle bas
	STI	window_open, 0
	STI	lcd_dirty, 1
	ret
