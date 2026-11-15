#Requires -Version 5.1
<#
.SYNOPSIS
    Passive Windows PC health check that produces an HTML dashboard.

.DESCRIPTION
    Reads health evidence that already exists on the machine: SMART / storage
    reliability counters, hardware error logs (WHEA), sensor readings, the
    driver inventory, Windows Update state and the servicing stack.

    It never runs a stress test, benchmark or surface scan, so it does not
    add wear to any component. The only optional heavier operation is
    -DeepScan, which runs the read-only DISM /ScanHealth and SFC /verifyonly.

.PARAMETER DeepScan
    Also run DISM ScanHealth and SFC /verifyonly (read-only, 10-20 minutes).

.PARAMETER NoSensors
    Do not download or load LibreHardwareMonitor (no kernel driver is loaded;
    temperatures, fans and voltages will be missing).

.PARAMETER Offline
    Make no network calls (no Windows Update search, no vendor lookups, no
    LibreHardwareMonitor download; an already downloaded copy is still used).

.PARAMETER WatchMinutes
    Keep reading the sensors for this many minutes while you use the PC
    normally (for example, play a game). Records the minimum and maximum of
    every sensor so voltage sag and peak temperatures under YOUR real load
    are captured, without this tool generating any load itself.

.PARAMETER Days
    How far back to look in the event logs. Default 30.

.PARAMETER OutDir
    Where to write the report. Default: .\reports next to this script.

.PARAMETER NoOpen
    Do not open the dashboard in the browser when finished.

.NOTES
    This file is deliberately pure ASCII so Windows PowerShell 5.1 parses it
    correctly regardless of the system code page.
#>
[CmdletBinding()]
param(
    [switch]$DeepScan,
    [switch]$NoSensors,
    [switch]$Offline,
    [int]$Days = 30,
    [int]$WatchMinutes = 0,
    [string]$OutDir,
    [switch]$NoOpen
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$started = Get-Date
$Since = $started.AddDays(-1 * $Days)

# ---------------------------------------------------------------- elevation
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$IsAdmin = (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin -and $PSCommandPath) {
    Write-Host 'Requesting administrator rights (needed for SMART, sensors and driver store)...'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', ('"{0}"' -f $PSCommandPath))
    foreach ($k in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$k]
        if ($v -is [switch]) { if ($v) { $argList += "-$k" } }
        else { $argList += "-$k"; $argList += ('"{0}"' -f $v) }
    }
    try {
        Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -ArgumentList $argList -ErrorAction Stop
        return
    } catch {
        Write-Warning 'Elevation was declined. Continuing with limited data.'
    }
}

try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

# -------------------------------------------------------------------- rules
$rulesPath = Join-Path $PSScriptRoot 'PCHealth.Rules.ps1'
if (-not (Test-Path $rulesPath)) { Write-Error 'PCHealth.Rules.ps1 must be in the same folder as this script.'; return }
. $rulesPath

# ------------------------------------------------------------------ helpers
$script:StepFailures = 0
$script:AppxAll = $null
# A compact record of this run, saved with the report so the next run can say what changed.
$script:Snap = @{ generated = ''; bios = ''; build = ''; incidents = @(); whea = @(); tdr = @(); drives = @{}; drivers = @{}; rails = @{}; findings = @() }
$script:Areas = [ordered]@{}
$script:Errors = New-Object System.Collections.ArrayList
$script:Sensors = New-Object System.Collections.ArrayList
$script:SensorNote = ''
$script:SensorSource = ''
$script:Links = New-Object System.Collections.ArrayList
$script:WuPending = @()
$script:WuSearched = $false
$script:WuDriverTitles = @()
$script:DriverOrigins = @{}

function New-Area([string]$id, [string]$name) {
    $script:Areas[$id] = [ordered]@{
        id = $id; name = $name; status = 'ok'; summary = ''
        gauges = (New-Object System.Collections.ArrayList)
        findings = (New-Object System.Collections.ArrayList)
        facts = (New-Object System.Collections.ArrayList)
        tables = (New-Object System.Collections.ArrayList)
    }
}
function Add-Fact([string]$area, [string]$k, $v) {
    if ($null -eq $v -or "$v" -eq '') { return }
    [void]$script:Areas[$area].facts.Add([ordered]@{ k = $k; v = [string]$v })
}
# sev: ok | info | warn | crit | gap   (gap = this could not be checked)
function Add-Finding([string]$area, [string]$sev, [string]$title, [string]$detail, [string]$action, [string]$link) {
    if ($sev -eq 'ok' -and $script:StepFailures -gt 0) {
        $sev = 'gap'; $title = 'Not verified: ' + $title
        $detail = ('One or more queries behind this check failed, so "nothing found" cannot be trusted here. See the collection notes at the bottom of the page. ' + $detail).Trim()
    }
    [void]$script:Areas[$area].findings.Add([ordered]@{
        sev = $sev; title = $title; detail = $detail; action = $action; link = $link })
}
function Add-Gauge([string]$area, [string]$label, [double]$value, [string]$unit, [double]$max, [string]$sev, [string]$note) {
    [void]$script:Areas[$area].gauges.Add([ordered]@{
        label = $label; value = [math]::Round($value, 1); unit = $unit; max = $max; sev = $sev; note = $note })
}
function New-Cell([string]$text, [string]$sev, [string]$href) {
    return [ordered]@{ t = $text; s = $sev; href = $href }
}
function Add-Table([string]$area, [string]$title, [string[]]$cols, $rows, [string]$note, [bool]$collapsed) {
    if ($null -eq $rows -or $rows.Count -eq 0) { return }
    $colList = New-Object System.Collections.ArrayList
    foreach ($c in $cols) { [void]$colList.Add([string]$c) }
    [void]$script:Areas[$area].tables.Add([ordered]@{
        title = $title; cols = $colList; rows = $rows; note = $note; collapsed = $collapsed })
}
function New-Rows { return ,(New-Object System.Collections.ArrayList) }
function Format-Day($d) { if ($d) { try { return ([datetime]$d).ToString('yyyy-MM-dd') } catch { return '' } } return '' }
function Format-Stamp($d) { if ($d) { try { return ([datetime]$d).ToString('yyyy-MM-dd HH:mm') } catch { return '' } } return '' }
function Format-Size([double]$bytes) {
    if ($bytes -ge 1TB) { return ('{0:N2} TB' -f ($bytes / 1TB)) }
    if ($bytes -ge 1GB) { return ('{0:N0} GB' -f ($bytes / 1GB)) }
    return ('{0:N0} MB' -f ($bytes / 1MB))
}
function Get-Short([string]$s, [int]$n) {
    if (-not $s) { return '' }
    $s = ($s -replace '\s+', ' ').Trim()
    if ($s.Length -gt $n) { return $s.Substring(0, $n) + '...' }
    return $s
}
# A query that FAILS must never look like a query that found nothing. Failures are recorded, and any
# "all clear" finding raised in the same step is downgraded to "could not be checked" (see Add-Finding).
function Register-QueryFailure([string]$what, $err) {
    $script:StepFailures++
    [void]$script:Errors.Add(('{0} could not be read: {1}' -f $what, (Get-Short ([string]$err.Exception.Message) 160)))
}
# $from: look back further than the normal window (used to find the boot that began a session)
function Get-Ev([string]$log, [string]$provider, [int[]]$ids, $from) {
    $f = @{ LogName = $log; StartTime = $Since }
    if ($from) { $f.StartTime = [datetime]$from }
    if ($provider) { $f.ProviderName = $provider }
    if ($ids) { $f.Id = $ids }
    try { return @(Get-WinEvent -FilterHashtable $f -MaxEvents 500 -ErrorAction Stop) }
    catch {
        # "no events match" and "this PC has no such event source" are genuine empties, not failures
        if ([string]$_.FullyQualifiedErrorId -notmatch 'NoMatching(Events|Providers|Logs)Found') {
            Register-QueryFailure ('Event log {0} ({1})' -f $log, $(if ($provider) { $provider } else { 'all sources' })) $_
        }
        return @()
    }
}
# -Optional: the class legitimately does not exist on many PCs (battery, ATA failure prediction), so a failure is not reported.
function Get-Cim([string]$class, [string]$ns, [string]$filter, [switch]$Optional) {
    $p = @{ ClassName = $class; ErrorAction = 'Stop' }
    if ($ns) { $p.Namespace = $ns }
    if ($filter) { $p.Filter = $filter }
    try { return @(Get-CimInstance @p) }
    catch {
        if (-not $Optional) { Register-QueryFailure ('WMI class {0}' -f $class) $_ }
        return @()
    }
}
function Get-Web([string]$url) {
    $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36'
    return (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 20 -UserAgent $ua -ErrorAction Stop).Content
}
function Invoke-Step([string]$name, [scriptblock]$body) {
    Write-Host ('  - {0}' -f $name)
    $script:StepFailures = 0
    try { & $body } catch {
        $script:StepFailures++
        [void]$script:Errors.Add(('{0}: {1}' -f $name, $_.Exception.Message))
        Write-Host ('      (problem: {0})' -f $_.Exception.Message) -ForegroundColor DarkYellow
        $areaOf = @{ 'CPU' = 'cpu'; 'GPU' = 'gpu'; 'Memory' = 'memory'; 'Drives' = 'drives'; 'Power supply' = 'psu'; 'Motherboard' = 'board'; 'Windows installation' = 'windows'; 'Crash analysis' = 'crash'; 'Drivers' = 'drivers'; 'Changes since last run' = 'changes' }
        if ($areaOf.ContainsKey($name)) {
            Add-Finding $areaOf[$name] 'gap' 'This section could not be completed' ('The tool hit an error part-way through this section, so what is shown here is incomplete: {0}' -f (Get-Short ([string]$_.Exception.Message) 200)) 'Please report this message so it can be fixed.' ''
        }
    }
}
function Get-Sens([string]$hwTypePattern, [string]$type) {
    return @($script:Sensors | Where-Object { $_.Valid -and $_.HwType -match $hwTypePattern -and $_.Type -eq $type -and -not ($type -eq 'Temperature' -and $_.Name -match $script:RefSensor) })
}
New-Area 'changes' 'Since last run'
New-Area 'crash' 'Crashes'
New-Area 'cpu' 'CPU'
New-Area 'gpu' 'GPU'
New-Area 'memory' 'Memory'
New-Area 'drives' 'Drives'
New-Area 'psu' 'Power supply'
New-Area 'board' 'Motherboard'
New-Area 'windows' 'Windows'
New-Area 'drivers' 'Drivers'

Write-Host ''
Write-Host 'PC Health Check - passive read-only scan' -ForegroundColor Cyan
Write-Host ('Looking back {0} days in the event logs.' -f $Days)
Write-Host ''

# ------------------------------------------------- sensors (LibreHardwareMonitor)
# The sensor library is loaded into an elevated process, so it is pinned: sensor-packages.json lists the exact
# NuGet packages and the SHA-256 of every DLL. Files are fetched from nuget.org (packages there are immutable),
# and EVERY file is re-verified on EVERY run before anything is loaded, so neither a changed upstream release
# nor a DLL planted in the lib folder can get code executed.
$script:LhmAllowed = @()
function Get-LhmLibrary {
    $manifestPath = Join-Path $PSScriptRoot 'sensor-packages.json'
    if (-not (Test-Path $manifestPath)) { $script:SensorNote = 'sensor-packages.json is missing from the tool folder, so the sensor library was not loaded.'; return $null }
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    $fw = 'net472'; if ($PSVersionTable.PSEdition -eq 'Core') { $fw = 'net8.0' }
    $files = @($manifest.frameworks.$fw)
    $dir = Join-Path $PSScriptRoot ('lib\sensors-' + $fw)
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $bad = @($files | Where-Object { $p = Join-Path $dir $_.name; -not (Test-Path $p) -or (Get-FileHash -Path $p -Algorithm SHA256).Hash -ne $_.sha256 })
    if ($bad.Count -gt 0) {
        if ($Offline) { $script:SensorNote = 'Offline mode and no verified local copy of the sensor library.'; return $null }
        Write-Host ('      downloading {0} from nuget.org (first run only)...' -f $manifest.library)
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        foreach ($grp in ($bad | Group-Object { '{0}/{1}' -f $_.id, $_.version })) {
            $f0 = $grp.Group[0]
            $idl = ([string]$f0.id).ToLower(); $verl = ([string]$f0.version).ToLower()
            $pkg = Join-Path ([IO.Path]::GetTempPath()) ('pchealth-{0}.{1}.zip' -f $idl, $verl)
            Invoke-WebRequest -Uri ('{0}/{1}/{2}/{1}.{2}.nupkg' -f $manifest.source, $idl, $verl) -OutFile $pkg -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
            $zip = [IO.Compression.ZipFile]::OpenRead($pkg)
            try {
                foreach ($f in $grp.Group) {
                    $entry = $zip.Entries | Where-Object { $_.FullName -eq $f.path } | Select-Object -First 1
                    if (-not $entry) { throw ('{0} not found inside package {1} {2}' -f $f.path, $f.id, $f.version) }
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $dir $f.name), $true)
                }
            } finally { $zip.Dispose(); Remove-Item $pkg -Force -ErrorAction SilentlyContinue }
        }
    }
    foreach ($f in $files) {
        $p = Join-Path $dir $f.name
        if (-not (Test-Path $p) -or (Get-FileHash -Path $p -Algorithm SHA256).Hash -ne $f.sha256) {
            throw ('Sensor library integrity check failed for {0}: the file does not match the pinned SHA-256, so nothing was loaded. Delete the lib folder and re-run.' -f $f.name)
        }
    }
    $script:LhmAllowed = @($files | ForEach-Object { [string]$_.name })
    return (Get-Item (Join-Path $dir 'LibreHardwareMonitorLib.dll'))
}

$script:SensorMap = @{}
$script:Watched = $false
$script:LowLevelBroken = $false
$script:ChipDistrust = @()
$script:Monitors = @()
function Read-LhmHardware($hw) {
    $hw.Update()
    foreach ($s in $hw.Sensors) {
        if ($null -ne $s.Value) {
            $key = '{0}|{1}|{2}|{3}' -f $hw.Identifier, $s.SensorType, $s.Name, $s.Index
            $v = [double]$s.Value
            $o = $script:SensorMap[$key]
            if (-not $o) {
                $o = [pscustomobject]@{
                    Hw = [string]$hw.Name; HwType = [string]$hw.HardwareType
                    Name = [string]$s.Name; Type = [string]$s.SensorType; Value = $v; Min = $v; Max = $v; Valid = $true; Note = ''; Step = 0.0; Id = [string]$hw.Identifier }
                $script:SensorMap[$key] = $o
                [void]$script:Sensors.Add($o)
            } else {
                $jump = [math]::Abs($v - $o.Value); if ($jump -gt $o.Step) { $o.Step = $jump }
                $o.Value = $v
                if ($v -lt $o.Min) { $o.Min = $v }
                if ($v -gt $o.Max) { $o.Max = $v }
            }
        }
    }
    foreach ($sub in $hw.SubHardware) { Read-LhmHardware $sub }
}
if (-not $NoSensors) {
    Invoke-Step 'Sensors (LibreHardwareMonitor)' {
        if (-not $IsAdmin) { $script:SensorNote = 'Not elevated, sensors skipped.'; return }
        $dll = Get-LhmLibrary
        if (-not $dll) { return }
        $script:LhmDir = $dll.DirectoryName
        Get-ChildItem $script:LhmDir -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
        $resolver = [ResolveEventHandler] {
            param($sender, $e)
            $n = (New-Object Reflection.AssemblyName $e.Name).Name
            $p = Join-Path $script:LhmDir ($n + '.dll')
            if ($script:LhmAllowed -contains ($n + '.dll') -and (Test-Path $p)) { return [Reflection.Assembly]::LoadFrom($p) }
            return $null
        }
        [AppDomain]::CurrentDomain.add_AssemblyResolve($resolver)
        $computer = $null
        try {
            [void][Reflection.Assembly]::LoadFrom($dll.FullName)
            $computer = New-Object LibreHardwareMonitor.Hardware.Computer
            foreach ($p in 'IsCpuEnabled', 'IsGpuEnabled', 'IsMotherboardEnabled', 'IsMemoryEnabled', 'IsStorageEnabled', 'IsPsuEnabled') {
                try { $computer.$p = $true } catch {}
            }
            $computer.Open()
            # Two reads a second apart: some sensors only report on the second poll.
            foreach ($hw in $computer.Hardware) { try { $hw.Update() } catch {} }
            Start-Sleep -Milliseconds 1200
            if ($WatchMinutes -gt 0) {
                $script:Watched = $true
                Write-Host ('      WATCH MODE: recording sensors for {0} minute(s). Use the PC as you normally would (play a game).' -f $WatchMinutes) -ForegroundColor Cyan
            }
            $until = (Get-Date).AddMinutes($WatchMinutes); $tick = 0
            if ($WatchMinutes -le 0) {
                # snapshot: three samples a second apart, enough to expose a sensor that jumps about
                foreach ($i in 1..2) { foreach ($hw in $computer.Hardware) { try { Read-LhmHardware $hw } catch {} }; Start-Sleep -Milliseconds 1000 }
            }
            do {
                foreach ($hw in $computer.Hardware) { try { Read-LhmHardware $hw } catch {} }
                if ($WatchMinutes -gt 0) {
                    Start-Sleep -Seconds 3; $tick++
                    if ($tick % 20 -eq 0) { Write-Host ('      ... {0:N0} minute(s) left' -f ($until - (Get-Date)).TotalMinutes) }
                }
            } while ((Get-Date) -lt $until)
            $script:SensorSource = 'LibreHardwareMonitor ' + $dll.VersionInfo.FileVersion
        } finally {
            if ($computer) { try { $computer.Close() } catch {} }   # unloads the kernel driver
            [AppDomain]::CurrentDomain.remove_AssemblyResolve($resolver)
        }
        if ($script:Sensors.Count -eq 0) { $script:SensorNote = 'LibreHardwareMonitor loaded but returned no readings.' }
        # Without low-level (MSR / port) access the library still lists CPU and board sensors but every value is a
        # placeholder: 0 C temperatures, 0 W power and an identical 1.55 V on every core. Detect that and discard them.
        $cpuT = @($script:Sensors | Where-Object { $_.HwType -eq 'Cpu' -and $_.Type -eq 'Temperature' })
        if ($cpuT.Count -gt 0 -and @($cpuT | Where-Object { $_.Max -gt 0 }).Count -eq 0) {
            $script:LowLevelBroken = $true
            foreach ($s in $script:Sensors) { if ($s.HwType -match '^Cpu$|SuperIO|EmbeddedController|Motherboard') { $s.Valid = $false } }
        }
        foreach ($s in $script:Sensors) { if ($s.Type -eq 'Temperature' -and ($s.Max -le 0 -or $s.Max -gt 150)) { $s.Valid = $false } }

        # ---- plausibility checks. The board's Super I/O chip (Nuvoton, ITE, Fintek) is the least trustworthy source:
        # its inputs are wired differently on every board and other monitoring software can corrupt its readings.
        foreach ($s in $script:Sensors) {
            if (-not $s.Valid) { continue }
            $why = Test-SensorErratic $s
            if ($why) { $s.Valid = $false; $s.Note = $why }
        }
        # cross-check the chip's CPU temperature against the CPU's own internal sensor
        $own = $script:Sensors | Where-Object { $_.Valid -and $_.HwType -eq 'Cpu' -and $_.Type -eq 'Temperature' -and $_.Name -match 'Package|Tctl|Tdie' } | Sort-Object Value -Descending | Select-Object -First 1
        if ($own) {
            foreach ($chip in @($script:Sensors | Where-Object { $_.HwType -eq 'SuperIO' } | ForEach-Object { $_.Hw } | Select-Object -Unique)) {
                $c = $script:Sensors | Where-Object { $_.Valid -and $_.Hw -eq $chip -and $_.Type -eq 'Temperature' -and $_.Name -match '^CPU' } | Select-Object -First 1
                if ($c -and [math]::Abs($c.Value - $own.Value) -gt 25) {
                    $script:ChipDistrust += ('{0} reports the CPU at {1:N0} C while the CPU''s own sensor says {2:N0} C' -f $chip, $c.Value, $own.Value)
                    foreach ($s in $script:Sensors) { if ($s.Hw -eq $chip -and $s.Type -eq 'Temperature') { $s.Valid = $false; $s.Note = 'Ignored: this chip''s CPU temperature disagrees with the CPU''s own sensor, so its temperatures are not trusted' } }
                }
            }
        }
        $script:Monitors = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^(ArmouryCrate|ArmourySocketServer|asus_framework|AsusFanControlService|AISuite3|DipAwayMode|HWiNFO|HWMonitor|iCUE|NZXT CAM|FanControl|OpenRGB|SignalRgb|AMDRyzenMasterDriver|AMD Ryzen Master|MSIAfterburner|SIV64X|AIDA64|CoreTemp|OpenHardwareMonitor|LibreHardwareMonitor)' } | ForEach-Object { $_.ProcessName } | Select-Object -Unique)
    }
    if (-not $script:SensorSource -and -not $script:SensorNote) {
        $script:SensorNote = 'LibreHardwareMonitor could not be loaded (see collection notes).'
    }
} else {
    $script:SensorNote = 'Sensors disabled with -NoSensors.'
}

