/* ============================================================
   BUILD SCRIPT — PipelineAnalytics (Databricks SQL)
   Horizon Data Predictive Model
   ============================================================
   Purpose  : Implements and executes all stored procedures that
              transform raw data into analytical outputs.
              Parallel to sql/sqlserver/02_build.sql.

   Usage    : 1. Ensure 01_setup.sql has been run.
              2. Load raw data into pipeline_analytics.stg_raw_data.
              3. Set catalog in Section 1 if not using default.
              4. Execute this script. Section 4 calls usp_RunBuild.

   Key Databricks vs SQL Server syntax differences:
              - CALL instead of EXEC
              - Parameters without @ prefix
              - DATEDIFF(end, start) — note reversed argument order
              - DATE_ADD(date, n) instead of DATEADD(day, n, date)
              - MAKE_DATE(y, m, d) instead of DATEFROMPARTS
              - JOIN + ROW_NUMBER() replaces CROSS APPLY
              - DECLARE EXIT HANDLER for error handling
              - MAX(key) after INSERT replaces SCOPE_IDENTITY()
              - CREATE OR REPLACE TEMPORARY VIEW for working data

   Sections :
     1. Configuration
     2. Schema additions
     3. Procedure implementations
        3a. usp_LoadRawData
        3b. usp_BuildSegments
        3c. usp_ApplyModel
        3d. usp_BuildPipelineAggregations
        3e. usp_RunBuild
     4. Execute build
   ============================================================ */


/* ============================================================
   SECTION 1 — CONFIGURATION
   ============================================================ */

-- SET CATALOG main;   -- Uncomment and set your catalog name


/* ============================================================
   SECTION 2 — SCHEMA ADDITIONS
   ============================================================ */

ALTER TABLE pipeline_analytics.analytical_segments
    ADD COLUMN IF NOT EXISTS GranularityLevel INT NOT NULL DEFAULT 0;

ALTER TABLE pipeline_analytics.analytical_segments
    ADD COLUMN IF NOT EXISTS Cat1Dropped BOOLEAN NOT NULL DEFAULT false;

ALTER TABLE pipeline_analytics.analytical_segments
    ADD COLUMN IF NOT EXISTS Cat2Dropped BOOLEAN NOT NULL DEFAULT false;

ALTER TABLE pipeline_analytics.analytical_job_results
    ADD COLUMN IF NOT EXISTS DatasetType STRING NOT NULL DEFAULT 'Current';


/* ============================================================
   SECTION 3 — PROCEDURE IMPLEMENTATIONS
   ============================================================ */


/* ────────────────────────────────────────────────────────────
   3a. usp_LoadRawData
   ────────────────────────────────────────────────────────────
   Transforms stg_raw_data into fact_opportunities.
   Maps text category values to dimension surrogate keys,
   derives Status, ResolutionDate, MarginDollars, and timing
   metrics. MERGEs results (upsert).

   Databricks note: DATEDIFF(end, start) returns days.
   ──────────────────────────────────────────────────────────── */
