<#
=======================================================================
 SQL Server Schema Export  (daily-run edition)
=======================================================================
 Scripts DB objects (procs, views, functions, tables, triggers,
 synonyms) and server-level SQL Agent jobs to a folder tree:
 server -> database -> object type. Writes README.md at root,
 per-server, and per-database. Optionally commits the tree to git.

 -----------------------------------------------------------------
 CONFIGURE ME: this is a template. Before first use, set the values
 marked "CONFIGURE" below (or pass them on the command line):
   - $Servers         : the server(s) to export
   - $RootDir         : where to write the output tree
   - $BulkInitServers : large-schema servers that need fast enumeration
   - $Exclude         : anything you want skipped
 The defaults here are placeholders (ServerA / ServerB / MyDatabase)
 and will not connect to anything real until you change them.
 -----------------------------------------------------------------

 DESIGNED FOR A DAILY SCHEDULED RUN:
  - Git toggles live in the $Config block below (set-and-forget).
  - Command-line params can OVERRIDE the config for a one-off run.
  - Commit messages auto-generate with date/servers/totals/outcome.

 GIT LAYOUT:
  - The export folder ($RootDir) is expected to be a SUBFOLDER inside an
    existing git repo, not the repo root. The script asks git for the
    real repo root and never runs 'git init', so it can't accidentally
    create a nested repo. Staging/commit are scoped to $RootDir only,
    so the nightly job never sweeps in unrelated changes elsewhere.

 PER-SERVER TUNING:
  - $BulkInitServers lists servers where SMO bulk field-init is enabled
    to speed up enumeration on large schemas. It is NOT applied
    elsewhere, because on some servers the bulk fetch requests a
    property the login can't read and throws at $srv.Databases. Even on
    listed servers it is wrapped in try/catch so a permission change
    degrades to slow-but-working, not a failure.

 FILE FORMAT:
  - Each proc/view/function/synonym/table file begins with a
    "USE [database]" + GO context header, added by the script (SMO's
    own header is suppressed because it embeds a changing Script Date).
  - Files carry NO timestamp anywhere, and trailing whitespace is
    normalized to a single final newline, so an unchanged object
    produces a byte-identical file every run (no git churn).

 SAFETY: read-only against SQL Server. Uses .Script() (text only) -
 never Create/Alter/Drop/Execute. Table DATA is never exported.

 RESILIENCE:
  - WithDependencies = false: scripts each object alone (avoids hangs).
  - Encrypted objects can't be scripted; skipped with a placeholder.
  - StatementTimeout caps each server call.
  - Per-object wall-clock timeout abandons a stuck object (TIMEOUT).
  - Failures/timeouts/encrypted still write a placeholder .sql with the
    reason commented out, so an empty file is self-explanatory.
=======================================================================
#>

param(
    # CONFIGURE: server name(s) to export, e.g. @("ServerA","ServerB").
    [string[]]$Servers = @("ServerA"),

    # CONFIGURE: output folder. Should live INSIDE an existing git repo
    # (see the git section). Example: "C:\SqlExport".
    [string]$RootDir   = "C:\SqlExport",

    [int]$ObjectTimeoutSec = 90,
    [int]$StatementTimeoutSec = 60,

    # CONFIGURE: servers where SMO bulk field-init is enabled (fast
    # enumeration on large schemas). Leave a server off this list if
    # bulk-init throws at $srv.Databases there (happens when the login
    # can't read some property). Empty @() = never bulk-init.
    [string[]]$BulkInitServers = @(),

    # Command-line OVERRIDES for git. Leave unset to use the $Config block.
    # Force either way with:  -EnableGit:$true   or   -EnableGit:$false
    [System.Nullable[bool]]$EnableGit = $null,
    [System.Nullable[bool]]$GitPush   = $null,
    [string]$GitCommitMessage = ""
)

# =====================================================================
#  RUN CONFIG  -  set-and-forget switches for the daily scheduled run.
#  A matching command-line param (-EnableGit / -GitPush) overrides the
#  value here for that single run.
# =====================================================================
$Config = @{
    GitEnabled = $false   # master switch: commit after each run. Set $true for daily commits.
    GitPush    = $false   # also push to remote. Keep $false until a remote is configured.
}

# Effective settings: CLI param wins if supplied, else the config block.
$UseGit  = if ($null -ne $EnableGit) { [bool]$EnableGit } else { [bool]$Config.GitEnabled }
$UsePush = if ($null -ne $GitPush)   { [bool]$GitPush }   else { [bool]$Config.GitPush }
# =====================================================================

# =====================================================================
#  EXCLUSIONS  (four layers)  -- CONFIGURE to taste
#    1. Databases : key "Server" (or "*")  -> DB-name patterns to skip
#    2. Types     : key "Server\Db"        -> type names to skip
#         ("Stored Procedures","Views","Functions","Tables",
#          "Triggers","Synonyms","Agent Jobs")
#    3. Objects   : key "Server\Db"        -> schema.name patterns to skip
#    4. Jobs      : key "Server" (or "*")  -> job-name patterns to skip
#  Every KEY is a wildcard PATTERN; the concrete item is tested against it.
#  Empty list @() = skip nothing there.
#
#  The entries below are EXAMPLES using placeholder names. Replace them
#  with your own, or leave only the "*" / "*\*" catch-alls to skip nothing.
# =====================================================================
$Exclude = @{
    Databases = @{
        "*" = @()
        # "ServerB" = @("Temp*")           # example: skip DBs starting with Temp on ServerB
    }
    Types = @{
        "*\*" = @()
        # "ServerA\MyDatabase" = @("Tables","Triggers")   # example: skip tables & triggers there
    }
    Objects = @{
        "*\*" = @()
        # "ServerB\OtherDb" = @("dbo.temp_*")             # example: skip scratch objects
    }
    Jobs = @{
        "*" = @()
    }
}
# =====================================================================

