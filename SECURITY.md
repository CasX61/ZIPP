# Sicherheit

ZIPP verarbeitet Archive aus dem Internet, also nicht vertrauenswürdige Daten. Sicherheitslücken nehmen
wir deshalb besonders ernst.

## Lücke melden

Bitte **kein öffentliches Issue** anlegen. Nutze stattdessen
[„Report a vulnerability“](../../security/advisories/new) (GitHub Private Vulnerability Reporting).
Hilfreich sind:

- betroffene Version und macOS-Version
- ein Beispielarchiv (oder ein Skript, das es erzeugt)
- was passiert und was du erwartet hättest

Wir melden uns innerhalb von 7 Tagen und veröffentlichen eine Korrektur samt Hinweis, sobald sie bereitsteht.

## Was ZIPP schützt

- Pfade, die aus dem Zielordner herausführen (`../`, absolute Pfade), werden blockiert (Zip-Slip).
- Symlinks werden nur angelegt, wenn ihr Ziel im Zielordner bleibt. Durch vorhandene Symlinks wird nie geschrieben.
- Die Quarantäne-Markierung des Archivs wird auf entpackte Dateien übertragen, damit Gatekeeper sie prüft.
- Vor ungewöhnlich hoher Kompression (Zip-Bomben) und fehlendem Speicherplatz wird gewarnt.
- Hardlinks, Gerätedateien und FIFOs aus TAR-Archiven werden nicht angelegt.
