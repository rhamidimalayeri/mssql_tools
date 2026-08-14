# SQL Server Schema Export

A PowerShell script that scripts out the schema of one or more SQL Server instances (stored procedures, views, functions, tables, triggers, synonyms, and SQL Agent jobs) into a folder tree you can keep in git. Run it nightly and the repo becomes a running history of how your schema changes.

It's read-only against SQL Server. It uses SMO's `.Script()` method (text only) and never runs `CREATE` / `ALTER` / `DROP` / `EXECUTE`. Table data is never exported, only structure.

## What it produces

```
SqlExport/                        <- $RootDir
├── README.md                     (root summary of the last run)
├── ServerA/
│   ├── README.md
│   ├── MyDatabase/
│   │   ├── README.md
│   │   ├── Stored Procedures/
│   │   │   └── dbo.usp_Something.StoredProcedure.sql
│   │   ├── Views/
│   │   ├── Functions/
│   │   ├── Tables/               (schema only, no data)
│   │   ├── Triggers/
│   │   └── Synonyms/
│   └── _ServerLevel/
│       └── Agent Jobs/
└── ServerB/
```

Each object is one `.sql` file with a database-context header:

```sql
USE [MyDatabase]
GO

CREATE OR ALTER PROCEDURE [dbo].[usp_Something]
...
```

Procedures, views, and functions come out as `CREATE OR ALTER` so they're safe to re-run. Tables include indexes and constraints but no data.

## Requirements

- Windows PowerShell 5.1 (uses SMO and statement-form `if` assignments; not tested on PowerShell 7+).
- The SqlServer module:
  ```powershell
  Install-Module SqlServer -Scope CurrentUser
  ```
- git on `PATH`, if you enable the commit step.
- A login that can connect to each server and read schema metadata on the databases you want.

## Quick start

```powershell
# defaults, no git
.\export-all-schema.ps1

# specific server and output folder
.\export-all-schema.ps1 -Servers "ServerA" -RootDir "C:\SqlExport"

# several servers, commit to git
.\export-all-schema.ps1 -Servers "ServerA","ServerB" -EnableGit:$true
```

## Parameters

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `-Servers` | one server name | Server(s) to export. |
| `-RootDir` | a local folder | Output folder. Should live inside an existing git repo (see Git). |
| `-ObjectTimeoutSec` | `90` | Per-object wall-clock timeout. A stuck object is abandoned and gets a placeholder instead of hanging the run. |
| `-StatementTimeoutSec` | `60` | SMO statement timeout per server call. |
| `-BulkInitServers` | empty | Servers that get fast bulk metadata fetch (see Performance). |
| `-EnableGit` | `$null` | Override the git switch for one run. `-EnableGit:$true` forces on, `:$false` forces off. Unset uses the `$Config` block. |
| `-GitPush` | `$null` | Override the push switch for one run. |
| `-GitCommitMessage` | `""` | Custom commit message. Empty auto-generates one. |

Set the defaults at the top of the script, or pass them each run.

## Configuration

### Git switches (`$Config` block)

```powershell
$Config = @{
    GitEnabled = $false   # $true = commit the tree after each run
    GitPush    = $false   # $true = also push to the remote
}
```

Command-line `-EnableGit` / `-GitPush` override these for one run. Keep `GitPush = $false` until you've confirmed the run account can actually push (see Scheduling).

### Exclusions (`$Exclude` block)

Four layers let you skip things. Every key is a wildcard pattern, tested with `-like`. An empty list `@()` skips nothing.

```powershell
$Exclude = @{
    # Layer 1: whole databases.  Key "Server" (or "*") -> DB-name patterns
    Databases = @{
        "*" = @()
        # "ServerB" = @("Temp*")
    }
    # Layer 2: object types.  Key "Server\Db" -> type names
    #   Types: "Stored Procedures","Views","Functions","Tables",
    #          "Triggers","Synonyms","Agent Jobs"
    Types = @{
        "*\*" = @()
        # "ServerA\MyDatabase" = @("Tables","Triggers")
    }
    # Layer 3: individual objects.  Key "Server\Db" -> schema.name patterns
    Objects = @{
        "*\*" = @()
        # "ServerB\OtherDb" = @("dbo.temp_*")
    }
    # Layer 4: Agent jobs.  Key "Server" (or "*") -> job-name patterns
    Jobs = @{
        "*" = @()
    }
}
```

