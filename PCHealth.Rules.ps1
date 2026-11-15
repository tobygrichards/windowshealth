# PCHealth.Rules.ps1
# Assessment rules for the PC health check. Every function here is pure: no WMI, registry, event log,
# network or file access. They take plain values in and return plain values, so they can be tested on
# any machine with tests\Run-Tests.ps1. Get-PCHealth.ps1 collects the data and calls these to judge it.
# This is the single place where limits and thresholds are defined.
# Pure ASCII, compatible with Windows PowerShell 5.1.

# Sensor names that are a device's published limit or offset rather than a measurement.
$script:RefSensor = 'Warning|Critical|Threshold|Limit|Resolution|Distance|TjMax|Offset'
$script:CpuTjMax = 95
$script:NoLimit = -1e9

function ConvertTo-Ver([string]$s) { try { return [version]$s } catch { return $null } }

# Highest version captured by group 1 of $pattern, returned exactly as the source wrote it (8.09, not 8.9).
function Get-MaxVer([string]$text, [string]$pattern) {
    $best = $null; $bestText = ''
    foreach ($m in [regex]::Matches($text, $pattern, 'IgnoreCase')) {
        $v = ConvertTo-Ver $m.Groups[1].Value
        if ($v -and (-not $best -or $v -gt $best)) { $best = $v; $bestText = $m.Groups[1].Value }
    }
    return $bestText
}

# "AMD Radeon(TM) RX 6800 XT" -> "amd-radeon-rx-6800-xt", the form AMD uses in its download page addresses.
function Get-AmdSlug([string]$name) {
    $s = $name.ToLower() -replace '\((tm|r)\)', ' ' -replace '\s+\d+-core processor.*$', '' -replace '\s+with radeon.*$', '' -replace '\s+series$', ''
    return (($s -replace '[^a-z0-9]+', '-').Trim('-'))
}

# Chipset token from a motherboard product name: "ROG STRIX X570-E GAMING" -> "x570", "B650M-A" -> "b650".
function Get-AmdChipsetToken([string]$boardProduct) {
    if ($boardProduct -match '(?<![A-Za-z0-9])([ABXabx]\d{3}[Ee]?)') { return $Matches[1].ToLower() }
    return ''
}

# The temperature at which a processor family throttles itself.
function Get-CpuTjMax([string]$cpuName) {
    if ($cpuName -match 'X3D') { return 89 }
    if ($cpuName -match 'Ryzen \d+ 5\d{3}') { return 90 }
    if ($cpuName -match 'Intel') { return 100 }
    return 95
}

# Nominal voltage of a supply rail, from the sensor's name. 0 when the name is not a rail.
function Get-RailNominal([string]$n) {
    if ($n -match '12\s?V') { return 12 }
    if ($n -match '(^|[^\d.])\+?5\s?V') { return 5 }
    if ($n -match '3\.3\s?V|3VCC|3V3|AVCC|3VSB|AVSB') { return 3.3 }
    return 0
}

# @(warning, critical) temperature for one drive: the limits the drive itself publishes when it does,
# otherwise general guidance. $driveId is the sensor library's identifier, e.g. /nvme/0 or /hdd/2.
function Get-DriveTempLimits($sensors, [string]$driveId) {
    $w = 70; $c = 80
    if ($driveId -match '/hdd/') { $w = 55; $c = 65 }
    $own = @($sensors | Where-Object { $_.HwType -eq 'Storage' -and $_.Type -eq 'Temperature' -and $_.Id -eq $driveId })
    $ow = $own | Where-Object { $_.Name -match 'Warning' -and $_.Value -gt 40 } | Select-Object -First 1
    $oc = $own | Where-Object { $_.Name -match 'Critical' -and $_.Value -gt 40 } | Select-Object -First 1
    if ($ow) { $w = $ow.Value }
    if ($oc) { $c = $oc.Value } elseif ($ow) { $c = $ow.Value + 5 }
    return @($w, $c)
}

