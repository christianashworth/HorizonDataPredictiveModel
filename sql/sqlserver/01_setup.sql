/* ============================================================
   SETUP SCRIPT — PipelineAnalytics Database
   Horizon Data Predictive Model
   ============================================================
   Purpose  : Creates the PipezonAnalytics database and all
              required objects: dimension tables (with seed data),
              staging table, fact table, analytical output tables,
              logging table, indexes, and stored procedure shells.

   Usage    : Run once to initialise the environment.
              Script is idempotent — safe to re-run; existing
              objects and data are preserved.

   Sections :
     1. Database creation
     2. Dimension tables + seed data
     3. Staging table  (raw data ingestion)
     4. Fact table
     5. Analytical output tables
     6. Logging table
     7. Stored procedure shells  (logic added in Phase 3)
     8. Setup verification query

   Analytical approach overview:
     Historical opportunity/job data is segmented by status and
     up to 5 category dimensions. For each segment the mean of
     each outcome (win %, net fees, margin, timing days) is
     computed from a training window and applied to the current
     pipeline. If a segment contains fewer than the configured
     minimum number of jobs, categories are dropped in priority
     order (Cat5 → Cat4 → Cat3) until the threshold is met or
     all non-status categories are exhausted.

   Category priority (drop order — lowest priority first):
     Cat1  ServiceLine      Never dropped first
     Cat2  ClientType
     Cat3  Industry         Dropped third
     Cat4  NewVsExisting    Dropped second
     Cat5  LeadSource       Dropped first
   ============================================================ */


/* ============================================================
   SECTION 1 — DATABASE CREATION
   ============================================================ */

USE master;
GO

IF NOT EXISTS (
    SELECT name FROM sys.databases WHERE name = N'PipelineAnalytics'
)
BEGIN
    CREATE DATABASE PipelineAnalytics;
END
GO

USE PipelineAnalytics;
GO


/* ============================================================
   SECTION 2 — DIMENSION TABLES + SEED DATA
   ============================================================
   One table per category dimension plus dim_status.
   Each table includes an 'Unknown' member to serve as the
   default surrogate key when a raw record has no value for
   that category (NULL maps to Unknown rather than being
   excluded from the fact table).
   ============================================================ */

/* ── dim_service_line  (Category 1 — highest priority) ────── */
IF NOT EXISTS (
    SELECT * FROM sys.objects
    WHERE object_id = OBJECT_ID(N'dbo.dim_service_line') AND type = 'U'
)
BEGIN
    CREATE TABLE dbo.dim_service_line (
        ServiceLineKey   INT           IDENTITY(1,1) NOT NULL,
        ServiceLineName  VARCHAR(50)   NOT NULL,
        CONSTRAINT PK_dim_service_line      PRIMARY KEY (ServiceLineKey),
        CONSTRAINT UQ_dim_service_line_Name UNIQUE      (ServiceLineName)
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM dbo.dim_service_line)
BEGIN
    INSERT INTO dbo.dim_service_line (ServiceLineName) VALUES
        ('Audit'),
        ('Tax'),
        ('Advisory'),
        ('Unknown');   -- Default for missing Category 1 values
END
GO

/* ── dim_client_type  (Category 2) ──────────────────────────── */
IF NOT EXISTS (
    SELECT * FROM sys.objects
    WHERE object_id = OBJECT_ID(N'dbo.dim_client_type') AND type = 'U'
)
BEGIN
    CREATE TABLE dbo.dim_client_type (
        ClientTypeKey   INT           IDENTITY(1,1) NOT NULL,
        ClientTypeName  VARCHAR(50)   NOT NULL,
        CONSTRAINT PK_dim_client_type      PRIMARY KEY (ClientTypeKey),
        CONSTRAINT UQ_dim_client_type_Name UNIQUE      (ClientTypeName)
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM dbo.dim_client_type)
BEGIN
    INSERT INTO dbo.dim_client_type (ClientTypeName) VALUES
        ('Business'),
        ('Individual'),
        ('Unknown');   -- Default for missing Category 2 values
END
GO

