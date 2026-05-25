# Rapport de projet — Serre

Veronika Wannack & Raphaël Wohrer — 26.05.2026

> Brouillon Markdown. Sections alignées sur le `.tex` pour copier-coller.
> Cible : `MCU2026-GXXX.pdf`, 7 pages max, police 11 pt, marges 2 cm.

---

## Description générale

*(Page 1 — info admin, titre, intro, description sans schémas)*

Le projet implémente le contrôle d'une mini-serre à base de l'ATmega128L
sur kit STK-300. La température interne est mesurée par un capteur Dallas
DS18B20 (bus 1-wire) et comparée à une consigne réglable par l'utilisateur.
Lorsque la température dépasse la consigne, une fenêtre motorisée par servo
s'ouvre automatiquement ; elle se referme une fois la température
redescendue. L'utilisateur interagit avec le système via une télécommande
infrarouge Vivanco UR Z2 (protocole RC5) et un afficheur LCD 2×16 affiche
l'état courant.

Trois modes de fonctionnement :

- **NORMAL** : régulation automatique selon la consigne.
- **SET** : réglage de la consigne par les touches haut/bas.
- **SLEEP** : régulation suspendue, fenêtre forcée fermée.

Périphériques utilisés : télécommande IR RC5 (obligatoire) + LCD 2×16 +
servomoteur Futaba S3003 + capteur DS18B20 (1-wire). Soit 1 périphérique
obligatoire et 3 supplémentaires, au-delà du minimum requis.

---

## Manuel d'utilisation

*(Pages 2 à 4)*

### Mode d'emploi

À la mise sous tension, le système entre en mode **NORMAL** avec une
consigne par défaut de 25 °C. La télécommande commande l'ensemble du
système :

| Touche      | Effet en NORMAL                   | Effet en SET            | Effet en SLEEP  |
| ----------- | --------------------------------- | ----------------------- | --------------- |
| SET         | Entre en mode SET                 | Retour en NORMAL        | —               |
| CH +        | —                                 | Augmente la consigne    | —               |
| CH −        | —                                 | Diminue la consigne     | —               |
| VOL +       | Ouverture manuelle de la fenêtre  | —                       | —               |
| VOL −       | Fermeture manuelle de la fenêtre  | —                       | —               |
| POWER       | Entre en mode SLEEP               | —                       | Retour en NORMAL |

La consigne est bornée entre 5 °C et 40 °C. Entrer en mode SLEEP force la
fenêtre fermée.

### Description technique du matériel

Configuration des ports utilisée :

| Port / pin | Direction | Rôle                                |
| ---------- | --------- | ----------------------------------- |
| PE7        | entrée    | sortie du récepteur IR (TSOP, M2)   |
| PB4        | sortie    | commande PWM du servo (M4)          |
| PB5        | E/S       | ligne DQ du DS18B20 (1-wire, M5)    |
| 0x8000     | écriture  | LCD instruction register (mappé)    |
| 0xC000     | écriture  | LCD data register (mappé)           |

L'afficheur LCD HD44780U est accédé via le bus de SRAM externe ; le bit
SRE de MCUCR est mis à 1 à l'initialisation.

### Méthodes d'interruption

Deux sources d'interruption sont utilisées :

- **INT7 (PE7, front descendant)** : déclenche le décodage RC5. Le
  récepteur IR maintient la ligne haute au repos ; un front descendant
  marque le début d'une trame RC5. L'ISR (`rc5_isr`, dans `ir_rc5.asm`)
  échantillonne 14 bits, stocke la commande décodée dans `rc5_cmd` et lève
  le drapeau `rc5_new`. Le drapeau INTF7 est explicitement réinitialisé
  avant `reti` car les fronts intermédiaires du codage Manchester
  l'auraient mis à 1 pendant le décodage.
- **Timer0 (overflow)** : déclenche la lecture périodique de la
  température sur le DS18B20 (~750 ms, durée de conversion du capteur).
  *(Partie développée par R, voir `wire1_temp2.asm`.)*

