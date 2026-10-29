<#
.SYNOPSIS
    Audit Windows startup entries (Run/RunOnce keys and Startup folders), and
    remove or restore one Run value with -WhatIf, a JSON backup and an undo.

.DESCRIPTION
    Dot-source this file to load three functions:

      Get-StartupEntry   Read-only list of Run/RunOnce values and Startup-folder files.
      Disable-RunEntry   Saves one Run value to a JSON file, then removes it.
                         Supports -WhatIf and -Confirm.
      Restore-RunEntry   Writes the value back from that JSON file.
                         Supports -WhatIf and -Confirm.

    Test status: parsed and checked with PSScriptAnalyzer (0 findings) and
    Pester tests using fake registry objects, under PowerShell 7 on Linux.
    NOT yet run against a real Windows registry or on Windows PowerShell 5.1.
    Try every change with -WhatIf first.

    Written with AI assistance. MIT License (see LICENSE).
    Not affiliated with or endorsed by Microsoft.

.EXAMPLE
    . .\startup-audit.ps1
    Get-StartupEntry | Format-Table -AutoSize

.EXAMPLE
    Disable-RunEntry -Key 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'SomeOldUpdater' -WhatIf

.EXAMPLE
    Restore-RunEntry -BackupFile "$env:LOCALAPPDATA\StartupBackups\SomeOldUpdater_20261029-101500.json"
#>

# --- Part 1: read-only audit -------------------------------------------
$runKeys = @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
)

function Get-StartupEntry {
    [CmdletBinding()]
    param()

    foreach ($key in $runKeys) {
        if (-not (Test-Path -LiteralPath $key)) { continue }
        $item = Get-Item -LiteralPath $key
        foreach ($name in $item.GetValueNames()) {
            if ($name -eq '') { continue }   # skip the (Default) value
            [pscustomobject]@{
                Source   = 'Registry'
                Location = $key
                Name     = $name
                # Read the raw text, so %ProgramFiles% etc. are not expanded
                Command  = $item.GetValue($name, $null, 'DoNotExpandEnvironmentNames')
            }
        }
    }

    $folders = [Environment]::GetFolderPath('Startup'),
               [Environment]::GetFolderPath('CommonStartup')
    foreach ($folder in $folders) {
        if (-not $folder -or -not (Test-Path -LiteralPath $folder)) { continue }
        Get-ChildItem -LiteralPath $folder -File |
            Where-Object Name -ne 'desktop.ini' |
            ForEach-Object {
                [pscustomobject]@{
                    Source   = 'StartupFolder'
                    Location = $folder
                    Name     = $_.Name
                    Command  = $_.FullName
                }
            }
    }
}

# --- Part 2: remove one Run value, with -WhatIf and a JSON backup -------
function Disable-RunEntry {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)] [string] $Key,
        [Parameter(Mandatory)] [string] $Name,
        [string] $BackupDir = (Join-Path $env:LOCALAPPDATA 'StartupBackups')
    )

    $item = Get-Item -LiteralPath $Key -ErrorAction Stop
    if ($item.GetValueNames() -notcontains $Name) {
        throw "No value named '$Name' under $Key"
    }

    # Capture everything needed to put it back, before touching anything.
    $backup = [pscustomobject]@{
        Key     = $Key
        Name    = $Name
        Value   = $item.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')
        Kind    = $item.GetValueKind($Name).ToString()
        SavedAt = (Get-Date).ToString('o')
    }

    if ($PSCmdlet.ShouldProcess("$Key\$Name", 'Remove startup value (backup is saved first)')) {
        New-Item -ItemType Directory -Path $BackupDir -Force -ErrorAction Stop -Confirm:$false | Out-Null
        $safeName = $Name -replace '[^\w.-]', '_'
        $file = Join-Path $BackupDir ('{0}_{1}.json' -f $safeName, (Get-Date -Format 'yyyyMMdd-HHmmss'))
        $backup | ConvertTo-Json | Set-Content -LiteralPath $file -Encoding UTF8 -ErrorAction Stop -Confirm:$false

        Remove-ItemProperty -LiteralPath $Key -Name $Name -ErrorAction Stop -Confirm:$false
        # Output the backup path so you can pass it straight to Restore-RunEntry
        [pscustomobject]@{ Removed = "$Key\$Name"; BackupFile = $file }
    }
}

# --- Part 3: undo from the backup file ----------------------------------
function Restore-RunEntry {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param([Parameter(Mandatory)] [string] $BackupFile)

    $b = Get-Content -LiteralPath $BackupFile -Raw -ErrorAction Stop | ConvertFrom-Json
    if ($PSCmdlet.ShouldProcess("$($b.Key)\$($b.Name)", 'Restore startup value')) {
        New-ItemProperty -LiteralPath $b.Key -Name $b.Name -Value $b.Value `
            -PropertyType $b.Kind -Force -ErrorAction Stop -Confirm:$false | Out-Null
        [pscustomobject]@{ Restored = "$($b.Key)\$($b.Name)"; Value = $b.Value }
    }
}
