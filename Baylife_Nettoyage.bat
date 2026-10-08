<# : Baylife - outil de nettoyage. Ce fichier se lit en entier dans le Bloc-notes.
@echo off
setlocal
title Baylife - Nettoyage
set "BAY_SELF=%~f0"
set "BAY_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "BAY_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%BAY_PS%" (
    echo PowerShell est introuvable sur ce PC. Ouvrez un ticket Baylife.
    pause
    exit /b 1
)
"%BAY_PS%" -NoProfile -Command "exit [int](-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))"
if errorlevel 1 (
    if "%~1"=="eleve" (
        echo Les droits administrateur sont necessaires. Ouvrez un ticket Baylife.
        pause
        exit /b 1
    )
    echo Windows va demander l'autorisation administrateur : cliquez sur Oui.
    "%BAY_PS%" -NoProfile -Command "try { Start-Process -FilePath $env:BAY_SELF -ArgumentList 'eleve' -Verb RunAs -ErrorAction Stop } catch { exit 1 }"
    if errorlevel 1 (
        echo.
        echo Autorisation refusee : rien n'a ete fait.
        pause
    )
    exit /b
)
"%BAY_PS%" -NoProfile -Command "& ([scriptblock]::Create([IO.File]::ReadAllText($env:BAY_SELF)))"
echo.
pause
exit /b
#>

# =============================================================================
#  Baylife - Nettoyage du programme espion "CrashHandler"
#
#  Les lignes au-dessus demandent seulement les droits administrateur puis lancent
#  la suite de ce fichier avec PowerShell (inclus dans Windows).
#
#  Ce que fait l'outil :
#   1. Bloque l'adresse et les domaines du pirate (pare-feu Windows + fichier hosts).
#   2. Cherche le programme espion, UNIQUEMENT aux endroits connus :
#        - dossier %LOCALAPPDATA%\CrashHandler (CrashHandler.exe, Updater.exe)
#        - dossier %TEMP%\iTQAFOqm
#        - tâches planifiées, raccourcis de démarrage, clés Run et abonnements WMI
#          qui lancent ces fichiers
#   3. S'il le trouve : retire son démarrage automatique, l'arrête, supprime ses fichiers.
#   4. Écrit un rapport texte sur votre Bureau.
#
#  Ce que l'outil ne fait PAS : il ne lit pas vos fichiers personnels, n'envoie rien
#  sur Internet et ne touche à aucun autre programme.
#
#  Mode test (ne modifie rien) : dans une invite de commandes administrateur,
#  tapez  set BAY_SIMULATION=1  puis lancez ce fichier.
# =============================================================================

$ErrorActionPreference = 'Continue'
$simulation = ($env:BAY_SIMULATION -eq '1')
$c2Ip = '45.152.149.66'
$c2Domains = @('simplynetworking.eu', 'www.simplynetworking.eu', 'cdn.simplynetworking.eu', 'content.simplynetworking.eu')
$spyRx = '(?i)(\\AppData\\Local|%LOCALAPPDATA%)\\CrashHandler\\|\\iTQAFOqm'
$report = New-Object System.Collections.ArrayList

function Say($text, $color) {
    if (-not $color) { $color = 'Gray' }
    Write-Host $text -ForegroundColor $color
    [void]$report.Add($text)
}

function Step($text) {
    Say ''
    Say "=== $text ===" 'Cyan'
}

function Act($text, [scriptblock]$action) {
    if ($simulation) { Say "  [simulation] $text" 'Yellow'; return }
    try { & $action; Say "  [OK] $text" 'Green' }
    catch { Say "  [ÉCHEC] $text : $($_.Exception.Message)" 'Red' }
}

function Invoke-Exe($exe, [string[]]$arguments) {
    $out = & $exe $arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw (($out | Out-String).Trim()) }
}

function Read-AsText($path) {
    try { $bytes = [IO.File]::ReadAllBytes($path) } catch { return '' }
    $text = [Text.Encoding]::Unicode.GetString($bytes) + [Text.Encoding]::Default.GetString($bytes)
    if ($bytes.Length -gt 1) { $text += [Text.Encoding]::Unicode.GetString($bytes, 1, $bytes.Length - 1) }
    $text
}

function Get-Sha256($path) {
    try {
        $stream = [IO.File]::OpenRead($path)
        try { $hash = [Security.Cryptography.SHA256]::Create().ComputeHash($stream) } finally { $stream.Close() }
        ([BitConverter]::ToString($hash) -replace '-', '')
    } catch { '?' }
}

function Get-Profiles {
    $seen = @{}
    $list = @()
    $paths = @()
    foreach ($k in @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction SilentlyContinue)) { $paths += $k.GetValue('ProfileImagePath') }
    $paths += $env:USERPROFILE
    foreach ($p in $paths) {
        if ($p -and -not $seen.ContainsKey($p.ToLower()) -and [IO.Directory]::Exists($p)) {
            $seen[$p.ToLower()] = $true
            $list += $p
        }
    }
    $list
}