# ---------------------------------------------------------------------- CPU
$script:Whea = @()
Invoke-Step 'CPU' {
    $cpus = Get-Cim 'Win32_Processor'
    $cpu = $cpus | Select-Object -First 1
    if ($cpu) {
        Add-Fact 'cpu' 'Model' $cpu.Name.Trim()
        Add-Fact 'cpu' 'Cores / threads' ('{0} / {1}' -f $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors)
        Add-Fact 'cpu' 'Socket' $cpu.SocketDesignation
        Add-Fact 'cpu' 'Rated speed' ('{0} MHz' -f $cpu.MaxClockSpeed)
        Add-Fact 'cpu' 'Load during scan' ('{0} %' -f $cpu.LoadPercentage)
    }
    $mcRev = $null
    try {
        $b = (Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -ErrorAction Stop).'Update Revision'
        if ($b -and $b.Length -ge 8) {
            $hi = [BitConverter]::ToUInt32($b, 4); $lo = [BitConverter]::ToUInt32($b, 0)
            if ($hi -ne 0) { $mcRev = $hi } else { $mcRev = $lo }
            Add-Fact 'cpu' 'Microcode revision' ('0x{0:X}' -f $mcRev)
        }
    } catch {}

    if ($cpu -and $cpu.Name -match 'i[579]-1[34]\d{3}(K|KF|KS|F|T)?(\s|$)' -and $null -ne $mcRev) {
        if ($mcRev -lt 0x12B) {
            Add-Finding 'cpu' 'warn' 'Microcode predates the Intel 13th/14th gen stability fix' `
                ('This desktop Core CPU family was affected by the "Vmin shift" instability issue, where elevated voltage requests cause permanent degradation. Microcode 0x12B or later contains the mitigations; this system reports 0x{0:X}.' -f $mcRev) `
                'Update the motherboard BIOS to a version that includes microcode 0x12B or newer.' ''
        } else {
            Add-Finding 'cpu' 'ok' 'Microcode includes the Intel 13th/14th gen voltage mitigations' ('Revision 0x{0:X} is 0x12B or newer.' -f $mcRev) '' ''
        }
    }

    if ($cpu) {
        $script:CpuTjMax = Get-CpuTjMax ([string]$cpu.Name)
        Add-Fact 'cpu' 'Thermal limit assumed (TjMax)' ('{0} C' -f $script:CpuTjMax)
    }
    $temps = Get-Sens '^Cpu$' 'Temperature'
    if ($temps.Count -eq 0) {
        Add-Finding 'cpu' 'gap' 'CPU temperature could not be read' $(if ($script:SensorNote) { $script:SensorNote } else { 'The sensor library returned no valid CPU temperature. See the Motherboard section for the reason.' }) '' ''
    }
    if ($temps.Count -gt 0) {
        $pkg = $temps | Where-Object { $_.Name -match 'Package|Tctl|Tdie|Core Max|CPU$' } | Sort-Object Max -Descending | Select-Object -First 1
        if (-not $pkg) { $pkg = $temps | Sort-Object Max -Descending | Select-Object -First 1 }
        $vd = Get-SensorVerdict $pkg $script:Sensors
        $sev = 'ok'; if ($vd[0] -in 'warn', 'crit') { $sev = $vd[0] }
        Add-Gauge 'cpu' ('Temperature ({0})' -f $pkg.Name) $pkg.Max 'C' 110 $sev $(if ($script:Watched) { 'Peak over the {0}-minute watch (lowest {1:N0} C)' -f $WatchMinutes, $pkg.Min } else { 'Snapshot at current load, not a stress test' })
        if ($sev -ne 'ok') {
            Add-Finding 'cpu' $sev ('CPU reached {0:N0} C' -f $pkg.Max) `
                ('That is within 5 C of this processor''s {0} C thermal limit, where it throttles itself. Load during the scan was about {1} %; a temperature this high near idle points at cooling, not the silicon.' -f $script:CpuTjMax, $cpu.LoadPercentage) `
                'Check the cooler is seated, the pump or fan is spinning, and the thermal paste is not dried out.' ''
        }
    }
    $load = Get-Sens '^Cpu$' 'Load' | Where-Object { $_.Name -match 'Total' } | Select-Object -First 1
    if ($load) { Add-Gauge 'cpu' 'Load' $load.Value '%' 100 'ok' '' }

    $script:Whea = Get-Ev 'System' 'Microsoft-Windows-WHEA-Logger' $null
    $script:Snap.whea = @($script:Whea | ForEach-Object { '{0}|WHEA event {1}' -f (Format-Stamp $_.TimeCreated), $_.Id })
    $fatal = @($script:Whea | Where-Object { $_.Id -in 18, 20 })
    $corrected = @($script:Whea | Where-Object { $_.Id -eq 19 })
    if ($fatal.Count -gt 0) {
        Add-Finding 'cpu' 'crit' ('{0} fatal machine-check error(s) logged' -f $fatal.Count) `
            ('Windows recorded uncorrectable hardware errors (WHEA event 18/20), most recently {0}. These come from the CPU reporting an internal, cache or bus fault.' -f (Format-Stamp $fatal[0].TimeCreated)) `
            'Remove any overclock or undervolt, load BIOS defaults, update the BIOS. If they continue at stock settings the CPU, motherboard or PSU is suspect.' ''
    }
    if ($corrected.Count -gt 0) {
        $sev = 'warn'; if ($corrected.Count -lt 3) { $sev = 'info' }
        Add-Finding 'cpu' $sev ('{0} corrected machine-check error(s) logged' -f $corrected.Count) `
            'The CPU detected and corrected internal errors (WHEA event 19). Occasional ones can be benign; a steady stream usually means an unstable overclock, undervolt or memory profile.' `
            'If you run PBO, Curve Optimizer, an undervolt or XMP/EXPO, back it off and see whether the count stops rising.' ''
    }
    $throttle = Get-Ev 'System' 'Microsoft-Windows-Kernel-Processor-Power' @(37)
    if ($throttle.Count -gt 0) {
        Add-Finding 'cpu' 'info' ('Firmware limited CPU speed {0} time(s)' -f $throttle.Count) `
            'Kernel-Processor-Power event 37: the firmware capped processor speed. This is usually thermal or power-limit throttling, and is routine on laptops.' `
            'On a desktop, check cooling and BIOS power limits.' ''
    }
    if ($fatal.Count -eq 0 -and $corrected.Count -eq 0) {
        Add-Finding 'cpu' 'ok' 'No CPU hardware errors logged' ('No machine-check events in the last {0} days.' -f $Days) '' ''
    }
}

