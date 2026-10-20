# Grafische Windows-Tests auf unserem gemeinsamen GitHub-Runner

**Status:** Experimenteller, separater Draft-PR. Noch kein Bestandteil von `main`, kein Release und keine reale Nutzerabnahme.

## Was bereits mit Windows Standard-Runnern bewiesen wurde

Der öffentliche, kurzlebige GitHub-Runner `windows-latest` besitzt in den
qualifizierten Läufen eine erreichbare interaktive Windows-Sitzung. Das
read-only Testfenster wird direkt im gleichen Runner-Prozess erzeugt. Es wurden
u. a. geprüft:

- sichtbares Testfenster / erreichbarer Eingabe-Desktop / Bildschirm 1024×768;
- Windows Accessibility/UI Automation: Steuerelementname, echter UIA-
  Baumsuchpfad, BoundingRectangle, Sichtbarkeit und genau ein Treffer;
- `CopyFromScreen`-Pixelprobe **im Arbeitsspeicher**, keine Datei;
- echte Win32-Mausereignisse für einen synthetischen, schadlosen Button;
- Tastatureingabe in ein ausschließlich synthetisches Textfeld;
- Lage von Fenster und Steuerelementen sowie konservatives
  Einzeilen-Button-Textbreitenmaß;
- absichtlich abgeschnittener Button wird erkannt; fehlender UIA-Name wird
  erkannt (Negativtests);
- synthetische Font-/Fenster-Skalierungsfälle mit 100/125/150/200 %:
  **keine** Behauptung einer tatsächlichen Windows-DPI-Umschaltung;
- unveränderter Code baut/testet weiter; bei fehlender Fähigkeit scheitert
  der Pilot mit einer eindeutigen Fehlermeldung.

Präziser aktueller Nachweis steht in den im Draft-PR verlinkten exakten
`Synthetic Windows interactive desktop capability probe`-Läufen.
Der Runner lädt weder private Dateien noch erzeugt er öffentliche
Screenshot-/DLL-/Installer-Artefakte.

## Wiederverwendbare Prüffunktionen

- `scripts/windows-ui-geometry.ps1` enthält
  `Get-SafeDesktopLayoutDiagnostics -Window <Form> -Controls <Control[]>`.
  Das ist ein WinForms-/Synthetic-Adapter für Fenster-/Kinderrechtecke und
  konservativ einzeilige Button-Texte, **kein** allgemeiner WPF-/Win32-
  Layout-Beweis.
- `scripts/windows-ui-accessibility.ps1` enthält
  `Test-WindowsUiAccessibility -WindowHandle <owned HWND>
  -RequiredNames <names> -RequiredAutomationIds <ids>`.
  Dieser read-only Adapter ist für echte **sichtbare** Win32-/WPF-
  Steuerelemente geeignet, wenn ein künftiger Produkttest die eigene
  Fenster-HWND kennt. Fehlender/doppelter Name bzw. AutomationId,
  Offscreen und ungültige/außerhalb liegende Rechtecke werden erkannt.
  Die Prüffunktion protokolliert nur Fehlerklassen, keine Pfad-, Tag- oder
  Nutzertexte. Für Tabs und virtualisierte Listen prüft man ausschließlich
  Elemente der jeweils sichtbaren Seite.
- `scripts/synthetic-windows-graphics-probe.ps1` bildet den
  CI-Vertrag aus positiven und negativen Tests ab.

## Anbindung an unsere bestehenden Projekte

Die Tests werden nicht kopiert oder als konkurrierende GUI-Frameworks
implementiert. Je Produkt wird ein expliziter read-only Adapter an den
bestehenden Produktions-UI-Test angehängt:

| Produkt | Vorhandener Produktions-Test | Nächste echte Prüfung |
| --- | --- | --- |
| foobar-Komponenten | Gemeinsamer `foobar-host-smoke` mit x86/x64, echtem foobar 2.26.1 und synthetischem WAV/CUE | Das tatsächliche Dialog-HWND nach Öffnen an UIA-Geometrieprüfung übergeben; sichtbare Buttons/Listen prüfen |
| rekordbox MyTagSync | `--ui-smoke` mit echter `MainWindow`-Konstruktion, Bindings und `AutomationId` | Sichtbares, temporäres Testfenster mit synthetischen/leeren Zuständen und verifizierten Tab-Wechseln testen |
| DJ Library | Bereits vorhandene WPF GUI-/Keyboard-/Tab-/Settings-Smokes im Projekt | UIA- und Overflowprüfung auf dem tatsächlich gestarteten Fenster |
| Discogger, Smart Tempo | Jeweils eigene UI-Branches/Runtime-Smokes | Doppelklick, Suche, Shortcuts, Dialogpersistenz und Tooltip-Semantik **im Produktbranch** qualifizieren |
| foobar Bridge | Headless | Keine GUI erfinden |

