###############################################################################
# GENERALIZED QUARTERLY REVENUE FORECAST
#
# Generalization of the securities forecast (see `current_version`).
# The methodology is unchanged; everything that was hardcoded for the
# June 2026 securities run (file paths, row numbers, years, driver names,
# product columns) is now either set in the CONFIG block below or derived
# from the data itself, so the same code can forecast ANY revenue series.
#
# Methodology (same as the original):
#   1. Load monthly actuals, aggregate to quarterly, merge with the
#      quarterly exogenous driver files (e.g. ERFC BCxxxx / BCxxxxW).
#   2. STL-decompose the target series and detect structural breaks
#      (breakpoints on level ~ trend + quarter). Keep the post-break sample.
#   3. Method A - "sales ratio" rule of thumb:
#        annual totals of the post-break sample -> centered-trend linear
#        regression -> annual forecasts; quarterly path from the average
#        cumulative within-year sales ratios of the last N complete years.
#        If the last actual year is incomplete, its annual total is
#        estimated as cum_sales / cum_sales_ratio at the last actual quarter.
#   4. Method B - multiple regression of the target on the exogenous
#      drivers + pulse dummies at the detected break dates + quarter
#      dummies; predict over the future quarters (drivers must extend
#      through the forecast horizon, as the ERFC files do).
#   5. Final forecast = weighted average of A and B (default 50/50).
#   6. Allocate the total to component series (products) using average
#      component shares per quarter over the last N complete years.
#   7. Add fiscal-year labels, roll up, and export.
#
# HOW TO REUSE FOR A NEW SERIES: edit the CONFIG block only -- or define a
# list named `config` with the same fields BEFORE source()ing this file,
# in which case the defaults below are skipped.
###############################################################################

### clear the space (skipped when a config is supplied externally)
if (!exists("config")) {
  cat("\014")
  rm(list = ls(all.names = TRUE))
}

### Load the packages
library(readxl)
library(writexl)
library(dplyr)
library(tidyr)
library(stringr)
library(zoo)          # as.yearqtr
library(strucchange)  # breakpoints()

###############################################################################
# CONFIG -- everything series-specific lives here
###############################################################################

if (!exists("config")) config <- list(

  ## ---- input files -------------------------------------------------------
  # Folder of the current forecast round (all inputs read / outputs written here)
  forecast_dir  = "C:/Users/AbdelmoumineT105/OneDrive - Washington State Executive Branch Agencies/Desktop/2024 -mid 2025/R_DFI/Securities Forecast/Jun_2026_forecast",

  # Monthly actuals workbook. Must contain a `Year:Quarter` column
  # (format "YYYY:Qq") plus the component columns below.
  actuals_file  = "Actuals.xlsx",
  actuals_sheet = 1,

  # Quarterly exogenous driver workbooks (any number of them). Their first
  # column is a date like "YYYY-MM-..." with quarter-start months 01/04/07/10.
  # They must extend through the forecast horizon (they carry the driver
  # projections used by the regression model).
  exogenous_files = list(
    list(file = "BC0526.xlsx",  sheet = 1, skip = 1),   # US drivers
    list(file = "BC0526W.xlsx", sheet = 1, skip = 1)    # WA drivers
  ),

  ## ---- series definition --------------------------------------------------
  # Component (product) columns in the actuals file, as they appear there.
  # The target = sum of these components. If your series has no components,
  # set component_cols = NULL and name the single revenue column target_col.
  component_cols = c("Total Registrations", "Total Exemptions & Opinions",
                     "Total Licensing", "Total Fran. & Bus Op."),

  # Name for the total series (also the column name if component_cols = NULL)
  target_col = "Total Revenue",

  # Exogenous regressors for the multiple-regression model
  # (must exist in the merged exogenous data after name cleaning)
  driver_vars = c("wl5000", "yp_wa", "csvfinfee", "savper", "lcbcai"),

  ## ---- forecast settings ---------------------------------------------------
  # Last quarter to forecast, "YYYY Qq". NULL = last row of the exogenous data.
  horizon_end = "2031 Q4",

  # Number of most recent COMPLETE years used to average the quarterly
  # sales ratios and the component shares (original code used 2).
  n_ratio_years = 2,

  # Ensemble weights: final = w * sales-ratio method + (1-w) * regression
  weight_sales_ratio = 0.5,

  # Quarter (calendar) in which the fiscal year starts: 3 = July (WA state).
  fy_start_quarter = 3,

  ## ---- optional: previous forecast round (for the driver-comparison export)
  # Set to NULL to skip that section.
  prev_forecast_dir   = "C:/Users/AbdelmoumineT105/OneDrive - Washington State Executive Branch Agencies/Desktop/2024 -mid 2025/R_DFI/Securities Forecast/Feb_2026_forecast",
  prev_actuals_file   = "Actuals.xlsx",
  prev_exogenous_files = list(
    list(file = "BC0126.xlsx",  sheet = 1, skip = 1),
    list(file = "BC0126W.xlsx", sheet = 1, skip = 1)
  ),

  # Show diagnostic plots (breakpoint plot etc.)
  make_plots = TRUE
)

