# Generalized Quarterly Revenue Forecast

This repository contains two versions of the same forecasting methodology:

| File | Description |
|---|---|
| `current_version` | Original script, hardwired to the securities revenue forecast (June 2026 round) |
| `generalized_revenue_forecast.R` | Generalized script — same methodology, applicable to **any quarterly revenue series** |
| `run_batch_forecast.R` | Batch runner — forecasts **several revenue streams in one run** using the generalized script |
| `driver_selection.R` | Finds the **best set of drivers** for a stream's multi-regression, judged out of sample on a train/test split |

## Methodology (unchanged from the original)

1. **Data preparation** — actuals are brought to quarterly form (monthly files
   are aggregated to quarters; files that are already quarterly are used
   as-is, see `actuals_frequency`) and merged with quarterly exogenous driver
   files (e.g. ERFC `BCxxxx` / `BCxxxxW` workbooks, which carry driver
   projections through the forecast horizon).
2. **Structural breaks** — the target series is STL-decomposed and
   `strucchange::breakpoints()` is run on `level ~ trend + quarter`. The sample
   after the last break is used for estimation (if no break is found, the full
   sample is used).
3. **Method A — sales-ratio rule of thumb** — annual totals of the post-break
   sample are projected forward with a trend model (`trend_method`): a
   **damped trend** by default, which keeps the trend's direction but flattens
   it over time (the year-over-year increment shrinks by a factor `damping_phi`
   each year) so long-horizon forecasts don't run away, or the original
   **linear** centered-trend regression (equivalently `damping_phi = 1`). The
   quarterly
   path is derived from average *cumulative* within-year sales ratios over the
   last N complete years. If the latest year is incomplete, its annual total
   is estimated as `cumulative sales / cumulative sales ratio` at the last
   actual quarter.
4. **Method B — multiple regression** — the target is regressed on the
   exogenous drivers, pulse dummies at the detected break dates, and quarter
   dummies; the fitted model predicts the future quarters using the projected
   drivers.
5. **Ensemble** — the final forecast is a weighted average of A and B
   (default 50/50).
6. **Component allocation** — the forecast total is split into component
   (product) series using average per-quarter component shares over the last
   N complete years.
7. **Fiscal-year rollup and export** — fiscal-year labels are added and
   `data_final.xlsx`, `data_drivers.xlsx` and `forecast_tab.xlsx` are written
   to the forecast folder. Optionally, drivers from the previous forecast
   round are exported for comparison (`data_drivers_old.xlsx`).

## How to apply it to a new series

Edit only the `config` block at the top of `generalized_revenue_forecast.R`
(or define a list named `config` before `source()`-ing the file — the built-in
defaults are then skipped):

```r
config <- list(
  # where the input files live and outputs are written
  forecast_dir  = "path/to/this/forecast/round",

  # actuals: must contain a `Year:Quarter` column ("YYYY:Qq")
  actuals_file  = "Actuals.xlsx",
  actuals_sheet = 1,

  # "monthly" = sum rows into quarters; "quarterly" = the file is already
  # one row per quarter, use it without aggregation
  actuals_frequency = "monthly",

  # any number of quarterly driver files; first column is a date whose
  # quarter-start months are 01/04/07/10; must extend through the horizon
  exogenous_files = list(
    list(file = "BC0526.xlsx",  sheet = 1, skip = 1),
    list(file = "BC0526W.xlsx", sheet = 1, skip = 1)
  ),

  # component columns in the actuals file; the target is their sum.
  # Use NULL if the series has no components (then target_col must be a
  # column of the actuals file itself).
  component_cols = c("Total Registrations", "Total Exemptions & Opinions",
                     "Total Licensing", "Total Fran. & Bus Op."),
  target_col     = "Total Revenue",

  # regressors for the multiple-regression model (names as they appear in
  # the driver files after cleaning: non-alphanumerics become "_")
  driver_vars = c("wl5000", "yp_wa", "csvfinfee", "savper", "lcbcai"),

  horizon_end        = "2031 Q4",  # NULL = last quarter of the driver files
  n_ratio_years      = 2,          # complete years used for ratio averaging
  trend_method       = "damped",   # annual-trend extrapolation: "damped" or "linear"
  damping_phi        = 0.9,        # damped-trend flattening factor in (0,1]; 1 = linear

  # which methods to run: "sales_ratio", "multi_reg", or both (the default).
  # With one method, it alone is the final forecast; driver_vars is only
  # needed when "multi_reg" is active.
  methods            = c("sales_ratio", "multi_reg"),
  weight_sales_ratio = 0.5,        # ensemble weight on Method A (both active)
  fy_start_quarter   = 3,          # 3 = July (WA state); 4 = October (federal)

  # previous forecast round (driver comparison); NULL to skip
  prev_forecast_dir    = "path/to/previous/round",
  prev_actuals_file    = "Actuals.xlsx",
  prev_exogenous_files = list(
    list(file = "BC0126.xlsx",  sheet = 1, skip = 1),
    list(file = "BC0126W.xlsx", sheet = 1, skip = 1)
  ),

  make_plots = TRUE
)
```

Everything that was hardcoded in `current_version` is now derived from the
data or the config:

