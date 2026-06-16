/* ============================================================
   SETUP SCRIPT — PipelineAnalytics (Databricks SQL)
   Horizon Data Predictive Model
   ============================================================
   Purpose  : Creates the pipeline_analytics schema and all
              required objects within the configured Unity
              Catalog: dimension tables (with seed data),
              staging table, fact table, analytical output
              tables, logging table, and stored procedure shells.

   Usage    : Run once to initialise the environment.
              Script is idempotent — safe to re-run; existing
              objects and data are preserved.

   Unity Catalog structure used:
              <CATALOG>.pipeline_analytics.<table>

   Configuration:
              Set the CATALOG variable below to match your
              Databricks Unity Catalog name before running.
              Default: main

   Databricks vs SQL Server differences:
              - No GO statements; statements separated by
                semicolons and run sequentially
              - Schema replaces database as the container
              - STRING replaces VARCHAR
              - BOOLEAN replaces BIT
              - TIMESTAMP replaces DATETIME
              - GENERATED ALWAYS AS IDENTITY replaces IDENTITY(1,1)
              - PK/FK constraints are declarative (informational
                only — not enforced by Delta Lake)
              - ZORDER BY replaces NONCLUSTERED INDEX
              - Stored procedures use Databricks SQL syntax
              - CURRENT_TIMESTAMP() replaces GETDATE()

   Sections :
     1. Schema creation
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
   CONFIGURATION
   ============================================================
   Update CATALOG to match your Unity Catalog name.
   All objects are created under <CATALOG>.pipeline_analytics
   ============================================================ */

-- SET CATALOG main;   -- Uncomment and replace 'main' with your catalog name


/* ============================================================
   SECTION 1 — SCHEMA CREATION
   ============================================================
   In Databricks Unity Catalog, a schema is the equivalent of
   a SQL Server database for object organisation purposes.
   ============================================================ */

CREATE SCHEMA IF NOT EXISTS pipeline_analytics
COMMENT 'Horizon Data Predictive Model — pipeline analytics and predictive estimation';


/* ============================================================
   SECTION 2 — DIMENSION TABLES + SEED DATA
   ============================================================
   One table per category dimension plus dim_status.
   Each table includes an Unknown member to serve as the
   default surrogate key when a raw record has no value for
   that category (NULL maps to Unknown rather than being
   excluded from the fact table).

   Note: PK/FK constraints in Delta Lake are informational
   only. They document the intended relationships and are
   surfaced in the Unity Catalog lineage graph, but are not
   enforced at write time.
   ============================================================ */

/* ── dim_service_line  (Category 1 — highest priority) ────── */
CREATE TABLE IF NOT EXISTS pipeline_analytics.dim_service_line (
    ServiceLineKey   BIGINT   GENERATED ALWAYS AS IDENTITY,
    ServiceLineName  STRING   NOT NULL,
    CONSTRAINT pk_dim_service_line PRIMARY KEY (ServiceLineKey)
)
USING DELTA
COMMENT 'Category 1 dimension — service line. Highest priority; dropped last if segment falls below minimum size.';

-- Seed: insert only if table is empty
INSERT INTO pipeline_analytics.dim_service_line (ServiceLineName)
SELECT vals.ServiceLineName
FROM (
    VALUES
        ('Audit'),
        ('Tax'),
        ('Advisory'),
        ('Unknown')
) AS vals(ServiceLineName)
WHERE NOT EXISTS (SELECT 1 FROM pipeline_analytics.dim_service_line LIMIT 1);

/* ── dim_client_type  (Category 2) ──────────────────────────── */
CREATE TABLE IF NOT EXISTS pipeline_analytics.dim_client_type (
    ClientTypeKey   BIGINT  GENERATED ALWAYS AS IDENTITY,
    ClientTypeName  STRING  NOT NULL,
    CONSTRAINT pk_dim_client_type PRIMARY KEY (ClientTypeKey)
)
USING DELTA
COMMENT 'Category 2 dimension — client type (Business / Individual).';