###############################################################################
# HELPER FUNCTIONS
###############################################################################

# Read one exogenous workbook and add Year / Quarter / Year:Quarter columns
read_exogenous <- function(path, sheet = 1, skip = 1) {
  x <- read_excel(path, sheet = sheet, skip = skip)
  colnames(x)[1] <- "date"
  x <- x %>%
    mutate(
      Year    = substr(date, 1, 4),
      Quarter = substr(date, 6, 7),
      Quarter = case_when(
        Quarter == "01" ~ "Q1",
        Quarter == "04" ~ "Q2",
        Quarter == "07" ~ "Q3",
        Quarter == "10" ~ "Q4",
        TRUE ~ Quarter
      ),
      `Year:Quarter` = paste(Year, Quarter, sep = ":")
    )
  x
}

# Aggregate the monthly actuals to quarterly and build the target series
aggregate_actuals <- function(m_actuals, component_cols, target_col) {
  if (!is.null(component_cols)) {
    q <- m_actuals %>%
      group_by(`Year:Quarter`) %>%
      summarise(across(all_of(component_cols), ~ sum(.x, na.rm = FALSE)),
                .groups = "drop")
    q[[target_col]] <- rowSums(q[, component_cols])
  } else {
    q <- m_actuals %>%
      group_by(`Year:Quarter`) %>%
      summarise(across(all_of(target_col), ~ sum(.x, na.rm = FALSE)),
                .groups = "drop")
  }
  q
}

# Merge actuals with all exogenous files and clean the column names the same
# way the original code did (non-alphanumerics -> "_")
build_quarterly_data <- function(q_actuals, exo_list) {
  data <- q_actuals
  for (exo in exo_list) data <- merge(data, exo, by = "Year:Quarter", all = TRUE)
  colnames(data) <- gsub("[^[:alnum:]_]", "_", colnames(data))
  data %>%
    mutate(
      Year_Quarter = as.yearqtr(Year_Quarter, format = "%Y:Q%q"),
      year    = as.integer(format(Year_Quarter, "%Y")),
      quarter = as.integer(format(Year_Quarter, "%q"))
    ) %>%
    arrange(Year_Quarter)
}

# Add fiscal-year columns. fy_start_quarter = calendar quarter in which the
# fiscal year begins (3 -> FY runs Jul..Jun, the WA state convention).
add_fiscal_year <- function(data, fy_start_quarter) {
  data %>%
    mutate(
      q_int     = as.integer(as.character(quarter)),
      C_Year    = year,
      F_Year    = ifelse(q_int >= fy_start_quarter, C_Year + 1, C_Year),
      F_quarter = ifelse(q_int >= fy_start_quarter,
                         q_int - fy_start_quarter + 1,
                         q_int + (4 - fy_start_quarter) + 1)
    ) %>%
    select(-q_int)
}

###############################################################################
# 1. LOAD AND PREPARE THE DATA
###############################################################################

in_path <- function(f) file.path(config$forecast_dir, f)

m_actuals <- read_excel(in_path(config$actuals_file), sheet = config$actuals_sheet)

exo_list <- lapply(config$exogenous_files, function(e)
  read_exogenous(in_path(e$file), sheet = e$sheet, skip = e$skip))

q_actuals <- aggregate_actuals(m_actuals, config$component_cols, config$target_col)
data      <- build_quarterly_data(q_actuals, exo_list)

# Cleaned names of the target and component columns (as they exist in `data`)
target     <- gsub("[^[:alnum:]_]", "_", config$target_col)
components <- if (!is.null(config$component_cols))
                gsub("[^[:alnum:]_]", "_", config$component_cols) else NULL

