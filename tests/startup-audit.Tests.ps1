# Pester 5+ tests for startup-audit.ps1.
# They use fake registry objects (mocks) and Pester's TestDrive:, so they run on
# any OS and never touch a real registry. They do NOT prove how a real Windows
# registry behaves.

BeforeAll {
    . (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'startup-audit.ps1')

    function Get-FakeRegistryKey {
        param([hashtable] $Values, [hashtable] $Kinds)
        $o = [pscustomobject]@{ Values = $Values; Kinds = $Kinds; LastGetValueOption = $null }
        $o | Add-Member ScriptMethod GetValueNames { @($this.Values.Keys) }
        $o | Add-Member ScriptMethod GetValue {
            param($n, $default, $opt)
            $this.LastGetValueOption = $opt
            if (-not $this.Values.ContainsKey($n)) { return $default }
            $this.Values[$n]
        }
        $o | Add-Member ScriptMethod GetValueKind { param($n) [Microsoft.Win32.RegistryValueKind]$this.Kinds[$n] }
        $o
    }

    $script:key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
}

Describe 'Disable-RunEntry' {
    BeforeEach {
        $script:fake = Get-FakeRegistryKey -Values @{ 'SomeOldUpdater' = '%LOCALAPPDATA%\Old\upd.exe' } `
                                   -Kinds  @{ 'SomeOldUpdater' = 'ExpandString' }
        Mock Get-Item { $script:fake }
        Mock Remove-ItemProperty { }
        $script:backupDir = Join-Path $TestDrive 'bk'
    }

    It '-WhatIf removes nothing and writes no backup' {
        Disable-RunEntry -Key $key -Name 'SomeOldUpdater' -BackupDir $backupDir -WhatIf
        Should -Invoke Remove-ItemProperty -Times 0 -Exactly
        Test-Path $backupDir | Should -BeFalse
    }

    It 'real run writes the JSON backup, then removes the value' {
        $r = Disable-RunEntry -Key $key -Name 'SomeOldUpdater' -BackupDir $backupDir
        Should -Invoke Remove-ItemProperty -Times 1 -Exactly -ParameterFilter { $Name -eq 'SomeOldUpdater' -and $LiteralPath -eq $key }
        Test-Path $r.BackupFile | Should -BeTrue
        $b = Get-Content -LiteralPath $r.BackupFile -Raw | ConvertFrom-Json
        $b.Key   | Should -Be $key
        $b.Name  | Should -Be 'SomeOldUpdater'
        $b.Value | Should -Be '%LOCALAPPDATA%\Old\upd.exe'
        $b.Kind  | Should -Be 'ExpandString'
        $script:fake.LastGetValueOption | Should -Be 'DoNotExpandEnvironmentNames'
    }

    It 'throws, and removes nothing, when the value name does not exist' {
        { Disable-RunEntry -Key $key -Name 'Missing' -BackupDir $backupDir } | Should -Throw '*No value named*'
        Should -Invoke Remove-ItemProperty -Times 0 -Exactly
    }

    It 'does not remove the value if the backup cannot be written (non-terminating error)' {
        # Real write failures (access denied, disk full) are usually non-terminating
        # errors, so simulate one with Write-Error rather than throw.
        Mock Set-Content { Write-Error 'simulated write failure' }
        { Disable-RunEntry -Key $key -Name 'SomeOldUpdater' -BackupDir $backupDir } | Should -Throw
        Should -Invoke Remove-ItemProperty -Times 0 -Exactly
    }
}

Describe 'Restore-RunEntry' {
    BeforeEach {
        Mock New-ItemProperty { }
        $script:file = Join-Path $TestDrive 'SomeOldUpdater.json'
        [pscustomobject]@{ Key = $key; Name = 'SomeOldUpdater'; Value = '%LOCALAPPDATA%\Old\upd.exe'; Kind = 'ExpandString'; SavedAt = 'x' } |
            ConvertTo-Json | Set-Content -LiteralPath $file
    }

    It '-WhatIf writes nothing' {
        Restore-RunEntry -BackupFile $file -WhatIf
        Should -Invoke New-ItemProperty -Times 0 -Exactly
    }

    It 'stops and reports nothing restored if the write fails' {
        Mock New-ItemProperty { Write-Error 'simulated write failure' }
        { Restore-RunEntry -BackupFile $file } | Should -Throw
    }

    It 'writes back the same name, raw value and value kind' {
        $r = Restore-RunEntry -BackupFile $file
        Should -Invoke New-ItemProperty -Times 1 -Exactly -ParameterFilter {
            $LiteralPath -eq $key -and $Name -eq 'SomeOldUpdater' -and
            $Value -eq '%LOCALAPPDATA%\Old\upd.exe' -and $PropertyType -eq 'ExpandString'
        }
        $r.Restored | Should -Be "$key\SomeOldUpdater"
    }
}

Describe 'Get-StartupEntry' {
    It 'lists Run values, skips (Default), and reads raw (unexpanded) text' {
        $fake = Get-FakeRegistryKey -Values @{ '' = 'default'; 'App1' = '%ProgramFiles%\a.exe' } -Kinds @{}
        # Only the HKCU Run key "exists". ($testKey, not $key: the function's own
        # loop variable is called $key and would shadow it inside the mock.)
        $testKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        Mock Test-Path { $LiteralPath -eq $testKey }
        Mock Get-Item { $fake }
        $r = @(Get-StartupEntry | Where-Object Source -eq 'Registry')
        $r.Count      | Should -Be 1
        $r[0].Name    | Should -Be 'App1'
        $r[0].Command | Should -Be '%ProgramFiles%\a.exe'
        $fake.LastGetValueOption | Should -Be 'DoNotExpandEnvironmentNames'
    }
}
