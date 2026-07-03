###############################################################################
# GENERALIZED DRIVER SELECTION FOR REVENUE FORECASTING
#
# Companion to generalized_revenue_forecast.R: for a given revenue stream,
# find the set of exogenous drivers that best forecasts it with the
# multiple-regression method, judged OUT OF SAMPLE:
#
#   1. Load the actuals and driver files and build the quarterly dataset
#      (same pipeline and helpers as the forecast script).
#   2. Detect structural breaks in the revenue stream (STL trend + quarter,
#      strucchange::breakpoints) and create a pulse dummy at the break dates
#      - the same dummies the forecast script uses.
#   3. Split the actual quarters chronologically: the first part trains the
#      models, the last part is held out as the test set.
#   4. For every combination of candidate drivers (up to max_drivers), fit
#        target ~ drivers + dummy_break + factor(quarter)      [quarter FE]
#      on the training window and forecast the test window.
#   5. Rank all models by test RMSE (MAE, MAPE and train adj-R2 are also
#      reported), print the top models, refit the winner on the full actual
#      sample, and export everything to Excel.
#
# The winning driver set can be pasted straight into the `driver_vars`
# field of generalized_revenue_forecast.R / run_batch_forecast.R.
#
# HOW TO USE: edit the CONFIG block below - or define a list named `config`
# before source()ing this file (the defaults are then skipped), exactly like
# the forecast script. To scan several revenue streams, loop over configs
# the same way run_batch_forecast.R does.
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
# CONFIG
###############################################################################

if (!exists("config")) config <- list(

  ## ---- input files (same meaning as in generalized_revenue_forecast.R) ----
  forecast_dir  = "C:/Users/AbdelmoumineT105/OneDrive - Washington State Executive Branch Agencies/Desktop/2024 -mid 2025/R_DFI/Securities Forecast/Jun_2026_forecast",
  actuals_file  = "Actuals.xlsx",
  actuals_sheet = 1,
  actuals_frequency = "monthly",    # or "quarterly" (already one row/quarter)
  exogenous_files = list(
    list(file = "BC0526.xlsx",  sheet = 1, skip = 1),
    list(file = "BC0526W.xlsx", sheet = 1, skip = 1)
  ),

  ## ---- series definition ---------------------------------------------------
  component_cols = c("Total Registrations", "Total Exemptions & Opinions",
                     "Total Licensing", "Total Fran. & Bus Op."),
  target_col     = "Total Revenue",

  ## ---- candidate drivers ---------------------------------------------------
  # Explicit vector of driver names (after cleaning: non-alphanumerics -> _),
  # or NULL to consider EVERY numeric column of the exogenous files that has
  # no missing values over the actual window.
  candidate_drivers = NULL,

  ## ---- train / test split --------------------------------------------------
  # Share of the actual quarters used for training (chronological split)...
  train_share = 0.8,
  # ...or an explicit last training quarter "YYYY Qq" (overrides train_share)
  train_end   = NULL,

  ## ---- search settings -----------------------------------------------------
  max_drivers       = 4,      # largest driver-set size to try
  top_n             = 20,     # how many models to keep in the output
  max_models        = 20000,  # safety cap on the number of models to fit
  use_break_dummies = TRUE,   # pulse dummies at detected structural breaks

  ## ---- output ---------------------------------------------------------------
  output_file = "driver_selection_results.xlsx",
  make_plots  = FALSE
)

###############################################################################
# HELPER FUNCTIONS (identical to generalized_revenue_forecast.R)
###############################################################################

read_exogenous <- function(path, sheet = 1, skip = 1) {
  x <- read_excel(path, sheet = sheet, skip = skip)
  colnames(x)[1] <- "date"
  x %>%
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
}

aggregate_actuals <- function(m_actuals, component_cols, target_col,
                              frequency = "monthly") {
  value_cols <- if (!is.null(component_cols)) component_cols else target_col
  if (frequency == "quarterly") {
    if (any(duplicated(m_actuals$`Year:Quarter`))) {
      stop("actuals_frequency = \"quarterly\" but the actuals file has more ",
           "than one row per Year:Quarter - use \"monthly\" instead.")
    }
    q <- m_actuals[, c("Year:Quarter", value_cols)]
  } else if (frequency == "monthly") {
    q <- m_actuals %>%
      group_by(`Year:Quarter`) %>%
      summarise(across(all_of(value_cols), ~ sum(.x, na.rm = FALSE)),
                .groups = "drop")
  } else {
    stop("actuals_frequency must be \"monthly\" or \"quarterly\", got: ",
         frequency)
  }
  if (!is.null(component_cols)) q[[target_col]] <- rowSums(q[, component_cols])
  q
}

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

###############################################################################
# 1. LOAD AND PREPARE THE DATA
###############################################################################

in_path <- function(f) file.path(config$forecast_dir, f)