### Critical points in the dataset (derived, not hardcoded)
first_row_actual <- which(!is.na(data[[target]]))[1]
last_row_actual  <- max(which(!is.na(data[[target]])))

horizon_end_yq <- if (!is.null(config$horizon_end))
  as.yearqtr(config$horizon_end, format = "%Y Q%q") else max(data$Year_Quarter)
last_row_forecast <- max(which(data$Year_Quarter <= horizon_end_yq))

stopifnot(last_row_forecast > last_row_actual)  # need future quarters to forecast

future_rows <- (last_row_actual + 1):last_row_forecast   # was 318:340
n_future_q  <- length(future_rows)                       # was 23

last_actual_yq   <- data$Year_Quarter[last_row_actual]
last_actual_year <- as.integer(format(last_actual_yq, "%Y"))
last_actual_qtr  <- as.integer(format(last_actual_yq, "%q"))

# Is the most recent actual year incomplete? (original: 2026 had only Q1)
last_year_complete   <- (last_actual_qtr == 4)
# First year excluded from ratio averaging / regression training
# (the original filtered year < 2026)
first_excluded_year  <- if (last_year_complete) last_actual_year + 1 else last_actual_year

###############################################################################
# 2. STL DECOMPOSITION AND STRUCTURAL BREAKS
###############################################################################

ts_target <- ts(data[[target]][first_row_actual:last_row_actual],
                frequency = 4,
                start = c(as.integer(format(data$Year_Quarter[first_row_actual], "%Y")),
                          as.integer(format(data$Year_Quarter[first_row_actual], "%q"))))

decomp <- stl(ts_target, s.window = "periodic")

data_sub <- data[first_row_actual:last_row_actual, ]
row.names(data_sub) <- NULL
data_sub$trend     <- as.numeric(decomp$time.series[, "trend"])
data_sub$seasonal  <- as.numeric(decomp$time.series[, "seasonal"])
data_sub$remainder <- as.numeric(decomp$time.series[, "remainder"])
data_sub$quarter   <- as.factor(data_sub$quarter)

bp <- breakpoints(as.formula(paste(target, "~ trend + quarter")), data = data_sub)
print(summary(bp))
if (config$make_plots) plot(bp)

break_rows_sub <- bp$breakpoints
has_breaks     <- !any(is.na(break_rows_sub)) && length(break_rows_sub) > 0

if (has_breaks) {
  break_dates <- data_sub$Year_Quarter[break_rows_sub]
  cat("Structural breaks detected at:", format(break_dates), "\n")
  last_break_row_sub <- tail(break_rows_sub, 1)          # was row 293 in `data`
} else {
  break_dates <- as.yearqtr(character(0))
  cat("No structural breaks detected; using the full actual sample.\n")
  last_break_row_sub <- 1
}

# Post-break estimation sample (the original's data_sub_final)
data_sub_final <- data_sub[last_break_row_sub:nrow(data_sub), ]
row.names(data_sub_final) <- NULL

###############################################################################
# 3. METHOD A -- SALES-RATIO RULE OF THUMB
###############################################################################

forecast_tab <- data.frame(
  Year_Quarter = data_sub_final$Year_Quarter,
  Actual       = data_sub_final[[target]]
)
n_actual_q <- nrow(forecast_tab)                          # was 25

fts <- forecast_tab %>%
  mutate(
    Year    = as.numeric(format(Year_Quarter, "%Y")),
    Quarter = paste0("Q", format(Year_Quarter, "%q"))
  ) %>%
  arrange(Year_Quarter) %>%
  group_by(Year) %>%
  mutate(
    annual_total    = sum(Actual, na.rm = TRUE),
    sales_ratio     = Actual / annual_total,
    cum_sales_ratio = cumsum(sales_ratio),
    cum_sales       = cumsum(Actual)
  ) %>%
  ungroup()

## Average (plain and cumulative) sales ratios per quarter over the last
## n_ratio_years COMPLETE years
last_n_years <- fts %>%
  filter(Year < first_excluded_year) %>%
  filter(Year %in% tail(sort(unique(Year)), config$n_ratio_years))

avg_ratio <- last_n_years %>%
  group_by(Quarter) %>%
  summarise(Avg_Sales_Ratio     = mean(sales_ratio),
            avg_cum_sales_ratio = mean(cum_sales_ratio), .groups = "drop")

