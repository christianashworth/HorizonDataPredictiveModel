/* ============================================================
   SCRIPT 03 — Training Summary & Test Results Tables
   PipelineAnalytics (SQL Server)
   Horizon Data Predictive Model
   ============================================================
   Purpose  : Adds two analytical output tables and their
              stored procedures:

              analytical_training_summary
                One row per segment-outcome combination.
                Fully denormalized (dimension names joined in).
                Dropped categories display as 'All'.
                Includes readable SegmentLabel and
                DroppedCategoriesLabel for Power BI.

              analytical_test_results
                One row per test-window record per outcome.
                Stores PredictedValue, ActualValue, Error,
                AbsoluteError, SquaredError, and PercentageError.
                SquaredError weights larger misses more heavily.
                Only written where actual values exist.
                WinPct actual = 1.0 (won) or 0.0 (lost).
                WinPct aggregates to SUM(Predicted) = expected wins
                vs SUM(Actual) = actual wins for calibration.

              usp_BuildTrainingSummary
                Populates analytical_training_summary from
                analytical_segments + dimension tables.

              usp_BuildTestResults
                Populates analytical_test_results by matching
                test records to their trained segments and
                comparing predicted vs actual outcomes.

              usp_RunBuild is updated to call both procedures
              automatically on every build run.

   Run order: After 01_setup.sql and 02_build.sql.
              Safe to re-run (idempotent).
   ============================================================ */

USE PipelineAnalytics;
GO


/* ============================================================
   SECTION 1 — TABLE DEFINITIONS
   ============================================================ */

/* ── analytical_training_summary ─────────────────────────────
   Human-readable version of analytical_segments.
   Joins dimension names in; dropped categories show as 'All'.
   Power BI uses this for the segment estimate analysis view.
   ──────────────────────────────────────────────────────────── */
IF NOT EXISTS (
    SELECT * FROM sys.objects
    WHERE object_id = OBJECT_ID(N'dbo.analytical_training_summary') AND type = 'U'
)
BEGIN
    CREATE TABLE dbo.analytical_training_summary (
        TrainingSummaryKey      INT           IDENTITY(1,1) NOT NULL,
        SegmentKey              INT           NOT NULL,
        BuildRunKey             INT           NOT NULL,

        -- Outcome
        OutcomeName             VARCHAR(50)   NOT NULL,
        OutcomeEstimate         DECIMAL(18,6) NULL,
        ObservationCount        INT           NOT NULL,

        -- Granularity
        GranularityLevel        INT           NOT NULL,
        CategoriesDropped       INT           NOT NULL,   -- Count: 0-5
        Cat1Dropped             BIT           NOT NULL,
        Cat2Dropped             BIT           NOT NULL,
        Cat3Dropped             BIT           NOT NULL,
        Cat4Dropped             BIT           NOT NULL,
        Cat5Dropped             BIT           NOT NULL,

        -- Dimension names (readable; 'All' where category was dropped)
        StatusName              VARCHAR(50)   NOT NULL,
        ServiceLineName         VARCHAR(50)   NOT NULL,   -- 'All' if Cat1 dropped
        ClientTypeName          VARCHAR(50)   NOT NULL,   -- 'All' if Cat2 dropped
        IndustryName            VARCHAR(100)  NOT NULL,   -- 'All' if Cat3 dropped
        NewVsExistingName       VARCHAR(50)   NOT NULL,   -- 'All' if Cat4 dropped
        LeadSourceName          VARCHAR(100)  NOT NULL,   -- 'All' if Cat5 dropped

        -- Readable labels for Power BI display
        SegmentLabel            VARCHAR(500)  NOT NULL,
        -- Format: "Audit | Business | Healthcare | Existing | Referral"
        -- Dropped categories shown as 'All'
        DroppedCategoriesLabel  VARCHAR(200)  NOT NULL,
        -- Format: "None" | "LeadSource" | "NewVsExisting, LeadSource" | etc.

        CONSTRAINT PK_analytical_training_summary PRIMARY KEY (TrainingSummaryKey),
        CONSTRAINT FK_train_Segment  FOREIGN KEY (SegmentKey)
            REFERENCES dbo.analytical_segments (SegmentKey)
    );
END
GO

IF NOT EXISTS (
    SELECT * FROM sys.indexes
    WHERE object_id = OBJECT_ID('dbo.analytical_training_summary')
      AND name = 'IX_train_BuildRun_Outcome'
)
    CREATE NONCLUSTERED INDEX IX_train_BuildRun_Outcome
        ON dbo.analytical_training_summary (BuildRunKey, OutcomeName)
        INCLUDE (OutcomeEstimate, ObservationCount, GranularityLevel,
                 SegmentLabel, DroppedCategoriesLabel);
GO


/* ── analytical_test_results ──────────────────────────────────
   One row per test-window record per applicable outcome.
   Stores predicted vs actual values and error metrics.
   Power BI uses this for model performance analysis.

   Error metric notes:
     Error           = PredictedValue - ActualValue
                       (positive = overestimate, negative = underestimate)
     AbsoluteError   = ABS(Error)
     SquaredError    = Error² — weights larger misses more heavily than
                       AbsoluteError. Power BI aggregates to SSE (sum),
                       MSE (mean), and RMSE (SQRT of mean) as measures.
     PercentageError = Error / ActualValue
                       (NULL when ActualValue = 0 to avoid division by zero)

   WinPct handling:
     PredictedValue  = segment win probability (e.g. 0.55)
     ActualValue     = 1.0 if won, 0.0 if lost
     At record level, SUM(PredictedValue) = expected number of wins,
     SUM(ActualValue) = actual number of wins — Power BI compares
     these at the segment level for calibration analysis.

   Rows only written where ActualValue IS NOT NULL:
     WinPct            — always available for test records (all resolved)
     NetFees           — available for sold jobs
     MarginPct         — available for 100%-complete jobs only
     DaysSellToStart   — available where StartDate IS NOT NULL
     DaysStartTo50Pct  — available where Pct50CompleteDate IS NOT NULL
     DaysStartTo100Pct — available where Pct100CompleteDate IS NOT NULL
   ──────────────────────────────────────────────────────────── */