function Get-SpyProcesses {
    @(Get-WmiObject Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.ExecutablePath -and $_.ExecutablePath -match $spyRx })
}

function Get-SpyChildren($spyProcs) {
    $all = @(Get-WmiObject Win32_Process -ErrorAction SilentlyContinue)
    $tree = @{}
    foreach ($x in $spyProcs) { $tree["$($x.ProcessId)"] = "$($x.CreationDate)" }
    $children = @()
    do {
        $added = $false
        foreach ($x in $all) {
            $id = "$($x.ProcessId)"
            $parent = "$($x.ParentProcessId)"
            if (-not $tree.ContainsKey($id) -and $tree.ContainsKey($parent) -and "$($x.CreationDate)" -gt $tree[$parent]) {
                $tree[$id] = "$($x.CreationDate)"
                $children += $x
                $added = $true
            }
        }
    } while ($added)
    $children
}

function Find-Spy {
    $found = @{ Dirs = @(); Kept = @(); Tasks = @(); Run = @(); Startup = @(); Wmi = @(); Procs = @() }
    $seen = @{}

    $temps = @()
    foreach ($p in $profiles) {
        $d = Join-Path $p 'AppData\Local\CrashHandler'
        if ([IO.Directory]::Exists($d)) {
            $content = $null
            try { $content = @([IO.Directory]::GetFileSystemEntries($d) | ForEach-Object { [IO.Path]::GetFileName($_) }) } catch { }
            if ($null -ne $content -and ($content.Count -eq 0 -or $content -contains 'CrashHandler.exe' -or $content -contains 'Updater.exe')) { $found.Dirs += $d }
            else { $found.Kept += $d }
        }
        $temps += Join-Path $p 'AppData\Local\Temp'
    }
    if ($env:TEMP) { $temps += $env:TEMP }
    foreach ($t in $temps) {
        if ($seen.ContainsKey($t.ToLower())) { continue }
        $seen[$t.ToLower()] = $true
        $d = Join-Path $t 'iTQAFOqm'
        if ([IO.Directory]::Exists($d)) { $found.Dirs += $d }
    }

    $taskRoot = Join-Path $env:SystemRoot 'System32\Tasks'
    $taskFiles = @(Join-Path $taskRoot 'CrashHandler')
    $taskFiles += @(Get-ChildItem -LiteralPath $taskRoot -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer } | ForEach-Object { $_.FullName })
    foreach ($tf in $taskFiles) {
        $name = $tf.Substring($taskRoot.Length)
        if ($found.Tasks -contains $name) { continue }
        $xml = ''
        try { $xml = [IO.File]::ReadAllText($tf) } catch { }
        if ($xml -match $spyRx -or ($name -eq '\CrashHandler' -and $xml -match '(?i)(CrashHandler|Updater)\.exe')) { $found.Tasks += $name }
    }

    $runKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce')
    foreach ($u in @(Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue)) {
        if ($u.PSChildName -match '^S-1-5-' -and $u.PSChildName -notmatch '_Classes$') {
            $runKeys += "Registry::HKEY_USERS\$($u.PSChildName)\Software\Microsoft\Windows\CurrentVersion\Run"
            $runKeys += "Registry::HKEY_USERS\$($u.PSChildName)\Software\Microsoft\Windows\CurrentVersion\RunOnce"
        }
    }
    foreach ($k in $runKeys) {
        $key = Get-Item -LiteralPath $k -ErrorAction SilentlyContinue
        if (-not $key) { continue }
        foreach ($n in $key.GetValueNames()) {
            if ($n -and ("$($key.GetValue($n))" -match $spyRx)) { $found.Run += New-Object PSObject -Property @{ Key = $k; Name = $n } }
        }
    }

    $startupDirs = @()
    if ($env:ProgramData) { $startupDirs += Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\StartUp' }
    foreach ($p in $profiles) { $startupDirs += Join-Path $p 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup' }
    foreach ($s in $startupDirs) {
        foreach ($sf in @(Get-ChildItem -LiteralPath $s -Force -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer -and $_.Length -lt 1MB })) {
            if ($sf.Name -eq 'CrashHandler.lnk' -or (Read-AsText $sf.FullName) -match $spyRx) { $found.Startup += $sf.FullName }
        }
    }

    foreach ($cls in 'CommandLineEventConsumer', 'ActiveScriptEventConsumer') {
        foreach ($c in @(Get-WmiObject -Namespace 'root\subscription' -Class $cls -ErrorAction SilentlyContinue)) {
            if ("$($c.CommandLineTemplate) $($c.ExecutablePath) $($c.ScriptText) $($c.ScriptFileName)" -match $spyRx) { $found.Wmi += $c }
        }
    }

    $found.Procs = @(Get-SpyProcesses)
    $found
}

