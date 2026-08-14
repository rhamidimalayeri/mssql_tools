/* ============================================================
   Find stored procedures across databases by NAME and/or BODY,
   or catalog every proc's metadata.
   Restructured into GO-separated batches so no query ever
   references a temp table created in its own batch (which is
   what triggered the "Invalid column name" compile errors).

   Parameters live in ##cfg (global one-row table) so they
   survive across GO boundaries.

   KEY OPTIONS (edit in Batch 1):
     @db_like      NULL = all databases; else name or LIKE pattern
                   ('db', '%db%')
     @name_cols    substring patterns for the PROC NAME (NULL=skip)
     @body_cols    substring patterns for the PROC TEXT (NULL=skip)
     @output_mode  SUMMARY | DETAIL | PARAMS | FULLTEXT | CATALOG
                   CATALOG ignores name/body filters and returns
                   metadata for EVERY proc in the targeted db(s).

   EDIT PARAMETERS in the first batch below.
   ============================================================ */

/* ---------- BATCH 1: parameters + cleanup ---------- */
DROP TABLE IF EXISTS ##cfg;
DROP TABLE IF EXISTS ##matches;
DROP TABLE IF EXISTS ##params;
DROP TABLE IF EXISTS ##alllines;
DROP TABLE IF EXISTS ##proc_report;
DROP TABLE IF EXISTS ##wanted_name;
DROP TABLE IF EXISTS ##wanted_body;

CREATE TABLE ##cfg (
    db_like          NVARCHAR(256),
    name_cols        NVARCHAR(MAX),
    body_cols        NVARCHAR(MAX),
    match_mode       VARCHAR(3),
    name_mode        VARCHAR(3),
    schema_like      NVARCHAR(256),
    output_mode      VARCHAR(8),
    include_full_text BIT,
    context_lines    INT,
    debug            BIT
);

INSERT INTO ##cfg VALUES (
    NULL,                       -- @db_like     'db' / '%db%' / NULL=all databases
    NULL,                       -- @name_cols   (NULL/''=skip name filter)
    'patient_poverty_detail',   -- @body_cols   (NULL/''=skip body filter)
    'ALL',                      -- @match_mode  ALL|ANY  (body patterns)
    'ANY',                      -- @name_mode   ALL|ANY  (name patterns)
    NULL,                       -- @schema_like 'dbo' / '%rpt%' / NULL=all
    'SUMMARY',                  -- @output_mode SUMMARY|DETAIL|PARAMS|FULLTEXT|CATALOG
    1,                          -- @include_full_text
    2,                          -- @context_lines
    0                           -- @debug
);
/* ------------------------------------------------------------
   CATALOG mode: set output_mode='CATALOG' to IGNORE the name/body
   filters and return metadata for EVERY proc in the targeted
   database(s). Combine with @db_like to scope to one database.
   ------------------------------------------------------------ */
GO

/* ---------- BATCH 2: split patterns ---------- */
SELECT LTRIM(RTRIM(value)) AS pat
INTO ##wanted_name
FROM ##cfg CROSS APPLY STRING_SPLIT(ISNULL((SELECT name_cols FROM ##cfg), ''), ',')
WHERE LTRIM(RTRIM(value)) <> '';

SELECT LTRIM(RTRIM(value)) AS pat
INTO ##wanted_body
FROM ##cfg CROSS APPLY STRING_SPLIT(ISNULL((SELECT body_cols FROM ##cfg), ''), ',')
WHERE LTRIM(RTRIM(value)) <> '';
GO

/* ---------- BATCH 3: PASS 1 — matches + metadata ---------- */
CREATE TABLE ##matches (
    database_name    SYSNAME,
    schema_name      SYSNAME,
    proc_name        SYSNAME,
    object_id        INT,
    pattern_matched  NVARCHAR(256),
    match_kind       VARCHAR(4),
    object_type      NVARCHAR(60),
    definition       NVARCHAR(MAX),
    line_count       INT,
    char_count       INT,
    param_count      INT,
    is_encrypted     BIT,
    uses_dynamic_sql BIT,
    references_count INT,
    referenced_by    INT,
    created_date     DATETIME,
    modified_date    DATETIME
);