Import-Module SqlServer

# ---------------- matching helpers ----------------
function Test-AnyLike {
    param([string]$Value, [string[]]$Patterns)
    foreach ($p in $Patterns) { if ($Value -like $p) { return $true } }
    return $false
}
function Get-ListForKeys {
    param([hashtable]$Map, [string[]]$LookupKeys)
    $result = @()
    foreach ($configKey in $Map.Keys) {
        foreach ($lk in $LookupKeys) {
            if ($lk -like $configKey) { $result += $Map[$configKey]; break }
        }
    }
    return $result
}
function Should-SkipDatabase {
    param([string]$Server, [string]$Db)
    $pats = Get-ListForKeys -Map $Exclude.Databases -LookupKeys @($Server, "*")
    return (Test-AnyLike -Value $Db -Patterns $pats)
}
function Should-SkipType {
    param([string]$Server, [string]$Db, [string]$Type)
    $pats = Get-ListForKeys -Map $Exclude.Types -LookupKeys @("$Server\$Db")
    return (Test-AnyLike -Value $Type -Patterns $pats)
}
function Get-ObjectSkipPatterns {
    param([string]$Server, [string]$Db)
    return (Get-ListForKeys -Map $Exclude.Objects -LookupKeys @("$Server\$Db"))
}
function Should-SkipJob {
    param([string]$Server, [string]$JobName)
    $pats = Get-ListForKeys -Map $Exclude.Jobs -LookupKeys @($Server, "*")
    return (Test-AnyLike -Value $JobName -Patterns $pats)
}