IF NOT EXISTS (
    SELECT * FROM sys.objects
    WHERE object_id = OBJECT_ID(N'dbo.analytical_test_results') AND type = 'U'
)
BEGIN
    CREATE TABLE dbo.analytical_test_results (
        TestResultKey           INT             IDENTITY(1,1) NOT NULL,
        OpportunityID           VARCHAR(20)     NOT NULL,
        SegmentKey              INT             NULL,
        BuildRunKey             INT             NOT NULL,

        -- Outcome
        OutcomeName             VARCHAR(50)     NOT NULL,
        PredictedValue          DECIMAL(18,6)   NULL,
        ActualValue             DECIMAL(18,6)   NULL,

        -- Error metrics
        Error                   DECIMAL(18,6)   NULL,   -- Predicted - Actual
        AbsoluteError           DECIMAL(18,6)   NULL,   -- ABS(Error)
        SquaredError            DECIMAL(18,6)   NULL,   -- Error² (weights large misses more heavily)
        PercentageError         DECIMAL(18,6)   NULL,   -- Error / ActualValue

        -- Segment context (for slicing in Power BI)
        GranularityLevel        INT             NULL,
        CategoriesDropped       INT             NULL,
        StatusName              VARCHAR(50)     NULL,
        ServiceLineName         VARCHAR(50)     NULL,
        ClientTypeName          VARCHAR(50)     NULL,
        IndustryName            VARCHAR(100)    NULL,
        NewVsExistingName       VARCHAR(50)     NULL,
        LeadSourceName          VARCHAR(100)    NULL,
        SegmentLabel            VARCHAR(500)    NULL,

        CONSTRAINT PK_analytical_test_results PRIMARY KEY (TestResultKey),
        CONSTRAINT FK_test_Opportunity FOREIGN KEY (OpportunityID)
            REFERENCES dbo.fact_opportunities (OpportunityID)
    );
END
GO

IF NOT EXISTS (
    SELECT * FROM sys.indexes
    WHERE object_id = OBJECT_ID('dbo.analytical_test_results')
      AND name = 'IX_test_BuildRun_Outcome'
)
    CREATE NONCLUSTERED INDEX IX_test_BuildRun_Outcome
        ON dbo.analytical_test_results (BuildRunKey, OutcomeName)
        INCLUDE (PredictedValue, ActualValue, Error, AbsoluteError,
                 PercentageError, SegmentLabel);
GO


/* ============================================================
   SECTION 2 — STORED PROCEDURE SHELLS
   (Logic implemented in Section 3)
   ============================================================ */

IF OBJECT_ID('dbo.usp_BuildTrainingSummary', 'P') IS NULL
    EXEC('CREATE PROCEDURE dbo.usp_BuildTrainingSummary AS BEGIN RETURN 0 END');
GO

IF OBJECT_ID('dbo.usp_BuildTestResults', 'P') IS NULL
    EXEC('CREATE PROCEDURE dbo.usp_BuildTestResults AS BEGIN RETURN 0 END');
GO


/* ============================================================
   SECTION 3 — PROCEDURE IMPLEMENTATIONS
   ============================================================ */


/* ────────────────────────────────────────────────────────────
   usp_BuildTrainingSummary
   ────────────────────────────────────────────────────────────
   Populates analytical_training_summary from analytical_segments
   by joining dimension tables for readable names.

   Dropped categories (NULL key in analytical_segments) are
   displayed as 'All' to indicate the segment covers all values
   of that dimension.

   SegmentLabel format:
     "Audit | Business | Healthcare | Existing | All"
     (last category dropped in this example)

   DroppedCategoriesLabel format:
     "None" | "LeadSource" | "Industry, NewVsExisting, LeadSource"
   ──────────────────────────────────────────────────────────── */