La boucle principale tourne quant à elle en *polling coopératif* : elle
consulte les drapeaux `rc5_new` (posé par l'ISR INT7) et les valeurs de
température (mises à jour par l'ISR Timer0), puis dispatche selon le mode
courant. Ce choix d'architecture coopérative est justifié : aucun
traitement long ne bloque la boucle, les seules attentes critiques (1/4 et
T1 d'un bit RC5) sont confinées dans l'ISR INT7, et la cadence de mise à
jour du DS18B20 (750 ms) absorbe largement les ~25 ms du décodage RC5.

### Fonctionnement du programme (top-down)

```
                +---------+        +-------------+
                | main    |        | INT7 ISR    |  (rc5_isr)
                |  loop   |        | front PE7   |
                +----+----+        +------+------+
                     |                    |
                     | rcall              | écrit rc5_cmd, rc5_new
                     v                    v
                +---------+        +-------------+
                |dispatch |<-------|  SRAM état  |
                +----+----+        +------+------+
                     |                    ^
                     v                    |
   +-----------------+-----------------+  |
   | do_normal | do_set | do_sleep     |  | met à jour temp
   +-----+-----+----+---+------+-------+  |
         |          |          |          |
         v          v          v   +------+------+
   open/close   target_up/    wake | Timer0 ISR  |
   window       target_down        | overflow0   |
                                   +-------------+
```

### Présentation des modules

| Fichier            | Rôle                                                 |
| ------------------ | ---------------------------------------------------- |
| `main.asm`         | reset, vecteurs d'interruption, boucle principale, machine à états, affichage LCD |
| `ir_rc5.asm`       | ISR de décodage RC5 (INT7)                           |
| `wire1_temp2.asm`  | ISR Timer0, lecture température, contrôle de la fenêtre *(R)* |
| `lcd.asm`          | pilote HD44780U *(fourni)*                           |
| `printf.asm`       | impression formatée *(fourni)*                       |
| `wire1.asm`        | pilote 1-wire bas niveau *(fourni)*                  |
| `macros.asm`       | macros AVR générales *(fourni)*                      |
| `definitions.asm`  | définitions de registres, ports, constantes *(fourni)* |

---

## Rapport technique

*(Pages 5 à 7 — détail de l'accès aux périphériques, références)*

### Télécommande IR (RC5)

Le codage RC5 transmet 14 bits en Manchester sur une porteuse 36 kHz : 2
bits de start (MSB), 1 bit toggle, 5 bits d'adresse, 6 bits de commande
(LSB). Le récepteur (module M2) délivre l'enveloppe démodulée sur PE7, au
repos à l'état haut.

**Accès** : interruption externe INT7 configurée sur front descendant
(`EICRB ← (1<<ISC71)`), activée dans `EIMSK`. Le premier front descendant
de la trame déclenche `rc5_isr`. L'ISR attend T1/4 (échantillonnage au
milieu du premier bit), puis échantillonne PE7 toutes les T1, accumulant
les 14 bits dans le registre 2 octets `b1:b0` via `P2C` (Pin-to-Carry) et
`ROL2`. À la fin, le registre est complémenté (`com b0`), la commande
déposée dans `rc5_cmd` (SRAM), et le drapeau `rc5_new` levé. Le flag
INTF7 est ensuite explicitement effacé (`OUTI EIFR, (1<<INTF7)`) car les
transitions Manchester intermédiaires l'ont armé pendant le décodage.

**Calibration.** La constante T1 fixe la durée d'un bit RC5 utilisée pour
l'échantillonnage. Le T1 par défaut de 1870 µs s'est avéré adéquat pour
notre paire MCU/télécommande : tous les codes des boutons utilisés se
décodent correctement et de façon stable, sans nécessiter de calibration
supplémentaire à l'oscilloscope.

**Sauvegarde du contexte** : l'ISR sauvegarde SREG (dans `_sreg`/r1) et
empile les registres qu'elle modifie (`w`, `u`, `b0`, `b1`, `b2`), puis
les restaure avant `reti`.

### Affichage LCD (HD44780U)

L'afficheur 2×16 est accessible en SRAM mappée : le registre d'instruction
à l'adresse `0x8000` et le registre de données à `0xC000`. L'accès SRAM
externe est activé en initialisation (`MCUCR ← (1<<SRE)|(1<<SRW10)`).

La librairie `lcd.asm` fournie est utilisée telle quelle : `LCD_init`,
`LCD_home`, `LCD_wr_dr` (via `LCD_putc`), avec gestion des codes
spéciaux CR et LF (passage à la ligne 2 à l'adresse `0x40`). L'impression
formatée passe par `PRINTF LCD` (librairie `printf.asm`) qui appelle
`LCD_putc` pour chaque caractère ; les valeurs (consigne, état fenêtre)
sont lues depuis la SRAM (adresses 0x0260+) au moyen du formateur FDEC.

Chaque routine d'affichage (`show_normal`, `show_set`, `show_sleep`)
remplit toujours 16 caractères par ligne afin que l'image précédente soit
intégralement écrasée à chaque rafraîchissement.

### Capteur de température DS18B20 (1-wire)

*(Section à compléter par R.)*

### Servomoteur Futaba S3003

*(Section à compléter par R.)*

### Allocations mémoire

**Mémoire programme (Flash)** : vecteur reset à 0x0000, vecteur INT7 à
0x0010 (`INT7addr`), vecteur Timer0 overflow à 0x0020 (`OVF0addr`). Le
code utilisateur commence après la table de vecteurs.

**Mémoire de données (SRAM interne)** : variables d'état placées dans la
plage compatible avec `printf` (0x0260–0x02FF) :

| Adresse | Symbole       | Taille | Contenu                              |
| ------- | ------------- | ------ | ------------------------------------ |
| 0x0260  | `mode_var`    | 1 o    | mode courant (0=NORMAL, 1=SET, 2=SLEEP) |
| 0x0261  | `target_temp` | 1 o    | consigne en °C (5..40)               |
| 0x0262  | `window_open` | 1 o    | état fenêtre (0=fermée, 1=ouverte)   |
| 0x0263  | `rc5_cmd`     | 1 o    | dernier code RC5 décodé              |
| 0x0264  | `rc5_new`     | 1 o    | drapeau « commande fraîche »         |

La pile est initialisée au sommet de la SRAM (`LDSP RAMEND`).

### Fonctions placées en librairie

Outre les librairies du cours (`macros.asm`, `lcd.asm`, `printf.asm`,
`wire1.asm`), les fonctions répétitives identifiées sont :

- `dispatch` : sélection de la routine de mode par `JK` successifs.
- `lcd_refresh` : sélection de la routine d'affichage par mode.
- `target_up` / `target_down` : ajustement borné de la consigne.
- `open_window` / `close_window` : commande du servo, point d'entrée
  unique pour les déclenchements manuels et automatiques.

### Références

1. *Vivanco, Universal TV-DVB Controller UR Z2*, BDA 34873-Rev-RZ, 2013.
2. *Vishay Semiconductors, Data Formats for IR Remote Control*, Doc. 80071 Rev. 2.2, 2019.
3. *Vishay Semiconductors, IR Receiver Modules for Remote Control Systems*, Doc. 82459, 2016.
4. *Maxim Integrated, DS18B20 Programmable Resolution 1-Wire Digital Thermometer*, datasheet.
5. *Atmel, ATmega128(L) Datasheet*, document 2467.
