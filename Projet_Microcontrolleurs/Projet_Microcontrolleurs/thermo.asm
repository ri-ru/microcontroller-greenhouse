; file	thermo.asm   target ATmega128L-4MHz-STK300
; purpose ISR Timer0 (~1Hz): lecture DS18B20, affichage temperature sur
;         ligne 2 du LCD, mise a jour de l'historique min/max, et
;         controle de la fenetre par seuil.
;         (vecteur OVF0addr installe dans main.asm)

; ==============================================================
;  overflow0 : ISR Timer0 (lecture temperature DS18B20)
; --------------------------------------------------------------
;  - SLEEP : early-exit, on ne fait rien.
;  - HISTORY : on lit le capteur et on met a jour l'historique,
;    mais on ne dessine pas sur le LCD et on ne regule pas.
;  - NORMAL / SET : lecture + affichage ligne 2 + update historique
;    + comparaison a la consigne + ouverture/fermeture fenetre.
; ==============================================================
overflow0:
	in	_sreg, SREG
	push	w

	; en SLEEP: l'afficheur est vide, on n'a rien a faire
	lds	w, mode_var
	cpi	w, MODE_SLEEP
	brne	ov_active
	pop	w
	out	SREG, _sreg
	reti

ov_active:
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

	; --- positionner le curseur sur ligne 2 (sauf en HISTORY) ---
	lds	w, mode_var
	cpi	w, MODE_HISTORY
	breq	ov_skip_lcdlf
	rcall	LCD_lf				; ligne 2 (bas)
ov_skip_lcdlf:

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
	breq	ov_skip_printf
	PRINTF	LCD
.db	"Temp: ",FFRAC2+FSIGN,a,4,$22," C  ",CR,0
ov_skip_printf:
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
	breq	ov_done

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
