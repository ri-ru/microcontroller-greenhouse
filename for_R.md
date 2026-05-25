# Pour R — état du code

Salut R, voici un récap rapide. Tu n'avais vu que `wire1_temp2.asm` jusqu'ici, alors voilà où on en est et ce qui te reste à faire.

## TL;DR

- Ton fichier `wire1_temp2.asm` est **toujours dans le repo**, intact, comme référence.
- Mais ce n'est **plus** lui qui est compilé. Le projet utilise maintenant `main.asm` comme point d'entrée, qui inclut plein d'autres fichiers via `.include`.
- **Ton code de l'ISR `overflow0`** (lecture température + affichage + contrôle fenêtre) a été repris dans un nouveau fichier `thermo.asm`. Le PRINTF qui affiche `Temp: XX.XX C` est **exactement le tien**, je n'y ai pas touché.
- **Il te reste à coder le servo** (PWM sur PB4) dans `servo.asm`. Le reste marche déjà.

## La structure du projet maintenant

Au lieu d'un seul gros `main.asm`, le projet est découpé en cinq fichiers, un par responsabilité :

```
main.asm        ─ reset, table des vecteurs, boucle principale, machine à états
ir_rc5.asm      ─ ISR INT7 (décodage RC5 de la télécommande)
thermo.asm      ─ ISR Timer0 (température + seuil + commande fenêtre)   ← TON CODE
servo.asm       ─ open_window / close_window (PWM servo)                ← À FAIRE
display.asm     ─ rafraîchissement LCD ligne 1 + écran d'accueil
```

Plus les librairies du cours (`lcd.asm`, `printf.asm`, `wire1.asm`, `macros.asm`, `definitions.asm`) qui sont inchangées.

Tout est inclus depuis `main.asm` dans cet ordre, juste après la table des vecteurs.

## Où est ton code maintenant

Ouvre `thermo.asm`. Tu y retrouveras la même séquence que dans ton `wire1_temp2.asm` :

1. `LCD_lf` (au lieu de `LCD_home` — on affiche la température sur la **ligne 2** maintenant, pas la ligne 1)
2. `wire1_reset` + `skipROM` + `readScratchpad`
3. deux `wire1_read` pour LSB puis MSB
4. ton `PRINTF "temp=…",FFRAC2+FSIGN,a,4,$22," C "` — j'ai juste changé `$42` en `$22` pour avoir 2 chiffres entiers au lieu de 4 (sinon ça débordait sur les 16 caractères)
5. `wire1_reset` + `skipROM` + `convertT` pour la conversion suivante
6. La comparaison `temp` vs consigne et la commande de la fenêtre

### Ce que j'ai dû corriger dans ta logique de fenêtre

Désolée, il y avait 3 bugs qu'il fallait fixer pour que ça marche, je te détaille pour que tu sois au courant :

1. **`rcall open_window` était commenté.** Tu avais écrit `nop;rcall open_window`. En AVR asm le `;` est un début de commentaire — donc seul le `nop` s'exécutait, le `rcall` était ignoré. J'ai enlevé le `nop;` pour que l'appel se fasse vraiment.
2. **Le 2ème branchement appelait aussi `open_window`** au lieu de `close_window` (probablement un copier-coller). Corrigé.
3. **`bst b1, 7`** lisait le bit 7 de `b1`, mais `b1` n'était pas initialisé à ce moment-là — c'était du contenu random venant d'avant l'ISR. J'ai remplacé par une lecture propre depuis la variable SRAM `window_open` qu'on tient à jour.

J'ai aussi ajouté les `push`/`pop` au début et à la fin de l'ISR pour sauvegarder tous les registres qu'on touche, sinon la boucle principale se faisait corrompre. C'est cosmétique mais nécessaire vu qu'on a maintenant une vraie boucle principale (et pas juste `rjmp main`).

Et j'ai bougé la valeur de la consigne `b3:b2` pour qu'elle se recalcule à chaque overflow depuis `target_temp` (qui est en SRAM, modifiable par la télécommande en mode SET) — sinon ta consigne restait à 25°C même si l'utilisateur essayait de la changer.

## Ce qui te reste à faire : le servo

Ouvre `servo.asm`. C'est 21 lignes, dont voici les deux routines à compléter :