# ---------------- file helpers ----------------
# Prepend "USE [db]" + GO, apply optional CREATE OR ALTER rewrite, and
# normalize the file to exactly one trailing newline. Writing without a
# BOM and with a single final newline keeps output byte-stable run to run
# (no git churn) and stops an extra blank line accumulating on each pass.
function Write-ObjectFile {
    param([string]$Path, [string]$DbName, [string]$AlterVerb)
    $content = Get-Content $Path -Raw
    if ($null -eq $content) { $content = "" }
    if ($AlterVerb) {
        $content = $content -replace "(?im)^\s*CREATE\s+$AlterVerb", "CREATE OR ALTER $AlterVerb"
    }
    # Strip any leading/trailing whitespace SMO left, then rebuild cleanly.
    $content = $content.Trim()
    $text    = "USE [$DbName]`r`nGO`r`n`r`n" + $content + "`r`n"
    # Write without BOM so the bytes are identical every run.
    [System.IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-Placeholder {
    param([string]$Path, [string]$Fq, [string]$Reason, [string]$Detail)
    # NOTE: intentionally NO timestamp here. A failing object that has not
    # changed produces a byte-identical placeholder every run, so git sees
    # no diff and the nightly commit stays clean.
    $body  = "-- ============================================================`r`n"
    $body += "-- OBJECT NOT EXPORTED`r`n"
    $body += "-- Object : $Fq`r`n"
    $body += "-- Reason : $Reason`r`n"
    if ($Detail) { foreach ($line in ($Detail -split "`r?`n")) { $body += "-- $line`r`n" } }
    $body += "-- This file is intentionally empty of DDL because the object`r`n"
    $body += "-- could not be scripted. See reason above.`r`n"
    $body += "-- ============================================================`r`n"
    [System.IO.File]::WriteAllText($Path, $body, (New-Object System.Text.UTF8Encoding($false)))
}

# ---------------- scripting options ----------------
function New-Opts {
    param([string]$FileName)
    $o = New-Object Microsoft.SqlServer.Management.Smo.ScriptingOptions
    $o.IncludeHeaders = $false
    $o.SchemaQualify = $true
    $o.NoCollation = $true
    $o.ScriptBatchTerminator = $true
    $o.ToFileOnly = $true
    $o.AnsiPadding = $false
    $o.ContinueScriptingOnError = $true
    $o.WithDependencies       = $false
    if ($FileName) { $o.FileName = $FileName }
    return $o
}

# Script one object in a runspace with a wall-clock timeout.
# Returns "ok" | "timeout" | "error:<msg>"
function Invoke-ScriptWithTimeout {
    param($SmoObject, [string]$FilePath, [int]$TimeoutSec)
    $ps = [powershell]::Create()
    $null = $ps.AddScript({
        param($obj, $file)
        $o = New-Object Microsoft.SqlServer.Management.Smo.ScriptingOptions
        $o.IncludeHeaders = $false; $o.SchemaQualify = $true; $o.NoCollation = $true
        $o.ScriptBatchTerminator = $true; $o.ToFileOnly = $true; $o.AnsiPadding = $false
        $o.ContinueScriptingOnError = $true; $o.WithDependencies = $false
        $o.FileName = $file
        $obj.Script($o) | Out-Null
    }).AddArgument($SmoObject).AddArgument($FilePath)

    $handle = $ps.BeginInvoke()
    if ($handle.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($TimeoutSec))) {
        try {
            $ps.EndInvoke($handle)
            if ($ps.HadErrors) {
                $msg = ($ps.Streams.Error | ForEach-Object { $_.ToString() }) -join "; "
                $ps.Dispose(); return "error:$msg"
            }
            $ps.Dispose(); return "ok"
        }
        catch { $m = $_.Exception.Message; $ps.Dispose(); return "error:$m" }
    }
    else { try { $ps.Stop() } catch {}; $ps.Dispose(); return "timeout" }
}

# ---------------- generic exporter (procs/views/functions/synonyms) ----------------
function Export-Objects {
    param($Collection, $OutDir, $Suffix, $AlterVerb, [string[]]$SkipObjectPatterns, $Label, [int]$TimeoutSec, [string]$DbName)
    $tStart = Get-Date
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $ok = 0; $fail = @(); $skipped = 0; $timedout = 0

    $items = @($Collection | Where-Object { -not $_.IsSystemObject })
    $total = $items.Count; $i = 0
    Write-Host ("    {0}: {1} candidate object(s)" -f $Label, $total)

    foreach ($obj in $items) {
        $i++
        $fq = "$($obj.Schema).$($obj.Name)"
        Write-Progress -Activity $Label -Status "$i of $total : $fq" -PercentComplete (($i / [math]::Max($total,1)) * 100)
        if (Test-AnyLike -Value $fq -Patterns $SkipObjectPatterns) { $skipped++; continue }

        $path = Join-Path $OutDir ("{0}.{1}.{2}.sql" -f $obj.Schema, $obj.Name, $Suffix)

        if ($obj.IsEncrypted) {
            Write-Host ("      ~ encrypted, skipped: {0}" -f $fq) -ForegroundColor DarkGray
            Write-Placeholder -Path $path -Fq $fq -Reason "Object is encrypted (WITH ENCRYPTION); definition not accessible."
            $skipped++; continue
        }

        $result = Invoke-ScriptWithTimeout -SmoObject $obj -FilePath $path -TimeoutSec $TimeoutSec
        if ($result -eq "ok") {
            Write-ObjectFile -Path $path -DbName $DbName -AlterVerb $AlterVerb
            $ok++
        }
        elseif ($result -eq "timeout") {
            Write-Host ("      ! TIMEOUT (> ${TimeoutSec}s), skipped: {0}" -f $fq) -ForegroundColor Yellow
            Write-Placeholder -Path $path -Fq $fq -Reason "Scripting exceeded ${TimeoutSec}s wall-clock timeout and was abandoned."
            $fail += "$fq - TIMEOUT after ${TimeoutSec}s"; $timedout++
        }
        else {
            $msg = $result.Substring(6)
            Write-Host ("      ! FAILED: {0} - {1}" -f $fq, $msg) -ForegroundColor Red
            Write-Placeholder -Path $path -Fq $fq -Reason "Scripting error." -Detail $msg
            $fail += "$fq - $msg"
        }
        if ($i % 25 -eq 0) {
            Write-Host ("      ... {0}/{1} ({2} ok, {3} failed, {4} skipped, {5} timeout)" -f $i, $total, $ok, $fail.Count, $skipped, $timedout)
        }
    }
    Write-Progress -Activity $Label -Completed
    $tEnd = Get-Date
    return [pscustomobject]@{
        Ok = $ok; Failed = $fail; Skipped = $skipped; TimedOut = $timedout
        Start = $tStart; End = $tEnd; Seconds = [math]::Round(($tEnd - $tStart).TotalSeconds, 1)
    }
}

# ---------------- tables (schema only) ----------------
function Export-Tables {
    param($Tables, $OutDir, [string[]]$SkipObjectPatterns, $Label, [int]$TimeoutSec, [string]$DbName)
    $tStart = Get-Date
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $ok = 0; $fail = @(); $skipped = 0; $timedout = 0

    $items = @($Tables | Where-Object { -not $_.IsSystemObject })
    $total = $items.Count; $i = 0
    Write-Host ("    {0}: {1} candidate table(s)" -f $Label, $total)

    foreach ($tbl in $items) {
        $i++
        $fq = "$($tbl.Schema).$($tbl.Name)"
        Write-Progress -Activity $Label -Status "$i of $total : $fq" -PercentComplete (($i / [math]::Max($total,1)) * 100)
        if (Test-AnyLike -Value $fq -Patterns $SkipObjectPatterns) { $skipped++; continue }

        $path = Join-Path $OutDir ("{0}.{1}.Table.sql" -f $tbl.Schema, $tbl.Name)

        $ps = [powershell]::Create()
        $null = $ps.AddScript({
            param($obj, $file)
            $o = New-Object Microsoft.SqlServer.Management.Smo.ScriptingOptions
            $o.IncludeHeaders = $false; $o.SchemaQualify = $true; $o.NoCollation = $true
            $o.ScriptBatchTerminator = $true; $o.ToFileOnly = $true; $o.AnsiPadding = $false
            $o.ContinueScriptingOnError = $true; $o.WithDependencies = $false
            $o.Indexes = $true; $o.DriAll = $true; $o.Triggers = $false; $o.ScriptData = $false
            $o.FileName = $file
            $obj.Script($o) | Out-Null
        }).AddArgument($tbl).AddArgument($path)

        $handle = $ps.BeginInvoke()
        if ($handle.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($TimeoutSec))) {
            try {
                $ps.EndInvoke($handle)
                if ($ps.HadErrors) {
                    $msg = ($ps.Streams.Error | ForEach-Object { $_.ToString() }) -join "; "
                    Write-Host ("      ! FAILED: {0} - {1}" -f $fq, $msg) -ForegroundColor Red
                    Write-Placeholder -Path $path -Fq $fq -Reason "Scripting error." -Detail $msg
                    $fail += "$fq - $msg"
                } else {
                    # Tables have no CREATE OR ALTER; pass $null for the verb.
                    Write-ObjectFile -Path $path -DbName $DbName -AlterVerb $null
                    $ok++
                }
            }
            catch {
                $m = $_.Exception.Message
                Write-Host ("      ! FAILED: {0} - {1}" -f $fq, $m) -ForegroundColor Red
                Write-Placeholder -Path $path -Fq $fq -Reason "Scripting error." -Detail $m
                $fail += "$fq - $m"
            }
            $ps.Dispose()
        }
        else {
            try { $ps.Stop() } catch {}; $ps.Dispose()
            Write-Host ("      ! TIMEOUT (> ${TimeoutSec}s), skipped: {0}" -f $fq) -ForegroundColor Yellow
            Write-Placeholder -Path $path -Fq $fq -Reason "Scripting exceeded ${TimeoutSec}s wall-clock timeout and was abandoned."
            $fail += "$fq - TIMEOUT after ${TimeoutSec}s"; $timedout++
        }
        if ($i % 25 -eq 0) {
            Write-Host ("      ... {0}/{1} ({2} ok, {3} failed, {4} skipped, {5} timeout)" -f $i, $total, $ok, $fail.Count, $skipped, $timedout)
        }
    }
    Write-Progress -Activity $Label -Completed
    $tEnd = Get-Date
    return [pscustomobject]@{
        Ok = $ok; Failed = $fail; Skipped = $skipped; TimedOut = $timedout
        Start = $tStart; End = $tEnd; Seconds = [math]::Round(($tEnd - $tStart).TotalSeconds, 1)
    }
}