CREATE OR REPLACE PROCEDURE pipeline_analytics.usp_LoadRawData(
    p_build_run_key BIGINT
)
COMMENT 'Transforms stg_raw_data into fact_opportunities with dimension key lookups and derived columns.'
BEGIN

    MERGE INTO pipeline_analytics.fact_opportunities AS tgt
    USING (
        SELECT
            s.OpportunityID,

            COALESCE(sl.ServiceLineKey,   sl_unk.ServiceLineKey)   AS ServiceLineKey,
            COALESCE(ct.ClientTypeKey,    ct_unk.ClientTypeKey)    AS ClientTypeKey,
            COALESCE(ind.IndustryKey,     ind_unk.IndustryKey)     AS IndustryKey,
            COALESCE(nve.NewVsExistingKey,nve_unk.NewVsExistingKey)AS NewVsExistingKey,
            COALESCE(ls.LeadSourceKey,    ls_unk.LeadSourceKey)    AS LeadSourceKey,

            -- Status derived from date fields
            CASE
                WHEN s.StartDate       IS NOT NULL THEN st_started.StatusKey
                WHEN s.SoldDate        IS NOT NULL THEN st_sns.StatusKey
                WHEN s.ClosedLostDate  IS NOT NULL THEN st_lost.StatusKey
                ELSE                                    st_open.StatusKey
            END AS StatusKey,

            s.CreatedDate,
            s.SoldDate,
            s.ClosedLostDate,
            s.StartDate,
            s.Pct50CompleteDate,
            s.Pct100CompleteDate,
            COALESCE(s.SoldDate, s.ClosedLostDate)                AS ResolutionDate,
            s.NetFees,
            s.MarginPct,
            CASE WHEN s.MarginPct IS NOT NULL AND s.NetFees IS NOT NULL
                 THEN s.MarginPct * s.NetFees ELSE NULL END        AS MarginDollars,
            -- DATEDIFF(end, start) in Databricks returns days
            CASE WHEN s.SoldDate IS NOT NULL AND s.StartDate IS NOT NULL
                 THEN DATEDIFF(s.StartDate, s.SoldDate) ELSE NULL END
                 AS DaysSellToStart,
            CASE WHEN s.StartDate IS NOT NULL AND s.Pct50CompleteDate IS NOT NULL
                 THEN DATEDIFF(s.Pct50CompleteDate, s.StartDate) ELSE NULL END
                 AS DaysStartTo50Pct,
            CASE WHEN s.StartDate IS NOT NULL AND s.Pct100CompleteDate IS NOT NULL
                 THEN DATEDIFF(s.Pct100CompleteDate, s.StartDate) ELSE NULL END
                 AS DaysStartTo100Pct,
            CURRENT_TIMESTAMP()                                    AS LoadTimestamp

        FROM pipeline_analytics.stg_raw_data s

        LEFT JOIN pipeline_analytics.dim_service_line    sl
            ON sl.ServiceLineName    = s.ServiceLine
        LEFT JOIN pipeline_analytics.dim_client_type     ct
            ON ct.ClientTypeName     = s.ClientType
        LEFT JOIN pipeline_analytics.dim_industry        ind
            ON ind.IndustryName      = s.Industry
        LEFT JOIN pipeline_analytics.dim_new_vs_existing nve
            ON nve.NewVsExistingName = s.NewVsExisting
        LEFT JOIN pipeline_analytics.dim_lead_source     ls
            ON ls.LeadSourceName     = s.LeadSource

        -- Unknown fallback keys
        JOIN (SELECT ServiceLineKey   FROM pipeline_analytics.dim_service_line
              WHERE ServiceLineName   = 'Unknown') sl_unk
        JOIN (SELECT ClientTypeKey    FROM pipeline_analytics.dim_client_type
              WHERE ClientTypeName    = 'Unknown') ct_unk
        JOIN (SELECT IndustryKey      FROM pipeline_analytics.dim_industry
              WHERE IndustryName      = 'Unknown') ind_unk
        JOIN (SELECT NewVsExistingKey FROM pipeline_analytics.dim_new_vs_existing
              WHERE NewVsExistingName = 'Unknown') nve_unk
        JOIN (SELECT LeadSourceKey    FROM pipeline_analytics.dim_lead_source
              WHERE LeadSourceName    = 'Unknown') ls_unk

        -- Status keys
        JOIN (SELECT StatusKey FROM pipeline_analytics.dim_status
              WHERE StatusName = 'Open Opportunity') st_open
        JOIN (SELECT StatusKey FROM pipeline_analytics.dim_status
              WHERE StatusName = 'Lost')             st_lost
        JOIN (SELECT StatusKey FROM pipeline_analytics.dim_status
              WHERE StatusName = 'Sold/Not Started') st_sns
        JOIN (SELECT StatusKey FROM pipeline_analytics.dim_status
              WHERE StatusName = 'Started')          st_started

    ) AS src ON tgt.OpportunityID = src.OpportunityID

    WHEN MATCHED THEN UPDATE SET
        tgt.ServiceLineKey     = src.ServiceLineKey,
        tgt.ClientTypeKey      = src.ClientTypeKey,
        tgt.IndustryKey        = src.IndustryKey,
        tgt.NewVsExistingKey   = src.NewVsExistingKey,
        tgt.LeadSourceKey      = src.LeadSourceKey,
        tgt.StatusKey          = src.StatusKey,
        tgt.CreatedDate        = src.CreatedDate,
        tgt.SoldDate           = src.SoldDate,
        tgt.ClosedLostDate     = src.ClosedLostDate,
        tgt.StartDate          = src.StartDate,
        tgt.Pct50CompleteDate  = src.Pct50CompleteDate,
        tgt.Pct100CompleteDate = src.Pct100CompleteDate,
        tgt.ResolutionDate     = src.ResolutionDate,
        tgt.NetFees            = src.NetFees,
        tgt.MarginPct          = src.MarginPct,
        tgt.MarginDollars      = src.MarginDollars,
        tgt.DaysSellToStart    = src.DaysSellToStart,
        tgt.DaysStartTo50Pct   = src.DaysStartTo50Pct,
        tgt.DaysStartTo100Pct  = src.DaysStartTo100Pct,
        tgt.LoadTimestamp      = src.LoadTimestamp

    WHEN NOT MATCHED THEN INSERT (
        OpportunityID, ServiceLineKey, ClientTypeKey, IndustryKey,
        NewVsExistingKey, LeadSourceKey, StatusKey,
        CreatedDate, SoldDate, ClosedLostDate, StartDate,
        Pct50CompleteDate, Pct100CompleteDate, ResolutionDate,
        NetFees, MarginPct, MarginDollars,
        DaysSellToStart, DaysStartTo50Pct, DaysStartTo100Pct,
        LoadTimestamp
    ) VALUES (
        src.OpportunityID, src.ServiceLineKey, src.ClientTypeKey, src.IndustryKey,
        src.NewVsExistingKey, src.LeadSourceKey, src.StatusKey,
        src.CreatedDate, src.SoldDate, src.ClosedLostDate, src.StartDate,
        src.Pct50CompleteDate, src.Pct100CompleteDate, src.ResolutionDate,
        src.NetFees, src.MarginPct, src.MarginDollars,
        src.DaysSellToStart, src.DaysStartTo50Pct, src.DaysStartTo100Pct,
        src.LoadTimestamp
    );

END;


/* ────────────────────────────────────────────────────────────
   3b. usp_BuildSegments
   ────────────────────────────────────────────────────────────
   Builds analytical_segments from the training dataset.
   Computes aggregates at all 6 granularity levels for all
   6 outcomes. Uses a temporary view for training data and
   builds all aggregates in a single UNION ALL INSERT.

   See sql/sqlserver/02_build.sql for full algorithm notes.
   ──────────────────────────────────────────────────────────── */