# ---------------------------------------------------------------------- GPU
$script:Gpus = @()
Invoke-Step 'GPU' {
    $script:Gpus = @(Get-Cim 'Win32_VideoController' | Where-Object { $_.PNPDeviceID -match '^PCI' })
    $rows = New-Rows
    foreach ($g in $script:Gpus) {
        $st = 'ok'; if ($g.ConfigManagerErrorCode -ne 0) { $st = 'crit' }
        [void]$rows.Add(@([string]$g.Name, [string]$g.DriverVersion, (Format-Day $g.DriverDate),
                [string]$g.VideoModeDescription, (New-Cell ([string]$g.Status) $st '')))
        if ($g.ConfigManagerErrorCode -ne 0) {
            Add-Finding 'gpu' 'crit' ('{0} reports device error code {1}' -f $g.Name, $g.ConfigManagerErrorCode) `
                'Windows Device Manager is reporting a problem with this adapter. Code 43 means the driver stopped the device because it reported a fault.' `
                'Clean-install the vendor driver. If code 43 persists after that, reseat the card and its power cables; the card itself may be failing.' ''
        }
    }
    Add-Table 'gpu' 'Adapters' @('Adapter', 'Driver version', 'Driver date', 'Mode', 'Status') $rows '' $false

    $gt = Get-Sens '^Gpu' 'Temperature'
    if ($gt.Count -eq 0 -and $script:Gpus.Count -gt 0) {
        Add-Finding 'gpu' 'gap' 'GPU temperature could not be read' $(if ($script:SensorNote) { $script:SensorNote } else { 'The sensor library returned no GPU temperature.' }) '' ''
    }
    foreach ($hwName in @($gt | Select-Object -ExpandProperty Hw -Unique)) {
        $t = $gt | Where-Object { $_.Hw -eq $hwName -and $_.Name -match '^GPU Core$' } | Select-Object -First 1
        if (-not $t) { $t = $gt | Where-Object { $_.Hw -eq $hwName -and $_.Name -notmatch 'Hot ?Spot' } | Sort-Object Max -Descending | Select-Object -First 1 }
        if (-not $t) { continue }
        $vd = Get-SensorVerdict $t $script:Sensors
        $sev = 'ok'; if ($vd[0] -in 'warn', 'crit') { $sev = $vd[0] }
        Add-Gauge 'gpu' ('{0} - {1}' -f $hwName, $t.Name) $t.Max 'C' 110 $sev $(if ($script:Watched) { 'Peak over the {0}-minute watch' -f $WatchMinutes } else { 'Snapshot at current load' })
        if ($sev -ne 'ok') {
            Add-Finding 'gpu' $sev ('{0} reached {1:N0} C' -f $hwName, $t.Max) 'That is high for a system that is not under a deliberate load.' `
                'Check the fans spin, clear dust from the heatsink, and check case airflow.' ''
        }
    }
    foreach ($f in (Get-Sens '^Gpu' 'Fan')) {
        Add-Fact 'gpu' ('{0} {1}' -f $f.Hw, $f.Name) $(if ($f.Value -le 0) { '0 RPM (normal: most cards stop their fans when cool)' } else { '{0:N0} RPM' -f $f.Value })
    }
    foreach ($x in ($gt | Where-Object { $_.Name -notmatch '^GPU Core$' })) { Add-Fact 'gpu' ('{0} temperature' -f $x.Name) ('{0:N0} C' -f $x.Max) }
    $gpw = Get-Sens '^Gpu' 'Power' | Sort-Object Max -Descending | Select-Object -First 1
    if ($gpw) { Add-Fact 'gpu' 'Power draw now' ('{0:N0} W' -f $gpw.Value) }
    $gmu = Get-Sens '^Gpu' 'SmallData' | Where-Object { $_.Name -eq 'GPU Memory Used' } | Select-Object -First 1
    $gmt = Get-Sens '^Gpu' 'SmallData' | Where-Object { $_.Name -eq 'GPU Memory Total' } | Select-Object -First 1
    if ($gmu -and $gmt -and $gmt.Value -gt 0) { Add-Fact 'gpu' 'Graphics memory in use' ('{0:N1} of {1:N1} GB' -f ($gmu.Value / 1024), ($gmt.Value / 1024)) }

    $tdr = Get-Ev 'System' 'Display' @(4101)
    $drvErr = @()
    foreach ($p in 'nvlddmkm', 'amdkmdag', 'amdwddmg', 'igfx') { $drvErr += @(Get-Ev 'System' $p $null | Where-Object { $_.Level -le 2 }) }
    if ($tdr.Count -gt 0) {
        $sev = 'warn'; if ($tdr.Count -ge 10) { $sev = 'crit' }
        Add-Finding 'gpu' $sev ('Display driver stopped responding and recovered {0} time(s)' -f $tdr.Count) `
            ('Event 4101 (TDR), most recently {0}. Causes in rough order of likelihood: a driver bug, an unstable GPU overclock or undervolt, overheating, insufficient PSU power, failing GPU.' -f (Format-Stamp $tdr[0].TimeCreated)) `
            'Note whether it follows one game or everything. Clean-install the current driver, remove any GPU tuning, then look at temperatures and power cabling.' ''
    }
    if ($drvErr.Count -gt 0) {
        Add-Finding 'gpu' 'warn' ('{0} error event(s) from the graphics kernel driver' -f $drvErr.Count) `
            ('Most recent: {0} - {1}' -f (Format-Stamp $drvErr[0].TimeCreated), (Get-Short $drvErr[0].Message 220)) '' ''
    }
    $lkr = @()
    if (Test-Path "$env:SystemRoot\LiveKernelReports") {
        $lkr = @(Get-ChildItem "$env:SystemRoot\LiveKernelReports" -Recurse -Filter '*.dmp' -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -ge $Since -and $_.FullName -match 'WATCHDOG' })
    }
    if ($lkr.Count -gt 0) {
        Add-Finding 'gpu' 'warn' ('{0} GPU watchdog dump(s) written' -f $lkr.Count) `
            'Windows wrote live kernel reports in the WATCHDOG folder, which it does when the GPU hangs (LiveKernelEvent 141 / 117).' '' ''
    }
    if ($tdr.Count -eq 0 -and $drvErr.Count -eq 0 -and $lkr.Count -eq 0) {
        Add-Finding 'gpu' 'ok' 'No display driver crashes or GPU hangs logged' ('Nothing in the last {0} days.' -f $Days) '' ''
    }
}

# ------------------------------------------------------------------- memory
Invoke-Step 'Memory' {
    $dimms = Get-Cim 'Win32_PhysicalMemory'
    $script:RamText = ''
    $ramTotal = 0; foreach ($d in $dimms) { $ramTotal += [double]$d.Capacity }
    if ($ramTotal -gt 0) { $script:RamText = ('{0} RAM' -f (Format-Size $ramTotal)) }
    $rows = New-Rows
    $slow = $false
    foreach ($d in $dimms) {
        $cfg = $d.ConfiguredClockSpeed
        if ($d.Speed -and $cfg -and $cfg -lt $d.Speed) { $slow = $true }
        $slot = [string]$d.DeviceLocator
        if (@($dimms | Where-Object { $_.DeviceLocator -eq $d.DeviceLocator }).Count -gt 1 -and $d.BankLabel) { $slot = ('{0} ({1})' -f $d.DeviceLocator, $d.BankLabel) }
        [void]$rows.Add(@($slot, (Format-Size $d.Capacity), (Get-MemoryMaker ([string]$d.Manufacturer) ([string]$d.PartNumber)),
                ([string]$d.PartNumber).Trim(), ('{0} MHz' -f $d.Speed), ('{0} MHz' -f $cfg)))
    }
    Add-Table 'memory' 'Modules' @('Slot', 'Size', 'Maker', 'Part number', 'Rated', 'Running at') $rows '' $false
    $os = Get-Cim 'Win32_OperatingSystem' | Select-Object -First 1
    if ($os) {
        $total = $os.TotalVisibleMemorySize * 1KB; $free = $os.FreePhysicalMemory * 1KB
        $usedPct = 100 * ($total - $free) / $total
        Add-Gauge 'memory' ('In use of {0}' -f (Format-Size $total)) $usedPct '%' 100 'ok' ''
    }
    if ($slow) {
        Add-Finding 'memory' 'info' 'Memory is running below its rated speed' `
            'At least one module reports a higher rated speed than it is configured for. That normally means XMP / EXPO is not enabled in the BIOS. This is a performance point, not a health fault.' `
            'Enable the XMP or EXPO profile in the BIOS if you want the rated speed.' ''
    }
    $memWhea = @($script:Whea | Where-Object { $_.Message -match 'memory' -or $_.Id -in 46, 47 })
    if ($memWhea.Count -gt 0) {
        Add-Finding 'memory' 'warn' ('{0} hardware memory error event(s) logged' -f $memWhea.Count) `
            'WHEA recorded memory errors. On consumer (non-ECC) systems this is uncommon and worth acting on.' `
            'Run Windows Memory Diagnostic or MemTest86 once, with XMP/EXPO disabled, to separate bad memory from an unstable profile.' ''
    }
    $diag = $null
    try { $diag = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-MemoryDiagnostics-Results' } -MaxEvents 1 -ErrorAction Stop } catch {}
    if ($diag) {
        Add-Fact 'memory' 'Last Windows Memory Diagnostic' ('{0}: {1}' -f (Format-Day $diag.TimeCreated), (Get-Short $diag.Message 160))
    } else {
        Add-Fact 'memory' 'Last Windows Memory Diagnostic' 'No result on record'
    }
    if ($memWhea.Count -eq 0) {
        Add-Finding 'memory' 'ok' 'No memory hardware errors logged' 'This is passive evidence only. Memory can only be proven good by a memory test, which this tool deliberately does not run.' '' ''
    }
}

# ------------------------------------------------------------------- drives
Invoke-Step 'Drives' {
    $rows = New-Rows
    $disks = @()
    try { $disks = @(Get-PhysicalDisk -ErrorAction Stop) } catch {}
    foreach ($d in $disks) {
        $r = $null
        try { $r = $d | Get-StorageReliabilityCounter -ErrorAction Stop } catch {}
        $hs = [string]$d.HealthStatus
        $hsSev = 'ok'
        if ($hs -eq 'Warning') { $hsSev = 'warn' } elseif ($hs -ne 'Healthy') { $hsSev = 'crit' }
        $name = [string]$d.FriendlyName
        if ($hsSev -ne 'ok') {
            Add-Finding 'drives' $hsSev ('{0} reports health status "{1}"' -f $name, $hs) `
                ('Operational status: {0}. The drive itself is signalling a problem.' -f ($d.OperationalStatus -join ', ')) `
                'Back up anything on this drive now, then plan its replacement.' ''
        }
        $wear = ''; $temp = ''; $hours = ''; $errs = ''; $written = ''
        # the drive's own SMART attributes as read by LibreHardwareMonitor, matched on model name
        $ls = @(Select-DriveSensors $script:Sensors $name $d.DeviceId)
        $wr = $ls | Where-Object { $_.Name -match 'Data Written|Total Bytes Written|Host Writes' } | Select-Object -First 1
        if ($wr) { if ($wr.Value -ge 1000) { $written = ('{0:N1} TB' -f ($wr.Value / 1000)) } else { $written = ('{0:N0} GB' -f $wr.Value) } }
        $pct = $null
        $winWear = $null; if ($r -and $null -ne $r.Wear) { $winWear = $r.Wear }
        $pct = Get-DriveLifeUsed $ls $winWear ([string]$d.BusType)
        if ($d.MediaType -eq 'HDD') { $wear = 'n/a (HDD)' }
        elseif ($null -ne $pct) {
            if ($pct -lt 1) { $wear = 'under 1 %' } else { $wear = ('{0:N0} %' -f $pct) }
            $ws = 'ok'; if ($pct -ge 90) { $ws = 'crit' } elseif ($pct -ge 70) { $ws = 'warn' }
            $gnote = 'Share of rated write endurance consumed, as reported by the drive'
            if ($written) { $gnote = ('{0} written in its lifetime. {1}' -f $written, $gnote) }
            Add-Gauge 'drives' ('{0} - rated life used' -f $name) $pct '%' 100 $ws $gnote
            if ($ws -ne 'ok') {
                Add-Finding 'drives' $ws ('{0} has used {1:N0} % of its rated write endurance' -f $name, $pct) `
                    'SSDs often outlive this figure, but past 100 % the manufacturer no longer guarantees data retention.' 'Plan a replacement and keep backups current.' ''
            }
        } else { $wear = 'not reported' }
        if ($r) {
            if ($r.Temperature) {
                $temp = ('{0} C' -f $r.Temperature)
                $driveId = ''; if ($ls.Count -gt 0) { $driveId = [string]$ls[0].Id } elseif ($d.MediaType -eq 'HDD') { $driveId = '/hdd/' }
                $lim = Get-DriveTempLimits $script:Sensors $driveId
                $ownW = $ls | Where-Object { $_.Type -eq 'Temperature' -and $_.Name -match 'Warning' -and $_.Value -gt 40 } | Select-Object -First 1
                if ($ownW) { $temp = ('{0} C (drive''s own warning limit {1:N0} C)' -f $r.Temperature, $ownW.Value) }
                if ($r.Temperature -ge ($lim[0] - 5)) {
                    Add-Finding 'drives' 'warn' ('{0} is at {1} C' -f $name, $r.Temperature) 'That is close to the temperature at which the drive starts throttling itself.' 'Check airflow over the drive; M.2 drives under a GPU often benefit from a heatsink.' ''
                }
            }
            $u = [double]$r.ReadErrorsUncorrected + [double]$r.WriteErrorsUncorrected
            $errs = [string]$u
            if ($u -gt 0) {
                Add-Finding 'drives' 'warn' ('{0} has {1} uncorrected read/write error(s)' -f $name, $u) `
                    'The drive failed to recover data on at least one operation over its lifetime.' 'Check the cable (SATA), back up, and watch whether the number rises between runs.' ''
            }
        }
        # fill from the drive's own SMART data whatever Windows left blank
        $poh = 0; if ($r -and $r.PowerOnHours) { $poh = [double]$r.PowerOnHours }
        if (-not $poh) { $ph = $ls | Where-Object { $_.Name -match 'Power On Hours' } | Select-Object -First 1; if ($ph) { $poh = [double]$ph.Value } }
        if ($poh) { $hours = ('{0:N0} h' -f $poh) }
        if (-not $temp) {
            $lt = $ls | Where-Object { $_.Type -eq 'Temperature' -and $_.Name -notmatch $script:RefSensor } | Sort-Object { $_.Name -notmatch 'Composite|^Temperature$' } | Select-Object -First 1
            if ($lt) { $temp = ('{0:N0} C' -f $lt.Value) }
        }
        $ageNote = Get-DriveAgeNote $poh
        if ($ageNote) {
            Add-Finding 'drives' 'info' ('{0} is an old drive: {1}' -f $name.Trim(), $ageNote) `
                ('It reports healthy{0}, and age alone is not a fault. But drives this old fail with less warning than a wear figure suggests.' -f $(if ($written) { ' with ' + $written + ' written' } else { '' })) `
                'Make sure anything on it that matters is backed up elsewhere.' ''
        }
        $dk = ([string]$d.SerialNumber).Trim(); if (-not $dk) { $dk = '{0}#{1}' -f $name.Trim(), $d.DeviceId }
        $script:Snap.drives[$dk] = @{ name = $name.Trim(); lifeUsed = $pct; writtenGB = $(if ($wr) { [double]$wr.Value } else { $null }); hours = $poh; uncorrected = $(if ($r) { $u } else { $null }); health = $hs }
        [void]$rows.Add(@($name, [string]$d.MediaType, [string]$d.BusType, (Format-Size $d.Size), (New-Cell $hs $hsSev ''),
                $wear, $written, $temp, $hours, $errs, [string]$d.FirmwareVersion))
    }
    Add-Table 'drives' 'Physical drives' @('Drive', 'Type', 'Bus', 'Size', 'Health', 'Life used', 'Data written', 'Temp', 'Power-on', 'Uncorrected errors', 'Firmware') $rows `
        'Read from the drive''s own SMART / NVMe health log; no surface scan or write test is performed. SSDs report life used in whole percent of their rated endurance, so a drive reads "under 1 %" until about 1 % of its rated terabytes-written is consumed (roughly 6 TB on a 600 TBW drive). "Data written" is the figure to judge that against, and needs the sensor library. Life used does not apply to hard disks.' $false
    $smart = New-Rows
    foreach ($s in ($script:Sensors | Where-Object { $_.HwType -eq 'Storage' -and $_.Valid } | Sort-Object Hw, Type, Name)) {
        $kind = [string]$s.Type; if ($s.Type -eq 'Temperature' -and $s.Name -match $script:RefSensor) { $kind = 'Limit set by the drive' }
        [void]$smart.Add(@([string]$s.Hw, [string]$s.Name, $kind, ('{0:N1}' -f $s.Value)))
    }
    Add-Table 'drives' 'SMART detail per drive' @('Drive', 'Attribute', 'Kind', 'Value') $smart 'Kinds: Level = percent, Data = gigabytes, Temperature = Celsius.' $true
    if ($disks.Count -eq 0) { Add-Finding 'drives' 'info' 'Could not enumerate physical drives' 'Get-PhysicalDisk returned nothing; run elevated.' '' '' }

    foreach ($p in (Get-Cim 'MSStorageDriver_FailurePredictStatus' 'root\wmi' '' -Optional)) {
        if ($p.PredictFailure) {
            Add-Finding 'drives' 'crit' 'A drive is predicting its own failure (SMART)' ('Instance: {0}' -f $p.InstanceName) 'Back up immediately and replace the drive.' ''
        }
    }
    foreach ($s in ($script:Sensors | Where-Object { $_.Valid -and $_.HwType -eq 'Storage' -and $_.Name -match 'Available Spare$|Remaining Life' })) {
        if ($s.Value -lt 20) {
            Add-Finding 'drives' 'warn' ('{0}: {1} is down to {2:N0} %' -f $s.Hw, $s.Name, $s.Value) '' 'Plan a replacement and keep backups current.' ''
        }
    }

    $vrows = New-Rows
    try {
        foreach ($v in @(Get-Volume -ErrorAction Stop | Where-Object { $_.DriveLetter -and $_.Size -gt 0 -and $_.DriveType -eq 'Fixed' } | Sort-Object DriveLetter)) {
            $freePct = 100 * $v.SizeRemaining / $v.Size
            $isSys = ([string]$env:SystemDrive).StartsWith([string]$v.DriveLetter)
            $sev = Get-FreeSpaceSeverity ([double]$v.SizeRemaining) ([double]$v.Size) $isSys
            Add-Gauge 'drives' ('{0}: space used' -f $v.DriveLetter) (100 - $freePct) '%' 100 $sev ('{0} free of {1}' -f (Format-Size $v.SizeRemaining), (Format-Size $v.Size))
            if ($sev -ne 'ok') {
                Add-Finding 'drives' $sev ('Volume {0}: is nearly full: {1} free ({2:N0} %)' -f $v.DriveLetter, (Format-Size $v.SizeRemaining), $freePct) `
                    $(if ($isSys) { 'This is the Windows drive. Windows needs working room for updates, the page file and temporary files; if it runs out, updates fail and the PC becomes unstable.' } else { 'This is a data drive, so Windows itself is unaffected. A nearly full SSD does slow down, because it has less spare room to reorganise itself.' }) `
                    'Free up space or move data to another drive.' ''
            }
            $vh = 'ok'; if ([string]$v.HealthStatus -ne 'Healthy') { $vh = 'warn' }
            [void]$vrows.Add(@(('{0}:' -f $v.DriveLetter), [string]$v.FileSystemLabel, [string]$v.FileSystem, (Format-Size $v.Size),
                    (Format-Size $v.SizeRemaining), (New-Cell ([string]$v.HealthStatus) $vh '')))
            if ($vh -ne 'ok') { Add-Finding 'drives' 'warn' ('File system on {0}: is flagged {1}' -f $v.DriveLetter, $v.HealthStatus) '' ('Run: chkdsk {0}: /scan' -f $v.DriveLetter) '' }
        }
    } catch {}
    Add-Table 'drives' 'Volumes' @('Volume', 'Label', 'File system', 'Size', 'Free', 'Health') $vrows '' $false

    $bad = @(Get-Ev 'System' 'disk' @(7, 52))
    $io = @(Get-Ev 'System' 'disk' @(11, 51, 153)) + @(Get-Ev 'System' 'stornvme' @(11)) + @(Get-Ev 'System' 'Ntfs' @(55))
    if ($bad.Count -gt 0) {
        Add-Finding 'drives' 'crit' ('{0} bad-block / failure-prediction event(s)' -f $bad.Count) (Get-Short $bad[0].Message 220) 'Back up now and identify which drive the event names.' ''
    }
    if ($io.Count -gt 0) {
        Add-Finding 'drives' 'warn' ('{0} disk I/O or file-system error event(s)' -f $io.Count) `
            ('Most recent {0}: {1}' -f (Format-Stamp $io[0].TimeCreated), (Get-Short $io[0].Message 200)) `
            'Often a cable, port or external USB drive rather than the disk. If it names an internal drive, reseat or replace the cable first.' ''
    }
    if ($bad.Count -eq 0 -and $io.Count -eq 0) { Add-Finding 'drives' 'ok' 'No disk error events logged' ('Nothing in the last {0} days.' -f $Days) '' '' }
}

# ---------------------------------------------------------------------- PSU
Invoke-Step 'Power supply' {
    Add-Finding 'psu' 'info' 'PSU health is inferred, not measured' `
        'Most power supplies have no data connection to the PC. This verdict is built from the voltage rails as seen by the motherboard sensor chip and from Windows power-loss events. A PSU can be marginal under heavy load and still look clean here.' '' ''

    $volts = Get-Sens 'SuperIO|Motherboard|EmbeddedController' 'Voltage'
    $rows = New-Rows
    $judged = 0
    foreach ($v in $volts) {
        $nominal = Get-RailNominal $v.Name
        $cell = New-Cell '-' '' ''
        if ($nominal -gt 0) {
            $vd = Get-SensorVerdict $v $script:Sensors
            if ($vd[0] -in 'ok', 'warn', 'crit') {
                $judged++
                $script:Snap.rails[[string]$v.Name] = [double]$v.Value
                $devLo = 100 * ($v.Min - $nominal) / $nominal; $devHi = 100 * ($v.Max - $nominal) / $nominal
                $dev = $devLo; if ([math]::Abs($devHi) -gt [math]::Abs($devLo)) { $dev = $devHi }
                $cell = New-Cell ('{0:+0.0;-0.0} % vs {1} V at worst' -f $dev, $nominal) $vd[0] ''
                if ($vd[0] -ne 'ok') {
                    $extra = ''
                    if ([math]::Abs($dev) -gt 15) { $extra = ' A deviation this large is either a severe fault or an input that is not wired the way its label suggests; the BIOS reading settles which.' }
                    Add-Finding 'psu' $vd[0] ('{0} rail reached {1:+0.0;-0.0} % from nominal (range {2:N2} to {3:N2} V)' -f $v.Name, $dev, $v.Min, $v.Max) `
                        ('The ATX specification allows +/-5 %. {0}.{1}' -f $vd[1], $extra) `
                        'Confirm in the BIOS hardware monitor or with a multimeter before replacing anything.' ''
                }
                if ($script:Watched -and $nominal -eq 12) {
                    $sag = 100 * ($v.Max - $v.Min) / $nominal
                    if ($sag -gt 3) {
                        Add-Finding 'psu' 'warn' ('12 V rail swung {0:N1} % during the watch ({1:N2} to {2:N2} V)' -f $sag, $v.Min, $v.Max) `
                            'A healthy PSU holds the 12 V rail within roughly 2-3 % between idle and full load. A larger drop when the GPU loads up is the classic sign of a tired, undersized or poorly cabled PSU.' `
                            'Check each GPU power connector has its own cable from the PSU (no daisy-chained pigtails), then consider the PSU itself.' ''
                    } else {
                        Add-Finding 'psu' 'ok' ('12 V rail held steady during the watch ({0:N2} to {1:N2} V, {2:N1} % swing)' -f $v.Min, $v.Max, $sag) ('Recorded over {0} minute(s) of your own use.' -f $WatchMinutes) '' ''
                    }
                }
            } else {
                $cell = New-Cell 'not a scaled rail reading' '' ''
            }
        }
        $reading = ('{0:N3} V' -f $v.Value); if ($script:Watched) { $reading = ('{0:N3} to {1:N3} V' -f $v.Min, $v.Max) }
        [void]$rows.Add(@([string]$v.Hw, [string]$v.Name, $reading, $cell))
    }
    if ($script:Watched) {
        $cp = Get-Sens '^Cpu$' 'Power' | Where-Object { $_.Name -match 'Package' } | Sort-Object Max -Descending | Select-Object -First 1
        $gp = Get-Sens '^Gpu' 'Power' | Sort-Object Max -Descending | Select-Object -First 1
        if ($cp) { Add-Fact 'psu' 'Peak CPU package power (watch)' ('{0:N0} W' -f $cp.Max) }
        if ($gp) { Add-Fact 'psu' 'Peak GPU power (watch)' ('{0:N0} W' -f $gp.Max) }
        if ($cp -and $gp) { Add-Fact 'psu' 'Peak CPU + GPU together' ('about {0:N0} W, plus roughly 60-100 W for the rest of the system' -f ($cp.Max + $gp.Max)) }
    } else {
        Add-Finding 'psu' 'info' 'Rails were only read at idle' 'A weak PSU usually looks fine at idle and sags when the GPU loads up.' `
            'Run Run-PCHealth-Watch.cmd and play a demanding game for 20 minutes. The tool records the rails, temperatures and power draw during your own use and reports the lowest 12 V reading.' ''
    }
    Add-Table 'psu' 'Voltage readings' @('Source', 'Sensor', 'Reading', 'Against ATX nominal') $rows `
        'Sensor-chip labels are not standardised; only readings clearly labelled as a 12 V, 5 V or 3.3 V rail are judged.' $false
    if ($judged -eq 0) {
        $why = 'No labelled voltage rails were readable.'
        if ($script:SensorNote) { $why = $script:SensorNote }
        Add-Finding 'psu' 'gap' 'Voltage rails could not be checked' $why 'The BIOS hardware monitor page shows the same rails if you want to check them by eye.' ''
    } elseif (@($script:Areas['psu'].findings | Where-Object { $_.sev -in 'warn', 'crit' }).Count -eq 0) {
        Add-Finding 'psu' 'ok' ('{0} voltage rail reading(s) within ATX tolerance' -f $judged) 'Measured at the current (light) load.' '' ''
    }

    $psuSens = @($script:Sensors | Where-Object { $_.HwType -eq 'Psu' })
    if ($psuSens.Count -gt 0) {
        $prow = New-Rows
        foreach ($s in $psuSens) { [void]$prow.Add(@([string]$s.Hw, [string]$s.Name, [string]$s.Type, ('{0:N2}' -f $s.Value))) }
        Add-Table 'psu' 'Digital PSU telemetry' @('PSU', 'Sensor', 'Type', 'Value') $prow '' $false
    }

    $kp = Get-Ev 'System' 'Microsoft-Windows-Kernel-Power' @(41)
    $dirty = Get-Ev 'System' 'EventLog' @(6008)
    Add-Fact 'psu' 'Unexpected shutdowns (event 6008)' $dirty.Count
    Add-Fact 'psu' 'Kernel-Power 41 events' $kp.Count
    if ($kp.Count -eq 0) {
        Add-Finding 'psu' 'ok' 'No unexpected power-loss events logged' ('Nothing in the last {0} days.' -f $Days) '' ''
    }
    # When there ARE power losses, the Crashes step works out what the PC was doing each time and reports
    # back here. The power supply is named as a suspect only if this report holds evidence for it.

    foreach ($b in (Get-Cim 'Win32_Battery')) {
        $full = (Get-Cim 'BatteryFullChargedCapacity' 'root\wmi' '' -Optional | Select-Object -First 1).FullChargedCapacity
        $design = (Get-Cim 'BatteryStaticData' 'root\wmi' '' -Optional | Select-Object -First 1).DesignedCapacity
        if ($full -and $design) {
            $pct = 100 * $full / $design
            $sev = 'ok'; if ($pct -lt 50) { $sev = 'crit' } elseif ($pct -lt 70) { $sev = 'warn' }
            Add-Gauge 'psu' 'Battery capacity vs design' $pct '%' 100 $sev ''
            if ($sev -ne 'ok') { Add-Finding 'psu' $sev ('Battery holds {0:N0} % of its design capacity' -f $pct) '' 'Consider a replacement battery.' '' }
        }
    }
}

# -------------------------------------------------------------- motherboard
$script:Board = $null
Invoke-Step 'Motherboard' {
    $script:Board = Get-Cim 'Win32_BaseBoard' | Select-Object -First 1
    $bios = Get-Cim 'Win32_BIOS' | Select-Object -First 1
    $cs = Get-Cim 'Win32_ComputerSystem' | Select-Object -First 1
    if ($script:Board) {
        Add-Fact 'board' 'Board' ('{0} {1}' -f $script:Board.Manufacturer, $script:Board.Product)
        Add-Fact 'board' 'Revision' $script:Board.Version
    }
    if ($cs) { Add-Fact 'board' 'System' ('{0} {1}' -f $cs.Manufacturer, $cs.Model) }
    if ($bios) {
        Add-Fact 'board' 'BIOS version' $bios.SMBIOSBIOSVersion
        $script:Snap.bios = [string]$bios.SMBIOSBIOSVersion
        Add-Fact 'board' 'BIOS date' (Format-Day $bios.ReleaseDate)
        if ($bios.ReleaseDate) {
            $ageY = ($started - [datetime]$bios.ReleaseDate).TotalDays / 365
            if ($ageY -ge 2) {
                Add-Finding 'board' 'info' ('BIOS is {0:N1} years old' -f $ageY) `
                    'Old firmware is not a fault. Updates are worth taking when they carry CPU microcode, memory compatibility or security fixes.' `
                    'Check the board''s support page (linked in the Drivers section) and read the changelog before deciding.' ''
            }
        }
    }
    try { Add-Fact 'board' 'Secure Boot' ([string](Confirm-SecureBootUEFI -ErrorAction Stop)) } catch { Add-Fact 'board' 'Secure Boot' 'Not available (legacy boot or not elevated)' }
    try { $tpm = Get-Tpm -ErrorAction Stop; Add-Fact 'board' 'TPM' ('Present: {0}, ready: {1}' -f $tpm.TpmPresent, $tpm.TpmReady) } catch {}

    $bus = @($script:Whea | Where-Object { $_.Id -eq 17 })
    $other = @($script:Whea | Where-Object { $_.Id -notin 17, 18, 19, 20, 46, 47 -and $_.Level -le 3 })
    if ($bus.Count -gt 0) {
        $sev = 'warn'; if ($bus.Count -lt 5) { $sev = 'info' }
        Add-Finding 'board' $sev ('{0} corrected bus / PCIe error(s) logged' -f $bus.Count) `
            ('WHEA event 17: a device on the PCI Express bus had a corrected error. Most recent: {0}' -f (Get-Short $bus[0].Message 200)) `
            'Reseat the GPU and M.2 drives. Riser cables and PCIe power-saving (ASPM) are the usual causes.' ''
    }
    if ($other.Count -gt 0) {
        Add-Finding 'board' 'warn' ('{0} other hardware error event(s) logged' -f $other.Count) (Get-Short $other[0].Message 220) '' ''
    }
    if ($script:Whea.Count -eq 0) { Add-Finding 'board' 'ok' 'No hardware error (WHEA) events logged' ('Nothing in the last {0} days.' -f $Days) '' '' }

    $chips = @($script:Sensors | Where-Object { $_.HwType -eq 'SuperIO' } | ForEach-Object { $_.Hw } | Select-Object -Unique)
    if ($chips.Count -gt 0) {
        Add-Fact 'board' 'Sensor chip' ($chips -join ', ')
        $erratic = @($script:Sensors | Where-Object { $_.HwType -eq 'SuperIO' -and $_.Note -match '^Erratic' })
        $detail = 'Readings from this chip are the least reliable in the report. Its inputs are wired and scaled differently on every board, unused inputs float, and it can be corrupted if another monitoring program reads it at the same moment. So this tool treats it as a low-confidence source: a chip reading on its own can raise a "verify this" warning but never a critical, and CPU, GPU and drive verdicts use each device''s own internal sensor instead.'
        if ($script:ChipDistrust.Count -gt 0) { $detail += ' Cross-check FAILED: ' + ($script:ChipDistrust -join '; ') + '. Its temperatures were discarded.' }
        elseif (@($script:Sensors | Where-Object { $_.Valid -and $_.HwType -eq 'SuperIO' -and $_.Type -eq 'Temperature' -and $_.Name -match '^CPU' }).Count -gt 0) { $detail += ' Cross-check passed: its CPU temperature agrees with the CPU''s own sensor to within 25 C.' }
        if ($erratic.Count -gt 0) { $detail += (' {0} reading(s) jumped implausibly between samples and were discarded.' -f $erratic.Count) }
        $sev = 'info'; if ($script:ChipDistrust.Count -gt 0) { $sev = 'warn' }
        Add-Finding 'board' $sev ('Board sensor chip ({0}) is treated as a low-confidence source' -f ($chips -join ', ')) $detail 'The BIOS hardware monitor is the reference for anything this chip reports.' ''
    }
    if ($script:Monitors.Count -gt 0) {
        Add-Finding 'board' 'info' 'Other hardware-monitoring software was running during the scan' `
            ('Running: {0}. Two programs reading the board''s sensor chip at once is a known cause of garbage values, because the chip is read through a shared register that one program can change while the other is mid-read.' -f ($script:Monitors -join ', ')) `
            'For the cleanest readings, close these (including their tray icons and services) and re-run.' ''
    }
    $boardT = Get-Sens 'SuperIO|Motherboard|EmbeddedController' 'Temperature'
    foreach ($t in ($boardT | Where-Object { @(Get-SensorSpec $_ $script:Sensors).Count -gt 0 } | Sort-Object Max -Descending | Select-Object -First 4)) {
        $vd = Get-SensorVerdict $t $script:Sensors
        Add-Gauge 'board' ('{0} temperature' -f $t.Name) $t.Max 'C' 110 $(if ($vd[0] -in 'warn', 'crit') { $vd[0] } else { 'ok' }) ('Expected {0}. Read from {1}' -f $vd[3], $t.Hw)
    }
    $mystery = @($boardT | Where-Object { @(Get-SensorSpec $_ $script:Sensors).Count -eq 0 -and $_.Max -ge 80 })
    if ($mystery.Count -gt 0) {
        Add-Finding 'board' 'info' ('{0} unidentified sensor input(s) read above 80 C and were not judged' -f $mystery.Count) `
            ('{0}. These are numbered inputs on the board''s sensor chip ({1}) that the sensor library cannot name, because board makers do not publish which input is wired to what. The chip has more inputs than most boards use, and an unconnected input floats at a meaningless, often high and steady, value. That is the likely explanation here, but it cannot be proven from software.' -f (($mystery | ForEach-Object { '{0} = {1:N0} C' -f $_.Name, $_.Max }) -join ', '), $mystery[0].Hw) `
            'Open the BIOS hardware monitor (or the board maker''s utility) and see whether any real temperature there matches these numbers. If none does, they are unconnected inputs and can be ignored.' ''
    }
    $srows = New-Rows
    $flagged = New-Rows
    foreach ($s in ($script:Sensors | Sort-Object HwType, Hw, Type, Name)) {
        $vd = Get-SensorVerdict $s $script:Sensors
        $u = Get-SensorUnit $s.Type
        $cellV = New-Cell $vd[1] $vd[0] ''
        $range = $vd[3]; if (-not $range) { $range = '-' }
        $row = @([string]$s.HwType, [string]$s.Hw, [string]$s.Type, [string]$s.Name, ('{0:N2}{1}' -f $s.Value, $u))
        if ($script:Watched) { $row += ('{0:N2} to {1:N2}{2}' -f $s.Min, $s.Max, $u) }
        $row += $range; $row += $cellV
        [void]$srows.Add($row)
        if ($vd[0] -in 'warn', 'crit') {
            [void]$flagged.Add(@([string]$s.Hw, [string]$s.Name, ('{0:N2}{1}' -f $s.Value, $u), $range, $cellV))
            if ($vd[2]) { Add-Finding 'board' $vd[0] ('{0} / {1}: {2} (expected {3})' -f $s.Hw, $s.Name, $vd[1], $range) $vd[2] '' '' }
        }
    }
    $cols = @('Kind', 'Hardware', 'Type', 'Sensor', 'Now'); if ($script:Watched) { $cols += 'Seen during watch' }; $cols += 'Expected range'; $cols += 'Assessment'
    Add-Table 'board' 'Sensors outside their expected range' @('Hardware', 'Sensor', 'Now', 'Expected range', 'Assessment') $flagged 'Expected ranges are general guidance for desktop parts; a board maker''s own limits take precedence.' $false
    Add-Table 'board' 'All sensor readings' $cols $srows `
        ('Source: {0}. "Expected range" is where that kind of component should sit; "Now" is compared against it. A dash means the sensor has no meaningful range (clock speeds, loads, counters) or could not be identified.' -f $script:SensorSource) $true
    if ($script:Sensors.Count -gt 0 -and -not $script:LowLevelBroken -and $flagged.Count -eq 0) {
        Add-Finding 'board' 'ok' 'No sensor reading is outside its expected range' $(if ($script:Watched) { 'Checked across the whole {0}-minute watch.' -f $WatchMinutes } else { 'Single snapshot at the current load.' }) '' ''
    }

    if ($script:LowLevelBroken) {
        $pawn = Get-Service -Name 'PawnIO' -ErrorAction SilentlyContinue
        Add-Finding 'board' 'gap' 'CPU and motherboard sensor readings are invalid and were ignored' `
            ('The sensor library listed the sensors but every value is a placeholder (0 C, 0 W, an identical 1.55 V on every core). That happens when it has no low-level access to the CPU and the board''s sensor chip, so temperatures, fan speeds and the 12 V / 5 V / 3.3 V rails could not be assessed. PawnIO driver installed: {0}.' -f $(if ($pawn) { 'yes' } else { 'no' })) `
            'Install the PawnIO driver (pawnio.eu, or: winget install namazso.PawnIO), restart, and re-run. If it is already installed, Windows Security > Core isolation > Memory integrity or an anti-cheat service may be blocking it.' 'https://pawnio.eu/'
    } elseif ($script:Sensors.Count -gt 0 -and (Get-Sens 'SuperIO' 'Voltage').Count -eq 0 -and (Get-Sens '^Cpu$' 'Temperature').Count -eq 0) {
        Add-Finding 'board' 'gap' 'CPU and motherboard sensors were not readable' `
            'LibreHardwareMonitor returned data for some devices but not the CPU or the board sensor chip. Recent LibreHardwareMonitor releases need the separate PawnIO driver for low-level access, and some anti-cheat or core-isolation settings block it.' `
            'Install PawnIO from pawnio.eu and re-run if you want temperatures and voltage rails.' 'https://pawnio.eu/'
    } elseif ($script:Sensors.Count -eq 0 -and $script:SensorNote) {
        Add-Finding 'board' 'gap' 'No sensor data in this report' $script:SensorNote '' ''
    }
}

