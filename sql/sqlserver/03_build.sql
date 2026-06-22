/* ============================================================
   BUILD SCRIPT — PipelineAnalytics (SQL Server)
   Horizon Data Predictive Model
   ============================================================
   Purpose  : Implements and executes all stored procedures that
              transform raw data into analytical outputs:
              - usp_LoadRawData
              - usp_BuildSegments
              - usp_ApplyModel
              - usp_BuildPipelineAggregations
              - usp_RunBuild (master orchestrator)

   Usage    : 1. Ensure 01_setup.sql has been run.
              2. Load raw data into dbo.stg_raw_data.
              3. Set configurable parameters in Section 1.
              4. Execute this script. Section 3 calls usp_RunBuild
                 automatically using the parameters defined above.

   Plug-and-play: To refresh the model with new data, reload
              stg_raw_data and re-run this script. Parameters
              at the top are the only values you need to change.

   Sections :
     1. Configurable parameters
     2. Schema additions  (new columns on analytical tables)
     3. Procedure implementations
        2a. usp_LoadRawData
        2b. usp_BuildSegments
        2c. usp_ApplyModel
        2d. usp_BuildPipelineAggregations
        2e. usp_RunBuild
     4. Execute build
   ============================================================ */


/* ============================================================
   SECTION 1 — CONFIGURABLE PARAMETERS
   ============================================================
   These are the only values you need to adjust between runs.
   All procedures read these via usp_RunBuild parameters.
   ============================================================ */

USE PipelineAnalytics;
GO

/*
   -- Minimum number of jobs required in a segment before
   -- categories are dropped. Default: 30.
   DECLARE @MinJobsPerSegment INT = 30;

   -- Training window: jobs resolved (sold or lost) between
   -- 24 and 7 months before the end of the last calendar month.
   -- Defaults are computed automatically from GETDATE() if
   -- left as NULL — override by providing explicit dates.
   DECLARE @TrainingStart DATE = NULL;   -- e.g. '2024-06-01'
   DECLARE @TrainingEnd   DATE = NULL;   -- e.g. '2025-10-31'

   -- Test window: jobs resolved between 6 and 1 months before
   -- end of last calendar month.
   DECLARE @TestStart DATE = NULL;       -- e.g. '2025-11-01'
   DECLARE @TestEnd   DATE = NULL;       -- e.g. '2026-04-30'
*/


/* ============================================================
   SECTION 2 — SCHEMA ADDITIONS
   ============================================================
   Extends analytical_segments with GranularityLevel and full
   set of category-drop flags (Cat1–Cat5). Extends
   analytical_job_results with DatasetType to distinguish
   current pipeline from test-set records.
   ============================================================ */

-- analytical_segments: add GranularityLevel (0=finest, 5=status only)
IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.analytical_segments')
      AND name = 'GranularityLevel'
)
    ALTER TABLE dbo.analytical_segments
        ADD GranularityLevel INT NOT NULL DEFAULT 0;
GO

-- analytical_segments: add Cat1Dropped and Cat2Dropped flags
IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.analytical_segments')
      AND name = 'Cat1Dropped'
)
    ALTER TABLE dbo.analytical_segments
        ADD Cat1Dropped BIT NOT NULL DEFAULT 0;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.analytical_segments')
      AND name = 'Cat2Dropped'
)
    ALTER TABLE dbo.analytical_segments
        ADD Cat2Dropped BIT NOT NULL DEFAULT 0;
GO

-- analytical_job_results: tag records as Current pipeline or Test dataset
IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.analytical_job_results')
      AND name = 'DatasetType'
)
    ALTER TABLE dbo.analytical_job_results
        ADD DatasetType VARCHAR(10) NOT NULL DEFAULT 'Current';
        -- Values: 'Current' (live pipeline) | 'Test' (test window, actuals available)
GO


/* ============================================================
   SECTION 3 — PROCEDURE IMPLEMENTATIONS
   ============================================================ */


/* ────────────────────────────────────────────────────────────
   3a. usp_LoadRawData
   ────────────────────────────────────────────────────────────
   Transforms dbo.stg_raw_data into dbo.fact_opportunities.

   For each staging row:
   - Maps raw text category values to dimension surrogate keys.
     Unknown/NULL values map to the 'Unknown' dimension member.
   - Derives StatusKey from the combination of populated dates.
   - Derives ResolutionDate = COALESCE(SoldDate, ClosedLostDate),
     used as the single anchor date for training/test bucketing.
   - Derives MarginDollars = MarginPct * NetFees.
   - Derives timing metrics: DaysSellToStart, DaysStartTo50Pct,
     DaysStartTo100Pct.
   - MERGEs results into fact_opportunities (upsert: update
     existing rows, insert new ones).
   ──────────────────────────────────────────────────────────── */
ALTER PROCEDURE dbo.usp_LoadRawData
    @BuildRunKey INT