CREATE OR REPLACE PROCEDURE pipeline_analytics.usp_BuildSegments(
    p_min_jobs_per_segment  INT,
    p_training_start        DATE,
    p_training_end          DATE,
    p_build_run_key         BIGINT
)
COMMENT 'Computes segment estimates at all 6 granularity levels for all 6 outcomes from the training dataset.'
BEGIN

    DECLARE v_sk_open  BIGINT DEFAULT (SELECT StatusKey FROM pipeline_analytics.dim_status WHERE StatusName = 'Open Opportunity');
    DECLARE v_sk_sns   BIGINT DEFAULT (SELECT StatusKey FROM pipeline_analytics.dim_status WHERE StatusName = 'Sold/Not Started');
    DECLARE v_sk_start BIGINT DEFAULT (SELECT StatusKey FROM pipeline_analytics.dim_status WHERE StatusName = 'Started');

    -- Training dataset as a temporary view
    CREATE OR REPLACE TEMPORARY VIEW training AS
    SELECT
        OpportunityID, ServiceLineKey, ClientTypeKey, IndustryKey,
        NewVsExistingKey, LeadSourceKey, StatusKey,
        SoldDate, ClosedLostDate, StartDate,
        Pct50CompleteDate, Pct100CompleteDate, ResolutionDate,
        NetFees, MarginPct, MarginDollars,
        DaysSellToStart, DaysStartTo50Pct, DaysStartTo100Pct
    FROM pipeline_analytics.fact_opportunities
    WHERE ResolutionDate BETWEEN p_training_start AND p_training_end;

    -- Clear previous build data (FK-safe order: job results before segments)
    DELETE FROM pipeline_analytics.analytical_job_results    WHERE BuildRunKey <> p_build_run_key;
    DELETE FROM pipeline_analytics.analytical_segments       WHERE BuildRunKey <> p_build_run_key;

    -- Insert all outcomes at all granularity levels in one operation
    INSERT INTO pipeline_analytics.analytical_segments (
        GranularityLevel, OutcomeName, StatusKey,
        ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey, LeadSourceKey,
        OutcomeEstimate, ObservationCount,
        Cat1Dropped, Cat2Dropped, Cat3Dropped, Cat4Dropped, Cat5Dropped,
        BuildRunKey
    )

    -- ════════════════ WinPct (6 levels) ═════════════════════
    SELECT 0,'WinPct',v_sk_open, ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey,LeadSourceKey,
           AVG(CAST(CASE WHEN SoldDate IS NOT NULL THEN 1.0 ELSE 0.0 END AS DECIMAL(18,6))),
           COUNT(*),false,false,false,false,false, p_build_run_key
    FROM training GROUP BY ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey,LeadSourceKey
    UNION ALL
    SELECT 1,'WinPct',v_sk_open, ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey,NULL,
           AVG(CAST(CASE WHEN SoldDate IS NOT NULL THEN 1.0 ELSE 0.0 END AS DECIMAL(18,6))),
           COUNT(*),false,false,false,false,true, p_build_run_key
    FROM training GROUP BY ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey
    UNION ALL
    SELECT 2,'WinPct',v_sk_open, ServiceLineKey,ClientTypeKey,IndustryKey,NULL,NULL,
           AVG(CAST(CASE WHEN SoldDate IS NOT NULL THEN 1.0 ELSE 0.0 END AS DECIMAL(18,6))),
           COUNT(*),false,false,false,true,true, p_build_run_key
    FROM training GROUP BY ServiceLineKey,ClientTypeKey,IndustryKey
    UNION ALL
    SELECT 3,'WinPct',v_sk_open, ServiceLineKey,ClientTypeKey,NULL,NULL,NULL,
           AVG(CAST(CASE WHEN SoldDate IS NOT NULL THEN 1.0 ELSE 0.0 END AS DECIMAL(18,6))),
           COUNT(*),false,false,true,true,true, p_build_run_key
    FROM training GROUP BY ServiceLineKey,ClientTypeKey
    UNION ALL
    SELECT 4,'WinPct',v_sk_open, ServiceLineKey,NULL,NULL,NULL,NULL,
           AVG(CAST(CASE WHEN SoldDate IS NOT NULL THEN 1.0 ELSE 0.0 END AS DECIMAL(18,6))),
           COUNT(*),false,true,true,true,true, p_build_run_key
    FROM training GROUP BY ServiceLineKey
    UNION ALL
    SELECT 5,'WinPct',v_sk_open, NULL,NULL,NULL,NULL,NULL,
           AVG(CAST(CASE WHEN SoldDate IS NOT NULL THEN 1.0 ELSE 0.0 END AS DECIMAL(18,6))),
           COUNT(*),true,true,true,true,true, p_build_run_key
    FROM training

    -- ════════════════ NetFees (6 levels × 4 statuses) ════════
    UNION ALL
    SELECT agg.lvl,'NetFees',s.StatusKey,
           agg.slk,agg.ctk,agg.ink,agg.nvek,agg.lsk,
           agg.est,agg.obs,agg.c1,agg.c2,agg.c3,agg.c4,agg.c5, p_build_run_key
    FROM (
        SELECT 0 lvl,ServiceLineKey slk,ClientTypeKey ctk,IndustryKey ink,NewVsExistingKey nvek,LeadSourceKey lsk,
               AVG(NetFees) est,COUNT(*) obs,false c1,false c2,false c3,false c4,false c5
        FROM training WHERE NetFees IS NOT NULL
        GROUP BY ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey,LeadSourceKey
        UNION ALL
        SELECT 1,ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey,NULL,AVG(NetFees),COUNT(*),false,false,false,false,true
        FROM training WHERE NetFees IS NOT NULL GROUP BY ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey
        UNION ALL
        SELECT 2,ServiceLineKey,ClientTypeKey,IndustryKey,NULL,NULL,AVG(NetFees),COUNT(*),false,false,false,true,true
        FROM training WHERE NetFees IS NOT NULL GROUP BY ServiceLineKey,ClientTypeKey,IndustryKey
        UNION ALL
        SELECT 3,ServiceLineKey,ClientTypeKey,NULL,NULL,NULL,AVG(NetFees),COUNT(*),false,false,true,true,true
        FROM training WHERE NetFees IS NOT NULL GROUP BY ServiceLineKey,ClientTypeKey
        UNION ALL
        SELECT 4,ServiceLineKey,NULL,NULL,NULL,NULL,AVG(NetFees),COUNT(*),false,true,true,true,true
        FROM training WHERE NetFees IS NOT NULL GROUP BY ServiceLineKey
        UNION ALL
        SELECT 5,NULL,NULL,NULL,NULL,NULL,AVG(NetFees),COUNT(*),true,true,true,true,true
        FROM training WHERE NetFees IS NOT NULL
    ) agg CROSS JOIN pipeline_analytics.dim_status s

    -- ════════════════ MarginPct (6 levels × 4 statuses) ══════
    UNION ALL
    SELECT agg.lvl,'MarginPct',s.StatusKey,
           agg.slk,agg.ctk,agg.ink,agg.nvek,agg.lsk,
           agg.est,agg.obs,agg.c1,agg.c2,agg.c3,agg.c4,agg.c5, p_build_run_key
    FROM (
        SELECT 0 lvl,ServiceLineKey slk,ClientTypeKey ctk,IndustryKey ink,NewVsExistingKey nvek,LeadSourceKey lsk,
               AVG(MarginPct) est,COUNT(*) obs,false c1,false c2,false c3,false c4,false c5
        FROM training WHERE MarginPct IS NOT NULL
        GROUP BY ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey,LeadSourceKey
        UNION ALL
        SELECT 1,ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey,NULL,AVG(MarginPct),COUNT(*),false,false,false,false,true
        FROM training WHERE MarginPct IS NOT NULL GROUP BY ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey
        UNION ALL
        SELECT 2,ServiceLineKey,ClientTypeKey,IndustryKey,NULL,NULL,AVG(MarginPct),COUNT(*),false,false,false,true,true
        FROM training WHERE MarginPct IS NOT NULL GROUP BY ServiceLineKey,ClientTypeKey,IndustryKey
        UNION ALL
        SELECT 3,ServiceLineKey,ClientTypeKey,NULL,NULL,NULL,AVG(MarginPct),COUNT(*),false,false,true,true,true
        FROM training WHERE MarginPct IS NOT NULL GROUP BY ServiceLineKey,ClientTypeKey
        UNION ALL
        SELECT 4,ServiceLineKey,NULL,NULL,NULL,NULL,AVG(MarginPct),COUNT(*),false,true,true,true,true
        FROM training WHERE MarginPct IS NOT NULL GROUP BY ServiceLineKey
        UNION ALL
        SELECT 5,NULL,NULL,NULL,NULL,NULL,AVG(MarginPct),COUNT(*),true,true,true,true,true
        FROM training WHERE MarginPct IS NOT NULL
    ) agg CROSS JOIN pipeline_analytics.dim_status s

    -- ════════════════ DaysSellToStart (6 levels) ═════════════
    UNION ALL
    SELECT 0,'DaysSellToStart',v_sk_sns, ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey,LeadSourceKey,
           AVG(CAST(DaysSellToStart AS DECIMAL(18,6))),COUNT(*),false,false,false,false,false, p_build_run_key
    FROM training WHERE DaysSellToStart IS NOT NULL
    GROUP BY ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey,LeadSourceKey
    UNION ALL
    SELECT 1,'DaysSellToStart',v_sk_sns, ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey,NULL,
           AVG(CAST(DaysSellToStart AS DECIMAL(18,6))),COUNT(*),false,false,false,false,true, p_build_run_key
    FROM training WHERE DaysSellToStart IS NOT NULL GROUP BY ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey
    UNION ALL
    SELECT 2,'DaysSellToStart',v_sk_sns, ServiceLineKey,ClientTypeKey,IndustryKey,NULL,NULL,
           AVG(CAST(DaysSellToStart AS DECIMAL(18,6))),COUNT(*),false,false,false,true,true, p_build_run_key
    FROM training WHERE DaysSellToStart IS NOT NULL GROUP BY ServiceLineKey,ClientTypeKey,IndustryKey
    UNION ALL
    SELECT 3,'DaysSellToStart',v_sk_sns, ServiceLineKey,ClientTypeKey,NULL,NULL,NULL,
           AVG(CAST(DaysSellToStart AS DECIMAL(18,6))),COUNT(*),false,false,true,true,true, p_build_run_key
    FROM training WHERE DaysSellToStart IS NOT NULL GROUP BY ServiceLineKey,ClientTypeKey
    UNION ALL
    SELECT 4,'DaysSellToStart',v_sk_sns, ServiceLineKey,NULL,NULL,NULL,NULL,
           AVG(CAST(DaysSellToStart AS DECIMAL(18,6))),COUNT(*),false,true,true,true,true, p_build_run_key
    FROM training WHERE DaysSellToStart IS NOT NULL GROUP BY ServiceLineKey
    UNION ALL
    SELECT 5,'DaysSellToStart',v_sk_sns, NULL,NULL,NULL,NULL,NULL,
           AVG(CAST(DaysSellToStart AS DECIMAL(18,6))),COUNT(*),true,true,true,true,true, p_build_run_key
    FROM training WHERE DaysSellToStart IS NOT NULL

    -- ════════════════ DaysStartTo50Pct (6 levels) ════════════
    UNION ALL
    SELECT 0,'DaysStartTo50Pct',v_sk_start, ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey,LeadSourceKey,
           AVG(CAST(DaysStartTo50Pct AS DECIMAL(18,6))),COUNT(*),false,false,false,false,false, p_build_run_key
    FROM training WHERE DaysStartTo50Pct IS NOT NULL
    GROUP BY ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey,LeadSourceKey
    UNION ALL
    SELECT 1,'DaysStartTo50Pct',v_sk_start, ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey,NULL,
           AVG(CAST(DaysStartTo50Pct AS DECIMAL(18,6))),COUNT(*),false,false,false,false,true, p_build_run_key
    FROM training WHERE DaysStartTo50Pct IS NOT NULL GROUP BY ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey
    UNION ALL
    SELECT 2,'DaysStartTo50Pct',v_sk_start, ServiceLineKey,ClientTypeKey,IndustryKey,NULL,NULL,
           AVG(CAST(DaysStartTo50Pct AS DECIMAL(18,6))),COUNT(*),false,false,false,true,true, p_build_run_key
    FROM training WHERE DaysStartTo50Pct IS NOT NULL GROUP BY ServiceLineKey,ClientTypeKey,IndustryKey
    UNION ALL
    SELECT 3,'DaysStartTo50Pct',v_sk_start, ServiceLineKey,ClientTypeKey,NULL,NULL,NULL,
           AVG(CAST(DaysStartTo50Pct AS DECIMAL(18,6))),COUNT(*),false,false,true,true,true, p_build_run_key
    FROM training WHERE DaysStartTo50Pct IS NOT NULL GROUP BY ServiceLineKey,ClientTypeKey
    UNION ALL
    SELECT 4,'DaysStartTo50Pct',v_sk_start, ServiceLineKey,NULL,NULL,NULL,NULL,
           AVG(CAST(DaysStartTo50Pct AS DECIMAL(18,6))),COUNT(*),false,true,true,true,true, p_build_run_key
    FROM training WHERE DaysStartTo50Pct IS NOT NULL GROUP BY ServiceLineKey
    UNION ALL
    SELECT 5,'DaysStartTo50Pct',v_sk_start, NULL,NULL,NULL,NULL,NULL,
           AVG(CAST(DaysStartTo50Pct AS DECIMAL(18,6))),COUNT(*),true,true,true,true,true, p_build_run_key
    FROM training WHERE DaysStartTo50Pct IS NOT NULL

    -- ════════════════ DaysStartTo100Pct (6 levels) ═══════════
    UNION ALL
    SELECT 0,'DaysStartTo100Pct',v_sk_start, ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey,LeadSourceKey,
           AVG(CAST(DaysStartTo100Pct AS DECIMAL(18,6))),COUNT(*),false,false,false,false,false, p_build_run_key
    FROM training WHERE DaysStartTo100Pct IS NOT NULL
    GROUP BY ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey,LeadSourceKey
    UNION ALL
    SELECT 1,'DaysStartTo100Pct',v_sk_start, ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey,NULL,
           AVG(CAST(DaysStartTo100Pct AS DECIMAL(18,6))),COUNT(*),false,false,false,false,true, p_build_run_key
    FROM training WHERE DaysStartTo100Pct IS NOT NULL GROUP BY ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey
    UNION ALL
    SELECT 2,'DaysStartTo100Pct',v_sk_start, ServiceLineKey,ClientTypeKey,IndustryKey,NULL,NULL,
           AVG(CAST(DaysStartTo100Pct AS DECIMAL(18,6))),COUNT(*),false,false,false,true,true, p_build_run_key
    FROM training WHERE DaysStartTo100Pct IS NOT NULL GROUP BY ServiceLineKey,ClientTypeKey,IndustryKey
    UNION ALL
    SELECT 3,'DaysStartTo100Pct',v_sk_start, ServiceLineKey,ClientTypeKey,NULL,NULL,NULL,
           AVG(CAST(DaysStartTo100Pct AS DECIMAL(18,6))),COUNT(*),false,false,true,true,true, p_build_run_key
    FROM training WHERE DaysStartTo100Pct IS NOT NULL GROUP BY ServiceLineKey,ClientTypeKey
    UNION ALL
    SELECT 4,'DaysStartTo100Pct',v_sk_start, ServiceLineKey,NULL,NULL,NULL,NULL,
           AVG(CAST(DaysStartTo100Pct AS DECIMAL(18,6))),COUNT(*),false,true,true,true,true, p_build_run_key
    FROM training WHERE DaysStartTo100Pct IS NOT NULL GROUP BY ServiceLineKey
    UNION ALL
    SELECT 5,'DaysStartTo100Pct',v_sk_start, NULL,NULL,NULL,NULL,NULL,
           AVG(CAST(DaysStartTo100Pct AS DECIMAL(18,6))),COUNT(*),true,true,true,true,true, p_build_run_key
    FROM training WHERE DaysStartTo100Pct IS NOT NULL;

    DROP VIEW IF EXISTS training;

