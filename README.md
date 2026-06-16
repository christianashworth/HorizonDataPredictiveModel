# Horizon Data Predictive Model

A plug-and-play predictive analytics tool for a professional services firm, built on SQL Server, Databricks SQL, Power BI, and Excel. Uses historical opportunity and job data to estimate win likelihood, timing of key milestones, net fees, and margin for unsold opportunities and in-progress jobs.

---

## Project Overview

### What It Does
- **Estimates win likelihood** for open (unsold) opportunities based on historical win rates within matching segments
- **Estimates milestone timing** (job sell date, start date, 50% complete, 100% complete) as estimated dates
- **Estimates net fees and margin** for both opportunities and sold jobs
- **Aggregates pipeline-level results** by time period (e.g., total estimated fees and margin for jobs starting in a given month)

### How It Works
Historical data is segmented by job status and up to 5 category dimensions. For each segment, outcome means are computed from a training dataset and applied to current opportunities and jobs. If a segment has too few observations, category dimensions are dropped in priority order until a minimum threshold is met.

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
/data/          # Raw source data (Excel) — swap in real data here
/sql/
  /sqlserver/   # SQL Server Setup, Build, and Dashboard scripts
  /databricks/  # Databricks SQL parallel scripts
/powerbi/       # Power BI .pbip files and semantic model
/docs/          # Mermaid ERD/data flow diagrams and field documentation
README.md
```

---

## Build Phases

| Phase | Description | Status |
|-------|-------------|--------|
| 1 | Data model design & sample data generation | ✅ Complete |
| 2 | SQL Server & Databricks Setup scripts (star schema, stored procedures) | 🔲 Pending |
| 3 | Build scripts (segmentation, estimation logic) | 🔲 Pending |
| 4 | Apply model to current pipeline (job-level & pipeline-level outputs) | 🔲 Pending |
| 5 | Power BI semantic model & report (.pbip) | 🔲 Pending |
| 6 | Documentation (in-code, Mermaid diagrams, Power BI field guide) | 🔲 Pending |

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

1. Replace `/data/raw_data_sample.xlsx` with your actual historical data, matching the schema above
2. Run the Setup script (`/sql/sqlserver/01_setup.sql`) to create the database schema
3. Run the Build script (`/sql/sqlserver/02_build.sql`) with your desired parameters
4. Open the Power BI file (`/powerbi/`) and refresh the data connection
