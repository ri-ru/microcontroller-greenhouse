; file	thermo.asm   target ATmega128L-4MHz-STK300
; purpose Timer0 ~1Hz: l'ISR ne fait que lever le flag convertT_ended.
;         readT (appelee depuis main) fait le vrai travail: lecture
;         DS18B20, affichage ligne 2 du LCD, historique min/max,
;         controle de la fenetre par seuil.
;         (vecteur OVF0addr installe dans main.asm)
;
;  On separe l'ISR du travail lourd parce que open_window/close_window
;  bloquent ~260 ms pour faire le PWM du servo. Tant que c'etait dans
;  l'ISR, INT7 (RC5) ne pouvait pas etre servi pendant ce temps.

; ==============================================================
;  overflow0 : ISR Timer0 -- juste lever le flag, tres court.
; ==============================================================
overflow0:
	in	_sreg, SREG
	push	w
	STI	convertT_ended, 1
	pop	w
	out	SREG, _sreg
	reti

; ==============================================================
;  readT : appelee depuis main quand convertT_ended = 1.
;  - SLEEP   : ne rien faire (afficheur vide).
;  - HISTORY : lire + maj historique, sans dessiner ligne 2 ni servo.
;  - NORMAL/SET : lecture + affichage ligne 2 + history_update
;                 + comparaison a la consigne + open/close fenetre.
; ==============================================================
readT:
	STI	convertT_ended, 0		; consommer le flag

	; en SLEEP: l'afficheur est vide, on n'a rien a faire
	; (brne+rjmp : breq trop court pour rt_done apres le PRINTF .db)
	lds	w, mode_var
	cpi	w, MODE_SLEEP
	brne	rt_not_sleep
	rjmp	rt_done
rt_not_sleep:

	; --- positionner le curseur sur ligne 2 (sauf en HISTORY) ---
	cpi	w, MODE_HISTORY
	breq	rt_skip_lcdlf
	rcall	LCD_lf				; ligne 2 (bas)
rt_skip_lcdlf:

	; --- lecture temperature DS18B20 ---
	rcall	wire1_reset
	CA	wire1_write, skipROM
	CA	wire1_write, readScratchpad
	rcall	wire1_read			; LSB -> a0
	mov	c0, a0
	rcall	wire1_read			; MSB -> a0
	mov	a1, a0
	mov	a0, c0				; a1:a0 = temperature (format DS18B20)

	; --- afficher la temperature (sauf en HISTORY)
	; PRINTF/FFRAC2 modifie a0..a3 pendant le formatage,
	; on sauvegarde la temperature pour history_update + seuil
	push	a0
	push	a1
	lds	w, mode_var
	cpi	w, MODE_HISTORY
	breq	rt_skip_printf
	PRINTF	LCD
.db	"Temp: ",FFRAC2+FSIGN,a,4,$22," C  ",CR,0
rt_skip_printf:
	rcall	wire1_reset			; lance la prochaine conversion
	CA	wire1_write, skipROM
	CA	wire1_write, convertT
	pop	a1				; recupere la temperature
	pop	a0

	; --- maj historique min/max (toujours, hors SLEEP) ---
	rcall	history_update

	; --- en HISTORY: pas de regulation thermique ---
	lds	w, mode_var
	cpi	w, MODE_HISTORY
	brne	rt_regul
	rjmp	rt_done
rt_regul:

	; --- comparaison a la consigne ---
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
	brmi	rt_close			; N=1 -> temp < consigne

	; temp >= consigne : ouvrir si pas deja
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