/* ── dim_industry  (Category 3 — dropped third if needed) ───── */
IF NOT EXISTS (
    SELECT * FROM sys.objects
    WHERE object_id = OBJECT_ID(N'dbo.dim_industry') AND type = 'U'
)
BEGIN
    CREATE TABLE dbo.dim_industry (
        IndustryKey   INT           IDENTITY(1,1) NOT NULL,
        IndustryName  VARCHAR(100)  NOT NULL,
        CONSTRAINT PK_dim_industry      PRIMARY KEY (IndustryKey),
        CONSTRAINT UQ_dim_industry_Name UNIQUE      (IndustryName)
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM dbo.dim_industry)
BEGIN
    INSERT INTO dbo.dim_industry (IndustryName) VALUES
        ('Healthcare'),
        ('Manufacturing'),
        ('Technology'),
        ('Financial Services'),
        ('Nonprofit'),
        ('Real Estate'),
        ('Construction'),
        ('Other'),
        ('Unknown');   -- Default for missing Category 3 values
END
GO

/* ── dim_new_vs_existing  (Category 4 — dropped second if needed) */
IF NOT EXISTS (
    SELECT * FROM sys.objects
    WHERE object_id = OBJECT_ID(N'dbo.dim_new_vs_existing') AND type = 'U'
)
BEGIN
    CREATE TABLE dbo.dim_new_vs_existing (
        NewVsExistingKey   INT          IDENTITY(1,1) NOT NULL,
        NewVsExistingName  VARCHAR(50)  NOT NULL,
        CONSTRAINT PK_dim_new_vs_existing      PRIMARY KEY (NewVsExistingKey),
        CONSTRAINT UQ_dim_new_vs_existing_Name UNIQUE      (NewVsExistingName)
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM dbo.dim_new_vs_existing)
BEGIN
    INSERT INTO dbo.dim_new_vs_existing (NewVsExistingName) VALUES
        ('New'),
        ('Existing'),
        ('Unknown');   -- Default for missing Category 4 values
END
GO

/* ── dim_lead_source  (Category 5 — dropped first if needed) ── */
IF NOT EXISTS (
    SELECT * FROM sys.objects
    WHERE object_id = OBJECT_ID(N'dbo.dim_lead_source') AND type = 'U'
)
BEGIN
    CREATE TABLE dbo.dim_lead_source (
        LeadSourceKey   INT           IDENTITY(1,1) NOT NULL,
        LeadSourceName  VARCHAR(100)  NOT NULL,
        CONSTRAINT PK_dim_lead_source      PRIMARY KEY (LeadSourceKey),
        CONSTRAINT UQ_dim_lead_source_Name UNIQUE      (LeadSourceName)
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM dbo.dim_lead_source)
BEGIN
    INSERT INTO dbo.dim_lead_source (LeadSourceName) VALUES
        ('Referral'),
        ('Existing-Client Expansion'),
        ('Competitive RFP'),
        ('Outbound'),
        ('Unknown');   -- Default for missing Category 5 values
END
GO

/* ── dim_status  (derived from date fields; never dropped) ──── */
/*
   Status is not stored in the raw data. It is derived at load
   time from the combination of populated date fields:

     Open Opportunity  → SoldDate IS NULL AND ClosedLostDate IS NULL
     Lost              → ClosedLostDate IS NOT NULL
     Sold/Not Started  → SoldDate IS NOT NULL AND StartDate IS NULL
     Started           → StartDate IS NOT NULL
*/
IF NOT EXISTS (
    SELECT * FROM sys.objects
    WHERE object_id = OBJECT_ID(N'dbo.dim_status') AND type = 'U'
)
BEGIN
    CREATE TABLE dbo.dim_status (
        StatusKey          INT           IDENTITY(1,1) NOT NULL,
        StatusName         VARCHAR(50)   NOT NULL,
        StatusDescription  VARCHAR(255)  NOT NULL,
        CONSTRAINT PK_dim_status      PRIMARY KEY (StatusKey),
        CONSTRAINT UQ_dim_status_Name UNIQUE      (StatusName)
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM dbo.dim_status)
BEGIN
    INSERT INTO dbo.dim_status (StatusName, StatusDescription) VALUES
        ('Open Opportunity',
         'SoldDate and ClosedLostDate are both null — opportunity is active in the pipeline'),
        ('Lost',
         'ClosedLostDate is populated — opportunity was pursued but not won'),
        ('Sold/Not Started',
         'SoldDate is populated but StartDate is null — job is sold and awaiting kickoff'),
        ('Started',
         'StartDate is populated — work is underway; milestone dates populate as reached');