m_actuals <- read_excel(in_path(config$actuals_file), sheet = config$actuals_sheet)
exo_list  <- lapply(config$exogenous_files, function(e)
  read_exogenous(in_path(e$file), sheet = e$sheet, skip = e$skip))

actuals_freq <- if (!is.null(config$actuals_frequency))
  config$actuals_frequency else "monthly"

q_actuals <- aggregate_actuals(m_actuals, config$component_cols,
                               config$target_col, actuals_freq)
data      <- build_quarterly_data(q_actuals, exo_list)

target     <- gsub("[^[:alnum:]_]", "_", config$target_col)
components <- if (!is.null(config$component_cols))
                gsub("[^[:alnum:]_]", "_", config$component_cols) else NULL

## Actual window (rows where the target is observed)
first_row_actual <- which(!is.na(data[[target]]))[1]
last_row_actual  <- max(which(!is.na(data[[target]])))
data_sub <- data[first_row_actual:last_row_actual, ]
row.names(data_sub) <- NULL
n_act <- nrow(data_sub)

###############################################################################
# 2. STRUCTURAL BREAKS AND PULSE DUMMIES
###############################################################################

data_sub$dummy_break <- 0
break_dates <- as.yearqtr(character(0))

if (isTRUE(config$use_break_dummies)) {
  ts_target <- ts(data_sub[[target]], frequency = 4,
                  start = c(as.integer(format(data_sub$Year_Quarter[1], "%Y")),
                            as.integer(format(data_sub$Year_Quarter[1], "%q"))))
  decomp <- stl(ts_target, s.window = "periodic")
  bp_dat <- data_sub
  bp_dat$trend   <- as.numeric(decomp$time.series[, "trend"])
  bp_dat$quarter <- as.factor(bp_dat$quarter)

  bp <- breakpoints(as.formula(paste(target, "~ trend + quarter")), data = bp_dat)
  if (isTRUE(config$make_plots)) plot(bp)

  if (!any(is.na(bp$breakpoints)) && length(bp$breakpoints) > 0) {
    break_dates <- data_sub$Year_Quarter[bp$breakpoints]
    data_sub$dummy_break[bp$breakpoints] <- 1
    cat("Structural breaks detected at:", format(break_dates), "\n")
  } else {
    cat("No structural breaks detected.\n")
  }
}

###############################################################################
# 3. TRAIN / TEST SPLIT (chronological)
###############################################################################

if (!is.null(config$train_end)) {
  train_end_yq <- as.yearqtr(config$train_end, format = "%Y Q%q")
  n_train <- sum(data_sub$Year_Quarter <= train_end_yq)
} else {
  n_train <- floor(config$train_share * n_act)
}
if (n_train < 12 || n_act - n_train < 4) {
  stop("Split leaves too little data: ", n_train, " training and ",
       n_act - n_train, " test quarters (need >= 12 and >= 4). ",
       "Adjust train_share / train_end.")
}

train_idx <- seq_len(n_train)
test_idx  <- (n_train + 1):n_act
cat("Training: ", format(data_sub$Year_Quarter[1]), "-",
    format(data_sub$Year_Quarter[n_train]), " (", n_train, " quarters)\n",
    "Test:     ", format(data_sub$Year_Quarter[n_train + 1]), "-",
    format(data_sub$Year_Quarter[n_act]), " (", n_act - n_train,
    " quarters)\n", sep = "")

## A pulse dummy is only estimable if a break falls inside the training
## window; otherwise it is dropped from the models (with a note).
use_dummy <- isTRUE(config$use_break_dummies) &&
  sum(data_sub$dummy_break[train_idx]) > 0
if (isTRUE(config$use_break_dummies) && !use_dummy) {
  cat("Note: no break falls in the training window; dummy_break dropped.\n")
}

###############################################################################
# 4. CANDIDATE DRIVERS
###############################################################################

if (!is.null(config$candidate_drivers)) {
  candidates <- gsub("[^[:alnum:]_]", "_", config$candidate_drivers)
  missing <- setdiff(candidates, colnames(data_sub))
  if (length(missing) > 0) {
    stop("candidate_drivers not found in the data: ",
         paste(missing, collapse = ", "),
         "\nAvailable columns: ",
         paste(setdiff(colnames(data_sub),
                       c(target, components)), collapse = ", "))
  }
} else {
  # every numeric exogenous column, excluding the series itself and the
  # bookkeeping columns created by the merge
  bookkeeping <- c(target, components, "Year_Quarter", "year", "quarter",
                   "dummy_break",
                   grep("^(date|Year|Quarter)", colnames(data_sub), value = TRUE))
  candidates <- setdiff(colnames(data_sub), bookkeeping)
  candidates <- candidates[sapply(data_sub[candidates], is.numeric)]
}

## Drop candidates with missing values or no variation over the actual window
bad_na  <- candidates[sapply(data_sub[candidates], function(x) any(is.na(x)))]
bad_var <- candidates[sapply(data_sub[candidates],
                             function(x) length(unique(x)) < 2)]