# ------------------------------------------------------------------ Windows
$script:UpdateErrors = @{
    '0x80073D02' = 'The package was in use at the time, so Windows could not replace it.'
    '0x80073CF9' = 'The package install failed, often through low disk space or a damaged Store cache.'
    '0x80073CF3' = 'A dependency or conflict check failed for the package.'
    '0x80073D06' = 'A newer version of the package is already installed.'
    '0x80070005' = 'Access was denied, typically by security software or a permissions problem.'
    '0x80070643' = 'The installer itself reported a fatal error.'
    '0x800F0922' = 'The update could not complete; usually the system reserved partition is full or a VPN blocked the connection.'
    '0x80240017' = 'The update was not applicable to this system.'
    '0x8024200B' = 'The installer failed; frequent with driver updates for a device that has changed.'
    '0x80246007' = 'The download did not complete.'
    '0x80240034' = 'The update failed to download.'
    '0x80240022' = 'The update could not be processed for this user.'
    '0x8024402C' = 'Windows Update could not reach the update servers (proxy or DNS problem).'
    '0x80070002' = 'Files the update expected were missing; usually a damaged download cache.'
    '0x800F081F' = 'Source files were missing from the component store.'
}
$script:StorePackages = [ordered]@{
    'WindowsAppRuntime' = 'The Windows App SDK runtime: a shared framework from Microsoft that modern Windows apps (those built with WinUI 3) load instead of each shipping its own copy. It has no window of its own; you only notice it if an app that needs it will not start.'
    'VCLibs' = 'The Microsoft Visual C++ runtime for Store apps: shared code many apps depend on.'
    'UI\.Xaml' = 'The WinUI 2 interface framework that many Store apps depend on.'
    'NET\.Native' = 'The .NET Native runtime that older Store apps depend on.'
    'DesktopAppInstaller' = 'App Installer, which provides the winget package manager.'
    'GamingServices' = 'Xbox Gaming Services, used by the Xbox app and Game Pass titles.'
    'WebExperience' = 'The Windows Widgets board.'
    'WindowsStore' = 'The Microsoft Store app itself.'
    'HPPrinterControl' = 'HP Smart, HP''s app for setting up printers and scanning.'
    'XboxApp|GamingApp' = 'The Xbox app.'
    'WindowsTerminal' = 'Windows Terminal, the command-line window.'
    'NVIDIAControlPanel' = 'NVIDIA Control Panel, the settings app for NVIDIA graphics cards.'
    'RealtekAudioControl|RealtekAudioConsole' = 'Realtek Audio Console, the settings app for the motherboard''s sound.'
}
Invoke-Step 'Driver inventory' {
    $script:AllDrv = @(Get-Cim 'Win32_PnPSignedDriver' | Where-Object { $_.DriverVersion -and $_.DeviceName })
}
$script:StoreDamaged = $false
# When the store is reported damaged, read Windows' own repair log to say WHAT is damaged and whether
# earlier repairs actually fixed it. Only the tail of the log is read; it can be tens of megabytes.
function Add-StoreRepairEvidence {
    try {
        $path = Join-Path $env:SystemRoot 'Logs\CBS\CBS.log'
        if (-not (Test-Path $path)) { Add-Finding 'windows' 'gap' 'Windows'' repair log was not found' 'CBS.log is where each scan and repair records what it found.' '' ''; return }
        $fs = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $max = 40MB
            if ($fs.Length -gt $max) { [void]$fs.Seek(-1 * $max, [IO.SeekOrigin]::End) }
            $sr = New-Object IO.StreamReader($fs)
            $lines = $sr.ReadToEnd() -split "`r?`n"
        } finally { $fs.Dispose() }
        $sessions = @(Get-CbsRepairSessions $lines)
        $v = Get-CbsRepairVerdict $sessions
        if (-not $v) {
            Add-Finding 'windows' 'gap' 'Windows'' repair log holds no completed scan or repair record' 'The log has probably been rotated since the last repair, so it cannot show what was found or fixed.' 'Run DISM /Online /Cleanup-Image /RestoreHealth, then re-run this report straight afterwards so the log still holds the record.' ''
            return
        }
        Add-Finding 'windows' $v.Sev $v.Title $v.Detail $v.Action ''
        $rows = New-Rows
        foreach ($x in ($sessions | Where-Object { $_.Complete } | Select-Object -Last 8)) {
            [void]$rows.Add(@([string]$x.When, [string]$x.Operation, [string]$x.Detected, [string]$x.Repaired, (Get-Short (($x.Items | Select-Object -First 4) -join '; ') 300), (($x.Failed | Select-Object -Unique) -join '; ')))
        }
        Add-Table 'windows' 'Component store scans and repairs recorded by Windows' @('When', 'Operation', 'Damaged items found', 'Repaired', 'Components named', 'Repair failures') $rows 'From C:\Windows\Logs\CBS\CBS.log. "Detect only" is a scan; "Detect and Repair" is the RestoreHealth command.' $false
    } catch { [void]$script:Errors.Add('Windows repair log could not be read: ' + $_.Exception.Message) }
}
Invoke-Step 'Windows installation' {
    $os = Get-Cim 'Win32_OperatingSystem' | Select-Object -First 1
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    if ($os) {
        Add-Fact 'windows' 'Edition' $os.Caption
        Add-Fact 'windows' 'Version' ('{0} (build {1}.{2})' -f $cv.DisplayVersion, $os.BuildNumber, $cv.UBR)
        Add-Fact 'windows' 'Installed' (Format-Day $os.InstallDate)
        $script:Snap.build = ('{0}.{1}' -f $os.BuildNumber, $cv.UBR)
        $ins = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\WindowsSelfHost\Applicability' -ErrorAction SilentlyContinue
        if ($ins -and $ins.BranchName) { Add-Fact 'windows' 'Windows Insider channel' ('{0} (pre-release builds)' -f $ins.BranchName) }
        Add-Fact 'windows' 'Last boot' (Format-Stamp $os.LastBootUpTime)
        $up = ($started - $os.LastBootUpTime).TotalDays
        if ($up -ge 14) {
            Add-Finding 'windows' 'info' ('Windows has been up for {0:N0} days' -f $up) 'With Fast Startup enabled, "Shut down" does not reset the kernel, so uptime keeps counting.' 'Use Restart occasionally so updates and driver changes fully apply.' ''
        }
        if ([int]$os.BuildNumber -lt 22000) {
            Add-Finding 'windows' 'warn' 'Windows 10 is past end of support' 'Windows 10 stopped receiving free security updates on 14 October 2025 unless the PC is enrolled in Extended Security Updates.' 'Enrol in ESU or move to Windows 11.' ''
        }
    }
    $pending = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $pending += 'component servicing' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $pending += 'Windows Update' }
    if ($pending.Count -gt 0) {
        Add-Finding 'windows' 'warn' 'A restart is pending' ('Waiting on: {0}. Until then, updates are half-applied.' -f ($pending -join ', ')) 'Restart the PC.' ''
    }

    if ($IsAdmin) {
        try {
            $img = Repair-WindowsImage -Online -CheckHealth -ErrorAction Stop
            $state = [string]$img.ImageHealthState
            Add-Fact 'windows' 'Component store flag' $state
            if ($state -ne 'Healthy' -and -not $DeepScan) {     # with -DeepScan the full scan below reports it once
                $sev = 'warn'; if ($state -eq 'NonRepairable') { $sev = 'crit' }
                Add-Finding 'windows' $sev ('Component store is flagged {0}' -f $state) 'Windows has previously detected corruption in its own servicing store.' 'Run: DISM /Online /Cleanup-Image /RestoreHealth   then: sfc /scannow' ''
            }
        } catch { [void]$script:Errors.Add('DISM CheckHealth: ' + $_.Exception.Message) }
    }
    if ($DeepScan -and $IsAdmin) {
        Write-Host '      deep scan: DISM ScanHealth (several minutes)...'
        try {
            $scan = Repair-WindowsImage -Online -ScanHealth -ErrorAction Stop
            $state = [string]$scan.ImageHealthState
            $sev = 'ok'; if ($state -eq 'Repairable') { $sev = 'warn' } elseif ($state -ne 'Healthy') { $sev = 'crit' }
            $script:StoreDamaged = ($sev -ne 'ok')
            Add-Finding 'windows' $sev $(if ($sev -eq 'ok') { 'Windows component store is healthy (full scan)' } else { 'Windows component store is damaged ({0})' -f $state }) `
                $(if ($sev -eq 'ok') { 'Full read-only DISM scan of the store Windows uses to install updates and repair itself.' } else { 'Windows keeps a private store of spare copies of its own files, used to install updates and to repair itself. A full scan found damage in that store. The files Windows is running from are checked separately by SFC (see its result). Left alone, future updates may fail and self-repair may not work.' }) `
                $(if ($sev -ne 'ok') { 'From an administrator prompt run: DISM /Online /Cleanup-Image /RestoreHealth   It downloads fresh copies from Microsoft and takes 10 to 20 minutes. Then restart.' } else { '' }) ''
        } catch { Add-Finding 'windows' 'info' 'DISM ScanHealth could not complete' $_.Exception.Message '' '' }
        if ($script:StoreDamaged) { Add-StoreRepairEvidence }
        Write-Host '      deep scan: SFC /verifyonly (several minutes)...'
        & "$env:SystemRoot\System32\sfc.exe" /verifyonly | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Add-Finding 'windows' 'ok' 'SFC found no integrity violations' 'System File Checker verified protected system files (read-only).' '' ''
        } else {
            Add-Finding 'windows' 'warn' ('SFC reported problems or could not finish (exit code {0})' -f $LASTEXITCODE) 'Details are in C:\Windows\Logs\CBS\CBS.log (lines tagged [SR]).' 'Run: sfc /scannow' ''
        }
    } else {
        Add-Finding 'windows' 'info' 'System file integrity was not deep-scanned' 'This run only read the existing corruption flag, which is fast but only reflects problems Windows has already noticed.' 'Re-run with -DeepScan (Run-PCHealth-DeepScan.cmd) for a full read-only DISM and SFC verification.' ''
    }

    try {
        $hf = @(Get-HotFix -ErrorAction Stop | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending)
        if ($hf.Count -gt 0) {
            Add-Fact 'windows' 'Last update installed' ('{0} ({1})' -f (Format-Day $hf[0].InstalledOn), $hf[0].HotFixID)
            $age = ($started - $hf[0].InstalledOn).TotalDays
            if ($age -gt 45) {
                Add-Finding 'windows' 'warn' ('No Windows update installed for {0:N0} days' -f $age) 'Security updates ship monthly.' 'Open Settings > Windows Update and check for updates.' ''
            }
        }
    } catch {}

    if (-not $Offline) {
        Write-Host '      querying Windows Update (can take a minute)...'
        try {
            $session = New-Object -ComObject Microsoft.Update.Session
            $searcher = $session.CreateUpdateSearcher()
            $res = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software' or IsInstalled=0 and IsHidden=0 and Type='Driver'")
            $script:WuSearched = $true
            $all = @(); foreach ($u in $res.Updates) { $all += $u }
            $script:WuPending = @($all | Where-Object { $_.Type -eq 2 })
            $swAll = @($all | Where-Object { $_.Type -ne 2 })
            $sw = @($swAll | Where-Object { -not (Test-RoutineUpdate ([string]$_.Title)) })
            if ($swAll.Count -gt $sw.Count) { Add-Fact 'windows' 'Antivirus definition updates queued' ('{0} (routine; they install themselves)' -f ($swAll.Count - $sw.Count)) }
            if ($sw.Count -gt 0) {
                Add-Finding 'windows' 'warn' ('{0} Windows update(s) waiting to install' -f $sw.Count) '' 'Open Settings > Windows Update.' ''
                $urow = New-Rows
                foreach ($u in $sw) { [void]$urow.Add(@((Get-Short ([string]$u.Title) 140), [string]$u.MsrcSeverity)) }
                Add-Table 'windows' 'Pending updates' @('Update', 'Severity') $urow '' $false
            } else {
                Add-Finding 'windows' 'ok' 'No Windows updates pending' '' '' ''
            }
            $n = $searcher.GetTotalHistoryCount()
            if ($n -gt 0) {
                $histAll = @($searcher.QueryHistory(0, [math]::Min(1000, $n)))
                $script:WuDriverTitles = @($histAll | Where-Object { $_.ResultCode -eq 2 } | ForEach-Object { [string]$_.Title })
                $hist = @($histAll | Where-Object { $_.Date -ge $Since })
                # Triage failures: ignore ones that later succeeded, and separate driver updates for hardware that is gone.
                $failed = @(); $stale = @(); $fixed = 0
                $vendors = 'NVIDIA', 'Advanced Micro Devices|AMD', 'Intel', 'Realtek', 'Qualcomm', 'MediaTek', 'Broadcom', 'Logitech', 'Corsair', 'Synaptics', 'Samsung'
                foreach ($f in @($hist | Where-Object { $_.ResultCode -eq 4 })) {
                    $title = [string]$f.Title
                    if (@($hist | Where-Object { $_.Title -eq $title -and $_.ResultCode -eq 2 -and $_.Date -gt $f.Date }).Count -gt 0) { $fixed++; continue }
                    $vend = $vendors | Where-Object { $title -match ('^({0})\b' -f $_) } | Select-Object -First 1
                    if ($vend -and $title -notmatch 'KB\d{6,}') {
                        if ($title -match ' - Display - |Display Driver') {
                            $present = @($script:Gpus | Where-Object { $_.Name -match $vend -or ($vend -match 'AMD' -and $_.Name -match 'Radeon') }).Count -gt 0
                        } else {
                            $present = @($script:AllDrv | Where-Object { ('{0} {1} {2}' -f $_.Manufacturer, $_.DriverProviderName, $_.DeviceName) -match $vend }).Count -gt 0
                        }
                        if (-not $present) { $stale += $f; continue }
                    }
                    $failed += $f
                }
                $frow = New-Rows
                foreach ($g in ($failed | Group-Object { [string]$_.Title })) {
                    $title = $g.Name
                    $f = $g.Group | Sort-Object Date -Descending | Select-Object -First 1
                    $hr = ''; try { $hr = '0x{0:X8}' -f [int]$f.HResult } catch {}
                    $errTxt = $script:UpdateErrors[$hr]; if (-not $errTxt) { $errTxt = 'No built-in explanation for this code; search for it on Microsoft Learn.' }
                    $sev = 'warn'; $what = 'An update delivered through Windows Update.'; $state = ''; $link = ''
                    $fix = 'Settings > Windows Update > Check for updates to retry. If it fails repeatedly, run the Windows Update troubleshooter (Settings > System > Troubleshoot > Other troubleshooters).'
                    if ($title -match '^9[A-Z0-9]{11}-(.+)$') {
                        $pkg = $Matches[1]
                        $what = 'A Microsoft Store package, not part of Windows itself. DISM and SFC do not cover Store packages, so a clean deep scan says nothing about it.'
                        foreach ($k in $script:StorePackages.Keys) { if ($pkg -match $k) { $what = $script:StorePackages[$k] + ' It is a Microsoft Store package, so DISM and SFC do not cover it and a clean deep scan says nothing about it.'; break } }
                        $inst = @(); $users = @()
                        try {
                            if ($null -eq $script:AppxAll) { $script:AppxAll = @(Get-AppxPackage -AllUsers -ErrorAction Stop) }
                            $inst = @($script:AppxAll | Where-Object { $_.Name -like ($pkg + '*') })
                            $users = @($script:AppxAll | Where-Object { @($_.Dependencies | Where-Object { $_.Name -like ($pkg + '*') }).Count -gt 0 } | ForEach-Object { $_.Name } | Select-Object -Unique)
                        } catch {}
                        if ($inst.Count -gt 0) {
                            $state = 'Installed now: version ' + ((($inst | ForEach-Object { [string]$_.Version } | Select-Object -Unique)) -join ', ') + '.'
                            if ($g.Count -lt 3) { $sev = 'info'; $state += ' A working copy is present, so nothing is broken; one update attempt failed and the Store retries on its own.' }
                        } else { $state = 'Not currently installed.' }
                        if ($users.Count -gt 0) { $state += ' Apps that depend on it: ' + (($users | Select-Object -First 8) -join ', ') + '.' }
                        $fix = 'Open Microsoft Store > Downloads (or Library) > Get updates. If it fails again, restart the PC first so no app is holding the package open, then retry. Last resort: run wsreset.exe to clear the Store cache.'
                    } elseif ($title -match '(KB\d{6,})') {
                        $what = 'A Windows update (' + $Matches[1] + '). The linked Microsoft article describes what it contains.'
                        $link = 'https://support.microsoft.com/help/' + ($Matches[1] -replace 'KB', '')
                        $fix += ' If it still fails: DISM /Online /Cleanup-Image /RestoreHealth, restart, retry.'
                    } elseif ($title -match 'Security Intelligence|Defender') {
                        $what = 'A Microsoft Defender definition update. These are replaced several times a day, so a single failure is superseded by the next one.'
                        $sev = 'info'
                    } elseif ($title -match ' - \w[\w ]* - |Driver') {
                        $what = 'A driver delivered by Windows Update for hardware that is present.'
                        $fix = 'Install the device maker''s own driver instead (see the Drivers section); that normally stops Windows Update offering this one.'
                    }
                    $times = ('{0} time(s), last {1}' -f $g.Count, (Format-Stamp $f.Date))
                    Add-Finding 'windows' $sev ('Update failed to install: {0}' -f (Get-Short $title 90)) `
                        ('{0} Error {1}: {2} {3} Failed {4}.' -f $what, $hr, $errTxt, $state, $times) $fix $link
                    [void]$frow.Add(@((Get-Short $title 90), $what, ('{0} - {1}' -f $hr, $errTxt), $times, $state))
                }
                Add-Table 'windows' 'Failed updates explained' @('Update', 'What it is', 'Error', 'How often', 'State now') $frow '' $false
                if ($stale.Count -gt 0) {
                    Add-Finding 'windows' 'info' ('{0} failed driver update(s) were for hardware that is no longer installed' -f $stale.Count) `
                        ('{0}. The failure itself does not matter because the device is gone. Windows Update tried it because driver packages or software for the old device are still on the system.' -f (($stale | ForEach-Object { Get-Short ([string]$_.Title) 80 } | Select-Object -Unique) -join '; ')) `
                        'Nothing needs fixing in Windows. To stop it being offered again, remove the leftover software and driver packages; the Drivers section lists them.' ''
                }
                if ($fixed -gt 0) { Add-Fact 'windows' 'Update failures that later succeeded' $fixed }
                $script:WuHistory = $hist
            }
        } catch { [void]$script:Errors.Add('Windows Update search: ' + $_.Exception.Message) }
    }

    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        Add-Fact 'windows' 'Defender real-time protection' ([string]$mp.RealTimeProtectionEnabled)
        Add-Fact 'windows' 'Defender signature age' ('{0} day(s)' -f $mp.AntivirusSignatureAge)
        if ($mp.AntivirusEnabled -and -not $mp.RealTimeProtectionEnabled) { Add-Finding 'windows' 'warn' 'Defender real-time protection is off' '' 'Turn it back on in Windows Security unless another antivirus is in charge.' '' }
        if ($mp.AntivirusEnabled -and $mp.AntivirusSignatureAge -gt 7) { Add-Finding 'windows' 'warn' ('Defender signatures are {0} days old' -f $mp.AntivirusSignatureAge) '' 'Check for updates in Windows Security.' '' }
    } catch {
        $av = @(Get-Cim 'AntiVirusProduct' 'root\SecurityCenter2' '' -Optional | ForEach-Object { $_.displayName })
        if ($av.Count -gt 0) { Add-Fact 'windows' 'Antivirus' ($av -join ', ') }
    }

    $svc = @(Get-Cim 'Win32_Service' '' "StartMode='Auto' AND State<>'Running'" | Where-Object { $_.ExitCode -ne 0 -and $_.ExitCode -ne 1077 })
    if ($svc.Count -gt 0) {
        $srow = New-Rows
        foreach ($s in $svc) { [void]$srow.Add(@([string]$s.DisplayName, [string]$s.Name, [string]$s.State, [string]$s.ExitCode)) }
        Add-Table 'windows' 'Automatic services that stopped with an error' @('Service', 'Name', 'State', 'Exit code') $srow '' $false
        Add-Finding 'windows' 'info' ('{0} automatic service(s) are stopped with an error code' -f $svc.Count) 'Listed below. Some of these are harmless leftovers from uninstalled software.' '' ''
    }
}

# ----------------------------------------------------------- crash analysis
function Test-Near($ev, [datetime]$from, [datetime]$to) { return @($ev | Where-Object { $_.TimeCreated -ge $from -and $_.TimeCreated -le $to }) }

Invoke-Step 'Crash analysis' {
    $cc = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -ErrorAction SilentlyContinue
    $modes = @{ 0 = 'None (disabled)'; 1 = 'Complete'; 2 = 'Kernel'; 3 = 'Small (minidump)'; 7 = 'Automatic' }
    if ($cc) {
        Add-Fact 'crash' 'Crash dump setting' $modes[[int]$cc.CrashDumpEnabled]
        if ([int]$cc.CrashDumpEnabled -eq 0) {
            Add-Finding 'crash' 'warn' 'Crash dumps are disabled' 'Windows is set to write no dump on a blue screen, so the driver at fault can never be identified afterwards.' `
                'System Properties > Advanced > Startup and Recovery > Write debugging information: choose "Automatic memory dump" or "Small memory dump".' ''
        }
    }
    $kp = Get-Ev 'System' 'Microsoft-Windows-Kernel-Power' @(41)
    $bc = Get-Ev 'System' 'Microsoft-Windows-WER-SystemErrorReporting' @(1001)
    $back = $Since.AddDays(-60)      # the session that ended in the oldest event may have begun before the window
    $boots = Get-Ev 'System' 'Microsoft-Windows-Kernel-General' @(12) $back
    $sleeps = @(Get-Ev 'System' 'Microsoft-Windows-Kernel-Power' @(42, 506) $back | ForEach-Object { $_.TimeCreated })
    $wakes = @(@(Get-Ev 'System' 'Microsoft-Windows-Kernel-Power' @(107, 507) $back) + @(Get-Ev 'System' 'Microsoft-Windows-Power-Troubleshooter' @(1) $back) | ForEach-Object { $_.TimeCreated })
    $shutdowns = @(@(Get-Ev 'System' 'User32' @(1074) $back) + @(Get-Ev 'System' 'Microsoft-Windows-Kernel-Power' @(109) $back) | ForEach-Object { $_.TimeCreated })
    $tdr = Get-Ev 'System' 'Display' @(4101)
    $diskEv = @(Get-Ev 'System' 'disk' @(7, 11, 51, 52, 153)) + @(Get-Ev 'System' 'stornvme' @(11))
    $throttle = Get-Ev 'System' 'Microsoft-Windows-Kernel-Processor-Power' @(37)

    $rows = New-Rows
    $codes = @(); $areasHit = @(); $usedBc = @{}; $states = @(); $nHw = 0; $nGpu = 0
    foreach ($e in ($kp | Sort-Object TimeCreated)) {
        $T = $e.TimeCreated
        $code = 0; try { $code = [int64]$e.Properties[0].Value } catch {}
        # Event 41 is written at the NEXT boot. Find the last thing logged before that boot to date the event itself.
        $boot = $boots | Where-Object { $_.TimeCreated -le $T -and $_.TimeCreated -ge $T.AddMinutes(-10) } | Sort-Object TimeCreated | Select-Object -First 1
        $bootStart = $T.AddMinutes(-1); if ($boot) { $bootStart = $boot.TimeCreated }
        $alive = $bootStart
        try { $last = Get-WinEvent -FilterHashtable @{ LogName = 'System'; EndTime = $bootStart.AddSeconds(-2) } -MaxEvents 1 -ErrorAction Stop; if ($last) { $alive = $last.TimeCreated } } catch {}
        # the boot that began the session which ended here
        $session = $boots | Where-Object { $_.TimeCreated -le $alive -and $_.TimeCreated -lt $bootStart } | Sort-Object TimeCreated -Descending | Select-Object -First 1
        $sessionStart = $null; $ranFor = 'not known'
        if ($session) { $sessionStart = $session.TimeCreated; $ranFor = Format-Duration ($alive - $sessionStart).TotalMinutes }
        $offFor = Format-Duration ($bootStart - $alive).TotalMinutes

        $dumpEv = Select-NearestRecord $bc $T $usedBc 2 30
        $dump = ''
        if ($dumpEv) {
            $usedBc[$dumpEv.RecordId] = 1
            if ($dumpEv.Message -match '([A-Za-z]:\\[^\s"]+\.dmp)') { $dump = [IO.Path]::GetFileName($Matches[1]) }
            if ($code -eq 0 -and $dumpEv.Message -match '0x([0-9a-fA-F]{8})') { $code = [Convert]::ToInt64($Matches[1], 16) }
        }
        $w = Test-Near $script:Whea $alive.AddMinutes(-15) $T.AddMinutes(10)
        $g = Test-Near $tdr $alive.AddMinutes(-30) $alive.AddMinutes(1)
        $d = Test-Near $diskEv $alive.AddMinutes(-30) $alive.AddMinutes(1)
        $th = Test-Near $throttle $alive.AddMinutes(-30) $alive.AddMinutes(1)
        $ev = @()
        if ($w.Count -gt 0) { $ev += ('{0} hardware error (WHEA) record(s)' -f $w.Count) }
        if ($g.Count -gt 0) { $ev += ('{0} graphics driver reset(s) in the 30 min before' -f $g.Count) }
        if ($d.Count -gt 0) { $ev += ('{0} disk error(s) in the 30 min before' -f $d.Count) }
        if ($th.Count -gt 0) { $ev += 'CPU was being throttled by firmware beforehand' }
        if ($ev.Count -eq 0) { $ev += 'No related warnings logged beforehand' }

        if ($code -ne 0) {
            $info = Resolve-Bugcheck $code
            $type = New-Cell 'Blue screen' 'crit' ''
            $codeTxt = ('0x{0:X} {1}' -f $code, $info[0]); $suspect = $info[1]; $cause = $info[2]
            if ($w.Count -gt 0 -and $suspect -notmatch 'Hardware|CPU') { $cause += ' Hardware error records were logged around this crash, which shifts suspicion toward hardware.' }
            $codes += $code; $areasHit += $suspect
        } else {
            # No crash record. Say what the PC was doing, and name a suspect only where an event supports it.
            $state = Get-PowerLossState $alive $sessionStart $sleeps $wakes $shutdowns
            $states += $state
            $pd = Get-PowerLossDescription $state
            $running = $state -in 'in-use', 'starting-up'
            $type = New-Cell $pd[0] $(if ($running) { 'warn' } else { 'info' }) ''
            $codeTxt = 'none recorded'; $suspect = 'None indicated'; $cause = $pd[1]
            if ($running) {
                if ($w.Count -gt 0) { $nHw++; $suspect = 'CPU, memory or motherboard'; $cause += ' Here the CPU also logged a hardware error, so the machine most likely reset itself on a fatal fault.' }
                elseif ($g.Count -gt 0) { $nGpu++; $suspect = 'Graphics card or its driver'; $cause += ' Here the graphics driver was resetting shortly beforehand.' }
                elseif ($d.Count -gt 0) { $suspect = 'Storage'; $cause += ' Here disk errors were logged shortly beforehand; if the system drive stalls, Windows cannot write a crash record.' }
                elseif ($th.Count -gt 0) { $suspect = 'Cooling'; $cause += ' Here the CPU was being throttled beforehand, which is consistent with overheating.' }
            }
        }
        [void]$rows.Add(@((Format-Stamp $alive), $ranFor, $offFor, $type, $codeTxt, $suspect, $cause, ($ev -join '; '), $dump))
        $script:Snap.incidents += ('{0}|{1}' -f (Format-Stamp $alive), $type.t)
    }
    foreach ($b in ($bc | Where-Object { $null -ne $_ -and -not $usedBc.ContainsKey($_.RecordId) })) {
        $code = 0; if ($b.Message -match '0x([0-9a-fA-F]{8})') { $code = [Convert]::ToInt64($Matches[1], 16) }
        $info = Resolve-Bugcheck $code
        $codes += $code; $areasHit += $info[1]
        $script:Snap.incidents += ('{0}|Blue screen' -f (Format-Stamp $b.TimeCreated))
        [void]$rows.Add(@((Format-Stamp $b.TimeCreated), '', '', (New-Cell 'Blue screen' 'crit' ''), ('0x{0:X} {1}' -f $code, $info[0]), $info[1], $info[2], '', ''))
    }
    $script:Snap.tdr = @($tdr | ForEach-Object { '{0}|Graphics driver reset' -f (Format-Stamp $_.TimeCreated) })
    Add-Table 'crash' 'Timeline of crashes and unexpected power losses' @('Last sign of life', 'Had been running', 'Off for', 'What happened', 'Bugcheck code', 'Suspect', 'What it means', 'Evidence around it', 'Dump file') $rows `
        '"Last sign of life" is the last event Windows logged before it stopped, accurate to a few minutes. "Off for" runs from then until the PC was next started, so it includes any time spent asleep. "Suspect" names a component only where a logged event supports it; "None indicated" means the logs do not point anywhere.' $false

    if ($rows.Count -eq 0) {
        Add-Finding 'crash' 'ok' 'No system crashes or unexpected shutdowns' ('Nothing in the last {0} days. Re-run with -Days 90 to look further back.' -f $Days) '' ''
    }
    if ($codes.Count -gt 0) {
        $sev = 'warn'; if ($codes.Count -ge 3) { $sev = 'crit' }
        $distinct = @($codes | Select-Object -Unique)
        $top = ($areasHit | Group-Object | Sort-Object Count -Descending | Select-Object -First 1).Name
        if ($distinct.Count -eq 1) {
            $pattern = 'Every blue screen has the same bugcheck code, which points at a single repeatable cause rather than general instability.'
            $act = 'Follow the "What it means" column, and get the faulting driver name from the dump (see below).'
        } else {
            $pattern = 'The blue screens do not share one code. A different failure each time is the signature of unstable hardware (memory, CPU settings, power) rather than one bad driver, because a bad driver tends to fail the same way.'
            $act = 'Return the BIOS to defaults (XMP/EXPO, PBO, Curve Optimizer and overclocks off) and see whether the crashes stop. If they do, re-enable one setting at a time.'
        }
        Add-Finding 'crash' $sev ('{0} blue-screen crash(es); most often pointing at: {1}' -f $codes.Count, $top) $pattern $act ''
    }
    if ($states.Count -gt 0) {
        $railEvidence = @($script:Areas['psu'].findings | Where-Object { $_.sev -in 'warn', 'crit' -and $_.title -match 'rail' }).Count -gt 0
        $railsReadable = @(Get-Sens 'SuperIO|Motherboard|EmbeddedController' 'Voltage' | Where-Object { (Get-RailNominal $_.Name) -gt 0 }).Count -gt 0
        $sum = Get-PowerLossSummary $states $railEvidence $nHw $nGpu $railsReadable
        Add-Finding 'crash' $sum.Sev $sum.Title $sum.Detail $sum.Action ''
        Add-Finding 'psu' $sum.PsuSev $sum.PsuTitle $sum.PsuDetail '' ''
    }

    # ---- name the faulting driver from the minidumps, if the Windows debugger is installed
    $dumps = @()
    if (Test-Path "$env:SystemRoot\Minidump") { $dumps = @(Get-ChildItem "$env:SystemRoot\Minidump" -Filter '*.dmp' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending) }
    Add-Fact 'crash' 'Minidumps on disk' $dumps.Count
    $cdb = @("${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\x64\cdb.exe", "$env:ProgramFiles\Windows Kits\10\Debuggers\x64\cdb.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($dumps.Count -gt 0 -and $cdb -and -not $Offline) {
        $drow = New-Rows
        $sym = 'srv*{0}*https://msdl.microsoft.com/download/symbols' -f (Join-Path $env:TEMP 'pchealth-symbols')
        foreach ($dmp in ($dumps | Select-Object -First 3)) {
            Write-Host ('      analysing {0} (downloads symbols on first use)...' -f $dmp.Name)
            $out = Join-Path $env:TEMP 'pchealth-cdb.txt'
            $p = Start-Process -FilePath $cdb -ArgumentList @('-z', ('"{0}"' -f $dmp.FullName), '-y', ('"{0}"' -f $sym), '-c', '"!analyze -v; q"') -RedirectStandardOutput $out -NoNewWindow -PassThru
            if (-not $p.WaitForExit(240000)) { try { $p.Kill() } catch {} }
            $txt = ''; try { $txt = Get-Content $out -Raw -ErrorAction Stop } catch {}
            $f = @{}
            foreach ($key in 'IMAGE_NAME', 'MODULE_NAME', 'PROCESS_NAME', 'FAILURE_BUCKET_ID') { if ($txt -match ('(?m)^{0}:\s+(\S+)' -f $key)) { $f[$key] = $Matches[1] } else { $f[$key] = '' } }
            [void]$drow.Add(@($dmp.Name, (Format-Stamp $dmp.LastWriteTime), [string]$f['IMAGE_NAME'], [string]$f['PROCESS_NAME'], [string]$f['FAILURE_BUCKET_ID']))
            if ($f['IMAGE_NAME']) {
                $own = $f['IMAGE_NAME'] -match '^(ntkrnlmp|ntoskrnl|hal|win32k\w*)\.'
                Add-Finding 'crash' 'info' ('Dump {0} blames {1}' -f $dmp.Name, $f['IMAGE_NAME']) `
                    $(if ($own) { 'That is a core Windows component, which usually means the real culprit corrupted memory earlier and Windows merely tripped over it: think RAM or CPU stability rather than Windows itself.' } else { 'This is the module that was executing when Windows crashed. Find which driver package it belongs to in the driver table.' }) '' ''
            }
        }
        Add-Table 'crash' 'Dump analysis (Windows debugger)' @('Dump', 'Written', 'Faulting module', 'Process running', 'Failure bucket') $drow '' $false
    } elseif ($dumps.Count -gt 0 -and -not $cdb) {
        Add-Finding 'crash' 'info' 'Minidumps exist but the faulting driver could not be named' `
            'Reading the driver name out of a dump needs Microsoft''s command-line debugger (cdb.exe), which is not installed.' `
            'Install the Windows SDK and tick only "Debugging Tools for Windows", then re-run. This tool will then analyse the three newest dumps automatically.' 'https://learn.microsoft.com/windows-hardware/drivers/debugger/'
    }

    # ---- application crashes
    $app = @(Get-Ev 'Application' 'Application Error' @(1000)) + @(Get-Ev 'Application' 'Application Hang' @(1002))
    if ($app.Count -gt 0) {
        $arow = New-Rows
        $grp = $app | Group-Object { $m = ''; try { if ($_.Id -eq 1000) { $m = [string]$_.Properties[3].Value } else { $m = '(stopped responding)' } } catch {}; '{0}|{1}' -f [string]$_.Properties[0].Value, $m } | Sort-Object Count -Descending
        foreach ($x in ($grp | Select-Object -First 12)) {
            $parts = $x.Name -split '\|'
            [void]$arow.Add(@($parts[0], $parts[1], [string]$x.Count, (Format-Stamp ($x.Group | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated)))
        }
        Add-Table 'crash' ('Application crashes and hangs ({0})' -f $app.Count) @('Program', 'Faulting module', 'Count', 'Most recent') $arow `
            'A graphics driver module (for example atidxx64.dll, amdxx64.dll, nvwgf2umx.dll) appearing here across several games points at the GPU driver or GPU stability.' $false
        $worst = $grp | Select-Object -First 1
        if ($worst.Count -ge 3) {
            $parts = $worst.Name -split '\|'
            Add-Finding 'crash' 'info' ('{0} crashed {1} times (module: {2})' -f $parts[0], $worst.Count, $parts[1]) 'One program failing repeatedly in the same module is usually that program or its add-ons. Many programs failing in different modules points back at memory or CPU stability.' '' ''
        }
    }
}

# ------------------------------------------------------------------ drivers
# AMD publishes one page per product; the index page embeds the full list of them.
$script:AmdIndex = $null
$script:AmdNewest = ''
function Get-AmdIndex {
    if ($null -eq $script:AmdIndex) {
        $h = Get-Web 'https://www.amd.com/en/support/download/drivers.html'
        $script:AmdIndex = @([regex]::Matches($h, 'https://www\.amd\.com/en/support/downloads/drivers\.html/[a-z0-9/_.\-]+\.html') | ForEach-Object { $_.Value } | Select-Object -Unique)
        $script:AmdNewest = Get-MaxVer $h 'adrenalin-edition-(\d{2}\.\d{1,2}\.\d{1,2})'
    }
    return $script:AmdIndex
}
# ASUS publishes a per-model listing (drivers and BIOS) for all its boards through its ROG support site.
function Get-AsusListing([string]$kind, [string]$model, [int]$osId) {
    $u = 'https://rog.asus.com/support/webapi/product/GetPD{0}?website=global&model={1}&cpu=' -f $kind, [uri]::EscapeDataString($model)
    if ($kind -eq 'Drivers') { $u += ('&osid={0}' -f $osId) }
    $j = (Get-Web $u) | ConvertFrom-Json
    $out = @()
    if ($j.Status -eq 'SUCCESS' -and $j.Result) {
        foreach ($c in $j.Result.Obj) { foreach ($f in $c.Files) { $out += [pscustomobject]@{ Category = [string]$c.Name; Version = [string]$f.Version; Title = [string]$f.Title; Date = [string]$f.ReleaseDate } } }
    }
    return $out
}
function Find-AmdPage([string]$section, [string]$slug) {
    if (-not $slug) { return '' }
    $hit = @(Get-AmdIndex) | Where-Object { $_ -match ('/{0}/' -f $section) -and $_.EndsWith('/' + $slug + '.html') } | Select-Object -First 1
    if ($hit) { return [string]$hit }
    return ''
}
function Get-AmdPageVersions([string]$url) {
    $h = Get-Web $url
    return @{
        Recommended = (Get-MaxVer $h 'whql-amd-software-adrenalin-edition-(\d{2}\.\d{1,2}\.\d{1,2})')
        Optional = (Get-MaxVer $h '(?<!whql-)amd-software-adrenalin-edition-(\d{2}\.\d{1,2}\.\d{1,2})-win')
        Chipset = (Get-MaxVer $h 'amd_chipset_software_(\d+\.\d+\.\d+(?:\.\d+)?)')
    }
}
function Get-InstalledProgram([string]$namePattern) {
    foreach ($root in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*') {
        $hit = Get-ItemProperty $root -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match $namePattern -and $_.DisplayVersion } | Select-Object -First 1
        if ($hit) { return $hit }
    }
    return $null
}

function Add-Link([string]$what, [string]$source, [string]$url, [string]$why) {
    [void]$script:Links.Add(@($what, (New-Cell $source '' $url), $why))
}

Invoke-Step 'Drivers' {
    $keyClasses = 'DISPLAY', 'NET', 'MEDIA', 'BLUETOOTH', 'SYSTEM', 'HDC', 'SCSIADAPTER', 'USB', 'MONITOR', 'HIDCLASS', 'MOUSE', 'KEYBOARD', 'CAMERA', 'AUDIOENDPOINT', 'SOFTWARECOMPONENT', 'EXTENSION', 'FIRMWARE', 'BIOMETRIC'
    $all = @($script:AllDrv)
    # Who installed each driver: read from Windows' own driver-installation log.
    try {
        $setupLog = Join-Path $env:SystemRoot 'INF\setupapi.dev.log'
        if (Test-Path $setupLog) {
            $fs = New-Object IO.FileStream($setupLog, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            try { $sr = New-Object IO.StreamReader($fs); $logText = $sr.ReadToEnd() } finally { $fs.Dispose() }
            $script:DriverOrigins = Get-DriverOriginsFromSetupLog ($logText -split "`r?`n")
        }
    } catch { [void]$script:Errors.Add('Driver installation log could not be read: ' + $_.Exception.Message) }
    Add-Fact 'drivers' 'Driver packages traced to their installer' $script:DriverOrigins.Count
    $third = @($all | Where-Object { $_.DriverProviderName -and $_.DriverProviderName -notmatch '^Microsoft' })
    $seen = @{}
    $rows = New-Rows
    $old = 0; $unsigned = 0
    foreach ($d in ($third | Sort-Object DeviceClass, DeviceName)) {
        $key = '{0}|{1}' -f $d.DeviceName, $d.DriverVersion
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = 1
        $script:Snap.drivers[[string]$d.DeviceName] = [string]$d.DriverVersion
        $ageTxt = ''; $ageSev = ''
        if ($d.DriverDate) {
            $y = ($started - [datetime]$d.DriverDate).TotalDays / 365
            $ageTxt = ('{0:N1} y' -f $y)
            if ($d.DeviceClass -eq 'DISPLAY' -and $y -ge 1) { $ageSev = 'warn' }
            elseif ($y -ge 4) { $ageSev = 'info'; $old++ }
        }
        $sig = New-Cell 'Yes' '' ''
        if ($d.IsSigned -eq $false) { $sig = New-Cell 'No' 'warn' ''; $unsigned++ }
        [void]$rows.Add(@([string]$d.DeviceName, [string]$d.DeviceClass, [string]$d.DriverProviderName, [string]$d.DriverVersion,
                (Format-Day $d.DriverDate), (New-Cell $ageTxt $ageSev ''), $sig,
                (Get-DriverOrigin ([string]$d.InfName) ([string]$d.DriverVersion) $script:DriverOrigins $script:WuDriverTitles)[0]))
    }
    Add-Table 'drivers' ('Installed third-party drivers ({0})' -f $rows.Count) @('Device', 'Class', 'Provider', 'Version', 'Date', 'Age', 'Signed', 'Installed by') $rows `
        'Microsoft in-box drivers are omitted; they are serviced by Windows Update. Age alone is not a fault: many chipset and device drivers are legitimately years old.' $true
    Add-Fact 'drivers' 'Drivers in use' ('{0} total, {1} third-party' -f $all.Count, $third.Count)
    if ($unsigned -gt 0) { Add-Finding 'drivers' 'warn' ('{0} unsigned driver(s) in use' -f $unsigned) 'See the Signed column in the driver table.' 'Replace with a signed version from the manufacturer.' '' }
    if ($old -gt 0) {
        $oldNames = @($third | Where-Object { $_.DriverDate -and $_.DeviceClass -ne 'DISPLAY' -and ($started - [datetime]$_.DriverDate).TotalDays / 365 -ge 4 } | ForEach-Object { '{0} ({1})' -f $_.DeviceName, (Format-Day $_.DriverDate) } | Select-Object -Unique)
        Add-Finding 'drivers' 'info' ('{0} third-party driver(s) are more than four years old' -f $old) `
            ('{0}. Usually fine: drivers for keyboards, mice and headsets are rarely updated. Worth a look only for network, audio, storage and chipset devices where the maker still publishes updates.' -f (($oldNames | Select-Object -First 8) -join '; ')) '' ''
    }
    $virt = @($all | Where-Object { Test-VirtualDevice $_ } | ForEach-Object { [string]$_.DeviceName } | Select-Object -Unique)
    if ($virt.Count -gt 0) {
        Add-Finding 'drivers' 'info' ('{0} virtual device(s) are installed by other software' -f $virt.Count) `
            ('{0}. Remote-desktop, streaming and VPN programs add software-only display, network and USB devices. They are legitimate, but they sit in the same driver stacks as the real graphics card and network adapter, so they are worth knowing about when chasing black screens, display glitches or network drop-outs.' -f ($virt -join '; ')) `
            'No action unless you are troubleshooting. If you are, uninstall the program that owns the device and see whether the problem stops.' ''
    }

    # devices Windows itself says are broken
    $prob = @(Get-Cim 'Win32_PnPEntity' 'root\cimv2' 'ConfigManagerErrorCode<>0')
    $codeText = @{ 1 = 'not configured correctly'; 10 = 'cannot start'; 12 = 'not enough free resources'; 14 = 'needs a restart'; 18 = 'drivers need reinstalling'
        19 = 'registry configuration damaged'; 22 = 'disabled'; 24 = 'not present or not working'; 28 = 'no driver installed'; 31 = 'driver failed to load'
        32 = 'driver service disabled'; 37 = 'driver failed to initialise'; 39 = 'driver corrupt or missing'; 43 = 'device reported a fault'; 45 = 'not connected'; 52 = 'driver signature not verified' }
    $prow = New-Rows
    $real = 0
    foreach ($p in $prob) {
        $c = [int]$p.ConfigManagerErrorCode
        if ($c -eq 45) { continue }
        $sev = 'warn'; if ($c -eq 22) { $sev = 'info' } else { $real++ }
        $txt = $codeText[$c]; if (-not $txt) { $txt = 'see Device Manager' }
        [void]$prow.Add(@([string]$p.Name, [string]$p.PNPClass, (New-Cell ('Code {0}: {1}' -f $c, $txt) $sev ''), (Get-Short ([string]$p.PNPDeviceID) 60)))
    }
    Add-Table 'drivers' 'Devices with a problem' @('Device', 'Class', 'Problem', 'Device ID') $prow '' $false
    if ($real -gt 0) { Add-Finding 'drivers' 'warn' ('{0} device(s) are not working according to Device Manager' -f $real) 'Listed in the table below. Code 28 means no driver at all; that is typically a chipset or motherboard-utility device.' 'Install the missing driver from the motherboard or PC maker''s support page.' '' }
    else { Add-Finding 'drivers' 'ok' 'Device Manager reports no failed devices' '' '' '' }

    # ---- Windows versus vendor conflicts
    $basic = @($all | Where-Object { $_.DeviceClass -eq 'DISPLAY' -and $_.DeviceName -match 'Basic Display' })
    if ($basic.Count -gt 0) {
        Add-Finding 'drivers' 'warn' 'A graphics adapter is running on the Microsoft Basic Display driver' 'No vendor driver is bound to it, so there is no acceleration. This happens after a failed driver install or a driver removal.' 'Install the GPU vendor driver (links below).' ''
    }
    $generic = @($all | Where-Object {
            $_.DeviceClass -in 'DISPLAY', 'NET', 'MEDIA', 'BLUETOOTH' -and $_.DriverProviderName -match '^Microsoft' -and
            $_.Manufacturer -match 'NVIDIA|AMD|Advanced Micro|Intel|Realtek|Qualcomm|MediaTek|Broadcom|Killer|Creative|Marvell|Aquantia' -and
            $_.DeviceName -notmatch 'WAN Miniport|Virtual|Wi-Fi Direct|Kernel Debug|Enumerator|Basic Display|High Definition Audio Device' })
    if ($generic.Count -gt 0) {
        $grow = New-Rows
        foreach ($g in $generic) { [void]$grow.Add(@([string]$g.DeviceName, [string]$g.DeviceClass, [string]$g.Manufacturer, [string]$g.DriverVersion, (Format-Day $g.DriverDate))) }
        Add-Table 'drivers' 'Vendor hardware running on a Microsoft in-box driver' @('Device', 'Class', 'Hardware maker', 'Version', 'Date') $grow '' $false
        Add-Finding 'drivers' 'info' ('{0} vendor device(s) use a generic Microsoft driver' -f $generic.Count) 'These work, but the manufacturer''s own driver usually adds features or fixes. Not a conflict in itself.' 'Optional: install the maker''s driver from the links below.' ''
    }

    $wuBlocked = $false
    try { if ((Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -ErrorAction Stop).ExcludeWUDriversInQualityUpdate -eq 1) { $wuBlocked = $true } } catch {}
    try { if ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching' -ErrorAction Stop).SearchOrderConfig -eq 0) { $wuBlocked = $true } } catch {}
    Add-Fact 'drivers' 'Windows Update may install drivers' $(if ($wuBlocked) { 'No (blocked by policy or setting)' } else { 'Yes (default)' })

    $conflicts = 0
    $staged = @()
    if ($IsAdmin) { try { $staged = @(Get-WindowsDriver -Online -ErrorAction Stop) } catch { [void]$script:Errors.Add('Driver store: ' + $_.Exception.Message) } }
    if ($staged.Count -gt 0) {
        Add-Fact 'drivers' 'Third-party packages in driver store' $staged.Count
        $drow = New-Rows
        $groups = $staged | Group-Object { '{0}|{1}|{2}' -f $_.ClassName, $_.ProviderName, [IO.Path]::GetFileName($_.OriginalFileName) } | Where-Object { $_.Count -gt 1 }
        foreach ($g in $groups) {
            $vers = @($g.Group | Sort-Object { ConvertTo-Ver $_.Version } -Descending)
            $first = $vers[0]
            if ($first.ClassName -notin 'Display', 'Net', 'MEDIA', 'Media', 'System', 'Bluetooth', 'HDC', 'SCSIAdapter', 'USB') { continue }
            [void]$drow.Add(@([string]$first.ClassName, [string]$first.ProviderName, [IO.Path]::GetFileName($first.OriginalFileName),
                    (($vers | ForEach-Object { '{0} ({1})' -f $_.Version, (Format-Day $_.Date) }) -join ', ')))
        }
        Add-Table 'drivers' 'Driver packages staged in more than one version' @('Class', 'Provider', 'Package', 'Versions (newest first)') $drow `
            'Normal after updates: Windows keeps old versions for roll-back. It matters only if the active driver is not the newest one (flagged separately).' $true

        $gpuNames = ($script:Gpus | ForEach-Object { $_.Name }) -join ' '
        $left = @($staged | Where-Object { $_.ClassName -eq 'Display' } | Where-Object {
                ($_.ProviderName -match 'NVIDIA' -and $gpuNames -notmatch 'NVIDIA') -or
                ($_.ProviderName -match 'Advanced Micro|AMD|ATI' -and $gpuNames -notmatch 'AMD|Radeon') -or
                ($_.ProviderName -match 'Intel' -and $gpuNames -notmatch 'Intel') })
        if ($left.Count -gt 0) {
            $orow = New-Rows
            foreach ($o in $left) { [void]$orow.Add(@([string]$o.Driver, [string]$o.ProviderName, [IO.Path]::GetFileName($o.OriginalFileName), [string]$o.Version, (Format-Day $o.Date))) }
            Add-Table 'drivers' 'Leftover graphics driver packages for hardware no longer installed' @('Package', 'Provider', 'Original file', 'Version', 'Date') $orow `
                'Remove one with:  pnputil /delete-driver <Package> /uninstall   (from an administrator prompt).' $false
            $apps = @()
            foreach ($pair in @(@('NVIDIA', 'NVIDIA'), @('AMD Software|Radeon Software', 'AMD|Radeon'), @('Intel.*Graphics', 'Intel'))) {
                if ($gpuNames -notmatch $pair[1]) { $pr = Get-InstalledProgram $pair[0]; if ($pr) { $apps += [string]$pr.DisplayName } }
            }
            Add-Finding 'drivers' 'warn' ('{0} graphics driver package(s) remain from a graphics card that is no longer installed' -f $left.Count) `
                ('Providers: {0}.{1} Leftovers from a previous card are a recognised source of instability after a GPU swap, and they are why Windows Update keeps trying to install drivers for it.' -f (($left | ForEach-Object { $_.ProviderName } | Select-Object -Unique) -join ', '), $(if ($apps.Count -gt 0) { ' Software still installed: ' + ($apps -join ', ') + '.' } else { '' })) `
                'Uninstall the old vendor''s software from Settings > Apps, then remove the packages listed in the table below (or run Display Driver Uninstaller in Safe Mode, choosing the OLD vendor).' ''
        }

        foreach ($gpu in $script:Gpus) {
            $active = ConvertTo-Ver $gpu.DriverVersion
            if (-not $active) { continue }
            $vendorWord = ($gpu.Name -split ' ')[0]
            $cand = @($staged | Where-Object { $_.ClassName -eq 'Display' -and $_.ProviderName -match [regex]::Escape($vendorWord) } | ForEach-Object { ConvertTo-Ver $_.Version } | Where-Object { $_ } | Sort-Object -Descending)
            if ($cand.Count -gt 0 -and $cand[0] -gt $active) {
                $conflicts++
                Add-Finding 'drivers' 'warn' ('{0}: a newer driver is staged than the one in use' -f $gpu.Name) `
                    ('Active {0}, newest in the driver store {1}. This pattern appears when Windows Update or a roll-back replaced a newer vendor driver with an older one, or when an install has not finished.' -f $active, $cand[0]) `
                    'Restart first. If it persists, clean-install the vendor driver, and consider stopping Windows Update from delivering drivers (see the note below).' ''
            }
        }
    }

    # WU offering a driver that is older than the vendor one already installed
    $wrow = New-Rows
    foreach ($u in $script:WuPending) {
        $verdict = New-Cell 'Offered' 'info' ''
        $uDate = $null; try { $uDate = [datetime]$u.DriverVerDate } catch {}
        $match = $all | Where-Object { $_.DeviceClass -eq [string]$u.DriverClass -and $_.DriverProviderName -notmatch '^Microsoft' -and $u.DriverModel -and $_.DeviceName -eq [string]$u.DriverModel } | Select-Object -First 1
        if (-not $match) { $match = Find-OfferedDriverTarget ([string]$u.Title) ([string]$u.DriverClass) $all }
        if ($match -and $uDate -and $match.DriverDate -and $uDate -lt ([datetime]$match.DriverDate).AddDays(-30)) {
            $conflicts++
            $verdict = New-Cell ('OLDER than installed ({0})' -f (Format-Day $match.DriverDate)) 'warn' ''
            Add-Finding 'drivers' 'warn' ('Windows Update is offering an older driver for {0}' -f $match.DeviceName) `
                ('Offered driver is dated {0}; the installed vendor driver is dated {1}. If installed, it would downgrade the vendor driver.' -f (Format-Day $uDate), (Format-Day $match.DriverDate)) `
                'Do not install it from Optional updates. Hide it with Microsoft''s "Show or hide updates" tool (wushowhide) if it keeps returning.' ''
        }
        [void]$wrow.Add(@((Get-Short ([string]$u.Title) 110), [string]$u.DriverClass, (Format-Day $uDate), $verdict))
    }
    Add-Table 'drivers' 'Driver updates offered by Windows Update' @('Update', 'Class', 'Driver date', 'Verdict') $wrow 'These appear under Settings > Windows Update > Advanced options > Optional updates.' $false
    if ($script:WuSearched -and $script:WuPending.Count -gt 0) {
        Add-Finding 'drivers' 'info' ('Windows Update is offering {0} driver update(s)' -f $script:WuPending.Count) 'See the table below. Prefer the device maker''s own package for GPU, chipset, audio and network.' '' ''
    }

    if ($script:WuHistory) {
        $hrow = New-Rows
        $drvHist = @($script:WuHistory | Where-Object { $_.Title -match 'NVIDIA|Advanced Micro Devices|AMD |Intel|Realtek|Qualcomm|MediaTek|Logitech|Corsair|ASUS|Micro-Star|Gigabyte|Broadcom|Synaptics|Samsung' -and $_.Title -notmatch 'KB\d{6,}|Defender|Security Intelligence' })
        foreach ($h in $drvHist) {
            $rc = New-Cell 'Installed' '' ''; if ($h.ResultCode -eq 4) { $rc = New-Cell 'Failed' 'warn' '' }
            [void]$hrow.Add(@((Format-Stamp $h.Date), (Get-Short ([string]$h.Title) 120), $rc))
        }
        foreach ($gpu in $script:Gpus) {
            $hit = $drvHist | Where-Object { $_.ResultCode -eq 2 -and $gpu.DriverVersion -and ([string]$_.Title).Contains([string]$gpu.DriverVersion) } | Select-Object -First 1
            if ($hit) {
                Add-Finding 'drivers' 'info' ('The graphics driver in use for {0} was installed by Windows Update' -f $gpu.Name) `
                    ('Windows Update installed driver {0} on {1}, and that is the version now active. Whether that is a conflict depends on how it compares with the manufacturer''s release: see the verdict in the "Windows versus manufacturer" table. Separately, if the vendor''s control software was installed from a different release, it can report a version mismatch.' -f $gpu.DriverVersion, (Format-Stamp $hit.Date)) '' ''
            }
        }
        foreach ($gpu in $script:Gpus) {
            $act = ConvertTo-Ver ([string]$gpu.DriverVersion)
            $vendorWord = ([string]$gpu.Name -split ' ')[0]
            foreach ($h in ($drvHist | Where-Object { $_.ResultCode -eq 2 -and $_.Title -match 'Display' -and $_.Title -match [regex]::Escape($vendorWord) })) {
                $hv = ConvertTo-Ver (Get-VersionFromTitle ([string]$h.Title))
                if ($act -and $hv -and $hv -lt $act) {
                    Add-Finding 'drivers' 'info' ('Windows Update installed an older graphics driver on {0}, since replaced' -f (Format-Day $h.Date)) `
                        ('It installed {0}; the driver now in use is {1}, which is newer. So Windows Update has overridden the graphics driver on this PC at least once in the last {2} days.{3}' -f $hv, $act, $Days, $(if ($wuBlocked) { ' The setting that stops Windows Update delivering drivers is on now; either it was turned on after that date or it did not prevent this.' } else { '' })) `
                        $(if ($wuBlocked) { 'Nothing to do now. If it happens again, the block is not working: check Group Policy > Windows Update > "Do not include drivers with Windows Updates".' } else { 'To stop it happening again, see the note about Windows Update and drivers in this section.' }) ''
                    break
                }
            }
        }
        Add-Table 'drivers' ('Drivers Windows Update installed in the last {0} days' -f $Days) @('When', 'Driver', 'Result') $hrow `
            'If a GPU or chipset entry here is dated after you installed the vendor package yourself, Windows Update overwrote it.' $false
    }
    if (-not $wuBlocked -and @($third | Where-Object { $_.DeviceClass -eq 'DISPLAY' }).Count -gt 0) {
        Add-Finding 'drivers' 'info' 'Windows Update is allowed to replace vendor drivers' `
            'This is the Windows default. It is the mechanism behind most "Windows versus manufacturer driver" conflicts, typically a GPU driver being swapped for an older one.' `
            'If you manage GPU and chipset drivers yourself: Group Policy > Windows Update > "Do not include drivers with Windows Updates", or System Properties > Hardware > Device Installation Settings > No.' ''
    }
    $compared = 0

    # ---- live GPU driver check
    $osId = 135; try { if ([int](Get-Cim 'Win32_OperatingSystem')[0].BuildNumber -lt 22000) { $osId = 57 } } catch {}
    $lrow = New-Rows
    foreach ($gpu in $script:Gpus) {
        $name = [string]$gpu.Name
        $gDrv = $all | Where-Object { $_.DeviceClass -eq 'DISPLAY' -and $_.DeviceName -eq $name } | Select-Object -First 1
        $gOrigin = @('Unknown', 'unknown'); if ($gDrv) { $gOrigin = Get-DriverOrigin ([string]$gDrv.InfName) ([string]$gpu.DriverVersion) $script:DriverOrigins $script:WuDriverTitles }
        $installed = [string]$gpu.DriverVersion; $latest = ''; $optional = ''; $src = ''; $note = ''
        $ageDays = 0; if ($gpu.DriverDate) { $ageDays = ($started - [datetime]$gpu.DriverDate).TotalDays }
        try {
            if ($name -match 'NVIDIA') {
                $src = 'https://www.nvidia.com/en-us/drivers/'
                $digits = ($installed -replace '\.', '')
                if ($digits.Length -ge 5) { $t = $digits.Substring($digits.Length - 5); $installed = '{0}.{1}' -f $t.Substring(0, 3), $t.Substring(3) }
                if ($name -match 'GTX (9|10)\d\d|GTX 7\d\d|GT \d') { $note = 'Legacy card: on a security-update-only driver branch, so the current Game Ready version does not apply.' }
                elseif (-not $Offline) {
                    foreach ($pair in @(@(127, 995), @(120, 877), @(120, 929))) {
                        $u = 'https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php?func=DriverManualLookup&psid={0}&pfid={1}&osID={2}&languageCode=1033&beta=0&isWHQL=1&dltype=-1&dch=1&upCRD=0&sort1=0&numberOfResults=1' -f $pair[0], $pair[1], $osId
                        $j = Invoke-RestMethod -Uri $u -TimeoutSec 20 -ErrorAction Stop
                        if ($j.IDS -and $j.IDS.Count -gt 0) { $latest = [uri]::UnescapeDataString([string]$j.IDS[0].downloadInfo.Version); break }
                    }
                    $note = 'Latest Game Ready driver for current-generation desktop cards.'
                }
            } elseif ($name -match 'AMD|Radeon') {
                $src = 'https://www.amd.com/en/support/download/drivers.html'
                try {
                    $rk = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}' -ErrorAction Stop |
                        ForEach-Object { Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue } | Where-Object { $_.RadeonSoftwareVersion } | Select-Object -First 1
                    if ($rk) { $installed = ([string]$rk.RadeonSoftwareVersion -replace '[^\d.].*$', '') } else { $installed = '' }
                } catch { $installed = '' }
                if (-not $installed) {
                    $prog = Get-InstalledProgram '^AMD Software$|^AMD Software: Adrenalin'
                    if ($prog) { $installed = [string]$prog.DisplayVersion }
                }
                if (-not $Offline) {
                    $page = Find-AmdPage 'graphics' (Get-AmdSlug $name)
                    # integrated graphics ("AMD Radeon(TM) Graphics") are listed under the processor instead
                    if (-not $page -and $name -notmatch '\d') { $page = Find-AmdPage 'processors' (Get-AmdSlug ([string](Get-Cim 'Win32_Processor' | Select-Object -First 1).Name)) }
                    if ($page) {
                        $src = $page
                        $pv = Get-AmdPageVersions $page
                        $latest = $pv.Recommended; $optional = $pv.Optional
                        if (-not $latest) { $latest = $optional; $optional = '' }
                        $note = 'From AMD''s download page for this exact product. "Latest found" is the WHQL (Recommended) release.'
                    } else {
                        $note = ('AMD lists no download page under this adapter''s name, which is typical of older cards on a legacy driver branch. The newest Adrenalin release overall is {0}, but it may not support this card.' -f $script:AmdNewest)
                    }
                }
            } elseif ($name -match 'Intel') {
                $src = 'https://www.intel.com/content/www/us/en/download/785597/intel-arc-iris-xe-graphics-windows.html'
                if (-not $Offline -and $name -match 'Arc|Iris|UHD') {
                    $html = Get-Web $src
                    $m = [regex]::Match($html, '\b(3\d\.0\.10\d\.\d{4})\b')
                    if ($m.Success) { $latest = $m.Groups[1].Value }
                    $note = 'Latest Arc / Iris Xe package. Older integrated graphics use a different, frozen package.'
                }
            }
        } catch { $note = 'Live lookup failed ({0}). Check the vendor page.' -f (Get-Short $_.Exception.Message 80) }

        $verdict = New-Cell 'Not checked' '' ''
        if ($latest) {
            $vi = ConvertTo-Ver $installed; $vl = ConvertTo-Ver $latest
            $vo = ConvertTo-Ver $optional
            if ($vi -and $vl -and $vl -gt $vi) {
                $gsev = Get-GpuDriverSeverity $ageDays
                $verdict = New-Cell 'Out of date' $gsev ''
                Add-Finding 'drivers' $gsev ('{0}: graphics driver {1} installed, {2} available' -f $name, $installed, $latest) `
                    ('Installed driver is dated {0}. {1}' -f (Format-Day $gpu.DriverDate), $(if ($optional) { 'A newer optional release, {0}, also exists.' -f $optional } else { '' })) `
                    'Download from the vendor (link in the table below). If the current driver is stable in your games, read the release notes first: newest is not automatically best for a GPU.' $src
            } elseif ($vi -and $vl -and $vo -and $vo -gt $vi) {
                $verdict = New-Cell 'Current (newer optional exists)' 'info' ''
                Add-Finding 'drivers' 'info' ('{0}: on the recommended driver {1}; optional {2} is available' -f $name, $installed, $optional) 'Optional releases carry newer game support but have had less testing than the WHQL release.' '' $src
            } elseif ($vi -and $vl) {
                $verdict = New-Cell 'Up to date' 'ok' ''
                Add-Finding 'drivers' 'ok' ('{0}: graphics driver is current ({1})' -f $name, $installed) '' '' ''
            } else {
                $verdict = New-Cell 'Could not compare' 'info' ''
                Add-Finding 'drivers' 'info' ('{0}: latest driver is {1}, but the installed version could not be read' -f $name, $latest) 'The vendor software does not appear to be installed, or it records its version somewhere this tool does not look.' 'Compare by eye against the vendor page.' $src
            }
        } else {
            $sev = 'info'; if ($ageDays -gt 365) { $sev = 'warn' }
            $verdict = New-Cell 'Not verified' $sev ''
            Add-Finding 'drivers' $sev ('{0}: could not verify the graphics driver against the vendor (installed driver dated {1})' -f $name, (Format-Day $gpu.DriverDate)) `
                $(if ($note) { $note } elseif ($Offline) { 'Offline mode: no vendor lookup was made.' } else { 'The vendor lookup returned no version.' }) 'Check the vendor page by hand.' $src
        }
        if ($latest) { $compared++ }
        if ($verdict.t -eq 'Out of date' -and $gOrigin[1] -in 'windows-inbox', 'windows-update') {
            $conflicts++
            $verdict = New-Cell 'CONFLICT: Windows installed an older driver than the manufacturer offers' 'warn' ''
            Add-Finding 'drivers' 'warn' ('CONFLICT: the graphics driver Windows installed for {0} is older than the manufacturer''s' -f $name) `
                ('Active driver: {0}, installed by {1}. The manufacturer''s current release is {2}. Windows Update tends to lag the manufacturer by weeks or months, and it will put its own version back unless told not to.' -f $installed, $gOrigin[0], $latest) `
                'Install the manufacturer''s driver from the link, then stop Windows Update replacing it (see the note about Windows Update and drivers in this section).' $src
        } elseif ($verdict.t -eq 'Up to date' -and $gOrigin[1] -eq 'windows-update') {
            $verdict = New-Cell 'No conflict: installed by Windows Update, and current' 'ok' ''
        }
        $latestTxt = '-'; if ($latest) { $latestTxt = $latest; if ($optional) { $latestTxt += (' (optional: {0})' -f $optional) } }
        [void]$lrow.Add(@($name, $installed, $gOrigin[0], (Format-Day $gpu.DriverDate), $latestTxt, $verdict, (New-Cell 'Vendor download page' '' $src), $note))
        if ($src) { Add-Link ('Graphics: {0}' -f $name) 'Vendor download page' $src 'Always take GPU drivers from the GPU vendor.' }
    }

    # ---- AMD chipset package: installed versus AMD's page for this board's chipset
    $cpu0 = Get-Cim 'Win32_Processor' | Select-Object -First 1
    if ($cpu0 -and [string]$cpu0.Name -match 'AMD') {
        $csrc = 'https://www.amd.com/en/support/download/drivers.html'; $clatest = ''; $cnote = ''
        $cprog = Get-InstalledProgram '^AMD Chipset Software'
        $cinst = ''; if ($cprog) { $cinst = [string]$cprog.DisplayVersion }
        if (-not $Offline) {
            try {
                $page = ''
                $prodName = ''; if ($script:Board) { $prodName = [string]$script:Board.Product }
                if ($prodName -match '(?<![A-Za-z0-9])([ABXabx]\d{3}[Ee]?)') {
                    $tok = $Matches[1].ToLower()
                    $page = Find-AmdPage 'chipsets' $tok
                    if (-not $page) { $page = Find-AmdPage 'chipsets' $tok.TrimEnd('e') }
                }
                if (-not $page -and [string]$cpu0.SocketDesignation -match '(AM\d)') {
                    # every chipset on a socket shares one package, so any page for that socket gives the right version
                    $sock = $Matches[1].ToLower()
                    $page = [string](@(Get-AmdIndex) | Where-Object { $_ -match ('/chipsets/{0}/' -f $sock) } | Select-Object -First 1)
                    $cnote = 'Board chipset not recognised from its name; version taken from AMD''s page for this CPU socket.'
                }
                if ($page) { $csrc = $page; $clatest = (Get-AmdPageVersions $page).Chipset }
            } catch { $cnote = 'Live lookup failed ({0}).' -f (Get-Short $_.Exception.Message 80) }
        }
        $vi = ConvertTo-Ver $cinst; $vl = ConvertTo-Ver $clatest
        if (-not $cinst) {
            $cver = New-Cell 'Not installed' 'warn' ''
            Add-Finding 'drivers' 'warn' 'AMD chipset driver package is not installed' `
                ('Windows is using its own in-box drivers for the chipset. AMD''s package adds the Ryzen power plan provisioning, PCI, GPIO, I2C and (on X3D parts) the 3D V-Cache optimiser.{0}' -f $(if ($clatest) { ' Current version: ' + $clatest + '.' } else { '' })) `
                'Install the AMD chipset drivers from the linked page.' $csrc
        } elseif ($vi -and $vl -and $vl -gt $vi) {
            $cver = New-Cell 'Out of date' 'warn' ''
            Add-Finding 'drivers' 'warn' ('AMD chipset drivers: {0} installed, {1} available' -f $cinst, $clatest) 'From AMD''s download page for this chipset.' 'Download and install the newer package, then restart.' $csrc
        } elseif ($vi -and $vl) {
            $cver = New-Cell 'Up to date' 'ok' ''
            Add-Finding 'drivers' 'ok' ('AMD chipset drivers are current ({0})' -f $cinst) '' '' ''
        } else {
            $cver = New-Cell 'Not verified' 'info' ''
            Add-Finding 'drivers' 'info' ('AMD chipset drivers {0} installed; could not verify against AMD' -f $cinst) $(if ($cnote) { $cnote } elseif ($Offline) { 'Offline mode.' } else { 'No version found on AMD''s page.' }) 'Check the AMD page by hand.' $csrc
        }
        $cdate = ''; if ($cprog -and $cprog.InstallDate -match '^(\d{4})(\d{2})(\d{2})$') { $cdate = '{0}-{1}-{2}' -f $Matches[1], $Matches[2], $Matches[3] }
        [void]$lrow.Add(@('AMD chipset drivers', $(if ($cinst) { $cinst } else { '-' }), $(if ($cinst) { 'AMD installer' } else { 'Windows (built in)' }), $cdate, $(if ($clatest) { $clatest } else { '-' }), $cver, (New-Cell 'AMD chipset page' '' $csrc), $cnote))
        Add-Link 'Chipset (AMD)' 'AMD chipset drivers' $csrc 'AMD''s page for this chipset. Includes the power plan and PCI drivers.'
    }

    # ---- motherboard devices: the driver in use versus the board maker's listing for this exact model
    $bMfr = ''; $bProd = ''
    if ($script:Board) { $bMfr = [string]$script:Board.Manufacturer; $bProd = [string]$script:Board.Product }
    if ($bMfr -match 'ASUS' -and $bProd -and -not $Offline) {
        $asusPage = 'https://www.asus.com/support/download-center/'
        try {
            $slug = Get-AsusModelSlug $bProd
            $asusOs = 52; if ($osId -eq 57) { $asusOs = 45 }
            $listing = @(Get-AsusListing 'Drivers' $slug $asusOs)
            if ($listing.Count -eq 0) {
                Add-Finding 'drivers' 'gap' ('ASUS returned no driver listing for "{0}"' -f $bProd) 'Audio, network, Wi-Fi and Bluetooth drivers could not be compared with the board maker''s versions.' 'Compare by hand on the board''s support page.' $asusPage
            }
            foreach ($g in (Get-BoardDriverLatest $listing | Sort-Object Category, Vendor)) {
                $done = @{}
                foreach ($d in @(Find-BoardDriverMatch $g $all)) {
                    if ($done.ContainsKey([string]$d.DeviceName)) { continue }
                    $done[[string]$d.DeviceName] = 1
                    $o = Get-DriverOrigin ([string]$d.InfName) ([string]$d.DriverVersion) $script:DriverOrigins $script:WuDriverTitles
                    $cv = Get-ConflictVerdict $o[1] ([string]$d.DriverVersion) $g.Version $true
                    $compared++
                    if ($cv[2]) { $conflicts++ }
                    if ($cv[0] -eq 'warn') {
                        Add-Finding 'drivers' 'warn' ('{0}: {1}' -f $d.DeviceName, $cv[1]) `
                            ('Driver in use: {0} (dated {1}), installed by: {2}. {3} lists {4} for this board, released {5}.' -f $d.DriverVersion, (Format-Day $d.DriverDate), $o[0], $bMfr, $g.Version, ($g.Date -replace '/', '-')) `
                            'Download it from the board maker''s support page for this exact model. If Windows Update put the older one in, see the note about stopping it in this section.' $asusPage
                    }
                    [void]$lrow.Add(@([string]$d.DeviceName, [string]$d.DriverVersion, $o[0], (Format-Day $d.DriverDate), $g.Version, (New-Cell $cv[1] $cv[0] ''),
                            (New-Cell 'ASUS support' '' $asusPage), ('ASUS lists: {0}' -f (Get-Short ($g.Title -replace '<[^>]+>.*$', '') 70))))
                }
            }
            $bios = Get-Cim 'Win32_BIOS' | Select-Object -First 1
            $newest = @(Get-AsusListing 'BIOS' $slug 0) | Where-Object { $_.Version -match '^\d+$' } | Sort-Object { [int]$_.Version } -Descending | Select-Object -First 1
            if ($bios -and $newest -and [string]$bios.SMBIOSBIOSVersion -match '^\d+$') {
                $bcell = New-Cell 'Up to date' 'ok' ''
                if ([int]$newest.Version -gt [int]$bios.SMBIOSBIOSVersion) {
                    $bcell = New-Cell 'Newer BIOS available' 'info' ''
                    Add-Finding 'drivers' 'info' ('BIOS {0} installed; {1} is available (released {2})' -f $bios.SMBIOSBIOSVersion, $newest.Version, ($newest.Date -replace '/', '-')) `
                        'A BIOS update is a choice, not a fix: take it when the changelog mentions CPU microcode, memory compatibility, stability or security, and never interrupt it.' 'Read the changelog on the board''s support page.' $asusPage
                }
                [void]$lrow.Add(@('Motherboard BIOS', [string]$bios.SMBIOSBIOSVersion, 'You (BIOS updates are manual)', (Format-Day $bios.ReleaseDate), [string]$newest.Version, $bcell, (New-Cell 'ASUS support' '' $asusPage), ''))
            }
        } catch {
            Add-Finding 'drivers' 'gap' 'The board maker''s driver listing could not be read' (Get-Short $_.Exception.Message 160) 'Compare audio, network, Wi-Fi and Bluetooth drivers by hand on the board''s support page.' $asusPage
        }
    } elseif ($bMfr -and $bMfr -notmatch 'ASUS') {
        $supUrl = Get-BoardSupportUrl $bMfr $bProd ([string]$cpu0.Name)
        $brow = New-Rows; $fromWindows = 0; $done = @{}
        foreach ($d in (Select-BoardDeviceDrivers $all | Sort-Object DeviceClass, DeviceName)) {
            if ($done.ContainsKey([string]$d.DeviceName)) { continue }
            $done[[string]$d.DeviceName] = 1
            $o = Get-DriverOrigin ([string]$d.InfName) ([string]$d.DriverVersion) $script:DriverOrigins $script:WuDriverTitles
            $win = $o[1] -in 'windows-inbox', 'windows-update'
            if ($win) { $fromWindows++ }
            [void]$brow.Add(@([string]$d.DeviceName, [string]$d.DriverVersion, (Format-Day $d.DriverDate), (New-Cell $o[0] $(if ($win) { 'info' } else { '' }) '')))
        }
        $bios = Get-Cim 'Win32_BIOS' | Select-Object -First 1
        if ($bios) { [void]$brow.Add(@('Motherboard BIOS', [string]$bios.SMBIOSBIOSVersion, (Format-Day $bios.ReleaseDate), 'You (BIOS updates are manual)')) }
        Add-Table 'drivers' ('Compare by hand against {0}''s support page' -f $bMfr) @('Device', 'Version in use', 'Dated', 'Installed by') $brow `
            'These are the motherboard devices whose drivers the board maker publishes. Compare each version with the newest one listed on the support page for this exact board.' $false
        Add-Finding 'drivers' 'gap' ('Motherboard device drivers could not be compared automatically with {0}''s versions' -f $bMfr) `
            ('MSI, Gigabyte and ASRock''s support sites refuse requests that do not come from a person using a browser, and this tool does not try to get round that. So sound, network, Wi-Fi, Bluetooth and BIOS versions for this board were not checked for Windows-versus-manufacturer conflicts. The table below lists what is installed so you can compare by eye.{0}' -f $(if ($fromWindows -gt 0) { ' {0} of these device(s) are running a driver supplied by Windows rather than the maker: check those first.' -f $fromWindows } else { '' })) `
            'Open the support page for this board (linked) and compare the versions in the "Compare by hand" table.' $supUrl
    }

    if ($conflicts -eq 0 -and $compared -gt 0) {
        Add-Finding 'drivers' 'ok' 'No driver conflict found: nothing Windows installed is older than the manufacturer''s version' `
            ('{0} device(s) were compared against a manufacturer source. Devices with no manufacturer source are not covered by this statement.' -f $compared) '' ''
    } elseif ($compared -eq 0) {
        Add-Finding 'drivers' 'gap' 'No driver could be compared with a manufacturer''s version' $(if ($Offline) { 'Offline mode: no manufacturer lookups were made.' } else { 'No manufacturer lookup returned a version.' }) '' ''
    }

    Add-Table 'drivers' 'Windows versus manufacturer: driver in use and latest available' @('Component', 'In use', 'Installed by', 'Dated', 'Manufacturer''s latest', 'Verdict', 'Get it', 'Note') $lrow `
        '"Installed by" comes from Windows'' own driver-installation log. A CONFLICT means Windows (built-in driver or Windows Update) is supplying an older driver than the manufacturer publishes. Manufacturer versions are read live from AMD, NVIDIA and ASUS; they publish no official API, so a failed lookup is reported as not verified, never as up to date.' $false

    # ---- where to get everything else
    $cpuName = [string](Get-Cim 'Win32_Processor' | Select-Object -First 1).Name
    if ($cpuName -match 'Intel') { Add-Link 'Chipset, Wi-Fi, Bluetooth, LAN (Intel)' 'Intel Driver & Support Assistant' 'https://www.intel.com/content/www/us/en/support/detect.html' 'Intel''s own scanner identifies and updates Intel components.' }
    $mfr = ''; $prod = ''
    if ($script:Board) { $mfr = [string]$script:Board.Manufacturer; $prod = [string]$script:Board.Product }
    $sysMfr = [string](Get-Cim 'Win32_ComputerSystem' | Select-Object -First 1).Manufacturer
    $vendorUrl = ''
    if ($sysMfr -match 'Dell') { $vendorUrl = 'https://www.dell.com/support/home' }
    elseif ($sysMfr -match 'HP|Hewlett') { $vendorUrl = 'https://support.hp.com/drivers' }
    elseif ($sysMfr -match 'Lenovo') { $vendorUrl = 'https://pcsupport.lenovo.com/' }
    elseif ($mfr -match 'ASUS') { $vendorUrl = 'https://www.asus.com/support/download-center/' }
    elseif ($mfr -match 'Micro-Star|MSI') { $vendorUrl = 'https://www.msi.com/support/download' }
    elseif ($mfr -match 'Gigabyte') { $vendorUrl = 'https://www.gigabyte.com/Support' }
    elseif ($mfr -match 'ASRock') { $vendorUrl = 'https://www.asrock.com/support/index.asp' }
    $why = 'BIOS, audio (Realtek), LAN, Wi-Fi and board utilities. Board makers ship versions validated for this exact board.'
    if ($vendorUrl) { Add-Link ('Motherboard / system: {0} {1}' -f $mfr, $prod) 'Manufacturer support site' $vendorUrl $why }
    $exactUrl = Get-BoardSupportUrl $mfr $prod $cpuName
    if ($exactUrl) { Add-Link ('Motherboard / system: {0} {1}' -f $mfr, $prod) 'Support page for this exact board' $exactUrl 'Built from the board''s name; if it does not open, use the search link below.' }
    if ($prod) {
        $q = [uri]::EscapeDataString(('{0} {1} support drivers BIOS' -f $mfr, $prod))
        Add-Link ('Motherboard / system: {0} {1}' -f $mfr, $prod) 'Search for the exact support page' ('https://duckduckgo.com/?q=' + $q) 'Opens a web search for this exact model.'
    }
    Add-Link 'Everything else' 'Windows Update > Optional updates' 'ms-settings:windowsupdate-optionalupdates' 'Safe fallback for devices whose maker publishes only through Microsoft.'
    Add-Table 'drivers' 'Where to get the latest drivers' @('Component', 'Source', 'Why this source') $script:Links `
        'Avoid third-party "driver updater" utilities; they are a common source of wrong or bundled drivers.' $false
}

# ------------------------------------------------------- changes since last run
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot 'reports' }
Invoke-Step 'Changes since last run' {
    $script:Snap.generated = $started.ToString('yyyy-MM-dd HH:mm')
    $fl = New-Object System.Collections.ArrayList
    foreach ($a in $script:Areas.Values) {
        if ($a.id -eq 'changes') { continue }
        foreach ($x in $a.findings) { if ($x.sev -in 'warn', 'crit') { [void]$fl.Add(@{ key = (Get-FindingKey $a.id $x.title); title = [string]$x.title; area = [string]$a.name }) } }
    }
    $script:Snap.findings = $fl
    $prevFile = $null
    if (Test-Path $OutDir) { $prevFile = Get-ChildItem $OutDir -Filter ('PCHealth-{0}-*.json' -f $env:COMPUTERNAME) -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1 }
    if (-not $prevFile) {
        Add-Finding 'changes' 'info' 'This is the first run on this PC, so there is nothing to compare with yet' 'A baseline has been saved with this report. From the next run onward this section shows what changed: new crashes and power losses, drive wear, drivers updated or downgraded, and problems that appeared or went away.' 'Keep the reports folder; the comparison reads the most recent report in it.' ''
        return
    }
    $prev = $null
    try { $prev = (Get-Content $prevFile.FullName -Raw | ConvertFrom-Json).snapshot } catch {}
    if (-not $prev) {
        Add-Finding 'changes' 'info' 'The previous report was made by an older version of this tool and cannot be compared' ('{0} has no saved baseline. One has been saved with this report, so the next run will show changes.' -f $prevFile.Name) '' ''
        return
    }
    $cmp = Compare-Snapshots $prev ($script:Snap | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
    Add-Fact 'changes' 'Compared with the run of' ([string]$prev.generated)
    Add-Fact 'changes' 'Previous report' $prevFile.Name
    foreach ($x in $cmp.Findings) { Add-Finding 'changes' $x.sev $x.title $x.detail '' '' }
    $crow = New-Rows
    foreach ($c in $cmp.DriverChanges) { [void]$crow.Add(@([string]$c[0], [string]$c[1], [string]$c[2], (New-Cell ([string]$c[3]) $(if ($c[3] -eq 'DOWNGRADED') { 'warn' } else { '' }) ''))) }
    Add-Table 'changes' 'Drivers that changed version' @('Device', 'Was', 'Now', 'Change') $crow '' $false
}

# ----------------------------------------------------------------- assemble
$areaList = New-Object System.Collections.ArrayList
foreach ($a in $script:Areas.Values) {
    $st = Get-AreaStatus $a.findings
    $a.status = $st[0]; $a.summary = $st[1]
    [void]$areaList.Add($a)
}
$overall = Get-OverallStatus @($areaList | ForEach-Object { $_.status })

$errList = New-Object System.Collections.ArrayList
foreach ($e in $script:Errors) { [void]$errList.Add([string]$e) }
$report = [ordered]@{
    meta = [ordered]@{
        computer = [string]$env:COMPUTERNAME
        machine = [string]((@(
                    (($script:Areas['cpu'].facts | Where-Object { $_.k -eq 'Model' } | Select-Object -First 1).v -replace '\s+\d+-Core Processor', ''),
                    (($script:Gpus | ForEach-Object { $_.Name }) -join ' + '),
                    $script:RamText,
                    ($script:Areas['board'].facts | Where-Object { $_.k -eq 'Board' } | Select-Object -First 1).v
                ) | Where-Object { $_ }) -join '  |  ')
        generated = $started.ToString('yyyy-MM-dd HH:mm')
        elevated = [bool]$IsAdmin
        days = $Days
        deepScan = [bool]$DeepScan
        watchMinutes = $WatchMinutes
        offline = [bool]$Offline
        sensorSource = [string]$script:SensorSource
        sensorNote = [string]$script:SensorNote
        durationSec = [int]((Get-Date) - $started).TotalSeconds
        overall = $overall
        errors = $errList
    }
    areas = $areaList
    snapshot = $script:Snap
}

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$stamp = $started.ToString('yyyyMMdd-HHmmss')
$base = Join-Path $OutDir ('PCHealth-{0}-{1}' -f $env:COMPUTERNAME, $stamp)
$json = ConvertTo-Json -InputObject $report -Depth 12 -Compress
$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText("$base.json", $json, $utf8)

$templatePath = Join-Path $PSScriptRoot 'dashboard.template.html'
if (Test-Path $templatePath) {
    $template = [IO.File]::ReadAllText($templatePath, [Text.Encoding]::UTF8)
    $safe = $json.Replace('</', '<\/')
    $html = $template.Replace('/*__REPORT_DATA__*/null', $safe)
    [IO.File]::WriteAllText("$base.html", $html, $utf8)
    Write-Host ''
    Write-Host ('Overall: {0}' -f $overall.ToUpper()) -ForegroundColor $(if ($overall -eq 'crit') { 'Red' } elseif ($overall -eq 'warn') { 'Yellow' } else { 'Green' })
    Write-Host ('Dashboard: {0}.html' -f $base)
    if (-not $NoOpen) { Start-Process "$base.html" }
} else {
    Write-Warning ('dashboard.template.html not found next to the script. Raw data written to {0}.json' -f $base)
}
if ($script:Errors.Count -gt 0) { Write-Host ('{0} collection step(s) had problems; they are listed at the bottom of the dashboard.' -f $script:Errors.Count) -ForegroundColor DarkYellow }