AS
BEGIN
    SET NOCOUNT ON;

    MERGE dbo.fact_opportunities AS tgt
    USING (
        SELECT
            s.OpportunityID,

            -- Category 1: ServiceLine → dim_service_line
            COALESCE(sl.ServiceLineKey, sl_unk.ServiceLineKey) AS ServiceLineKey,
            -- Category 2: ClientType → dim_client_type
            COALESCE(ct.ClientTypeKey,  ct_unk.ClientTypeKey)  AS ClientTypeKey,
            -- Category 3: Industry → dim_industry
            COALESCE(ind.IndustryKey,   ind_unk.IndustryKey)   AS IndustryKey,
            -- Category 4: NewVsExisting → dim_new_vs_existing
            COALESCE(nve.NewVsExistingKey, nve_unk.NewVsExistingKey) AS NewVsExistingKey,
            -- Category 5: LeadSource → dim_lead_source
            COALESCE(ls.LeadSourceKey,  ls_unk.LeadSourceKey)  AS LeadSourceKey,

            -- Status (derived from date fields — order matters):
            --   StartDate populated                          → Started
            --   SoldDate populated, StartDate NULL           → Sold/Not Started
            --   ClosedLostDate populated                     → Lost
            --   Both null                                    → Open Opportunity
            CASE
                WHEN s.StartDate        IS NOT NULL THEN st_started.StatusKey
                WHEN s.SoldDate         IS NOT NULL THEN st_sns.StatusKey
                WHEN s.ClosedLostDate   IS NOT NULL THEN st_lost.StatusKey
                ELSE                                     st_open.StatusKey
            END AS StatusKey,

            s.CreatedDate,
            s.SoldDate,
            s.ClosedLostDate,
            s.StartDate,
            s.Pct50CompleteDate,
            s.Pct100CompleteDate,

            -- ResolutionDate: single anchor for training/test window filters.
            -- SoldDate for won jobs, ClosedLostDate for lost, NULL for open.
            COALESCE(s.SoldDate, s.ClosedLostDate) AS ResolutionDate,

            s.NetFees,
            s.MarginPct,
            -- MarginDollars stored at load time for aggregation performance
            CASE WHEN s.MarginPct IS NOT NULL AND s.NetFees IS NOT NULL
                 THEN s.MarginPct * s.NetFees ELSE NULL END AS MarginDollars,

            -- Timing metrics (days between milestones)
            CASE WHEN s.SoldDate IS NOT NULL AND s.StartDate IS NOT NULL
                 THEN DATEDIFF(day, s.SoldDate, s.StartDate) ELSE NULL END
                 AS DaysSellToStart,
            CASE WHEN s.StartDate IS NOT NULL AND s.Pct50CompleteDate IS NOT NULL
                 THEN DATEDIFF(day, s.StartDate, s.Pct50CompleteDate) ELSE NULL END
                 AS DaysStartTo50Pct,
            CASE WHEN s.StartDate IS NOT NULL AND s.Pct100CompleteDate IS NOT NULL
                 THEN DATEDIFF(day, s.StartDate, s.Pct100CompleteDate) ELSE NULL END
                 AS DaysStartTo100Pct,

            GETDATE() AS LoadTimestamp

        FROM dbo.stg_raw_data s

        -- Dimension lookups (LEFT JOIN so missing values fall through to Unknown)
        LEFT JOIN dbo.dim_service_line    sl      ON sl.ServiceLineName    = s.ServiceLine
        LEFT JOIN dbo.dim_client_type     ct      ON ct.ClientTypeName     = s.ClientType
        LEFT JOIN dbo.dim_industry        ind     ON ind.IndustryName      = s.Industry
        LEFT JOIN dbo.dim_new_vs_existing nve     ON nve.NewVsExistingName = s.NewVsExisting
        LEFT JOIN dbo.dim_lead_source     ls      ON ls.LeadSourceName     = s.LeadSource

        -- Unknown fallback keys (used when raw value is NULL or unrecognised)
        CROSS JOIN (SELECT ServiceLineKey   FROM dbo.dim_service_line    WHERE ServiceLineName   = 'Unknown') sl_unk
        CROSS JOIN (SELECT ClientTypeKey    FROM dbo.dim_client_type     WHERE ClientTypeName    = 'Unknown') ct_unk
        CROSS JOIN (SELECT IndustryKey      FROM dbo.dim_industry        WHERE IndustryName      = 'Unknown') ind_unk
        CROSS JOIN (SELECT NewVsExistingKey FROM dbo.dim_new_vs_existing WHERE NewVsExistingName = 'Unknown') nve_unk
        CROSS JOIN (SELECT LeadSourceKey    FROM dbo.dim_lead_source     WHERE LeadSourceName    = 'Unknown') ls_unk

        -- Status keys (resolved once via CROSS JOIN for efficiency)
        CROSS JOIN (SELECT StatusKey FROM dbo.dim_status WHERE StatusName = 'Open Opportunity') st_open
        CROSS JOIN (SELECT StatusKey FROM dbo.dim_status WHERE StatusName = 'Lost')             st_lost
        CROSS JOIN (SELECT StatusKey FROM dbo.dim_status WHERE StatusName = 'Sold/Not Started') st_sns
        CROSS JOIN (SELECT StatusKey FROM dbo.dim_status WHERE StatusName = 'Started')          st_started

    ) AS src ON tgt.OpportunityID = src.OpportunityID

    WHEN MATCHED THEN UPDATE SET
        tgt.ServiceLineKey      = src.ServiceLineKey,
        tgt.ClientTypeKey       = src.ClientTypeKey,
        tgt.IndustryKey         = src.IndustryKey,
        tgt.NewVsExistingKey    = src.NewVsExistingKey,
        tgt.LeadSourceKey       = src.LeadSourceKey,
        tgt.StatusKey           = src.StatusKey,
        tgt.CreatedDate         = src.CreatedDate,
        tgt.SoldDate            = src.SoldDate,
        tgt.ClosedLostDate      = src.ClosedLostDate,
        tgt.StartDate           = src.StartDate,
        tgt.Pct50CompleteDate   = src.Pct50CompleteDate,
        tgt.Pct100CompleteDate  = src.Pct100CompleteDate,
        tgt.ResolutionDate      = src.ResolutionDate,
        tgt.NetFees             = src.NetFees,
        tgt.MarginPct           = src.MarginPct,
        tgt.MarginDollars       = src.MarginDollars,
        tgt.DaysSellToStart     = src.DaysSellToStart,
        tgt.DaysStartTo50Pct    = src.DaysStartTo50Pct,
        tgt.DaysStartTo100Pct   = src.DaysStartTo100Pct,
        tgt.LoadTimestamp       = src.LoadTimestamp

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
GO


/* ────────────────────────────────────────────────────────────
   3b. usp_BuildSegments
   ────────────────────────────────────────────────────────────
   Core estimation engine. Builds the analytical_segments table
   from the training dataset.

   Algorithm:
   For each of 6 outcomes × 6 granularity levels:
     1. Filter training data to records with the outcome
        populated (missing outcomes excluded per spec).
     2. Group by Status + whichever categories remain at
        that granularity level (NULL = category dropped).
     3. Compute: AVG(outcome), COUNT(*).
     4. Store all levels in analytical_segments.

   Granularity levels (finest → coarsest):
     0 — Status + Cat1 + Cat2 + Cat3 + Cat4 + Cat5
     1 — Status + Cat1 + Cat2 + Cat3 + Cat4        (Cat5 dropped)
     2 — Status + Cat1 + Cat2 + Cat3               (Cat4+5 dropped)
     3 — Status + Cat1 + Cat2                      (Cat3+4+5 dropped)
     4 — Status + Cat1                             (Cat2+3+4+5 dropped)
     5 — Status only                               (all cats dropped)

   usp_ApplyModel picks the finest level (lowest number) that
   meets @MinJobsPerSegment for each current record. Storing
   all levels here makes that matching a simple index seek.

   Outcome-to-status mapping:
     WinPct           → segments tagged 'Open Opportunity'
                        (computed across all resolved training records)
     NetFees          → segments tagged for all 4 statuses
                        (computed from records where NetFees IS NOT NULL)
     MarginPct        → segments tagged for all 4 statuses
                        (computed from records where MarginPct IS NOT NULL)
     DaysSellToStart  → segments tagged 'Sold/Not Started'
     DaysStartTo50Pct → segments tagged 'Started'
     DaysStartTo100Pct→ segments tagged 'Started'
   ──────────────────────────────────────────────────────────── */
ALTER PROCEDURE dbo.usp_BuildSegments
    @MinJobsPerSegment  INT,
    @TrainingStart      DATE,
    @TrainingEnd        DATE,
    @BuildRunKey        INT
