# =============================================================================
# r_demand_analysis.R
# =============================================================================
# Complementary R analysis for the demand forecasting project.
# Covers: time-series diagnostics, ETS modelling, cross-validation,
#         and a formatted HTML report via R Markdown (optional).
#
# Author  : Samiya Sarker Hiya
# Program : M.Sc. Operational Research & Business Analytics
#           Otto-von-Guericke University Magdeburg
#
# Run from project root:
#   Rscript src/r_demand_analysis.R
# =============================================================================

# ── 0.  Dependencies ──────────────────────────────────────────────────────────
required_pkgs <- c("forecast", "tseries", "ggplot2", "dplyr",
                   "lubridate", "scales", "tidyr", "readr")

invisible(lapply(required_pkgs, function(p) {
  if (!requireNamespace(p, quietly = TRUE)) {
    install.packages(p, repos = "https://cloud.r-project.org", quiet = TRUE)
  }
  library(p, character.only = TRUE)
}))

cat("✅  R packages loaded.\n")


# ── 1.  Load data ─────────────────────────────────────────────────────────────
demand_path <- file.path("data", "daily_demand.csv")

if (!file.exists(demand_path)) {
  stop("Run src/generate_data.py first to create the data/ files.")
}

demand_raw <- read_csv(demand_path, col_types = cols(date = col_date()))
cat(sprintf("   Rows loaded: %s\n", format(nrow(demand_raw), big.mark = ",")))


# ── 2.  Aggregate to monthly ──────────────────────────────────────────────────
monthly <- demand_raw %>%
  mutate(year_month = floor_date(date, "month")) %>%
  group_by(sku_id, year_month) %>%
  summarise(total_demand = sum(daily_demand), .groups = "drop")

cat(sprintf("   Monthly rows:  %s\n\n", nrow(monthly)))


# ── 3.  Helper: build monthly ts object ──────────────────────────────────────
make_ts <- function(df, sku) {
  sub   <- df %>% filter(sku_id == sku) %>% arrange(year_month)
  start <- c(year(min(sub$year_month)), month(min(sub$year_month)))
  ts(sub$total_demand, start = start, frequency = 12)
}


# ── 4.  Stationarity check (ADF test) per SKU ────────────────────────────────
cat("── Augmented Dickey-Fuller Tests ──────────────────────────────────────\n")
for (sku in unique(monthly$sku_id)) {
  s   <- make_ts(monthly, sku)
  adf <- adf.test(s, alternative = "stationary")
  sig <- ifelse(adf$p.value < 0.05, "✓ stationary", "✗ non-stationary (difference needed)")
  cat(sprintf("  %-8s  p = %.4f  → %s\n", sku, adf$p.value, sig))
}
cat("\n")


# ── 5.  Auto-ARIMA & ETS per SKU with cross-validated MAPE ───────────────────
cat("── Model Comparison (Time-series CV, h=3) ─────────────────────────────\n")

results <- data.frame()

for (sku in unique(monthly$sku_id)) {
  s         <- make_ts(monthly, sku)
  n         <- length(s)
  h         <- 3L                  # forecast horizon for CV
  min_train <- 18L                 # minimum training window

  mae_ets   <- numeric(0)
  mae_arima <- numeric(0)

  # Rolling-origin cross-validation
  for (i in seq(min_train, n - h)) {
    train_win <- window(s, end = time(s)[i])

    # ETS
    tryCatch({
      fit_ets  <- ets(train_win, damped = TRUE)
      fc_ets   <- forecast(fit_ets, h = h)$mean
      actual   <- window(s, start = time(s)[i + 1], end = time(s)[i + h])
      mae_ets  <- c(mae_ets,  mean(abs(as.numeric(actual) - as.numeric(fc_ets))))
    }, error = function(e) NULL)

    # Auto-ARIMA
    tryCatch({
      fit_ar   <- auto.arima(train_win, seasonal = TRUE,
                              stepwise = TRUE, approximation = TRUE)
      fc_ar    <- forecast(fit_ar, h = h)$mean
      actual   <- window(s, start = time(s)[i + 1], end = time(s)[i + h])
      mae_arima <- c(mae_arima, mean(abs(as.numeric(actual) - as.numeric(fc_ar))))
    }, error = function(e) NULL)
  }

  results <- rbind(results, data.frame(
    sku_id     = sku,
    ETS_MAE    = round(mean(mae_ets,   na.rm = TRUE), 2),
    ARIMA_MAE  = round(mean(mae_arima, na.rm = TRUE), 2),
    Best_Model = ifelse(mean(mae_ets, na.rm = TRUE) <= mean(mae_arima, na.rm = TRUE),
                        "ETS", "ARIMA")
  ))
}

