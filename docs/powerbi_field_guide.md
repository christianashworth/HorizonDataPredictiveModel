# Power BI Field Guide — PipelineAnalytics.pbip
## Horizon Data Predictive Model

This document describes every table, field, and DAX measure in the Power BI semantic model, written in plain language for report users and developers.

---

## Report Pages

| Page | Purpose |
|------|---------|
| 1. Training Analysis | Shows how the model was trained — what segment cells exist, what outcomes were estimated, how many historical observations backed each estimate, and whether any category dimensions were dropped |
| 2. Model Performance — Test Dataset | Compares the model's predictions against known actual outcomes for a held-out test window. Used to evaluate model accuracy |
| 3. Current Pipeline — Job Predictions | Shows the model's estimates applied to each individual current opportunity and job, including estimated milestone dates |
| 4. Pipeline Summary | Monthly aggregation of the current pipeline — how many jobs are estimated to start each month and what fees and margin they represent |

---

## Tables

### analytical_training_summary
Human-readable version of the model's training segments. One row per segment-outcome combination. This is the primary table for Page 1.

| Field | Type | Description |
|-------|------|-------------|
| TrainingSummaryKey | Integer | Unique row identifier |
| SegmentKey | Integer | Links to the underlying analytical_segments table |
| BuildRunKey | Integer | Identifies which build run produced this row |
| OutcomeName | Text | The outcome being estimated. One of: WinPct, NetFees, MarginPct, DaysSellToStart, DaysStartTo50Pct, DaysStartTo100Pct |
| OutcomeEstimate | Decimal | The model's estimated mean value for this outcome within this segment, computed from the training dataset |
| ObservationCount | Integer | Number of historical records used to compute the estimate. Lower counts indicate less reliable estimates |
| GranularityLevel | Integer | How many category dimensions were used: 0 = all 5 categories, 5 = status only. Higher numbers mean fewer categories were available |
| CategoriesDropped | Integer | Count of category dimensions dropped to meet the minimum segment size (0–5) |
| Cat1Dropped | Boolean | True if ServiceLine was dropped for this segment |
| Cat2Dropped | Boolean | True if ClientType was dropped for this segment |
| Cat3Dropped | Boolean | True if Industry was dropped for this segment |
| Cat4Dropped | Boolean | True if NewVsExisting was dropped for this segment |
| Cat5Dropped | Boolean | True if LeadSource was dropped for this segment |
| StatusName | Text | The job status this segment applies to (Open Opportunity, Lost, Sold/Not Started, Started) |
| ServiceLineName | Text | Service line for this segment, or "All" if Cat1 was dropped |
| ClientTypeName | Text | Client type for this segment, or "All" if Cat2 was dropped |
| IndustryName | Text | Industry for this segment, or "All" if Cat3 was dropped |
| NewVsExistingName | Text | New vs existing for this segment, or "All" if Cat4 was dropped |
| LeadSourceName | Text | Lead source for this segment, or "All" if Cat5 was dropped |
| SegmentLabel | Text | Pipe-delimited readable cell label, e.g. "Open Opportunity \| Audit \| Business \| Healthcare \| Existing \| Referral". Dropped categories show as "All" |
| DroppedCategoriesLabel | Text | Comma-separated list of dropped category names, or "None" if no categories were dropped |

---

### analytical_test_results
Predicted vs actual comparison for records in the held-out test window. One row per test record per applicable outcome. Used exclusively on Page 2.