function Count-Spy($found) {
    $found.Dirs.Count + $found.Tasks.Count + $found.Run.Count + $found.Startup.Count + $found.Wmi.Count + $found.Procs.Count
}

$profiles = @(Get-Profiles)

Say '============================================================' 'Cyan'
Say ' Baylife - Nettoyage du programme espion "CrashHandler"' 'Cyan'
Say '============================================================' 'Cyan'
Say "$(Get-Date -Format 'yyyy-MM-dd HH:mm')  |  $([Environment]::OSVersion.VersionString)  |  PowerShell $($PSVersionTable.PSVersion)"
if ($simulation) { Say 'MODE SIMULATION : rien ne sera modifié.' 'Yellow' }
Write-Host ''
Write-Host 'Cet outil :'
Write-Host ' - bloque l''adresse du pirate (pare-feu Windows et fichier hosts) ;'
Write-Host ' - cherche le programme espion, uniquement aux endroits connus ;'
Write-Host ' - s''il le trouve, l''arrête et le supprime.'
Write-Host 'Il ne lit pas vos fichiers personnels et n''envoie rien sur Internet.'
Write-Host ''
[void](Read-Host 'Appuyez sur Entrée pour lancer (ou fermez cette fenêtre pour annuler)')

Step '1/4  Blocage du serveur du pirate'
foreach ($dir in 'out', 'in') {
    $rule = 'Baylife_Blocage_{0}_{1}' -f $c2Ip, $dir
    & netsh.exe advfirewall firewall show rule "name=$rule" > $null 2>&1
    if ($LASTEXITCODE -eq 0) { Say "  [OK] Pare-feu Windows : $c2Ip déjà bloqué ($dir)" 'Green'; continue }
    Act "Pare-feu Windows : blocage de $c2Ip ($dir)" {
        Invoke-Exe 'netsh.exe' @('advfirewall', 'firewall', 'add', 'rule', "name=$rule", "dir=$dir", 'action=block', "remoteip=$c2Ip", 'enable=yes', 'profile=any')
    }
}
$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$hostsText = ''
if ([IO.File]::Exists($hostsPath)) { try { $hostsText = [IO.File]::ReadAllText($hostsPath) } catch { } }
$missing = @($c2Domains | Where-Object { $hostsText -notmatch ('(?im)^[^#\r\n]*[ \t]' + [regex]::Escape($_) + '([ \t#\r]|$)') })
if ($missing.Count -eq 0) { Say '  [OK] Fichier hosts : domaines du pirate déjà bloqués' 'Green' }
else {
    Act ('Fichier hosts : blocage de ' + ($missing -join ', ')) {
        $add = ''
        if ($hostsText.Length -gt 0 -and -not $hostsText.EndsWith("`n")) { $add = "`r`n" }
        $add += "`r`n# Baylife : blocage du programme espion CrashHandler`r`n"
        foreach ($d in $missing) { $add += "0.0.0.0 $d`r`n" }
        [IO.File]::AppendAllText($hostsPath, $add, [Text.Encoding]::ASCII)
    }
    if (-not $simulation) { & ipconfig.exe /flushdns > $null 2>&1 }
}

Step '2/4  Recherche du programme espion'
$found = Find-Spy
$total = Count-Spy $found
foreach ($x in $found.Procs) { Say "  [TROUVÉ] Programme en cours : $($x.ExecutablePath) (PID $($x.ProcessId))" 'Red' }
foreach ($x in $found.Tasks) { Say "  [TROUVÉ] Tâche planifiée : $x" 'Red' }
foreach ($x in $found.Run) { Say "  [TROUVÉ] Démarrage automatique : $($x.Key) -> $($x.Name)" 'Red' }
foreach ($x in $found.Startup) { Say "  [TROUVÉ] Raccourci de démarrage : $x" 'Red' }
foreach ($x in $found.Wmi) { Say "  [TROUVÉ] Abonnement WMI : $($x.Name)" 'Red' }
foreach ($x in $found.Dirs) {
    $files = @(Get-ChildItem -LiteralPath $x -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer })
    Say "  [TROUVÉ] Dossier : $x ($($files.Count) fichiers)" 'Red'
    foreach ($f in @($files | Where-Object { $_.Extension -eq '.exe' -or $_.Extension -eq '.dll' })) { Say "           $($f.Name)  SHA256 $(Get-Sha256 $f.FullName)" }
}
foreach ($x in $found.Kept) { Say "  [ATTENTION] Dossier $x présent mais sans CrashHandler.exe ni Updater.exe : laissé intact" 'Yellow' }
if ($total -eq 0) { Say '  Rien trouvé.' 'Green' }