Die Autorität für alle UI-Regeln bleibt **ausschließlich**
`lxsdd/dev-infrastructure/STANDARDS/SHARED-DESKTOP-UX.md`
und `STANDARDS/UI-RUNTIME-QUALIFICATION.md`.
Dieses Dokument beschreibt nur die Infrastruktur/Prüfgrenzen.

## Sicherheits- und Ergebnisgrenzen

1. Nur kurzlebige gehostete Windows-Standard-Runner; **keine persistenten
   Self-Hosted-Runner** für fremde/forkbare PRs.
2. Keine produktiven Profile, Musikbibliotheken, `master.db`, Secrets oder
   persönlichen Screenshots laden. Testdaten synthetisch und schreibgeschützt.
3. Keine öffentlichen Bild-/Binary-Artefakte oder Screenshots in Logs;
   Logs enthalten ausschließlich geprüfte Statusflags und Fehlerklassen.
4. Exakte Commit-SHA-Pins für abhängige gemeinsame Aktionen/Quelldateien;
   kein unqualifiziertes `@main` als Runtime-Download.
5. UIA-/Positionstest **ist keine menschliche Usability-Abnahme**. Der Runner
   erlaubt GDI-Pixelprüfungen, aber echte Bildbetrachtung durch ChatGPT und
   sichere private Bildübertragung sind noch nicht eingerichtet. Echte
   Windows-DPI 100–200 %, Dark Mode, Monitorwechsel, Touchpad und
   Bildschirmleser müssen gesondert qualifiziert werden.
6. Kein Merge/Release/CI-Artefakt-Upload ohne gesonderte Eigentümerfreigabe.

**Definition einer weiteren Freigabe:** Zuerst ein echter foobar- bzw.
WPF-Produktdialog aus einer unveränderten, synthetischen Testumgebung mit
`PRODUCTION_WINDOW_GEOMETRY_PASS`, danach optional sichere visuelle
Bildweitergabe und finale Nutzersichtung. Simulierter GUI-Pilot !=
Produktionsdialog.


## Echter produktiver WPF-Fenstertest (2026-10-20)

**Erstmals PASS am wirklichen MyTagSync-Hauptfenster** auf einem kurzlebigen
GitHub-hosted Windows-Runner, unabhängig von den bestehenden produktspezifischen
`--ui-smoke`-/Offscreen-Layout-Tests.

- Im selben isolierten Runner wurde ausschließlich der unveränderliche,
  öffentliche MyTagSync-Commit
  `81e8aa8fb6d8aa2f97a9e1383db7b1b71dd9ce53` ausgecheckt.
- Das Projekt-`global.json` fixiert das SDK `10.0.401`. `dotnet` wird
  **im Produktverzeichnis** ausgeführt, damit die Lockfile-Paketprüfung die
  passende, im Projekt vorgegebene .NET-Version statt der globalen Default-SDK
  verwendet. `--locked-mode` bleibt verpflichtend.
- Der echte WPF-Release-Build ist erfolgreich, Fehleranzahl 0. Das Hauptfenster
  `rekordbox MyTagSync` wurde angezeigt und über seine HWND/UIA-Root gefunden.
  Ein echtes sichtbares Textfeld (`BridgeDirectoryTextBox`) und
  `DiscoverSourceButton` haben gültige Bounds, gültige Accessibility-Namen
  und jeweils **eine eindeutige AutomationId**.
- Das tatsächliche Eingabefeld akzeptierte UIA-Tastaturfokus. Keine
  Source-/Database-/Apply-/Restore-Aktion wurde ausgeführt.
- Ein Button und sein WPF-Inhalt können denselben Accessibility-`Name`
  besitzen. Das ist erlaubt; nur die AutomationId muss für gezielte Aktionen
  eindeutig sein. Der gemeinsame Adapter hat dafür weiterhin negative
  Tests auf komplett fehlende Namen und IDs.
