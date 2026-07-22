<#
.SYNOPSIS
    Checks for and installs application and Windows updates at logon.
.DESCRIPTION
    Runs as the scheduled task "Software Update at Logon" (elevated) at
    every logon. Uses winget to upgrade Docker Desktop, Visual Studio Code,
    Visual Studio and LibreOffice when a newer version is available, then installs
    pending Windows updates via the Windows Update Agent COM API. If any
    Windows update requires a reboot, the script prompts the user and
    restarts the machine once a key is pressed. Output is logged to
    C:\scripts\logs\SoftwareUpdate.txt
.NOTES
    winget (App Installer) ships with Windows 11 and requires an internet
    connection; when offline the check fails silently and is retried at
    the next logon.
#>

$ErrorActionPreference = 'Continue'
$LogDir = 'C:\scripts\logs'
$null = New-Item -Path $LogDir -ItemType Directory -Force
$LogFile = Join-Path $LogDir 'SoftwareUpdate.txt'
# Simple rotation: start over once the log exceeds 1 MB.
if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 1MB) {
    Remove-Item $LogFile -Force
}
Start-Transcript -Path $LogFile -Append

# winget error codes that are expected during a routine check.
$UPDATE_NOT_APPLICABLE = -1978335189   # no newer version available
$NO_APPLICATIONS_FOUND = -1978335212   # package is not installed

$packages = @(
    @{ Id = 'Docker.DockerDesktop';              Name = 'Docker Desktop' }
    @{ Id = 'Microsoft.VisualStudioCode';        Name = 'Visual Studio Code' }
    @{ Id = 'Microsoft.VisualStudio.Enterprise'; Name = 'Visual Studio Enterprise' }
    @{ Id = 'TheDocumentFoundation.LibreOffice'; Name = 'LibreOffice' }
    @{ Id = '7zip.7zip';                         Name = '7-Zip' }
    @{ Id = 'Anthropic.Claude';                  Name = 'Claude' }
    @{ Id = 'DBeaver.DBeaver.Community';         Name = 'DBeaver Community' }
    @{ Id = 'Git.Git';                           Name = 'Git' }
    @{ Id = 'HandBrake.HandBrake';               Name = 'HandBrake' }
    @{ Id = 'DominikReichl.KeePass';             Name = 'KeePass' }
    @{ Id = 'ElementLabs.LMStudio';              Name = 'LM Studio' }
    @{ Id = 'OpenJS.NodeJS';                     Name = 'Node.js' }
    # Version-line specific id: tracks 3.14.x updates only.
    @{ Id = 'Python.Python.3.14';                Name = 'Python 3.14' }
    @{ Id = 'SumatraPDF.SumatraPDF';             Name = 'SumatraPDF' }
    @{ Id = 'Ghisler.TotalCommander';            Name = 'Total Commander' }
    @{ Id = 'IDRIX.VeraCrypt';                   Name = 'VeraCrypt' }
    @{ Id = 'OpenWhisperSystems.Signal';         Name = 'Signal' }
)

foreach ($pkg in $packages) {
    # Skip packages that are not installed on this machine so the same
    # script can be used on machines with a different software set.
    winget list --id $pkg.Id --exact --accept-source-agreements --disable-interactivity | Out-Null
    if ($LASTEXITCODE -eq $NO_APPLICATIONS_FOUND) {
        Write-Host "SKIPPED - $($pkg.Name): not installed."
        continue
    }

    Write-Host "Checking for updates: $($pkg.Name)"
    winget upgrade --id $pkg.Id --exact --silent `
        --accept-source-agreements --accept-package-agreements --disable-interactivity
    switch ($LASTEXITCODE) {
        0                      { Write-Host "OK - $($pkg.Name) is up to date or was updated." }
        $UPDATE_NOT_APPLICABLE { Write-Host "OK - $($pkg.Name): no update available." }
        default                { Write-Host "WARNING - $($pkg.Name): winget exit code $LASTEXITCODE" }
    }
}

# --- Windows Updates --------------------------------------------------------
# Uses the Windows Update Agent COM API instead of the PSWindowsUpdate
# module so the script has no external dependencies.
$RebootPending = $false
Write-Host 'Checking for Windows updates'
try {
    $session  = New-Object -ComObject 'Microsoft.Update.Session'
    $searcher = $session.CreateUpdateSearcher()
    # Software updates that are not yet installed and not hidden by the user.
    $searchResult = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")

    if ($searchResult.Updates.Count -eq 0) {
        Write-Host 'OK - Windows is up to date.'
    } else {
        $toInstall = New-Object -ComObject 'Microsoft.Update.UpdateColl'
        foreach ($update in $searchResult.Updates) {
            if (-not $update.EulaAccepted) { $update.AcceptEula() }
            $null = $toInstall.Add($update)
            Write-Host "Pending: $($update.Title)"
        }

        Write-Host "Downloading $($toInstall.Count) update(s)"
        $downloader = $session.CreateUpdateDownloader()
        $downloader.Updates = $toInstall
        $null = $downloader.Download()

        Write-Host 'Installing updates'
        $installer = $session.CreateUpdateInstaller()
        $installer.Updates = $toInstall
        $installResult = $installer.Install()

        # OperationResultCode: 2 = succeeded, 3 = succeeded with errors.
        for ($i = 0; $i -lt $toInstall.Count; $i++) {
            $code   = $installResult.GetUpdateResult($i).ResultCode
            $status = if ($code -in 2, 3) { 'OK' } else { "WARNING (result code $code)" }
            Write-Host "$status - $($toInstall.Item($i).Title)"
        }

        $RebootPending = $installResult.RebootRequired
    }
} catch {
    # Typically no internet connection or the Windows Update service is
    # unavailable; the check is retried at the next logon.
    Write-Host "WARNING - Windows Update failed: $($_.Exception.Message)"
}

if ($RebootPending) {
    Write-Host 'Reboot required - waiting for user confirmation.'
}

Stop-Transcript

# Prompt after the transcript is closed so the log file is complete.
# The script runs in a visible window, so the user can trigger the
# reboot at a convenient moment by pressing any key.
if ($RebootPending) {
    Write-Host 'Die Updates erfordern einen Neustart. Drücke eine Taste, um den PC neu zu starten.'
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    shutdown.exe /r /t 0
}