END;


/* ────────────────────────────────────────────────────────────
   3c. usp_ApplyModel
   ────────────────────────────────────────────────────────────
   Applies segment estimates to the current pipeline and test
   dataset. Uses JOIN + ROW_NUMBER() to find the finest
   qualifying segment for each record and outcome — this is the
   Databricks equivalent of SQL Server's CROSS APPLY pattern.
   ──────────────────────────────────────────────────────────── */
CREATE OR REPLACE PROCEDURE pipeline_analytics.usp_ApplyModel(
    p_min_jobs_per_segment  INT,
    p_training_start        DATE,
    p_training_end          DATE,
    p_test_start            DATE,
    p_test_end              DATE,
    p_build_run_key         BIGINT
)
COMMENT 'Applies segment estimates to current pipeline and test records. Uses JOIN + ROW_NUMBER to find finest qualifying segment per record per outcome.'
BEGIN

    DECLARE v_sk_open  BIGINT DEFAULT (SELECT StatusKey FROM pipeline_analytics.dim_status WHERE StatusName = 'Open Opportunity');
    DECLARE v_sk_sns   BIGINT DEFAULT (SELECT StatusKey FROM pipeline_analytics.dim_status WHERE StatusName = 'Sold/Not Started');
    DECLARE v_sk_start BIGINT DEFAULT (SELECT StatusKey FROM pipeline_analytics.dim_status WHERE StatusName = 'Started');

    DELETE FROM pipeline_analytics.analytical_job_results WHERE BuildRunKey <> p_build_run_key;

    -- Step 1: build candidate records (current pipeline + test dataset)
    CREATE OR REPLACE TEMPORARY VIEW candidates AS
    SELECT
        fo.OpportunityID,
        fo.StatusKey,
        fo.ServiceLineKey,
        fo.ClientTypeKey,
        fo.IndustryKey,
        fo.NewVsExistingKey,
        fo.LeadSourceKey,
        fo.SoldDate,
        fo.StartDate,
        fo.ResolutionDate,
        fo.NetFees,
        fo.MarginPct,
        CASE
            WHEN fo.ResolutionDate BETWEEN p_test_start AND p_test_end THEN 'Test'
            ELSE 'Current'
        END AS DatasetType
    FROM pipeline_analytics.fact_opportunities fo
    WHERE fo.ResolutionDate NOT BETWEEN p_training_start AND p_training_end
       OR fo.ResolutionDate IS NULL;

    -- Step 2: join candidates to all matching segments, rank by granularity
    -- (replaces SQL Server CROSS APPLY — joins all matching rows, then picks finest)
    CREATE OR REPLACE TEMPORARY VIEW seg_matches AS
    SELECT
        c.OpportunityID,
        s.OutcomeName,
        s.OutcomeEstimate,
        s.SegmentKey,
        s.GranularityLevel,
        ROW_NUMBER() OVER (
            PARTITION BY c.OpportunityID, s.OutcomeName
            ORDER BY s.GranularityLevel ASC
        ) AS rn
    FROM candidates c
    JOIN pipeline_analytics.analytical_segments s
        ON  s.BuildRunKey        = p_build_run_key
        AND s.ObservationCount  >= p_min_jobs_per_segment
        AND s.StatusKey          = c.StatusKey
        AND (s.ServiceLineKey    = c.ServiceLineKey   OR s.ServiceLineKey   IS NULL)
        AND (s.ClientTypeKey     = c.ClientTypeKey    OR s.ClientTypeKey    IS NULL)
        AND (s.IndustryKey       = c.IndustryKey      OR s.IndustryKey      IS NULL)
        AND (s.NewVsExistingKey  = c.NewVsExistingKey OR s.NewVsExistingKey IS NULL)
        AND (s.LeadSourceKey     = c.LeadSourceKey    OR s.LeadSourceKey    IS NULL);

    -- Step 3: pivot finest segment estimate per outcome to one row per record
    CREATE OR REPLACE TEMPORARY VIEW best_estimates AS
    SELECT
        OpportunityID,
        MAX(CASE WHEN OutcomeName = 'WinPct'            THEN OutcomeEstimate END) AS EstimatedWinPct,
        MAX(CASE WHEN OutcomeName = 'NetFees'           THEN OutcomeEstimate END) AS EstimatedNetFees,
        MAX(CASE WHEN OutcomeName = 'MarginPct'         THEN OutcomeEstimate END) AS EstimatedMarginPct,
        MAX(CASE WHEN OutcomeName = 'DaysSellToStart'   THEN OutcomeEstimate END) AS EstDaysSellToStart,
        MAX(CASE WHEN OutcomeName = 'DaysStartTo50Pct'  THEN OutcomeEstimate END) AS EstDaysStartTo50,
        MAX(CASE WHEN OutcomeName = 'DaysStartTo100Pct' THEN OutcomeEstimate END) AS EstDaysStartTo100,
        MAX(CASE WHEN OutcomeName = 'NetFees'           THEN SegmentKey      END) AS SegmentKey
    FROM seg_matches
    WHERE rn = 1
    GROUP BY OpportunityID;

    -- Step 4: merge final estimates into analytical_job_results
    -- DATE_ADD(date, n) adds n days in Databricks
    MERGE INTO pipeline_analytics.analytical_job_results AS tgt
    USING (
        SELECT
            c.OpportunityID,
            e.SegmentKey,
            CASE WHEN c.StatusKey = v_sk_open THEN e.EstimatedWinPct END AS EstimatedWinPct,
            COALESCE(c.NetFees,   e.EstimatedNetFees)   AS EstimatedNetFees,
            COALESCE(c.MarginPct, e.EstimatedMarginPct) AS EstimatedMarginPct,
            COALESCE(c.MarginPct, e.EstimatedMarginPct)
                * COALESCE(c.NetFees, e.EstimatedNetFees) AS EstimatedMarginDollars,
            NULL AS EstimatedSellDate,
            COALESCE(c.StartDate,
                CASE WHEN c.SoldDate IS NOT NULL AND e.EstDaysSellToStart IS NOT NULL
                     THEN DATE_ADD(c.SoldDate, CAST(e.EstDaysSellToStart AS INT))
                END
            ) AS EstimatedStartDate,
            CASE WHEN c.StartDate IS NOT NULL AND e.EstDaysStartTo50 IS NOT NULL
                 THEN DATE_ADD(c.StartDate, CAST(e.EstDaysStartTo50 AS INT))
            END AS EstimatedPct50Date,
            CASE WHEN c.StartDate IS NOT NULL AND e.EstDaysStartTo100 IS NOT NULL
                 THEN DATE_ADD(c.StartDate, CAST(e.EstDaysStartTo100 AS INT))
            END AS EstimatedPct100Date,
            c.DatasetType,
            p_build_run_key AS BuildRunKey
        FROM candidates c
        LEFT JOIN best_estimates e ON e.OpportunityID = c.OpportunityID
    ) AS src ON tgt.OpportunityID = src.OpportunityID

    WHEN MATCHED THEN UPDATE SET
        tgt.SegmentKey             = src.SegmentKey,
        tgt.EstimatedWinPct        = src.EstimatedWinPct,
        tgt.EstimatedNetFees       = src.EstimatedNetFees,
        tgt.EstimatedMarginPct     = src.EstimatedMarginPct,
        tgt.EstimatedMarginDollars = src.EstimatedMarginDollars,
        tgt.EstimatedSellDate      = src.EstimatedSellDate,
        tgt.EstimatedStartDate     = src.EstimatedStartDate,
        tgt.EstimatedPct50Date     = src.EstimatedPct50Date,
        tgt.EstimatedPct100Date    = src.EstimatedPct100Date,
        tgt.DatasetType            = src.DatasetType,
        tgt.BuildRunKey            = src.BuildRunKey

    WHEN NOT MATCHED THEN INSERT (
        OpportunityID, SegmentKey,
        EstimatedWinPct, EstimatedNetFees, EstimatedMarginPct, EstimatedMarginDollars,
        EstimatedSellDate, EstimatedStartDate, EstimatedPct50Date, EstimatedPct100Date,
        DatasetType, BuildRunKey
    ) VALUES (
        src.OpportunityID, src.SegmentKey,
        src.EstimatedWinPct, src.EstimatedNetFees, src.EstimatedMarginPct, src.EstimatedMarginDollars,
        src.EstimatedSellDate, src.EstimatedStartDate, src.EstimatedPct50Date, src.EstimatedPct100Date,
        src.DatasetType, src.BuildRunKey
    );

    DROP VIEW IF EXISTS candidates;
    DROP VIEW IF EXISTS seg_matches;
    DROP VIEW IF EXISTS best_estimates;

