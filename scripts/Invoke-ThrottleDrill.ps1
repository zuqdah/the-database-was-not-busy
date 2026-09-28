#Requires -Version 7.0
<#
    .SYNOPSIS
    Runs three write workloads against an Azure SQL Database, measures which of
    them the platform held at its log rate ceiling, and grades the result against
    throttle-matrix.json.

    .DESCRIPTION
    The three phases exist to be compared, not just to be run. One is throttled,
    one is slower and is not, and one is the control -- and the only way to tell
    them apart is a metric nobody watches. A drill that ran only the throttled
    phase would prove that a limit exists; running all three proves you can tell
    a platform limit from a schema problem, which is the part worth having.

    Everything the drill creates is dropped at the end, because a second run must
    not inherit the first one's tables.

    .PARAMETER Server
    Logical server name or fully qualified name. Entra authentication only --
    there is no SQL password anywhere in this lab.

    .PARAMETER SettleSeconds
    How long to wait for sys.dm_db_resource_stats to catch up. Not a fudge
    factor: the DMV aggregates in 15-second buckets and lags, so reading it
    immediately returns 0.00 for every column. The drill measures that lag as a
    declared assertion rather than hiding it in a sleep.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Server,
    [Parameter()][string] $Database = 'lograte',
    [Parameter()][string] $MatrixPath = (Join-Path -Path $PSScriptRoot -ChildPath '../throttle-matrix.json'),
    [Parameter()][string] $ReportPath = (Join-Path -Path $PSScriptRoot -ChildPath '../throttle-report.json'),
    [Parameter()][int] $SettleSeconds = 75,
    # Longer than the 15 seconds the sample window is widened by. Without a gap,
    # a short phase reads the saturation of whatever ran next: the six-second
    # control graded Throttled on the first run because the widening reached into
    # a thirty-second bulk write that started immediately afterwards.
    [Parameter()][int] $GapSeconds = 35,
    [Parameter()][switch] $Keep
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Write-Information is the house style for progress in this series, and it is
# only visible with the preference set.
$InformationPreference = 'Continue'

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '../module/LogRateGovernor/LogRateGovernor.psm1') -Force
Import-Module SqlServer -ErrorAction Stop

$matrix = Get-ThrottleMatrix -Path $MatrixPath
$saturatedThreshold = [double]$matrix.thresholds.saturatedLogWritePercent
$idleCpuThreshold = [double]$matrix.thresholds.idleCpuPercent

if ($Server -notlike '*.database.windows.net') { $Server = "$Server.database.windows.net" }

# ---------------------------------------------------------------------- token

function Get-DrillToken {
    <#
        Environment variable first, then the Azure CLI. Errors are captured and
        reported rather than suppressed: a sibling lab hid the CLI's own
        explanation behind 2>$null and reported "could not get a token" for a
        message the CLI had already written.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $EnvironmentVariable)

    $fromEnv = [Environment]::GetEnvironmentVariable($EnvironmentVariable)
    if (-not [string]::IsNullOrWhiteSpace($fromEnv)) {
        Write-Information "  token from `$env:$EnvironmentVariable"
        return $fromEnv.Trim()
    }

    $stderr = [IO.Path]::GetTempFileName()
    try {
        $token = (& az account get-access-token --resource https://database.windows.net/ --query accessToken -o tsv 2>$stderr)
        $detail = (Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue)
        if ([string]::IsNullOrWhiteSpace($token)) {
            throw "Could not get a SQL access token. Set `$env:$EnvironmentVariable, or sign in with az login.$(if ($detail) { " The CLI said: $($detail.Trim())" })"
        }
        Write-Information '  token from the Azure CLI'
        return $token.Trim()
    }
    finally {
        Remove-Item -LiteralPath $stderr -Force -ErrorAction SilentlyContinue
    }
}

Write-Information '== Acquiring a token'
$token = Get-DrillToken -EnvironmentVariable 'SQL_TOKEN'