fts$sales_ratio_forecast <- avg_ratio$Avg_Sales_Ratio[match(fts$Quarter, avg_ratio$Quarter)]
fts$cum_sales_ratio_forecast <- avg_ratio$avg_cum_sales_ratio[match(fts$Quarter, avg_ratio$Quarter)]

## Annual totals of the post-break sample
forecast_tab_annual <- fts %>%
  group_by(Year) %>%
  summarise(Annual_Revenue = sum(Actual, na.rm = TRUE), .groups = "drop") %>%
  mutate(Year = as.numeric(Year))

## If the last actual year is incomplete, estimate its full-year total from
## the cumulative sales ratio (original: forecast_tab_annual[7,2] <- ...)
if (!last_year_complete) {
  i_last <- n_actual_q                                    # last actual row in fts
  forecast_tab_annual$Annual_Revenue[forecast_tab_annual$Year == last_actual_year] <-
    fts$cum_sales[i_last] / fts$cum_sales_ratio_forecast[i_last]
}

## Centered-trend linear regression on the annual totals
n_obs <- nrow(forecast_tab_annual)
if (n_obs %% 2 == 0) {
  trend_centered <- seq(from = -(n_obs - 1), to = n_obs - 1, by = 2)
  trend_step <- 2
} else {
  trend_centered <- seq(from = -(n_obs - 1) / 2, to = (n_obs - 1) / 2, by = 1)
  trend_step <- 1
}
forecast_tab_annual$trend_centered <- trend_centered

annual_model <- lm(Annual_Revenue ~ trend_centered, data = forecast_tab_annual)
coeffmodel   <- coef(annual_model)

## Extend the annual table through the horizon (was forecast_steps <- 5)
horizon_year   <- as.integer(format(horizon_end_yq, "%Y"))
forecast_steps <- horizon_year - max(forecast_tab_annual$Year)

if (forecast_steps > 0) {
  future_annual <- data.frame(
    Year           = max(forecast_tab_annual$Year) + seq_len(forecast_steps),
    Annual_Revenue = NA_real_,
    trend_centered = max(forecast_tab_annual$trend_centered) + trend_step * seq_len(forecast_steps)
  )
  future_annual$Annual_Revenue <- coeffmodel[1] + coeffmodel[2] * future_annual$trend_centered
  forecast_tab_annual <- bind_rows(forecast_tab_annual, future_annual)
}

## Extend the quarterly table through the horizon (was rows 26:48)
future_quarters <- seq(from = last_actual_yq + 1/4, to = horizon_end_yq, by = 1/4)

fts_future <- data.frame(Year_Quarter = future_quarters) %>%
  mutate(
    Actual  = NA_real_,
    Year    = as.numeric(format(Year_Quarter, "%Y")),
    Quarter = paste0("Q", format(Year_Quarter, "%q"))
  )
fts <- bind_rows(fts, fts_future)

fts$annual_total_forecast <- forecast_tab_annual$Annual_Revenue[
  match(fts$Year, forecast_tab_annual$Year)]
fts$cum_sales_ratio_forecast <- avg_ratio$avg_cum_sales_ratio[
  match(fts$Quarter, avg_ratio$Quarter)]
fts$sales_ratio_forecast <- avg_ratio$Avg_Sales_Ratio[
  match(fts$Quarter, avg_ratio$Quarter)]

## Quarterly forecast from the cumulative ratios: Q1 gets annual * cum(Q1);
## later quarters get the difference of the cumulated amounts.
fts$Total_forecast <- fts$Actual                          # actuals kept as-is
for (i in (n_actual_q + 1):nrow(fts)) {
  if (fts$Quarter[i] == "Q1") {
    fts$Total_forecast[i] <- fts$annual_total_forecast[i] * fts$cum_sales_ratio_forecast[i]
  } else {
    fts$Total_forecast[i] <- fts$annual_total_forecast[i]     * fts$cum_sales_ratio_forecast[i] -
                             fts$annual_total_forecast[i - 1] * fts$cum_sales_ratio_forecast[i - 1]
  }
}

## Collect Method A into forecast_tab (actuals + future quarters)
forecast_tab <- bind_rows(
  forecast_tab,
  data.frame(Year_Quarter = future_quarters, Actual = NA_real_)
)
forecast_tab$avg_sales_ratio <- fts$Total_forecast

###############################################################################
# 4. METHOD B -- MULTIPLE REGRESSION ON EXOGENOUS DRIVERS
###############################################################################