Names are matched as `-like` patterns, so `\` is literal but `[`, `]`, and `?` are wildcards. Escape them if a name uses them.

## Performance: the `$BulkInitServers` list

On large schemas, enumerating triggers makes SMO do one server round-trip per table, sometimes thousands of silent calls that make the script look frozen for minutes.

Turning on bulk field-init (`SetDefaultInitFields($true)`) fixes that by fetching properties in bulk. But on some servers the bulk fetch asks for a property the login can't read, and it throws while listing databases (you'll see "0 user database(s) found").

So the script only turns bulk-init on for servers in `-BulkInitServers`, and even there it's wrapped in try/catch, so a permission change degrades to slow-but-working rather than a failure.

Rule of thumb: add a server to `-BulkInitServers` if it has a large schema you want triggers or tables from. Leave it off if the plain run already works. If you add a server and want its triggers, make sure `"Triggers"` isn't in that server's `$Exclude.Types` entry. The two settings are independent, so keep them consistent yourself.

## Git behaviour

`$RootDir` is meant to be a subfolder inside an existing git repo, not the repo root. The script:

- Finds the real repo root with `git rev-parse --show-toplevel`.
- Never runs `git init`, so it can't create a nested repo by accident. If `$RootDir` isn't inside a repo, the git step is skipped with a warning.
- Stages and commits only `$RootDir`, leaving anything else in the repo alone.
- Auto-generates a commit message like:
  `Daily schema export 2026-01-01 02:00 | ServerA, ServerB | 1423 objects, 7 file change(s), clean`

One-time setup, create the repo by hand at the true root before enabling git:

```powershell
cd C:\path\to\repo-root
git init
git config user.name  "Schema Export"
git config user.email "schema-export@example.com"
```

### No-churn design

So the nightly commit only shows real schema changes, output is byte-stable between runs:

- Object files have no timestamp. The `USE [db]` header is fixed text, not SMO's changing `Script Date` banner.
- Placeholder files (encrypted / failed / timed-out objects) have no timestamp either.
- Files are UTF-8 without BOM, trimmed, with one trailing newline, so an unchanged object produces identical bytes.

The generated `README.md` summaries do include run timestamps, so those files show a diff every night by design. The object `.sql` files don't.

### Reviewing changes before committing (VS Code)

To eyeball changes first, keep `GitEnabled = $false` and commit by hand. In VS Code, open Source Control (`Ctrl+Shift+G`), click a modified file (orange **M**) to see a side-by-side diff, or use the Timeline view for a file's full history.

## Scheduling a nightly run (Task Scheduler)

Create the task once from an elevated PowerShell. Adjust the account, time, and paths.

```powershell
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument '-NoProfile -ExecutionPolicy Bypass -Command "Start-Transcript -Path C:\Logs\schema-export.log -Append; & ''C:\path\to\export-all-schema.ps1'' -EnableGit:$true; Stop-Transcript"'

$trigger = New-ScheduledTaskTrigger -Daily -At 2:00AM

$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable -DontStopOnIdleEnd `
    -ExecutionTimeLimit (New-TimeSpan -Hours 2)

Register-ScheduledTask -TaskName "SQL Schema Export (nightly)" `
    -Action $action -Trigger $trigger -Settings $settings `
    -RunLevel Highest `
    -User "DOMAIN\serviceaccount" -Password 'thepassword'
```

What matters:

- The run account is what connects to SQL. A domain service account is best, it survives your password changes and works whether or not you're logged in. It needs SQL rights to read schema metadata on every target server, plus its own git credentials and commit identity if you're pushing.
- `-ExecutionPolicy Bypass` and `-NoProfile` keep the run predictable, `-RunLevel Highest` runs elevated.
- `-StartWhenAvailable` runs at next wake if the machine was off at the scheduled time.
- `-ExecutionTimeLimit` kills a hung run instead of letting it sit forever.
- `Start-Transcript` captures output, since unattended runs are otherwise invisible. Create the log folder first and make sure the account can write there.

Before trusting the schedule, run it once with `Start-ScheduledTask` and check the log and the repo. Confirm the task account (not your interactive session) can reach SQL and push. The classic failure is that it works when you run it but fails overnight because the service account lacks SQL rights or git credentials.

## How resilience works

- Each object is scripted in a child runspace with a wall-clock limit. A stuck object is abandoned and written as a placeholder, so one bad object can't hang the whole run.
- Encrypted objects can't be scripted, so they get a placeholder `.sql` explaining why.
- Failures and timeouts still produce a `.sql` file with the reason commented out, so an empty-looking file explains itself.
- An unreachable server is logged, marked `UNREACHABLE`, and the run moves on.
- Objects are scripted independently (`WithDependencies = $false`) to avoid SMO dependency-walk hangs.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Hangs silently for minutes, often around Triggers | Per-table trigger enumeration on a large schema | Add the server to `-BulkInitServers`. A heartbeat line shows it's working, not frozen. |
| "0 user database(s) found" plus an enumeration exception | Bulk-init is on for a server whose login can't read some property, or a real permissions change | Remove that server from `-BulkInitServers`. If it still fails, check rights with `SELECT name, state_desc, HAS_DBACCESS(name) FROM sys.databases`. |
| `USE [db] / GO` header missing | Old version with `IncludeHeaders` off and no header prepend | Re-run with the current script; it prepends the header itself. |
| An extra blank line accrues each run | Re-read/re-write kept appending a newline | Fixed. Files are trimmed to one trailing newline. |
| Git step creates a repo inside `$RootDir` | Old behaviour ran `git init` | Current version never inits. Create the repo at the true root by hand. |
| Every file shows as modified after upgrading | Output format changed (header, whitespace, no BOM) | Expected once. Commit that baseline, then only real changes diff. |

## Safety

- Read-only against SQL Server. No DDL/DML is ever run.
- Table data is never exported, schema only.
- Agent job scripts can contain connection strings, proxy accounts, or credentials. Review the `_ServerLevel/Agent Jobs` output before committing to a shared or public remote.

## Before you publish

If you point this at your own servers and commit the output to a public repo, the exported `.sql` files, the generated `README.md` summaries, and the commit messages will all contain your real server names, database names, object names, and the machine and user that ran the export. Agent job scripts can hold more sensitive details still. Review what you're committing, and keep real schema output in a private repo.