ALTER PROCEDURE dbo.usp_BuildTrainingSummary
    @BuildRunKey INT
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM dbo.analytical_training_summary
    WHERE BuildRunKey <> @BuildRunKey;

    INSERT INTO dbo.analytical_training_summary (
        SegmentKey, BuildRunKey,
        OutcomeName, OutcomeEstimate, ObservationCount,
        GranularityLevel, CategoriesDropped,
        Cat1Dropped, Cat2Dropped, Cat3Dropped, Cat4Dropped, Cat5Dropped,
        StatusName, ServiceLineName, ClientTypeName, IndustryName,
        NewVsExistingName, LeadSourceName,
        SegmentLabel, DroppedCategoriesLabel
    )
    SELECT
        s.SegmentKey,
        s.BuildRunKey,
        s.OutcomeName,
        s.OutcomeEstimate,
        s.ObservationCount,
        s.GranularityLevel,

        -- Count of categories dropped
        CAST(s.Cat1Dropped AS INT) + CAST(s.Cat2Dropped AS INT)
        + CAST(s.Cat3Dropped AS INT) + CAST(s.Cat4Dropped AS INT)
        + CAST(s.Cat5Dropped AS INT)                     AS CategoriesDropped,

        s.Cat1Dropped, s.Cat2Dropped, s.Cat3Dropped,
        s.Cat4Dropped, s.Cat5Dropped,

        -- Dimension names ('All' where category was dropped)
        st.StatusName,
        CASE WHEN s.Cat1Dropped = 1 THEN 'All' ELSE sl.ServiceLineName  END AS ServiceLineName,
        CASE WHEN s.Cat2Dropped = 1 THEN 'All' ELSE ct.ClientTypeName   END AS ClientTypeName,
        CASE WHEN s.Cat3Dropped = 1 THEN 'All' ELSE ind.IndustryName    END AS IndustryName,
        CASE WHEN s.Cat4Dropped = 1 THEN 'All' ELSE nve.NewVsExistingName END AS NewVsExistingName,
        CASE WHEN s.Cat5Dropped = 1 THEN 'All' ELSE ls.LeadSourceName   END AS LeadSourceName,

        -- SegmentLabel: pipe-delimited readable cell identifier
        CONCAT(
            st.StatusName, ' | ',
            CASE WHEN s.Cat1Dropped = 1 THEN 'All' ELSE sl.ServiceLineName  END, ' | ',
            CASE WHEN s.Cat2Dropped = 1 THEN 'All' ELSE ct.ClientTypeName   END, ' | ',
            CASE WHEN s.Cat3Dropped = 1 THEN 'All' ELSE ind.IndustryName    END, ' | ',
            CASE WHEN s.Cat4Dropped = 1 THEN 'All' ELSE nve.NewVsExistingName END, ' | ',
            CASE WHEN s.Cat5Dropped = 1 THEN 'All' ELSE ls.LeadSourceName   END
        ) AS SegmentLabel,

        -- DroppedCategoriesLabel: comma-separated list of dropped category names
        CASE
            WHEN s.Cat1Dropped = 0 AND s.Cat2Dropped = 0 AND s.Cat3Dropped = 0
             AND s.Cat4Dropped = 0 AND s.Cat5Dropped = 0
            THEN 'None'
            ELSE STUFF(
                CASE WHEN s.Cat1Dropped = 1 THEN ', ServiceLine'    ELSE '' END +
                CASE WHEN s.Cat2Dropped = 1 THEN ', ClientType'     ELSE '' END +
                CASE WHEN s.Cat3Dropped = 1 THEN ', Industry'       ELSE '' END +
                CASE WHEN s.Cat4Dropped = 1 THEN ', NewVsExisting'  ELSE '' END +
                CASE WHEN s.Cat5Dropped = 1 THEN ', LeadSource'     ELSE '' END,
                1, 2, ''   -- Remove leading ', '
            )
        END AS DroppedCategoriesLabel

    FROM dbo.analytical_segments s
    JOIN dbo.dim_status           st  ON st.StatusKey        = s.StatusKey
    -- Dimension lookups: join on key when not dropped, fall back to Unknown name for display
    LEFT JOIN dbo.dim_service_line    sl  ON sl.ServiceLineKey    = s.ServiceLineKey
    LEFT JOIN dbo.dim_client_type     ct  ON ct.ClientTypeKey     = s.ClientTypeKey
    LEFT JOIN dbo.dim_industry        ind ON ind.IndustryKey      = s.IndustryKey
    LEFT JOIN dbo.dim_new_vs_existing nve ON nve.NewVsExistingKey = s.NewVsExistingKey
    LEFT JOIN dbo.dim_lead_source     ls  ON ls.LeadSourceKey     = s.LeadSourceKey
    WHERE s.BuildRunKey = @BuildRunKey;
END;
GO


/* ────────────────────────────────────────────────────────────
   usp_BuildTestResults
   ────────────────────────────────────────────────────────────
   Populates analytical_test_results by:
   1. Identifying test-window records (DatasetType = 'Test')
      from analytical_job_results
   2. Joining to fact_opportunities for actual outcome values
   3. Unpivoting to one row per record per applicable outcome
   4. Computing Error, AbsoluteError, PercentageError
   5. Joining training summary for readable segment context

   Only writes rows where ActualValue IS NOT NULL.
   ──────────────────────────────────────────────────────────── */