INSERT INTO pipeline_analytics.dim_client_type (ClientTypeName)
SELECT vals.ClientTypeName
FROM (
    VALUES
        ('Business'),
        ('Individual'),
        ('Unknown')
) AS vals(ClientTypeName)
WHERE NOT EXISTS (SELECT 1 FROM pipeline_analytics.dim_client_type LIMIT 1);

/* ── dim_industry  (Category 3 — dropped third if needed) ───── */
CREATE TABLE IF NOT EXISTS pipeline_analytics.dim_industry (
    IndustryKey   BIGINT  GENERATED ALWAYS AS IDENTITY,
    IndustryName  STRING  NOT NULL,
    CONSTRAINT pk_dim_industry PRIMARY KEY (IndustryKey)
)
USING DELTA
COMMENT 'Category 3 dimension — client industry/sector. Dropped third when segment falls below minimum size.';

INSERT INTO pipeline_analytics.dim_industry (IndustryName)
SELECT vals.IndustryName
FROM (
    VALUES
        ('Healthcare'),
        ('Manufacturing'),
        ('Technology'),
        ('Financial Services'),
        ('Nonprofit'),
        ('Real Estate'),
        ('Construction'),
        ('Other'),
        ('Unknown')
) AS vals(IndustryName)
WHERE NOT EXISTS (SELECT 1 FROM pipeline_analytics.dim_industry LIMIT 1);

/* ── dim_new_vs_existing  (Category 4 — dropped second if needed) */
CREATE TABLE IF NOT EXISTS pipeline_analytics.dim_new_vs_existing (
    NewVsExistingKey   BIGINT  GENERATED ALWAYS AS IDENTITY,
    NewVsExistingName  STRING  NOT NULL,
    CONSTRAINT pk_dim_new_vs_existing PRIMARY KEY (NewVsExistingKey)
)
USING DELTA
COMMENT 'Category 4 dimension — new vs existing client relationship. Dropped second when segment falls below minimum size.';

INSERT INTO pipeline_analytics.dim_new_vs_existing (NewVsExistingName)
SELECT vals.NewVsExistingName
FROM (
    VALUES
        ('New'),
        ('Existing'),
        ('Unknown')
) AS vals(NewVsExistingName)
WHERE NOT EXISTS (SELECT 1 FROM pipeline_analytics.dim_new_vs_existing LIMIT 1);

/* ── dim_lead_source  (Category 5 — dropped first if needed) ── */
CREATE TABLE IF NOT EXISTS pipeline_analytics.dim_lead_source (
    LeadSourceKey   BIGINT  GENERATED ALWAYS AS IDENTITY,
    LeadSourceName  STRING  NOT NULL,
    CONSTRAINT pk_dim_lead_source PRIMARY KEY (LeadSourceKey)
)
USING DELTA
COMMENT 'Category 5 dimension — lead origination channel. Lowest priority; dropped first when segment falls below minimum size.';

INSERT INTO pipeline_analytics.dim_lead_source (LeadSourceName)
SELECT vals.LeadSourceName
FROM (
    VALUES
        ('Referral'),
        ('Existing-Client Expansion'),
        ('Competitive RFP'),
        ('Outbound'),
        ('Unknown')
) AS vals(LeadSourceName)
WHERE NOT EXISTS (SELECT 1 FROM pipeline_analytics.dim_lead_source LIMIT 1);

/* ── dim_status  (derived from date fields; never dropped) ──── */
/*
   Status is not stored in the raw data. It is derived at load
   time from the combination of populated date fields:

     Open Opportunity  → SoldDate IS NULL AND ClosedLostDate IS NULL
     Lost              → ClosedLostDate IS NOT NULL
     Sold/Not Started  → SoldDate IS NOT NULL AND StartDate IS NULL
     Started           → StartDate IS NOT NULL
*/
CREATE TABLE IF NOT EXISTS pipeline_analytics.dim_status (
    StatusKey          BIGINT  GENERATED ALWAYS AS IDENTITY,
    StatusName         STRING  NOT NULL,
    StatusDescription  STRING  NOT NULL,
    CONSTRAINT pk_dim_status PRIMARY KEY (StatusKey)
)
USING DELTA
COMMENT 'Status dimension — derived from lifecycle date fields at load time. Never dropped in segment matching.';

