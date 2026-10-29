# startup-audit

A small PowerShell file that lists what starts when you sign in to Windows (the `Run` / `RunOnce` registry keys and the two Startup folders), and can remove **one** leftover `Run` value safely: preview with `-WhatIf`, save a JSON backup first, and put it back later.

> **Test status, honestly:** the script parses cleanly, PSScriptAnalyzer reports 0 findings, and the Pester tests in `tests/` pass. All of that was done with **PowerShell 7 on Linux, using fake registry objects**. **It has not yet been run against a real Windows registry, on Windows 10/11, or on Windows PowerShell 5.1.** Try every change with `-WhatIf` first, and make a restore point if you are unsure.

## What it does

Dot-sourcing `startup-audit.ps1` loads three functions. Nothing runs and nothing changes until you call one.

| Function | Changes anything? | What it does |
|---|---|---|
| `Get-StartupEntry` | No (read-only) | Lists values under `HKCU`/`HKLM` `...\CurrentVersion\Run` and `RunOnce`, and `HKLM\Software\WOW6432Node\...\Run`, plus files in your Startup folder and the all-users Startup folder (`desktop.ini` is skipped). Commands are shown as stored, so `%LOCALAPPDATA%` and similar are not expanded. |
| `Disable-RunEntry -Key <path> -Name <value>` | Yes: removes one registry value | Reads the value's raw text and its kind (`String` / `ExpandString` and so on), writes them to a JSON file, then removes the value. Throws if the name doesn't exist. Returns the path of the backup file. |
| `Restore-RunEntry -BackupFile <file>` | Yes: writes one registry value | Reads the JSON file and writes the value back with the same name, text and kind (overwriting a value of that name if one exists). |

What it does **not** cover: scheduled tasks, services, per-app "start with Windows" settings, or the On/Off state you see in Settings > Apps > Startup and Task Manager. Check there first; if an entry has a toggle, the toggle is the simpler fix and you can undo it with one click.

## How to run it

1. Download `startup-audit.ps1` and read it (it's about 120 lines of plain text).
2. Open PowerShell. A normal (non-admin) window is enough for listing everything (reading `HKLM` doesn't need admin rights) and for changing `HKCU` entries. Removing or restoring an `HKLM` entry, or touching the all-users Startup folder, needs **Run as administrator**.
3. If PowerShell refuses to run scripts, allow them for this window only, and unblock the file you have read:

   ```powershell
   Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process
   Unblock-File -Path .\startup-audit.ps1
   ```

   `-Scope Process` lasts until you close the window; your normal execution policy is unchanged.
4. Load the functions (note the leading dot and space) and list your startup entries:

   ```powershell
   . .\startup-audit.ps1
   Get-StartupEntry | Format-Table -AutoSize
   ```

5. Remove one leftover value, previewing first:

   ```powershell
   Disable-RunEntry -Key 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'SomeOldUpdater' -WhatIf
   Disable-RunEntry -Key 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'SomeOldUpdater'
   ```

Only remove entries you understand, typically one that points to a program you've already uninstalled. Don't remove security software, and look up anything you don't recognise first.

## -WhatIf, -Confirm and undo (as implemented)

- `Disable-RunEntry` and `Restore-RunEntry` declare `SupportsShouldProcess`, so both accept `-WhatIf` and `-Confirm`. Under `-WhatIf` nothing is written: no backup folder, no backup file, no registry change. (`Disable-RunEntry` still reads the key and still throws if the value name doesn't exist; `Restore-RunEntry` still reads the backup file.)
- `-Confirm` asks once, at the main step. The inner commands use `-Confirm:$false` so you aren't asked three times.
- **Backup before delete:** `Disable-RunEntry` writes the JSON backup first. Folder creation, the backup write and the removal all use `-ErrorAction Stop`, so if the backup can't be written the value is not removed.
- **Backup location:** by default `%LOCALAPPDATA%\StartupBackups\<Name>_<yyyyMMdd-HHmmss>.json`. Change it with `-BackupDir`. Backups are never deleted by the script.
- **Undo:** pass the backup file path (printed by `Disable-RunEntry`) to `Restore-RunEntry`, ideally with `-WhatIf` first:

  ```powershell
  Restore-RunEntry -BackupFile "$env:LOCALAPPDATA\StartupBackups\SomeOldUpdater_20261029-101500.json" -WhatIf
  Restore-RunEntry -BackupFile "$env:LOCALAPPDATA\StartupBackups\SomeOldUpdater_20261029-101500.json"
  ```

- **Startup folder shortcuts** have no remove/undo function here. Move a shortcut to a backup folder (not delete), and move it back to undo:

  ```powershell
  $backup = Join-Path $env:LOCALAPPDATA 'StartupBackups\StartupFolder'
  New-Item -ItemType Directory -Path $backup -Force | Out-Null
  Move-Item -LiteralPath (Join-Path ([Environment]::GetFolderPath('Startup')) 'SomeApp.lnk') -Destination $backup -WhatIf
  ```

- If you elevate with a *different* administrator's password, `HKCU` and `%LOCALAPPDATA%` belong to that administrator's account, not yours.

## Tests

```powershell
Invoke-ScriptAnalyzer -Path .\startup-audit.ps1 -Severity Error,Warning,Information
Invoke-Pester -Path .\tests
```

The tests mock `Get-Item`, `Test-Path`, `Remove-ItemProperty` and `New-ItemProperty`, and write backups only to Pester's `TestDrive:`. They never touch a real registry. They check: `-WhatIf` writes nothing; a real run writes the backup (raw value and kind) before removing; a missing name throws and removes nothing; a failed backup write stops the removal; restore writes back the same name, value and kind; the read-only list skips the `(Default)` value and doesn't expand environment variables.

Last run (Oct 29, 2026, ET): PowerShell 7.4.6 on Linux, PSScriptAnalyzer 1.25.0: 0 findings in the script and in `tests/`; Pester 6.2.0: 8 passed, 0 failed. Not run on Windows yet. If you run it on Windows 10/11, an issue saying what happened is welcome.

## Sources (Microsoft)

- Configure startup applications in Windows: https://support.microsoft.com/en-us/windows/experience/startup-boot/configure-startup-applications-in-windows
- Run and RunOnce registry keys: https://learn.microsoft.com/en-us/windows/win32/setupapi/run-and-runonce-registry-keys
- Win32_StartupCommand class: https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-startupcommand
- Everything you wanted to know about ShouldProcess: https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess

## Related

A fuller paid guide (Windows 11 Fix-It Guide + PowerShell Toolkit) covers startup, disk space, Windows Update and more: https://pcfixitkits.gumroad.com/l/vgkvmp. This repo is free and complete on its own; you don't need the guide to use it.

## License and disclaimers

MIT (see `LICENSE`). Provided as-is, without warranty. Making changes to Windows carries risk; back up first.

This code and README were written with AI assistance.

Not affiliated with or endorsed by Microsoft. Windows and PowerShell are trademarks of the Microsoft group of companies.