| Field | Type | Description |
|-------|------|-------------|
| TestResultKey | Integer | Unique row identifier |
| OpportunityID | Text | Links to the opportunity/job in fact_opportunities |
| SegmentKey | Integer | The segment used to generate the prediction |
| BuildRunKey | Integer | Identifies which build run produced this row |
| OutcomeName | Text | The outcome being compared (WinPct, NetFees, MarginPct, DaysSellToStart, DaysStartTo50Pct, DaysStartTo100Pct) |
| PredictedValue | Decimal | The model's segment-level estimate for this outcome |
| ActualValue | Decimal | The observed real value. For WinPct: 1.0 = won, 0.0 = lost. Only populated where the actual outcome is known |
| Error | Decimal | PredictedValue minus ActualValue. Positive = model overestimated; negative = model underestimated |
| AbsoluteError | Decimal | Absolute value of Error — magnitude of the miss regardless of direction |
| SquaredError | Decimal | Error squared — weights larger misses more heavily than smaller ones. Used to compute RMSE |
| PercentageError | Decimal | Error divided by ActualValue — normalises the miss by the scale of the outcome. Null when ActualValue is zero |
| GranularityLevel | Integer | Granularity level of the segment used for this prediction |
| CategoriesDropped | Integer | Number of categories dropped in the segment used for this prediction |
| StatusName | Text | Status of the record at the time of prediction |
| ServiceLineName | Text | Service line of the record |
| ClientTypeName | Text | Client type of the record |
| IndustryName | Text | Industry of the record |
| NewVsExistingName | Text | New vs existing classification of the record |
| LeadSourceName | Text | Lead source of the record |
| SegmentLabel | Text | Readable segment cell label for context |

---

### analytical_job_results
Model estimates applied at the individual opportunity/job level. One row per record. Used on Page 3. Contains both Current pipeline records and Test dataset records (see DatasetType).

| Field | Type | Description |
|-------|------|-------------|
| OpportunityID | Text | Unique identifier linking to fact_opportunities |
| SegmentKey | Integer | The segment matched to this record for estimation |
| EstimatedWinPct | Decimal | Estimated probability of winning this opportunity (0–1). Populated for Open Opportunity status only |
| EstimatedNetFees | Decimal | Estimated net fees in dollars. Uses actual NetFees if already known, otherwise the segment mean |
| EstimatedMarginPct | Decimal | Estimated margin percentage. Uses actual MarginPct if already known, otherwise the segment mean |
| EstimatedMarginDollars | Decimal | EstimatedMarginPct × EstimatedNetFees |
| EstimatedSellDate | Date | Estimated date the opportunity will convert to a sold job. Currently not populated (reserved for future use) |
| EstimatedStartDate | Date | Estimated date work will begin. For sold jobs: SoldDate + segment mean DaysSellToStart. For started jobs: the actual StartDate |
| EstimatedPct50Date | Date | Estimated date the job will reach 50% complete. StartDate + segment mean DaysStartTo50Pct. Null for Sold/Not Started jobs |
| EstimatedPct100Date | Date | Estimated date the job will reach 100% complete. StartDate + segment mean DaysStartTo100Pct. Null for Sold/Not Started jobs |
| DatasetType | Text | "Current" = live pipeline record. "Test" = held-out test window record where actuals are available for comparison |
| BuildRunKey | Integer | Identifies which build run produced this row |

---

### analytical_pipeline_results
Monthly aggregation of current pipeline job estimates. One row per calendar month. Used on Page 4.

| Field | Type | Description |
|-------|------|-------------|
| PipelineResultKey | Integer | Unique row identifier |
| PeriodMonth | Date | First day of the calendar month. Jobs are bucketed by their EstimatedStartDate month |
| EstimatedJobCount | Integer | Number of jobs estimated to start in this month |
| EstimatedNetFees | Decimal | Total estimated net fees for jobs starting in this month |
| EstimatedMarginDollars | Decimal | Total estimated margin dollars for jobs starting in this month |
| MedianPct50Date | Date | Median estimated 50%-complete date across all jobs starting in this month. Null for months dominated by Sold/Not Started jobs (those jobs have an estimated start date but no estimated completion dates) |
| MedianPct100Date | Date | Median estimated 100%-complete date across all jobs starting in this month. Null for same reason as above |
| BuildRunKey | Integer | Identifies which build run produced this row |

---

### fact_opportunities
Core fact table. One row per opportunity/job. Contains all raw dates, financials, dimension keys, and derived timing metrics.

