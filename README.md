# Horizon Data Predictive Model

A plug-and-play predictive analytics tool for a professional services firm, built on SQL Server, Databricks SQL, Power BI, and Excel. Uses historical opportunity and job data to estimate win likelihood, timing of key milestones, net fees, and margin for unsold opportunities and in-progress jobs.

---

## Project Overview

### What It Does
- **Estimates win likelihood** for open (unsold) opportunities based on historical win rates within matching segments
- **Estimates milestone timing** (job sell date, start date, 50% complete, 100% complete) as estimated calendar dates
- **Estimates net fees and margin** for both opportunities and sold jobs
- **Validates model performance** by comparing predicted vs actual outcomes against a held-out test dataset
- **Aggregates pipeline-level results** by calendar month (estimated job counts, fees, margin, and median milestone dates)

### How It Works
Historical opportunity and job data is segmented by status and up to 5 category dimensions. For each segment, outcome means are computed from a training dataset (jobs resolved 7–24 months ago) and applied to current opportunities and jobs. If a segment has fewer than 30 observations, category dimensions are dropped in priority order until the threshold is met. Model accuracy is then evaluated against a separate test dataset (jobs resolved 1–6 months ago) where real outcomes are known.

**Category dimensions (in drop order — lowest priority dropped first):**
| Priority | Category | Field | Values |
|----------|----------|-------|--------|
| 1 (never dropped first) | Service Line | ServiceLine | Audit, Tax, Advisory |
| 2 | Client Type | ClientType | Business, Individual |
| 3 | Industry/Sector | Industry | Healthcare, Manufacturing, Technology, Financial Services, Nonprofit, Real Estate, Construction, Other |
| 4 | New vs. Existing Client | NewVsExisting | New, Existing |
| 5 (dropped first) | Lead Source | LeadSource | Referral, Existing-Client Expansion, Competitive RFP, Outbound |

---

## Repository Structure

```
/data/
  raw_data_sample.xlsx          # Raw source data (Excel) — swap in real data here
/sql/
  /sqlserver/                   # SQL Server scripts (primary implementation)
    01_setup.sql                # Creates database, tables, indexes, procedure shells
    02_load_sample_data.sql     # Loads 3,500 sample records into stg_raw_data
    03_build.sql                # Implements all procedures and runs the full build
    04_training_test_tables.sql # Adds training summary and test results tables
  /databricks/                  # Databricks SQL parallel scripts
    01_setup.sql
    02_build.sql
/powerbi/
  PipelineAnalytics.pbip        # Power BI project file — open in Power BI Desktop
  PipelineAnalytics.Report/     # Report definition (4 pages)
  PipelineAnalytics.SemanticModel/ # Semantic model (tables, relationships, measures)
/docs/
  star_schema_erd.mermaid       # Entity relationship diagram
  data_flow.mermaid             # End-to-end data flow diagram
  powerbi_field_guide.md        # Plain-language field and measure documentation
README.md
```

---

## Build Phases

| Phase | Description | Status |
|-------|-------------|--------|
| 1 | Data model design & sample data generation | ✅ Complete |
| 2 | SQL Server & Databricks Setup scripts | ✅ Complete |
| 3 | Build scripts — segmentation, estimation, training summary, test results | ✅ Complete |
| 4 | Apply model to current pipeline (embedded in Phase 3) | ✅ Complete |
| 5 | Power BI semantic model & 4-page report | ✅ Complete |
| 6 | Documentation — ERD, data flow diagram, Power BI field guide | ✅ Complete |

---

## SQL Server Script Run Order

Run these scripts in sequence on a fresh SQL Server instance:

| Step | Script | Purpose |
|------|--------|---------|
| 1 | `01_setup.sql` | Creates the `PipelineAnalytics` database, all tables, indexes, and stored procedure shells |
| 2 | `02_load_sample_data.sql` | Truncates and loads 3,500 sample records into `stg_raw_data` |
| 3 | `03_build.sql` | Implements all stored procedures and runs the full build via `usp_RunBuild` |
| 4 | `04_training_test_tables.sql` | Adds `analytical_training_summary` and `analytical_test_results` and re-runs the build |

> **Plug-and-play:** To use real data, replace step 2 with your own load process (BULK INSERT, SSIS, etc.) targeting `stg_raw_data` with the same column structure. Steps 3 and 4 remain unchanged. Re-run steps 3 and 4 whenever new data is available to refresh all model outputs.

---

## Stored Procedures

All procedures are called automatically by `usp_RunBuild`.

| Procedure | Script | Purpose |
|-----------|--------|---------|
| `usp_LoadRawData` | 03_build.sql | Transforms `stg_raw_data` → `fact_opportunities`. Maps category text to dimension keys, derives Status, ResolutionDate, MarginDollars, and timing metrics |
| `usp_BuildSegments` | 03_build.sql | Core estimation engine. Computes outcome means at all 6 granularity levels × 6 outcomes from the training dataset. Populates `analytical_segments` |
| `usp_ApplyModel` | 03_build.sql | Matches each current and test record to its finest qualifying segment. Converts estimated days to calendar dates. Populates `analytical_job_results` |
| `usp_BuildPipelineAggregations` | 03_build.sql | Aggregates job-level estimates into monthly summaries with median milestone dates. Populates `analytical_pipeline_results` |
| `usp_BuildTrainingSummary` | 04_training_test_tables.sql | Joins `analytical_segments` to dimension tables for human-readable segment labels. Populates `analytical_training_summary` |
| `usp_BuildTestResults` | 04_training_test_tables.sql | Compares predicted vs actual outcomes for test-window records. Computes Error, AbsoluteError, SquaredError, and PercentageError. Populates `analytical_test_results` |
| `usp_RunBuild` | 03_build.sql (updated in 04) | Master orchestrator. Logs every run to `log_build_runs` and calls all procedures above in sequence |

