<#
.SYNOPSIS
    Checks for and installs application and Windows updates at logon.
.DESCRIPTION
    Runs as the scheduled task "Software Update at Logon" (elevated) at
    every logon. Uses winget to upgrade Docker Desktop, Visual Studio Code,
    Visual Studio and LibreOffice when a newer version is available, then installs
    pending Windows updates via the Windows Update Agent COM API. If any
    Windows update requires a reboot, the script prompts the user and
    restarts the machine once a key is pressed.

    Nothing is written to disk: the task runs in a visible window, and a run
    that reported a problem waits for a key press before the window closes.
.NOTES
    winget (App Installer) ships with Windows 11 and requires an internet
    connection; when offline the check fails silently and is retried at
    the next logon.
#>

$ErrorActionPreference = 'Continue'

# Counts the warnings of this run: without a log file they would be gone as
# soon as the window closes, so the script keeps the window open if any occur.
$Problems = 0

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
        default                {
            Write-Host "WARNING - $($pkg.Name): winget exit code $LASTEXITCODE"
            $Problems++
        }
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
            if ($code -notin 2, 3) { $Problems++ }
            Write-Host "$status - $($toInstall.Item($i).Title)"
        }

        $RebootPending = $installResult.RebootRequired
    }
} catch {
    # Typically no internet connection or the Windows Update service is
    # unavailable; the check is retried at the next logon.
    Write-Host "WARNING - Windows Update failed: $($_.Exception.Message)"
    $Problems++
}

# The script runs in a visible window, so the user can trigger the
# reboot at a convenient moment by pressing any key.
if ($RebootPending) {
    Write-Host ''
    Write-Host 'Die Updates erfordern einen Neustart. Drücke eine Taste, um den PC neu zu starten.'
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    shutdown.exe /r /t 0
} elseif ($Problems -gt 0) {
    # Nothing is written to disk, so the warnings above would be gone the
    # moment the window closes. Keep it open until the user has seen them.
    Write-Host ''
    Write-Host "$Problems Warnung(en) - siehe oben. Drücke eine Taste, um das Fenster zu schließen."
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}