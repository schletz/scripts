<#
.SYNOPSIS
    Mirrors local folders into dynamically expanding VHDX containers.
.DESCRIPTION
    Runs as the scheduled task "Backup at Logon" (elevated) at every logon.
    Each job attaches (or creates) its own VHDX container on E:, mirrors the
    source folder into it with robocopy and detaches the container again.

    A VHDX keeps the "single file" property of an archive - it can be copied
    to a NAS or over SMB in one piece - but holds a real NTFS volume inside,
    so robocopy can sync incrementally by comparing timestamp and size
    instead of rewriting several hundred gigabytes on every run.

    The Google Drive job runs last because G:\ only appears once the Google
    Drive client has finished starting up; the script waits for it.

    Nothing is written to disk: the task runs in a visible window, robocopy is
    called with /V so the file names scrolling by show that the machine is busy,
    and a run with a failed job waits for a key press before the window closes.
.NOTES
    Requires administrator rights: attaching a virtual disk is privileged.
#>

$ErrorActionPreference = 'Continue'

# --- Configuration ----------------------------------------------------------

# MaxSizeMB is the maximum size of the container, not the space it occupies:
# the VHDX grows on demand and only takes up as much room as the data inside.
# ExcludeDirs are directory name patterns passed to robocopy /XD.
# WaitForSource is used for volumes that are mounted by a background service
# and are therefore not available immediately after logon.
$Jobs = @(
    @{
        Name          = 'Fotos'
        Source        = 'D:\Fotos'
        Vhdx          = 'E:\Backup_Fotos.vhdx'
        MaxSizeMB     = 1572864
        Label         = 'Backup_Fotos'
        TargetFolder  = 'Fotos'
        # Lightroom previews are a regenerable cache and account for roughly
        # 72000 of the 119000 files. The wildcard survives catalog renames on
        # Lightroom upgrades, which silently broke the hard-coded name before.
        ExcludeDirs   = @('*Previews.lrdata')
        WaitForSource = $false
    }
    @{
        Name          = 'GoogleDrive'
        Source        = 'G:\My Drive'
        Vhdx          = 'E:\Backup_GoogleDrive.vhdx'
        MaxSizeMB     = 512000
        Label         = 'Backup_GoogleDrive'
        TargetFolder  = 'GoogleDrive'
        ExcludeDirs   = @()
        WaitForSource = $true
    }
)

# Wait up to 5 minutes (30 x 10 s) for a source volume to be mounted.
$SourceWaitAttempts = 30
$SourceWaitSeconds  = 10

# --- Helpers ----------------------------------------------------------------

<#
.SYNOPSIS
    Reports whether the current process runs with administrator rights.
#>
function Test-Elevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$identity).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

<#
.SYNOPSIS
    Waits until a path becomes available.
.PARAMETER Path
    Path that is polled.
.PARAMETER Attempts
    Number of checks before giving up.
.PARAMETER DelaySeconds
    Pause between two checks.
.OUTPUTS
    [bool] True if the path showed up within the given time.
#>
function Wait-ForPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$Attempts = 30,
        [int]$DelaySeconds = 10
    )

    for ($i = 1; $i -le $Attempts; $i++) {
        if (Test-Path -LiteralPath $Path) { return $true }
        Write-Host "  Waiting for $Path ($i/$Attempts)"
        Start-Sleep -Seconds $DelaySeconds
    }
    return $false
}

<#
.SYNOPSIS
    Creates a dynamically expanding VHDX with a single formatted NTFS volume.
.DESCRIPTION
    diskpart is used for the creation itself because New-VHD is only available
    with the Hyper-V PowerShell module, which is not installed on every
    machine. Partitioning and formatting are done with the Storage cmdlets,
    which ship with Windows.
.PARAMETER Path
    File name of the container to create.
.PARAMETER MaxSizeMB
    Maximum size in MB the container may grow to.
.PARAMETER Label
    Volume label of the NTFS file system inside the container.
