; file	servo.asm   target ATmega128L-4MHz-STK300
; purpose servo control for the greenhouse window
;         signal sur PORTB bit SERVO1 (= PB4, module M4 / P7 cf. servo1.asm TP10)
;
;  open_window  -> fenetre ouverte (signal PWM ~2ms)
;  close_window -> fenetre fermee  (signal PWM ~1ms)
;
;  Pour l'instant: simples stubs qui mettent a jour la SRAM. R
;  remplit ici l'envoi des impulsions PWM au servo Futaba S3003.

; TODO R: bouger le servo en position ouverte
open_window:
	STI	window_open, 1
	STI	lcd_dirty, 1
	ret

; TODO R: bouger le servo en position fermee
close_window:
	STI	window_open, 0
	STI	lcd_dirty, 1
	ret
