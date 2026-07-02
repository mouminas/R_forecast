###############################################################################
# BATCH REVENUE FORECAST
#
# Forecast SEVERAL revenue streams with the same methodology in ONE run,
# instead of editing and re-running generalized_revenue_forecast.R once per
# stream. Each stream gets its own config (same fields as the config block
# of generalized_revenue_forecast.R); settings shared by all streams are
# defined once in `shared` and only the differences are listed per stream.
#
# Each stream is run in its own clean environment, so nothing leaks from one
# stream to the next. Per-stream outputs are written with the stream's
# output_prefix (securities_data_final.xlsx, ...), and a combined workbook
# `combined_forecasts.xlsx` is written at the end with:
#   - one column per stream, by fiscal year (plus a grand total)
#   - one column per stream, by quarter (ensemble forecast)
#
# HOW TO USE: edit `forecast_script`, `shared`, and `streams` below, then
# source this file. Add as many streams as you need.
###############################################################################

cat("\014")
rm(list = ls(all.names = TRUE))

library(dplyr)
library(zoo)
library(writexl)

# Path to the generalized single-series forecast script
forecast_script <- "generalized_revenue_forecast.R"

###############################################################################
# SHARED SETTINGS -- everything that is the same for all streams
###############################################################################

base_dir      <- "C:/Users/AbdelmoumineT105/OneDrive - Washington State Executive Branch Agencies/Desktop/2024 -mid 2025/R_DFI/Securities Forecast/Jun_2026_forecast"
prev_base_dir <- "C:/Users/AbdelmoumineT105/OneDrive - Washington State Executive Branch Agencies/Desktop/2024 -mid 2025/R_DFI/Securities Forecast/Feb_2026_forecast"

shared <- list(
  forecast_dir  = base_dir,
  actuals_sheet = 1,
  actuals_frequency = "monthly",   # override per stream if already quarterly
  exogenous_files = list(
    list(file = "BC0526.xlsx",  sheet = 1, skip = 1),
    list(file = "BC0526W.xlsx", sheet = 1, skip = 1)
  ),
  horizon_end        = "2031 Q4",
  n_ratio_years      = 2,
  weight_sales_ratio = 0.5,
  fy_start_quarter   = 3,

  ## previous forecast round: each stream exports its old drivers for
  ## comparison (<prefix>data_drivers_old.xlsx). To skip this for a stream,
  ## override with  prev_forecast_dir = NULL  in that stream's entry.
  prev_forecast_dir    = prev_base_dir,
  prev_actuals_file    = "Actuals.xlsx",   # override per stream if it differs
  prev_exogenous_files = list(
    list(file = "BC0126.xlsx",  sheet = 1, skip = 1),
    list(file = "BC0126W.xlsx", sheet = 1, skip = 1)
  ),

  make_plots = FALSE   # keep FALSE in batch runs
)

###############################################################################
# STREAMS -- one entry per revenue stream; only the differences from `shared`
###############################################################################

streams <- list(

  securities = modifyList(shared, list(
    actuals_file   = "Actuals.xlsx",
    component_cols = c("Total Registrations", "Total Exemptions & Opinions",
                       "Total Licensing", "Total Fran. & Bus Op."),
    target_col     = "Total Revenue",
    driver_vars    = c("wl5000", "yp_wa", "csvfinfee", "savper", "lcbcai"),
    output_prefix  = "securities_"
  ))

  # , consumer_services = modifyList(shared, list(
  #     actuals_file   = "Actuals_consumer.xlsx",
  #     component_cols = NULL,                     # single-column series
  #     target_col     = "Total Revenue",
  #     driver_vars    = NULL,                     # not needed: sales ratio only
  #     methods        = "sales_ratio",            # skip the regression method
  #     actuals_frequency = "quarterly",           # already quarterly: no aggregation
  #     prev_actuals_file = "Actuals_consumer.xlsx",  # this stream's old actuals
  #     output_prefix  = "consumer_"
  # ))
  #
  # , banks = modifyList(shared, list(
  #     actuals_file   = "Actuals_banks.xlsx",
  #     component_cols = c("Assessments", "Exam Fees"),
  #     target_col     = "Total Revenue",
  #     driver_vars    = c("yp_wa", "lcbcai"),
  #     output_prefix  = "banks_"
  # ))
)

###############################################################################
# RUN ALL STREAMS
###############################################################################

run_one_stream <- function(name, cfg) {
  cat("\n=============================================================\n")
  cat("=== Forecasting stream:", name, "===\n")
  cat("=============================================================\n")
  env <- new.env(parent = globalenv())
  env$config <- cfg
  source(forecast_script, local = env)
  list(
    name           = name,
    forecast_tab   = env$forecast_tab,       # quarterly: actual, A, B, ensemble
    by_fiscal_year = env$target_by_F_year,   # fiscal-year totals
    data_final     = env$data_final          # full quarterly data incl. components
  )
}

results <- Map(run_one_stream, names(streams), streams)

###############################################################################
# COMBINED OUTPUTS
###############################################################################

# Fiscal-year totals: one column per stream + grand total
fy_combined <- results %>%
  lapply(function(r) setNames(r$by_fiscal_year, c("F_Year", r$name))) %>%
  Reduce(f = function(a, b) full_join(a, b, by = "F_Year")) %>%
  arrange(F_Year)
fy_combined$All_Streams <- rowSums(fy_combined[, names(streams), drop = FALSE])

# Quarterly ensemble forecast: one column per stream
q_combined <- results %>%
  lapply(function(r) setNames(r$forecast_tab[, c("Year_Quarter", "avg")],
                              c("Year_Quarter", r$name))) %>%
  Reduce(f = function(a, b) full_join(a, b, by = "Year_Quarter")) %>%
  arrange(Year_Quarter) %>%
  mutate(Year_Quarter = format(as.yearqtr(Year_Quarter)))

cat("\n=== Combined forecast by fiscal year ===\n")
print(as.data.frame(fy_combined))

write_xlsx(
  list(by_fiscal_year = fy_combined, by_quarter = q_combined),
  file.path(base_dir, "combined_forecasts.xlsx")
)

cat("\nBatch complete:", length(streams), "stream(s) forecast;",
    "combined workbook written to combined_forecasts.xlsx\n")
