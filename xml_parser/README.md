# SQL Trace / Extended Events Search

A Jupyter notebook that searches a SQL Server trace or Extended Events XML export for events whose SQL text contains a target substring (a GUID, a table name, a login, anything), then reports which SPIDs ran it and prints the formatted SQL for each one.

Handy for questions like "who touched this record?" or "which session ran this statement?" when all you have is a big trace file.

## What it does

- Reads a Profiler trace or Extended Events XML file.
- Finds every event whose SQL text contains your search string (case-insensitive).
- Groups the matches by SPID, with the login, host, application, and database for each.
- De-duplicates the SQL per SPID and shows how many times each statement appeared.
- Formats every statement with consistent indentation and upper-cased keywords.
- Writes a plain-text report and prints the same summary inline in the notebook.

It understands both formats:

- Classic Profiler traces (`Event` / `Column` elements).
- Extended Events sessions (`event` / `data` / `action` elements).

## Why a notebook

Trace files are messy. Encodings vary, and exports often contain invalid XML character references that make a plain parser throw. Running this in a notebook lets you re-run one cell at a time, see the encoding it detected, and adjust the search without rerunning everything.

## Requirements

- Python 3.8+
- `sqlparse` for SQL formatting:
  ```
  pip install sqlparse
  ```
- `lxml` is optional. Only needed as a fallback if a file is too broken for the built-in parser (the notebook prints the snippet to use if that happens).
  ```
  pip install lxml
  ```

## Setup

1. Open `trace_search.ipynb` in Jupyter or VS Code.
2. Edit the **Configuration** cell:
   - `XML_PATH` - full path to your trace/XE XML file.
   - `OUTPUT_PATH` - folder for the report (created if missing).
   - `OUTPUT_FILE` - report file name.
   - `SEARCH_TEXT` - the substring to look for.
   - `SKIP_EVENT_CLASSES` - event classes to drop as connection noise. The defaults cover login/logout churn; add more if your trace is noisy.
3. Run all cells.

## Output

The report is written to `OUTPUT_PATH/OUTPUT_FILE` and printed inline. It contains:

- An event-class breakdown before filtering, so you can see what got skipped.
- One section per SPID: session details, the count of unique statements, and each formatted statement with its first-seen timestamp and event class.

Example shape:

```
Found 12 relevant event(s) across 3 SPID(s).
Distinct SPIDs: [53, 78, 91]

========================================================================
SPID: 53   (5 event(s))
========================================================================
  login      : APP\svc_reports
  host       : APPSERVER01
  application: .Net SqlClient Data Provider
  database   : MyDatabase

  Unique SQL statements: 2
  ----------------------------------------------------------------------

  [1] 2026-01-01 09:14:22.100   (RPC:Completed)
      SELECT ...
```

## How encoding detection works

Trace exports arrive as UTF-8, UTF-8 with BOM, or UTF-16, sometimes with no BOM at all. The notebook reads the first bytes, decides the encoding, strips a BOM if present, and removes invalid XML character references before parsing. If a file still won't parse, the notebook prints a short `lxml` recover-mode snippet you can drop in.

## Notes and limits

- Search is a plain case-insensitive substring match, not a regex.
- The report is grouped by SPID. A SPID is reused across connections over time, so if your trace spans a long window the same SPID can represent different sessions. The session details flag anything that varies within a SPID as `[varies: ...]`.
- Table data and full statement text from the trace are written to the report as-is. If the SQL contains sensitive values, treat the output file accordingly.

## Before you share the output

The report contains real logins, host names, application names, database names, and the full SQL text from your trace. Don't commit it to a public repo. Keep report output somewhere private, and share only the notebook.