# The range a sensor is EXPECTED to sit in for this kind of component.
# Returns @(low, high, criticalLow, criticalHigh, explanation, raiseFindingInMotherboardSection), or nothing
# when the sensor has no meaningful range (clock speeds, loads) or cannot be identified.
function Get-SensorSpec($s, $sensors) {
    $n = $s.Name; $none = $script:NoLimit
    if ($s.Type -eq 'Temperature') {
        if ($n -match $script:RefSensor) { return }
        if ($s.HwType -eq 'Cpu') { return @(10, ($script:CpuTjMax - 5), $none, ($script:CpuTjMax + 3), '', $false) }
        if ($s.HwType -match '^Gpu') {
            if ($n -match 'Hot ?Spot') { return @(10, 100, $none, 110, 'The hot spot is the hottest point on the GPU die. A gap of more than about 25 C above the core temperature suggests dried thermal paste or poor cooler contact.', $true) }
            return @(10, 88, $none, 100, '', $false)
        }
        if ($s.HwType -eq 'Storage') { $lim = Get-DriveTempLimits $sensors $s.Id; return @(0, ($lim[0] - 5), $none, $lim[1], '', $false) }
        if ($s.HwType -eq 'Memory') { return @(10, 55, $none, 65, 'Hot memory produces errors, particularly with XMP / EXPO enabled.', $true) }
        if ($n -match 'VRM|MOS') { return @(10, 100, $none, 115, 'The VRM feeds the CPU. Overheating VRMs throttle the CPU and cause shutdowns under load; improve airflow around the CPU socket.', $true) }
        if ($n -match 'Chipset|PCH') { return @(10, 80, $none, 95, 'X570 boards have a chipset fan; check it spins and is not clogged.', $true) }
        if ($n -match '^(CPU|System|Motherboard|T_Sensor|Water)') { return @(10, 80, $none, 95, 'Board-level temperatures this high point at case airflow.', $true) }
        return
    }
    if ($s.Type -eq 'Voltage') {
        $nom = Get-RailNominal $n
        if ($nom -gt 0 -and $s.HwType -ne 'Cpu') {
            # More than 30 % out means the input is not scaled as a rail on this board (a 12 V input reading 1 V).
            # Anything nearer than that is judged, so a rail that has genuinely collapsed is never hidden.
            if ([math]::Abs(100 * ($s.Value - $nom) / $nom) -gt 30) { return }
            return @(($nom * 0.95), ($nom * 1.05), ($nom * 0.92), ($nom * 1.08), 'The ATX specification allows +/-5 % on this rail.', $false)
        }
        if ($n -match 'VBAT|CMOS') { return @(2.7, 3.4, $none, 1e9, 'A CR2032 below about 2.7 V is near the end of its life; the symptom is the clock and BIOS settings resetting. Replace the coin cell.', $true) }
        if ($n -match 'SoC') { return @(0.85, 1.25, $none, 1.35, 'On Ryzen, SoC voltage above about 1.25 V risks long-term degradation and is a known cause of memory instability. It is normally set by the XMP / EXPO profile or by hand in the BIOS.', $true) }
        if ($n -match 'DRAM|DIMM') { return @(1.05, 1.5, $none, 1.6, 'DDR4 XMP profiles run at 1.35-1.5 V and DDR5 at 1.25-1.45 V. More than that needs active cooling and shortens module life.', $true) }
        if ($n -match 'SVI2|Vcore|CPU Core$|^Core$') { return @(0.2, 1.5, $none, 1.55, 'AMD specifies 1.55 V as the absolute maximum core voltage. Brief peaks near 1.5 V at light load are normal for Ryzen; sustained readings above that usually come from a manual voltage or aggressive PBO setting.', $true) }
        return
    }
    if ($s.Type -eq 'Fan' -and $n -match 'CPU' -and $n -notmatch 'OPT|Pump') {
        return @(1, 1e9, $none, 1e9, 'Nothing is spinning on the CPU fan header. Expected if an AIO pump or fan hub is connected elsewhere; otherwise the CPU cooler fan has stopped.', $true)
    }
    return
}