if ($total -gt 0) {
    Step '3/4  Suppression du programme espion'
    foreach ($tn in $found.Tasks) {
        Act "Supprimer la tâche planifiée $tn" {
            & schtasks.exe /End /TN $tn > $null 2>&1
            Invoke-Exe 'schtasks.exe' @('/Delete', '/TN', $tn, '/F')
        }
    }
    foreach ($r in $found.Run) {
        Act "Retirer le démarrage automatique $($r.Name)" { Remove-ItemProperty -LiteralPath $r.Key -Name $r.Name -ErrorAction Stop }
    }
    foreach ($s in $found.Startup) {
        Act "Supprimer le raccourci de démarrage $s" { Remove-Item -LiteralPath $s -Force -ErrorAction Stop }
    }
    foreach ($c in $found.Wmi) {
        Act "Supprimer l'abonnement WMI $($c.Name)" {
            $rel = $c.__RELPATH
            Get-WmiObject -Namespace 'root\subscription' -Class __FilterToConsumerBinding -ErrorAction SilentlyContinue |
                Where-Object { "$($_.Consumer)".EndsWith($rel) } | ForEach-Object { $_.Delete() }
            $c.Delete()
        }
    }
    for ($pass = 1; $pass -le 5; $pass++) {
        $procs = @(Get-SpyProcesses | Sort-Object { $_.Name -ne 'CrashHandler.exe' })
        if ($procs.Count -eq 0) { break }
        $children = @(Get-SpyChildren $procs)
        foreach ($x in $procs + $children) {
            $label = "Arrêter $($x.Name) (PID $($x.ProcessId))"
            if ($children -contains $x) { $label += ', lancé par le programme espion' }
            Act $label {
                try { Stop-Process -Id $x.ProcessId -Force -ErrorAction Stop }
                catch { if (Get-Process -Id $x.ProcessId -ErrorAction SilentlyContinue) { throw } }
            }
        }
        if ($simulation) { break }
        Start-Sleep -Seconds 2
    }
    foreach ($t in $found.Dirs) {
        Act "Supprimer $t" {
            for ($try = 1; $try -le 5; $try++) {
                try { Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction Stop } catch { }
                if (-not [IO.Directory]::Exists($t)) { return }
                Start-Sleep -Seconds 2
            }
            throw 'encore utilisé : redémarrez le PC puis relancez cet outil'
        }
    }

    Step '4/4  Vérification'
    if ($simulation) { $left = $total; Say '  Sautée en simulation.' 'Yellow' }
    else {
        $after = Find-Spy
        $left = Count-Spy $after
        if ($left -eq 0) { Say '  Plus aucune trace du programme espion.' 'Green' }
        else { Say "  $left élément(s) encore présent(s)." 'Red' }
    }
}

Say ''
if ($simulation) {
    if ($total -gt 0) { Say ">>> SIMULATION : $total élément(s) du programme espion trouvé(s). Rien n'a été modifié. <<<" 'Yellow' }
    else { Say ">>> SIMULATION : aucune trace du programme espion. Rien n'a été modifié. <<<" 'Yellow' }
} elseif ($total -eq 0) {
    Say '>>> Aucune trace du programme espion sur ce PC. <<<' 'Green'
} elseif ($left -eq 0) {
    Say '>>> VOTRE PC ÉTAIT INFECTÉ. Le programme espion a été supprimé. <<<' 'Green'
    Say 'Maintenant :' 'White'
    Say '  1. Redémarrez votre PC.' 'White'
    Say '  2. Relancez cet outil : il doit afficher "Aucune trace".' 'White'
    Say '  3. Changez vos mots de passe.' 'White'
} else {
    Say '>>> NETTOYAGE INCOMPLET <<<' 'Red'
    Say 'Redémarrez votre PC et relancez cet outil. Si ce message revient, ouvrez un ticket Baylife avec le rapport.' 'White'
}
if ($found.Kept.Count -gt 0) { Say 'Un dossier CrashHandler inhabituel a été laissé intact : ouvrez un ticket Baylife avec le rapport.' 'Yellow' }

$desktop = [Environment]::GetFolderPath('Desktop')
if (-not $desktop -or -not [IO.Directory]::Exists($desktop)) { $desktop = $env:TEMP }
$reportPath = Join-Path $desktop ('Baylife_nettoyage_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.txt')
try {
    [IO.File]::WriteAllLines($reportPath, [string[]]$report.ToArray(), [Text.Encoding]::UTF8)
    Write-Host ''
    Write-Host "Rapport enregistré : $reportPath"
} catch {
    Write-Host "Rapport non enregistré : $($_.Exception.Message)" -ForegroundColor Yellow
}