DECLARE @schema_like NVARCHAR(256) = (SELECT schema_like FROM ##cfg);
DECLARE @db_like     NVARCHAR(256) = (SELECT db_like     FROM ##cfg);
DECLARE @is_catalog  BIT           = CASE WHEN (SELECT output_mode FROM ##cfg) = 'CATALOG' THEN 1 ELSE 0 END;
DECLARE @schema_pred NVARCHAR(200) = CASE WHEN @schema_like IS NULL THEN N'1=1' ELSE N's.name LIKE @slike' END;
DECLARE @sql NVARCHAR(MAX) = N'';

IF @is_catalog = 1
BEGIN
    /* CATALOG: one row per proc, name/body filters ignored */
    SELECT @sql = @sql + N'
USE ' + QUOTENAME(name) + N';
INSERT INTO ##matches
SELECT DB_NAME(), s.name, p.name, p.object_id, ''(all)'', ''CAT'',
       p.type_desc, m.definition,
       CASE WHEN m.definition IS NULL THEN NULL
            ELSE LEN(m.definition) - LEN(REPLACE(m.definition, CHAR(10), '''')) + 1 END,
       LEN(m.definition),
       (SELECT COUNT(*) FROM sys.parameters pr WHERE pr.object_id = p.object_id),
       CAST(CASE WHEN m.definition IS NULL THEN 1 ELSE 0 END AS BIT),
       CAST(CASE WHEN m.definition LIKE ''%sp_executesql%''
                   OR m.definition LIKE ''%EXEC(%''
                   OR m.definition LIKE ''%EXECUTE(%'' THEN 1 ELSE 0 END AS BIT),
       (SELECT COUNT(*) FROM sys.sql_expression_dependencies d WHERE d.referencing_id = p.object_id),
       (SELECT COUNT(*) FROM sys.sql_expression_dependencies d WHERE d.referenced_id = p.object_id),
       p.create_date, p.modify_date
FROM sys.procedures p
JOIN sys.schemas s ON p.schema_id = s.schema_id
LEFT JOIN sys.sql_modules m ON m.object_id = p.object_id
WHERE (' + @schema_pred + N');'
    FROM sys.databases
    WHERE state = 0
      AND name NOT IN ('master','tempdb','model','msdb')
      AND HAS_DBACCESS(name) = 1
      AND (@db_like IS NULL OR name LIKE @db_like);
END
ELSE
BEGIN
    /* SEARCH: name and/or body pattern matches */
    SELECT @sql = @sql + N'
USE ' + QUOTENAME(name) + N';

INSERT INTO ##matches
SELECT DB_NAME(), s.name, p.name, p.object_id, wn.pat, ''NAME'',
       p.type_desc, m.definition,
       CASE WHEN m.definition IS NULL THEN NULL
            ELSE LEN(m.definition) - LEN(REPLACE(m.definition, CHAR(10), '''')) + 1 END,
       LEN(m.definition),
       (SELECT COUNT(*) FROM sys.parameters pr WHERE pr.object_id = p.object_id),
       CAST(CASE WHEN m.definition IS NULL THEN 1 ELSE 0 END AS BIT),
       CAST(CASE WHEN m.definition LIKE ''%sp_executesql%''
                   OR m.definition LIKE ''%EXEC(%''
                   OR m.definition LIKE ''%EXECUTE(%'' THEN 1 ELSE 0 END AS BIT),
       (SELECT COUNT(*) FROM sys.sql_expression_dependencies d WHERE d.referencing_id = p.object_id),
       (SELECT COUNT(*) FROM sys.sql_expression_dependencies d WHERE d.referenced_id = p.object_id),
       p.create_date, p.modify_date
FROM sys.procedures p
JOIN sys.schemas s ON p.schema_id = s.schema_id
LEFT JOIN sys.sql_modules m ON m.object_id = p.object_id
JOIN ##wanted_name wn ON p.name LIKE ''%'' + wn.pat + ''%''
WHERE (' + @schema_pred + N');

INSERT INTO ##matches
SELECT DB_NAME(), s.name, p.name, p.object_id, wb.pat, ''BODY'',
       p.type_desc, m.definition,
       LEN(m.definition) - LEN(REPLACE(m.definition, CHAR(10), '''')) + 1,
       LEN(m.definition),
       (SELECT COUNT(*) FROM sys.parameters pr WHERE pr.object_id = p.object_id),
       CAST(0 AS BIT),
       CAST(CASE WHEN m.definition LIKE ''%sp_executesql%''
                   OR m.definition LIKE ''%EXEC(%''
                   OR m.definition LIKE ''%EXECUTE(%'' THEN 1 ELSE 0 END AS BIT),
       (SELECT COUNT(*) FROM sys.sql_expression_dependencies d WHERE d.referencing_id = p.object_id),
       (SELECT COUNT(*) FROM sys.sql_expression_dependencies d WHERE d.referenced_id = p.object_id),
       p.create_date, p.modify_date
FROM sys.procedures p
JOIN sys.schemas s ON p.schema_id = s.schema_id
JOIN sys.sql_modules m ON m.object_id = p.object_id
JOIN ##wanted_body wb ON m.definition LIKE ''%'' + wb.pat + ''%''
WHERE (' + @schema_pred + N');'
    FROM sys.databases
    WHERE state = 0
      AND name NOT IN ('master','tempdb','model','msdb')
      AND HAS_DBACCESS(name) = 1
      AND (@db_like IS NULL OR name LIKE @db_like);
END

EXEC sys.sp_executesql @sql, N'@slike NVARCHAR(256)', @slike = @schema_like;
GO

/* ---------- BATCH 4: PASS 2 — parameters ---------- */
CREATE TABLE ##params (
    database_name SYSNAME, schema_name SYSNAME, proc_name SYSNAME,
    param_id INT, param_name SYSNAME, data_type SYSNAME,
    max_length INT, is_output BIT, has_default BIT
);

DECLARE @sqlp NVARCHAR(MAX) = N'';
SELECT @sqlp = @sqlp + N'
USE ' + QUOTENAME(name) + N';
INSERT INTO ##params
SELECT DB_NAME(), s.name, p.name, pr.parameter_id,
       CASE WHEN pr.name = '''' THEN ''(return)'' ELSE pr.name END,
       ty.name, pr.max_length, pr.is_output, pr.has_default_value
FROM sys.procedures p
JOIN sys.schemas s ON p.schema_id = s.schema_id
JOIN sys.parameters pr ON pr.object_id = p.object_id
JOIN sys.types ty ON ty.user_type_id = pr.user_type_id
JOIN (SELECT DISTINCT schema_name, proc_name FROM ##matches WHERE database_name = DB_NAME()) mt
  ON mt.schema_name = s.name AND mt.proc_name = p.name;'
FROM sys.databases
WHERE state = 0
  AND name NOT IN ('master','tempdb','model','msdb')
  AND HAS_DBACCESS(name) = 1
  AND EXISTS (SELECT 1 FROM ##matches m WHERE m.database_name = name);

EXEC sys.sp_executesql @sqlp;
GO

/* ---------- BATCH 5: PASS 3 — proc lines (DETAIL only) ---------- */
CREATE TABLE ##alllines (
    database_name SYSNAME, schema_name SYSNAME, proc_name SYSNAME,
    line_no INT, line_text NVARCHAR(MAX)
);

IF (SELECT output_mode FROM ##cfg) = 'DETAIL'
   AND EXISTS (SELECT 1 FROM ##wanted_body)
BEGIN
    DECLARE @sql3 NVARCHAR(MAX) = N'';
    SELECT @sql3 = @sql3 + N'
USE ' + QUOTENAME(name) + N';
;WITH lines AS (
    SELECT s.name AS schema_name, p.name AS proc_name,
           ROW_NUMBER() OVER (ORDER BY (SELECT 1)) AS line_no,
           x.ln.value(''.'', ''NVARCHAR(MAX)'') AS line_text
    FROM sys.procedures p
    JOIN sys.schemas s ON p.schema_id = s.schema_id
    JOIN sys.sql_modules m ON m.object_id = p.object_id
    CROSS APPLY (
        SELECT CAST(''<a><b>'' +
            REPLACE(REPLACE(REPLACE(m.definition,''&'',''&amp;''),''<'',''&lt;''),CHAR(10),''</b><b>'')
            + ''</b></a>'' AS XML) AS doc
    ) parsed
    CROSS APPLY parsed.doc.nodes(''/a/b'') AS x(ln)
    JOIN (SELECT DISTINCT schema_name, proc_name FROM ##matches
          WHERE database_name = DB_NAME() AND match_kind = ''BODY'') mt
      ON mt.schema_name = s.name AND mt.proc_name = p.name
)
INSERT INTO ##alllines
SELECT DB_NAME(), schema_name, proc_name, line_no, line_text FROM lines;'
    FROM sys.databases
    WHERE state = 0
      AND name NOT IN ('master','tempdb','model','msdb')
      AND HAS_DBACCESS(name) = 1
      AND EXISTS (SELECT 1 FROM ##matches m WHERE m.database_name = name AND m.match_kind = 'BODY');

    IF LEN(@sql3) > 0 EXEC sys.sp_executesql @sql3;
END
GO

/* ---------- BATCH 6: build ##proc_report ---------- */
DECLARE @name_count INT = (SELECT COUNT(*) FROM ##wanted_name);
DECLARE @body_count INT = (SELECT COUNT(*) FROM ##wanted_body);
DECLARE @match_mode VARCHAR(3) = (SELECT match_mode FROM ##cfg);
DECLARE @name_mode  VARCHAR(3) = (SELECT name_mode  FROM ##cfg);
DECLARE @incl BIT   = (SELECT include_full_text FROM ##cfg);
DECLARE @is_catalog BIT = CASE WHEN (SELECT output_mode FROM ##cfg) = 'CATALOG' THEN 1 ELSE 0 END;

CREATE TABLE ##proc_report (
    database_name           SYSNAME,
    schema_name             SYSNAME,
    proc_name               SYSNAME,
    object_type             NVARCHAR(60),
    patterns_found          NVARCHAR(MAX),
    parameter_signature     NVARCHAR(MAX),
    name_patterns_matched   INT,
    body_patterns_matched   INT,
    requested_name_patterns INT,
    requested_body_patterns INT,
    param_count             INT,
    line_count              INT,
    char_count              INT,
    is_encrypted            INT,
    uses_dynamic_sql        INT,
    references_count        INT,
    referenced_by           INT,
    created_date            DATETIME,
    modified_date           DATETIME,
    full_definition         NVARCHAR(MAX)
);

;WITH grouped AS (
    SELECT
        database_name, schema_name, proc_name,
        MAX(object_type)      AS object_type,
        MAX(line_count)       AS line_count,
        MAX(char_count)       AS char_count,
        MAX(param_count)      AS param_count,
        MAX(CAST(is_encrypted AS INT))     AS is_encrypted,
        MAX(CAST(uses_dynamic_sql AS INT)) AS uses_dynamic_sql,
        MAX(references_count) AS references_count,
        MAX(referenced_by)    AS referenced_by,
        MAX(created_date)     AS created_date,
        MAX(modified_date)    AS modified_date,
        MAX(definition)       AS definition,
        COUNT(DISTINCT CASE WHEN match_kind='BODY' THEN pattern_matched END) AS body_patterns_matched,
        COUNT(DISTINCT CASE WHEN match_kind='NAME' THEN pattern_matched END) AS name_patterns_matched
    FROM ##matches
    GROUP BY database_name, schema_name, proc_name
    HAVING
        @is_catalog = 1   -- CATALOG mode: keep every proc, ignore filters
        OR (
        (
            @body_count = 0
         OR (@match_mode='ANY' AND COUNT(DISTINCT CASE WHEN match_kind='BODY' THEN pattern_matched END) >= 1)
         OR (@match_mode='ALL' AND COUNT(DISTINCT CASE WHEN match_kind='BODY' THEN pattern_matched END) = @body_count)
        )
        AND
        (
            @name_count = 0
         OR (@name_mode='ANY' AND COUNT(DISTINCT CASE WHEN match_kind='NAME' THEN pattern_matched END) >= 1)
         OR (@name_mode='ALL' AND COUNT(DISTINCT CASE WHEN match_kind='NAME' THEN pattern_matched END) = @name_count)
        )
        )
)
INSERT INTO ##proc_report
SELECT
    g.database_name, g.schema_name, g.proc_name, g.object_type,
    STUFF((
        SELECT ', ' + m2.pattern_matched + ' [' + m2.match_kind + ']'
        FROM (SELECT DISTINCT pattern_matched, match_kind FROM ##matches m3
              WHERE m3.database_name = g.database_name
                AND m3.schema_name   = g.schema_name
                AND m3.proc_name     = g.proc_name) m2
        ORDER BY m2.match_kind, m2.pattern_matched
        FOR XML PATH(''), TYPE
    ).value('.', 'NVARCHAR(MAX)'), 1, 2, '') AS patterns_found,
    STUFF((
        SELECT ', ' + pp.param_name + ' ' + pp.data_type
               + CASE WHEN pp.is_output = 1 THEN ' OUT' ELSE '' END
        FROM ##params pp
        WHERE pp.database_name = g.database_name
          AND pp.schema_name   = g.schema_name
          AND pp.proc_name     = g.proc_name
        ORDER BY pp.param_id
        FOR XML PATH(''), TYPE
    ).value('.', 'NVARCHAR(MAX)'), 1, 2, '') AS parameter_signature,
    g.name_patterns_matched, g.body_patterns_matched,
    @name_count, @body_count,
    g.param_count, g.line_count, g.char_count,
    g.is_encrypted, g.uses_dynamic_sql, g.references_count, g.referenced_by,
    g.created_date, g.modified_date,
    CASE WHEN @incl = 1 THEN g.definition ELSE NULL END
FROM grouped g;
GO

/* ---------- BATCH 7: OUTPUT ---------- */
DECLARE @output_mode  VARCHAR(8) = (SELECT output_mode  FROM ##cfg);
DECLARE @context_lines INT       = (SELECT context_lines FROM ##cfg);

IF @output_mode = 'DETAIL'
    SELECT
        r.database_name, r.schema_name, r.proc_name, r.object_type,
        al.line_no,
        CASE WHEN hit.line_no = al.line_no THEN '>>' ELSE '  ' END AS is_hit,
        al.line_text,
        r.param_count, r.line_count, r.char_count,
        r.uses_dynamic_sql, r.references_count, r.referenced_by,
        r.created_date, r.modified_date
    FROM ##proc_report r
    JOIN ##alllines al
      ON al.database_name = r.database_name
     AND al.schema_name   = r.schema_name
     AND al.proc_name     = r.proc_name
    JOIN (
        SELECT DISTINCT a.database_name, a.schema_name, a.proc_name, a.line_no
        FROM ##alllines a
        JOIN ##wanted_body wb ON a.line_text LIKE '%' + wb.pat + '%'
    ) hit
      ON hit.database_name = al.database_name
     AND hit.schema_name   = al.schema_name
     AND hit.proc_name     = al.proc_name
     AND al.line_no BETWEEN hit.line_no - @context_lines AND hit.line_no + @context_lines
    ORDER BY r.database_name, r.schema_name, r.proc_name, al.line_no;
ELSE IF @output_mode = 'PARAMS'
    SELECT
        p.database_name, p.schema_name, p.proc_name,
        p.param_id, p.param_name, p.data_type, p.max_length,
        p.is_output, p.has_default,
        r.line_count, r.char_count, r.uses_dynamic_sql,
        r.created_date, r.modified_date
    FROM ##proc_report r
    JOIN ##params p
      ON p.database_name = r.database_name
     AND p.schema_name   = r.schema_name
     AND p.proc_name     = r.proc_name
    ORDER BY p.database_name, p.schema_name, p.proc_name, p.param_id;
ELSE IF @output_mode = 'FULLTEXT'
    SELECT
        database_name, schema_name, proc_name, object_type,
        patterns_found, parameter_signature,
        param_count, line_count, char_count,
        is_encrypted, uses_dynamic_sql, references_count, referenced_by,
        created_date, modified_date, full_definition
    FROM ##proc_report
    ORDER BY database_name, schema_name, proc_name;
ELSE IF @output_mode = 'CATALOG'
    /* every proc in the targeted db(s), metadata only */
    SELECT
        database_name, schema_name, proc_name, object_type,
        parameter_signature,
        param_count, line_count, char_count,
        is_encrypted, uses_dynamic_sql, references_count, referenced_by,
        created_date, modified_date, full_definition
    FROM ##proc_report
    ORDER BY database_name, schema_name, proc_name;
ELSE  /* SUMMARY */
    SELECT
        database_name, schema_name, proc_name, object_type,
        patterns_found, parameter_signature,
        name_patterns_matched, body_patterns_matched,
        requested_name_patterns, requested_body_patterns,
        param_count, line_count, char_count,
        is_encrypted, uses_dynamic_sql, references_count, referenced_by,
        created_date, modified_date, full_definition
    FROM ##proc_report
    ORDER BY line_count DESC, database_name, schema_name, proc_name;
GO

/* ---------- BATCH 8: cleanup (optional) ----------
   Comment these out if you want to query ##proc_report afterward.
*/
IF (SELECT debug FROM ##cfg) = 0
BEGIN
    DROP TABLE IF EXISTS ##cfg;
    DROP TABLE IF EXISTS ##matches;
    DROP TABLE IF EXISTS ##params;
    DROP TABLE IF EXISTS ##alllines;
    DROP TABLE IF EXISTS ##wanted_name;
    DROP TABLE IF EXISTS ##wanted_body;
    -- ##proc_report kept so you can re-query it in another window
END
GO
