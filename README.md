# Windows Skripts

- [Update-Software.ps1: Automatische Aktualisierung der Software beim Login](#update-softwareps1-automatische-aktualisierung-der-software-beim-login)
  - [Grundprinzip](#grundprinzip)
  - [Installation und Anpassung](#installation-und-anpassung)
  - [Registrieren als Loginskript](#registrieren-als-loginskript)
- [Backup.ps1: Automatische Sicherung von Ordnern](#backupps1-automatische-sicherung-von-ordnern)
  - [Grundprinzip: VHDX statt Archiv](#grundprinzip-vhdx-statt-archiv)
  - [Ablauf eines Sicherungsauftrags](#ablauf-eines-sicherungsauftrags)
  - [Installation und Anpassung](#installation-und-anpassung-1)
  - [Wartezeit auf Google Drive](#wartezeit-auf-google-drive)
  - [Rückmeldung ohne Logdatei](#rückmeldung-ohne-logdatei)
  - [Registrieren als geplante Aufgabe](#registrieren-als-geplante-aufgabe)
  - [Zugriff auf die Sicherung](#zugriff-auf-die-sicherung)

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
Fehler auftrat, und gibt das Ergebnis im Fenster aus.

Windows Updates lassen sich nicht über winget beziehen, sind aber ebenfalls per
PowerShell skriptbar: Das Skript verwendet dazu die COM-Objekte des Windows Update
Agents (`Microsoft.Update.Session`). Es sucht nach nicht installierten, nicht
ausgeblendeten Updates, lädt sie herunter und installiert sie – derselbe Mechanismus,
den auch die Windows-Update-Einstellungen verwenden.

Meldet die Installation, dass ein Neustart erforderlich ist, gibt das Skript eine
Meldung aus und wartet auf einen Tastendruck. Erst danach wird der Rechner mit
`shutdown.exe /r /t 0` neu gestartet.

Ist kein Neustart nötig, wurde aber mindestens eine Warnung ausgegeben – ein
unerwarteter winget-Exitcode oder ein fehlgeschlagenes Windows-Update –, wartet das
Skript ebenfalls auf einen Tastendruck, damit die Meldung nicht mit dem Fenster
verschwindet. Verlief alles fehlerfrei, endet das Skript einfach.

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

## Backup.ps1: Automatische Sicherung von Ordnern

Das Skript [Backup.ps1](./Backup.ps1) spiegelt bei jedem Login die konfigurierten
Quellordner in jeweils einen VHDX-Container auf dem Sicherungslaufwerk. Aktuell sind
zwei Aufträge eingerichtet:

| Auftrag       | Quelle         | Container                     |
| ------------- | -------------- | ----------------------------- |
| `Fotos`       | `D:\Fotos`     | `E:\Backup_Fotos.vhdx`        |
| `GoogleDrive` | `G:\My Drive`  | `E:\Backup_GoogleDrive.vhdx`  |

### Grundprinzip: VHDX statt Archiv

Naheliegend wäre, die Ordner in ein Archiv (z. B. mit 7-Zip) zu packen. Der Nachteil:
7-Zip kann ein Archiv nicht an Ort und Stelle aktualisieren, sondern schreibt es
komplett neu. Bei der Fotosammlung bedeutete das rund 100 Minuten Laufzeit pro
Sicherung – unabhängig davon, ob sich ein einziges Bild geändert hatte.

Ein VHDX ist eine virtuelle Festplatte, wie sie auch Hyper-V verwendet. Sie behält den
Vorteil des Archivs – die Sicherung ist **eine einzige Datei**, die sich bequem auf ein
NAS oder über SMB kopieren lässt – enthält aber ein echtes NTFS-Dateisystem. Wird der
Container eingehängt, erscheint er als normales Laufwerk. Damit kann **robocopy**
inkrementell abgleichen: Es vergleicht Zeitstempel und Größe und kopiert nur, was sich
tatsächlich geändert hat.

Der Container wird *dynamisch wachsend* (`type=expandable`) angelegt. `MaxSizeMB` ist
also nur die Obergrenze; belegt wird auf der Platte nur so viel, wie tatsächlich an
Daten drinsteckt.

Angelegt wird der Container mit `diskpart`, weil das PowerShell-Pendant `New-VHD` zum
Hyper-V-Modul gehört und nicht auf jedem Rechner installiert ist. Partitionieren,
Formatieren, Einhängen und Aushängen erledigen dagegen die Storage-Cmdlets
(`Mount-DiskImage`, `Initialize-Disk`, `New-Partition`, `Format-Volume`), die zu
Windows gehören.

### Ablauf eines Sicherungsauftrags

Für jeden Eintrag der Auftragsliste führt das Skript folgende Schritte aus:

1. **Auf die Quelle warten**, falls der Auftrag das vorsieht (siehe unten).
2. **Quelle prüfen.** Fehlt sie oder ist sie leer, wird der Auftrag übersprungen. Diese
   Prüfung ist wichtig, weil robocopy im Spiegelmodus sonst die gesamte Sicherung
   löschen würde.
3. **Container anlegen**, falls die VHDX-Datei noch nicht existiert.
4. **Container aushängen und wieder einhängen.** Das vorherige Aushängen macht den
   Schritt fehlertolerant: Nach einem abgestürzten Lauf kann der Container noch
   eingehängt sein.
5. **Laufwerksbuchstaben ermitteln.** Der Buchstabe wird nicht fest vorgegeben, sondern
   nach dem Einhängen ausgelesen – Windows vergibt je nach belegten Buchstaben einen
   anderen. Fehlt einer, weist das Skript einen freien zu.
6. **Spiegeln** mit robocopy.
7. **Container aushängen** – auch dann, wenn robocopy oder das Einhängen fehlgeschlagen
   sind.

Der robocopy-Aufruf lautet im Kern:

```powershell
robocopy.exe <Quelle> <Ziel> /MIR /DCOPY:DAT /XJ /R:1 /W:5 /MT:8 /NP /V
```

`/MIR` spiegelt: Was an der Quelle gelöscht wurde, verschwindet auch aus der Sicherung.
Sollen gelöschte Dateien dauerhaft aufbewahrt werden, ist `/MIR` durch `/E` zu ersetzen.
`/XJ` überspringt Junctions und verhindert so Endlosschleifen, `/MT:8` kopiert mit acht
Threads.

`/V` sorgt für die sichtbare Rückmeldung im Fenster, indem es auch die unveränderten
Dateien auflistet. Ohne `/V` gibt robocopy bei einem Lauf ohne Änderungen zwischen
Kopfzeile und Zusammenfassung überhaupt nichts aus – das Fenster stünde minutenlang
still. Wem die Ausgabe zu geschwätzig ist, entfernt `/V` aus dem Array
`$robocopyArgs`.

Robocopy meldet das Ergebnis über eine Bitmaske. Das Skript übersetzt sie in Klartext;
Werte ab 8 gelten als Fehler:

| Bit | Bedeutung                                          |
| --- | -------------------------------------------------- |
| 1   | Dateien wurden kopiert                             |
| 2   | Zusätzliche Dateien aus der Sicherung entfernt     |
| 4   | Nicht übereinstimmende Dateien/Verzeichnisse       |
| 8   | Dateien konnten nicht kopiert werden (**Fehler**)  |
| 16  | Schwerwiegender Fehler (**Fehler**)                |

### Installation und Anpassung

Lade das Skript [Backup.ps1](./Backup.ps1) in das Verzeichnis **C:\scripts**.

Die Sicherungsaufträge stehen im Array `$Jobs` am Anfang des Skripts. Ein neuer Ordner
wird gesichert, indem ein weiterer Eintrag ergänzt wird:

```powershell
$Jobs = @(
    @{
        Name          = 'Fotos'                    # Name für die Bildschirmausgabe
        Source        = 'D:\Fotos'                 # zu sichernder Ordner
        Vhdx          = 'E:\Backup_Fotos.vhdx'     # Containerdatei
        MaxSizeMB     = 1572864                    # Obergrenze, hier 1,5 TB
        Label         = 'Backup_Fotos'             # Datenträgerbezeichnung im Container
        TargetFolder  = 'Fotos'                    # Unterordner im Container
        ExcludeDirs   = @('*Previews.lrdata')      # Ausschlüsse für robocopy /XD
        WaitForSource = $false                     # auf die Quelle warten?
    }
)
```

`ExcludeDirs` nimmt Verzeichnisnamen entgegen, Platzhalter sind erlaubt. Im Fotoauftrag
werden damit die Lightroom-Vorschauen ausgenommen: Sie lassen sich jederzeit neu
erzeugen und machen rund 72.000 der etwa 119.000 Dateien aus. Das Muster
`*Previews.lrdata` überlebt außerdem das Umbenennen des Katalogs bei einem
Lightroom-Update – ein fest verdrahteter Name passte irgendwann unbemerkt nicht mehr.

### Wartezeit auf Google Drive

Google Drive stellt `G:\My Drive` erst bereit, wenn der Client vollständig gestartet
ist. Unmittelbar nach dem Login existiert das Laufwerk noch nicht – der Auftrag würde
also übersprungen. Deshalb steht der Google-Drive-Auftrag in der Liste an letzter
Stelle, und für ihn ist `WaitForSource = $true` gesetzt.

Das Skript prüft dann alle 10 Sekunden, ob die Quelle erschienen ist, maximal 30-mal.
Ist sie nach diesen 5 Minuten immer noch nicht verfügbar, wird der Auftrag mit einer
Warnung übersprungen; die übrigen Aufträge sind zu diesem Zeitpunkt bereits erledigt.
Die Werte lassen sich über `$SourceWaitAttempts` und `$SourceWaitSeconds` anpassen.

### Rückmeldung ohne Logdatei

Beide Skripts schreiben bewusst keine Logdatei: Die geplanten Aufgaben laufen in einem
sichtbaren Fenster, dort steht alles mit, was robocopy und die Skripts ausgeben.

Damit eine Meldung nicht mit dem Fenster verschwindet, bleibt es stehen, wenn etwas
schiefgegangen ist. `Backup.ps1` wartet auf einen Tastendruck, sobald mindestens ein
Auftrag fehlgeschlagen ist; `Update-Software.ps1` tut dasselbe, wenn winget oder ein
Windows-Update eine Warnung gemeldet hat (bei anstehendem Neustart greift wie bisher
die Neustart-Abfrage). Verlief alles fehlerfrei, schließt sich das Fenster von selbst.

Der Exitcode von `Backup.ps1` entspricht der Anzahl fehlgeschlagener Aufträge, ist also
`0`, wenn alles funktioniert hat – in der Aufgabenplanung ist er in der Spalte *Letztes
Ergebnis der Ausführung* sichtbar.

### Registrieren als geplante Aufgabe

Das Einhängen einer virtuellen Festplatte ist eine privilegierte Operation, das Skript
benötigt daher Administratorrechte. Fehlen sie, bricht es mit einer entsprechenden
Meldung ab. Die folgenden Befehle werden in einer **als Administrator gestarteten
PowerShell** ausgeführt:

```powershell
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\scripts\Backup.ps1'
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
# Zwei Minuten Verzögerung, damit der Login nicht ausgebremst wird.
$trigger.Delay = 'PT2M'
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 6) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'Backup at Logon' `
    -Action $action -Trigger $trigger -Principal $principal -Settings $settings
```

Die Einstellungen im Einzelnen:

- `-RunLevel Highest` führt die Aufgabe mit Administratorrechten aus, ohne bei jedem
  Login eine UAC-Abfrage zu zeigen.
- `$trigger.Delay` verzögert den Start um zwei Minuten. Der Login bleibt dadurch flott,
  und Google Drive bekommt einen Vorsprung.
- `-MultipleInstances IgnoreNew` verhindert, dass sich zwei Sicherungsläufe
  überschneiden, wenn ein Lauf noch nicht fertig ist.
- `-ExecutionTimeLimit` bricht einen hängenden Lauf nach sechs Stunden ab.

Da die Aufgabe an die angemeldete Sitzung gebunden ist (`LogonType Interactive`, gesetzt
durch `New-ScheduledTaskPrincipal`) und die Einstellung `Hidden` nicht aktiviert ist,
öffnet sich beim Login – wie beim Update-Skript – ein sichtbares PowerShell-Fenster, in
dem der Fortschritt mitläuft. Es schließt sich, sobald alle Aufträge erfolgreich fertig
sind, und bleibt bei einem Fehler bis zum Tastendruck stehen (siehe
[Rückmeldung ohne Logdatei](#rückmeldung-ohne-logdatei)).

Zum Testen kann die Aufgabe sofort manuell gestartet werden:

```powershell
Start-ScheduledTask -TaskName 'Backup at Logon'
```

Soll die automatische Sicherung wieder entfernt werden:

```powershell
Unregister-ScheduledTask -TaskName 'Backup at Logon' -Confirm:$false
```

### Zugriff auf die Sicherung

Die Container sind gewöhnliche VHDX-Dateien. Ein Doppelklick auf `E:\Backup_Fotos.vhdx`
im Explorer hängt sie als Laufwerk ein, über *Auswerfen* im Kontextmenü wird sie wieder
ausgehängt. Alternativ auf der Kommandozeile:

```powershell
Mount-DiskImage   -ImagePath 'E:\Backup_Fotos.vhdx'
Dismount-DiskImage -ImagePath 'E:\Backup_Fotos.vhdx'
```

Einzelne Dateien lassen sich so direkt zurückkopieren. Für eine Auslagerung auf ein NAS
genügt es, die VHDX-Datei im ausgehängten Zustand zu kopieren.
