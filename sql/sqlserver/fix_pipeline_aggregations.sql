/* ============================================================
   FIX SCRIPT — usp_BuildPipelineAggregations
   ============================================================
   Corrects a SQL Server restriction where PERCENTILE_CONT
   (a window function) cannot be mixed with GROUP BY in the
   same query level. Restructured using two CTEs:
     1. job_data   — filters and prepares raw rows
     2. with_medians — applies PERCENTILE_CONT as a window
                       function (no GROUP BY at this level)
   Final SELECT aggregates the pre-computed median offsets.
   ============================================================ */

USE PipelineAnalytics;
GO

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
    -- Step 1: filter and label each job with its period month
    WITH job_data AS (
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
    -- Step 2: compute median day offsets as window functions
    -- (no GROUP BY here — PERCENTILE_CONT requires a clean window context)
    with_medians AS (
        SELECT
            PeriodMonth,
            EstimatedNetFees,
            EstimatedMarginDollars,
            -- Median days from period start to 50% complete
            CAST(
                PERCENTILE_CONT(0.5) WITHIN GROUP (
                    ORDER BY DATEDIFF(day, PeriodMonth, EstimatedPct50Date)
                ) OVER (PARTITION BY PeriodMonth)
            AS INT) AS Median50Offset,
            -- Median days from period start to 100% complete
            CAST(
                PERCENTILE_CONT(0.5) WITHIN GROUP (
                    ORDER BY DATEDIFF(day, PeriodMonth, EstimatedPct100Date)
                ) OVER (PARTITION BY PeriodMonth)
            AS INT) AS Median100Offset
        FROM job_data
    )
    -- Step 3: aggregate — MIN() picks the (identical) median
    -- value that PERCENTILE_CONT assigned to every row in the partition
    SELECT
        PeriodMonth,
        COUNT(*)                                        AS EstimatedJobCount,
        SUM(EstimatedNetFees)                           AS EstimatedNetFees,
        SUM(EstimatedMarginDollars)                     AS EstimatedMarginDollars,
        DATEADD(day, MIN(Median50Offset),  MIN(PeriodMonth)) AS MedianPct50Date,
        DATEADD(day, MIN(Median100Offset), MIN(PeriodMonth)) AS MedianPct100Date,
        @BuildRunKey                                    AS BuildRunKey
    FROM with_medians
    GROUP BY PeriodMonth;

END;
GO

-- Re-run the full build with default rolling date windows
EXEC dbo.usp_RunBuild
    @MinJobsPerSegment  = 30,
    @TrainingStart      = NULL,
    @TrainingEnd        = NULL,
    @TestStart          = NULL,
    @TestEnd            = NULL;
GO