# ---------------- triggers ----------------
function Export-Triggers {
    param($Tables, $OutDir, [string[]]$SkipObjectPatterns, $Label, [int]$TimeoutSec, [string]$DbName)
    $tStart = Get-Date
    $ok = 0; $fail = @(); $skipped = 0; $timedout = 0; $any = $false

    $tblItems = @($Tables | Where-Object { -not $_.IsSystemObject })
    # Heartbeat: counting triggers touches $tbl.Triggers on every table, which
    # can be slow on large schemas. Announce it so a long scan is not mistaken
    # for a freeze.
    Write-Host ("    {0}: scanning {1} table(s) for triggers..." -f $Label, $tblItems.Count)
    $total = 0; foreach ($tbl in $tblItems) { $total += @($tbl.Triggers).Count }
    $i = 0
    Write-Host ("    {0}: {1} candidate trigger(s)" -f $Label, $total)

    foreach ($tbl in $tblItems) {
        foreach ($trg in $tbl.Triggers) {
            $i++
            $fq = "$($tbl.Schema).$($trg.Name)"
            Write-Progress -Activity $Label -Status "$i of $total : $fq" -PercentComplete (($i / [math]::Max($total,1)) * 100)
            if (Test-AnyLike -Value $fq -Patterns $SkipObjectPatterns) { $skipped++; continue }
            if (-not $any) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null; $any = $true }
            $path = Join-Path $OutDir ("{0}.{1}.Trigger.sql" -f $tbl.Schema, $trg.Name)

            if ($trg.IsEncrypted) {
                Write-Host ("      ~ encrypted, skipped: {0}" -f $fq) -ForegroundColor DarkGray
                Write-Placeholder -Path $path -Fq $fq -Reason "Trigger is encrypted (WITH ENCRYPTION); definition not accessible."
                $skipped++; continue
            }

            $result = Invoke-ScriptWithTimeout -SmoObject $trg -FilePath $path -TimeoutSec $TimeoutSec
            if ($result -eq "ok") {
                Write-ObjectFile -Path $path -DbName $DbName -AlterVerb $null
                $ok++
            }
            elseif ($result -eq "timeout") {
                Write-Host ("      ! TIMEOUT (> ${TimeoutSec}s), skipped: {0}" -f $fq) -ForegroundColor Yellow
                Write-Placeholder -Path $path -Fq $fq -Reason "Scripting exceeded ${TimeoutSec}s wall-clock timeout and was abandoned."
                $fail += "$fq - TIMEOUT after ${TimeoutSec}s"; $timedout++
            }
            else {
                $msg = $result.Substring(6)
                Write-Host ("      ! FAILED: {0} - {1}" -f $fq, $msg) -ForegroundColor Red
                Write-Placeholder -Path $path -Fq $fq -Reason "Scripting error." -Detail $msg
                $fail += "$fq - $msg"
            }
            if ($i % 25 -eq 0) {
                Write-Host ("      ... {0}/{1} ({2} ok, {3} failed, {4} skipped, {5} timeout)" -f $i, $total, $ok, $fail.Count, $skipped, $timedout)
            }
        }
    }
    Write-Progress -Activity $Label -Completed
    $tEnd = Get-Date
    return [pscustomobject]@{
        Ok = $ok; Failed = $fail; Skipped = $skipped; TimedOut = $timedout
        Start = $tStart; End = $tEnd; Seconds = [math]::Round(($tEnd - $tStart).TotalSeconds, 1)
    }
}

