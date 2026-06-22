"""
05_dashboard.py — Dashboard Script
Horizon Data Predictive Model
======================================================================
Purpose : Generates or updates the Power BI .pbip project files:
            - PipelineAnalytics.pbip
            - PipelineAnalytics.SemanticModel/model.bim
            - PipelineAnalytics.SemanticModel/definition.pbism
            - PipelineAnalytics.Report/definition.pbir
            - PipelineAnalytics.Report/report.json

Usage   : python 05_dashboard.py [--server SERVER] [--output OUTPUT]

          --server  SQL Server instance name
                    Default: localhost\\SQLEXPRESS
          --output  Path to write Power BI files
                    Default: ../powerbi  (relative to this script)

          Example — default:
            python 05_dashboard.py

          Example — custom server:
            python 05_dashboard.py --server MYSERVER\\SQLEXPRESS

          Example — custom output path:
            python 05_dashboard.py --output C:\\Users\\Me\\PowerBI

Re-run this script whenever:
  - The SQL Server instance or database name changes
  - A new table or measure needs to be added
  - A report page layout needs to be updated
  Then open (or refresh) the .pbip file in Power BI Desktop.

Power BI Desktop setup (first time only):
  1. File → Options → Preview features → enable
     "Power BI Project (.pbip) save format" → restart
  2. Open powerbi/PipelineAnalytics.pbip
  3. Click Refresh in the Home ribbon to load data

Report pages:
  1. Training Analysis   — segment cells, estimates, observation counts
  2. Model Performance   — predicted vs actual, error metrics, calibration
  3. Job Predictions     — job-level estimates with estimated dates
  4. Pipeline Summary    — monthly aggregations, fees, margin, milestones
======================================================================
"""

import argparse
import json
import os
import sys
from pathlib import Path

# ── Configuration ─────────────────────────────────────────────

DATABASE = "PipelineAnalytics"

SCRIPT_DIR  = Path(__file__).parent
DEFAULT_OUT = (SCRIPT_DIR / ".." / "powerbi").resolve()


# ── Argument parsing ──────────────────────────────────────────

def parse_args():
    parser = argparse.ArgumentParser(
        description="Generate or update Power BI .pbip files for the "
                    "Horizon Data Predictive Model."
    )
    parser.add_argument(
        "--server",
        default=r"localhost\SQLEXPRESS",
        help=r"SQL Server instance (default: localhost\SQLEXPRESS)"
    )
    parser.add_argument(
        "--output",
        default=str(DEFAULT_OUT),
        help=f"Output directory for .pbip files (default: {DEFAULT_OUT})"
    )
    return parser.parse_args()


# ── Helper builders ───────────────────────────────────────────

def m_expr(server, database, sql_table):
    """Power Query M expression to pull a SQL Server table."""
    return [
        "let",
        f"    Source = Sql.Database(\"{server}\", \"{database}\"),",
        f"    data = Source{{[Schema=\"dbo\",Item=\"{sql_table}\"]}}[Data]",
        "in",
        "    data"
    ]


def col(name, dtype, hidden=False, fmt=None, summarize="none"):
    """Column definition for model.bim."""
    c = {
        "name": name,
        "dataType": dtype,
        "sourceColumn": name,
        "summarizeBy": summarize
    }
    if hidden: c["isHidden"] = True
    if fmt:    c["formatString"] = fmt
    return c


def tbl(name, sql_table, columns, server, database, measures=None, hidden=False):
    """Table definition for model.bim."""
    t = {
        "name": name,
        "columns": columns,
        "partitions": [{
            "name": "Partition",
            "dataView": "full",
            "source": {
                "type": "m",
                "expression": m_expr(server, database, sql_table)
            }
        }]
    }
    if measures: t["measures"] = measures
    if hidden:   t["isHidden"] = True
    return t


def msr(name, expr, fmt=None, folder=None, desc=None):
    """DAX measure definition for model.bim."""
    m = {"name": name, "expression": expr}
    if fmt:    m["formatString"] = fmt
    if folder: m["displayFolder"] = folder
    if desc:   m["description"]   = desc
    return m