| Original hardcoding | Generalized as |
|---|---|
| Windows file paths for the June 2026 round | `forecast_dir` + file names in config |
| 4 securities product columns | `component_cols` (any number, or `NULL`) |
| Drivers `wl5000, yp_wa, csvfinfee, savper, lcbcai` | `driver_vars` |
| Rows `25`, `26:48`, `318:340` | computed from the first/last actual quarter and the horizon |
| Break-dummy rows `214/244/293` | rows matching the dates found by `breakpoints()` |
| `filter(Year < 2026)` (exclude partial year) | detected automatically from the last actual quarter |
| `forecast_tab_annual[7,2] <- ...[25,10]/...[25,9]` (partial-year estimate) | applied automatically when the last actual year is incomplete |
| `forecast_steps <- 5`, `"2031 Q4"` | derived from `horizon_end` |
| Last-2-years ratio averaging | `n_ratio_years` |
| 50/50 ensemble | `weight_sales_ratio` |
| July–June fiscal year | `fy_start_quarter` |

## Forecasting several revenue streams in one run

Use `run_batch_forecast.R` instead of running the single-series script once
per stream. Define the settings shared by all streams once, then list only
the per-stream differences:

```r
shared <- list(
  forecast_dir  = base_dir,
  exogenous_files = list(...),      # same driver files for all streams
  horizon_end = "2031 Q4", n_ratio_years = 2,
  weight_sales_ratio = 0.5, fy_start_quarter = 3,
  # previous round (old-driver export); override prev_forecast_dir = NULL
  # in a stream's entry to skip it for that stream
  prev_forecast_dir    = prev_base_dir,
  prev_actuals_file    = "Actuals.xlsx",
  prev_exogenous_files = list(...), # previous round's driver files
  make_plots = FALSE, actuals_sheet = 1
)

streams <- list(
  securities = modifyList(shared, list(
    actuals_file   = "Actuals.xlsx",
    component_cols = c("Total Registrations", "Total Exemptions & Opinions",
                       "Total Licensing", "Total Fran. & Bus Op."),
    target_col     = "Total Revenue",
    driver_vars    = c("wl5000", "yp_wa", "csvfinfee", "savper", "lcbcai"),
    output_prefix  = "securities_"
  )),
  consumer_services = modifyList(shared, list(
    actuals_file   = "Actuals_consumer.xlsx",
    component_cols = NULL,
    target_col     = "Total Revenue",
    driver_vars    = c("yp_wa", "savper"),
    actuals_frequency = "quarterly",   # already quarterly: no aggregation
    output_prefix  = "consumer_"
  ))
  # ... add as many streams as needed
)
```

Each stream runs in its own clean R environment (no leakage between
streams), writes its own prefixed outputs (`securities_data_final.xlsx`,
`consumer_forecast_tab.xlsx`, ...), and at the end a single
`combined_forecasts.xlsx` is written with one column per stream — by fiscal
year (including an `All_Streams` grand total) and by quarter. Streams can
differ in anything the config supports: different actuals files, monthly or
quarterly frequency, components (or none), drivers, methods (e.g. one stream
sales-ratio-only, another with the full ensemble), ensemble weights, or
horizons.

## Finding the best drivers for a stream

`driver_selection.R` answers "which drivers should `driver_vars` contain?"
for any revenue stream. It shares the forecast script's data pipeline and
config style (inject a `config` list before `source()` to run it
programmatically, e.g. in a loop over streams):

1. Builds the quarterly dataset from the actuals and driver files.
2. Detects structural breaks in the stream (same STL + `breakpoints()`
   approach as the forecast) and creates a pulse dummy at the break dates.
3. Splits the actual quarters chronologically into a training window
   (`train_share`, default 80%, or an explicit `train_end = "YYYY Qq"`) and
   a held-out test window.
4. Fits `target ~ drivers + dummy_break + factor(quarter)` (quarter fixed
   effects) on the training window for **every combination** of candidate
   drivers up to `max_drivers`, and forecasts the test window.
   Candidates come from `candidate_drivers`, or with `NULL` every numeric
   column of the driver files (columns with gaps or no variation over the
   actual window are dropped automatically).
5. Ranks all models (plus a no-driver quarter-FE baseline) by test RMSE
   — also reporting MAE, MAPE and train adjusted R² — prints the top
   models, refits the winner on the full actual sample, and writes
   `driver_selection_results.xlsx` (ranking, best-model coefficients,
   split settings).

The winning set is printed ready to paste into the forecast config:
`driver_vars = c("wl5000", "yp_wa")`. Check the coefficient sheet before
adopting it: a driver that helps test RMSE but has an insignificant
coefficient in the full-sample refit is usually worth dropping.

## Requirements

```r
install.packages(c("readxl", "writexl", "dplyr", "tidyr",
                   "stringr", "zoo", "strucchange"))
```

The generalized script no longer needs `lightgbm`, `vars`, `caret`, `plm`,
`fable`, etc. — only the packages actually used by the methodology. (The
damped trend is computed directly, so no extra package is required.)

## To reproduce the June 2026 securities forecast

The default `config` in `generalized_revenue_forecast.R` uses the same inputs
as `current_version` (June 2026 securities round). Note the annual trend now
defaults to `trend_method = "damped"`; set `trend_method = "linear"` to
reproduce the original straight-line extrapolation exactly.