- GitHub-[Lauf 39482829350](https://github.com/lxsdd/dev-infrastructure-public/actions/runs/39482829350)
  **SUCCESS**, **0 öffentliche Artefakte**. Auch der synthetische Grafiktest
  [39482829408](https://github.com/lxsdd/dev-infrastructure-public/actions/runs/39482829408)
  und die öffentliche Infrastruktur-Baseline
  [39482829723](https://github.com/lxsdd/dev-infrastructure-public/actions/runs/39482829723)
  bestanden am gleichen Quellstand.

**Echte Layoutgrenze entdeckt:** Die Runner-Arbeitsfläche ist
**1024 × 720**. MyTagSync setzt im produktiven XAML
`MinWidth=1050` und `MinHeight=700`; das Fenster kann bei dieser
Auflösung nicht vollständig in der Arbeitsfläche liegen.
`PRODUCTION_WPF_WINDOW_FITS_WORKAREA=LIMITED_BY_DISPLAY_RESOLUTION` ist
ein bewusst separat protokollierter Befund, **kein** optischer Layout-PASS.
Der Befund ist an die Produktautomatisierung weitergegeben:
[MyTagSync Issue #7, Befund 6299238654](https://github.com/lxsdd/rekordbox-mytag-sync/issues/7#issuecomment-6299238654).

**Offen:** echte 100–200-%-Windows-DPI-Wechsel, visuelle Screenshots und
menschliche Bildbeurteilung, Dark Mode, echte Touchpad-Gesten,
multimonitorige Fensterpositionierung und tatsächliche Endgerätabnahme.
Der produktive CI-Test fotografiert keinen privaten Bildschirm und stellt
keine Benutzerprofile, Musiksammlung oder Datenbank zur Verfügung.
Dies ist ein quellcodegebundener Infrastruktur-Draft, keine Produktfreigabe.


## Echte Registerkarten-Navigation und Schreibschutz (20.10.2026)

Nachdem der 1024×720-Fensterzuschnitt des inzwischen bereits separat
zusammengeführten MyTagSync-PR #67 nachweisbar behoben wurde, erweitert der
*gemeinsame* Runner seinen produktiven Test – ohne Produktänderungen.

- Testquelle: exakt `3d2ad55d29e1b02c1add95829703a042eca46828`,
  Produkt-`global.json` SDK `10.0.401` und `--locked-mode`. Falls das
  GitHub-Windows-Image nur ein neueres SDK anbietet, wird die genaue Version
  isoliert in `RUNNER_TEMP` installiert, nicht im Repository.
- [Windows-Grafiklauf #39494722674](https://github.com/lxsdd/dev-infrastructure-public/actions/runs/39494722674)
  **SUCCESS**, **0 Artefakte**.
- `PRODUCTION_WPF_TAB_TARGET_UIA=PASS`: echte Registerkarte *Target Library*
  per `SelectionItemPattern.Select()` aktiviert; Textfeld und Button haben
  sichtbare eindeutige Accessibility-Kennungen.
- `PRODUCTION_WPF_TAB_PATH_UIA=PASS`: echte Registerkarte *Path matching*
  aktiviert; Aktionsschaltfläche sichtbar und erreichbar.
- `PRODUCTION_WPF_TAB_PREVIEW_UIA=PASS`: echte Registerkarte *Preview / Changes*
  aktiviert; Vorschau-Button sichtbar und erreichbar.
- `PRODUCTION_WPF_UNSAFE_ACTIONS_DISABLED=PASS`: nach Wechsel zur echten
  Registerkarte *Apply / Restore* bleiben die produktiven Buttons **Apply**
  und **Restore** ohne verifizierten Vorgang deaktiviert. Die Buttons wurden
  **nicht angeklickt**.
- Weiterhin bestanden: Sichtbares Hauptfenster, 1024×720-Fenstergrenzen,
  echtes Tastaturfokussieren und nichtleerer grafischer Inhalt
  (`CopyFromScreen` ausschließlich im Arbeitsspeicher).
- Derselbe Commit hat zusätzlich [synthetischen Windows-Grafiktest
  #39494722263](https://github.com/lxsdd/dev-infrastructure-public/actions/runs/39494722263)
  und [Infrastruktur-Baseline #39494722361](https://github.com/lxsdd/dev-infrastructure-public/actions/runs/39494722361)
  bestanden, zusammen **3/3 SUCCESS, 0 Artefakte**.

Der Test schaltet ausdrücklich nur *Registerkarten*, nicht die darunterliegenden
Aktionen (keine automatische Suche, kein Scan, keine Preview-Erstellung und
keine Änderung an rekordbox-Daten). Ein solcher `PRODUCTION_UIA_WORKFLOW_PASS`
ist ein belastbarer Bedienbarkeitstest für reale WPF-Steuerelemente, **kein**
visueller Abnahmetest zu Lesbarkeit, Schnittstellenästhetik, echten
Windows-11-Touchpad-Gesten oder systemweiten DPI-Wechseln. Dazu sind
weitere getrennte Prüfungen notwendig.


## Laufende Produktversion und echte Tastatur-Tabfolge

Der Prüfstand des aktuellen, unveränderlich fixierten MyTagSync-`main` wurde
wegen einer Sicherheitsaktualisierung von `.NET SDK 10.0.401` auf
`.NET SDK 10.0.402` und aktualisierte SQLite-Abhängigkeiten umgestellt.
Es wurde ausschließlich der **gemeinsame Grafik-Runner** angepasst, nicht
die Produktquelldatei oder der Paket-Lock.

- Aktueller Produkt-Commit:
  `6974bdd603908adebd17031302244feaa100ae78`.
- [Aktueller Build und UI-Prüfung #39496487332](https://github.com/lxsdd/dev-infrastructure-public/actions/runs/39496487332):
  **SUCCESS**, **0 Artefakte**, echtes Programmfenster, feste SDK-Version,
  sichtbare Registerkarten, 1024×720-Fenstergrenzen und Schreibsperre geprüft.
- [Erweiterter Tastatur-Lauf #39496799643](https://github.com/lxsdd/dev-infrastructure-public/actions/runs/39496799643):
  **SUCCESS**, **0 Artefakte**.
  Der tatsächlich fokussierte `TargetDatabaseTextBox` erhielt ein reales
  `Tab`-Tastenereignis. Der Tastaturfokus wechselte eindeutig auf
  `DiscoverTargetButton` (`Find libraries`);
  `Umschalt+Tab` brachte ihn wieder zum Eingabefeld.
  `PRODUCTION_WPF_KEYBOARD_FORWARD_TAB=PASS` und
  `PRODUCTION_WPF_KEYBOARD_REVERSE_TAB=PASS`.
- Keine Find-/Scan-/Preview-/Apply-/Restore-Aktion wurde ausgelöst. Die
  Produktionsschaltflächen für Datenbankänderungen blieben deaktiviert.

Das sind echte **Tastatur- und Accessibility-Prüfungen** eines aktuellen,
leeren Produktionsfensters in einer flüchtigen Windows-GitHub-Sitzung. Eine
menschliche Lesbarkeits- und intuitiv-visuelle Prüfung, echte Windows-DPI-
Umschaltung und Hardware-Touchpadtests bleiben separate offene Kriterien.


## Live-WPF-Tests bei kompakten Fenstergrößen

Die Produktionsversion `6974bdd603908adebd17031302244feaa100ae78`
(.NET SDK 10.0.402, Paketrestore `--locked-mode`) wurde auf dem
vorhandenen 1024×720-GitHub-Desktop in **zwei tatsächlich veränderten
Fenstergrößen** geöffnet: `920×640` und `1000×700`.

[GitHub-Lauf #39497862793](https://github.com/lxsdd/dev-infrastructure-public/actions/runs/39497862793):
**SUCCESS, 0 hochgeladene Artefakte**.

Auf jeder tatsächlichen Fenstergröße:
- Source: Textfeld sowie „Find sources“ und „Inspect selected“ sichtbar,
  gültige BoundingRects, keinerlei Überschneidungen;
- Target Library: Ziel-Datenbankfeld und „Find libraries“ sichtbar,
  eindeutig erreichbar, keine Button-/Feldüberschneidungen;
- Path matching: „Analyze paths“, „Check selected files“ und
  „Check all file identities“ sichtbar; deren reale Rechtecke
  überschneiden sich nicht, auch wenn die Aktionsleiste umbrechen muss;
- Preview / Changes: „Refresh verified preview“ und
  „Auto-match and preview“ sichtbar und ohne Überschneidung;
- Fenster komplett innerhalb der echten Monitor-Arbeitsfläche;
- Tab-/Umschalt+Tab-Fokus sowie Apply-/Restore-Schreibsperre PASS.

Die Testbefehle ändern die WPF-Fenstergröße mittels `SetWindowPos`,
schalten Registerkarten mittels `SelectionItemPattern.Select()` um und
lesen ausschließlich UIA-Namen/AutomationIds/Bildschirmrechtecke. Es
werden **keine Aktionen ausgeführt**, Dateien gescannt oder Datenbank-
Änderungen vorgenommen. So entsteht ein sinnvoller struktureller
Layout-Nachweis, jedoch **keine** tatsächlich umgestellte Windows-
DPI-Auflösung, kein Screenshot-Designurteil, kein Touchpad- oder
Mehrmonitor-Hardwaretest.