INSERT INTO pipeline_analytics.dim_status (StatusName, StatusDescription)
SELECT vals.StatusName, vals.StatusDescription
FROM (
    VALUES
        ('Open Opportunity',
         'SoldDate and ClosedLostDate are both null — opportunity is active in the pipeline'),
        ('Lost',
         'ClosedLostDate is populated — opportunity was pursued but not won'),
        ('Sold/Not Started',
         'SoldDate is populated but StartDate is null — job is sold and awaiting kickoff'),
        ('Started',
         'StartDate is populated — work is underway; milestone dates populate as reached')
) AS vals(StatusName, StatusDescription)
WHERE NOT EXISTS (SELECT 1 FROM pipeline_analytics.dim_status LIMIT 1);


/* ============================================================
   SECTION 3 — STAGING TABLE (Raw Data Ingestion)
   ============================================================
   Mirrors the column structure of the raw Excel source file
   (data/raw_data_sample.xlsx, sheet Raw Data).
   Data is loaded here first, then transformed into
   fact_opportunities by usp_LoadRawData.
   This table is truncated and reloaded on every Build run.
   ============================================================ */

CREATE TABLE IF NOT EXISTS pipeline_analytics.stg_raw_data (
    OpportunityID       STRING,
    ServiceLine         STRING,
    ClientType          STRING,
    Industry            STRING,
    NewVsExisting       STRING,
    LeadSource          STRING,
    CreatedDate         DATE,
    SoldDate            DATE,
    ClosedLostDate      DATE,
    StartDate           DATE,
    Pct50CompleteDate   DATE,
    Pct100CompleteDate  DATE,
    NetFees             DECIMAL(18,2),
    MarginPct           DECIMAL(10,6),
    LoadTimestamp       TIMESTAMP  DEFAULT CURRENT_TIMESTAMP()
)
USING DELTA
COMMENT 'Staging table — mirrors raw Excel source schema. Truncated and reloaded on each Build run.';


/* ============================================================
   SECTION 4 — FACT TABLE
   ============================================================
   One row per opportunity/job. Populated by usp_LoadRawData
   from stg_raw_data. Category text values are resolved to
   dimension surrogate keys; derived columns (ResolutionDate,
   MarginDollars, DaysSell*, DaysStart*) are computed at load.

   ZORDER BY is applied via OPTIMIZE in the Build script
   (not at table creation time) on the most common filter
   columns: ResolutionDate and StatusKey.
   ============================================================ */