def rel(from_t, from_c, to_t, to_c):
    """Relationship definition for model.bim."""
    return {
        "name": f"{from_t}_{from_c}_to_{to_t}_{to_c}",
        "fromTable": from_t,
        "fromColumn": from_c,
        "toTable": to_t,
        "toColumn": to_c,
        "crossFilteringBehavior": "oneDirection"
    }


def txt(x, y, w, h, text, size=11, bold=False):
    """Text box visual container for report.json."""
    return {
        "x": x, "y": y, "z": 0, "width": w, "height": h,
        "config": json.dumps({
            "name": f"txt{x}{y}",
            "visualType": "textbox",
            "droppedFields": [],
            "prototypeQuery": {"Version": 2, "From": [], "Select": []},
            "vcObjects": {"general": [{"properties": {"paragraphs": [{
                "textRuns": [{
                    "value": text,
                    "textStyle": {
                        "fontWeight": "bold" if bold else "normal",
                        "fontSize": f"{size}pt"
                    }
                }],
                "horizontalTextAlignment": "left"
            }]}}]}
        })
    }


# ── Table definitions ─────────────────────────────────────────

def build_tables(server, database):
    """
    Returns all table definitions for the semantic model.
    12 SQL Server tables + 1 hidden _Measures table.
    """
    tables = [

        # ── Dimension tables ───────────────────────────────────
        tbl("dim_service_line", "dim_service_line", [
            col("ServiceLineKey", "int64", hidden=True),
            col("ServiceLineName", "string")
        ], server, database),

        tbl("dim_client_type", "dim_client_type", [
            col("ClientTypeKey", "int64", hidden=True),
            col("ClientTypeName", "string")
        ], server, database),

        tbl("dim_industry", "dim_industry", [
            col("IndustryKey", "int64", hidden=True),
            col("IndustryName", "string")
        ], server, database),

        tbl("dim_new_vs_existing", "dim_new_vs_existing", [
            col("NewVsExistingKey", "int64", hidden=True),
            col("NewVsExistingName", "string")
        ], server, database),

        tbl("dim_lead_source", "dim_lead_source", [
            col("LeadSourceKey", "int64", hidden=True),
            col("LeadSourceName", "string")
        ], server, database),

        tbl("dim_status", "dim_status", [
            col("StatusKey", "int64", hidden=True),
            col("StatusName", "string"),
            col("StatusDescription", "string")
        ], server, database),

        # ── Fact table ────────────────────────────────────────
        tbl("fact_opportunities", "fact_opportunities", [
            col("OpportunityID",      "string"),
            col("ServiceLineKey",     "int64",    hidden=True),
            col("ClientTypeKey",      "int64",    hidden=True),
            col("IndustryKey",        "int64",    hidden=True),
            col("NewVsExistingKey",   "int64",    hidden=True),
            col("LeadSourceKey",      "int64",    hidden=True),
            col("StatusKey",          "int64",    hidden=True),
            col("CreatedDate",        "dateTime", fmt="Short Date"),
            col("SoldDate",           "dateTime", fmt="Short Date"),
            col("ClosedLostDate",     "dateTime", fmt="Short Date"),
            col("StartDate",          "dateTime", fmt="Short Date"),
            col("Pct50CompleteDate",  "dateTime", fmt="Short Date"),
            col("Pct100CompleteDate", "dateTime", fmt="Short Date"),
            col("ResolutionDate",     "dateTime", fmt="Short Date"),
            col("NetFees",            "decimal",  fmt=r"$#,##0",  summarize="sum"),
            col("MarginPct",          "decimal",  fmt="0.0%",     summarize="average"),
            col("MarginDollars",      "decimal",  fmt=r"$#,##0",  summarize="sum"),
            col("DaysSellToStart",    "int64",                    summarize="average"),
            col("DaysStartTo50Pct",   "int64",                    summarize="average"),
            col("DaysStartTo100Pct",  "int64",                    summarize="average"),
            col("LoadTimestamp",      "dateTime", hidden=True)
        ], server, database),

        # ── Analytical output tables ──────────────────────────
        # Training summary: human-readable segment cells
        # Connects to the Training Analysis report page
        tbl("analytical_training_summary", "analytical_training_summary", [
            col("TrainingSummaryKey",     "int64",   hidden=True),
            col("SegmentKey",             "int64",   hidden=True),
            col("BuildRunKey",            "int64",   hidden=True),
            col("OutcomeName",            "string"),
            col("OutcomeEstimate",        "decimal"),
            col("ObservationCount",       "int64",   summarize="sum"),
            col("GranularityLevel",       "int64"),
            col("CategoriesDropped",      "int64"),
            col("Cat1Dropped",            "boolean"),
            col("Cat2Dropped",            "boolean"),
            col("Cat3Dropped",            "boolean"),
            col("Cat4Dropped",            "boolean"),
            col("Cat5Dropped",            "boolean"),
            col("StatusName",             "string"),
            col("ServiceLineName",        "string"),
            col("ClientTypeName",         "string"),
            col("IndustryName",           "string"),
            col("NewVsExistingName",      "string"),
            col("LeadSourceName",         "string"),
            col("SegmentLabel",           "string"),
            col("DroppedCategoriesLabel", "string")
        ], server, database),

        # Job results: model applied at individual job level
        # Connects to the Job Predictions report page
        # Timing outcomes stored as estimated dates (not days)
        tbl("analytical_job_results", "analytical_job_results", [
            col("OpportunityID",          "string"),
            col("SegmentKey",             "int64",    hidden=True),
            col("BuildRunKey",            "int64",    hidden=True),
            col("EstimatedWinPct",        "decimal",  fmt="0.0%"),
            col("EstimatedNetFees",       "decimal",  fmt=r"$#,##0", summarize="sum"),
            col("EstimatedMarginPct",     "decimal",  fmt="0.0%"),
            col("EstimatedMarginDollars", "decimal",  fmt=r"$#,##0", summarize="sum"),
            col("EstimatedSellDate",      "dateTime", fmt="Short Date"),
            col("EstimatedStartDate",     "dateTime", fmt="Short Date"),
            col("EstimatedPct50Date",     "dateTime", fmt="Short Date"),
            col("EstimatedPct100Date",    "dateTime", fmt="Short Date"),
            col("DatasetType",            "string")
        ], server, database),

        # Test results: predicted vs actual for model validation
        # Connects to the Model Performance report page
        tbl("analytical_test_results", "analytical_test_results", [
            col("TestResultKey",     "int64",   hidden=True),
            col("OpportunityID",     "string"),
            col("SegmentKey",        "int64",   hidden=True),
            col("BuildRunKey",       "int64",   hidden=True),
            col("OutcomeName",       "string"),
            col("PredictedValue",    "decimal"),
            col("ActualValue",       "decimal"),
            col("Error",             "decimal"),
            col("AbsoluteError",     "decimal"),
            col("SquaredError",      "decimal"),
            col("PercentageError",   "decimal", fmt="0.0%"),
            col("GranularityLevel",  "int64"),
            col("CategoriesDropped", "int64"),
            col("StatusName",        "string"),
            col("ServiceLineName",   "string"),
            col("ClientTypeName",    "string"),
            col("IndustryName",      "string"),
            col("NewVsExistingName", "string"),
            col("LeadSourceName",    "string"),
            col("SegmentLabel",      "string")
        ], server, database),

        # Pipeline results: monthly aggregations
        # Connects to the Pipeline Summary report page
        tbl("analytical_pipeline_results", "analytical_pipeline_results", [
            col("PipelineResultKey",      "int64",    hidden=True),
            col("PeriodMonth",            "dateTime", fmt="MMM YYYY"),
            col("EstimatedJobCount",      "int64",    summarize="sum"),
            col("EstimatedNetFees",       "decimal",  fmt=r"$#,##0", summarize="sum"),
            col("EstimatedMarginDollars", "decimal",  fmt=r"$#,##0", summarize="sum"),
            col("MedianPct50Date",        "dateTime", fmt="Short Date"),
            col("MedianPct100Date",       "dateTime", fmt="Short Date"),
            col("BuildRunKey",            "int64",    hidden=True)
        ], server, database),

        # Build audit log
        tbl("log_build_runs", "log_build_runs", [
            col("BuildRunKey",       "int64",    hidden=True),
            col("RunTimestamp",      "dateTime"),
            col("MinJobsPerSegment", "int64"),
            col("TrainingStart",     "dateTime", fmt="Short Date"),
            col("TrainingEnd",       "dateTime", fmt="Short Date"),
            col("TestStart",         "dateTime", fmt="Short Date"),
            col("TestEnd",           "dateTime", fmt="Short Date"),
            col("RowsProcessed",     "int64"),
            col("SegmentsBuilt",     "int64"),
            col("JobResultsWritten", "int64"),
            col("Status",            "string"),
            col("StatusMessage",     "string")
        ], server, database),
    ]

    # ── DAX Measures ───────────────────────────────────────────
    # Stored in a hidden table so they appear in the field pane
    # under _Measures, organized by display folder.

    measures = [

        # Error Metrics (continuous outcomes)
        msr("SSE",
            "SUMX(analytical_test_results, analytical_test_results[SquaredError])",
            fmt="#,##0.00", folder="Error Metrics",
            desc="Sum of Squared Errors. Weights large misses more heavily than MAE."),
        msr("MSE",
            "AVERAGEX(analytical_test_results, analytical_test_results[SquaredError])",
            fmt="#,##0.00", folder="Error Metrics",
            desc="Mean Squared Error — average squared prediction error per record."),
        msr("RMSE",
            "SQRT(AVERAGEX(analytical_test_results, analytical_test_results[SquaredError]))",
            fmt="#,##0.00", folder="Error Metrics",
            desc="Root Mean Squared Error — in the same units as the outcome. Lower is better."),
        msr("MAE",
            "AVERAGEX(analytical_test_results, analytical_test_results[AbsoluteError])",
            fmt="#,##0.00", folder="Error Metrics",
            desc="Mean Absolute Error — average size of prediction error regardless of direction."),
        msr("MAPE",
            "AVERAGEX("
            "FILTER(analytical_test_results, NOT ISBLANK(analytical_test_results[PercentageError])), "
            "ABS(analytical_test_results[PercentageError]))",
            fmt="0.0%", folder="Error Metrics",
            desc="Mean Absolute Percentage Error. Normalises error by outcome scale for cross-outcome comparison."),
        msr("Mean Error (Bias)",
            "AVERAGEX(analytical_test_results, analytical_test_results[Error])",
            fmt="+#,##0.00;-#,##0.00;0.00", folder="Error Metrics",
            desc="Mean Error — directional bias. Positive = overestimate, negative = underestimate."),

        # Win % Calibration
        # Actual = 1.0 (won) or 0.0 (lost) at record level.
        # SUM(PredictedValue) = expected wins; SUM(ActualValue) = actual wins.
        msr("Expected Wins",
            "CALCULATE(SUM(analytical_test_results[PredictedValue]), "
            "analytical_test_results[OutcomeName] = \"WinPct\")",
            fmt="#,##0.0", folder="Win % Calibration",
            desc="Sum of predicted win probabilities — the number of wins the model expected."),
        msr("Actual Wins",
            "CALCULATE(SUM(analytical_test_results[ActualValue]), "
            "analytical_test_results[OutcomeName] = \"WinPct\")",
            fmt="#,##0", folder="Win % Calibration",
            desc="Actual number of won opportunities in the test dataset."),
        msr("Win Rate Predicted",
            "DIVIDE([Expected Wins], "
            "CALCULATE(COUNTROWS(analytical_test_results), "
            "analytical_test_results[OutcomeName] = \"WinPct\"))",
            fmt="0.0%", folder="Win % Calibration",
            desc="Average predicted win probability across test records."),
        msr("Win Rate Actual",
            "DIVIDE([Actual Wins], "
            "CALCULATE(COUNTROWS(analytical_test_results), "
            "analytical_test_results[OutcomeName] = \"WinPct\"))",
            fmt="0.0%", folder="Win % Calibration",
            desc="Actual win rate observed in the test dataset."),
        msr("Win Rate Calibration Gap",
            "[Win Rate Predicted] - [Win Rate Actual]",
            fmt="+0.0%;-0.0%;0.0%", folder="Win % Calibration",
            desc="Predicted minus actual win rate. Near zero = well calibrated model."),

        # Pipeline Summary
        msr("Total Estimated Fees",
            "SUM(analytical_pipeline_results[EstimatedNetFees])",
            fmt=r"$#,##0", folder="Pipeline",
            desc="Total estimated net fees across all months in scope."),
        msr("Total Estimated Margin",
            "SUM(analytical_pipeline_results[EstimatedMarginDollars])",
            fmt=r"$#,##0", folder="Pipeline",
            desc="Total estimated margin dollars across all months in scope."),
        msr("Total Estimated Jobs",
            "SUM(analytical_pipeline_results[EstimatedJobCount])",
            fmt="#,##0", folder="Pipeline",
            desc="Total estimated number of jobs starting across all months in scope."),
        msr("Avg Estimated Margin %",
            "DIVIDE([Total Estimated Margin], [Total Estimated Fees])",
            fmt="0.0%", folder="Pipeline",
            desc="Blended estimated margin percentage across all jobs in scope."),

        # Job-Level Predictions
        msr("Current Pipeline Jobs",
            "CALCULATE(COUNTROWS(analytical_job_results), "
            "analytical_job_results[DatasetType] = \"Current\")",
            fmt="#,##0", folder="Job Predictions",
            desc="Number of opportunities and jobs in the current pipeline."),
        msr("Current Pipeline Estimated Fees",
            "CALCULATE(SUM(analytical_job_results[EstimatedNetFees]), "
            "analytical_job_results[DatasetType] = \"Current\")",
            fmt=r"$#,##0", folder="Job Predictions",
            desc="Total estimated net fees across current pipeline records."),
        msr("Current Pipeline Estimated Margin",
            "CALCULATE(SUM(analytical_job_results[EstimatedMarginDollars]), "
            "analytical_job_results[DatasetType] = \"Current\")",
            fmt=r"$#,##0", folder="Job Predictions",
            desc="Total estimated margin dollars across current pipeline records."),
        msr("Probability-Weighted Fees",
            "SUMX("
            "FILTER(analytical_job_results, "
            "analytical_job_results[DatasetType] = \"Current\" && "
            "NOT ISBLANK(analytical_job_results[EstimatedWinPct])), "
            "analytical_job_results[EstimatedNetFees] * "
            "analytical_job_results[EstimatedWinPct])",
            fmt=r"$#,##0", folder="Job Predictions",
            desc="Estimated fees weighted by win probability — expected value of the open opportunity pipeline."),

        # Training Analysis
        msr("Total Segments",
            "DISTINCTCOUNT(analytical_training_summary[SegmentKey])",
            fmt="#,##0", folder="Training",
            desc="Total distinct segment-outcome combinations built from training data."),
        msr("Segments With Dropped Categories",
            "CALCULATE(DISTINCTCOUNT(analytical_training_summary[SegmentKey]), "
            "analytical_training_summary[CategoriesDropped] > 0)",
            fmt="#,##0", folder="Training",
            desc="Segments where at least one category was dropped to meet the minimum observation threshold."),
        msr("Avg Observations Per Segment",
            "AVERAGE(analytical_training_summary[ObservationCount])",
            fmt="#,##0", folder="Training",
            desc="Average number of historical observations backing each segment estimate."),
    ]

    # Hidden measures table
    tables.append({
        "name": "_Measures",
        "isHidden": True,
        "columns": [{"name": "Placeholder", "dataType": "string",
                     "isHidden": True, "sourceColumn": "Placeholder"}],
        "measures": measures,
        "partitions": [{"name": "Partition", "dataView": "full",
                        "source": {"type": "m", "expression": [
                            "let",
                            "    Source = Table.FromRows({}, {\"Placeholder\"})",
                            "in",
                            "    Source"
                        ]}}]
    })

    return tables


