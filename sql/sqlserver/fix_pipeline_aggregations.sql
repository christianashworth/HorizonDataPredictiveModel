/* ============================================================
   FIX SCRIPT v3 — usp_BuildPipelineAggregations
   ============================================================
   SQL Server requires the CTE to come BEFORE the INSERT
   statement, not inside its SELECT clause.
   Correct pattern:
     ;WITH cte AS (...)
     INSERT INTO table (...)
     SELECT ... FROM cte
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

-- Re-run the full build
EXEC dbo.usp_RunBuild
    @MinJobsPerSegment  = 30,
    @TrainingStart      = NULL,
    @TrainingEnd        = NULL,
    @TestStart          = NULL,
    @TestEnd            = NULL;
GO