---

## Analytical Output Tables

| Table | Rows (sample data) | Purpose | Power BI Page |
|-------|--------------------|---------|---------------|
| `fact_opportunities` | 3,500 | Core fact table — one row per opportunity/job | Page 3 |
| `analytical_segments` | 4,749 | Raw segment estimates at all granularity levels | — |
| `analytical_training_summary` | 4,749 | Human-readable training cells with dimension names and segment labels | Page 1 |
| `analytical_job_results` | 1,868 | Job-level predictions with estimated milestone dates | Page 3 |
| `analytical_test_results` | 803 | Predicted vs actual with error metrics for model validation | Page 2 |
| `analytical_pipeline_results` | 22 | Monthly pipeline aggregations with median milestone dates | Page 4 |
| `log_build_runs` | 1 per run | Full audit log of every build execution | — |

---

## Power BI Report

Open `powerbi/PipelineAnalytics.pbip` in Power BI Desktop. Connect to `localhost\SQLEXPRESS01` using SQL Server Authentication (`pbi_user`).

| Page | Description |
|------|-------------|
| 1. Training Analysis | Segment cells, estimated outcomes, observation counts, and category-drop indicators. Slice by OutcomeName and ServiceLineName |
| 2. Model Performance | Predicted vs actual for held-out test records. Error metrics (RMSE, MAE, Mean Error), scatter chart, win probability calibration |
| 3. Job Predictions | Job-level model estimates including EstimatedWinPct, EstimatedNetFees, and estimated milestone dates. Filter by status and service line |
| 4. Pipeline Summary | Monthly pipeline view — job counts, total fees, total margin, and median milestone dates by month |

See `docs/powerbi_field_guide.md` for plain-language descriptions of every table, field, and DAX measure.

---

## Raw Data Schema

The source data lives in `/data/raw_data_sample.xlsx` (sheet: `Raw Data`). One row per opportunity/job. See the `Data Dictionary` sheet for full field descriptions.

| Field | Type | Description |
|-------|------|-------------|
| OpportunityID | Text | Unique identifier |
| ServiceLine | Text | Category 1 — Audit, Tax, Advisory |
| ClientType | Text | Category 2 — Business, Individual |
| Industry | Text | Category 3 — sector (often blank for individuals) |
| NewVsExisting | Text | Category 4 — New or Existing client |
| LeadSource | Text | Category 5 — origination channel |
| CreatedDate | Date | Date opportunity entered pipeline |
| SoldDate | Date | Date contract signed (null if not won) |
| ClosedLostDate | Date | Date marked lost (null if won or open) |
| StartDate | Date | Date work began (null until started) |
| Pct50CompleteDate | Date | Date 50% milestone reached |
| Pct100CompleteDate | Date | Date 100% complete |
| NetFees | Currency | Actual net fees (populated once sold) |
| MarginPct | Percent | Actual margin % (populated once 100% complete) |

**Derived status logic (not stored in raw data):**
- `Open Opportunity` — SoldDate and ClosedLostDate both null
- `Lost` — ClosedLostDate populated
- `Sold / Not Started` — SoldDate populated, StartDate null
- `Started` — StartDate populated

---

## Configurable Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| Minimum jobs per segment | 30 | Minimum observations required before dropping a category |
| Training data start | 24 months before end of last calendar month | Start of training window |
| Training data end | 7 months before end of last calendar month | End of training window |
| Test data start | 6 months before end of last calendar month | Start of test window |
| Test data end | 1 month before end of last calendar month | End of test window |

Parameters are set at the top of `03_build.sql` and passed to `usp_RunBuild`. Leave as NULL to use the rolling defaults, which automatically adjust each time the build is run.

---

## Documentation

| File | Description |
|------|-------------|
| `docs/star_schema_erd.mermaid` | Entity relationship diagram for the star schema |
| `docs/data_flow.mermaid` | End-to-end data flow from Excel input to Power BI output |
| `docs/powerbi_field_guide.md` | Plain-language descriptions of all Power BI tables, fields, and DAX measures |

---

## Getting Started

1. Clone this repository
2. Run `sql/sqlserver/01_setup.sql` to create the database and all objects
3. Run `sql/sqlserver/02_load_sample_data.sql` to load the sample dataset
4. Run `sql/sqlserver/03_build.sql` to build the model
5. Run `sql/sqlserver/04_training_test_tables.sql` to add training and test output tables
6. Open `powerbi/PipelineAnalytics.pbip` in Power BI Desktop and connect to SQL Server
7. Click Refresh to load all data into the report
8. To use real data: replace step 3 with your own load process into `stg_raw_data`, then re-run steps 4 and 5