CREATE TABLE IF NOT EXISTS pipeline_analytics.fact_opportunities (

    OpportunityID       STRING         NOT NULL,

    /* ── Category dimension foreign keys ─────────────────── */
    ServiceLineKey      BIGINT         NOT NULL,   -- Cat1
    ClientTypeKey       BIGINT         NOT NULL,   -- Cat2
    IndustryKey         BIGINT         NOT NULL,   -- Cat3
    NewVsExistingKey    BIGINT         NOT NULL,   -- Cat4
    LeadSourceKey       BIGINT         NOT NULL,   -- Cat5
    StatusKey           BIGINT         NOT NULL,   -- Derived from dates

    /* ── Raw lifecycle dates ─────────────────────────────── */
    CreatedDate         DATE,
    SoldDate            DATE,          -- Null if lost or open
    ClosedLostDate      DATE,          -- Null if won or open
    StartDate           DATE,          -- Null until work begins
    Pct50CompleteDate   DATE,          -- Null until 50% reached
    Pct100CompleteDate  DATE,          -- Null until 100% reached

    /* ── ResolutionDate ──────────────────────────────────── */
    -- Derived: COALESCE(SoldDate, ClosedLostDate).
    -- Single anchor date used to bucket records into the
    -- training window (7–24 months ago) or test window
    -- (1–6 months ago). Open opportunities have NULL here
    -- and are excluded from both windows.
    ResolutionDate      DATE,

    /* ── Financial outcomes ──────────────────────────────── */
    NetFees             DECIMAL(18,2), -- Populated once sold
    MarginPct           DECIMAL(10,6), -- Populated once 100% complete
    MarginDollars       DECIMAL(18,2), -- Derived: MarginPct * NetFees

    /* ── Derived timing metrics (stored for performance) ─── */
    DaysSellToStart     INT,           -- StartDate − SoldDate
    DaysStartTo50Pct    INT,           -- Pct50CompleteDate − StartDate
    DaysStartTo100Pct   INT,           -- Pct100CompleteDate − StartDate

    /* ── Audit ───────────────────────────────────────────── */
    LoadTimestamp       TIMESTAMP      DEFAULT CURRENT_TIMESTAMP(),

    /* Informational constraints (not enforced by Delta Lake) */
    CONSTRAINT pk_fact_opportunities  PRIMARY KEY (OpportunityID),
    CONSTRAINT fk_fact_service_line   FOREIGN KEY (ServiceLineKey)
        REFERENCES pipeline_analytics.dim_service_line   (ServiceLineKey),
    CONSTRAINT fk_fact_client_type    FOREIGN KEY (ClientTypeKey)
        REFERENCES pipeline_analytics.dim_client_type    (ClientTypeKey),
    CONSTRAINT fk_fact_industry       FOREIGN KEY (IndustryKey)
        REFERENCES pipeline_analytics.dim_industry       (IndustryKey),
    CONSTRAINT fk_fact_new_vs_existing FOREIGN KEY (NewVsExistingKey)
        REFERENCES pipeline_analytics.dim_new_vs_existing(NewVsExistingKey),
    CONSTRAINT fk_fact_lead_source    FOREIGN KEY (LeadSourceKey)
        REFERENCES pipeline_analytics.dim_lead_source    (LeadSourceKey),
    CONSTRAINT fk_fact_status         FOREIGN KEY (StatusKey)
        REFERENCES pipeline_analytics.dim_status         (StatusKey)
)
USING DELTA
COMMENT 'Fact table — one row per opportunity/job. Core table for all segmentation and estimation queries.'
TBLPROPERTIES (
    'delta.autoOptimize.optimizeWrite' = 'true',
    'delta.autoOptimize.autoCompact'   = 'true'
);

/*
   Optimize fact table for the most common query patterns.
   Run after initial data load in the Build script.

   OPTIMIZE pipeline_analytics.fact_opportunities
       ZORDER BY (ResolutionDate, StatusKey);
*/


/* ============================================================
   SECTION 5 — ANALYTICAL OUTPUT TABLES
   ============================================================ */

/* ── analytical_segments ─────────────────────────────────────
   One row per segment-outcome combination, produced by
   usp_BuildSegments from the training dataset.

   A segment is the intersection of Status and whichever
   category dimensions were not dropped for this outcome.
   When a category key is NULL, that dimension is ignored in
   the matching logic — e.g. IndustryKey IS NULL means all
   industries are included in this segment.

   Cat3Dropped / Cat4Dropped / Cat5Dropped flags record which
   categories were dropped to satisfy the minimum segment size.
   ─────────────────────────────────────────────────────────── */