END;


/* ────────────────────────────────────────────────────────────
   3d. usp_BuildPipelineAggregations
   ────────────────────────────────────────────────────────────
   Monthly pipeline aggregations from job-level results.
   MAKE_DATE(y, m, 1) replaces SQL Server DATEFROMPARTS.
   PERCENTILE_CONT syntax is the same as SQL Server.
   ──────────────────────────────────────────────────────────── */
CREATE OR REPLACE PROCEDURE pipeline_analytics.usp_BuildPipelineAggregations(
    p_build_run_key BIGINT
)
COMMENT 'Aggregates job-level estimates into monthly pipeline summary with median milestone dates.'
BEGIN

    DELETE FROM pipeline_analytics.analytical_pipeline_results
    WHERE BuildRunKey <> p_build_run_key;

    -- MAKE_DATE(year, month, day) is the Databricks equivalent of DATEFROMPARTS
    WITH job_data AS (
        SELECT
            MAKE_DATE(YEAR(jr.EstimatedStartDate), MONTH(jr.EstimatedStartDate), 1) AS PeriodMonth,
            jr.EstimatedNetFees,
            jr.EstimatedMarginDollars,
            jr.EstimatedPct50Date,
            jr.EstimatedPct100Date
        FROM pipeline_analytics.analytical_job_results jr
        WHERE jr.BuildRunKey        = p_build_run_key
          AND jr.DatasetType        = 'Current'
          AND jr.EstimatedStartDate IS NOT NULL
    ),
    with_medians AS (
        SELECT
            PeriodMonth,
            EstimatedNetFees,
            EstimatedMarginDollars,
            CAST(
                PERCENTILE_CONT(0.5) WITHIN GROUP (
                    ORDER BY DATEDIFF(EstimatedPct50Date, PeriodMonth)
                ) OVER (PARTITION BY PeriodMonth)
            AS INT) AS Median50Offset,
            CAST(
                PERCENTILE_CONT(0.5) WITHIN GROUP (
                    ORDER BY DATEDIFF(EstimatedPct100Date, PeriodMonth)
                ) OVER (PARTITION BY PeriodMonth)
            AS INT) AS Median100Offset
        FROM job_data
    )
    INSERT INTO pipeline_analytics.analytical_pipeline_results (
        PeriodMonth, EstimatedJobCount,
        EstimatedNetFees, EstimatedMarginDollars,
        MedianPct50Date, MedianPct100Date,
        BuildRunKey
    )
    SELECT
        PeriodMonth,
        COUNT(*)                                               AS EstimatedJobCount,
        SUM(EstimatedNetFees)                                  AS EstimatedNetFees,
        SUM(EstimatedMarginDollars)                            AS EstimatedMarginDollars,
        DATE_ADD(MIN(PeriodMonth), MIN(Median50Offset))        AS MedianPct50Date,
        DATE_ADD(MIN(PeriodMonth), MIN(Median100Offset))       AS MedianPct100Date,
        p_build_run_key                                        AS BuildRunKey
    FROM with_medians
    GROUP BY PeriodMonth;

    -- Optimize for downstream query performance
    OPTIMIZE pipeline_analytics.analytical_pipeline_results
        ZORDER BY (PeriodMonth);

    OPTIMIZE pipeline_analytics.analytical_job_results
        ZORDER BY (DatasetType, EstimatedStartDate);

    OPTIMIZE pipeline_analytics.analytical_segments
        ZORDER BY (StatusKey, ServiceLineKey, ClientTypeKey,
                   IndustryKey, NewVsExistingKey, LeadSourceKey, OutcomeName);