# ── Relationship definitions ──────────────────────────────────

RELATIONSHIPS = [
    rel("fact_opportunities",      "ServiceLineKey",   "dim_service_line",    "ServiceLineKey"),
    rel("fact_opportunities",      "ClientTypeKey",    "dim_client_type",     "ClientTypeKey"),
    rel("fact_opportunities",      "IndustryKey",      "dim_industry",        "IndustryKey"),
    rel("fact_opportunities",      "NewVsExistingKey", "dim_new_vs_existing", "NewVsExistingKey"),
    rel("fact_opportunities",      "LeadSourceKey",    "dim_lead_source",     "LeadSourceKey"),
    rel("fact_opportunities",      "StatusKey",        "dim_status",          "StatusKey"),
    rel("analytical_job_results",  "OpportunityID",    "fact_opportunities",  "OpportunityID"),
    rel("analytical_test_results", "OpportunityID",    "fact_opportunities",  "OpportunityID"),
]


# ── Report page definitions ───────────────────────────────────

def build_report_pages():
    """
    Returns the 4 report page definitions.
    Each page has a title and recommended visual layout.
    Add visuals in Power BI Desktop by dragging from the field pane.
    """
    return [
        {
            "name": "ReportSection1",
            "displayName": "1. Training Analysis",
            "width": 1280, "height": 720,
            "visualContainers": [
                txt(20, 20,  1200, 55,
                    "Segment Training Analysis", size=22, bold=True),
                txt(20, 85,  1200, 35,
                    "How the model was trained: estimated outcomes per segment cell, "
                    "observation counts, and category-drop indicators.", size=11),
                txt(20, 140, 580, 520,
                    "RECOMMENDED VISUALS\n\n"
                    "Slicers:\n"
                    "  \u2022 OutcomeName\n"
                    "  \u2022 StatusName\n"
                    "  \u2022 ServiceLineName\n\n"
                    "Cards (top row):\n"
                    "  \u2022 Total Segments\n"
                    "  \u2022 Segments With Dropped Categories\n"
                    "  \u2022 Avg Observations Per Segment\n\n"
                    "Main table:\n"
                    "  SegmentLabel | OutcomeName | OutcomeEstimate\n"
                    "  | ObservationCount | GranularityLevel\n"
                    "  | DroppedCategoriesLabel\n\n"
                    "Bar chart:\n"
                    "  ObservationCount by SegmentLabel\n"
                    "  (shows data-rich vs data-sparse cells)", size=11),
            ]
        },
        {
            "name": "ReportSection2",
            "displayName": "2. Model Performance",
            "width": 1280, "height": 720,
            "visualContainers": [
                txt(20, 20,  1200, 55,
                    "Model Performance \u2014 Test Dataset", size=22, bold=True),
                txt(20, 85,  1200, 35,
                    "Predicted vs actual outcomes for the held-out test window. "
                    "Evaluate accuracy by outcome, service line, and segment.", size=11),
                txt(20, 140, 580, 560,
                    "RECOMMENDED VISUALS\n\n"
                    "Slicer: OutcomeName (select one at a time)\n\n"
                    "Continuous outcome \u2014 error metric cards:\n"
                    "  \u2022 RMSE  (same units as outcome)\n"
                    "  \u2022 MAE\n"
                    "  \u2022 MAPE\n"
                    "  \u2022 Mean Error (Bias)\n\n"
                    "Scatter chart:\n"
                    "  X axis: PredictedValue\n"
                    "  Y axis: ActualValue\n"
                    "  Add a 45-degree reference line\n"
                    "  (perfect predictions lie on the line)\n\n"
                    "Error summary table:\n"
                    "  SegmentLabel | OutcomeName | RMSE | MAE | MAPE\n\n"
                    "Win % Calibration (filter OutcomeName = WinPct):\n"
                    "  \u2022 Card: Win Rate Predicted\n"
                    "  \u2022 Card: Win Rate Actual\n"
                    "  \u2022 Card: Win Rate Calibration Gap\n"
                    "  \u2022 Bar: Expected Wins vs Actual Wins\n"
                    "    by ServiceLineName or SegmentLabel", size=11),
            ]
        },
        {
            "name": "ReportSection3",
            "displayName": "3. Job Predictions",
            "width": 1280, "height": 720,
            "visualContainers": [
                txt(20, 20,  1200, 55,
                    "Current Pipeline \u2014 Job-Level Predictions", size=22, bold=True),
                txt(20, 85,  1200, 35,
                    "Model estimates for each individual opportunity and job. "
                    "Timing outcomes are presented as estimated calendar dates "
                    "(SoldDate + estimated days from sell to start = EstimatedStartDate, etc.).",
                    size=11),
                txt(20, 140, 580, 530,
                    "RECOMMENDED VISUALS\n\n"
                    "Slicers:\n"
                    "  \u2022 StatusName (from dim_status)\n"
                    "  \u2022 ServiceLineName (from dim_service_line)\n"
                    "  \u2022 DatasetType (Current / Test)\n\n"
                    "Summary cards:\n"
                    "  \u2022 Current Pipeline Jobs\n"
                    "  \u2022 Current Pipeline Estimated Fees\n"
                    "  \u2022 Current Pipeline Estimated Margin\n"
                    "  \u2022 Probability-Weighted Fees\n"
                    "    (expected value of open opp pipeline)\n\n"
                    "Main table:\n"
                    "  OpportunityID | StatusName | ServiceLineName\n"
                    "  | EstimatedWinPct | EstimatedNetFees\n"
                    "  | EstimatedMarginPct | EstimatedStartDate\n"
                    "  | EstimatedPct50Date | EstimatedPct100Date\n\n"
                    "Bar chart:\n"
                    "  EstimatedNetFees by ServiceLineName", size=11),
            ]
        },
        {
            "name": "ReportSection4",
            "displayName": "4. Pipeline Summary",
            "width": 1280, "height": 720,
            "visualContainers": [
                txt(20, 20,  1200, 55,
                    "Pipeline Summary \u2014 Monthly View", size=22, bold=True),
                txt(20, 85,  1200, 50,
                    "Monthly aggregation of estimated pipeline activity, bucketed by "
                    "estimated start date. MedianPct50Date and MedianPct100Date are NULL "
                    "for months dominated by Sold/Not Started jobs \u2014 this is expected "
                    "and reflects that completion timing cannot be estimated until a job has started.",
                    size=11),
                txt(20, 155, 580, 480,
                    "RECOMMENDED VISUALS\n\n"
                    "Slicer: PeriodMonth (date range)\n\n"
                    "Summary cards:\n"
                    "  \u2022 Total Estimated Jobs\n"
                    "  \u2022 Total Estimated Fees\n"
                    "  \u2022 Total Estimated Margin\n"
                    "  \u2022 Avg Estimated Margin %\n\n"
                    "Clustered column chart:\n"
                    "  X axis: PeriodMonth\n"
                    "  Y axis: EstimatedJobCount\n\n"
                    "Line chart:\n"
                    "  X axis: PeriodMonth\n"
                    "  Y axis: EstimatedNetFees\n\n"
                    "Summary table:\n"
                    "  PeriodMonth | EstimatedJobCount\n"
                    "  | EstimatedNetFees | EstimatedMarginDollars\n"
                    "  | MedianPct50Date | MedianPct100Date", size=11),
            ]
        },
    ]