END
GO


/* ============================================================
   SECTION 3 — STAGING TABLE (Raw Data Ingestion)
   ============================================================
   Mirrors the column structure of the raw Excel source file
   (data/raw_data_sample.xlsx, sheet "Raw Data").
   Data is bulk-loaded here first, then transformed into
   fact_opportunities by usp_LoadRawData.
   This table is truncated and reloaded on every Build run.
   ============================================================ */

IF NOT EXISTS (
    SELECT * FROM sys.objects
    WHERE object_id = OBJECT_ID(N'dbo.stg_raw_data') AND type = 'U'
)
BEGIN
    CREATE TABLE dbo.stg_raw_data (
        OpportunityID       VARCHAR(20)    NOT NULL,
        ServiceLine         VARCHAR(50)    NULL,
        ClientType          VARCHAR(50)    NULL,
        Industry            VARCHAR(100)   NULL,
        NewVsExisting       VARCHAR(50)    NULL,
        LeadSource          VARCHAR(100)   NULL,
        CreatedDate         DATE           NULL,
        SoldDate            DATE           NULL,
        ClosedLostDate      DATE           NULL,
        StartDate           DATE           NULL,
        Pct50CompleteDate   DATE           NULL,
        Pct100CompleteDate  DATE           NULL,
        NetFees             DECIMAL(18,2)  NULL,
        MarginPct           DECIMAL(10,6)  NULL,
        LoadTimestamp       DATETIME       NOT NULL DEFAULT GETDATE(),
        CONSTRAINT PK_stg_raw_data PRIMARY KEY (OpportunityID)
    );
END
GO


/* ============================================================
   SECTION 4 — FACT TABLE
   ============================================================
   One row per opportunity/job. Populated by usp_LoadRawData
   from stg_raw_data. Category text values are resolved to
   dimension surrogate keys; derived columns (ResolutionDate,
   MarginDollars, DaysSell*, DaysStart*) are computed at load.
   ============================================================ */

