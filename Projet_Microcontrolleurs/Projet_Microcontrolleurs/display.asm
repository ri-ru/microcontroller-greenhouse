; file	display.asm   target ATmega128L-4MHz-STK300
; purpose affichage LCD: ligne 1 (state) update when lcd_dirty is set, splash
;  Ligne 1 (haut) = etat (mode/consigne/fenetre) -- ecrite ici, seulement
;  quand un changement d'etat a leve lcd_dirty.
;  Ligne 2 (bas) = "Temp: XX.XX C" -- ecrite par overflow0 (~1 fois/s).
lcd_refresh:
	lds	w, lcd_dirty
	tst	w
	breq	lr_skip
	STI	lcd_dirty, 0
	lds	w, mode_var
	_JK	w, MODE_NORMAL,  show_normal
	_JK	w, MODE_SET,     show_set
	_JK	w, MODE_SLEEP,   show_sleep
	_JK	w, MODE_HISTORY, show_history
lr_skip:
	ret

show_normal:
	rcall	LCD_home
	lds	w, window_open
	tst	w
	brne	show_normal_open
	PRINTF	LCD
.db	"Set:",FDEC|FDIG2,low(target_temp),"C. Closed.",0
	ret
show_normal_open:
	PRINTF	LCD
.db	"Set:",FDEC|FDIG2,low(target_temp),"C. Open.  ",0
	ret

show_set:
	rcall	LCD_home
	PRINTF	LCD
.db	"Set:",FDEC|FDIG2,low(target_temp),"C. <EDIT>.",0
	ret

show_sleep:
	rcall	LCD_home
	PRINTF	LCD
.db	"Sleeping...     ",0
	ret

; HISTORY : Min sur la ligne du haut, Max sur la ligne du bas.
; Les valeurs viennent de la SRAM (mirror de l'EEPROM, charge au boot
; et entretenu par history_update dans thermo.asm).
show_history:
	rcall	LCD_home
	lds	a0, min_temp
	lds	a1, min_temp+1
	PRINTF	LCD
.db	"Min:",FFRAC2+FSIGN,a,4,$22," C    ",LF,0
	lds	a0, max_temp
	lds	a1, max_temp+1
	PRINTF	LCD
.db	"Max:",FFRAC2+FSIGN,a,4,$22," C    ",0
	ret

; ecran d'accueil partage (boot + reveil de SLEEP)
do_splash:
	rcall	LCD_home
	PRINTF	LCD
.db	"Hello gardener!",LF,"                ",0
	WAIT_MS	2000
	rcall	LCD_clear
	ret
