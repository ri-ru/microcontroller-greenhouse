; file	thermo.asm   target ATmega128L-4MHz-STK300

; ==============================================================
;  readT : appelee depuis main quand convertT_ended = 1.
;  - SLEEP   : ne rien faire (afficheur vide).
;  - HISTORY : lire + maj historique, sans dessiner ligne 2 ni servo.
;  - NORMAL/SET : lecture + affichage ligne 2 + history_update
;                 + compare to threshold + open/close window.
; ==============================================================
readT:
	STI	convertT_ended, 0

	; (brne+rjmp : breq trop court pour rt_done apres le .db pour PRINTF)
	lds	w, mode_var
	cpi	w, MODE_SLEEP
	brne	rt_not_sleep
	rjmp	rt_done
rt_not_sleep:

	cpi	w, MODE_HISTORY
	breq	rt_skip_lcdlf
	rcall	LCD_lf
rt_skip_lcdlf:
	rcall	wire1_reset
	CA	wire1_write, skipROM
	CA	wire1_write, readScratchpad
	rcall	wire1_read			; LSB -> a0
	mov	c0, a0
	rcall	wire1_read			; MSB -> a0
	mov	a1, a0
	mov	a0, c0				; a1:a0 = temperature
	push	a0				; saving temperature bc PRINTF uses a0 and a1
	push	a1
	lds	w, mode_var
	cpi	w, MODE_HISTORY
	breq	rt_skip_printf
	PRINTF	LCD
.db	"Temp: ",FFRAC2+FSIGN,a,4,$22," C  ",CR,0
rt_skip_printf:
	rcall	wire1_reset
	CA	wire1_write, skipROM
	CA	wire1_write, convertT
	pop	a1
	pop	a0

	rcall	history_update

	lds	w, mode_var
	cpi	w, MODE_HISTORY
	brne	rt_regul
	rjmp	rt_done
rt_regul:

	; --- comparaison a la consigne ---
	; recalculate the threshold: b3:b2 = target_temp * 16 (sensor uses a 12-bit fixed point representation)
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
	rol	b3				

	; comparer temp (a1:a0) a la consigne (b3:b2)
	mov	b0, a0
	mov	b1, a1
	sub	b0, b2
	sbc	b1, b3
	brmi	rt_close

	lds	w, window_open
	tst	w
	brne	rt_done
	rcall	open_window
	rjmp	rt_done
rt_close:
	lds	w, window_open
	tst	w
	breq	rt_done
	rcall	close_window
rt_done:
	ret