#>
function New-BackupContainer {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$MaxSizeMB,
        [Parameter(Mandatory)][string]$Label
    )

    Write-Host "  Creating container $Path (max. $MaxSizeMB MB, expandable)"
    $diskpartScript = Join-Path $env:TEMP "backup_create_$PID.txt"
    "create vdisk file=`"$Path`" maximum=$MaxSizeMB type=expandable" |
        Set-Content -LiteralPath $diskpartScript -Encoding Ascii
    try {
        diskpart /s $diskpartScript | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "diskpart returned exit code $LASTEXITCODE."
        }
    } finally {
        Remove-Item -LiteralPath $diskpartScript -Force -ErrorAction SilentlyContinue
    }

    $disk = Mount-DiskImage -ImagePath $Path -StorageType VHDX -PassThru -ErrorAction Stop |
        Get-DiskImage | Get-Disk
    Initialize-Disk -Number $disk.Number -PartitionStyle GPT -ErrorAction Stop
    $partition = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter -ErrorAction Stop
    $null = Format-Volume -Partition $partition -FileSystem NTFS `
        -NewFileSystemLabel $Label -Confirm:$false -ErrorAction Stop
}

<#
.SYNOPSIS
    Attaches a VHDX container and returns the root of the volume inside it.
.DESCRIPTION
    Windows needs a moment to surface the volume after attaching, so the
    partition is polled. A container that lost its drive letter - for example
    after being copied to another machine - is given a free one.
.PARAMETER Path
    File name of the container.
.PARAMETER TimeoutSeconds
    Time to wait for the volume to appear.