IF NOT EXISTS (
    SELECT * FROM sys.objects
    WHERE object_id = OBJECT_ID(N'dbo.fact_opportunities') AND type = 'U'
)
BEGIN
    CREATE TABLE dbo.fact_opportunities (

        OpportunityID       VARCHAR(20)    NOT NULL,

        /* ── Category dimension foreign keys ─────────────────── */
        ServiceLineKey      INT            NOT NULL,   -- Cat1
        ClientTypeKey       INT            NOT NULL,   -- Cat2
        IndustryKey         INT            NOT NULL,   -- Cat3
        NewVsExistingKey    INT            NOT NULL,   -- Cat4
        LeadSourceKey       INT            NOT NULL,   -- Cat5
        StatusKey           INT            NOT NULL,   -- Derived from dates

        /* ── Raw lifecycle dates ─────────────────────────────── */
        CreatedDate         DATE           NULL,
        SoldDate            DATE           NULL,       -- Null if lost or open
        ClosedLostDate      DATE           NULL,       -- Null if won or open
        StartDate           DATE           NULL,       -- Null until work begins
        Pct50CompleteDate   DATE           NULL,       -- Null until 50% reached
        Pct100CompleteDate  DATE           NULL,       -- Null until 100% reached

        /* ── ResolutionDate ──────────────────────────────────── */
        -- Derived: COALESCE(SoldDate, ClosedLostDate).
        -- Single anchor date used to bucket records into the
        -- training window (7–24 months ago) or test window
        -- (1–6 months ago). Open opportunities have NULL here
        -- and are excluded from both windows.
        ResolutionDate      DATE           NULL,

        /* ── Financial outcomes ──────────────────────────────── */
        NetFees             DECIMAL(18,2)  NULL,       -- Populated once sold
        MarginPct           DECIMAL(10,6)  NULL,       -- Populated once 100% complete
        MarginDollars       DECIMAL(18,2)  NULL,       -- Derived: MarginPct * NetFees

        /* ── Derived timing metrics (stored for performance) ─── */
        DaysSellToStart     INT            NULL,       -- StartDate − SoldDate
        DaysStartTo50Pct    INT            NULL,       -- Pct50CompleteDate − StartDate
        DaysStartTo100Pct   INT            NULL,       -- Pct100CompleteDate − StartDate

        /* ── Audit ───────────────────────────────────────────── */
        LoadTimestamp       DATETIME       NOT NULL DEFAULT GETDATE(),

        CONSTRAINT PK_fact_opportunities     PRIMARY KEY (OpportunityID),
        CONSTRAINT FK_fact_ServiceLine       FOREIGN KEY (ServiceLineKey)
            REFERENCES dbo.dim_service_line   (ServiceLineKey),
        CONSTRAINT FK_fact_ClientType        FOREIGN KEY (ClientTypeKey)
            REFERENCES dbo.dim_client_type    (ClientTypeKey),
        CONSTRAINT FK_fact_Industry          FOREIGN KEY (IndustryKey)
            REFERENCES dbo.dim_industry       (IndustryKey),
        CONSTRAINT FK_fact_NewVsExisting     FOREIGN KEY (NewVsExistingKey)
            REFERENCES dbo.dim_new_vs_existing(NewVsExistingKey),
        CONSTRAINT FK_fact_LeadSource        FOREIGN KEY (LeadSourceKey)
            REFERENCES dbo.dim_lead_source    (LeadSourceKey),
        CONSTRAINT FK_fact_Status            FOREIGN KEY (StatusKey)
            REFERENCES dbo.dim_status         (StatusKey)
    );
END
GO

/* ── Indexes on fact_opportunities ───────────────────────────── */

-- ResolutionDate: primary filter for training/test window bucketing
IF NOT EXISTS (
    SELECT * FROM sys.indexes
    WHERE object_id = OBJECT_ID('dbo.fact_opportunities')
      AND name = 'IX_fact_opp_ResolutionDate'
)
    CREATE NONCLUSTERED INDEX IX_fact_opp_ResolutionDate
        ON dbo.fact_opportunities (ResolutionDate)
        INCLUDE (StatusKey, ServiceLineKey, ClientTypeKey,
                 IndustryKey, NewVsExistingKey, LeadSourceKey);
GO

-- StatusKey: frequently filtered in segmentation queries
IF NOT EXISTS (
    SELECT * FROM sys.indexes
    WHERE object_id = OBJECT_ID('dbo.fact_opportunities')
      AND name = 'IX_fact_opp_StatusKey'
)
    CREATE NONCLUSTERED INDEX IX_fact_opp_StatusKey
        ON dbo.fact_opportunities (StatusKey)
        INCLUDE (ServiceLineKey, ClientTypeKey, IndustryKey,
                 NewVsExistingKey, LeadSourceKey,
                 NetFees, MarginPct, MarginDollars,
                 DaysSellToStart, DaysStartTo50Pct, DaysStartTo100Pct);
GO

-- SoldDate: used in pipeline date arithmetic
IF NOT EXISTS (
    SELECT * FROM sys.indexes
    WHERE object_id = OBJECT_ID('dbo.fact_opportunities')
      AND name = 'IX_fact_opp_SoldDate'
)
    CREATE NONCLUSTERED INDEX IX_fact_opp_SoldDate
        ON dbo.fact_opportunities (SoldDate)
        INCLUDE (StatusKey, NetFees, MarginPct, MarginDollars);
GO


/* ============================================================
   SECTION 5 — ANALYTICAL OUTPUT TABLES
   ============================================================ */