if (length(c(bad_na, bad_var)) > 0) {
  cat("Dropped candidates (missing values or constant):",
      paste(unique(c(bad_na, bad_var)), collapse = ", "), "\n")
}
candidates <- setdiff(candidates, c(bad_na, bad_var))
if (length(candidates) == 0) stop("No usable candidate drivers.")
cat("Candidate drivers (", length(candidates), "): ",
    paste(candidates, collapse = ", "), "\n", sep = "")

max_k <- min(config$max_drivers, length(candidates))
n_models <- sum(choose(length(candidates), seq_len(max_k)))
if (n_models > config$max_models) {
  stop(n_models, " driver combinations to test exceeds max_models (",
       config$max_models, "). Reduce candidate_drivers or max_drivers, ",
       "or raise max_models.")
}
cat("Testing", n_models, "driver combinations (sizes 1-", max_k, ")\n")

###############################################################################
# 5. FIT AND EVALUATE EVERY DRIVER COMBINATION
###############################################################################

data_sub$quarter <- as.factor(data_sub$quarter)
train_data <- data_sub[train_idx, ]
test_data  <- data_sub[test_idx, ]
y_test     <- test_data[[target]]

fixed_terms <- c(if (use_dummy) "dummy_break", "factor(quarter)")

evaluate_model <- function(drivers) {
  fml <- as.formula(paste(target, "~",
                          paste(c(drivers, fixed_terms), collapse = " + ")))
  fit <- tryCatch(lm(fml, data = train_data), error = function(e) NULL)
  if (is.null(fit) || anyNA(coef(fit))) return(NULL)   # rank-deficient: skip
  pred <- predict(fit, newdata = test_data)
  err  <- y_test - pred
  data.frame(
    drivers      = paste(drivers, collapse = " + "),
    n_drivers    = length(drivers),
    test_RMSE    = sqrt(mean(err^2)),
    test_MAE     = mean(abs(err)),
    test_MAPE_pct = mean(abs(err / y_test)) * 100,
    train_adj_R2 = summary(fit)$adj.r.squared
  )
}

results <- list()
for (k in seq_len(max_k)) {
  combos <- combn(candidates, k, simplify = FALSE)
  results <- c(results, lapply(combos, evaluate_model))
}
## baseline for reference: quarter FE (+ break dummy) only, no drivers
baseline_fit  <- lm(as.formula(paste(target, "~", paste(fixed_terms, collapse = " + "))),
                    data = train_data)
baseline_err  <- y_test - predict(baseline_fit, newdata = test_data)
baseline <- data.frame(
  drivers = "(none - quarter FE baseline)", n_drivers = 0,
  test_RMSE = sqrt(mean(baseline_err^2)), test_MAE = mean(abs(baseline_err)),
  test_MAPE_pct = mean(abs(baseline_err / y_test)) * 100,
  train_adj_R2 = summary(baseline_fit)$adj.r.squared
)

ranking <- bind_rows(c(results, list(baseline))) %>%
  arrange(test_RMSE) %>%
  mutate(rank = row_number()) %>%
  relocate(rank)

cat("\n=== Top models by test RMSE ===\n")
print(head(as.data.frame(ranking), 10), row.names = FALSE)

###############################################################################
# 6. REFIT THE BEST MODEL ON THE FULL ACTUAL SAMPLE AND EXPORT
###############################################################################

best_drivers <- strsplit(ranking$drivers[ranking$n_drivers > 0][1], " \\+ ")[[1]]
cat("\nBest driver set:", paste(best_drivers, collapse = ", "), "\n")
cat("Paste into the forecast config:\n  driver_vars = c(",
    paste0('"', best_drivers, '"', collapse = ", "), ")\n", sep = "")

best_fml <- as.formula(paste(target, "~",
                             paste(c(best_drivers, fixed_terms), collapse = " + ")))
best_fit <- lm(best_fml, data = data_sub)   # full actual sample
print(summary(best_fit))

coef_tab <- as.data.frame(summary(best_fit)$coefficients)
coef_tab <- cbind(term = rownames(coef_tab), coef_tab)
rownames(coef_tab) <- NULL

split_info <- data.frame(
  item  = c("target", "train_start", "train_end", "test_start", "test_end",
            "n_train", "n_test", "break_dates", "dummy_break_used",
            "n_candidates", "n_models_tested"),
  value = c(target,
            format(data_sub$Year_Quarter[1]),
            format(data_sub$Year_Quarter[n_train]),
            format(data_sub$Year_Quarter[n_train + 1]),
            format(data_sub$Year_Quarter[n_act]),
            n_train, n_act - n_train,
            if (length(break_dates) > 0) paste(format(break_dates), collapse = ", ") else "none",
            use_dummy, length(candidates), n_models)
)

write_xlsx(
  list(ranking            = head(ranking, config$top_n),
       best_model_coefs   = coef_tab,
       split_and_settings = split_info),
  in_path(config$output_file)
)

cat("\nResults written to", config$output_file, "\n")
