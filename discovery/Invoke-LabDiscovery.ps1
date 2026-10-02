<#
.SYNOPSIS
    Phase 0 discovery for the POS Lab Control Centre. READ-ONLY.

.DESCRIPTION
    Collects facts from a POS lab machine so we can decide how the monitoring agent
    should detect sessions, installed component versions, Windows services, lab
    configuration and Master Data Distribution (MDD) health.

    The script changes NOTHING on the machine. It only reads:
      - OS / uptime / disks / pending reboot
      - RDP sessions (quser / qwinsta)
      - Installed programs (registry Uninstall keys)
      - File versions of executables under the TFG install folders
      - Windows services related to POS / Store / MDD
      - The MDD folder (listing, config files, tail of recent logs)
      - Related Application/System event log entries
      - Scheduled tasks pointing at TFG folders
      - Candidate configuration values (country / branch / store / environment)
      - Optionally (-IncludeSqlProbe) read-only metadata from local SQL Server

    Secrets (passwords, tokens, keys in connection strings / config) are redacted.
    Review the output folder before sharing it.

.PARAMETER OutputPath
    Folder to write results to. Defaults to the current user's Desktop.

.PARAMETER IncludeSqlProbe
    Also query local SQL Server instances (Windows auth, read-only metadata queries).

.PARAMETER ExtraRoots
    Additional install folders to scan for executables/config.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Invoke-LabDiscovery.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Invoke-LabDiscovery.ps1 -IncludeSqlProbe -ExtraRoots 'D:\POS'