AS
BEGIN
    SET NOCOUNT ON;

    -- ── Status key lookups ───────────────────────────────────
    DECLARE @SK_Open  INT = (SELECT StatusKey FROM dbo.dim_status WHERE StatusName = 'Open Opportunity');
    DECLARE @SK_Lost  INT = (SELECT StatusKey FROM dbo.dim_status WHERE StatusName = 'Lost');
    DECLARE @SK_SNS   INT = (SELECT StatusKey FROM dbo.dim_status WHERE StatusName = 'Sold/Not Started');
    DECLARE @SK_Start INT = (SELECT StatusKey FROM dbo.dim_status WHERE StatusName = 'Started');

    -- ── Working table: all-level aggregates for all outcomes ─
    -- Populated via INSERT...SELECT for each outcome below,
    -- then used to populate analytical_segments.
    CREATE TABLE #seg_work (
        GranularityLevel    INT          NOT NULL,   -- 0 = finest, 5 = status only
        OutcomeName         VARCHAR(50)  NOT NULL,
        StatusKey           INT          NOT NULL,
        ServiceLineKey      INT          NULL,        -- NULL = category dropped at this level
        ClientTypeKey       INT          NULL,
        IndustryKey         INT          NULL,
        NewVsExistingKey    INT          NULL,
        LeadSourceKey       INT          NULL,
        OutcomeEstimate     DECIMAL(18,6) NULL,
        ObservationCount    INT          NOT NULL,
        -- Drop flags (derived from level)
        Cat1Dropped         BIT          NOT NULL DEFAULT 0,
        Cat2Dropped         BIT          NOT NULL DEFAULT 0,
        Cat3Dropped         BIT          NOT NULL DEFAULT 0,
        Cat4Dropped         BIT          NOT NULL DEFAULT 0,
        Cat5Dropped         BIT          NOT NULL DEFAULT 0
    );

    -- ── Training dataset (filtered to window) ────────────────
    -- Stored in a temp table to avoid repeated scans.
    -- ResolutionDate IS NOT NULL filters open opportunities
    -- (they have no resolution date yet).
    SELECT
        OpportunityID,
        ServiceLineKey, ClientTypeKey, IndustryKey,
        NewVsExistingKey, LeadSourceKey, StatusKey,
        SoldDate, ClosedLostDate, StartDate,
        Pct50CompleteDate, Pct100CompleteDate,
        ResolutionDate,
        NetFees, MarginPct, MarginDollars,
        DaysSellToStart, DaysStartTo50Pct, DaysStartTo100Pct
    INTO #training
    FROM dbo.fact_opportunities
    WHERE ResolutionDate BETWEEN @TrainingStart AND @TrainingEnd;

    -- ── Helper macro: insert aggregates at all 6 levels ──────
    -- Used once per outcome. Parameters supplied by the caller
    -- via the variables set before each INSERT block below.
    --
    -- For each level, we GROUP BY the categories that remain
    -- at that level and set the dropped ones to NULL.
    -- The HAVING clause enforces the minimum segment size.
    -- We do NOT filter by MinJobsPerSegment here — all levels
    -- are stored so usp_ApplyModel can choose the finest that
    -- meets the threshold at query time.


    -- ════════════════════════════════════════════════════════
    -- OUTCOME 1: WinPct
    -- Training source: all resolved training records
    -- Metric: proportion with SoldDate IS NOT NULL (= won)
    -- Applied to: Open Opportunity status
    -- ════════════════════════════════════════════════════════

    INSERT INTO #seg_work
        (GranularityLevel, OutcomeName, StatusKey,
         ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey, LeadSourceKey,
         OutcomeEstimate, ObservationCount,
         Cat1Dropped, Cat2Dropped, Cat3Dropped, Cat4Dropped, Cat5Dropped)

    -- Level 0: all categories
    SELECT 0, 'WinPct', @SK_Open,
           ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey, LeadSourceKey,
           AVG(CAST(CASE WHEN SoldDate IS NOT NULL THEN 1.0 ELSE 0.0 END AS DECIMAL(18,6))),
           COUNT(*), 0,0,0,0,0
    FROM #training
    GROUP BY ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey, LeadSourceKey

    UNION ALL
    -- Level 1: Cat5 dropped
    SELECT 1, 'WinPct', @SK_Open,
           ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey, NULL,
           AVG(CAST(CASE WHEN SoldDate IS NOT NULL THEN 1.0 ELSE 0.0 END AS DECIMAL(18,6))),
           COUNT(*), 0,0,0,0,1
    FROM #training
    GROUP BY ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey

    UNION ALL
    -- Level 2: Cat4+5 dropped
    SELECT 2, 'WinPct', @SK_Open,
           ServiceLineKey, ClientTypeKey, IndustryKey, NULL, NULL,
           AVG(CAST(CASE WHEN SoldDate IS NOT NULL THEN 1.0 ELSE 0.0 END AS DECIMAL(18,6))),
           COUNT(*), 0,0,0,1,1
    FROM #training
    GROUP BY ServiceLineKey, ClientTypeKey, IndustryKey

    UNION ALL
    -- Level 3: Cat3+4+5 dropped
    SELECT 3, 'WinPct', @SK_Open,
           ServiceLineKey, ClientTypeKey, NULL, NULL, NULL,
           AVG(CAST(CASE WHEN SoldDate IS NOT NULL THEN 1.0 ELSE 0.0 END AS DECIMAL(18,6))),
           COUNT(*), 0,0,1,1,1
    FROM #training
    GROUP BY ServiceLineKey, ClientTypeKey

    UNION ALL
    -- Level 4: Cat2+3+4+5 dropped
    SELECT 4, 'WinPct', @SK_Open,
           ServiceLineKey, NULL, NULL, NULL, NULL,
           AVG(CAST(CASE WHEN SoldDate IS NOT NULL THEN 1.0 ELSE 0.0 END AS DECIMAL(18,6))),
           COUNT(*), 0,1,1,1,1
    FROM #training
    GROUP BY ServiceLineKey

    UNION ALL
    -- Level 5: status only
    SELECT 5, 'WinPct', @SK_Open,
           NULL, NULL, NULL, NULL, NULL,
           AVG(CAST(CASE WHEN SoldDate IS NOT NULL THEN 1.0 ELSE 0.0 END AS DECIMAL(18,6))),
           COUNT(*), 1,1,1,1,1
    FROM #training;


    -- ════════════════════════════════════════════════════════
    -- OUTCOME 2: NetFees
    -- Training source: records where NetFees IS NOT NULL
    -- Applied to: all 4 statuses (4 rows per segment combo,
    --             same estimate across statuses)
    -- ════════════════════════════════════════════════════════

    INSERT INTO #seg_work
        (GranularityLevel, OutcomeName, StatusKey,
         ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey, LeadSourceKey,
         OutcomeEstimate, ObservationCount,
         Cat1Dropped, Cat2Dropped, Cat3Dropped, Cat4Dropped, Cat5Dropped)

    SELECT agg.GranularityLevel, 'NetFees', s.StatusKey,
           agg.ServiceLineKey, agg.ClientTypeKey, agg.IndustryKey,
           agg.NewVsExistingKey, agg.LeadSourceKey,
           agg.OutcomeEstimate, agg.ObservationCount,
           agg.Cat1Dropped, agg.Cat2Dropped, agg.Cat3Dropped,
           agg.Cat4Dropped, agg.Cat5Dropped
    FROM (
        SELECT 0 AS GranularityLevel,
               ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey, LeadSourceKey,
               AVG(NetFees) AS OutcomeEstimate, COUNT(*) AS ObservationCount,
               CAST(0 AS BIT) Cat1Dropped, CAST(0 AS BIT) Cat2Dropped,
               CAST(0 AS BIT) Cat3Dropped, CAST(0 AS BIT) Cat4Dropped, CAST(0 AS BIT) Cat5Dropped
        FROM #training WHERE NetFees IS NOT NULL
        GROUP BY ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey, LeadSourceKey
        UNION ALL
        SELECT 1, ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey, NULL,
               AVG(NetFees), COUNT(*), 0,0,0,0,1
        FROM #training WHERE NetFees IS NOT NULL
        GROUP BY ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey
        UNION ALL
        SELECT 2, ServiceLineKey, ClientTypeKey, IndustryKey, NULL, NULL,
               AVG(NetFees), COUNT(*), 0,0,0,1,1
        FROM #training WHERE NetFees IS NOT NULL
        GROUP BY ServiceLineKey, ClientTypeKey, IndustryKey
        UNION ALL
        SELECT 3, ServiceLineKey, ClientTypeKey, NULL, NULL, NULL,
               AVG(NetFees), COUNT(*), 0,0,1,1,1
        FROM #training WHERE NetFees IS NOT NULL
        GROUP BY ServiceLineKey, ClientTypeKey
        UNION ALL
        SELECT 4, ServiceLineKey, NULL, NULL, NULL, NULL,
               AVG(NetFees), COUNT(*), 0,1,1,1,1
        FROM #training WHERE NetFees IS NOT NULL
        GROUP BY ServiceLineKey
        UNION ALL
        SELECT 5, NULL, NULL, NULL, NULL, NULL,
               AVG(NetFees), COUNT(*), 1,1,1,1,1
        FROM #training WHERE NetFees IS NOT NULL
    ) agg
    CROSS JOIN dbo.dim_status s;   -- Replicate across all 4 statuses


    -- ════════════════════════════════════════════════════════
    -- OUTCOME 3: MarginPct
    -- Training source: records where MarginPct IS NOT NULL
    --                  (only 100%-complete jobs)
    -- Applied to: all 4 statuses
    -- ════════════════════════════════════════════════════════

    INSERT INTO #seg_work
        (GranularityLevel, OutcomeName, StatusKey,
         ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey, LeadSourceKey,
         OutcomeEstimate, ObservationCount,
         Cat1Dropped, Cat2Dropped, Cat3Dropped, Cat4Dropped, Cat5Dropped)

    SELECT agg.GranularityLevel, 'MarginPct', s.StatusKey,
           agg.ServiceLineKey, agg.ClientTypeKey, agg.IndustryKey,
           agg.NewVsExistingKey, agg.LeadSourceKey,
           agg.OutcomeEstimate, agg.ObservationCount,
           agg.Cat1Dropped, agg.Cat2Dropped, agg.Cat3Dropped,
           agg.Cat4Dropped, agg.Cat5Dropped
    FROM (
        SELECT 0 AS GranularityLevel,
               ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey, LeadSourceKey,
               AVG(MarginPct) AS OutcomeEstimate, COUNT(*) AS ObservationCount,
               CAST(0 AS BIT) Cat1Dropped, CAST(0 AS BIT) Cat2Dropped,
               CAST(0 AS BIT) Cat3Dropped, CAST(0 AS BIT) Cat4Dropped, CAST(0 AS BIT) Cat5Dropped
        FROM #training WHERE MarginPct IS NOT NULL
        GROUP BY ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey, LeadSourceKey
        UNION ALL
        SELECT 1, ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey, NULL,
               AVG(MarginPct), COUNT(*), 0,0,0,0,1
        FROM #training WHERE MarginPct IS NOT NULL
        GROUP BY ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey
        UNION ALL
        SELECT 2, ServiceLineKey, ClientTypeKey, IndustryKey, NULL, NULL,
               AVG(MarginPct), COUNT(*), 0,0,0,1,1
        FROM #training WHERE MarginPct IS NOT NULL
        GROUP BY ServiceLineKey, ClientTypeKey, IndustryKey
        UNION ALL
        SELECT 3, ServiceLineKey, ClientTypeKey, NULL, NULL, NULL,
               AVG(MarginPct), COUNT(*), 0,0,1,1,1
        FROM #training WHERE MarginPct IS NOT NULL
        GROUP BY ServiceLineKey, ClientTypeKey
        UNION ALL
        SELECT 4, ServiceLineKey, NULL, NULL, NULL, NULL,
               AVG(MarginPct), COUNT(*), 0,1,1,1,1
        FROM #training WHERE MarginPct IS NOT NULL
        GROUP BY ServiceLineKey
        UNION ALL
        SELECT 5, NULL, NULL, NULL, NULL, NULL,
               AVG(MarginPct), COUNT(*), 1,1,1,1,1
        FROM #training WHERE MarginPct IS NOT NULL
    ) agg
    CROSS JOIN dbo.dim_status s;


    -- ════════════════════════════════════════════════════════
    -- OUTCOME 4: DaysSellToStart
    -- Training source: records where DaysSellToStart IS NOT NULL
    -- Applied to: Sold/Not Started status
    -- ════════════════════════════════════════════════════════

    INSERT INTO #seg_work
        (GranularityLevel, OutcomeName, StatusKey,
         ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey, LeadSourceKey,
         OutcomeEstimate, ObservationCount,
         Cat1Dropped, Cat2Dropped, Cat3Dropped, Cat4Dropped, Cat5Dropped)

    SELECT 0, 'DaysSellToStart', @SK_SNS,
           ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey, LeadSourceKey,
           AVG(CAST(DaysSellToStart AS DECIMAL(18,6))), COUNT(*), 0,0,0,0,0
    FROM #training WHERE DaysSellToStart IS NOT NULL
    GROUP BY ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey, LeadSourceKey
    UNION ALL
    SELECT 1, 'DaysSellToStart', @SK_SNS,
           ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey, NULL,
           AVG(CAST(DaysSellToStart AS DECIMAL(18,6))), COUNT(*), 0,0,0,0,1
    FROM #training WHERE DaysSellToStart IS NOT NULL
    GROUP BY ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey
    UNION ALL
    SELECT 2, 'DaysSellToStart', @SK_SNS,
           ServiceLineKey, ClientTypeKey, IndustryKey, NULL, NULL,
           AVG(CAST(DaysSellToStart AS DECIMAL(18,6))), COUNT(*), 0,0,0,1,1
    FROM #training WHERE DaysSellToStart IS NOT NULL
    GROUP BY ServiceLineKey, ClientTypeKey, IndustryKey
    UNION ALL
    SELECT 3, 'DaysSellToStart', @SK_SNS,
           ServiceLineKey, ClientTypeKey, NULL, NULL, NULL,
           AVG(CAST(DaysSellToStart AS DECIMAL(18,6))), COUNT(*), 0,0,1,1,1
    FROM #training WHERE DaysSellToStart IS NOT NULL
    GROUP BY ServiceLineKey, ClientTypeKey
    UNION ALL
    SELECT 4, 'DaysSellToStart', @SK_SNS,
           ServiceLineKey, NULL, NULL, NULL, NULL,
           AVG(CAST(DaysSellToStart AS DECIMAL(18,6))), COUNT(*), 0,1,1,1,1
    FROM #training WHERE DaysSellToStart IS NOT NULL
    GROUP BY ServiceLineKey
    UNION ALL
    SELECT 5, 'DaysSellToStart', @SK_SNS,
           NULL, NULL, NULL, NULL, NULL,
           AVG(CAST(DaysSellToStart AS DECIMAL(18,6))), COUNT(*), 1,1,1,1,1
    FROM #training WHERE DaysSellToStart IS NOT NULL;


    -- ════════════════════════════════════════════════════════
    -- OUTCOME 5: DaysStartTo50Pct
    -- Training source: records where DaysStartTo50Pct IS NOT NULL
    -- Applied to: Started status
    -- ════════════════════════════════════════════════════════

    INSERT INTO #seg_work
        (GranularityLevel, OutcomeName, StatusKey,
         ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey, LeadSourceKey,
         OutcomeEstimate, ObservationCount,
         Cat1Dropped, Cat2Dropped, Cat3Dropped, Cat4Dropped, Cat5Dropped)

    SELECT 0, 'DaysStartTo50Pct', @SK_Start,
           ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey, LeadSourceKey,
           AVG(CAST(DaysStartTo50Pct AS DECIMAL(18,6))), COUNT(*), 0,0,0,0,0
    FROM #training WHERE DaysStartTo50Pct IS NOT NULL
    GROUP BY ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey, LeadSourceKey
    UNION ALL
    SELECT 1, 'DaysStartTo50Pct', @SK_Start,
           ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey, NULL,
           AVG(CAST(DaysStartTo50Pct AS DECIMAL(18,6))), COUNT(*), 0,0,0,0,1
    FROM #training WHERE DaysStartTo50Pct IS NOT NULL
    GROUP BY ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey
    UNION ALL
    SELECT 2, 'DaysStartTo50Pct', @SK_Start,
           ServiceLineKey, ClientTypeKey, IndustryKey, NULL, NULL,
           AVG(CAST(DaysStartTo50Pct AS DECIMAL(18,6))), COUNT(*), 0,0,0,1,1
    FROM #training WHERE DaysStartTo50Pct IS NOT NULL
    GROUP BY ServiceLineKey, ClientTypeKey, IndustryKey
    UNION ALL
    SELECT 3, 'DaysStartTo50Pct', @SK_Start,
           ServiceLineKey, ClientTypeKey, NULL, NULL, NULL,
           AVG(CAST(DaysStartTo50Pct AS DECIMAL(18,6))), COUNT(*), 0,0,1,1,1
    FROM #training WHERE DaysStartTo50Pct IS NOT NULL
    GROUP BY ServiceLineKey, ClientTypeKey
    UNION ALL
    SELECT 4, 'DaysStartTo50Pct', @SK_Start,
           ServiceLineKey, NULL, NULL, NULL, NULL,
           AVG(CAST(DaysStartTo50Pct AS DECIMAL(18,6))), COUNT(*), 0,1,1,1,1
    FROM #training WHERE DaysStartTo50Pct IS NOT NULL
    GROUP BY ServiceLineKey
    UNION ALL
    SELECT 5, 'DaysStartTo50Pct', @SK_Start,
           NULL, NULL, NULL, NULL, NULL,
           AVG(CAST(DaysStartTo50Pct AS DECIMAL(18,6))), COUNT(*), 1,1,1,1,1
    FROM #training WHERE DaysStartTo50Pct IS NOT NULL;


    -- ════════════════════════════════════════════════════════
    -- OUTCOME 6: DaysStartTo100Pct
    -- Training source: records where DaysStartTo100Pct IS NOT NULL
    -- Applied to: Started status
    -- ════════════════════════════════════════════════════════

    INSERT INTO #seg_work
        (GranularityLevel, OutcomeName, StatusKey,
         ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey, LeadSourceKey,
         OutcomeEstimate, ObservationCount,
         Cat1Dropped, Cat2Dropped, Cat3Dropped, Cat4Dropped, Cat5Dropped)

    SELECT 0, 'DaysStartTo100Pct', @SK_Start,
           ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey, LeadSourceKey,
           AVG(CAST(DaysStartTo100Pct AS DECIMAL(18,6))), COUNT(*), 0,0,0,0,0
    FROM #training WHERE DaysStartTo100Pct IS NOT NULL
    GROUP BY ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey, LeadSourceKey
    UNION ALL
    SELECT 1, 'DaysStartTo100Pct', @SK_Start,
           ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey, NULL,
           AVG(CAST(DaysStartTo100Pct AS DECIMAL(18,6))), COUNT(*), 0,0,0,0,1
    FROM #training WHERE DaysStartTo100Pct IS NOT NULL
    GROUP BY ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey
    UNION ALL
    SELECT 2, 'DaysStartTo100Pct', @SK_Start,
           ServiceLineKey, ClientTypeKey, IndustryKey, NULL, NULL,
           AVG(CAST(DaysStartTo100Pct AS DECIMAL(18,6))), COUNT(*), 0,0,0,1,1
    FROM #training WHERE DaysStartTo100Pct IS NOT NULL
    GROUP BY ServiceLineKey, ClientTypeKey, IndustryKey
    UNION ALL
    SELECT 3, 'DaysStartTo100Pct', @SK_Start,
           ServiceLineKey, ClientTypeKey, NULL, NULL, NULL,
           AVG(CAST(DaysStartTo100Pct AS DECIMAL(18,6))), COUNT(*), 0,0,1,1,1
    FROM #training WHERE DaysStartTo100Pct IS NOT NULL
    GROUP BY ServiceLineKey, ClientTypeKey
    UNION ALL
    SELECT 4, 'DaysStartTo100Pct', @SK_Start,
           ServiceLineKey, NULL, NULL, NULL, NULL,
           AVG(CAST(DaysStartTo100Pct AS DECIMAL(18,6))), COUNT(*), 0,1,1,1,1
    FROM #training WHERE DaysStartTo100Pct IS NOT NULL
    GROUP BY ServiceLineKey
    UNION ALL
    SELECT 5, 'DaysStartTo100Pct', @SK_Start,
           NULL, NULL, NULL, NULL, NULL,
           AVG(CAST(DaysStartTo100Pct AS DECIMAL(18,6))), COUNT(*), 1,1,1,1,1
    FROM #training WHERE DaysStartTo100Pct IS NOT NULL;


    -- ── Clear previous build's data in FK-safe order ──────────
    -- Delete in reverse FK dependency order:
    --   analytical_training_summary → analytical_segments
    --   analytical_test_results     → fact_opportunities
    --   analytical_job_results      → analytical_segments
    --   analytical_segments         (safe to delete last)
    DELETE FROM dbo.analytical_training_summary WHERE BuildRunKey <> @BuildRunKey;
    DELETE FROM dbo.analytical_test_results     WHERE BuildRunKey <> @BuildRunKey;
    DELETE FROM dbo.analytical_job_results      WHERE BuildRunKey <> @BuildRunKey;
    DELETE FROM dbo.analytical_segments         WHERE BuildRunKey <> @BuildRunKey;

    INSERT INTO dbo.analytical_segments (
        GranularityLevel, OutcomeName, StatusKey,
        ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey, LeadSourceKey,
        OutcomeEstimate, ObservationCount,
        Cat1Dropped, Cat2Dropped, Cat3Dropped, Cat4Dropped, Cat5Dropped,
        BuildRunKey
    )
    SELECT
        GranularityLevel, OutcomeName, StatusKey,
        ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey, LeadSourceKey,
        OutcomeEstimate, ObservationCount,
        Cat1Dropped, Cat2Dropped, Cat3Dropped, Cat4Dropped, Cat5Dropped,
        @BuildRunKey
    FROM #seg_work;

    DROP TABLE IF EXISTS #training;
    DROP TABLE IF EXISTS #seg_work;
