; file	servo.asm   target ATmega128L-4MHz-STK300
; purpose servo control for the greenhouse window
;         Le signal PWM lui-meme est genere dans la boucle principale
;         (main.asm), TP10-style: pin LOW ~18 ms, puis travail, puis pin
;         HIGH pendant 1.5/1.9 ms selon window_open. PORTF.SERVO1 = PF4.
;
;         open_window / close_window se contentent de mettre a jour
;         l'etat (window_open) et le flag d'affichage. Le servo bouge
;         tout seul a la prochaine impulsion.

open_window:
	STI	window_open, 1
	STI	lcd_dirty, 1
	ret

close_window:
	STI	window_open, 0
	STI	lcd_dirty, 1
	ret