# ---------------- MAIN ----------------
$runStart   = Get-Date
$runUser    = "$env:USERDOMAIN\$env:USERNAME"
$runMachine = $env:COMPUTERNAME
$serverSummaries = @()

Write-Host "Git this run: $(if ($UseGit) { 'ENABLED' } else { 'disabled' })$(if ($UseGit -and $UsePush) { ' + push' } else { '' })"

foreach ($serverName in $Servers) {

    Write-Host "`n############################################"
    Write-Host "##  SERVER: $serverName"
    Write-Host "############################################"

    $safeServer = ($serverName -replace '[\\/:*?"<>|]', '_')
    $serverDir  = Join-Path $RootDir $safeServer
    New-Item -ItemType Directory -Force -Path $serverDir | Out-Null

    Write-Host "  Connecting to $serverName ..."
    try {
        $srv = New-Object Microsoft.SqlServer.Management.Smo.Server $serverName
        $null = $srv.Version
        $srv.ConnectionContext.StatementTimeout = $StatementTimeoutSec
        # Bulk-fetch object properties instead of one round-trip per object.
        # Needed on large schemas to avoid a multi-minute silent hang during
        # trigger enumeration. On some servers the bulk fetch requests a
        # property the login can't read and throws at $srv.Databases, so only
        # enable it for servers in $BulkInitServers and make it non-fatal.
        if ($BulkInitServers -contains $serverName) {
            try {
                $srv.SetDefaultInitFields($true)
                Write-Host "  Bulk field init enabled (fast enumeration)."
            }
            catch {
                Write-Warning "  SetDefaultInitFields not applied on $serverName - $($_.Exception.Message)"
            }
        }
        Write-Host "  Connected (SQL Server $($srv.Version)). Statement timeout ${StatementTimeoutSec}s, per-object timeout ${ObjectTimeoutSec}s."
    }
    catch {
        Write-Warning "  Could not connect to $serverName - $($_.Exception.Message)"
        $serverSummaries += [pscustomobject]@{ Server = $serverName; Databases = 0; Objects = 0; Failed = 0; Status = "UNREACHABLE" }
        "# Server Export - $serverName`n`n**Status: UNREACHABLE**`n`nError: $($_.Exception.Message)`n" |
            Set-Content -Path (Join-Path $serverDir "README.md") -Encoding UTF8
        continue
    }

    $userDbs = @($srv.Databases | Where-Object { -not $_.IsSystemObject })
    Write-Host "  $($userDbs.Count) user database(s) found."

    $grandTotal = 0; $grandSkipped = 0; $dbSummaries = @(); $dbIndex = 0

    foreach ($db in $userDbs) {
        $dbIndex++

        if ($db.Status -ne [Microsoft.SqlServer.Management.Smo.DatabaseStatus]::Normal) {
            Write-Host "[$dbIndex/$($userDbs.Count)] Skipping $($db.Name) (status: $($db.Status))"
            $dbSummaries += [pscustomobject]@{ Name = $db.Name; Total = 0; Failed = 0; Status = "SKIPPED ($($db.Status))" }
            continue
        }
        if (Should-SkipDatabase -Server $serverName -Db $db.Name) {
            Write-Host "[$dbIndex/$($userDbs.Count)] Skipping $($db.Name) (excluded by config)"
            $dbSummaries += [pscustomobject]@{ Name = $db.Name; Total = 0; Failed = 0; Status = "EXCLUDED" }
            continue
        }

        $safeName = ($db.Name -replace '[\\/:*?"<>|]', '_')
        $dbDir    = Join-Path $serverDir $safeName
        New-Item -ItemType Directory -Force -Path $dbDir | Out-Null

        Write-Host "`n[$dbIndex/$($userDbs.Count)] === $($db.Name) ===  (enumerating; large DBs can pause here)"
        $dbStart = Get-Date
        $objSkip = Get-ObjectSkipPatterns -Server $serverName -Db $db.Name

        $types = [ordered]@{}
        if (-not (Should-SkipType -Server $serverName -Db $db.Name -Type "Stored Procedures")) {
            $types["Stored Procedures"] = Export-Objects -Collection $db.StoredProcedures -OutDir (Join-Path $dbDir "Stored Procedures") -Suffix "StoredProcedure" -AlterVerb "PROCEDURE" -SkipObjectPatterns $objSkip -Label "$($db.Name) / Stored Procedures" -TimeoutSec $ObjectTimeoutSec -DbName $db.Name
        }
        if (-not (Should-SkipType -Server $serverName -Db $db.Name -Type "Views")) {
            $types["Views"] = Export-Objects -Collection $db.Views -OutDir (Join-Path $dbDir "Views") -Suffix "View" -AlterVerb "VIEW" -SkipObjectPatterns $objSkip -Label "$($db.Name) / Views" -TimeoutSec $ObjectTimeoutSec -DbName $db.Name
        }
        if (-not (Should-SkipType -Server $serverName -Db $db.Name -Type "Functions")) {
            $types["Functions"] = Export-Objects -Collection $db.UserDefinedFunctions -OutDir (Join-Path $dbDir "Functions") -Suffix "Function" -AlterVerb "FUNCTION" -SkipObjectPatterns $objSkip -Label "$($db.Name) / Functions" -TimeoutSec $ObjectTimeoutSec -DbName $db.Name
        }
        if (-not (Should-SkipType -Server $serverName -Db $db.Name -Type "Tables")) {
            $types["Tables"] = Export-Tables -Tables $db.Tables -OutDir (Join-Path $dbDir "Tables") -SkipObjectPatterns $objSkip -Label "$($db.Name) / Tables" -TimeoutSec $ObjectTimeoutSec -DbName $db.Name
        }
        if (-not (Should-SkipType -Server $serverName -Db $db.Name -Type "Triggers")) {
            $types["Triggers"] = Export-Triggers -Tables $db.Tables -OutDir (Join-Path $dbDir "Triggers") -SkipObjectPatterns $objSkip -Label "$($db.Name) / Triggers" -TimeoutSec $ObjectTimeoutSec -DbName $db.Name
        }
        if (-not (Should-SkipType -Server $serverName -Db $db.Name -Type "Synonyms")) {
            $types["Synonyms"] = Export-Objects -Collection $db.Synonyms -OutDir (Join-Path $dbDir "Synonyms") -Suffix "Synonym" -AlterVerb $null -SkipObjectPatterns $objSkip -Label "$($db.Name) / Synonyms" -TimeoutSec $ObjectTimeoutSec -DbName $db.Name
        }

        $dbEnd = Get-Date

        $dbOk      = ($types.Values | Measure-Object -Property Ok -Sum).Sum
        $dbFailed  = ($types.Values | ForEach-Object { $_.Failed.Count } | Measure-Object -Sum).Sum
        $dbSkipped = ($types.Values | Measure-Object -Property Skipped -Sum).Sum
        $dbTimeout = ($types.Values | Measure-Object -Property TimedOut -Sum).Sum
        $overall   = if ($dbFailed -eq 0) { "SUCCESS" } else { "COMPLETED WITH ERRORS" }

        $readme  = "# Schema Export - $($db.Name)`n`n"
        $readme += "**This directory is generated automatically. Do not edit files here by hand.**`n`n"
        $readme += "| Field | Value |`n|-------|-------|`n"
        $readme += "| Status | $overall |`n"
        $readme += "| Server | $serverName |`n"
        $readme += "| Database | $($db.Name) |`n"
        $readme += "| Total objects exported | $dbOk |`n"
        $readme += "| Objects failed | $dbFailed |`n"
        $readme += "| Objects skipped (excluded/encrypted) | $dbSkipped |`n"
        $readme += "| Objects timed out | $dbTimeout |`n"
        $readme += "| Run started | $($dbStart.ToString('yyyy-MM-dd HH:mm:ss')) |`n"
        $readme += "| Run finished | $($dbEnd.ToString('yyyy-MM-dd HH:mm:ss')) |`n"
        $readme += "| Duration | $([math]::Round(($dbEnd - $dbStart).TotalSeconds,1)) sec |`n"
        $readme += "| Run by | $runUser |`n"
        $readme += "| From machine | $runMachine |`n`n"
        $readme += "## Objects by type`n`n"
        $readme += "| Type | Exported | Failed | Skipped | Timeout | Started | Finished | Duration (s) |`n"
        $readme += "|------|----------|--------|---------|---------|---------|----------|--------------|`n"
        foreach ($k in $types.Keys) {
            $t = $types[$k]
            $readme += "| $k | $($t.Ok) | $($t.Failed.Count) | $($t.Skipped) | $($t.TimedOut) | $($t.Start.ToString('HH:mm:ss')) | $($t.End.ToString('HH:mm:ss')) | $($t.Seconds) |`n"
        }
        $excludedTypes = @("Stored Procedures","Views","Functions","Tables","Triggers","Synonyms") | Where-Object { -not $types.Contains($_) }
        if ($excludedTypes.Count -gt 0) {
            $readme += "`n**Object types excluded by config (Layer 2):** $($excludedTypes -join ', ')`n"
        }
        $readme += "`n## What this is`n`n"
        $readme += "Each file is one object scripted from ``$($db.Name)`` on ``$serverName``, prefixed with a ``USE [db]`` / ``GO`` context header. Procedures, views, functions are ``CREATE OR ALTER``. Tables are **schema only (no data)**. Objects that could not be scripted (encrypted, error, timeout) still get a ``.sql`` file with the reason commented out. Files are overwritten each run; deleted objects retain their last file (not cleaned).`n`n"

        $allFailures = @()
        foreach ($k in $types.Keys) { foreach ($f in $types[$k].Failed) { $allFailures += "[$k] $f" } }
        if ($allFailures.Count -gt 0) {
            $readme += "## Failures and timeouts`n`n"
            foreach ($f in $allFailures) { $readme += "- $f`n" }
            $readme += "`n"
        }
        $readme | Set-Content -Path (Join-Path $dbDir "README.md") -Encoding UTF8

        Write-Host ("  {0} - {1} objects, {2} failed, {3} skipped, {4} timeout, {5}s total" -f $overall, $dbOk, $dbFailed, $dbSkipped, $dbTimeout, [math]::Round(($dbEnd - $dbStart).TotalSeconds,1))
        foreach ($k in $types.Keys) {
            $t = $types[$k]
            Write-Host ("    {0,-18} {1,5} ok  {2,3} failed  {3,3} skipped  {4,3} timeout  {5,7}s" -f $k, $t.Ok, $t.Failed.Count, $t.Skipped, $t.TimedOut, $t.Seconds)
        }

        $grandTotal += $dbOk; $grandSkipped += $dbSkipped
        $dbSummaries += [pscustomobject]@{ Name = $db.Name; Total = $dbOk; Failed = $dbFailed; Status = $overall }
    }

    # ---- Agent jobs ----
    $jobOk = 0; $jobFail = @(); $jobSkipped = 0; $jobStart = Get-Date; $jobEnd = Get-Date
    if (-not (Should-SkipType -Server $serverName -Db "_ServerLevel" -Type "Agent Jobs")) {
        Write-Host "`n=== _ServerLevel (SQL Agent Jobs) ==="
        $srvLevelDir = Join-Path $serverDir "_ServerLevel"
        $jobDir      = Join-Path $srvLevelDir "Agent Jobs"
        New-Item -ItemType Directory -Force -Path $jobDir | Out-Null
        $jobStart = Get-Date
        try {
            $allJobs = @($srv.JobServer.Jobs); $jTotal = $allJobs.Count; $jI = 0
            Write-Host "  $jTotal Agent job(s) found."
            foreach ($job in $allJobs) {
                $jI++
                Write-Progress -Activity "$serverName / Agent Jobs" -Status "$jI of $jTotal : $($job.Name)" -PercentComplete (($jI / [math]::Max($jTotal,1)) * 100)
                if (Should-SkipJob -Server $serverName -JobName $job.Name) { $jobSkipped++; continue }
                $safeJob = ($job.Name -replace '[\\/:*?"<>|]', '_')
                $path    = Join-Path $jobDir ("{0}.Job.sql" -f $safeJob)
                $o = New-Opts -FileName $path
                try { $job.Script($o) | Out-Null; $jobOk++ }
                catch {
                    $m = $_.Exception.Message
                    Write-Host ("      ! FAILED job: {0} - {1}" -f $job.Name, $m) -ForegroundColor Red
                    Write-Placeholder -Path $path -Fq $job.Name -Reason "Job scripting error." -Detail $m
                    $jobFail += "$($job.Name) - $m"
                }
            }
            Write-Progress -Activity "$serverName / Agent Jobs" -Completed
        }
        catch { $jobFail += "JobServer unavailable - $($_.Exception.Message)" }
        $jobEnd = Get-Date

        $jobStatus = if ($jobFail.Count -eq 0) { "SUCCESS" } else { "COMPLETED WITH ERRORS" }
        $jobSecs   = [math]::Round(($jobEnd - $jobStart).TotalSeconds, 1)
        $sr  = "# Server-Level Export - $serverName`n`n"
        $sr += "**Generated automatically. Do not edit by hand.**`n`n"
        $sr += "| Field | Value |`n|-------|-------|`n"
        $sr += "| Status | $jobStatus |`n"
        $sr += "| Agent jobs exported | $jobOk |`n"
        $sr += "| Agent jobs failed | $($jobFail.Count) |`n"
        $sr += "| Agent jobs skipped | $jobSkipped |`n"
        $sr += "| Run started | $($jobStart.ToString('yyyy-MM-dd HH:mm:ss')) |`n"
        $sr += "| Run finished | $($jobEnd.ToString('yyyy-MM-dd HH:mm:ss')) |`n"
        $sr += "| Duration | $jobSecs sec |`n"
        $sr += "| Run by | $runUser |`n"
        $sr += "| From machine | $runMachine |`n`n"
        $sr += "SQL Server Agent jobs scripted from ``msdb``. **Review before committing** - steps can embed connection strings, proxy accounts, or credentials.`n`n"
        if ($jobFail.Count -gt 0) { $sr += "## Failures`n`n"; foreach ($f in $jobFail) { $sr += "- $f`n" } }
        $sr | Set-Content -Path (Join-Path $srvLevelDir "README.md") -Encoding UTF8
        Write-Host ("  {0} - {1} jobs, {2} failed, {3} skipped  {4}s" -f $jobStatus, $jobOk, $jobFail.Count, $jobSkipped, $jobSecs)
        $grandTotal += $jobOk
    }
    else { Write-Host "`nSkipping SQL Agent Jobs (excluded by config)" }

    # ---- per-server README ----
    $srvFailTotal = (($dbSummaries | ForEach-Object { $_.Failed } | Measure-Object -Sum).Sum + $jobFail.Count)
    $srvOverall   = if ($srvFailTotal -eq 0) { "SUCCESS" } else { "COMPLETED WITH ERRORS" }
    $sv  = "# Schema Export - $serverName`n`n"
    $sv += "**Generated automatically. Do not edit by hand.**`n`n"
    $sv += "| Field | Value |`n|-------|-------|`n"
    $sv += "| Status | $srvOverall |`n"
    $sv += "| Server | $serverName |`n"
    $sv += "| Databases processed | $($dbSummaries.Count) |`n"
    $sv += "| Total objects exported | $grandTotal |`n"
    $sv += "| Total objects skipped | $grandSkipped |`n"
    $sv += "| Agent jobs exported | $jobOk |`n"
    $sv += "| Run by | $runUser |`n"
    $sv += "| From machine | $runMachine |`n`n"
    $sv += "## Databases`n`n"
    $sv += "| Database | Objects | Failed | Status |`n|----------|---------|--------|--------|`n"
    foreach ($s in $dbSummaries) { $sv += "| $($s.Name) | $($s.Total) | $($s.Failed) | $($s.Status) |`n" }
    $sv | Set-Content -Path (Join-Path $serverDir "README.md") -Encoding UTF8

    $serverSummaries += [pscustomobject]@{ Server = $serverName; Databases = $dbSummaries.Count; Objects = $grandTotal; Failed = $srvFailTotal; Status = $srvOverall }
}