CREATE TABLE IF NOT EXISTS pipeline_analytics.analytical_segments (
    SegmentKey          BIGINT   GENERATED ALWAYS AS IDENTITY,

    /* Category keys — NULL means dimension was dropped */
    ServiceLineKey      BIGINT,
    ClientTypeKey       BIGINT,
    IndustryKey         BIGINT,
    NewVsExistingKey    BIGINT,
    LeadSourceKey       BIGINT,
    StatusKey           BIGINT   NOT NULL,   -- Never NULL

    /* Outcome being estimated */
    OutcomeName         STRING   NOT NULL,
    /*
      Valid values:
        WinPct            — Win probability (Open Opportunity only)
        NetFees           — Estimated net fees
        MarginPct         — Estimated margin percentage
        DaysSellToStart   — Days from job sale to start (Sold/Not Started only)
        DaysStartTo50Pct  — Days from start to 50% complete
        DaysStartTo100Pct — Days from start to 100% complete
    */
    OutcomeEstimate     DECIMAL(18,6),
    ObservationCount    INT      NOT NULL,

    /* Category-drop flags */
    Cat3Dropped         BOOLEAN  NOT NULL DEFAULT false,  -- true = Industry dropped
    Cat4Dropped         BOOLEAN  NOT NULL DEFAULT false,  -- true = NewVsExisting dropped
    Cat5Dropped         BOOLEAN  NOT NULL DEFAULT false,  -- true = LeadSource dropped

    /* Audit */
    BuildRunKey         BIGINT   NOT NULL,

    CONSTRAINT pk_analytical_segments   PRIMARY KEY (SegmentKey),
    CONSTRAINT fk_seg_service_line      FOREIGN KEY (ServiceLineKey)
        REFERENCES pipeline_analytics.dim_service_line   (ServiceLineKey),
    CONSTRAINT fk_seg_client_type       FOREIGN KEY (ClientTypeKey)
        REFERENCES pipeline_analytics.dim_client_type    (ClientTypeKey),
    CONSTRAINT fk_seg_industry          FOREIGN KEY (IndustryKey)
        REFERENCES pipeline_analytics.dim_industry       (IndustryKey),
    CONSTRAINT fk_seg_new_vs_existing   FOREIGN KEY (NewVsExistingKey)
        REFERENCES pipeline_analytics.dim_new_vs_existing(NewVsExistingKey),
    CONSTRAINT fk_seg_lead_source       FOREIGN KEY (LeadSourceKey)
        REFERENCES pipeline_analytics.dim_lead_source    (LeadSourceKey),
    CONSTRAINT fk_seg_status            FOREIGN KEY (StatusKey)
        REFERENCES pipeline_analytics.dim_status         (StatusKey)
)
USING DELTA
COMMENT 'Analytical output — segment-level outcome estimates from training data. One row per segment-outcome combination.'
TBLPROPERTIES (
    'delta.autoOptimize.optimizeWrite' = 'true',
    'delta.autoOptimize.autoCompact'   = 'true'
);

/*
   Optimize for segment-matching lookups in usp_ApplyModel.

   OPTIMIZE pipeline_analytics.analytical_segments
       ZORDER BY (StatusKey, ServiceLineKey, ClientTypeKey,
                  IndustryKey, NewVsExistingKey, LeadSourceKey, OutcomeName);
*/

/* ── analytical_job_results ──────────────────────────────────
   Model estimates applied at the individual opportunity/job
   level, produced by usp_ApplyModel.

   Timing outcomes are stored as estimated dates rather than
   days, computed as:
     EstimatedStartDate  = SoldDate  + segment mean DaysSellToStart
     EstimatedPct50Date  = StartDate + segment mean DaysStartTo50Pct
     EstimatedPct100Date = StartDate + segment mean DaysStartTo100Pct
   ─────────────────────────────────────────────────────────── */