# ── File writers ──────────────────────────────────────────────

def write_json(path, obj, indent=2):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=indent)


def write_model_bim(sm_dir, server, database):
    tables = build_tables(server, database)
    model = {
        "name": "SemanticModel",
        "compatibilityLevel": 1550,
        "model": {
            "culture": "en-US",
            "dataAccessOptions": {
                "legacyRedirects": True,
                "returnErrorValuesAsNull": True
            },
            "defaultPowerBIDataSourceVersion": "powerBI_V3",
            "sourceQueryCulture": "en-US",
            "dataSources": [{
                "type": "structured",
                "name": f"SqlServer {server} {database}",
                "connectionDetails": {
                    "protocol": "tds",
                    "address": {"server": server, "database": database},
                    "authentication": None,
                    "query": None
                },
                "options": {},
                "credential": {
                    "AuthenticationKind": "Windows",
                    "kind": "SQL",
                    "path": f"{server};{database}",
                    "EncryptConnection": False
                }
            }],
            "tables": tables,
            "relationships": RELATIONSHIPS,
            "cultures": [{
                "name": "en-US",
                "linguisticMetadata": {
                    "content": {"Version": "1.0.0", "Language": "en-US"},
                    "contentType": "json"
                }
            }],
            "annotations": [{
                "name": "PBI_QueryOrder",
                "value": json.dumps([t["name"] for t in tables])
            }]
        }
    }
    path = sm_dir / "model.bim"
    write_json(path, model)
    return len(tables), path


