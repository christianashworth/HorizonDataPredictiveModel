/* ============================================================
   FIX SCRIPT v2 — usp_BuildPipelineAggregations +
                   usp_BuildSegments FK delete order
   ============================================================
   Fixes two issues:
   1. Adds semicolon before WITH inside procedure body
      (required by SQL Server when CTE follows a statement)
   2. Corrects delete order in usp_BuildSegments — must delete
      analytical_job_results before analytical_segments due to
      FK_jobres_Segment foreign key constraint
   ============================================================ */

USE PipelineAnalytics;
GO

/* ── Fix 1: usp_BuildPipelineAggregations ─────────────────── */
ALTER PROCEDURE dbo.usp_BuildPipelineAggregations
    @BuildRunKey INT
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM dbo.analytical_pipeline_results
    WHERE BuildRunKey <> @BuildRunKey;

    INSERT INTO dbo.analytical_pipeline_results (
        PeriodMonth, EstimatedJobCount,
        EstimatedNetFees, EstimatedMarginDollars,
        MedianPct50Date, MedianPct100Date,
        BuildRunKey
    )
    -- Semicolon required before WITH when CTE follows a prior statement
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

/* ── Fix 2: usp_BuildSegments — correct FK delete order ───── */
-- analytical_job_results references analytical_segments via
-- FK_jobres_Segment, so job results must be deleted first.
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
    FROM #training GROUP BY ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey, LeadSourceKey
    UNION ALL
    SELECT 1, 'WinPct', @SK_Open, ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey, NULL,
           AVG(CAST(CASE WHEN SoldDate IS NOT NULL THEN 1.0 ELSE 0.0 END AS DECIMAL(18,6))),
           COUNT(*), 0,0,0,0,1
    FROM #training GROUP BY ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey
    UNION ALL
    SELECT 2, 'WinPct', @SK_Open, ServiceLineKey, ClientTypeKey, IndustryKey, NULL, NULL,
           AVG(CAST(CASE WHEN SoldDate IS NOT NULL THEN 1.0 ELSE 0.0 END AS DECIMAL(18,6))),
           COUNT(*), 0,0,0,1,1
    FROM #training GROUP BY ServiceLineKey, ClientTypeKey, IndustryKey
    UNION ALL
    SELECT 3, 'WinPct', @SK_Open, ServiceLineKey, ClientTypeKey, NULL, NULL, NULL,
           AVG(CAST(CASE WHEN SoldDate IS NOT NULL THEN 1.0 ELSE 0.0 END AS DECIMAL(18,6))),
           COUNT(*), 0,0,1,1,1
    FROM #training GROUP BY ServiceLineKey, ClientTypeKey
    UNION ALL
    SELECT 4, 'WinPct', @SK_Open, ServiceLineKey, NULL, NULL, NULL, NULL,
           AVG(CAST(CASE WHEN SoldDate IS NOT NULL THEN 1.0 ELSE 0.0 END AS DECIMAL(18,6))),
           COUNT(*), 0,1,1,1,1
    FROM #training GROUP BY ServiceLineKey
    UNION ALL
    SELECT 5, 'WinPct', @SK_Open, NULL, NULL, NULL, NULL, NULL,
           AVG(CAST(CASE WHEN SoldDate IS NOT NULL THEN 1.0 ELSE 0.0 END AS DECIMAL(18,6))),
           COUNT(*), 1,1,1,1,1
    FROM #training;

    -- NetFees (replicated across all statuses)
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
        SELECT 0 AS GranularityLevel, ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey, LeadSourceKey,
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
    CROSS JOIN dbo.dim_status s;

    -- MarginPct (replicated across all statuses)
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
        SELECT 0 AS GranularityLevel, ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey, LeadSourceKey,
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

    -- DaysSellToStart
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
    SELECT 1, 'DaysSellToStart', @SK_SNS, ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey, NULL,
           AVG(CAST(DaysSellToStart AS DECIMAL(18,6))), COUNT(*), 0,0,0,0,1
    FROM #training WHERE DaysSellToStart IS NOT NULL
    GROUP BY ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey
    UNION ALL
    SELECT 2, 'DaysSellToStart', @SK_SNS, ServiceLineKey, ClientTypeKey, IndustryKey, NULL, NULL,
           AVG(CAST(DaysSellToStart AS DECIMAL(18,6))), COUNT(*), 0,0,0,1,1
    FROM #training WHERE DaysSellToStart IS NOT NULL
    GROUP BY ServiceLineKey, ClientTypeKey, IndustryKey
    UNION ALL
    SELECT 3, 'DaysSellToStart', @SK_SNS, ServiceLineKey, ClientTypeKey, NULL, NULL, NULL,
           AVG(CAST(DaysSellToStart AS DECIMAL(18,6))), COUNT(*), 0,0,1,1,1
    FROM #training WHERE DaysSellToStart IS NOT NULL
    GROUP BY ServiceLineKey, ClientTypeKey
    UNION ALL
    SELECT 4, 'DaysSellToStart', @SK_SNS, ServiceLineKey, NULL, NULL, NULL, NULL,
           AVG(CAST(DaysSellToStart AS DECIMAL(18,6))), COUNT(*), 0,1,1,1,1
    FROM #training WHERE DaysSellToStart IS NOT NULL
    GROUP BY ServiceLineKey
    UNION ALL
    SELECT 5, 'DaysSellToStart', @SK_SNS, NULL, NULL, NULL, NULL, NULL,
           AVG(CAST(DaysSellToStart AS DECIMAL(18,6))), COUNT(*), 1,1,1,1,1
    FROM #training WHERE DaysSellToStart IS NOT NULL;

    -- DaysStartTo50Pct
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
    SELECT 1, 'DaysStartTo50Pct', @SK_Start, ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey, NULL,
           AVG(CAST(DaysStartTo50Pct AS DECIMAL(18,6))), COUNT(*), 0,0,0,0,1
    FROM #training WHERE DaysStartTo50Pct IS NOT NULL
    GROUP BY ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey
    UNION ALL
    SELECT 2, 'DaysStartTo50Pct', @SK_Start, ServiceLineKey, ClientTypeKey, IndustryKey, NULL, NULL,
           AVG(CAST(DaysStartTo50Pct AS DECIMAL(18,6))), COUNT(*), 0,0,0,1,1
    FROM #training WHERE DaysStartTo50Pct IS NOT NULL
    GROUP BY ServiceLineKey, ClientTypeKey, IndustryKey
    UNION ALL
    SELECT 3, 'DaysStartTo50Pct', @SK_Start, ServiceLineKey, ClientTypeKey, NULL, NULL, NULL,
           AVG(CAST(DaysStartTo50Pct AS DECIMAL(18,6))), COUNT(*), 0,0,1,1,1
    FROM #training WHERE DaysStartTo50Pct IS NOT NULL
    GROUP BY ServiceLineKey, ClientTypeKey
    UNION ALL
    SELECT 4, 'DaysStartTo50Pct', @SK_Start, ServiceLineKey, NULL, NULL, NULL, NULL,
           AVG(CAST(DaysStartTo50Pct AS DECIMAL(18,6))), COUNT(*), 0,1,1,1,1
    FROM #training WHERE DaysStartTo50Pct IS NOT NULL
    GROUP BY ServiceLineKey
    UNION ALL
    SELECT 5, 'DaysStartTo50Pct', @SK_Start, NULL, NULL, NULL, NULL, NULL,
           AVG(CAST(DaysStartTo50Pct AS DECIMAL(18,6))), COUNT(*), 1,1,1,1,1
    FROM #training WHERE DaysStartTo50Pct IS NOT NULL;

    -- DaysStartTo100Pct
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
    SELECT 1, 'DaysStartTo100Pct', @SK_Start, ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey, NULL,
           AVG(CAST(DaysStartTo100Pct AS DECIMAL(18,6))), COUNT(*), 0,0,0,0,1
    FROM #training WHERE DaysStartTo100Pct IS NOT NULL
    GROUP BY ServiceLineKey, ClientTypeKey, IndustryKey, NewVsExistingKey
    UNION ALL
    SELECT 2, 'DaysStartTo100Pct', @SK_Start, ServiceLineKey, ClientTypeKey, IndustryKey, NULL, NULL,
           AVG(CAST(DaysStartTo100Pct AS DECIMAL(18,6))), COUNT(*), 0,0,0,1,1
    FROM #training WHERE DaysStartTo100Pct IS NOT NULL
    GROUP BY ServiceLineKey, ClientTypeKey, IndustryKey
    UNION ALL
    SELECT 3, 'DaysStartTo100Pct', @SK_Start, ServiceLineKey, ClientTypeKey, NULL, NULL, NULL,
           AVG(CAST(DaysStartTo100Pct AS DECIMAL(18,6))), COUNT(*), 0,0,1,1,1
    FROM #training WHERE DaysStartTo100Pct IS NOT NULL
    GROUP BY ServiceLineKey, ClientTypeKey
    UNION ALL
    SELECT 4, 'DaysStartTo100Pct', @SK_Start, ServiceLineKey, NULL, NULL, NULL, NULL,
           AVG(CAST(DaysStartTo100Pct AS DECIMAL(18,6))), COUNT(*), 0,1,1,1,1
    FROM #training WHERE DaysStartTo100Pct IS NOT NULL
    GROUP BY ServiceLineKey
    UNION ALL
    SELECT 5, 'DaysStartTo100Pct', @SK_Start, NULL, NULL, NULL, NULL, NULL,
           AVG(CAST(DaysStartTo100Pct AS DECIMAL(18,6))), COUNT(*), 1,1,1,1,1
    FROM #training WHERE DaysStartTo100Pct IS NOT NULL;

    -- Delete in correct FK order: job results first, then segments
    DELETE FROM dbo.analytical_job_results    WHERE BuildRunKey <> @BuildRunKey;
    DELETE FROM dbo.analytical_segments       WHERE BuildRunKey <> @BuildRunKey;

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

-- Re-run the full build
EXEC dbo.usp_RunBuild
    @MinJobsPerSegment  = 30,
    @TrainingStart      = NULL,
    @TrainingEnd        = NULL,
    @TestStart          = NULL,
    @TestEnd            = NULL;
GO