function Get-SensorUnit([string]$type) {
    switch ($type) {
        'Temperature' { return ' C' }
        'Voltage' { return ' V' }
        'Fan' { return ' RPM' }
        'Clock' { return ' MHz' }
        'Power' { return ' W' }
        'Load' { return ' %' }
        'Level' { return ' %' }
        'Control' { return ' %' }
        'Data' { return ' GB' }
        'SmallData' { return ' MB' }
        'Current' { return ' A' }
        'Throughput' { return ' B/s' }
        'Frequency' { return ' Hz' }
    }
    return ''
}

# Judges one sensor against its expected range, using the lowest and highest values seen.
# Returns @(severity, assessment text, finding detail or '', expected-range text).
# severity: 'ok' | 'warn' | 'crit' | 'info' (invalid reading) | '' (not judged)
function Get-SensorVerdict($s, $sensors) {
    if (-not $s.Valid) { $t = 'Invalid reading, ignored'; if ($s.Note) { $t = $s.Note }; return @('info', $t, '', '') }
    $sp = @(Get-SensorSpec $s $sensors)
    if ($sp.Count -eq 0) {
        $why = ''
        if ($s.Type -eq 'Temperature' -and $s.Name -match $script:RefSensor) { $why = 'Reference value, not a reading' }
        elseif ($s.Type -eq 'Temperature' -and $s.Name -match '^Temperature( #\d+)?$') { $why = 'Not judged: unlabelled input on the sensor chip' }
        elseif ($s.Type -eq 'Voltage' -and (Get-RailNominal $s.Name) -gt 0 -and $s.HwType -ne 'Cpu') { $why = 'Not judged: not a correctly scaled rail reading' }
        elseif ($s.Type -in 'Temperature', 'Voltage') { $why = 'Not judged: no known range for this sensor' }
        return @('', $why, '', '')
    }
    $u = Get-SensorUnit $s.Type
    if ($sp[1] -ge 1e9) { $range = ('above {0:0.##}{1}' -f ($sp[0] - 1), $u) } else { $range = ('{0:0.##} to {1:0.##}{2}' -f $sp[0], $sp[1], $u) }
    $detail = ''; if ($sp[5]) { $detail = $sp[4] }
    $sev = ''; $txt = ''
    if ($s.Max -ge $sp[3]) { $sev = 'crit'; $txt = ('{0:0.##}{1} is beyond the safe limit of {2:0.##}{1}' -f $s.Max, $u, $sp[3]) }
    elseif ($s.Min -le $sp[2]) { $sev = 'crit'; $txt = ('{0:0.##}{1} is below the safe limit of {2:0.##}{1}' -f $s.Min, $u, $sp[2]) }
    elseif ($s.Max -gt $sp[1]) { $sev = 'warn'; $txt = ('{0:0.##}{1} is above the expected range' -f $s.Max, $u) }
    elseif ($s.Min -lt $sp[0]) { $sev = 'warn'; $txt = ('{0:0.##}{1} is below the expected range' -f $s.Min, $u) }
    if (-not $sev) { return @('ok', 'Within expected range', '', $range) }
    if ($s.HwType -eq 'SuperIO') {
        # The board's sensor chip is a single unconfirmed source: report it as something to verify, never as critical.
        $sev = 'warn'; $txt += '. Low-confidence source (board sensor chip): confirm in the BIOS before acting'
    }
    return @($sev, $txt, $detail, $range)
}

# A reading that moved further between two samples a second apart than physics allows.
# Returns the reason, or '' when the sensor is plausible. Only supply rails are checked for voltage:
# CPU core voltage legitimately swings by far more than 10 % from one second to the next.
function Test-SensorErratic($s) {
    if ($s.Type -eq 'Temperature' -and $s.Step -gt 20) {
        return ('Erratic: jumped {0:N0} C between samples a few seconds apart, which is not physically possible' -f $s.Step)
    }
    if ($s.Type -eq 'Voltage' -and $s.HwType -eq 'SuperIO' -and (Get-RailNominal $s.Name) -gt 0 -and $s.Max -gt 0.5 -and ($s.Step / $s.Max) -gt 0.10) {
        return 'Erratic: jumped more than 10 % between samples a few seconds apart'
    }
    return ''
}

