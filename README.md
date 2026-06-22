# Horizon Data Predictive Model

A plug-and-play predictive analytics tool for a professional services firm, built on SQL Server, Databricks SQL, Power BI, and Excel. Uses historical opportunity and job data to estimate win likelihood, timing of key milestones, net fees, and margin for unsold opportunities and in-progress jobs.

---

## Project Overview

### What It Does
- **Estimates win likelihood** for open (unsold) opportunities based on historical win rates within matching segments
- **Estimates milestone timing** (job sell date, start date, 50% complete, 100% complete) as estimated dates
- **Estimates net fees and margin** for both opportunities and sold jobs
- **Validates model performance** by comparing predicted vs actual outcomes on a held-out test dataset
- **Aggregates pipeline-level results** by time period (e.g., total estimated fees and margin for jobs starting in a given month)

### How It Works
Historical data is segmented by job status and up to 5 category dimensions. For each segment, outcome means are computed from a training dataset and applied to current opportunities and jobs. If a segment has too few observations, category dimensions are dropped in priority order until a minimum threshold is met. Model performance is then evaluated against a separate test dataset where real outcomes are known.

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
  raw_data_sample.xlsx        # Raw source data (Excel) — swap in real data here
/sql/
  /sqlserver/                 # SQL Server scripts (primary implementation)
    01_setup.sql              # Creates database, tables, indexes, procedure shells
    02_load_sample_data.sql   # Loads sample data into stg_raw_data
    03_build.sql              # Implements procedures and runs the full build
    04_training_test_tables.sql # Adds training summary and test results tables
  /databricks/                # Databricks SQL parallel scripts
    01_setup.sql
    02_build.sql
/powerbi/                     # Power BI .pbip files and semantic model
/docs/                        # Mermaid ERD/data flow diagrams and field documentation
  star_schema_erd.mermaid     # Entity relationship diagram
README.md
```

---

## Build Phases

| Phase | Description | Status |
|-------|-------------|--------|
| 1 | Data model design & sample data generation | ✅ Complete |
| 2 | SQL Server & Databricks Setup scripts (star schema, stored procedures) | ✅ Complete |
| 3 | Build scripts — segmentation, estimation logic, training summary, test results | ✅ Complete |
| 4 | Apply model to current pipeline (embedded in Phase 3 Build scripts) | ✅ Complete |
| 5 | Power BI semantic model & report (.pbip) | 🔲 In Progress |
| 6 | Documentation (in-code, Mermaid diagrams, Power BI field guide) | 🔲 Pending |

---

## SQL Server Script Run Order

Run these scripts in sequence on a fresh SQL Server instance:

| Step | Script | Purpose |
|------|--------|---------|
| 1 | `01_setup.sql` | Creates the `PipelineAnalytics` database, all tables, indexes, and stored procedure shells |
| 2 | `02_load_sample_data.sql` | Truncates and loads 3,500 sample records into `stg_raw_data` |
| 3 | `03_build.sql` | Implements all stored procedures and runs the full build via `usp_RunBuild` |
| 4 | `04_training_test_tables.sql` | Adds `analytical_training_summary` and `analytical_test_results` tables and re-runs the build |

> When switching to real data, replace step 2 with your own load process (BULK INSERT, SSIS, etc.) targeting the same `stg_raw_data` table and column structure. Steps 3 and 4 remain unchanged.

---

## Stored Procedures

All procedures are implemented in `03_build.sql` and called automatically by `usp_RunBuild`.

| Procedure | Script | Purpose |
|-----------|--------|---------|
| `usp_LoadRawData` | 03_build.sql | Transforms `stg_raw_data` → `fact_opportunities`. Maps category text values to dimension keys, derives Status, ResolutionDate, MarginDollars, and timing metrics |
| `usp_BuildSegments` | 03_build.sql | Core estimation engine. Computes outcome means at all 6 granularity levels for all 6 outcomes from the training dataset. Populates `analytical_segments` |
| `usp_ApplyModel` | 03_build.sql | Matches current pipeline and test records to their finest qualifying segment. Converts day estimates to calendar dates. Populates `analytical_job_results` |
| `usp_BuildPipelineAggregations` | 03_build.sql | Aggregates job-level estimates into monthly pipeline summaries with median milestone dates. Populates `analytical_pipeline_results` |
| `usp_BuildTrainingSummary` | 04_training_test_tables.sql | Joins `analytical_segments` to dimension tables for human-readable segment labels. Populates `analytical_training_summary` |
| `usp_BuildTestResults` | 04_training_test_tables.sql | Compares predicted vs actual outcomes for test-window records. Computes Error, AbsoluteError, SquaredError, and PercentageError. Populates `analytical_test_results` |
| `usp_RunBuild` | 03_build.sql (updated in 04) | Master orchestrator. Accepts configurable parameters, logs every run to `log_build_runs`, and calls all procedures above in sequence |

---

## Analytical Output Tables

| Table | Rows (sample data) | Purpose |
|-------|--------------------|---------|
| `fact_opportunities` | 3,500 | Core fact table — one row per opportunity/job |
| `analytical_segments` | 4,749 | Raw segment estimates at all granularity levels |
| `analytical_training_summary` | 4,749 | Human-readable training cells for Power BI segment analysis view |
| `analytical_job_results` | 1,868 | Job-level predictions with estimated milestone dates |
| `analytical_test_results` | 971 | Predicted vs actual with error metrics for model performance view |
| `analytical_pipeline_results` | 22 | Monthly pipeline aggregations with median milestone dates |
| `log_build_runs` | 1 per run | Full audit log of every build execution |

---

## Raw Data Schema

The source data lives in `/data/raw_data_sample.xlsx` (sheet: `Raw Data`). One row per opportunity/job. See the `Data Dictionary` sheet in that file for full field descriptions.

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

**Derived status logic (not stored):**
- `Open Opportunity` — SoldDate and ClosedLostDate both null
- `Lost` — ClosedLostDate populated
- `Sold / Not Started` — SoldDate populated, StartDate null
- `Started` — StartDate populated

---

## Configurable Parameters (Build Script)

| Parameter | Default | Description |
|-----------|---------|-------------|
| Minimum jobs per segment | 30 | Minimum observations required before dropping a category |
| Training data start | 24 months before end of last calendar month | Start of training window |
| Training data end | 7 months before end of last calendar month | End of training window |
| Test data start | 6 months before end of last calendar month | Start of test window |
| Test data end | 1 month before end of last calendar month | End of test window |

---

## Getting Started

1. Clone this repository
2. Run `sql/sqlserver/01_setup.sql` to create the database and all objects
3. Run `sql/sqlserver/02_load_sample_data.sql` to load the sample dataset
4. Run `sql/sqlserver/03_build.sql` to build the model
5. Run `sql/sqlserver/04_training_test_tables.sql` to add training and test output tables
6. Open the Power BI file in `/powerbi/` and connect to your SQL Server instance
7. To use real data: replace step 3 with your own load process into `stg_raw_data`, then re-run steps 4 and 5