END;


/* ────────────────────────────────────────────────────────────
   3e. usp_RunBuild
   ────────────────────────────────────────────────────────────
   Master orchestrator. Computes rolling default date windows,
   logs each run to log_build_runs, and calls all sub-procedures
   in sequence.

   Databricks notes:
   - DECLARE EXIT HANDLER replaces SQL Server TRY/CATCH
   - MAX(BuildRunKey) replaces SCOPE_IDENTITY()
   - ADD_MONTHS(date, n) / LAST_DAY(date) for date arithmetic
   - CALL instead of EXEC to invoke sub-procedures
   ──────────────────────────────────────────────────────────── */
CREATE OR REPLACE PROCEDURE pipeline_analytics.usp_RunBuild(
    p_min_jobs_per_segment  INT     DEFAULT 30,
    p_training_start        DATE    DEFAULT NULL,
    p_training_end          DATE    DEFAULT NULL,
    p_test_start            DATE    DEFAULT NULL,
    p_test_end              DATE    DEFAULT NULL
)
COMMENT 'Master orchestrator. Computes default date windows, logs run, and calls LoadRawData, BuildSegments, ApplyModel, BuildPipelineAggregations in sequence.'
BEGIN

    DECLARE v_build_run_key    BIGINT DEFAULT 0;
    DECLARE v_rows_processed   INT    DEFAULT 0;
    DECLARE v_segments_built   INT    DEFAULT 0;
    DECLARE v_job_results      INT    DEFAULT 0;
    DECLARE v_end_last_month   DATE;
    DECLARE v_err_msg          STRING DEFAULT '';

    -- Error handler: update log row and re-raise
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        UPDATE pipeline_analytics.log_build_runs
        SET    Status        = 'Error',
               StatusMessage = v_err_msg
        WHERE  BuildRunKey   = v_build_run_key;
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_err_msg;
    END;

    -- Compute end of last calendar month
    -- LAST_DAY(ADD_MONTHS(date, -1)) = last day of previous month
    SET v_end_last_month = LAST_DAY(ADD_MONTHS(CURRENT_DATE(), -1));

    -- Apply defaults if parameters are NULL
    IF p_training_start IS NULL THEN
        SET p_training_start = ADD_MONTHS(v_end_last_month, -24);
    END IF;
    IF p_training_end IS NULL THEN
        SET p_training_end = ADD_MONTHS(v_end_last_month, -7);
    END IF;
    IF p_test_start IS NULL THEN
        SET p_test_start = ADD_MONTHS(v_end_last_month, -6);
    END IF;
    IF p_test_end IS NULL THEN
        SET p_test_end = ADD_MONTHS(v_end_last_month, -1);
    END IF;

    -- Log run start
    INSERT INTO pipeline_analytics.log_build_runs (
        MinJobsPerSegment, TrainingStart, TrainingEnd,
        TestStart, TestEnd, Status
    ) VALUES (
        p_min_jobs_per_segment, p_training_start, p_training_end,
        p_test_start, p_test_end, 'Running'
    );

    -- Get the key of the row just inserted
    SET v_build_run_key = (
        SELECT MAX(BuildRunKey) FROM pipeline_analytics.log_build_runs
        WHERE  Status = 'Running'
          AND  MinJobsPerSegment = p_min_jobs_per_segment
          AND  TrainingStart     = p_training_start
    );

    -- Step 1: Load raw data
    CALL pipeline_analytics.usp_LoadRawData(v_build_run_key);
    SET v_rows_processed = (SELECT COUNT(*) FROM pipeline_analytics.fact_opportunities);

    -- Step 2: Build segments
    CALL pipeline_analytics.usp_BuildSegments(
        p_min_jobs_per_segment, p_training_start, p_training_end, v_build_run_key
    );
    SET v_segments_built = (
        SELECT COUNT(*) FROM pipeline_analytics.analytical_segments
        WHERE BuildRunKey = v_build_run_key
    );

    -- Step 3: Apply model
    CALL pipeline_analytics.usp_ApplyModel(
        p_min_jobs_per_segment,
        p_training_start, p_training_end,
        p_test_start, p_test_end,
        v_build_run_key
    );
    SET v_job_results = (
        SELECT COUNT(*) FROM pipeline_analytics.analytical_job_results
        WHERE BuildRunKey = v_build_run_key
    );

    -- Step 4: Pipeline aggregations
    CALL pipeline_analytics.usp_BuildPipelineAggregations(v_build_run_key);

    -- Mark success
    UPDATE pipeline_analytics.log_build_runs
    SET    Status            = 'Success',
           RowsProcessed     = v_rows_processed,
           SegmentsBuilt     = v_segments_built,
           JobResultsWritten = v_job_results,
           StatusMessage     = CONCAT(
               'Training: ', CAST(p_training_start AS STRING), ' to ', CAST(p_training_end AS STRING),
               ' | Test: ', CAST(p_test_start AS STRING), ' to ', CAST(p_test_end AS STRING),
               ' | Min segment size: ', CAST(p_min_jobs_per_segment AS STRING)
           )
    WHERE  BuildRunKey = v_build_run_key;

    -- Summary output
    SELECT
        v_build_run_key        AS BuildRunKey,
        'Success'              AS Status,
        p_training_start       AS TrainingStart,
        p_training_end         AS TrainingEnd,
        p_test_start           AS TestStart,
        p_test_end             AS TestEnd,
        p_min_jobs_per_segment AS MinJobsPerSegment,
        v_rows_processed       AS RowsProcessed,
        v_segments_built       AS SegmentsBuilt,
        v_job_results          AS JobResultsWritten;

END;


/* ============================================================
   SECTION 4 — EXECUTE BUILD
   ============================================================
   CALL usp_RunBuild with default rolling date windows.
   Pass explicit dates to override defaults.
   ============================================================ */

CALL pipeline_analytics.usp_RunBuild(
    30,     -- MinJobsPerSegment
    NULL,   -- TrainingStart: default = 24 months before end of last calendar month
    NULL,   -- TrainingEnd:   default =  7 months before end of last calendar month
    NULL,   -- TestStart:     default =  6 months before end of last calendar month
    NULL    -- TestEnd:       default =  1 month  before end of last calendar month
);