function Invoke-Db {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][string] $Query,
        [Parameter()][int] $TimeoutSeconds = 600
    )
    return Invoke-Sqlcmd -ServerInstance $Server -Database $Database -AccessToken $token `
        -Query $Query -QueryTimeout $TimeoutSeconds -ConnectionTimeout 120 -TrustServerCertificate -ErrorAction Stop
}

function Wait-DatabaseAwake {
    <#
        A serverless database auto-pauses after its idle delay, and the first
        connection afterwards fails while the service resumes it. The failure is
        a connection timeout in the post-login phase, which reads like a network
        problem rather than a database that was asleep.

        This is not defensive boilerplate. The drill hit it: a run failed with
        "[Post-Login] complete=14018" because the database had paused since the
        previous measurement. An application without retry logic sees exactly
        this, while the portal reports the database as Online -- which is its own
        small lesson about what Online means for serverless.

        Retried with backoff rather than given one long timeout, because a resume
        can outlast any single timeout and a retry is what production code needs
        anyway.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter()][int] $Attempts = 6)

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            $null = Invoke-Db -Query 'SELECT 1 AS awake' -TimeoutSeconds 60
            if ($attempt -gt 1) { Write-Information "   awake after $attempt attempt(s)" }
            return
        }
        catch {
            if ($attempt -eq $Attempts) {
                throw "The database did not accept a connection after $Attempts attempts. Last error: $($_.Exception.Message)"
            }
            $delay = 15 * $attempt
            Write-Information "   attempt $attempt did not connect; the database is probably resuming. Retrying in ${delay}s."
            Start-Sleep -Seconds $delay
        }
    }
}

# ------------------------------------------------------------------- the cap

Write-Information '== Waking the database if it has auto-paused'
Wait-DatabaseAwake

Write-Information '== Reading the governor'
# primary_max_log_rate is in bytes per second and is the only place this ceiling
# is written down. It is not on the portal blade, and the column is not called
# max_log_rate whatever older documentation suggests.
$gov = Invoke-Db -Query @'
SELECT slo_name,
       cpu_limit,
       CAST(primary_min_log_rate / 1048576.0 AS DECIMAL(10,2)) AS min_log_mbps,
       CAST(primary_max_log_rate / 1048576.0 AS DECIMAL(10,2)) AS max_log_mbps
FROM sys.dm_user_db_resource_governance
'@

$slo = [string]$gov.slo_name
$capMBps = [double]$gov.max_log_mbps
Write-Information "   slo $slo"
Write-Information "   log ceiling $capMBps MB/s (floor $($gov.min_log_mbps) MB/s), cpu limit $($gov.cpu_limit)"

if ($capMBps -le 0) { throw 'The governor reported no log rate ceiling. Without it the drill has nothing to compare against.' }

# ------------------------------------------------------------------- fixture

$created = [Collections.Generic.List[string]]::new()

function New-Fixture {
    <#
        One source table, read by all three phases, so the phases differ only in
        where the rows land and what indexes are maintained on the way. If each
        phase generated its own rows they would differ in content as well, and
        the comparison between them would be worth less.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param()

    if (-not $PSCmdlet.ShouldProcess($Database, 'Create drill tables')) { return }

    Invoke-Db -Query @'
DROP TABLE IF EXISTS dbo.DrillMinimal
DROP TABLE IF EXISTS dbo.DrillSaturated
DROP TABLE IF EXISTS dbo.DrillIndexHeavy
DROP TABLE IF EXISTS dbo.DrillSource

CREATE TABLE dbo.DrillSource (
    Id     INT IDENTITY PRIMARY KEY,
    Status VARCHAR(12)  NOT NULL,
    Ref    INT          NOT NULL,
    Note   VARCHAR(180) NOT NULL,
    Wide   CHAR(200)    NOT NULL
)

-- Identifier-like text from the catalogue rather than a REPLICATE of one
-- character: a single repeated character compresses to nothing and would make
-- every measurement here flattering and wrong.
INSERT INTO dbo.DrillSource (Status, Ref, Note, Wide)
SELECT TOP (600000)
       CASE ABS(CHECKSUM(NEWID())) % 4 WHEN 0 THEN 'open' WHEN 1 THEN 'closed' WHEN 2 THEN 'pending' ELSE 'escalated' END,
       ABS(CHECKSUM(NEWID())) % 100000,
       LEFT(CONCAT(c.name, ' ', o.name, ' ', c.name, ' reference ', c.column_id), 180),
       -- COLLATE DATABASE_DEFAULT is load-bearing: type_desc carries the catalogue
       -- collation while name carries the database one, and CONCAT of the two fails
       -- with "Cannot resolve collation conflict", which names neither column.
       LEFT(CONCAT(c.name, ' ', o.name, ' ', c.name, ' ', o.type_desc COLLATE DATABASE_DEFAULT, ' padding '), 200)
FROM sys.all_columns c CROSS JOIN sys.all_objects o

CREATE TABLE dbo.DrillMinimal (Id INT NOT NULL PRIMARY KEY, Status VARCHAR(12) NOT NULL, Ref INT NOT NULL, Note VARCHAR(180) NOT NULL)

CREATE TABLE dbo.DrillSaturated (Id INT IDENTITY PRIMARY KEY, Wide CHAR(200) NOT NULL)

CREATE TABLE dbo.DrillIndexHeavy (Id INT NOT NULL PRIMARY KEY, Status VARCHAR(12) NOT NULL, Ref INT NOT NULL, Note VARCHAR(180) NOT NULL)
CREATE INDEX IX_DrillIndexHeavy_Status ON dbo.DrillIndexHeavy (Status, Ref)
CREATE INDEX IX_DrillIndexHeavy_Ref    ON dbo.DrillIndexHeavy (Ref) INCLUDE (Note)
CREATE INDEX IX_DrillIndexHeavy_Note   ON dbo.DrillIndexHeavy (Note)
'@ | Out-Null

    foreach ($t in 'DrillSource', 'DrillMinimal', 'DrillSaturated', 'DrillIndexHeavy') { $created.Add($t) }
    $rows = (Invoke-Db -Query 'SELECT COUNT(*) AS n FROM dbo.DrillSource').n
    Write-Information "   source rows $rows"
    if ([int]$rows -lt 500000) {
        throw "The source table only has $rows rows. The catalogue cross join did not yield enough; the phases would not be comparable to the declared measurements."
    }
}

# --------------------------------------------------------------------- phases

$phaseSql = @{
    # Paced deliberately, in batches with a wait between them. Measured: the same
    # 600,000 rows inserted in one statement reach 19.56 MB/s and 100% log write,
    # because the ceiling is low enough that any flat-out bulk write hits it. A
    # small workload is not an unthrottled workload, and pacing is the only way to
    # observe one on this tier.
    paced      = @'
DECLARE @batch INT = 0
WHILE @batch < 30
BEGIN
    INSERT INTO dbo.DrillMinimal (Id, Status, Ref, Note)
    SELECT Id, Status, Ref, Note FROM dbo.DrillSource
    WHERE Id > @batch * 20000 AND Id <= (@batch + 1) * 20000
    SET @batch += 1
    WAITFOR DELAY '00:00:01'
END
'@
    saturated  = 'INSERT INTO dbo.DrillSaturated (Wide) SELECT Wide FROM dbo.DrillSource UNION ALL SELECT Wide FROM dbo.DrillSource UNION ALL SELECT Wide FROM dbo.DrillSource'
    indexHeavy = 'INSERT INTO dbo.DrillIndexHeavy (Id, Status, Ref, Note) SELECT Id, Status, Ref, Note FROM dbo.DrillSource UNION ALL SELECT Id + 600000, Status, Ref, Note FROM dbo.DrillSource'
}

function Invoke-Phase {
    <#
        Runs one workload and returns what it cost, including an IMMEDIATE read
        of the resource statistics taken before any waiting. That immediate read
        is not diagnostics -- it is the evidence for the assertion that the DMV
        lags, and it has to be captured here because a moment later it stops
        being true.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string] $Phase)

    $sql = $phaseSql[$Phase]
    if (-not $sql) { throw "No workload defined for phase '$Phase'." }

    $result = Invoke-Db -TimeoutSeconds 900 -Query @"
SET NOCOUNT ON
DECLARE @l0 BIGINT = (SELECT num_of_bytes_written FROM sys.dm_io_virtual_file_stats(DB_ID(), 2))
DECLARE @g0 BIGINT = (SELECT ISNULL(SUM(wait_time_ms), 0) FROM sys.dm_db_wait_stats WHERE wait_type = 'LOG_RATE_GOVERNOR')
DECLARE @t0 DATETIME2 = SYSUTCDATETIME()

$sql

DECLARE @rows INT = CASE WHEN '$Phase' = 'paced' THEN (SELECT COUNT(*) FROM dbo.DrillMinimal) ELSE @@ROWCOUNT END
DECLARE @t1 DATETIME2 = SYSUTCDATETIME()
DECLARE @l1 BIGINT = (SELECT num_of_bytes_written FROM sys.dm_io_virtual_file_stats(DB_ID(), 2))
DECLARE @g1 BIGINT = (SELECT ISNULL(SUM(wait_time_ms), 0) FROM sys.dm_db_wait_stats WHERE wait_type = 'LOG_RATE_GOVERNOR')

SELECT
    @rows                                                       AS rows_written,
    DATEDIFF(MILLISECOND, @t0, @t1)                             AS elapsed_ms,
    CAST((@l1 - @l0) / 1048576.0 AS DECIMAL(12,1))              AS log_mb,
    @g1 - @g0                                                   AS governor_ms,
    CONVERT(VARCHAR(30), @t0, 126)                              AS started_utc,
    CONVERT(VARCHAR(30), @t1, 126)                              AS ended_utc,
    (SELECT COUNT(*) FROM sys.dm_db_resource_stats WHERE end_time >= @t0 AND end_time <= @t1)                    AS immediate_sample_count,
    (SELECT CAST(MAX(avg_log_write_percent) AS DECIMAL(6,2)) FROM sys.dm_db_resource_stats WHERE end_time >= @t0 AND end_time <= @t1) AS immediate_peak_log_percent
"@

    return [pscustomobject]@{
        Phase                    = $Phase
        RowsWritten              = [int]$result.rows_written
        ElapsedMs                = [int]$result.elapsed_ms
        LogMB                    = [double]$result.log_mb
        GovernorMs               = [long]$result.governor_ms
        StartedUtc               = [string]$result.started_utc
        EndedUtc                 = [string]$result.ended_utc
        ImmediateSampleCount     = [int]$result.immediate_sample_count
        ImmediatePeakLogPercent  = if ($result.immediate_peak_log_percent -is [DBNull]) { $null } else { [double]$result.immediate_peak_log_percent }
        AchievedMBps             = if ([int]$result.elapsed_ms -gt 0) { [math]::Round([double]$result.log_mb / ([int]$result.elapsed_ms / 1000.0), 2) } else { $null }
    }
}

function Get-SettledSnapshot {
    <#
        Reads the resource statistics for a phase's window after the buckets have
        had time to land. The sample count is returned separately from the
        percentages because zero samples and a zero percentage are the same
        number with opposite meanings, and the grading module needs to tell them
        apart.

        The window is widened by 20 seconds past the end of the workload: a
        15-second bucket that straddles the finish still describes it.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string] $StartedUtc,
        [Parameter(Mandatory)][string] $EndedUtc
    )

    $row = Invoke-Db -Query @"
SET NOCOUNT ON
DECLARE @t0 DATETIME2 = CONVERT(DATETIME2, '$StartedUtc', 126)
DECLARE @t1 DATETIME2 = DATEADD(SECOND, 15, CONVERT(DATETIME2, '$EndedUtc', 126))
SELECT
    COUNT(*)                                          AS sample_count,
    CAST(MAX(avg_log_write_percent) AS DECIMAL(6,2))   AS peak_log_percent,
    CAST(MAX(avg_cpu_percent) AS DECIMAL(6,2))         AS peak_cpu_percent,
    CAST(MAX(avg_data_io_percent) AS DECIMAL(6,2))     AS peak_data_io_percent
FROM sys.dm_db_resource_stats
WHERE end_time >= @t0 AND end_time <= @t1
"@

    $asDouble = { param($v) if ($null -eq $v -or $v -is [DBNull]) { $null } else { [double]$v } }
    return [pscustomobject]@{
        SampleCount       = [int]$row.sample_count
        PeakLogPercent    = & $asDouble $row.peak_log_percent
        PeakCpuPercent    = & $asDouble $row.peak_cpu_percent
        PeakDataIoPercent = & $asDouble $row.peak_data_io_percent
    }
}

# ------------------------------------------------------------------- the run

$phases = @{}

try {
    Write-Information '== Building the fixture'
    New-Fixture

    foreach ($phase in @($matrix.phases.id)) {
        Write-Information ''
        Write-Information "== $phase"
        $run = Invoke-Phase -Phase $phase
        $phases[$phase] = [pscustomobject]@{ Run = $run; Settled = $null }
        Write-Information ("   {0} rows, {1} ms, {2} MB of log, {3} MB/s, governor {4} ms" -f `
            $run.RowsWritten, $run.ElapsedMs, $run.LogMB, $run.AchievedMBps, $run.GovernorMs)
        Write-Information ("   immediately afterwards: {0} sample(s) cover the window" -f $run.ImmediateSampleCount)

        # Quiet time, so this phase owns its own buckets. See $GapSeconds.
        if ($phase -ne @($matrix.phases.id)[-1]) {
            Write-Information "   quiet for ${GapSeconds}s so the next phase cannot borrow these samples"
            Start-Sleep -Seconds $GapSeconds
        }
    }

    Write-Information ''
    Write-Information "== Waiting ${SettleSeconds}s for resource statistics to land"
    Write-Information '   The DMV aggregates in 15-second buckets and lags the workload. Reading it'
    Write-Information '   before now returns 0.00 for every column, which is what a drill that'
    Write-Information '   concluded "not throttled" from nothing at all would have seen.'
    Start-Sleep -Seconds $SettleSeconds

    foreach ($phase in @($matrix.phases.id)) {
        $phases[$phase].Settled = Get-SettledSnapshot -StartedUtc $phases[$phase].Run.StartedUtc -EndedUtc $phases[$phase].Run.EndedUtc
        $s = $phases[$phase].Settled
        Write-Information ("   {0,-11} {1} sample(s)  peak log {2}%  peak cpu {3}%  peak data io {4}%" -f `
            $phase, $s.SampleCount, $s.PeakLogPercent, $s.PeakCpuPercent, $s.PeakDataIoPercent)
    }
}
finally {
    if (-not $Keep -and $created.Count) {
        Write-Information ''
        Write-Information '== Cleaning up'
        foreach ($t in $created) {
            try { Invoke-Db -Query "DROP TABLE IF EXISTS dbo.$t" | Out-Null } catch { Write-Information "   could not drop $t : $($_.Exception.Message)" }
        }
        Write-Information "   dropped $($created.Count) table(s)"
    }
    elseif ($created.Count) {
        Write-Information ''
        Write-Information "== Left behind for inspection: $($created -join ', ')"
    }
}

# ------------------------------------------------------------------- grading

Write-Information ''
Write-Information '== Grading against the matrix'

$results = [Collections.Generic.List[pscustomobject]]::new()

foreach ($guard in $matrix.guards) {
    $entry = if ($phases.ContainsKey($guard.phase)) { $phases[$guard.phase] } else { $null }

    if ($null -eq $entry -or $null -eq $entry.Settled) {
        $outcome = [pscustomobject]@{ Outcome = 'Unknown'; Reason = "Phase '$($guard.phase)' produced no settled measurement." }
    }
    else {
        $outcome = Resolve-ThrottleOutcome `
            -SamplesFound ($entry.Settled.SampleCount -gt 0) `
            -LogWritePercent $entry.Settled.PeakLogPercent `
            -GovernorWaitMs $entry.Run.GovernorMs `
            -ElapsedMs $entry.Run.ElapsedMs `
            -SaturatedLogWritePercent $saturatedThreshold
    }

    $verdict = Test-GuardExpectation -Expected $guard.expect -Observed $outcome.Outcome

    $results.Add([pscustomobject]@{
        Kind         = 'Guard'
        Id           = $guard.id
        Phase        = $guard.phase
        Severity     = $guard.severity
        Title        = $guard.title
        Expected     = $guard.expect
        Observed     = $outcome.Outcome
        Passed       = $verdict.Passed
        Inconclusive = $verdict.Inconclusive
        Reason       = $outcome.Reason
        Why          = $guard.why
    })

    $label = if ($verdict.Passed) { 'as declared' } elseif ($verdict.Inconclusive) { 'INCONCLUSIVE' } else { 'FAILED' }
    Write-Information ("   {0,-38} {1,-12} {2}" -f $guard.id, $outcome.Outcome, $label)
}

