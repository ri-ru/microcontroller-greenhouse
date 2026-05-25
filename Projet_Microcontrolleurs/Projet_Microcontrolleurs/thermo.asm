; file	thermo.asm   target ATmega128L-4MHz-STK300
; purpose ISR Timer0 (~1Hz): lecture DS18B20, affichage temperature sur
;         ligne 2 du LCD, et controle de la fenetre par seuil.
;         (vecteur OVF0addr installe dans main.asm)

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
readT:
	; --- lecture temperature DS18B20 et affichage (code R) ---
	rcall	LCD_lf				; ligne 2 (bas)
	rcall	wire1_reset
	CA	wire1_write, skipROM
	CA	wire1_write, readScratchpad
	rcall	wire1_read			; LSB -> a0
	mov	c0, a0
	rcall	wire1_read			; MSB -> a0
	mov	a1, a0
	mov	a0, c0				; a1:a0 = temperature (format DS18B20)

	; PRINTF/FFRAC2 modifie a0..a3 pendant le formatage,
	; on sauvegarde la temperature pour le compare plus bas
	push	a0
	push	a1
	PRINTF	LCD
.db	"Temp: ",FFRAC2+FSIGN,a,4,$22," C  ",CR,0
	rcall	wire1_reset			; lance la prochaine conversion
	CA	wire1_write, skipROM
	CA	wire1_write, convertT
	pop	a1				; recupere la temperature
	pop	a0

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
	ret