| Field | Type | Description |
|-------|------|-------------|
| OpportunityID | Text | Unique identifier |
| ServiceLineKey | Integer | Links to dim_service_line |
| ClientTypeKey | Integer | Links to dim_client_type |
| IndustryKey | Integer | Links to dim_industry |
| NewVsExistingKey | Integer | Links to dim_new_vs_existing |
| LeadSourceKey | Integer | Links to dim_lead_source |
| StatusKey | Integer | Links to dim_status. Derived from date fields at load time |
| CreatedDate | Date | Date the opportunity entered the pipeline |
| SoldDate | Date | Date the contract was signed. Null if not yet won |
| ClosedLostDate | Date | Date the opportunity was marked lost. Null if won or still open |
| StartDate | Date | Date work began. Null until the job has started |
| Pct50CompleteDate | Date | Date the job reached 50% completion. Null until reached |
| Pct100CompleteDate | Date | Date the job reached 100% completion. Null until reached |
| ResolutionDate | Date | SoldDate if won, ClosedLostDate if lost. Used to bucket records into training/test windows. Null for open opportunities |
| NetFees | Currency | Actual net fees. Populated once the opportunity is sold |
| MarginPct | Decimal | Actual margin percentage. Populated only once the job is 100% complete |
| MarginDollars | Currency | MarginPct × NetFees. Stored for query performance |
| DaysSellToStart | Integer | Days between SoldDate and StartDate |
| DaysStartTo50Pct | Integer | Days between StartDate and Pct50CompleteDate |
| DaysStartTo100Pct | Integer | Days between StartDate and Pct100CompleteDate |

---

### Dimension Tables

#### dim_service_line
| Field | Description |
|-------|-------------|
| ServiceLineKey | Surrogate key |
| ServiceLineName | Audit, Tax, Advisory, Unknown |

#### dim_client_type
| Field | Description |
|-------|-------------|
| ClientTypeKey | Surrogate key |
| ClientTypeName | Business, Individual, Unknown |

#### dim_industry
| Field | Description |
|-------|-------------|
| IndustryKey | Surrogate key |
| IndustryName | Healthcare, Manufacturing, Technology, Financial Services, Nonprofit, Real Estate, Construction, Other, Unknown |

#### dim_new_vs_existing
| Field | Description |
|-------|-------------|
| NewVsExistingKey | Surrogate key |
| NewVsExistingName | New, Existing, Unknown |

#### dim_lead_source
| Field | Description |
|-------|-------------|
| LeadSourceKey | Surrogate key |
| LeadSourceName | Referral, Existing-Client Expansion, Competitive RFP, Outbound, Unknown |

#### dim_status
| Field | Description |
|-------|-------------|
| StatusKey | Surrogate key |
| StatusName | Open Opportunity, Lost, Sold/Not Started, Started |
| StatusDescription | Plain-language description of how status is derived from date fields |

---

### log_build_runs
Audit log of every build execution. Used to track model refresh history.

| Field | Description |
|-------|-------------|
| BuildRunKey | Unique run identifier |
| RunTimestamp | Date and time the build started |
| MinJobsPerSegment | Minimum segment size configured for this run (default 30) |
| TrainingStart | Start of the training window used |
| TrainingEnd | End of the training window used |
| TestStart | Start of the test window used |
| TestEnd | End of the test window used |
| RowsProcessed | Total records loaded into fact_opportunities |
| SegmentsBuilt | Total segment-outcome combinations built |
| JobResultsWritten | Total job-level estimate rows written |
| Status | Running, Success, Warning, or Error |
| StatusMessage | Details of the run parameters or error message if failed |

---

## DAX Measures

### Page 1 — Training Analysis

| Measure | Formula | Plain-Language Description |
|---------|---------|---------------------------|
| Seg Count | `DISTINCTCOUNT(analytical_training_summary[SegmentLabel])` | Number of unique segment cells in the training summary. Each cell is a unique combination of status and category dimensions |
| Avg Obs Per Segment | `AVERAGE(analytical_training_summary[ObservationCount])` | Average number of historical records used per segment estimate. Higher is better — more observations = more reliable estimates |
| Segs With Drops | `CALCULATE(DISTINCTCOUNT(analytical_training_summary[SegmentLabel]), analytical_training_summary[CategoriesDropped] > 0)` | Number of segments where at least one category dimension had to be dropped to meet the minimum observation threshold of 30 |

---

### Page 2 — Model Performance

