/* ============================================================
   Find tables across ALL databases containing 1 or many columns,
   enriched with row counts and table metadata.
   Column matching is always LIKE %pattern% (substring).
   Works on SQL Server 2016 and earlier (no STRING_AGG).
   @match_mode  = 'ALL'      -> table must match every listed pattern
   @match_mode  = 'ANY'      -> table matches at least one (ranked by count)
   @row_filter  = 'ALL'      -> return every matched table
   @row_filter  = 'NONZERO'  -> drop empty tables
   @row_filter  = 'CUSTOM'   -> drop tables below @min_rows
   @output_mode = 'SUMMARY'  -> one row per table, matched columns concatenated
   @output_mode = 'DETAIL'   -> one row per column, ALL columns of each table
   @debug       = 1/0        -> run the dev/scratch section at the bottom
   ============================================================ */

DECLARE @cols        NVARCHAR(MAX) = 'col_name';          -- comma-separated patterns
DECLARE @match_mode  VARCHAR(3)    = 'any';               -- 'ALL' or 'ANY'
DECLARE @table_like  NVARCHAR(256) = NULL;                -- 'table' / '%table%' / NULL = all
DECLARE @row_filter  VARCHAR(10)   = 'NONZERO';           -- 'ALL', 'NONZERO', 'CUSTOM'
DECLARE @min_rows    BIGINT        = 1000;                -- used only when CUSTOM
DECLARE @output_mode VARCHAR(7)    = 'SUMMARY';           -- 'SUMMARY' or 'DETAIL'
DECLARE @debug       BIT           = 0;                   -- 1 = run dev section, 0 = skip it

/* Split the requested patterns once */
DROP TABLE IF EXISTS #wanted;
SELECT LTRIM(RTRIM(value)) AS col_name
INTO #wanted
FROM STRING_SPLIT(@cols, ',')
WHERE LTRIM(RTRIM(value)) <> '';

DECLARE @wanted_count INT = (SELECT COUNT(*) FROM #wanted);

/* ============================================================
   PASS 1 — columns matching the patterns, + table metadata
   ============================================================ */
DROP TABLE IF EXISTS #matches;
CREATE TABLE #matches (
    database_name   SYSNAME,
    schema_name     SYSNAME,
    table_name      SYSNAME,
    object_id       INT,
    column_name     SYSNAME,
    data_type       SYSNAME,
    pattern_matched SYSNAME,
    row_count       BIGINT,
    total_mb        DECIMAL(18,2),
    used_mb         DECIMAL(18,2),
    total_columns   INT,
    index_count     INT,
    has_primary_key BIT,
    created_date    DATETIME,
    modified_date   DATETIME
);

DECLARE @sql NVARCHAR(MAX) = N'';

SELECT @sql = @sql + N'
USE ' + QUOTENAME(name) + N';
INSERT INTO #matches
SELECT
    DB_NAME(), s.name, t.name, t.object_id, c.name, ty.name, w.col_name,
    rc.row_count,
    CAST(sp.total_pages * 8.0 / 1024 AS DECIMAL(18,2)),
    CAST(sp.used_pages  * 8.0 / 1024 AS DECIMAL(18,2)),
    cc.col_count,
    ic.idx_count,
    CASE WHEN pk.object_id IS NOT NULL THEN 1 ELSE 0 END,
    t.create_date, t.modify_date
FROM sys.columns c
JOIN sys.tables  t  ON c.object_id = t.object_id
JOIN sys.schemas s  ON t.schema_id = s.schema_id
JOIN sys.types   ty ON c.user_type_id = ty.user_type_id
JOIN #wanted     w  ON c.name LIKE ''%'' + w.col_name + ''%''
OUTER APPLY (
    SELECT SUM(ps.row_count) AS row_count
    FROM sys.dm_db_partition_stats ps
    WHERE ps.object_id = t.object_id AND ps.index_id IN (0,1)
) rc
OUTER APPLY (
    SELECT SUM(au.total_pages) AS total_pages, SUM(au.used_pages) AS used_pages
    FROM sys.partitions p
    JOIN sys.allocation_units au ON au.container_id = p.partition_id
    WHERE p.object_id = t.object_id
) sp
OUTER APPLY (
    SELECT COUNT(*) AS col_count FROM sys.columns cc2 WHERE cc2.object_id = t.object_id
) cc
OUTER APPLY (
    SELECT COUNT(*) AS idx_count FROM sys.indexes ix
    WHERE ix.object_id = t.object_id AND ix.index_id > 0
) ic
OUTER APPLY (
    SELECT TOP 1 kc.object_id FROM sys.key_constraints kc
    WHERE kc.parent_object_id = t.object_id AND kc.type = ''PK''
) pk
WHERE (' + CASE WHEN @table_like IS NULL THEN N'1=1'
               ELSE N't.name LIKE @tlike' END + N');'
FROM sys.databases
WHERE state = 0
  AND name NOT IN ('master','tempdb','model','msdb')
  AND HAS_DBACCESS(name) = 1;

EXEC sys.sp_executesql @sql, N'@tlike NVARCHAR(256)', @tlike = @table_like;

/* ============================================================
   PASS 2 — ALL columns of each matched table (used by DETAIL mode)
   ============================================================ */
DROP TABLE IF EXISTS #allcols;
CREATE TABLE #allcols (
    database_name SYSNAME,
    schema_name   SYSNAME,
    table_name    SYSNAME,
    column_id     INT,
    column_name   SYSNAME,
    data_type     SYSNAME,
    max_length    INT,
    is_nullable   BIT,
    is_identity   BIT,
    is_pk_column  BIT
);