END;
GO


/* ────────────────────────────────────────────────────────────
   3c. usp_ApplyModel
   ────────────────────────────────────────────────────────────
   Applies segment estimates to both the current pipeline and
   the test dataset. For each record, finds the finest
   granularity segment (lowest GranularityLevel) that:
     a. Matches the record's Status + category dimension keys
        (NULL keys in the segment match any value, i.e. the
        category was dropped at that level)
     b. Has ObservationCount >= @MinJobsPerSegment

   Converts day-based estimates into calendar dates by adding
   estimated days to the relevant anchor date:
     EstimatedStartDate  = SoldDate  + DaysSellToStart estimate
     EstimatedPct50Date  = StartDate + DaysStartTo50Pct estimate
     EstimatedPct100Date = StartDate + DaysStartTo100Pct estimate

   DatasetType:
     'Current' — open opportunities, sold/not started, or
                 started jobs outside the training/test windows
     'Test'    — jobs resolved within the test window (actuals
                 available for model performance evaluation)
   ──────────────────────────────────────────────────────────── */
ALTER PROCEDURE dbo.usp_ApplyModel
    @MinJobsPerSegment  INT,
    @TrainingStart      DATE,
    @TrainingEnd        DATE,
    @TestStart          DATE,
    @TestEnd            DATE,
    @BuildRunKey        INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @SK_Open  INT = (SELECT StatusKey FROM dbo.dim_status WHERE StatusName = 'Open Opportunity');
    DECLARE @SK_SNS   INT = (SELECT StatusKey FROM dbo.dim_status WHERE StatusName = 'Sold/Not Started');
    DECLARE @SK_Start INT = (SELECT StatusKey FROM dbo.dim_status WHERE StatusName = 'Started');

    -- ── Segment-matching helper function (inline CTE pattern) ─
    -- For a given record and outcome, this returns the estimate
    -- from the finest qualifying segment.
    -- Applied separately for each outcome in the MERGE below.

    -- ── Clear previous results ────────────────────────────────
    DELETE FROM dbo.analytical_job_results WHERE BuildRunKey <> @BuildRunKey;

    -- ── Build results for all applicable records ──────────────
    -- Records in scope:
    --   - Current pipeline: open opps, sold/not started, started
    --     (ResolutionDate outside training/test windows OR NULL)
    --   - Test dataset: records with ResolutionDate in test window

    ;WITH candidates AS (
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
                WHEN fo.ResolutionDate BETWEEN @TestStart AND @TestEnd THEN 'Test'
                ELSE 'Current'
            END AS DatasetType
        FROM dbo.fact_opportunities fo
        -- Exclude training window records (used to build segments, not to apply model to)
        WHERE fo.ResolutionDate NOT BETWEEN @TrainingStart AND @TrainingEnd
           OR fo.ResolutionDate IS NULL
    ),

    -- For each candidate and outcome, find the finest qualifying segment
    -- using a correlated approach via CROSS APPLY
    win_pct AS (
        SELECT c.OpportunityID, s.OutcomeEstimate AS EstimatedWinPct
        FROM candidates c
        CROSS APPLY (
            SELECT TOP 1 OutcomeEstimate
            FROM dbo.analytical_segments
            WHERE OutcomeName       = 'WinPct'
              AND StatusKey         = @SK_Open
              AND ObservationCount  >= @MinJobsPerSegment
              AND BuildRunKey       = @BuildRunKey
              AND (ServiceLineKey   = c.ServiceLineKey   OR ServiceLineKey   IS NULL)
              AND (ClientTypeKey    = c.ClientTypeKey    OR ClientTypeKey    IS NULL)
              AND (IndustryKey      = c.IndustryKey      OR IndustryKey      IS NULL)
              AND (NewVsExistingKey = c.NewVsExistingKey OR NewVsExistingKey IS NULL)
              AND (LeadSourceKey    = c.LeadSourceKey    OR LeadSourceKey    IS NULL)
            ORDER BY GranularityLevel ASC
        ) s
        -- WinPct only applies to open opportunities and test records
        WHERE c.StatusKey = @SK_Open OR c.DatasetType = 'Test'
    ),

    net_fees AS (
        SELECT c.OpportunityID, s.OutcomeEstimate AS EstimatedNetFees
        FROM candidates c
        CROSS APPLY (
            SELECT TOP 1 OutcomeEstimate
            FROM dbo.analytical_segments
            WHERE OutcomeName       = 'NetFees'
              AND StatusKey         = c.StatusKey
              AND ObservationCount  >= @MinJobsPerSegment
              AND BuildRunKey       = @BuildRunKey
              AND (ServiceLineKey   = c.ServiceLineKey   OR ServiceLineKey   IS NULL)
              AND (ClientTypeKey    = c.ClientTypeKey    OR ClientTypeKey    IS NULL)
              AND (IndustryKey      = c.IndustryKey      OR IndustryKey      IS NULL)
              AND (NewVsExistingKey = c.NewVsExistingKey OR NewVsExistingKey IS NULL)
              AND (LeadSourceKey    = c.LeadSourceKey    OR LeadSourceKey    IS NULL)
            ORDER BY GranularityLevel ASC
        ) s
        -- Only estimate NetFees where actual is unknown
        WHERE c.NetFees IS NULL
    ),

    margin_pct AS (
        SELECT c.OpportunityID, s.OutcomeEstimate AS EstimatedMarginPct
        FROM candidates c
        CROSS APPLY (
            SELECT TOP 1 OutcomeEstimate
            FROM dbo.analytical_segments
            WHERE OutcomeName       = 'MarginPct'
              AND StatusKey         = c.StatusKey
              AND ObservationCount  >= @MinJobsPerSegment
              AND BuildRunKey       = @BuildRunKey
              AND (ServiceLineKey   = c.ServiceLineKey   OR ServiceLineKey   IS NULL)
              AND (ClientTypeKey    = c.ClientTypeKey    OR ClientTypeKey    IS NULL)
              AND (IndustryKey      = c.IndustryKey      OR IndustryKey      IS NULL)
              AND (NewVsExistingKey = c.NewVsExistingKey OR NewVsExistingKey IS NULL)
              AND (LeadSourceKey    = c.LeadSourceKey    OR LeadSourceKey    IS NULL)
            ORDER BY GranularityLevel ASC
        ) s
        -- Only estimate MarginPct where actual is unknown
        WHERE c.MarginPct IS NULL
    ),

    days_sell_to_start AS (
        SELECT c.OpportunityID,
               s.OutcomeEstimate AS EstimatedDaysSellToStart,
               -- Compute estimated start date: SoldDate + estimated days
               DATEADD(day, CAST(s.OutcomeEstimate AS INT), c.SoldDate) AS EstimatedStartDate
        FROM candidates c
        CROSS APPLY (
            SELECT TOP 1 OutcomeEstimate
            FROM dbo.analytical_segments
            WHERE OutcomeName       = 'DaysSellToStart'
              AND StatusKey         = @SK_SNS
              AND ObservationCount  >= @MinJobsPerSegment
              AND BuildRunKey       = @BuildRunKey
              AND (ServiceLineKey   = c.ServiceLineKey   OR ServiceLineKey   IS NULL)
              AND (ClientTypeKey    = c.ClientTypeKey    OR ClientTypeKey    IS NULL)
              AND (IndustryKey      = c.IndustryKey      OR IndustryKey      IS NULL)
              AND (NewVsExistingKey = c.NewVsExistingKey OR NewVsExistingKey IS NULL)
              AND (LeadSourceKey    = c.LeadSourceKey    OR LeadSourceKey    IS NULL)
            ORDER BY GranularityLevel ASC
        ) s
        WHERE c.StatusKey = @SK_SNS
          AND c.SoldDate  IS NOT NULL
    ),

    days_to_50 AS (
        SELECT c.OpportunityID,
               -- Compute estimated 50% date: StartDate + estimated days
               DATEADD(day, CAST(s.OutcomeEstimate AS INT), c.StartDate) AS EstimatedPct50Date
        FROM candidates c
        CROSS APPLY (
            SELECT TOP 1 OutcomeEstimate
            FROM dbo.analytical_segments
            WHERE OutcomeName       = 'DaysStartTo50Pct'
              AND StatusKey         = @SK_Start
              AND ObservationCount  >= @MinJobsPerSegment
              AND BuildRunKey       = @BuildRunKey
              AND (ServiceLineKey   = c.ServiceLineKey   OR ServiceLineKey   IS NULL)
              AND (ClientTypeKey    = c.ClientTypeKey    OR ClientTypeKey    IS NULL)
              AND (IndustryKey      = c.IndustryKey      OR IndustryKey      IS NULL)
              AND (NewVsExistingKey = c.NewVsExistingKey OR NewVsExistingKey IS NULL)
              AND (LeadSourceKey    = c.LeadSourceKey    OR LeadSourceKey    IS NULL)
            ORDER BY GranularityLevel ASC
        ) s
        WHERE c.StatusKey  = @SK_Start
          AND c.StartDate  IS NOT NULL
    ),

    days_to_100 AS (
        SELECT c.OpportunityID,
               -- Compute estimated 100% date: StartDate + estimated days
               DATEADD(day, CAST(s.OutcomeEstimate AS INT), c.StartDate) AS EstimatedPct100Date
        FROM candidates c
        CROSS APPLY (
            SELECT TOP 1 OutcomeEstimate
            FROM dbo.analytical_segments
            WHERE OutcomeName       = 'DaysStartTo100Pct'
              AND StatusKey         = @SK_Start
              AND ObservationCount  >= @MinJobsPerSegment
              AND BuildRunKey       = @BuildRunKey
              AND (ServiceLineKey   = c.ServiceLineKey   OR ServiceLineKey   IS NULL)
              AND (ClientTypeKey    = c.ClientTypeKey    OR ClientTypeKey    IS NULL)
              AND (IndustryKey      = c.IndustryKey      OR IndustryKey      IS NULL)
              AND (NewVsExistingKey = c.NewVsExistingKey OR NewVsExistingKey IS NULL)
              AND (LeadSourceKey    = c.LeadSourceKey    OR LeadSourceKey    IS NULL)
            ORDER BY GranularityLevel ASC
        ) s
        WHERE c.StatusKey  = @SK_Start
          AND c.StartDate  IS NOT NULL
    ),

    -- Resolve best-fit SegmentKey for each record
    -- (finest segment used for NetFees, as a representative key)
    best_segment AS (
        SELECT c.OpportunityID, s.SegmentKey
        FROM candidates c
        CROSS APPLY (
            SELECT TOP 1 SegmentKey
            FROM dbo.analytical_segments
            WHERE OutcomeName       = 'NetFees'
              AND StatusKey         = c.StatusKey
              AND ObservationCount  >= @MinJobsPerSegment
              AND BuildRunKey       = @BuildRunKey
              AND (ServiceLineKey   = c.ServiceLineKey   OR ServiceLineKey   IS NULL)
              AND (ClientTypeKey    = c.ClientTypeKey    OR ClientTypeKey    IS NULL)
              AND (IndustryKey      = c.IndustryKey      OR IndustryKey      IS NULL)
              AND (NewVsExistingKey = c.NewVsExistingKey OR NewVsExistingKey IS NULL)
              AND (LeadSourceKey    = c.LeadSourceKey    OR LeadSourceKey    IS NULL)
            ORDER BY GranularityLevel ASC
        ) s
    )

    -- ── Merge all estimates into analytical_job_results ───────
    MERGE dbo.analytical_job_results AS tgt
    USING (
        SELECT
            c.OpportunityID,
            bs.SegmentKey,
            wp.EstimatedWinPct,
            -- Use actual NetFees if available, otherwise estimated
            COALESCE(c.NetFees,    nf.EstimatedNetFees)    AS EstimatedNetFees,
            COALESCE(c.MarginPct,  mp.EstimatedMarginPct)  AS EstimatedMarginPct,
            -- MarginDollars = estimated margin % × estimated net fees
            COALESCE(c.MarginPct, mp.EstimatedMarginPct)
                * COALESCE(c.NetFees, nf.EstimatedNetFees) AS EstimatedMarginDollars,
            -- Timing dates: use actual date where known, estimated where not
            NULL                                            AS EstimatedSellDate,
            COALESCE(c.StartDate, ds.EstimatedStartDate)   AS EstimatedStartDate,
            d50.EstimatedPct50Date,
            d100.EstimatedPct100Date,
            c.DatasetType,
            @BuildRunKey                                    AS BuildRunKey
        FROM candidates          c
        LEFT JOIN best_segment   bs   ON bs.OpportunityID  = c.OpportunityID
        LEFT JOIN win_pct        wp   ON wp.OpportunityID  = c.OpportunityID
        LEFT JOIN net_fees       nf   ON nf.OpportunityID  = c.OpportunityID
        LEFT JOIN margin_pct     mp   ON mp.OpportunityID  = c.OpportunityID
        LEFT JOIN days_sell_to_start ds ON ds.OpportunityID = c.OpportunityID
        LEFT JOIN days_to_50     d50  ON d50.OpportunityID = c.OpportunityID
        LEFT JOIN days_to_100    d100 ON d100.OpportunityID = c.OpportunityID
    ) AS src ON tgt.OpportunityID = src.OpportunityID

    WHEN MATCHED THEN UPDATE SET
        tgt.SegmentKey              = src.SegmentKey,
        tgt.EstimatedWinPct         = src.EstimatedWinPct,
        tgt.EstimatedNetFees        = src.EstimatedNetFees,
        tgt.EstimatedMarginPct      = src.EstimatedMarginPct,
        tgt.EstimatedMarginDollars  = src.EstimatedMarginDollars,
        tgt.EstimatedSellDate       = src.EstimatedSellDate,
        tgt.EstimatedStartDate      = src.EstimatedStartDate,
        tgt.EstimatedPct50Date      = src.EstimatedPct50Date,
        tgt.EstimatedPct100Date     = src.EstimatedPct100Date,
        tgt.DatasetType             = src.DatasetType,
        tgt.BuildRunKey             = src.BuildRunKey

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
END;
GO