ALTER PROCEDURE dbo.usp_BuildTestResults
    @BuildRunKey INT
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM dbo.analytical_test_results
    WHERE BuildRunKey <> @BuildRunKey;

    INSERT INTO dbo.analytical_test_results (
        OpportunityID, SegmentKey, BuildRunKey,
        OutcomeName, PredictedValue, ActualValue,
        Error, AbsoluteError, SquaredError, PercentageError,
        GranularityLevel, CategoriesDropped,
        StatusName, ServiceLineName, ClientTypeName,
        IndustryName, NewVsExistingName, LeadSourceName,
        SegmentLabel
    )

    -- Unpivot: one row per outcome per test record
    -- Each UNION ALL block covers one outcome
    SELECT
        jr.OpportunityID,
        jr.SegmentKey,
        jr.BuildRunKey,
        outcomes.OutcomeName,
        outcomes.PredictedValue,
        outcomes.ActualValue,
        -- Error metrics
        outcomes.PredictedValue - outcomes.ActualValue          AS Error,
        ABS(outcomes.PredictedValue - outcomes.ActualValue)     AS AbsoluteError,
        POWER(outcomes.PredictedValue - outcomes.ActualValue, 2) AS SquaredError,
        CASE
            WHEN outcomes.ActualValue = 0 THEN NULL  -- Avoid division by zero
            ELSE (outcomes.PredictedValue - outcomes.ActualValue) / outcomes.ActualValue
        END                                                     AS PercentageError,
        -- Segment context from training summary
        ts.GranularityLevel,
        ts.CategoriesDropped,
        ts.StatusName,
        ts.ServiceLineName,
        ts.ClientTypeName,
        ts.IndustryName,
        ts.NewVsExistingName,
        ts.LeadSourceName,
        ts.SegmentLabel

    FROM dbo.analytical_job_results jr
    JOIN dbo.fact_opportunities fo
        ON fo.OpportunityID = jr.OpportunityID
    -- Join training summary for segment context (use OutcomeName = 'NetFees'
    -- as the representative row since SegmentKey is keyed to NetFees segments)
    LEFT JOIN dbo.analytical_training_summary ts
        ON ts.SegmentKey    = jr.SegmentKey
        AND ts.BuildRunKey  = jr.BuildRunKey
        AND ts.OutcomeName  = 'NetFees'

    -- Unpivot outcomes via CROSS APPLY VALUES
    CROSS APPLY (
        VALUES
        -- WinPct: actual = 1.0 if won, 0.0 if lost (always available for test records)
        (
            'WinPct',
            jr.EstimatedWinPct,
            CASE WHEN fo.SoldDate IS NOT NULL THEN 1.0 ELSE 0.0 END
        ),
        -- NetFees: actual available once sold
        (
            'NetFees',
            jr.EstimatedNetFees,
            CAST(fo.NetFees AS DECIMAL(18,6))
        ),
        -- MarginPct: actual available only at 100% complete
        (
            'MarginPct',
            jr.EstimatedMarginPct,
            CAST(fo.MarginPct AS DECIMAL(18,6))
        ),
        -- DaysSellToStart: actual available where job has started
        (
            'DaysSellToStart',
            NULL,   -- Not stored in job_results; derived from segment for comparison
            CAST(fo.DaysSellToStart AS DECIMAL(18,6))
        ),
        -- DaysStartTo50Pct: actual available where 50% reached
        (
            'DaysStartTo50Pct',
            NULL,
            CAST(fo.DaysStartTo50Pct AS DECIMAL(18,6))
        ),
        -- DaysStartTo100Pct: actual available where 100% reached
        (
            'DaysStartTo100Pct',
            NULL,
            CAST(fo.DaysStartTo100Pct AS DECIMAL(18,6))
        )
    ) AS outcomes(OutcomeName, PredictedValue, ActualValue)

    WHERE jr.DatasetType        = 'Test'
      AND jr.BuildRunKey        = @BuildRunKey
      AND outcomes.ActualValue  IS NOT NULL
      AND outcomes.PredictedValue IS NOT NULL;


    -- ── Patch: populate timing predicted values from segments ──
    -- DaysSellToStart/50Pct/100Pct predicted values come from
    -- the matched segment rather than job_results directly.
    -- Update these rows with the segment estimate.
    UPDATE tr
    SET tr.PredictedValue  = s.OutcomeEstimate,
        tr.Error           = s.OutcomeEstimate - tr.ActualValue,
        tr.AbsoluteError   = ABS(s.OutcomeEstimate - tr.ActualValue),
        tr.SquaredError    = POWER(s.OutcomeEstimate - tr.ActualValue, 2),
        tr.PercentageError = CASE
            WHEN tr.ActualValue = 0 THEN NULL
            ELSE (s.OutcomeEstimate - tr.ActualValue) / tr.ActualValue
        END
    FROM dbo.analytical_test_results tr
    JOIN dbo.analytical_job_results  jr ON jr.OpportunityID = tr.OpportunityID
                                        AND jr.BuildRunKey  = tr.BuildRunKey
    JOIN dbo.analytical_segments     s  ON s.SegmentKey     = jr.SegmentKey
                                        AND s.OutcomeName   = tr.OutcomeName
                                        AND s.BuildRunKey   = tr.BuildRunKey
    WHERE tr.BuildRunKey = @BuildRunKey
      AND tr.OutcomeName IN ('DaysSellToStart','DaysStartTo50Pct','DaysStartTo100Pct')
      AND tr.PredictedValue IS NULL;

    -- Remove any remaining rows where predicted is still NULL after patch
    DELETE FROM dbo.analytical_test_results
    WHERE BuildRunKey     = @BuildRunKey
      AND PredictedValue  IS NULL;

END;
GO


/* ============================================================
   SECTION 3b — FIX usp_BuildSegments DELETE ORDER
   ============================================================
   analytical_training_summary references analytical_segments
   via FK_train_Segment, so it must be deleted before
   analytical_segments. Update the procedure to include all
   dependent tables in the correct FK-safe delete order.
   ============================================================ */