DECLARE @sql2 NVARCHAR(MAX) = N'';
SELECT @sql2 = @sql2 + N'
USE ' + QUOTENAME(name) + N';
INSERT INTO #allcols
SELECT DB_NAME(), s.name, t.name, c.column_id, c.name, ty.name,
       c.max_length, c.is_nullable, c.is_identity,
       CASE WHEN pkc.column_id IS NOT NULL THEN 1 ELSE 0 END
FROM sys.columns c
JOIN sys.tables  t  ON c.object_id = t.object_id
JOIN sys.schemas s  ON t.schema_id = s.schema_id
JOIN sys.types   ty ON c.user_type_id = ty.user_type_id
JOIN (SELECT DISTINCT database_name, schema_name, table_name
      FROM #matches WHERE database_name = DB_NAME()) mt
  ON mt.schema_name = s.name AND mt.table_name = t.name
LEFT JOIN (
    SELECT ic.object_id, ic.column_id
    FROM sys.index_columns ic
    JOIN sys.key_constraints kc ON kc.parent_object_id = ic.object_id
                               AND kc.unique_index_id  = ic.index_id
                               AND kc.type = ''PK''
) pkc ON pkc.object_id = c.object_id AND pkc.column_id = c.column_id;'
FROM sys.databases
WHERE state = 0
  AND name NOT IN ('master','tempdb','model','msdb')
  AND HAS_DBACCESS(name) = 1
  AND EXISTS (SELECT 1 FROM #matches m WHERE m.database_name = name);  -- skip dbs with no hits

EXEC sys.sp_executesql @sql2;

/* ============================================================
   Build the grouped table list (ALL/ANY + row filter) into ##report
   ============================================================ */
DROP TABLE IF EXISTS ##report;

;WITH grouped AS (
    SELECT
        database_name, schema_name, table_name,
        MAX(row_count)       AS row_count,
        MAX(total_mb)        AS total_mb,
        MAX(used_mb)         AS used_mb,
        MAX(total_columns)   AS total_columns,
        MAX(index_count)     AS index_count,
        MAX(CAST(has_primary_key AS INT)) AS has_primary_key,
        MAX(created_date)    AS created_date,
        MAX(modified_date)   AS modified_date,
        COUNT(DISTINCT pattern_matched) AS patterns_matched
    FROM #matches
    GROUP BY database_name, schema_name, table_name
    HAVING
        (@match_mode = 'ANY')
     OR (@match_mode = 'ALL' AND COUNT(DISTINCT pattern_matched) = @wanted_count)
)
SELECT
    g.database_name,
    g.schema_name,
    g.table_name,
    STUFF((
        SELECT ', ' + m2.column_name + ' (' + m2.data_type + ')'
        FROM (
            SELECT DISTINCT column_name, data_type
            FROM #matches m3
            WHERE m3.database_name = g.database_name
              AND m3.schema_name   = g.schema_name
              AND m3.table_name    = g.table_name
        ) m2
        ORDER BY m2.column_name
        FOR XML PATH(''), TYPE
    ).value('.', 'NVARCHAR(MAX)'), 1, 2, '') AS columns_found,
    g.row_count,
    g.total_mb,
    g.used_mb,
    g.total_columns,
    g.patterns_matched,
    @wanted_count AS requested_patterns,
    g.index_count,
    g.has_primary_key,
    g.created_date,
    g.modified_date
INTO ##report
FROM grouped g
WHERE
    (@row_filter = 'ALL')
 OR (@row_filter = 'NONZERO' AND ISNULL(g.row_count, 0) > 0)
 OR (@row_filter = 'CUSTOM'  AND ISNULL(g.row_count, 0) >= @min_rows);

/* ============================================================
   OUTPUT — SUMMARY (one row per table) or DETAIL (one row per column)
   DETAIL result is also persisted to ##report_detail.
   ============================================================ */
DROP TABLE IF EXISTS ##report_detail;

SELECT
    r.database_name,
    r.schema_name,
    r.table_name,
    a.column_id,
    a.column_name,
    a.data_type,
    a.max_length,
    a.is_nullable,
    a.is_identity,
    a.is_pk_column,
    CASE WHEN EXISTS (
        SELECT 1 FROM #matches mm
        WHERE mm.database_name = r.database_name
          AND mm.schema_name   = r.schema_name
          AND mm.table_name    = r.table_name
          AND mm.column_name   = a.column_name
    ) THEN 1 ELSE 0 END AS is_matched_column,
    r.row_count,
    r.total_mb,
    r.used_mb,
    r.total_columns,
    r.patterns_matched,
    r.requested_patterns,
    r.index_count,
    r.has_primary_key,
    r.created_date,
    r.modified_date
INTO ##report_detail
FROM ##report r
JOIN #allcols a
  ON a.database_name = r.database_name
 AND a.schema_name   = r.schema_name
 AND a.table_name    = r.table_name;

IF @output_mode = 'DETAIL'
    SELECT *
    FROM ##report_detail
    ORDER BY database_name, schema_name, table_name, column_id;
ELSE
    SELECT *
    FROM ##report
    ORDER BY database_name, schema_name, table_name, row_count DESC, patterns_matched DESC;

/* ════════════════════════════════════════════════════════════
   DEV / SCRATCH AREA — runs only when @debug = 1.
   ##report (one row per table) and ##report_detail (one row per column)
   both persist, so you can reference either here or in a separate window.
   ════════════════════════════════════════════════════════════ */
IF @debug = 1
BEGIN

    SELECT TOP 10 * FROM ##report;
    SELECT TOP 100 * FROM ##report_detail;
    -- SELECT TOP 100 * FROM NGProd.dbo.claim_charges;

END
GO
