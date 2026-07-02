# Generalized Quarterly Revenue Forecast

This repository contains two versions of the same forecasting methodology:

| File | Description |
|---|---|
| `current_version` | Original script, hardwired to the securities revenue forecast (June 2026 round) |
| `generalized_revenue_forecast.R` | Generalized script — same methodology, applicable to **any quarterly revenue series** |

## Methodology (unchanged from the original)

1. **Data preparation** — monthly actuals are aggregated to quarters and merged
   with quarterly exogenous driver files (e.g. ERFC `BCxxxx` / `BCxxxxW`
   workbooks, which carry driver projections through the forecast horizon).
2. **Structural breaks** — the target series is STL-decomposed and
   `strucchange::breakpoints()` is run on `level ~ trend + quarter`. The sample
   after the last break is used for estimation (if no break is found, the full
   sample is used).
3. **Method A — sales-ratio rule of thumb** — annual totals of the post-break
   sample are regressed on a centered linear trend to project annual revenue;
   the quarterly path is derived from average *cumulative* within-year sales
   ratios over the last N complete years. If the latest year is incomplete,
   its annual total is estimated as `cumulative sales / cumulative sales ratio`
   at the last actual quarter.
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

  # monthly actuals: must contain a `Year:Quarter` column ("YYYY:Qq")
  actuals_file  = "Actuals.xlsx",
  actuals_sheet = 1,

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
  weight_sales_ratio = 0.5,        # ensemble weight on Method A
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

## Requirements

```r
install.packages(c("readxl", "writexl", "dplyr", "tidyr",
                   "stringr", "zoo", "strucchange"))
```

(The generalized script no longer needs `lightgbm`, `vars`, `caret`, `plm`,
`fable`, etc. — only the packages actually used by the methodology.)

## To reproduce the June 2026 securities forecast

The default `config` in `generalized_revenue_forecast.R` is set to the same
inputs as `current_version` (June 2026 securities round), so running it
unchanged reproduces that forecast.