$runEnd = Get-Date

# ---- root README ----
$root  = "# Schema Export - Multi-Server`n`n"
$root += "**This tree is generated automatically by an export script. Do not edit by hand.**`n`n"
$root += "| Field | Value |`n|-------|-------|`n"
$root += "| Servers processed | $($serverSummaries.Count) |`n"
$root += "| Run started | $($runStart.ToString('yyyy-MM-dd HH:mm:ss')) |`n"
$root += "| Run finished | $($runEnd.ToString('yyyy-MM-dd HH:mm:ss')) |`n"
$root += "| Duration | $([math]::Round(($runEnd - $runStart).TotalSeconds,1)) sec |`n"
$root += "| Run by | $runUser |`n"
$root += "| From machine | $runMachine |`n`n"
$root += "Each server has its own folder; within it one folder per database plus ``_ServerLevel`` for Agent jobs. Exclusions: ``Exclude`` block (Databases, Types, Objects, Jobs). Objects that fail/timeout/are encrypted still get a placeholder ``.sql`` with the reason commented out. Table **data is not exported**.`n`n"
$root += "## Servers`n`n"
$root += "| Server | Databases | Objects | Failed | Status |`n|--------|-----------|---------|--------|--------|`n"
foreach ($s in $serverSummaries) {
    $root += "| $($s.Server) | $($s.Databases) | $($s.Objects) | $($s.Failed) | $($s.Status) |`n"
}
$root | Set-Content -Path (Join-Path $RootDir "README.md") -Encoding UTF8