# The sensor library's readings that belong to ONE physical drive. Two drives of the same model share a
# name, so when a name matches several drives the one whose identifier ends in the Windows disk number is
# used; if that cannot be decided, nothing is returned rather than another drive's figures.
function Select-DriveSensors($sensors, [string]$name, $diskNumber) {
    $cand = @($sensors | Where-Object { $_.HwType -eq 'Storage' -and $_.Valid -and $name -and ($_.Hw -eq $name -or $_.Hw.Contains($name) -or $name.Contains($_.Hw)) })
    $ids = @($cand | ForEach-Object { $_.Id } | Select-Object -Unique)
    if ($ids.Count -le 1) { return $cand }
    $want = $ids | Where-Object { ($_ -split '/')[-1] -eq [string]$diskNumber } | Select-Object -First 1
    if (-not $want) { return @() }
    return @($cand | Where-Object { $_.Id -eq $want })
}

# The record closest in time to $t (within the window) that has not already been claimed by another crash.
function Select-NearestRecord($records, [datetime]$t, [hashtable]$used, [double]$minutesBefore, [double]$minutesAfter) {
    return ($records |
        Where-Object { -not $used.ContainsKey($_.RecordId) -and $_.TimeCreated -ge $t.AddMinutes(-1 * $minutesBefore) -and $_.TimeCreated -le $t.AddMinutes($minutesAfter) } |
        Sort-Object { [math]::Abs(($_.TimeCreated - $t).TotalSeconds) } | Select-Object -First 1)
}

# bugcheck code = name, suspect area, plain-English meaning
$script:Bugchecks = @{
    0x124 = @('WHEA_UNCORRECTABLE_ERROR', 'Hardware', 'The CPU reported a fatal hardware error. Almost never software: an unstable overclock, undervolt or memory profile, overheating, or a failing CPU, PSU or motherboard.')
    0x101 = @('CLOCK_WATCHDOG_TIMEOUT', 'CPU', 'A CPU core stopped responding. Typical of an unstable overclock, undervolt or Curve Optimizer setting; occasionally a failing CPU.')
    0x116 = @('VIDEO_TDR_FAILURE', 'GPU', 'The graphics driver hung and could not be reset. Graphics driver, GPU overheating or instability, or insufficient power to the card.')
    0x117 = @('VIDEO_TDR_TIMEOUT_DETECTED', 'GPU', 'The graphics driver took too long to respond.')
    0x119 = @('VIDEO_SCHEDULER_INTERNAL_ERROR', 'GPU', 'The graphics scheduler hit a fatal error. Graphics driver or failing GPU.')
    0x10E = @('VIDEO_MEMORY_MANAGEMENT_INTERNAL', 'GPU', 'Graphics memory manager error. Graphics driver or GPU memory.')
    0x1A = @('MEMORY_MANAGEMENT', 'Memory', 'Windows found its memory bookkeeping corrupted. Faulty or unstable RAM (XMP/EXPO), less often a driver.')
    0x4E = @('PFN_LIST_CORRUPT', 'Memory', 'Memory page list corrupted. Faulty or unstable RAM, or a driver writing where it should not.')
    0x12B = @('FAULTY_HARDWARE_CORRUPTED_PAGE', 'Memory', 'A memory page changed when nothing should have touched it. Strongly suggests faulty RAM.')
    0x50 = @('PAGE_FAULT_IN_NONPAGED_AREA', 'Driver or memory', 'Something referenced memory that does not exist. A buggy driver or faulty RAM.')
    0x0A = @('IRQL_NOT_LESS_OR_EQUAL', 'Driver or memory', 'A driver touched memory at the wrong priority level. Buggy driver, or faulty RAM.')
    0xD1 = @('DRIVER_IRQL_NOT_LESS_OR_EQUAL', 'Driver', 'A driver touched invalid memory. The dump normally names the driver; network and storage drivers are common.')
    0x3B = @('SYSTEM_SERVICE_EXCEPTION', 'Driver', 'A system call crashed in kernel code. Usually a driver (graphics and antivirus are common).')
    0x7E = @('SYSTEM_THREAD_EXCEPTION_NOT_HANDLED', 'Driver', 'A driver thread crashed. The dump normally names the driver.')
    0x1E = @('KMODE_EXCEPTION_NOT_HANDLED', 'Driver or memory', 'Kernel code hit an error it did not handle. A driver, or faulty RAM.')
    0x9F = @('DRIVER_POWER_STATE_FAILURE', 'Driver', 'A driver did not complete a sleep, wake or shutdown transition. Usually network, USB or graphics drivers.')
    0x133 = @('DPC_WATCHDOG_VIOLATION', 'Driver or storage', 'A driver held the CPU too long. Storage controller or SSD firmware, or network and graphics drivers.')
    0x139 = @('KERNEL_SECURITY_CHECK_FAILURE', 'Driver or memory', 'Kernel data structure corruption detected. A driver bug or faulty RAM.')
    0xEF = @('CRITICAL_PROCESS_DIED', 'Windows or storage', 'A process Windows cannot run without died. Corrupt system files, or a failing system drive.')
    0x7A = @('KERNEL_DATA_INPAGE_ERROR', 'Storage', 'Windows could not read its own data back from disk. Failing drive, cable or storage controller.')
    0xF4 = @('CRITICAL_OBJECT_TERMINATION', 'Storage', 'A critical process ended, most often because the system drive stopped responding.')
    0x7B = @('INACCESSIBLE_BOOT_DEVICE', 'Storage', 'Windows lost access to the boot drive. Storage driver, controller mode change or failing drive.')
    0x154 = @('UNEXPECTED_STORE_EXCEPTION', 'Storage', 'The memory compression store failed, most often because the system drive stalled.')
    0xC2 = @('BAD_POOL_CALLER', 'Driver', 'A driver made an invalid memory pool request.')
    0x19 = @('BAD_POOL_HEADER', 'Driver or memory', 'Kernel memory pool corrupted. A driver, or faulty RAM.')
}