/* ────────────────────────────────────────────────────────────
   3d. usp_BuildPipelineAggregations
   ────────────────────────────────────────────────────────────
   Aggregates job-level results into monthly pipeline summary.

   - Buckets current-pipeline records by EstimatedStartDate month
   - Computes: EstimatedJobCount, EstimatedNetFees,
     EstimatedMarginDollars, and median 50%/100% dates
   - Median dates computed via PERCENTILE_CONT(0.5)
   - Only includes DatasetType = 'Current' records
     (test records have actuals and are excluded from pipeline)
   ──────────────────────────────────────────────────────────── */
ALTER PROCEDURE dbo.usp_BuildPipelineAggregations
    @BuildRunKey INT
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM dbo.analytical_pipeline_results
    WHERE BuildRunKey <> @BuildRunKey;

    -- CTE must precede the INSERT statement in SQL Server
    ;WITH job_data AS (
        SELECT
            DATEFROMPARTS(
                YEAR(jr.EstimatedStartDate),
                MONTH(jr.EstimatedStartDate),
                1
            )                           AS PeriodMonth,
            jr.EstimatedNetFees,
            jr.EstimatedMarginDollars,
            jr.EstimatedPct50Date,
            jr.EstimatedPct100Date
        FROM dbo.analytical_job_results jr
        WHERE jr.BuildRunKey        = @BuildRunKey
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
                    ORDER BY DATEDIFF(day, PeriodMonth, EstimatedPct50Date)
                ) OVER (PARTITION BY PeriodMonth)
            AS INT) AS Median50Offset,
            CAST(
                PERCENTILE_CONT(0.5) WITHIN GROUP (
                    ORDER BY DATEDIFF(day, PeriodMonth, EstimatedPct100Date)
                ) OVER (PARTITION BY PeriodMonth)
            AS INT) AS Median100Offset
        FROM job_data
    )
    INSERT INTO dbo.analytical_pipeline_results (
        PeriodMonth, EstimatedJobCount,
        EstimatedNetFees, EstimatedMarginDollars,
        MedianPct50Date, MedianPct100Date,
        BuildRunKey
    )
    SELECT
        PeriodMonth,
        COUNT(*)                                         AS EstimatedJobCount,
        SUM(EstimatedNetFees)                            AS EstimatedNetFees,
        SUM(EstimatedMarginDollars)                      AS EstimatedMarginDollars,
        DATEADD(day, MIN(Median50Offset),  MIN(PeriodMonth)) AS MedianPct50Date,
        DATEADD(day, MIN(Median100Offset), MIN(PeriodMonth)) AS MedianPct100Date,
        @BuildRunKey                                     AS BuildRunKey
    FROM with_medians
    GROUP BY PeriodMonth;