ALTER PROCEDURE dbo.usp_BuildSegments
    @MinJobsPerSegment  INT,
    @TrainingStart      DATE,
    @TrainingEnd        DATE,
    @BuildRunKey        INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @SK_Open  INT = (SELECT StatusKey FROM dbo.dim_status WHERE StatusName = 'Open Opportunity');
    DECLARE @SK_Lost  INT = (SELECT StatusKey FROM dbo.dim_status WHERE StatusName = 'Lost');
    DECLARE @SK_SNS   INT = (SELECT StatusKey FROM dbo.dim_status WHERE StatusName = 'Sold/Not Started');
    DECLARE @SK_Start INT = (SELECT StatusKey FROM dbo.dim_status WHERE StatusName = 'Started');

    CREATE TABLE #seg_work (
        GranularityLevel    INT          NOT NULL,
        OutcomeName         VARCHAR(50)  NOT NULL,
        StatusKey           INT          NOT NULL,
        ServiceLineKey      INT          NULL,
        ClientTypeKey       INT          NULL,
        IndustryKey         INT          NULL,
        NewVsExistingKey    INT          NULL,
        LeadSourceKey       INT          NULL,
        OutcomeEstimate     DECIMAL(18,6) NULL,
        ObservationCount    INT          NOT NULL,
        Cat1Dropped         BIT          NOT NULL DEFAULT 0,
        Cat2Dropped         BIT          NOT NULL DEFAULT 0,
        Cat3Dropped         BIT          NOT NULL DEFAULT 0,
        Cat4Dropped         BIT          NOT NULL DEFAULT 0,
        Cat5Dropped         BIT          NOT NULL DEFAULT 0
    );

    SELECT
        OpportunityID, ServiceLineKey, ClientTypeKey, IndustryKey,
        NewVsExistingKey, LeadSourceKey, StatusKey,
        SoldDate, ClosedLostDate, StartDate,
        Pct50CompleteDate, Pct100CompleteDate, ResolutionDate,
        NetFees, MarginPct, MarginDollars,
        DaysSellToStart, DaysStartTo50Pct, DaysStartTo100Pct
    INTO #training
    FROM dbo.fact_opportunities
    WHERE ResolutionDate BETWEEN @TrainingStart AND @TrainingEnd;

    -- WinPct
    INSERT INTO #seg_work
        (GranularityLevel, OutcomeName, StatusKey,
         ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey, LeadSourceKey,
         OutcomeEstimate, ObservationCount,
         Cat1Dropped, Cat2Dropped, Cat3Dropped, Cat4Dropped, Cat5Dropped)
    SELECT 0, 'WinPct', @SK_Open,
           ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey, LeadSourceKey,
           AVG(CAST(CASE WHEN SoldDate IS NOT NULL THEN 1.0 ELSE 0.0 END AS DECIMAL(18,6))),
           COUNT(*), 0,0,0,0,0
    FROM #training GROUP BY ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey,LeadSourceKey
    UNION ALL
    SELECT 1,'WinPct',@SK_Open,ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey,NULL,
           AVG(CAST(CASE WHEN SoldDate IS NOT NULL THEN 1.0 ELSE 0.0 END AS DECIMAL(18,6))),COUNT(*),0,0,0,0,1
    FROM #training GROUP BY ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey
    UNION ALL
    SELECT 2,'WinPct',@SK_Open,ServiceLineKey,ClientTypeKey,IndustryKey,NULL,NULL,
           AVG(CAST(CASE WHEN SoldDate IS NOT NULL THEN 1.0 ELSE 0.0 END AS DECIMAL(18,6))),COUNT(*),0,0,0,1,1
    FROM #training GROUP BY ServiceLineKey,ClientTypeKey,IndustryKey
    UNION ALL
    SELECT 3,'WinPct',@SK_Open,ServiceLineKey,ClientTypeKey,NULL,NULL,NULL,
           AVG(CAST(CASE WHEN SoldDate IS NOT NULL THEN 1.0 ELSE 0.0 END AS DECIMAL(18,6))),COUNT(*),0,0,1,1,1
    FROM #training GROUP BY ServiceLineKey,ClientTypeKey
    UNION ALL
    SELECT 4,'WinPct',@SK_Open,ServiceLineKey,NULL,NULL,NULL,NULL,
           AVG(CAST(CASE WHEN SoldDate IS NOT NULL THEN 1.0 ELSE 0.0 END AS DECIMAL(18,6))),COUNT(*),0,1,1,1,1
    FROM #training GROUP BY ServiceLineKey
    UNION ALL
    SELECT 5,'WinPct',@SK_Open,NULL,NULL,NULL,NULL,NULL,
           AVG(CAST(CASE WHEN SoldDate IS NOT NULL THEN 1.0 ELSE 0.0 END AS DECIMAL(18,6))),COUNT(*),1,1,1,1,1
    FROM #training;

    -- NetFees
    INSERT INTO #seg_work
        (GranularityLevel,OutcomeName,StatusKey,ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey,LeadSourceKey,
         OutcomeEstimate,ObservationCount,Cat1Dropped,Cat2Dropped,Cat3Dropped,Cat4Dropped,Cat5Dropped)
    SELECT agg.GranularityLevel,'NetFees',s.StatusKey,agg.slk,agg.ctk,agg.ink,agg.nvek,agg.lsk,
           agg.est,agg.obs,agg.c1,agg.c2,agg.c3,agg.c4,agg.c5
    FROM (
        SELECT 0 GranularityLevel,ServiceLineKey slk,ClientTypeKey ctk,IndustryKey ink,NewVsExistingKey nvek,LeadSourceKey lsk,
               AVG(NetFees) est,COUNT(*) obs,CAST(0 AS BIT) c1,CAST(0 AS BIT) c2,CAST(0 AS BIT) c3,CAST(0 AS BIT) c4,CAST(0 AS BIT) c5
        FROM #training WHERE NetFees IS NOT NULL GROUP BY ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey,LeadSourceKey
        UNION ALL
        SELECT 1,ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey,NULL,AVG(NetFees),COUNT(*),0,0,0,0,1
        FROM #training WHERE NetFees IS NOT NULL GROUP BY ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey
        UNION ALL
        SELECT 2,ServiceLineKey,ClientTypeKey,IndustryKey,NULL,NULL,AVG(NetFees),COUNT(*),0,0,0,1,1
        FROM #training WHERE NetFees IS NOT NULL GROUP BY ServiceLineKey,ClientTypeKey,IndustryKey
        UNION ALL
        SELECT 3,ServiceLineKey,ClientTypeKey,NULL,NULL,NULL,AVG(NetFees),COUNT(*),0,0,1,1,1
        FROM #training WHERE NetFees IS NOT NULL GROUP BY ServiceLineKey,ClientTypeKey
        UNION ALL
        SELECT 4,ServiceLineKey,NULL,NULL,NULL,NULL,AVG(NetFees),COUNT(*),0,1,1,1,1
        FROM #training WHERE NetFees IS NOT NULL GROUP BY ServiceLineKey
        UNION ALL
        SELECT 5,NULL,NULL,NULL,NULL,NULL,AVG(NetFees),COUNT(*),1,1,1,1,1
        FROM #training WHERE NetFees IS NOT NULL
    ) agg CROSS JOIN dbo.dim_status s;

    -- MarginPct
    INSERT INTO #seg_work
        (GranularityLevel,OutcomeName,StatusKey,ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey,LeadSourceKey,
         OutcomeEstimate,ObservationCount,Cat1Dropped,Cat2Dropped,Cat3Dropped,Cat4Dropped,Cat5Dropped)
    SELECT agg.GranularityLevel,'MarginPct',s.StatusKey,agg.slk,agg.ctk,agg.ink,agg.nvek,agg.lsk,
           agg.est,agg.obs,agg.c1,agg.c2,agg.c3,agg.c4,agg.c5
    FROM (
        SELECT 0 GranularityLevel,ServiceLineKey slk,ClientTypeKey ctk,IndustryKey ink,NewVsExistingKey nvek,LeadSourceKey lsk,
               AVG(MarginPct) est,COUNT(*) obs,CAST(0 AS BIT) c1,CAST(0 AS BIT) c2,CAST(0 AS BIT) c3,CAST(0 AS BIT) c4,CAST(0 AS BIT) c5
        FROM #training WHERE MarginPct IS NOT NULL GROUP BY ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey,LeadSourceKey
        UNION ALL
        SELECT 1,ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey,NULL,AVG(MarginPct),COUNT(*),0,0,0,0,1
        FROM #training WHERE MarginPct IS NOT NULL GROUP BY ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey
        UNION ALL
        SELECT 2,ServiceLineKey,ClientTypeKey,IndustryKey,NULL,NULL,AVG(MarginPct),COUNT(*),0,0,0,1,1
        FROM #training WHERE MarginPct IS NOT NULL GROUP BY ServiceLineKey,ClientTypeKey,IndustryKey
        UNION ALL
        SELECT 3,ServiceLineKey,ClientTypeKey,NULL,NULL,NULL,AVG(MarginPct),COUNT(*),0,0,1,1,1
        FROM #training WHERE MarginPct IS NOT NULL GROUP BY ServiceLineKey,ClientTypeKey
        UNION ALL
        SELECT 4,ServiceLineKey,NULL,NULL,NULL,NULL,AVG(MarginPct),COUNT(*),0,1,1,1,1
        FROM #training WHERE MarginPct IS NOT NULL GROUP BY ServiceLineKey
        UNION ALL
        SELECT 5,NULL,NULL,NULL,NULL,NULL,AVG(MarginPct),COUNT(*),1,1,1,1,1
        FROM #training WHERE MarginPct IS NOT NULL
    ) agg CROSS JOIN dbo.dim_status s;

    -- DaysSellToStart
    INSERT INTO #seg_work
        (GranularityLevel,OutcomeName,StatusKey,ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey,LeadSourceKey,
         OutcomeEstimate,ObservationCount,Cat1Dropped,Cat2Dropped,Cat3Dropped,Cat4Dropped,Cat5Dropped)
    SELECT 0,'DaysSellToStart',@SK_SNS,ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey,LeadSourceKey,
           AVG(CAST(DaysSellToStart AS DECIMAL(18,6))),COUNT(*),0,0,0,0,0
    FROM #training WHERE DaysSellToStart IS NOT NULL GROUP BY ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey,LeadSourceKey
    UNION ALL
    SELECT 1,'DaysSellToStart',@SK_SNS,ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey,NULL,
           AVG(CAST(DaysSellToStart AS DECIMAL(18,6))),COUNT(*),0,0,0,0,1
    FROM #training WHERE DaysSellToStart IS NOT NULL GROUP BY ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey
    UNION ALL
    SELECT 2,'DaysSellToStart',@SK_SNS,ServiceLineKey,ClientTypeKey,IndustryKey,NULL,NULL,
           AVG(CAST(DaysSellToStart AS DECIMAL(18,6))),COUNT(*),0,0,0,1,1
    FROM #training WHERE DaysSellToStart IS NOT NULL GROUP BY ServiceLineKey,ClientTypeKey,IndustryKey
    UNION ALL
    SELECT 3,'DaysSellToStart',@SK_SNS,ServiceLineKey,ClientTypeKey,NULL,NULL,NULL,
           AVG(CAST(DaysSellToStart AS DECIMAL(18,6))),COUNT(*),0,0,1,1,1
    FROM #training WHERE DaysSellToStart IS NOT NULL GROUP BY ServiceLineKey,ClientTypeKey
    UNION ALL
    SELECT 4,'DaysSellToStart',@SK_SNS,ServiceLineKey,NULL,NULL,NULL,NULL,
           AVG(CAST(DaysSellToStart AS DECIMAL(18,6))),COUNT(*),0,1,1,1,1
    FROM #training WHERE DaysSellToStart IS NOT NULL GROUP BY ServiceLineKey
    UNION ALL
    SELECT 5,'DaysSellToStart',@SK_SNS,NULL,NULL,NULL,NULL,NULL,
           AVG(CAST(DaysSellToStart AS DECIMAL(18,6))),COUNT(*),1,1,1,1,1
    FROM #training WHERE DaysSellToStart IS NOT NULL;

    -- DaysStartTo50Pct
    INSERT INTO #seg_work
        (GranularityLevel,OutcomeName,StatusKey,ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey,LeadSourceKey,
         OutcomeEstimate,ObservationCount,Cat1Dropped,Cat2Dropped,Cat3Dropped,Cat4Dropped,Cat5Dropped)
    SELECT 0,'DaysStartTo50Pct',@SK_Start,ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey,LeadSourceKey,
           AVG(CAST(DaysStartTo50Pct AS DECIMAL(18,6))),COUNT(*),0,0,0,0,0
    FROM #training WHERE DaysStartTo50Pct IS NOT NULL GROUP BY ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey,LeadSourceKey
    UNION ALL
    SELECT 1,'DaysStartTo50Pct',@SK_Start,ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey,NULL,
           AVG(CAST(DaysStartTo50Pct AS DECIMAL(18,6))),COUNT(*),0,0,0,0,1
    FROM #training WHERE DaysStartTo50Pct IS NOT NULL GROUP BY ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey
    UNION ALL
    SELECT 2,'DaysStartTo50Pct',@SK_Start,ServiceLineKey,ClientTypeKey,IndustryKey,NULL,NULL,
           AVG(CAST(DaysStartTo50Pct AS DECIMAL(18,6))),COUNT(*),0,0,0,1,1
    FROM #training WHERE DaysStartTo50Pct IS NOT NULL GROUP BY ServiceLineKey,ClientTypeKey,IndustryKey
    UNION ALL
    SELECT 3,'DaysStartTo50Pct',@SK_Start,ServiceLineKey,ClientTypeKey,NULL,NULL,NULL,
           AVG(CAST(DaysStartTo50Pct AS DECIMAL(18,6))),COUNT(*),0,0,1,1,1
    FROM #training WHERE DaysStartTo50Pct IS NOT NULL GROUP BY ServiceLineKey,ClientTypeKey
    UNION ALL
    SELECT 4,'DaysStartTo50Pct',@SK_Start,ServiceLineKey,NULL,NULL,NULL,NULL,
           AVG(CAST(DaysStartTo50Pct AS DECIMAL(18,6))),COUNT(*),0,1,1,1,1
    FROM #training WHERE DaysStartTo50Pct IS NOT NULL GROUP BY ServiceLineKey
    UNION ALL
    SELECT 5,'DaysStartTo50Pct',@SK_Start,NULL,NULL,NULL,NULL,NULL,
           AVG(CAST(DaysStartTo50Pct AS DECIMAL(18,6))),COUNT(*),1,1,1,1,1
    FROM #training WHERE DaysStartTo50Pct IS NOT NULL;

    -- DaysStartTo100Pct
    INSERT INTO #seg_work
        (GranularityLevel,OutcomeName,StatusKey,ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey,LeadSourceKey,
         OutcomeEstimate,ObservationCount,Cat1Dropped,Cat2Dropped,Cat3Dropped,Cat4Dropped,Cat5Dropped)
    SELECT 0,'DaysStartTo100Pct',@SK_Start,ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey,LeadSourceKey,
           AVG(CAST(DaysStartTo100Pct AS DECIMAL(18,6))),COUNT(*),0,0,0,0,0
    FROM #training WHERE DaysStartTo100Pct IS NOT NULL GROUP BY ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey,LeadSourceKey
    UNION ALL
    SELECT 1,'DaysStartTo100Pct',@SK_Start,ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey,NULL,
           AVG(CAST(DaysStartTo100Pct AS DECIMAL(18,6))),COUNT(*),0,0,0,0,1
    FROM #training WHERE DaysStartTo100Pct IS NOT NULL GROUP BY ServiceLineKey,ClientTypeKey,IndustryKey,NewVsExistingKey
    UNION ALL
    SELECT 2,'DaysStartTo100Pct',@SK_Start,ServiceLineKey,ClientTypeKey,IndustryKey,NULL,NULL,
           AVG(CAST(DaysStartTo100Pct AS DECIMAL(18,6))),COUNT(*),0,0,0,1,1
    FROM #training WHERE DaysStartTo100Pct IS NOT NULL GROUP BY ServiceLineKey,ClientTypeKey,IndustryKey
    UNION ALL
    SELECT 3,'DaysStartTo100Pct',@SK_Start,ServiceLineKey,ClientTypeKey,NULL,NULL,NULL,
           AVG(CAST(DaysStartTo100Pct AS DECIMAL(18,6))),COUNT(*),0,0,1,1,1
    FROM #training WHERE DaysStartTo100Pct IS NOT NULL GROUP BY ServiceLineKey,ClientTypeKey
    UNION ALL
    SELECT 4,'DaysStartTo100Pct',@SK_Start,ServiceLineKey,NULL,NULL,NULL,NULL,
           AVG(CAST(DaysStartTo100Pct AS DECIMAL(18,6))),COUNT(*),0,1,1,1,1
    FROM #training WHERE DaysStartTo100Pct IS NOT NULL GROUP BY ServiceLineKey
    UNION ALL
    SELECT 5,'DaysStartTo100Pct',@SK_Start,NULL,NULL,NULL,NULL,NULL,
           AVG(CAST(DaysStartTo100Pct AS DECIMAL(18,6))),COUNT(*),1,1,1,1,1
    FROM #training WHERE DaysStartTo100Pct IS NOT NULL;

    -- Delete in correct FK order: training summary and job results before segments
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