print(results, row.names = FALSE)
cat("\n")


# ── 6.  Fit best model per SKU and generate 12-month forecast ────────────────
cat("── 12-Month Forecasts ──────────────────────────────────────────────────\n")

dir.create("outputs", showWarnings = FALSE)
forecast_list <- list()

for (sku in unique(monthly$sku_id)) {
  s       <- make_ts(monthly, sku)
  best    <- results$Best_Model[results$sku_id == sku]

  if (best == "ETS") {
    fit <- ets(s, damped = TRUE)
  } else {
    fit <- auto.arima(s, seasonal = TRUE, stepwise = TRUE, approximation = TRUE)
  }

  fc  <- forecast(fit, h = 12)
  forecast_list[[sku]] <- fc

  cat(sprintf("  %s  [%s]  Next-12-month range: %.0f – %.0f units/month\n",
              sku, best,
              min(fc$mean), max(fc$mean)))
}
cat("\n")


# ── 7.  Visualise forecasts ───────────────────────────────────────────────────
plot_forecast <- function(fc, sku_id, output_path) {
  fc_df <- data.frame(
    period    = as.Date(time(fc$mean) %>% {as.Date(paste0(floor(.), "-",
                sprintf("%02d", round((. %% 1) * 12 + 1)), "-01"))}),
    forecast  = as.numeric(fc$mean),
    lower_80  = as.numeric(fc$lower[,"80%"]),
    upper_80  = as.numeric(fc$upper[,"80%"]),
    lower_95  = as.numeric(fc$lower[,"95%"]),
    upper_95  = as.numeric(fc$upper[,"95%"])
  )

  hist_df <- data.frame(
    period = as.Date(time(fc$x) %>% {as.Date(paste0(floor(.), "-",
              sprintf("%02d", round((. %% 1) * 12 + 1)), "-01"))}),
    actual = as.numeric(fc$x)
  )

  p <- ggplot() +
    geom_ribbon(data = fc_df,
                aes(x = period, ymin = lower_95, ymax = upper_95),
                fill = "#d2a8ff", alpha = 0.20) +
    geom_ribbon(data = fc_df,
                aes(x = period, ymin = lower_80, ymax = upper_80),
                fill = "#d2a8ff", alpha = 0.35) +
    geom_line(data = hist_df,
              aes(x = period, y = actual),
              colour = "#58a6ff", size = 1.0) +
    geom_line(data = fc_df,
              aes(x = period, y = forecast),
              colour = "#ffa657", size = 1.1, linetype = "dashed") +
    geom_point(data = fc_df,
               aes(x = period, y = forecast),
               colour = "#ffa657", size = 2) +
    scale_y_continuous(labels = comma) +
    scale_x_date(date_breaks = "3 months", date_labels = "%b %Y") +
    labs(
      title    = paste("12-Month Demand Forecast —", sku_id),
      subtitle = "Shaded bands: 80 % and 95 % prediction intervals",
      x = NULL, y = "Units / Month"
    ) +
    theme_minimal(base_family = "mono") +
    theme(
      plot.background  = element_rect(fill = "#0d1117", colour = NA),
      panel.background = element_rect(fill = "#161b22", colour = NA),
      panel.grid.major = element_line(colour = "#21262d"),
      panel.grid.minor = element_blank(),
      text             = element_text(colour = "#e6edf3"),
      axis.text        = element_text(colour = "#8b949e"),
      plot.title       = element_text(size = 13, face = "bold"),
      axis.text.x      = element_text(angle = 30, hjust = 1)
    )

  ggsave(output_path, p, width = 12, height = 5, dpi = 150, bg = "#0d1117")
}

for (sku in names(forecast_list)) {
  out_path <- file.path("outputs", paste0("r_forecast_", tolower(sku), ".png"))
  plot_forecast(forecast_list[[sku]], sku, out_path)
  cat(sprintf("  ✓  %s\n", out_path))
}

cat("\n✅  R analysis complete.  Plots saved to outputs/\n")