/* ── analytical_segments ─────────────────────────────────────
   One row per segment-outcome combination, produced by
   usp_BuildSegments from the training dataset.

   A "segment" is the intersection of Status and whichever
   category dimensions were not dropped for this outcome.
   When a category is dropped (NULL key), that dimension is
   ignored in the matching logic — e.g. a row with
   IndustryKey = NULL means "all industries" for this segment.

   Cat3Dropped / Cat4Dropped / Cat5Dropped flags record which
   categories were dropped to satisfy the minimum segment size.
   ─────────────────────────────────────────────────────────── */
IF NOT EXISTS (
    SELECT * FROM sys.objects
    WHERE object_id = OBJECT_ID(N'dbo.analytical_segments') AND type = 'U'
)
BEGIN
    CREATE TABLE dbo.analytical_segments (
        SegmentKey          INT           IDENTITY(1,1) NOT NULL,

        /* Category keys — NULL means dimension was dropped */
        ServiceLineKey      INT           NULL,
        ClientTypeKey       INT           NULL,
        IndustryKey         INT           NULL,
        NewVsExistingKey    INT           NULL,
        LeadSourceKey       INT           NULL,
        StatusKey           INT           NOT NULL,   -- Never NULL

        /* Outcome being estimated */
        OutcomeName         VARCHAR(50)   NOT NULL,
        /*
          Valid values:
            WinPct            — Win probability (status = Open Opportunity only)
            NetFees           — Estimated net fees
            MarginPct         — Estimated margin percentage
            DaysSellToStart   — Days from job sale to start (status = Sold/Not Started only)
            DaysStartTo50Pct  — Days from start to 50% complete
            DaysStartTo100Pct — Days from start to 100% complete
        */
        OutcomeEstimate     DECIMAL(18,6) NULL,
        ObservationCount    INT           NOT NULL,

        /* Category-drop flags */
        Cat3Dropped         BIT           NOT NULL DEFAULT 0,   -- 1 = Industry dropped
        Cat4Dropped         BIT           NOT NULL DEFAULT 0,   -- 1 = NewVsExisting dropped
        Cat5Dropped         BIT           NOT NULL DEFAULT 0,   -- 1 = LeadSource dropped

        /* Audit */
        BuildRunKey         INT           NOT NULL,

        CONSTRAINT PK_analytical_segments    PRIMARY KEY (SegmentKey),
        CONSTRAINT FK_seg_ServiceLine        FOREIGN KEY (ServiceLineKey)
            REFERENCES dbo.dim_service_line   (ServiceLineKey),
        CONSTRAINT FK_seg_ClientType         FOREIGN KEY (ClientTypeKey)
            REFERENCES dbo.dim_client_type    (ClientTypeKey),
        CONSTRAINT FK_seg_Industry           FOREIGN KEY (IndustryKey)
            REFERENCES dbo.dim_industry       (IndustryKey),
        CONSTRAINT FK_seg_NewVsExisting      FOREIGN KEY (NewVsExistingKey)
            REFERENCES dbo.dim_new_vs_existing(NewVsExistingKey),
        CONSTRAINT FK_seg_LeadSource         FOREIGN KEY (LeadSourceKey)
            REFERENCES dbo.dim_lead_source    (LeadSourceKey),
        CONSTRAINT FK_seg_Status             FOREIGN KEY (StatusKey)
            REFERENCES dbo.dim_status         (StatusKey)
    );
END
GO

-- Composite index to support segment-matching lookups in usp_ApplyModel
IF NOT EXISTS (
    SELECT * FROM sys.indexes
    WHERE object_id = OBJECT_ID('dbo.analytical_segments')
      AND name = 'IX_seg_lookup'
)
    CREATE NONCLUSTERED INDEX IX_seg_lookup
        ON dbo.analytical_segments
            (StatusKey, ServiceLineKey, ClientTypeKey,
             IndustryKey, NewVsExistingKey, LeadSourceKey, OutcomeName)
        INCLUDE (OutcomeEstimate, ObservationCount,
                 Cat3Dropped, Cat4Dropped, Cat5Dropped);
GO