Write-Host "`nDone. $($serverSummaries.Count) server(s) exported into $RootDir"

# =====================================================================
#  GIT  (controlled by $Config.GitEnabled, override with -EnableGit)
#
#  IMPORTANT: $RootDir is expected to live INSIDE an existing repo as a
#  subfolder. This block:
#    - asks git for the real repo root (never runs 'git init', so it
#      can't create a nested repo by mistake);
#    - stages/commits ONLY $RootDir, so unrelated changes elsewhere in
#      the repo are left alone.
#  If $RootDir is not inside a repo, the git step is skipped with a
#  warning. Create the repo once by hand at the true root first.
# =====================================================================
if ($UseGit) {
    Write-Host "`n=== Git ==="
    $git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $git) {
        Write-Warning "  Git is enabled but 'git' is not on PATH. Skipping git step."
    }
    else {
        Push-Location $RootDir
        try {
            # Find the repo root from wherever $RootDir sits. Do NOT git init.
            $repoRoot = (git rev-parse --show-toplevel 2>$null)
            if ([string]::IsNullOrWhiteSpace($repoRoot)) {
                Write-Warning "  $RootDir is not inside a git repository. Skipping git step."
                Write-Warning "  (Not running 'git init' - that would create a nested repo. Create the repo once at the true root by hand.)"
            }
            else {
                Write-Host "  Repo root : $repoRoot"
                Write-Host "  Committing: $RootDir (scoped)"

                # Stage ONLY the export folder, not the whole repo.
                git add -A -- $RootDir | Out-Null
                $status = git status --porcelain -- $RootDir
                if ([string]::IsNullOrWhiteSpace($status)) {
                    Write-Host "  No changes to commit - export folder clean."
                }
                else {
                    $changeCount = ($status -split "`n" | Where-Object { $_ }).Count
                    if ([string]::IsNullOrWhiteSpace($GitCommitMessage)) {
                        $stamp   = Get-Date -Format "yyyy-MM-dd HH:mm"
                        $srvList = ($serverSummaries | ForEach-Object { $_.Server }) -join ", "
                        $totObj  = ($serverSummaries | Measure-Object -Property Objects -Sum).Sum
                        $totFail = ($serverSummaries | Measure-Object -Property Failed  -Sum).Sum
                        $outcome = if ($totFail -eq 0) { "clean" } else { "$totFail issue(s)" }
                        $GitCommitMessage = "Daily schema export $stamp | $srvList | $totObj objects, $changeCount file change(s), $outcome"
                    }
                    # Commit only the staged export paths.
                    git commit -m $GitCommitMessage -- $RootDir | Out-Null
                    Write-Host "  Committed: $GitCommitMessage"
                    if ($UsePush) {
                        Write-Host "  Pushing to remote ..."
                        $pushOut = git push 2>&1
                        if ($LASTEXITCODE -eq 0) { Write-Host "  Push complete." }
                        else { Write-Warning "  git push failed: $pushOut" }
                    }
                    else { Write-Host "  (Local commit only; push disabled.)" }
                }
            }
        }
        catch { Write-Warning "  Git step error: $($_.Exception.Message)" }
        finally { Pop-Location }
    }
}
else {
    Write-Host "`n(Git is disabled. Set `$Config.GitEnabled = `$true or run with -EnableGit:`$true.)"
}
