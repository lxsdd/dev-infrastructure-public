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