/* ── analytical_job_results ──────────────────────────────────
   Model estimates applied at the individual opportunity/job
   level, produced by usp_ApplyModel.

   Timing outcomes are stored as estimated dates rather than
   days, computed as:
     EstimatedStartDate  = SoldDate  + segment mean DaysSellToStart
     EstimatedPct50Date  = StartDate + segment mean DaysStartTo50Pct
     EstimatedPct100Date = StartDate + segment mean DaysStartTo100Pct

   EstimatedSellDate is only populated for open opportunities
   and is computed separately (not yet defined in Phase 2 —
   approach to be confirmed in Phase 3).
   ─────────────────────────────────────────────────────────── */
IF NOT EXISTS (
    SELECT * FROM sys.objects
    WHERE object_id = OBJECT_ID(N'dbo.analytical_job_results') AND type = 'U'
)
BEGIN
    CREATE TABLE dbo.analytical_job_results (
        OpportunityID               VARCHAR(20)    NOT NULL,
        SegmentKey                  INT            NULL,

        /* Estimated outcomes */
        EstimatedWinPct             DECIMAL(10,6)  NULL,   -- Opportunities only
        EstimatedNetFees            DECIMAL(18,2)  NULL,
        EstimatedMarginPct          DECIMAL(10,6)  NULL,
        EstimatedMarginDollars      DECIMAL(18,2)  NULL,   -- EstimatedMarginPct * EstimatedNetFees

        /* Estimated milestone dates */
        EstimatedSellDate           DATE           NULL,   -- Open opportunities only
        EstimatedStartDate          DATE           NULL,   -- SoldDate + DaysSellToStart estimate
        EstimatedPct50Date          DATE           NULL,   -- StartDate + DaysStartTo50Pct estimate
        EstimatedPct100Date         DATE           NULL,   -- StartDate + DaysStartTo100Pct estimate

        /* Audit */
        BuildRunKey                 INT            NOT NULL,

        CONSTRAINT PK_analytical_job_results  PRIMARY KEY (OpportunityID),
        CONSTRAINT FK_jobres_Opportunity      FOREIGN KEY (OpportunityID)
            REFERENCES dbo.fact_opportunities (OpportunityID),
        CONSTRAINT FK_jobres_Segment          FOREIGN KEY (SegmentKey)
            REFERENCES dbo.analytical_segments(SegmentKey)
    );
END
GO

/* ── analytical_pipeline_results ─────────────────────────────
   Monthly aggregations of job-level estimates, produced by
   usp_BuildPipelineAggregations.

   One row per calendar month (PeriodMonth = first day of month).
   Jobs are bucketed by EstimatedStartDate month.
   ─────────────────────────────────────────────────────────── */
IF NOT EXISTS (
    SELECT * FROM sys.objects
    WHERE object_id = OBJECT_ID(N'dbo.analytical_pipeline_results') AND type = 'U'
)
BEGIN
    CREATE TABLE dbo.analytical_pipeline_results (
        PipelineResultKey       INT           IDENTITY(1,1) NOT NULL,
        PeriodMonth             DATE          NOT NULL,   -- First day of calendar month
        EstimatedJobCount       INT           NOT NULL,
        EstimatedNetFees        DECIMAL(18,2) NULL,
        EstimatedMarginDollars  DECIMAL(18,2) NULL,
        MedianPct50Date         DATE          NULL,       -- Median across jobs in period
        MedianPct100Date        DATE          NULL,       -- Median across jobs in period

        /* Audit */
        BuildRunKey             INT           NOT NULL,

        CONSTRAINT PK_analytical_pipeline_results PRIMARY KEY (PipelineResultKey)
    );
END
GO


/* ============================================================
   SECTION 6 — LOGGING TABLE
   ============================================================
   Records every execution of the Build script (via usp_RunBuild).
   Captures all configurable parameters, row counts, and final
   status so that every model run is fully auditable.
   ============================================================ */

