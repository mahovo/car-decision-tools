#!/usr/bin/env Rscript
# depreciation_by_fueltype.R
# ---------------------------------------------------------------------------
# Fuel-type-specific, mileage-adjusted brand depreciation for the three
# bilsammenligning tables. Reproduces the methodology in analyze_depreciation
# (log-price ~ age + log(mileage)) but split by fuel type (el vs benzin/hybrid),
# and adds empirical-Bayes shrinkage that uses each brand's regression standard
# error (i.e. the "diagnostics") to pull noisy estimates toward the group mean.
#
# Reads depreciation/bilbasen_data.csv and writes depreciation_by_fueltype.csv.
# It does NOT touch analyze_depreciation.Rmd.
# ---------------------------------------------------------------------------
suppressWarnings(Sys.setlocale("LC_CTYPE", "en_US.UTF-8"))

# NOTE: the bilbasen scrape this reads is NOT distributed with the repository
# (see depreciation/README.md). Regenerate it with depreciation/scrape_bilbasen.py
# before running. The committed outputs of this script are what the notes consume.
DATA  <- "depreciation/bilbasen_data.csv"
CUR   <- as.integer(format(Sys.Date(), "%Y"))
MIN_N <- 15            # min usable listings to fit a brand
MIN_AGES <- 3          # min distinct ages

d <- read.csv(DATA, stringsAsFactors = FALSE, fileEncoding = "UTF-8")
num <- function(x) suppressWarnings(as.numeric(x))
d$kontantpris <- num(d$kontantpris)
d$reg_year    <- num(d$reg_year)
d$mileage_km  <- num(d$mileage_km)
d$age   <- CUR - d$reg_year
d$brand <- ifelse(is.na(d$make) | d$make == "", d$brand_slug, d$make)

keep <- with(d, !is.na(kontantpris) & kontantpris >= 10000 & kontantpris <= 5e6 &
  !is.na(reg_year) & reg_year >= 1990 & reg_year <= CUR & age >= 0 & age <= 30 &
  (is.na(price_type) | price_type == "Retail"))
d <- d[keep, ]

# fuel groups: el; benzin = Benzin + (full) Hybrid, excluding Plug-in and Diesel
d$grp <- ifelse(grepl("El", d$fueltype), "el",
         ifelse(grepl("Benzin|Hybrid", d$fueltype) & !grepl("Plug", d$fueltype),
                "benzin", NA))

# per-brand mileage-adjusted fit -> slope b (age coef) and its standard error
fit_brand <- function(sub) {
  sub2 <- sub[!is.na(sub$mileage_km) & sub$mileage_km > 0 & sub$kontantpris > 0, ]
  if (nrow(sub2) < MIN_N || length(unique(sub2$age)) < MIN_AGES) return(NULL)
  m <- lm(log(kontantpris) ~ age + log(mileage_km), data = sub2)
  s <- summary(m)
  data.frame(b = coef(m)[["age"]], se = s$coefficients["age", "Std. Error"],
             n = nrow(sub2), r2 = round(s$r.squared, 2))
}

# empirical-Bayes shrinkage of the slopes toward the (precision-weighted) group
# mean; brands with large se (uncertain) are pulled harder toward the mean.
shrink_group <- function(df) {
  mu   <- weighted.mean(df$b, 1 / df$se^2)
  tau2 <- max(0, var(df$b) - mean(df$se^2))          # between-brand variance
  df$mu_grp  <- mu                                   # group prior mean (log scale)
  df$tau_grp <- sqrt(tau2)                           # between-brand SD (log scale)
  if (tau2 == 0) { df$b_shrunk <- mu; df$sd_shrunk <- df$se; return(df) }
  df$b_shrunk <- (df$b / df$se^2 + mu / tau2) / (1 / df$se^2 + 1 / tau2)
  # Posterior SD of the shrunk slope: precisions add. This is what downstream
  # models need to put an interval on the rate, so it is now written out.
  df$sd_shrunk <- sqrt(1 / (1 / df$se^2 + 1 / tau2))
  df
}

out <- list()
for (g in c("el", "benzin")) {
  dd     <- d[!is.na(d$grp) & d$grp == g, ]
  brands <- sort(unique(dd$brand))
  rows   <- lapply(brands, function(b) {
    r <- fit_brand(dd[dd$brand == b, ])
    if (!is.null(r)) { r$brand <- b; r$grp <- g }
    r
  })
  res <- do.call(rbind, rows)
  out[[g]] <- shrink_group(res)
}

allres <- do.call(rbind, out)
allres$dep_adj_pct        <- round(100 * (1 - exp(allres$b)), 1)         # raw
allres$dep_adj_shrunk_pct <- round(100 * (1 - exp(allres$b_shrunk)), 1)  # used
allres <- allres[, c("brand", "grp", "n", "r2", "dep_adj_pct", "dep_adj_shrunk_pct",
                     "b", "se", "b_shrunk", "sd_shrunk", "mu_grp", "tau_grp")]
allres <- allres[order(allres$grp, allres$dep_adj_shrunk_pct), ]
rownames(allres) <- NULL

write.csv(allres, "depreciation_by_fueltype.csv", row.names = FALSE)
cat("Wrote depreciation_by_fueltype.csv\n\n")
print(allres)