data$quarter     <- as.factor(data$quarter)
data$dummy_break <- 0
if (has_breaks) {
  data$dummy_break[data$Year_Quarter %in% break_dates] <- 1   # was rows 214/244/293
}

## Training sample: actual quarters, excluding the incomplete final year
## (was: drop_na(Total_Revenue) %>% filter(year < 2026))
train_data <- data %>%
  filter(!is.na(.data[[target]]), year < first_excluded_year)

reg_formula <- as.formula(paste(
  target, "~",
  paste(config$driver_vars, collapse = " + "),
  "+ dummy_break + factor(quarter)"
))
multi_reg <- lm(reg_formula, data = train_data)
print(summary(multi_reg))

## Predict the future quarters (drivers must be populated there)
future_data_sub <- data[future_rows, c(config$driver_vars, "dummy_break", "quarter")]
reg_forecast    <- predict(multi_reg, newdata = future_data_sub)

data$multireg_target <- data[[target]]
data$multireg_target[future_rows] <- reg_forecast

## Align with forecast_tab: rows last_break .. horizon (was data[293:340,])
forecast_tab$multi_reg <- data$multireg_target[
  (first_row_actual + last_break_row_sub - 1):last_row_forecast]

###############################################################################
# 5. ENSEMBLE FORECAST
###############################################################################

w <- config$weight_sales_ratio
forecast_tab$avg <- w * forecast_tab$avg_sales_ratio + (1 - w) * forecast_tab$multi_reg

## Write the combined forecast back into the master data
future_rows_tab <- (n_actual_q + 1):nrow(forecast_tab)
data[[target]][future_rows] <- forecast_tab$avg[future_rows_tab]

###############################################################################
# 6. ALLOCATE THE TOTAL TO THE COMPONENT SERIES
###############################################################################

if (!is.null(components)) {
  # Component shares of the total, per quarter, averaged over the last
  # n_ratio_years complete years
  share_data <- data %>%
    filter(!is.na(.data[[target]]), year < first_excluded_year) %>%
    filter(year %in% tail(sort(unique(year)), config$n_ratio_years))

  for (comp in components) {
    shares <- share_data %>%
      mutate(share = .data[[comp]] / .data[[target]]) %>%
      group_by(quarter) %>%
      summarise(avg_share = mean(share), .groups = "drop")

    share_fc <- shares$avg_share[match(data$quarter, shares$quarter)]
    data[[comp]][future_rows] <- data[[target]][future_rows] * share_fc[future_rows]
  }
}

###############################################################################
# 7. FISCAL YEAR, ROLL-UPS AND EXPORT
###############################################################################

data <- add_fiscal_year(data, config$fy_start_quarter)
data_final <- data

data_drivers <- data_final[, c("F_Year", "F_quarter", config$driver_vars,
                               "dummy_break", "quarter")]

target_by_F_year <- data_final %>%
  group_by(F_Year) %>%
  summarise(!!target := sum(.data[[target]]), .groups = "drop")
print(as.data.frame(target_by_F_year))

write_xlsx(data_final,   in_path("data_final.xlsx"))
write_xlsx(data_drivers, in_path("data_drivers.xlsx"))
write_xlsx(forecast_tab, in_path("forecast_tab.xlsx"))

###############################################################################
# 8. OPTIONAL -- DRIVERS FROM THE PREVIOUS FORECAST ROUND (for comparison)
###############################################################################

if (!is.null(config$prev_forecast_dir)) {
  prev_path <- function(f) file.path(config$prev_forecast_dir, f)

  m_prev <- read_excel(prev_path(config$prev_actuals_file), sheet = config$actuals_sheet)
  exo_prev <- lapply(config$prev_exogenous_files, function(e)
    read_exogenous(prev_path(e$file), sheet = e$sheet, skip = e$skip))

  q_prev    <- aggregate_actuals(m_prev, config$component_cols, config$target_col)
  data_prev <- build_quarterly_data(q_prev, exo_prev)
  data_prev <- add_fiscal_year(data_prev, config$fy_start_quarter)

  data_drivers_old <- data_prev[, c("F_Year", "F_quarter", config$driver_vars, "quarter")]
  write_xlsx(data_drivers_old, in_path("data_drivers_old.xlsx"))
}

cat("\nForecast complete:", target, "through", format(horizon_end_yq), "\n")