# Returns @(name, suspect area, meaning) for a bugcheck code. Windows reports some codes with 0x10000000
# added (0x1000007E is the same failure as 0x7E), so that flag is removed before the lookup.
function Resolve-Bugcheck([int64]$code) {
    $k = $code
    if ($k -ge 0x10000000 -and $k -lt 0x20000000) { $k = $k - 0x10000000 }
    $info = $null
    if ($k -ge 0 -and $k -le 0x7FFFFFFF) { $info = $script:Bugchecks[[int]$k] }
    if (-not $info) { return @('(not in built-in table)', 'Unknown', 'Search this bugcheck code on Microsoft Learn for its meaning.') }
    return $info
}

# Overall state of one dashboard area from its findings.
# 'gap' findings mean "this could not be checked". An area with gaps and no faults is 'limited',
# never 'ok': absence of evidence is not reported as health.
function Get-AreaStatus($findings) {
    $c = 0; $w = 0; $g = 0; $i = 0; $n = 0
    foreach ($f in $findings) {
        $n++
        switch ($f.sev) { 'crit' { $c++ } 'warn' { $w++ } 'gap' { $g++ } 'info' { $i++ } }
    }
    if ($c -gt 0) { return @('crit', ('{0} critical, {1} warning' -f $c, $w)) }
    if ($w -gt 0) { return @('warn', ('{0} warning(s)' -f $w)) }
    if ($n -eq 0) { return @('unknown', 'No data collected') }
    if ($g -gt 0) { return @('limited', ('No problems found, but {0} check(s) could not be made' -f $g)) }
    if ($i -gt 0) { return @('ok', ('No problems found, {0} note(s)' -f $i)) }
    return @('ok', 'No problems found')
}

# Worst status across all areas. 'limited' and 'unknown' do not outrank 'ok' here; the dashboard
# reports them separately.
function Get-OverallStatus($statuses) {
    if ($statuses -contains 'crit') { return 'crit' }
    if ($statuses -contains 'warn') { return 'warn' }
    return 'ok'
}