CREATE TABLE IF NOT EXISTS pipeline_analytics.analytical_job_results (
    OpportunityID               STRING         NOT NULL,
    SegmentKey                  BIGINT,

    /* Estimated outcomes */
    EstimatedWinPct             DECIMAL(10,6),  -- Opportunities only
    EstimatedNetFees            DECIMAL(18,2),
    EstimatedMarginPct          DECIMAL(10,6),
    EstimatedMarginDollars      DECIMAL(18,2),  -- EstimatedMarginPct * EstimatedNetFees

    /* Estimated milestone dates */
    EstimatedSellDate           DATE,           -- Open opportunities only
    EstimatedStartDate          DATE,           -- SoldDate + DaysSellToStart estimate
    EstimatedPct50Date          DATE,           -- StartDate + DaysStartTo50Pct estimate
    EstimatedPct100Date         DATE,           -- StartDate + DaysStartTo100Pct estimate

    /* Audit */
    BuildRunKey                 BIGINT         NOT NULL,

    CONSTRAINT pk_analytical_job_results  PRIMARY KEY (OpportunityID),
    CONSTRAINT fk_jobres_opportunity      FOREIGN KEY (OpportunityID)
        REFERENCES pipeline_analytics.fact_opportunities (OpportunityID),
    CONSTRAINT fk_jobres_segment          FOREIGN KEY (SegmentKey)
        REFERENCES pipeline_analytics.analytical_segments(SegmentKey)
)
USING DELTA
COMMENT 'Analytical output — model estimates at the individual opportunity/job level, including estimated milestone dates.';

/* ── analytical_pipeline_results ─────────────────────────────
   Monthly aggregations of job-level estimates, produced by
   usp_BuildPipelineAggregations. One row per calendar month.
   Jobs are bucketed by EstimatedStartDate month.
   ─────────────────────────────────────────────────────────── */
CREATE TABLE IF NOT EXISTS pipeline_analytics.analytical_pipeline_results (
    PipelineResultKey       BIGINT   GENERATED ALWAYS AS IDENTITY,
    PeriodMonth             DATE     NOT NULL,   -- First day of calendar month
    EstimatedJobCount       INT      NOT NULL,
    EstimatedNetFees        DECIMAL(18,2),
    EstimatedMarginDollars  DECIMAL(18,2),
    MedianPct50Date         DATE,               -- Median across jobs in period
    MedianPct100Date        DATE,               -- Median across jobs in period

    /* Audit */
    BuildRunKey             BIGINT   NOT NULL,

    CONSTRAINT pk_analytical_pipeline_results PRIMARY KEY (PipelineResultKey)
)
USING DELTA
COMMENT 'Analytical output — monthly pipeline aggregations of job-level estimates.';


/* ============================================================
   SECTION 6 — LOGGING TABLE
   ============================================================
   Records every execution of the Build script (via
   usp_RunBuild). Captures all configurable parameters, row
   counts, and final status so that every model run is fully
   auditable.
   ============================================================ */

CREATE TABLE IF NOT EXISTS pipeline_analytics.log_build_runs (
    BuildRunKey         BIGINT    GENERATED ALWAYS AS IDENTITY,
    RunTimestamp        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP(),

    /* Configurable parameters captured at runtime */
    MinJobsPerSegment   INT       NOT NULL,
    TrainingStart       DATE      NOT NULL,
    TrainingEnd         DATE      NOT NULL,
    TestStart           DATE      NOT NULL,
    TestEnd             DATE      NOT NULL,

    /* Row counts */
    RowsProcessed       INT,
    SegmentsBuilt       INT,
    JobResultsWritten   INT,

    /* Run outcome */
    Status              STRING    NOT NULL DEFAULT 'Running',
    /*
      Running  — build is in progress
      Success  — completed without errors
      Warning  — completed with non-fatal issues
      Error    — failed with an unhandled exception
    */
    StatusMessage       STRING,

    CONSTRAINT pk_log_build_runs PRIMARY KEY (BuildRunKey)
)
USING DELTA
COMMENT 'Audit log — records every Build script execution with parameters and row counts.';


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

   Note: Databricks SQL stored procedures use BEGIN/END blocks
   and support full SQL DML. Parameters use the syntax
   (param_name TYPE) rather than SQL Server's @param_name TYPE.
   ============================================================ */