IF NOT EXISTS (
    SELECT * FROM sys.objects
    WHERE object_id = OBJECT_ID(N'dbo.log_build_runs') AND type = 'U'
)
BEGIN
    CREATE TABLE dbo.log_build_runs (
        BuildRunKey         INT           IDENTITY(1,1) NOT NULL,
        RunTimestamp        DATETIME      NOT NULL DEFAULT GETDATE(),

        /* Configurable parameters captured at runtime */
        MinJobsPerSegment   INT           NOT NULL,
        TrainingStart       DATE          NOT NULL,
        TrainingEnd         DATE          NOT NULL,
        TestStart           DATE          NOT NULL,
        TestEnd             DATE          NOT NULL,

        /* Row counts */
        RowsProcessed       INT           NULL,
        SegmentsBuilt       INT           NULL,
        JobResultsWritten   INT           NULL,

        /* Run outcome */
        Status              VARCHAR(20)   NOT NULL DEFAULT 'Running',
        /*
          Running  — build is in progress
          Success  — completed without errors
          Warning  — completed with non-fatal issues (e.g. some segments below minimum)
          Error    — failed with an unhandled exception
        */
        StatusMessage       VARCHAR(500)  NULL,

        CONSTRAINT PK_log_build_runs PRIMARY KEY (BuildRunKey)
    );
END
GO


/* ============================================================
   SECTION 7 — STORED PROCEDURE SHELLS
   ============================================================
   Empty shells created here so the full object graph exists
   after Setup. Business logic is implemented in Phase 3
   (Build script / 02_build.sql).

   Procedures (in execution order):
     usp_LoadRawData            — stg_raw_data → fact_opportunities
     usp_BuildSegments          — training data → analytical_segments
     usp_ApplyModel             — segments → analytical_job_results
     usp_BuildPipelineAggregations — job results → analytical_pipeline_results
     usp_RunBuild               — master orchestrator (called by Build script)
   ============================================================ */

IF OBJECT_ID('dbo.usp_LoadRawData', 'P') IS NULL
    EXEC('CREATE PROCEDURE dbo.usp_LoadRawData AS BEGIN RETURN 0 END');
GO

IF OBJECT_ID('dbo.usp_BuildSegments', 'P') IS NULL
    EXEC('CREATE PROCEDURE dbo.usp_BuildSegments AS BEGIN RETURN 0 END');
GO

IF OBJECT_ID('dbo.usp_ApplyModel', 'P') IS NULL
    EXEC('CREATE PROCEDURE dbo.usp_ApplyModel AS BEGIN RETURN 0 END');
GO

IF OBJECT_ID('dbo.usp_BuildPipelineAggregations', 'P') IS NULL
    EXEC('CREATE PROCEDURE dbo.usp_BuildPipelineAggregations AS BEGIN RETURN 0 END');
GO

IF OBJECT_ID('dbo.usp_RunBuild', 'P') IS NULL
    EXEC('CREATE PROCEDURE dbo.usp_RunBuild AS BEGIN RETURN 0 END');
GO


/* ============================================================
   SECTION 8 — SETUP VERIFICATION
   ============================================================
   Returns a summary of all objects created.
   Expected result: 12 Tables | 5 Stored Procedures | 4 Indexes
   ============================================================ */

SELECT 'Tables'             AS ObjectType, COUNT(*) AS ObjectCount
FROM   sys.tables
WHERE  schema_id = SCHEMA_ID('dbo')
  AND  name IN (
         'dim_service_line','dim_client_type','dim_industry',
         'dim_new_vs_existing','dim_lead_source','dim_status',
         'stg_raw_data','fact_opportunities',
         'analytical_segments','analytical_job_results',
         'analytical_pipeline_results','log_build_runs'
       )
UNION ALL
SELECT 'Stored Procedures', COUNT(*)
FROM   sys.procedures
WHERE  schema_id = SCHEMA_ID('dbo')
  AND  name IN (
         'usp_LoadRawData','usp_BuildSegments',
         'usp_ApplyModel','usp_BuildPipelineAggregations','usp_RunBuild'
       )
UNION ALL
SELECT 'Indexes',           COUNT(*)
FROM   sys.indexes     i
JOIN   sys.tables      t ON i.object_id = t.object_id
WHERE  t.schema_id = SCHEMA_ID('dbo')
  AND  i.name IN (
         'IX_fact_opp_ResolutionDate',
         'IX_fact_opp_StatusKey',
         'IX_fact_opp_SoldDate',
         'IX_seg_lookup'
       );
GO