END;
GO


/* ────────────────────────────────────────────────────────────
   3e. usp_RunBuild
   ────────────────────────────────────────────────────────────
   Master orchestrator. Called by Section 4 of this script.

   Sequence:
     1. Compute default date windows if NULLs passed in
     2. Insert a log row (Status = 'Running')
     3. usp_LoadRawData     → fact_opportunities
     4. usp_BuildSegments   → analytical_segments
     5. usp_ApplyModel      → analytical_job_results
     6. usp_BuildPipelineAggregations → analytical_pipeline_results
     7. Update log row (Status = 'Success' or 'Error')

   On error: catches exceptions, marks log row as 'Error',
   and re-raises so the caller sees the failure.

   Default date windows (computed from end of last calendar month):
     TrainingStart = end_of_last_month - 24 months
     TrainingEnd   = end_of_last_month -  7 months
     TestStart     = end_of_last_month -  6 months
     TestEnd       = end_of_last_month -  1 month
   ──────────────────────────────────────────────────────────── */
ALTER PROCEDURE dbo.usp_RunBuild
    @MinJobsPerSegment  INT  = 30,
    @TrainingStart      DATE = NULL,
    @TrainingEnd        DATE = NULL,
    @TestStart          DATE = NULL,
    @TestEnd            DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @BuildRunKey    INT;
    DECLARE @ErrMsg         VARCHAR(500);
    DECLARE @RowsProcessed  INT;
    DECLARE @SegmentsBuilt  INT;
    DECLARE @JobResults     INT;

    -- ── Compute default date windows ──────────────────────────
    -- End of last calendar month = first day of this month - 1 day
    DECLARE @EndOfLastMonth DATE =
        DATEADD(day, -1, DATEADD(month, DATEDIFF(month, 0, GETDATE()), 0));

    IF @TrainingStart IS NULL
        SET @TrainingStart = DATEADD(month, -24, @EndOfLastMonth);
    IF @TrainingEnd   IS NULL
        SET @TrainingEnd   = DATEADD(month,  -7, @EndOfLastMonth);
    IF @TestStart     IS NULL
        SET @TestStart     = DATEADD(month,  -6, @EndOfLastMonth);
    IF @TestEnd       IS NULL
        SET @TestEnd       = DATEADD(month,  -1, @EndOfLastMonth);

    -- ── Log run start ─────────────────────────────────────────
    INSERT INTO dbo.log_build_runs (
        MinJobsPerSegment, TrainingStart, TrainingEnd,
        TestStart, TestEnd, Status
    ) VALUES (
        @MinJobsPerSegment, @TrainingStart, @TrainingEnd,
        @TestStart, @TestEnd, 'Running'
    );
    SET @BuildRunKey = SCOPE_IDENTITY();

    BEGIN TRY

        -- Step 1: Load raw data into fact table
        EXEC dbo.usp_LoadRawData @BuildRunKey = @BuildRunKey;
        SET @RowsProcessed = @@ROWCOUNT;

        -- Step 2: Build segment estimates from training data
        EXEC dbo.usp_BuildSegments
            @MinJobsPerSegment  = @MinJobsPerSegment,
            @TrainingStart      = @TrainingStart,
            @TrainingEnd        = @TrainingEnd,
            @BuildRunKey        = @BuildRunKey;
        SET @SegmentsBuilt = (
            SELECT COUNT(*) FROM dbo.analytical_segments
            WHERE BuildRunKey = @BuildRunKey
        );

        -- Step 3: Apply segment estimates to current pipeline + test data
        EXEC dbo.usp_ApplyModel
            @MinJobsPerSegment  = @MinJobsPerSegment,
            @TrainingStart      = @TrainingStart,
            @TrainingEnd        = @TrainingEnd,
            @TestStart          = @TestStart,
            @TestEnd            = @TestEnd,
            @BuildRunKey        = @BuildRunKey;
        SET @JobResults = (
            SELECT COUNT(*) FROM dbo.analytical_job_results
            WHERE BuildRunKey = @BuildRunKey
        );

        -- Step 4: Aggregate job results into monthly pipeline summary
        EXEC dbo.usp_BuildPipelineAggregations @BuildRunKey = @BuildRunKey;

        -- ── Mark run as successful ────────────────────────────
        UPDATE dbo.log_build_runs SET
            Status             = 'Success',
            RowsProcessed      = @RowsProcessed,
            SegmentsBuilt      = @SegmentsBuilt,
            JobResultsWritten  = @JobResults,
            StatusMessage      = CONCAT(
                'Training: ', @TrainingStart, ' to ', @TrainingEnd,
                ' | Test: ', @TestStart, ' to ', @TestEnd,
                ' | Min segment size: ', @MinJobsPerSegment
            )
        WHERE BuildRunKey = @BuildRunKey;

        -- ── Summary output ────────────────────────────────────
        SELECT
            @BuildRunKey        AS BuildRunKey,
            'Success'           AS Status,
            @TrainingStart      AS TrainingStart,
            @TrainingEnd        AS TrainingEnd,
            @TestStart          AS TestStart,
            @TestEnd            AS TestEnd,
            @MinJobsPerSegment  AS MinJobsPerSegment,
            @RowsProcessed      AS RowsProcessed,
            @SegmentsBuilt      AS SegmentsBuilt,
            @JobResults         AS JobResultsWritten;

    END TRY
    BEGIN CATCH

        SET @ErrMsg = CONCAT(
            'ERROR in usp_RunBuild: ', ERROR_MESSAGE(),
            ' (Line ', ERROR_LINE(), ')'
        );

        UPDATE dbo.log_build_runs SET
            Status        = 'Error',
            StatusMessage = @ErrMsg
        WHERE BuildRunKey = @BuildRunKey;

        RAISERROR(@ErrMsg, 16, 1);

    END CATCH;
END;
GO


/* ============================================================
   SECTION 4 — EXECUTE BUILD
   ============================================================
   Calls usp_RunBuild with the parameters from Section 1.
   Edit the values below to change the build configuration.
   Leave date parameters as NULL to use the rolling defaults
   computed from GETDATE() (recommended for scheduled runs).
   ============================================================ */

EXEC dbo.usp_RunBuild
    @MinJobsPerSegment  = 30,
    @TrainingStart      = NULL,   -- Default: 24 months before end of last calendar month
    @TrainingEnd        = NULL,   -- Default:  7 months before end of last calendar month
    @TestStart          = NULL,   -- Default:  6 months before end of last calendar month
    @TestEnd            = NULL;   -- Default:  1 month  before end of last calendar month
GO
