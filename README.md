# Windows Skripts

- [Update-Software.ps1: Automatische Aktualisierung der Software beim Login](#update-softwareps1-automatische-aktualisierung-der-software-beim-login)
  - [Features](#features)
  - [Grundprinzip](#grundprinzip)
  - [Anpassung](#anpassung)
  - [Registrieren als Loginskript](#registrieren-als-loginskript)

## Update-Software.ps1: Automatische Aktualisierung der Software beim Login

Das Skript hält einen Windows-Rechner automatisch aktuell: Bei jedem Login werden die
installierten Anwendungen und die Windows Updates geprüft und – falls neuere Versionen
vorliegen – ohne weitere Nachfrage installiert. So bleibt der Rechner ohne manuelles
Zutun auf dem aktuellen Stand.

### Grundprinzip

Seit Windows 10 liefert Microsoft mit **winget** (App Installer) einen Paketmanager
mit. Ähnlich wie `apt` unter Linux
kann winget Software aus einem zentralen Repository installieren und aktualisieren.
Der zentrale Befehl dafür ist:

```powershell
winget upgrade --id <PackageId> --exact --silent
```

Das Skript ruft diesen Befehl für jedes Paket der Liste auf. Über die Exit-Codes von
winget erkennt es, ob ein Update installiert wurde, keines verfügbar war oder ein
Fehler auftrat, und protokolliert das Ergebnis.

Windows Updates lassen sich nicht über winget beziehen, sind aber ebenfalls per
PowerShell skriptbar: Das Skript verwendet dazu die COM-Objekte des Windows Update
Agents (`Microsoft.Update.Session`). Es sucht nach nicht installierten, nicht
ausgeblendeten Updates, lädt sie herunter und installiert sie – derselbe Mechanismus,
den auch die Windows-Update-Einstellungen verwenden.

Meldet die Installation, dass ein Neustart erforderlich ist, gibt das Skript eine
Meldung aus und wartet auf einen Tastendruck. Erst danach wird der Rechner mit
`shutdown.exe /r /t 0` neu gestartet. Ohne ausstehenden Neustart endet das Skript
einfach.

### Installation und Anpassung

Lade das Skript [Update-Software.ps1](./Update-Software.ps1) in das Verzeichnis **C:\scripts**

#### Paketliste anpassen

Die zu aktualisierenden Programme stehen im Array `$packages` am Anfang des Skripts.
Jeder Eintrag besteht aus der winget-Paket-ID und einem Anzeigenamen für das Log:

```powershell
$packages = @(
    @{ Id = 'Microsoft.VisualStudioCode'; Name = 'Visual Studio Code' }
    # ...
)
```

Welche Software auf dem eigenen Rechner installiert ist und welche IDs sie hat, zeigt:

```powershell
winget list
```

```
Name                      Id                      Version 
------------------------ ---------------------------------
Git                       Git.Git                 2.55.0.3
LM Studio 0.4.20+1        ElementLabs.LMStudio    0.4.20+1
Node.js                   OpenJS.NodeJS           26.4.0  
Python 3.14.6 (64-bit)    Python.Python.3.14      3.14.6  
```

Die Spalte *Id* enthält die exakte Paket-ID (z. B. `Git.Git` oder
`OpenJS.NodeJS`). Diese ID wird als neuer Eintrag in das Array übernommen. Einträge
für Software, die man nicht automatisch aktualisieren möchte, löscht man einfach –
nicht installierte Pakete überspringt das Skript aber ohnehin von selbst.

Manche IDs enthalten die Versionslinie, z. B. `Python.Python.3.14`. Damit werden nur
Updates innerhalb von Python 3.14.x installiert, aber kein automatischer Sprung auf
eine neue Hauptversion gemacht.

### Registrieren als Loginskript

Damit das Skript beim Login gestartet wird, muss es als geplante Aufgabe registriert werden, die bei jedem Login des
aktuellen Benutzers mit erhöhten Rechten startet. Die folgenden Befehle werden in
einer **als Administrator gestarteten PowerShell** ausgeführt:

```powershell
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\scripts\Update-Software.ps1'
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest
Register-ScheduledTask -TaskName 'Software Update at Logon' `
    -Action $action -Trigger $trigger -Principal $principal
```

Durch `-RunLevel Highest` läuft die Aufgabe mit Administratorrechten, ohne dass bei
jedem Login eine UAC-Abfrage erscheint. Da die Aufgabe nur bei angemeldetem Benutzer
läuft, öffnet sich beim Login ein sichtbares PowerShell-Fenster – so ist der
Update-Fortschritt erkennbar und der Tastendruck für einen eventuellen Neustart
möglich.

Zum Testen kann die Aufgabe sofort manuell gestartet werden:

```powershell
Start-ScheduledTask -TaskName 'Software Update at Logon'
```

Soll die automatische Aktualisierung wieder entfernt werden:

```powershell
Unregister-ScheduledTask -TaskName 'Software Update at Logon' -Confirm:$false
```