.NOTES
    Compatible with Windows PowerShell 5.1. Run as Administrator for complete results
    (some service paths, event logs and other users' sessions need elevation).
#>
[CmdletBinding()]
param(
    [string]   $OutputPath = [Environment]::GetFolderPath('Desktop'),
    [switch]   $IncludeSqlProbe,
    [string[]] $ExtraRoots = @()
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
$Pattern = 'TFG|Foschini|\bPOS\b|Store ?Services|Store ?Master ?Data|Enterprise ?Library|Store ?Management|Master ?Data|Change ?Tracking|MDD|Peripheral|Pay@?Till'
$MddFolder = 'C:\Program Files\TFG\SQL\Change Tracking Queue Import Services'
$Roots = @('C:\Program Files\TFG', 'C:\Program Files (x86)\TFG') + $ExtraRoots |
    Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
$ConfigKeyPattern = 'Country|Branch|Store|Site|Environment|Region|Till|Lane|HeadOffice|Head ?Office|Server|Database|Catalog'
$EventLookbackHours = 48
$MaxFileBytesToRead = 2MB

$Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$RunDir = Join-Path $OutputPath ("LabDiscovery_{0}_{1}" -f $env:COMPUTERNAME, $Stamp)
New-Item -ItemType Directory -Path $RunDir -Force | Out-Null
$RawDir = Join-Path $RunDir 'raw'
New-Item -ItemType Directory -Path $RawDir -Force | Out-Null

$Result = [ordered]@{
    schema      = 'pos-lab-discovery/1'
    machine     = $env:COMPUTERNAME
    collectedAt = (Get-Date).ToString('o')
    collectedBy = "$env:USERDOMAIN\$env:USERNAME"
    elevated    = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    sections    = [ordered]@{}
    errors      = [ordered]@{}
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Protect-Secrets {
    param([string] $Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    # key=value / key: value  (connection strings, ini, json-ish)
    $Text = [regex]::Replace($Text,
        '(?i)((?:password|pwd|passwd|secret|token|apikey|api[_-]?key|accesskey|sharedkey|client[_-]?secret)\s*["'']?\s*[=:]\s*["'']?)([^;"''<>\s,}]+)',
        '$1***REDACTED***')
    # <add key="...Password..." value="..."/>
    $Text = [regex]::Replace($Text,
        '(?i)(key\s*=\s*"[^"]*(?:password|pwd|secret|token|apikey)[^"]*"\s+value\s*=\s*")([^"]*)(")',
        '$1***REDACTED***$3')
    # <Password>...</Password>
    $Text = [regex]::Replace($Text,
        '(?i)(<(password|pwd|secret|token|apikey)[^>]*>)([^<]*)(</\2>)',
        '$1***REDACTED***$4')
    return $Text
}

function Invoke-Section {
    param([string] $Name, [scriptblock] $Body)
    Write-Host ("[{0}] {1}..." -f (Get-Date -Format 'HH:mm:ss'), $Name)
    try {
        $Result.sections[$Name] = & $Body
    }
    catch {
        $Result.errors[$Name] = $_.Exception.Message
        Write-Warning ("{0} failed: {1}" -f $Name, $_.Exception.Message)
    }
}

function Read-TextSafe {
    param([string] $Path, [int] $TailLines = 0)
    $item = Get-Item -LiteralPath $Path
    if ($TailLines -gt 0) {
        $lines = Get-Content -LiteralPath $Path -Tail $TailLines -ErrorAction Stop
        return Protect-Secrets (($lines) -join "`r`n")
    }
    if ($item.Length -gt $MaxFileBytesToRead) { return "<skipped: $($item.Length) bytes>" }
    return Protect-Secrets ([IO.File]::ReadAllText($Path))
}

function ConvertFrom-QUser {
    param([string[]] $Lines)
    # quser columns: USERNAME SESSIONNAME ID STATE IDLE TIME LOGON TIME
    # SESSIONNAME is blank for disconnected sessions, so parse from the right.
    $out = @()
    foreach ($line in ($Lines | Select-Object -Skip 1)) {
        if (-not $line.Trim()) { continue }
        $current = $line.StartsWith('>')
        $l = $line.TrimStart('>', ' ')
        $m = [regex]::Match($l, '^(?<user>\S+)\s+(?:(?<session>\S+)\s+)?(?<id>\d+)\s+(?<state>\S+)\s+(?<idle>\S+)\s+(?<logon>.+?)\s*$')
        if ($m.Success) {
            $out += [ordered]@{
                user        = $m.Groups['user'].Value
                sessionName = $m.Groups['session'].Value
                id          = [int]$m.Groups['id'].Value
                state       = $m.Groups['state'].Value
                idle        = $m.Groups['idle'].Value
                logonTime   = $m.Groups['logon'].Value
                isCurrent   = $current
            }
        }
        else {
            $out += [ordered]@{ unparsed = $line }
        }
    }
    return , $out
}

# ---------------------------------------------------------------------------
# 1. Machine
# ---------------------------------------------------------------------------
Invoke-Section 'machine' {
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    [ordered]@{
        computerName   = $env:COMPUTERNAME
        domain         = $cs.Domain
        osCaption      = $os.Caption
        osVersion      = $os.Version
        osBuild        = $os.BuildNumber
        # ProductType: 1 = workstation (single interactive session), 2 = DC, 3 = server
        osProductType  = $os.ProductType
        lastBootTime   = $os.LastBootUpTime.ToString('o')
        uptimeMinutes  = [int]((Get-Date) - $os.LastBootUpTime).TotalMinutes
        memoryTotalMb  = [int]($os.TotalVisibleMemorySize / 1KB)
        memoryFreeMb   = [int]($os.FreePhysicalMemory / 1KB)
        psVersion      = $PSVersionTable.PSVersion.ToString()
        dotNetRelease  = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue).Release
        ipAddresses    = @(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = TRUE' |
            ForEach-Object { $_.IPAddress } | Where-Object { $_ -and $_ -notmatch ':' })
    }
}

# ---------------------------------------------------------------------------
# 2. Sessions / RDP
# ---------------------------------------------------------------------------
Invoke-Section 'sessions' {
    $quserRaw = @()
    $qwinstaRaw = @()
    try { $quserRaw = @(& quser.exe 2>&1 | ForEach-Object { "$_" }) } catch { $quserRaw = @("quser failed: $($_.Exception.Message)") }
    try { $qwinstaRaw = @(& qwinsta.exe 2>&1 | ForEach-Object { "$_" }) } catch { $qwinstaRaw = @("qwinsta failed: $($_.Exception.Message)") }
    $quserRaw | Set-Content (Join-Path $RawDir 'quser.txt')
    $qwinstaRaw | Set-Content (Join-Path $RawDir 'qwinsta.txt')

    $ts = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -ErrorAction SilentlyContinue
    $tsPolicy = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -ErrorAction SilentlyContinue
    [ordered]@{
        parsed                = ConvertFrom-QUser $quserRaw
        rdpEnabled            = if ($ts) { $ts.fDenyTSConnections -eq 0 } else { $null }
        singleSessionPerUser  = if ($ts -and ($ts.PSObject.Properties.Name -contains 'fSingleSessionPerUser')) { $ts.fSingleSessionPerUser } else { $null }
        policyMaxConnections  = if ($tsPolicy -and ($tsPolicy.PSObject.Properties.Name -contains 'MaxInstanceCount')) { $tsPolicy.MaxInstanceCount } else { $null }
        rdsRoleInstalled      = [bool](Get-Service -Name 'TermServLicensing', 'Tssdis' -ErrorAction SilentlyContinue)
        recentLogons          = @(
            try {
                Get-WinEvent -FilterHashtable @{
                    LogName   = 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational'
                    Id        = 21, 23, 24, 25
                    StartTime = (Get-Date).AddHours(-$EventLookbackHours)
                } -MaxEvents 100 -ErrorAction Stop | ForEach-Object {
                    [ordered]@{ time = $_.TimeCreated.ToString('o'); id = $_.Id; message = ($_.Message -split "`r?`n" | Where-Object { $_ } ) -join ' | ' }
                }
            } catch { @() }
        )
    }
}

# ---------------------------------------------------------------------------
# 3. Installed programs (registry)
# ---------------------------------------------------------------------------
Invoke-Section 'installedPrograms' {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $all = foreach ($k in $keys) {
        Get-ItemProperty $k -ErrorAction SilentlyContinue | Where-Object { $_.PSObject.Properties.Name -contains 'DisplayName' -and $_.DisplayName }
    }
    $all | Select-Object DisplayName, DisplayVersion, Publisher, InstallDate, InstallLocation |
        Sort-Object DisplayName | Export-Csv (Join-Path $RawDir 'installed-programs-all.csv') -NoTypeInformation
    @($all | Where-Object { ($_.DisplayName -match $Pattern) -or ("$($_.Publisher)" -match $Pattern) } |
        Sort-Object DisplayName | ForEach-Object {
            [ordered]@{
                name            = $_.DisplayName
                version         = "$($_.DisplayVersion)"
                publisher       = "$($_.Publisher)"
                installDate     = "$($_.InstallDate)"
                installLocation = "$($_.InstallLocation)"
            }
        })
}

# ---------------------------------------------------------------------------
# 4. File versions under TFG install roots
# ---------------------------------------------------------------------------
Invoke-Section 'fileVersions' {
    $files = foreach ($r in $Roots) {
        Get-ChildItem -LiteralPath $r -Recurse -File -Include *.exe, *.dll -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -eq '.exe' -or $_.Name -match $Pattern -or $_.Name -match '^(TFG|Store|POS)' }
    }
    @($files | ForEach-Object {
            $vi = $_.VersionInfo
            [ordered]@{
                path           = $_.FullName
                fileVersion    = "$($vi.FileVersion)"
                productVersion = "$($vi.ProductVersion)"
                productName    = "$($vi.ProductName)"
                company        = "$($vi.CompanyName)"
                lastWriteTime  = $_.LastWriteTime.ToString('o')
            }
        })
}

# ---------------------------------------------------------------------------
# 5. Windows services
# ---------------------------------------------------------------------------
Invoke-Section 'services' {
    $svcs = Get-CimInstance Win32_Service | Where-Object {
        $_.Name -match $Pattern -or $_.DisplayName -match $Pattern -or "$($_.PathName)" -match $Pattern -or "$($_.PathName)" -match '\\TFG\\'
    }
    @($svcs | Sort-Object DisplayName | ForEach-Object {
            $started = $null
            if ($_.ProcessId -gt 0) {
                try { $started = (Get-Process -Id $_.ProcessId -ErrorAction Stop).StartTime.ToString('o') } catch { }
            }
            $exeVersion = $null
            $exe = [regex]::Match("$($_.PathName)", '^\s*"?(?<p>[^"]+?\.exe)').Groups['p'].Value
            if ($exe -and (Test-Path -LiteralPath $exe)) { $exeVersion = (Get-Item -LiteralPath $exe).VersionInfo.FileVersion }
            [ordered]@{
                name          = $_.Name
                displayName   = $_.DisplayName
                state         = $_.State
                startMode     = $_.StartMode
                delayedStart  = $_.DelayedAutoStart
                account       = $_.StartName
                path          = Protect-Secrets "$($_.PathName)"
                exeVersion    = $exeVersion
                processStart  = $started
                description   = $_.Description
            }
        })
}

# ---------------------------------------------------------------------------
# 6. MDD folder
# ---------------------------------------------------------------------------
Invoke-Section 'mddFolder' {
    if (-not (Test-Path -LiteralPath $MddFolder)) {
        return [ordered]@{ exists = $false; path = $MddFolder }
    }
    $items = Get-ChildItem -LiteralPath $MddFolder -Recurse -Force -ErrorAction SilentlyContinue
    $listing = @($items | ForEach-Object {
            [ordered]@{
                path          = $_.FullName.Substring($MddFolder.Length).TrimStart('\')
                isDir         = $_.PSIsContainer
                size          = if ($_.PSIsContainer) { $null } else { $_.Length }
                lastWriteTime = $_.LastWriteTime.ToString('o')
                version       = if (-not $_.PSIsContainer -and $_.Extension -in '.exe', '.dll') { $_.VersionInfo.FileVersion } else { $null }
            }
        })

    $configDir = Join-Path $RawDir 'mdd-config'
    $logDir = Join-Path $RawDir 'mdd-logs'
    New-Item -ItemType Directory -Path $configDir, $logDir -Force | Out-Null

    $configs = @($items | Where-Object { -not $_.PSIsContainer -and $_.Extension -in '.config', '.json', '.xml', '.ini', '.settings' })
    foreach ($c in $configs) {
        $safeName = ($c.FullName.Substring($MddFolder.Length).TrimStart('\') -replace '[\\/:]', '_')
        Read-TextSafe $c.FullName | Set-Content -LiteralPath (Join-Path $configDir $safeName)
    }

    $logs = @($items | Where-Object { -not $_.PSIsContainer -and $_.Extension -in '.log', '.txt', '.csv' } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 8)
    foreach ($lf in $logs) {
        $safeName = ($lf.FullName.Substring($MddFolder.Length).TrimStart('\') -replace '[\\/:]', '_')
        Read-TextSafe $lf.FullName -TailLines 300 | Set-Content -LiteralPath (Join-Path $logDir $safeName)
    }

    # Also look for logs written elsewhere (e.g. ProgramData) by the MDD services
    $otherLogs = @()
    foreach ($p in @('C:\ProgramData\TFG', 'C:\Logs', 'C:\TFG', 'D:\Logs')) {
        if (Test-Path -LiteralPath $p) {
            $otherLogs += Get-ChildItem -LiteralPath $p -Recurse -File -Include *.log, *.txt -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 20 |
                ForEach-Object { [ordered]@{ path = $_.FullName; size = $_.Length; lastWriteTime = $_.LastWriteTime.ToString('o') } }
        }
    }

    [ordered]@{
        exists         = $true
        path           = $MddFolder
        listing        = $listing
        configFiles    = @($configs | ForEach-Object { $_.FullName })
        newestLogFiles = @($logs | ForEach-Object { [ordered]@{ path = $_.FullName; lastWriteTime = $_.LastWriteTime.ToString('o'); size = $_.Length } })
        otherLogFiles  = $otherLogs
    }
}

# ---------------------------------------------------------------------------
# 7. Event logs
# ---------------------------------------------------------------------------
Invoke-Section 'eventLogs' {
    $since = (Get-Date).AddHours(-$EventLookbackHours)
    $app = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $since } -MaxEvents 5000 -ErrorAction SilentlyContinue |
            Where-Object { $_.ProviderName -match $Pattern -or ($_.LevelDisplayName -in 'Error', 'Critical' -and "$($_.Message)" -match $Pattern) } |
            Select-Object -First 300)
    # 7036 = state change, 7031/7034 = unexpected termination, 7000/7009 = failed to start
    $scm = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager'; Id = 7000, 7009, 7031, 7034, 7036; StartTime = $since } -MaxEvents 3000 -ErrorAction SilentlyContinue |
            Where-Object { "$($_.Message)" -match $Pattern } | Select-Object -First 300)
    $toObj = { param($e) [ordered]@{ time = $e.TimeCreated.ToString('o'); provider = $e.ProviderName; id = $e.Id; level = $e.LevelDisplayName; message = Protect-Secrets ("$($e.Message)".Substring(0, [Math]::Min(2000, "$($e.Message)".Length))) } }
    [ordered]@{
        lookbackHours     = $EventLookbackHours
        application       = @($app | ForEach-Object { & $toObj $_ })
        serviceControl    = @($scm | ForEach-Object { & $toObj $_ })
        applicationSources = @($app | Group-Object ProviderName | ForEach-Object { [ordered]@{ source = $_.Name; count = $_.Count } })
    }
}

# ---------------------------------------------------------------------------
# 8. Scheduled tasks pointing at TFG
# ---------------------------------------------------------------------------
Invoke-Section 'scheduledTasks' {
    @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
            ($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' ' -match $Pattern -or $_.TaskName -match $Pattern
        } | ForEach-Object {
            $info = $null
            try { $info = $_ | Get-ScheduledTaskInfo -ErrorAction Stop } catch { }
            [ordered]@{
                name           = $_.TaskName
                path           = $_.TaskPath
                state          = "$($_.State)"
                actions        = @($_.Actions | ForEach-Object { Protect-Secrets "$($_.Execute) $($_.Arguments)" })
                lastRunTime    = if ($info) { "$($info.LastRunTime)" } else { $null }
                lastTaskResult = if ($info) { $info.LastTaskResult } else { $null }
                nextRunTime    = if ($info) { "$($info.NextRunTime)" } else { $null }
            }
        })
}

# ---------------------------------------------------------------------------
# 9. Candidate configuration values (country / branch / store / environment)
# ---------------------------------------------------------------------------
Invoke-Section 'configCandidates' {
    $hits = @()
    foreach ($r in $Roots) {
        $files = Get-ChildItem -LiteralPath $r -Recurse -File -Include *.config, *.json, *.xml, *.ini -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -lt $MaxFileBytesToRead -and $_.Name -notmatch '\.(deps|runtimeconfig)\.json$' }
        foreach ($f in $files) {
            $n = 0
            try {
                foreach ($line in [IO.File]::ReadLines($f.FullName)) {
                    $n++
                    if ($line -match $ConfigKeyPattern -and $line.Length -lt 1000) {
                        $hits += [ordered]@{ file = $f.FullName; line = $n; text = (Protect-Secrets $line.Trim()) }
                    }
                }
            }
            catch { $hits += [ordered]@{ file = $f.FullName; error = $_.Exception.Message } }
        }
    }
    # Registry: anything TFG-owned
    $reg = @()
    foreach ($k in 'HKLM:\SOFTWARE\TFG', 'HKLM:\SOFTWARE\WOW6432Node\TFG', 'HKLM:\SOFTWARE\Foschini', 'HKLM:\SOFTWARE\WOW6432Node\Foschini') {
        if (Test-Path $k) {
            Get-ChildItem $k -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
                if ($props) {
                    foreach ($p in $props.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' }) {
                        $reg += [ordered]@{ key = $_.Name; name = $p.Name; value = (Protect-Secrets "$($p.Value)") }
                    }
                }
            }
        }
    }
    [ordered]@{
        roots        = @($Roots)
        fileMatches  = @($hits | Select-Object -First 2000)
        registry     = $reg
    }
}

# ---------------------------------------------------------------------------
# 10. Machine health
# ---------------------------------------------------------------------------
Invoke-Section 'health' {
    $pending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
               (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
    [ordered]@{
        cpuLoadPercent = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
        disks          = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType = 3' | ForEach-Object {
                [ordered]@{ drive = $_.DeviceID; sizeGb = [math]::Round($_.Size / 1GB, 1); freeGb = [math]::Round($_.FreeSpace / 1GB, 1) }
            })
        pendingReboot  = $pending
    }
}