/* ============================================================
   SECTION 4 — UPDATE usp_RunBuild
   ============================================================
   Adds calls to usp_BuildTrainingSummary and usp_BuildTestResults
   after the existing pipeline steps.
   ============================================================ */
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

    DECLARE @EndOfLastMonth DATE =
        DATEADD(day, -1, DATEADD(month, DATEDIFF(month, 0, GETDATE()), 0));

    IF @TrainingStart IS NULL SET @TrainingStart = DATEADD(month, -24, @EndOfLastMonth);
    IF @TrainingEnd   IS NULL SET @TrainingEnd   = DATEADD(month,  -7, @EndOfLastMonth);
    IF @TestStart     IS NULL SET @TestStart     = DATEADD(month,  -6, @EndOfLastMonth);
    IF @TestEnd       IS NULL SET @TestEnd       = DATEADD(month,  -1, @EndOfLastMonth);

    INSERT INTO dbo.log_build_runs (
        MinJobsPerSegment, TrainingStart, TrainingEnd,
        TestStart, TestEnd, Status
    ) VALUES (
        @MinJobsPerSegment, @TrainingStart, @TrainingEnd,
        @TestStart, @TestEnd, 'Running'
    );
    SET @BuildRunKey = SCOPE_IDENTITY();

    BEGIN TRY

        -- Step 1: Load raw data
        EXEC dbo.usp_LoadRawData @BuildRunKey = @BuildRunKey;
        SET @RowsProcessed = @@ROWCOUNT;

        -- Step 2: Build segment estimates from training data
        EXEC dbo.usp_BuildSegments
            @MinJobsPerSegment = @MinJobsPerSegment,
            @TrainingStart     = @TrainingStart,
            @TrainingEnd       = @TrainingEnd,
            @BuildRunKey       = @BuildRunKey;
        SET @SegmentsBuilt = (
            SELECT COUNT(*) FROM dbo.analytical_segments WHERE BuildRunKey = @BuildRunKey
        );

        -- Step 3: Apply model to current pipeline + test data
        EXEC dbo.usp_ApplyModel
            @MinJobsPerSegment = @MinJobsPerSegment,
            @TrainingStart     = @TrainingStart,
            @TrainingEnd       = @TrainingEnd,
            @TestStart         = @TestStart,
            @TestEnd           = @TestEnd,
            @BuildRunKey       = @BuildRunKey;
        SET @JobResults = (
            SELECT COUNT(*) FROM dbo.analytical_job_results WHERE BuildRunKey = @BuildRunKey
        );

        -- Step 4: Monthly pipeline aggregations
        EXEC dbo.usp_BuildPipelineAggregations @BuildRunKey = @BuildRunKey;

        -- Step 5: Human-readable training summary
        EXEC dbo.usp_BuildTrainingSummary @BuildRunKey = @BuildRunKey;

        -- Step 6: Test results (predicted vs actual with error metrics)
        EXEC dbo.usp_BuildTestResults @BuildRunKey = @BuildRunKey;

        UPDATE dbo.log_build_runs SET
            Status            = 'Success',
            RowsProcessed     = @RowsProcessed,
            SegmentsBuilt     = @SegmentsBuilt,
            JobResultsWritten = @JobResults,
            StatusMessage     = CONCAT(
                'Training: ', @TrainingStart, ' to ', @TrainingEnd,
                ' | Test: ', @TestStart, ' to ', @TestEnd,
                ' | Min segment size: ', @MinJobsPerSegment
            )
        WHERE BuildRunKey = @BuildRunKey;

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
        SET @ErrMsg = CONCAT('ERROR in usp_RunBuild: ', ERROR_MESSAGE(),
                             ' (Line ', ERROR_LINE(), ')');
        UPDATE dbo.log_build_runs SET
            Status        = 'Error',
            StatusMessage = @ErrMsg
        WHERE BuildRunKey = @BuildRunKey;
        RAISERROR(@ErrMsg, 16, 1);
    END CATCH;
END;
GO


/* ============================================================
   SECTION 5 — EXECUTE BUILD
   ============================================================
   Re-runs the full build to populate the new tables.
   ============================================================ */
EXEC dbo.usp_RunBuild
    @MinJobsPerSegment = 30,
    @TrainingStart     = NULL,
    @TrainingEnd       = NULL,
    @TestStart         = NULL,
    @TestEnd           = NULL;
GO


/* ============================================================
   SECTION 6 — VERIFICATION
   ============================================================ */
SELECT 'analytical_training_summary rows' AS TableName,
       COUNT(*) AS [RowCount]
FROM dbo.analytical_training_summary
WHERE BuildRunKey = (SELECT MAX(BuildRunKey) FROM dbo.log_build_runs WHERE Status = 'Success')
UNION ALL
SELECT 'analytical_test_results rows',
       COUNT(*)
FROM dbo.analytical_test_results
WHERE BuildRunKey = (SELECT MAX(BuildRunKey) FROM dbo.log_build_runs WHERE Status = 'Success');
GO