.OUTPUTS
    [string] Root of the volume (e.g. "V:\"), or $null on timeout.
#>
function Mount-BackupContainer {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$TimeoutSeconds = 30
    )

    $image = Get-DiskImage -ImagePath $Path -StorageType VHDX -ErrorAction Stop
    if (-not $image.Attached) {
        $null = Mount-DiskImage -ImagePath $Path -StorageType VHDX -ErrorAction Stop
    }

    for ($i = 0; $i -lt $TimeoutSeconds; $i++) {
        $disk = Get-DiskImage -ImagePath $Path -StorageType VHDX -ErrorAction SilentlyContinue |
            Get-Disk -ErrorAction SilentlyContinue
        if ($disk) {
            # The container holds exactly one data partition. The Microsoft
            # Reserved partition created during GPT initialisation carries no
            # file system and is skipped.
            $partition = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue |
                Where-Object { $_.Type -ne 'Reserved' } |
                Sort-Object Size -Descending | Select-Object -First 1

            if ($partition) {
                if ([string]$partition.DriveLetter -notmatch '^[A-Za-z]$') {
                    $partition | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction SilentlyContinue
                    $partition = Get-Partition -DiskNumber $partition.DiskNumber `
                        -PartitionNumber $partition.PartitionNumber -ErrorAction SilentlyContinue
                }
                $letter = [string]$partition.DriveLetter
                if ($letter -match '^[A-Za-z]$' -and (Test-Path "${letter}:\")) {
                    return "${letter}:\"
                }
            }
        }
        Start-Sleep -Seconds 1
    }
    return $null
}

<#
.SYNOPSIS
    Detaches a VHDX container, ignoring the error when it is not attached.
.PARAMETER Path
    File name of the container.
#>
function Dismount-BackupContainer {
    param([Parameter(Mandatory)][string]$Path)

    Write-Host '  Detaching container'
    Dismount-DiskImage -ImagePath $Path -StorageType VHDX -ErrorAction SilentlyContinue | Out-Null
}

<#
.SYNOPSIS
    Translates the robocopy exit code into a readable message.
.DESCRIPTION
    Robocopy uses a bit mask: values below 8 are informational, 8 and above
    mean that files could not be copied.
.PARAMETER ExitCode
    Exit code returned by robocopy.
.OUTPUTS
    [string] Description of the individual bits.
#>
function Format-RobocopyResult {
    param([Parameter(Mandatory)][int]$ExitCode)

    if ($ExitCode -eq 0) { return 'no changes' }
    $parts = @()
    if ($ExitCode -band 1)  { $parts += 'files copied' }
    if ($ExitCode -band 2)  { $parts += 'extra files removed from the backup' }
    if ($ExitCode -band 4)  { $parts += 'mismatched files/directories' }
    if ($ExitCode -band 8)  { $parts += 'FILES COULD NOT BE COPIED' }
    if ($ExitCode -band 16) { $parts += 'FATAL ERROR' }
    return ($parts -join ', ')
}

<#
.SYNOPSIS
    Runs a single backup job.
.DESCRIPTION
    Waits for the source if required, creates the container on first use,
    attaches it, mirrors the source into it and always detaches it again -
    including after a robocopy failure.
.PARAMETER Job
    Hashtable from the $Jobs list.
.OUTPUTS
    [bool] True if the job completed without errors.
#>
function Invoke-BackupJob {
    param([Parameter(Mandatory)][hashtable]$Job)

    Write-Host ''
    Write-Host "=== Backup $($Job.Name): $($Job.Source) ==="

    if ($Job.WaitForSource -and -not (Test-Path -LiteralPath $Job.Source)) {
        if (-not (Wait-ForPath -Path $Job.Source `
                    -Attempts $SourceWaitAttempts -DelaySeconds $SourceWaitSeconds)) {
            Write-Host "WARNING - $($Job.Name): source $($Job.Source) did not appear, job skipped."
            return $false
        }
    }

    if (-not (Test-Path -LiteralPath $Job.Source)) {
        Write-Host "WARNING - $($Job.Name): source $($Job.Source) not found, job skipped."
        return $false
    }

    # Guard against an empty source: robocopy /MIR would delete the whole
    # backup if the source is mounted but not yet populated.
    if (-not (Get-ChildItem -LiteralPath $Job.Source -Force -ErrorAction SilentlyContinue |
                Select-Object -First 1)) {
        Write-Host "WARNING - $($Job.Name): source $($Job.Source) is empty, job skipped."
        return $false
    }

    $containerDrive = Split-Path -Qualifier $Job.Vhdx
    if (-not (Test-Path "$containerDrive\")) {
        Write-Host "WARNING - $($Job.Name): target drive $containerDrive not available, job skipped."
        return $false
    }

    try {
        if (-not (Test-Path -LiteralPath $Job.Vhdx)) {
            New-BackupContainer -Path $Job.Vhdx -MaxSizeMB $Job.MaxSizeMB -Label $Job.Label
        }

        # A crashed previous run may have left the container attached. Detaching
        # first makes the attach step idempotent.
        Dismount-BackupContainer -Path $Job.Vhdx

        Write-Host "  Attaching container $($Job.Vhdx)"
        $volumeRoot = Mount-BackupContainer -Path $Job.Vhdx
        if (-not $volumeRoot) {
            Write-Host "ERROR - $($Job.Name): the volume did not appear after attaching."
            return $false
        }

        $target = Join-Path $volumeRoot $Job.TargetFolder
        $null = New-Item -Path $target -ItemType Directory -Force

        # /MIR removes files from the backup once they are deleted at the
        # source. Replace with /E to keep deleted files indefinitely.
        # /XJ skips junctions and therefore avoids recursion loops.
        # /V also lists the unchanged files: without it a run without any
        # changes prints nothing at all between header and summary, and the
        # window would sit still for minutes.
        $robocopyArgs = @(
            $Job.Source, $target,
            '/MIR', '/DCOPY:DAT', '/XJ', '/R:1', '/W:5', '/MT:8', '/NP', '/V'
        )
        foreach ($exclude in $Job.ExcludeDirs) { $robocopyArgs += @('/XD', $exclude) }

        Write-Host "  Mirroring to $target"
        robocopy.exe @robocopyArgs
        $exitCode = $LASTEXITCODE

        if ($exitCode -ge 8) {
            Write-Host "ERROR - $($Job.Name): robocopy code $exitCode - $(Format-RobocopyResult $exitCode)"
            return $false
        }
        Write-Host "OK - $($Job.Name): $(Format-RobocopyResult $exitCode) (robocopy code $exitCode)"
        return $true
    } catch {
        Write-Host "ERROR - $($Job.Name): $($_.Exception.Message)"
        return $false
    } finally {
        Dismount-BackupContainer -Path $Job.Vhdx
    }
}

# --- Main -------------------------------------------------------------------

Write-Host "=== Backup run started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="

$failed = 0
if (-not (Test-Elevated)) {
    Write-Host 'ERROR - Administrator rights are required to attach a virtual disk.'
    $failed = 1
} else {
    foreach ($job in $Jobs) {
        if (-not (Invoke-BackupJob -Job $job)) { $failed++ }
    }

    Write-Host ''
    if ($failed -eq 0) {
        Write-Host "OK - all $($Jobs.Count) backup job(s) completed."
    } else {
        Write-Host "WARNING - $failed of $($Jobs.Count) backup job(s) failed."
    }
}

# Nothing is written to disk, so a failure would be gone the moment the window
# closes. Keep it open until the user has seen the message.
if ($failed -gt 0) {
    Write-Host ''
    Write-Host "$failed Auftrag/Aufträge fehlgeschlagen - siehe oben. Drücke eine Taste, um das Fenster zu schließen."
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}

exit $failed