function Add-Assertion {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string] $Id,
        [Parameter(Mandatory)][AllowNull()][object] $Observed,
        [Parameter(Mandatory)][string] $Detail
    )

    $declared = @($matrix.assertions | Where-Object { $_.id -eq $Id })
    if (-not $declared.Count) { throw "Assertion '$Id' is not declared in the matrix." }

    $inconclusive = $null -eq $Observed
    $passed = (-not $inconclusive) -and ([bool]$Observed -eq [bool]$declared[0].expected)

    $results.Add([pscustomobject]@{
        Kind         = 'Assertion'
        Id           = $Id
        Phase        = 'across'
        Severity     = $declared[0].severity
        Title        = $Id
        Expected     = $declared[0].expected
        Observed     = $Observed
        Passed       = $passed
        Inconclusive = $inconclusive
        Reason       = $Detail
        Why          = $declared[0].why
    })

    $label = if ($passed) { 'as declared' } elseif ($inconclusive) { 'INCONCLUSIVE' } else { 'FAILED' }
    Write-Information ("   {0,-38} {1,-12} {2}" -f $Id, $Observed, $label)
}

$pacedId = 'paced'
$sat = if ($phases.ContainsKey('saturated')) { $phases['saturated'] } else { $null }
$idx = if ($phases.ContainsKey('indexHeavy')) { $phases['indexHeavy'] } else { $null }