def write_report_json(report_dir):
    pages = build_report_pages()
    report = {
        "id": "00000000-0000-0000-0000-000000000001",
        "resourcePackages": [],
        "sections": pages,
        "config": json.dumps({
            "version": "5.43",
            "themeCollection": {
                "baseTheme": {"name": "CY24SU06", "version": "5.43", "type": 2}
            }
        }),
        "layoutOptimization": 0
    }
    path = report_dir / "report.json"
    write_json(path, report)
    return len(pages), path


# ── Main ──────────────────────────────────────────────────────

def main():
    args = parse_args()
    server   = args.server
    database = DATABASE
    out_dir  = Path(args.output)

    sm_dir     = out_dir / "PipelineAnalytics.SemanticModel"
    report_dir = out_dir / "PipelineAnalytics.Report"

    sm_dir.mkdir(parents=True, exist_ok=True)
    report_dir.mkdir(parents=True, exist_ok=True)

    print(f"\nHorizon Data Predictive Model — Dashboard Script")
    print(f"{'=' * 52}")
    print(f"SQL Server : {server}")
    print(f"Database   : {database}")
    print(f"Output     : {out_dir}\n")

    # .pbip project file
    pbip_path = out_dir / "PipelineAnalytics.pbip"
    write_json(pbip_path, {
        "version": "1.0",
        "artifacts": [{"report": {"path": "PipelineAnalytics.Report"}}],
        "settings": {}
    })
    print(f"  \u2713 {pbip_path.name}")

    # Semantic model definition
    write_json(sm_dir / "definition.pbism", {"version": "4.0", "settings": {}})
    print(f"  \u2713 PipelineAnalytics.SemanticModel/definition.pbism")

    # model.bim (tables, relationships, measures)
    n_tables, bim_path = write_model_bim(sm_dir, server, database)
    size_kb = bim_path.stat().st_size // 1024
    print(f"  \u2713 PipelineAnalytics.SemanticModel/model.bim  "
          f"({n_tables} tables, {size_kb} KB)")

    # Report definition
    write_json(report_dir / "definition.pbir", {
        "version": "4.0",
        "datasetReference": {
            "byPath": {"path": "../PipelineAnalytics.SemanticModel"}
        }
    })
    print(f"  \u2713 PipelineAnalytics.Report/definition.pbir")

    # report.json (pages + visuals)
    n_pages, _ = write_report_json(report_dir)
    print(f"  \u2713 PipelineAnalytics.Report/report.json  ({n_pages} pages)\n")

    print("Done. Next steps:")
    print("  1. Open powerbi/PipelineAnalytics.pbip in Power BI Desktop")
    print("  2. Click Refresh in the Home ribbon to load data")
    print("  3. Add visuals to each page following the on-page layout guides")
    print(f"\n  To regenerate after changes:")
    print(f"  python {Path(__file__).name} --server \"{server}\"")


if __name__ == "__main__":
    main()