# ---------------------------------------------------------------------------
# 11. SQL Server (optional, read-only metadata)
# ---------------------------------------------------------------------------
Invoke-Section 'sql' {
    $instances = @(Get-Service -Name 'MSSQL*' -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'MSSQLSERVER' -or $_.Name -like 'MSSQL$*' } |
            ForEach-Object { [ordered]@{ service = $_.Name; status = "$($_.Status)"; instance = if ($_.Name -eq 'MSSQLSERVER') { '.' } else { '.\' + $_.Name.Substring(6) } } })
    $probe = @()
    if ($IncludeSqlProbe) {
        foreach ($i in $instances | Where-Object { $_.status -eq 'Running' }) {
            $entry = [ordered]@{ instance = $i.instance; databases = @(); changeTracking = @(); candidateTables = @(); error = $null }
            try {
                $cn = New-Object System.Data.SqlClient.SqlConnection ("Server={0};Integrated Security=SSPI;Connect Timeout=5;Application Name=LabDiscovery;ApplicationIntent=ReadOnly" -f $i.instance)
                $cn.Open()
                $q = {
                    param($sql)
                    $cmd = $cn.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 30
                    $rdr = $cmd.ExecuteReader(); $rows = @()
                    while ($rdr.Read()) { $row = [ordered]@{}; for ($c = 0; $c -lt $rdr.FieldCount; $c++) { $row[$rdr.GetName($c)] = "$($rdr.GetValue($c))" }; $rows += $row }
                    $rdr.Close(); , $rows
                }
                $entry.databases = & $q "SELECT name, state_desc, create_date FROM sys.databases ORDER BY name"
                $entry.changeTracking = & $q "SELECT DB_NAME(database_id) AS db, is_auto_cleanup_on, retention_period, retention_period_units_desc FROM sys.change_tracking_databases"
                foreach ($db in $entry.databases | Where-Object { $_.state_desc -eq 'ONLINE' -and $_.name -notin 'master', 'model', 'msdb', 'tempdb' }) {
                    $dbName = $db.name.Replace(']', ']]')
                    try {
                        $entry.candidateTables += & $q (("SELECT '{0}' AS db, s.name AS [schema], t.name AS [table], SUM(p.rows) AS [rows], MAX(us.last_user_update) AS lastUserUpdate " +
                            "FROM [{1}].sys.tables t JOIN [{1}].sys.schemas s ON s.schema_id = t.schema_id " +
                            "JOIN [{1}].sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1) " +
                            "LEFT JOIN sys.dm_db_index_usage_stats us ON us.object_id = t.object_id AND us.database_id = DB_ID('{0}') " +
                            "WHERE t.name LIKE '%Queue%' OR t.name LIKE '%Import%' OR t.name LIKE '%ChangeTrack%' OR t.name LIKE '%Sync%' OR t.name LIKE '%Log%' OR t.name LIKE '%Batch%' OR t.name LIKE '%Version%' " +
                            "GROUP BY s.name, t.name") -f $db.name.Replace("'", "''"), $dbName)
                    }
                    catch { $entry.candidateTables += [ordered]@{ db = $db.name; error = $_.Exception.Message } }
                }
                $cn.Close()
            }
            catch { $entry.error = $_.Exception.Message }
            $probe += $entry
        }
    }
    [ordered]@{ instances = $instances; probed = [bool]$IncludeSqlProbe; probe = $probe }
}

# ---------------------------------------------------------------------------
# Write output
# ---------------------------------------------------------------------------
$jsonPath = Join-Path $RunDir 'discovery.json'
$Result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

$s = $Result.sections
$summary = New-Object System.Text.StringBuilder
[void]$summary.AppendLine("POS Lab Discovery - $($Result.machine) - $($Result.collectedAt)")
[void]$summary.AppendLine("Elevated: $($Result.elevated)")
if ($s.Contains('machine')) { [void]$summary.AppendLine("OS: $($s.machine.osCaption) (ProductType $($s.machine.osProductType)), uptime $($s.machine.uptimeMinutes) min") }
if ($s.Contains('sessions')) { [void]$summary.AppendLine("Sessions: " + (@($s.sessions.parsed | ForEach-Object { if ($_.Contains('user')) { "$($_.user) [$($_.state)]" } }) -join ', ')) }
if ($s.Contains('installedPrograms')) { [void]$summary.AppendLine("`nInstalled programs (matching):"); $s.installedPrograms | ForEach-Object { [void]$summary.AppendLine("  $($_.name)  $($_.version)") } }
if ($s.Contains('services')) { [void]$summary.AppendLine("`nServices (matching):"); $s.services | ForEach-Object { [void]$summary.AppendLine("  [$($_.state)] $($_.displayName) ($($_.name)) $($_.exeVersion)") } }
if ($s.Contains('mddFolder')) { [void]$summary.AppendLine("`nMDD folder exists: $($s.mddFolder.exists)") }
if ($Result.errors.Count) { [void]$summary.AppendLine("`nErrors:"); $Result.errors.GetEnumerator() | ForEach-Object { [void]$summary.AppendLine("  $($_.Key): $($_.Value)") } }
$summary.ToString() | Set-Content -LiteralPath (Join-Path $RunDir 'summary.txt') -Encoding UTF8

$zip = "$RunDir.zip"
try { Compress-Archive -Path (Join-Path $RunDir '*') -DestinationPath $zip -Force } catch { $zip = $null }

Write-Host ''
Write-Host $summary.ToString()
Write-Host "Results folder: $RunDir"
if ($zip) { Write-Host "Zip:            $zip" }
Write-Host 'Please review the output for anything sensitive before sharing.'