| Measure | Formula | Plain-Language Description |
|---------|---------|---------------------------|
| Test RMSE | `SQRT(AVERAGE(analytical_test_results[SquaredError]))` | Root Mean Squared Error — the average prediction miss in the same units as the outcome (dollars for NetFees, percentage points for MarginPct, probability for WinPct). Penalises large misses more heavily than small ones |
| Test MAE | `AVERAGE(analytical_test_results[AbsoluteError])` | Mean Absolute Error — the average size of the prediction miss regardless of direction. More interpretable than RMSE for day-to-day use |
| Test Mean Error | `AVERAGE(analytical_test_results[Error])` | Mean Error (Bias) — the average directional miss. Near zero means the model has no systematic bias. Positive means the model consistently overestimates; negative means it consistently underestimates |
| Test Expected Wins | `CALCULATE(SUM(analytical_test_results[PredictedValue]), analytical_test_results[OutcomeName] = "WinPct")` | Sum of predicted win probabilities across all test-window opportunities. Represents how many wins the model expected. Compare to Test Actual Wins to evaluate win probability calibration |
| Test Actual Wins | `CALCULATE(SUM(analytical_test_results[ActualValue]), analytical_test_results[OutcomeName] = "WinPct")` | Actual number of wins observed in the test window. Compare to Test Expected Wins — if they are close, the win probability model is well calibrated |

---

### Page 3 — Job Predictions

| Measure | Formula | Plain-Language Description |
|---------|---------|---------------------------|
| Pipeline Jobs | `COUNTROWS(analytical_job_results)` | Total number of opportunities and jobs with model estimates applied |
| Pipeline Estimated Fees | `CALCULATE(SUM(analytical_job_results[EstimatedNetFees]), analytical_job_results[DatasetType] = "Current")` | Total estimated net fees across all current pipeline records (excludes test dataset records) |
| Pipeline Estimated Margin | `CALCULATE(SUM(analytical_job_results[EstimatedMarginDollars]), analytical_job_results[DatasetType] = "Current")` | Total estimated margin dollars across all current pipeline records |
| Prob Weighted Fees | `CALCULATE(SUMX(analytical_job_results, analytical_job_results[EstimatedWinPct] * analytical_job_results[EstimatedNetFees]), analytical_job_results[DatasetType] = "Current")` | Expected value of the open opportunity pipeline — each opportunity's estimated fees multiplied by its estimated win probability, then summed. Meaningful only when filtering to Open Opportunity status. Represents the risk-adjusted pipeline value |

---

### Page 4 — Pipeline Summary

| Measure | Formula | Plain-Language Description |
|---------|---------|---------------------------|
| Total Pipeline Jobs | `SUM(analytical_pipeline_results[EstimatedJobCount])` | Total number of jobs estimated to start across all months in the selected date range |
| Total Pipeline Fees | `SUM(analytical_pipeline_results[EstimatedNetFees])` | Total estimated net fees across all months in the selected date range |
| Total Pipeline Margin | `SUM(analytical_pipeline_results[EstimatedMarginDollars])` | Total estimated margin dollars across all months in the selected date range |

---

## Key Concepts

### Segment Granularity
The model segments historical data by status and up to 5 category dimensions. When a segment has fewer than 30 observations, categories are dropped in this order until the threshold is met:
1. LeadSource dropped first (Cat5)
2. NewVsExisting dropped second (Cat4)
3. Industry dropped third (Cat3)
4. ClientType dropped fourth (Cat2)
5. ServiceLine dropped last (Cat1)

If all categories are dropped and the status-only segment still has fewer than 30 observations, the estimate is based on all available records for that status.

### DatasetType
Records in analytical_job_results are tagged as either:
- **Current** — live pipeline records (open opportunities, sold jobs, started jobs) where the real outcome is not yet known
- **Test** — records from a held-out test window (typically 1–6 months before end of last calendar month) where the real outcome is now known, used to evaluate model accuracy on Page 2

### Why MedianPct50Date and MedianPct100Date are sometimes blank
These dates are only estimated for jobs that have already started (StartDate is known). Jobs in Sold/Not Started status have an EstimatedStartDate but no estimated completion dates, since completion timing is estimated relative to the actual start date. Months where most jobs are Sold/Not Started will show blank median completion dates — this is expected, not missing data.

### Win Probability Calibration
The model estimates win probability as the historical win rate within a segment (e.g. 55% of Audit × Business × Referral opportunities were won). To evaluate calibration on Page 2, compare Test Expected Wins (sum of predicted probabilities) against Test Actual Wins (count of actual wins). If they are close, the model is well calibrated — meaning a 55% predicted probability really does correspond to winning about 55% of the time in practice.