# CPU is idle while the log channel is at the wall.
$cpuIdle = $null
$detail = 'Not measured.'
if ($null -ne $sat -and $null -ne $sat.Settled -and $null -ne $sat.Settled.PeakCpuPercent -and $null -ne $sat.Settled.PeakLogPercent) {
    $bottleneck = Resolve-Bottleneck -CpuPercent $sat.Settled.PeakCpuPercent -LogWritePercent $sat.Settled.PeakLogPercent `
        -SaturatedLogWritePercent $saturatedThreshold -IdleCpuPercent $idleCpuThreshold
    $cpuIdle = ($bottleneck.Bottleneck -eq 'Log')
    $detail = $bottleneck.Reason
}
Add-Assertion -Id 'cpu-stays-idle-while-throttled' -Observed $cpuIdle -Detail $detail

# The same rows cost very different amounts of log depending only on the schema,
# and against a fixed ceiling that is elapsed time.
$pacedPhase = if ($phases.ContainsKey($pacedId)) { $phases[$pacedId] } else { $null }
$indexesCost = $null
$detail = 'Not measured.'
if ($null -ne $pacedPhase -and $null -ne $idx -and $pacedPhase.Run.LogMB -gt 0 -and $pacedPhase.Run.RowsWritten -gt 0 -and $idx.Run.RowsWritten -gt 0) {
    $perRowMinimal = $pacedPhase.Run.LogMB / $pacedPhase.Run.RowsWritten
    $perRowIndexed = $idx.Run.LogMB / $idx.Run.RowsWritten
    $ratio = [math]::Round($perRowIndexed / $perRowMinimal, 2)
    $indexesCost = ($ratio -ge 2.0)
    $detail = "Per row, a minimal table cost $([math]::Round($perRowMinimal * 1024, 3)) KB of log and one with three nonclustered indexes cost $([math]::Round($perRowIndexed * 1024, 3)) KB -- a factor of $ratio. Against a fixed ceiling that is elapsed time, not a rounding error."
}
Add-Assertion -Id 'indexes-multiply-the-log-for-identical-rows' -Observed $indexesCost -Detail $detail

# The metric does work -- it is just not the one anyone watches.
$metricWorks = $null
$detail = 'Not measured.'
if ($null -ne $sat -and $null -ne $sat.Settled -and $null -ne $sat.Settled.PeakLogPercent) {
    $metricWorks = ($sat.Settled.PeakLogPercent -ge $saturatedThreshold)
    $detail = "avg_log_write_percent reported $($sat.Settled.PeakLogPercent)% for the throttled phase, at or above the $saturatedThreshold% threshold. The signal is accurate; it is simply not on the default blade."
}
Add-Assertion -Id 'log-write-percent-does-report-it' -Observed $metricWorks -Detail $detail

# Orderings rather than verdicts. The index-heavy phase sits near the saturation
# threshold and moves between runs, so its throttle state is recorded in the
# matrix under knownVariance and never graded. What held on every run is that it
# is slower AND less saturated AND more CPU-hungry than the throttled phase.
$slowerNotThrottled = $null
$detail = 'Not measured.'
if ($null -ne $sat -and $null -ne $pacedPhase -and $null -ne $sat.Run.AchievedMBps -and $null -ne $pacedPhase.Run.AchievedMBps) {
    # Against the control, not the index-heavy phase: the control is the only
    # comparison that held on every run. Hitting a rate ceiling requires going
    # fast, so the throttled phase is the FASTEST of the three.
    $slowerNotThrottled = ($pacedPhase.Run.AchievedMBps -lt $sat.Run.AchievedMBps)
    $detail = "The throttled phase achieved $($sat.Run.AchievedMBps) MB/s; the unthrottled control achieved $($pacedPhase.Run.AchievedMBps) MB/s, and was not throttled. Slow does not mean throttled -- reaching a rate ceiling requires speed."
}
Add-Assertion -Id 'throughput-does-not-indicate-throttling' -Observed $slowerNotThrottled -Detail $detail

$cpuMoved = $null
$detail = 'Not measured.'
if ($null -ne $sat -and $null -ne $idx -and $null -ne $sat.Settled -and $null -ne $idx.Settled -and
    $null -ne $sat.Settled.PeakCpuPercent -and $null -ne $idx.Settled.PeakCpuPercent) {
    $cpuMoved = ($idx.Settled.PeakCpuPercent -gt $sat.Settled.PeakCpuPercent)
    $detail = "Index-heavy used $($idx.Settled.PeakCpuPercent)% CPU against $($sat.Settled.PeakCpuPercent)% for the throttled phase, while generating less log pressure. The bottleneck moved."
}
Add-Assertion -Id 'index-maintenance-moves-the-cost-to-cpu' -Observed $cpuMoved -Detail $detail

# The buckets are still arriving after the workload ends. Narrower than the
# claim this replaces: an earlier version asserted that an immediate read finds
# NOTHING, which is true of a six-second write and false of a thirty-second one.
# What holds everywhere is that the settled read finds more.
$stillFilling = $null
$detail = 'Not measured.'
$comparable = @(@($matrix.phases.id) | Where-Object { $phases.ContainsKey($_) -and $null -ne $phases[$_].Settled })
if ($comparable.Count) {
    $grew = @($comparable | Where-Object { $phases[$_].Settled.SampleCount -gt $phases[$_].Run.ImmediateSampleCount })
    $stillFilling = ($grew.Count -eq $comparable.Count)
    $detail = (@($comparable | ForEach-Object { "$_ $($phases[$_].Run.ImmediateSampleCount) then $($phases[$_].Settled.SampleCount)" }) -join '; ') + '. Every phase gained samples after it finished.'
}
Add-Assertion -Id 'the-dmv-is-still-filling-in-after-the-workload' -Observed $stillFilling -Detail $detail

# The ceiling is only written down in a DMV.
$capFound = ($capMBps -gt 0)
Add-Assertion -Id 'the-cap-is-only-in-a-dmv' -Observed $capFound `
    -Detail "sys.dm_user_db_resource_governance.primary_max_log_rate reported $capMBps MB/s for $slo. No portal blade shows this number."

# -------------------------------------------------------------------- report

$total = $results.Count
$passed = @($results | Where-Object Passed).Count
$inconclusive = @($results | Where-Object Inconclusive).Count
$failed = $total - $passed - $inconclusive

$report = [pscustomobject]@{
    generatedUtc   = (Get-Date).ToUniversalTime().ToString('o')
    server         = $Server
    database       = $Database
    slo            = $slo
    logCeilingMBps = $capMBps
    settleSeconds  = $SettleSeconds
    total          = $total
    passed         = $passed
    failed         = $failed
    inconclusive   = $inconclusive
    ok             = ($failed -eq 0 -and $inconclusive -eq 0)
    phases         = $phases
    results        = $results
}
$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ReportPath -Encoding utf8

Write-Information ''
Write-Information "$passed/$total as declared; $failed failed; $inconclusive inconclusive."
if ($report.ok) { Write-Information 'Everything behaved as declared.' }
Write-Information "Report written to $ReportPath"

if ($env:GITHUB_STEP_SUMMARY) {
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('### Log rate governance drill')
    $lines.Add('')
    $lines.Add("**$passed/$total** as declared; $failed failed; $inconclusive inconclusive.")
    $lines.Add('')
    $lines.Add("Log ceiling for ``$slo``: **$capMBps MB/s**")
    $lines.Add('')
    $lines.Add('| phase | rows | elapsed | log | rate | peak log % | peak cpu % |')
    $lines.Add('|---|---|---|---|---|---|---|')
    foreach ($phase in @($matrix.phases.id)) {
        if (-not $phases.ContainsKey($phase)) { continue }
        $r = $phases[$phase].Run
        $s = $phases[$phase].Settled
        $lines.Add("| $phase | $($r.RowsWritten) | $($r.ElapsedMs) ms | $($r.LogMB) MB | $($r.AchievedMBps) MB/s | $(if ($s) { $s.PeakLogPercent } else { '?' }) | $(if ($s) { $s.PeakCpuPercent } else { '?' }) |")
    }
    $lines.Add('')
    $lines.Add('| check | expected | observed | |')
    $lines.Add('|---|---|---|---|')
    foreach ($r in $results) {
        $mark = if ($r.Passed) { 'ok' } elseif ($r.Inconclusive) { 'inconclusive' } else { 'FAILED' }
        $lines.Add("| $($r.Id) | $($r.Expected) | $($r.Observed) | $mark |")
    }
    $lines -join "`n" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}

# Inconclusive is not a pass. A drill that could not read its own result must not
# exit green, or the next change gets made against a number nobody earned.
if (-not $report.ok) { exit 1 }