CREATE OR REPLACE PROCEDURE pipeline_analytics.usp_LoadRawData()
COMMENT 'Transforms stg_raw_data into fact_opportunities. Maps raw text category values to dimension surrogate keys. Derives Status, ResolutionDate, MarginDollars, and timing metrics. Implemented in Phase 3.'
BEGIN
    -- Placeholder: logic implemented in 02_build.sql (Phase 3)
    SELECT 'usp_LoadRawData: not yet implemented' AS Status;
END;

CREATE OR REPLACE PROCEDURE pipeline_analytics.usp_BuildSegments(
    p_min_jobs_per_segment  INT,
    p_training_start        DATE,
    p_training_end          DATE,
    p_build_run_key         BIGINT
)
COMMENT 'Core estimation engine. Segments training data by status and category dimensions. Computes mean outcomes per segment; applies minimum-size cascade (drops Cat5, Cat4, Cat3 in order). Writes results to analytical_segments. Implemented in Phase 3.'
BEGIN
    -- Placeholder: logic implemented in 02_build.sql (Phase 3)
    SELECT 'usp_BuildSegments: not yet implemented' AS Status;
END;

CREATE OR REPLACE PROCEDURE pipeline_analytics.usp_ApplyModel(
    p_build_run_key  BIGINT
)
COMMENT 'Applies segment estimates to the current pipeline. Matches each opportunity/job to its best-fit segment. Converts estimated days to estimated dates using anchor dates. Writes results to analytical_job_results. Implemented in Phase 3.'
BEGIN
    -- Placeholder: logic implemented in 02_build.sql (Phase 3)
    SELECT 'usp_ApplyModel: not yet implemented' AS Status;
END;

CREATE OR REPLACE PROCEDURE pipeline_analytics.usp_BuildPipelineAggregations(
    p_build_run_key  BIGINT
)
COMMENT 'Aggregates job-level results by calendar month. Computes total estimated fees, margin, job counts, and median milestone dates. Writes results to analytical_pipeline_results. Implemented in Phase 3.'
BEGIN
    -- Placeholder: logic implemented in 02_build.sql (Phase 3)
    SELECT 'usp_BuildPipelineAggregations: not yet implemented' AS Status;
END;

CREATE OR REPLACE PROCEDURE pipeline_analytics.usp_RunBuild(
    p_min_jobs_per_segment  INT     DEFAULT 30,
    p_training_start        DATE    DEFAULT NULL,   -- Defaults computed in body if NULL
    p_training_end          DATE    DEFAULT NULL,
    p_test_start            DATE    DEFAULT NULL,
    p_test_end              DATE    DEFAULT NULL
)
COMMENT 'Master orchestration procedure. Accepts configurable parameters, logs the run to log_build_runs, and calls usp_LoadRawData, usp_BuildSegments, usp_ApplyModel, and usp_BuildPipelineAggregations in sequence. Implemented in Phase 3.'
BEGIN
    -- Placeholder: logic implemented in 02_build.sql (Phase 3)
    SELECT 'usp_RunBuild: not yet implemented' AS Status;
END;


/* ============================================================
   SECTION 8 — SETUP VERIFICATION
   ============================================================
   Returns a count of all objects created, confirming
   successful setup.
   Expected: 12 Tables | 5 Procedures
   ============================================================ */

SELECT 'Tables' AS ObjectType, COUNT(*) AS ObjectCount
FROM   information_schema.tables
WHERE  table_schema = 'pipeline_analytics'
  AND  table_name IN (
           'dim_service_line','dim_client_type','dim_industry',
           'dim_new_vs_existing','dim_lead_source','dim_status',
           'stg_raw_data','fact_opportunities',
           'analytical_segments','analytical_job_results',
           'analytical_pipeline_results','log_build_runs'
       )

UNION ALL

SELECT 'Procedures', COUNT(*)
FROM   information_schema.routines
WHERE  routine_schema = 'pipeline_analytics'
  AND  routine_type   = 'PROCEDURE'
  AND  routine_name IN (
           'usp_LoadRawData','usp_BuildSegments',
           'usp_ApplyModel','usp_BuildPipelineAggregations','usp_RunBuild'
       );