```asm
open_window:
    STI  window_open, 1
    STI  lcd_dirty, 1
    ret

close_window:
    STI  window_open, 0
    STI  lcd_dirty, 1
    ret
```

Pour l'instant elles ne font que mettre à jour la variable SRAM. **Aucun signal PWM ne sort sur PB4.** Donc le servo ne bouge pas.

### Ce qu'il faut ajouter

Le pattern est **exactement celui de `docs/TP10/TP10/servo1.asm`** — regarde lignes 20–35. C'est ça qu'il faut copier dans `servo.asm` :

```asm
open_window:
    STI  window_open, 1
    STI  lcd_dirty, 1
    ldi  b3, 20                ; 20 impulsions ~ 400ms
ow_loop:
    P1   PORTB, SERVO1         ; broche haut
    WAIT_US 2000               ; HIGH 2ms = position "ouvert"
    P0   PORTB, SERVO1         ; broche bas
    WAIT_US 18000              ; LOW 18ms (période ~20ms)
    dec  b3
    brne ow_loop
    ret

close_window:
    STI  window_open, 0
    STI  lcd_dirty, 1
    ldi  b3, 20
cw_loop:
    P1   PORTB, SERVO1
    WAIT_US 1000               ; HIGH 1ms = position "fermé"
    P0   PORTB, SERVO1
    WAIT_US 18000
    dec  b3
    brne cw_loop
    ret
```

Mêmes macros (`P0`, `P1`, `WAIT_US`, `SERVO1`) que dans le TP. Pas de timer, pas de PWM hardware — juste des impulsions en busy-wait, exactement comme le TP.

**Une chose à ajouter dans `main.asm`** : dans `reset:` (vers ligne 73, juste après `rcall LCD_init`), il faut ajouter :

```asm
sbi  DDRB, SERVO1     ; PB4 en sortie pour le servo
```

Sans ça, PB4 reste en input et le servo ne reçoit rien.

## Comment c'est appelé

`open_window` et `close_window` sont appelés depuis deux endroits, et tu n'as rien à faire pour ça — c'est déjà câblé :

1. **Depuis la télécommande** : touches VOL+ / VOL− (commande manuelle). Dans `main.asm`, `do_normal` à la ligne 133.
2. **Depuis ton ISR Timer0** automatiquement quand la température franchit le seuil. Dans `thermo.asm`, lignes 103 et 110.

Donc dès que tu mets le PWM dans `servo.asm`, les deux chemins (manuel + automatique) marchent.

## Pour résumer ce qui marche déjà / ce qui manque

| Fonctionnalité | État |
|---|---|
| Splash "Hello gardener!" à l'allumage | ✅ |
| Affichage ligne 1 (mode / consigne / état fenêtre) | ✅ |
| Affichage ligne 2 (température) | ✅ |
| Télécommande IR (toutes les touches) | ✅ |
| Mode NORMAL / SET / SLEEP | ✅ |
| Filtre auto-répétition RC5 (pas de double-action quand on appuie une fois) | ✅ |
| Ouverture/fermeture **automatique** de la fenêtre par seuil | ✅ (logique faite, manque juste le servo) |
| Ouverture/fermeture **manuelle** par VOL+/VOL− | ✅ (logique faite, manque juste le servo) |
| **PWM réel pour faire bouger le servo** | ❌ — c'est ta partie |
| Connexion physique du servo sur PB4 (M4) | ❌ — il faut brancher le câble |

## Si tu veux comprendre toute la structure

Lis aussi `servo_explain.md` à la racine du repo — c'est une explication plus complète de l'architecture (machine à états, comment les ISRs et la boucle principale communiquent par des variables SRAM partagées, etc.).

Et `CHANGES.md` documente tous les changements qu'on a faits avec les justifications, dans l'ordre chronologique.

## Si quelque chose ne marche pas

- Si le build foire : poste le message d'erreur, c'est souvent juste un `.include` manquant ou une étiquette dupliquée.
- Si le servo grince mais ne bouge pas : essaye d'inverser les durées (1ms ↔ 2ms) ou d'ajouter quelques pulses en plus (30 au lieu de 20).
- Si toute la carte se reset quand le servo bouge : c'est un problème d'alimentation, il faut brancher la STK-300 sur l'alim externe et pas juste l'USB.

Bisou, bon courage !
