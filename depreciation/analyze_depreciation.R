#!/usr/bin/env Rscript
# ---------------------------------------------------------------------------
# Estimate average annual depreciation per car brand from scraped bilbasen data.
#
# Input : bilbasen_data.csv  (produced by scrape_bilbasen.py)
# Output: console tables + depreciation_by_brand.csv + depreciation_curves.pdf
#
# Two estimates are produced:
#
#  (A) STATISTICAL (primary).  Per brand we fit
#          log(kontantpris) ~ age            [+ log(mileage) in a 2nd model]
#      where age = current_year - reg_year. The age coefficient b gives a
#      constant *proportional* decline: a car loses (1 - e^b) of its value
#      per extra year of age. This is the robust backbone and needs no nypris.
#
#  (B) DIRECT (where nypris exists).  For the minority of listings that quote a
#      new price, depreciation%/yr = 1 - (kontantpris / nypris)^(1/age).
#      Reported only as a cross-check; nypris is sparse.
#
# Base R only — no packages to install.
# ---------------------------------------------------------------------------

# NOTE: the bilbasen scrape this reads is NOT distributed with the repository
# (see README.md). Regenerate it with scrape_bilbasen.py
# before running. The committed outputs of this script are what the notes consume.
CSV <- "bilbasen_data.csv"
CUR_YEAR <- as.integer(format(Sys.Date(), "%Y"))
suppressWarnings(Sys.setlocale("LC_CTYPE", "en_US.UTF-8"))  # keep ë/ø/å intact

stopifnot(file.exists(CSV))
d <- read.csv(CSV, stringsAsFactors = FALSE, fileEncoding = "UTF-8")

# The CSV accumulates scrape snapshots; a car listed in more than one appears
# multiple times. Keep the most recent listing per external_id.
d <- d[order(d$external_id, d$scraped_at), ]
d <- d[!duplicated(d$external_id, fromLast = TRUE), ]

# --- clean ----------------------------------------------------------------
num <- function(x) suppressWarnings(as.numeric(x))
d$kontantpris <- num(d$kontantpris)
d$reg_year    <- num(d$reg_year)
d$mileage_km  <- num(d$mileage_km)
d$reg_month   <- num(d$reg_month)
d$nypris      <- num(d$nypris)

# Continuous age in years from first-registration date (mid-month = day 15;
# ~0.4% without a month fall back to mid-year).
mo <- ifelse(is.na(d$reg_month) | d$reg_month < 1 | d$reg_month > 12, 7, d$reg_month)
reg_date <- as.Date(sprintf("%04d-%02d-15", d$reg_year, mo))
d$age <- as.numeric(Sys.Date() - reg_date) / 365.25
d$age <- pmax(d$age, 1 / 365)               # floor brand-new at ~1 day, not 0
d$age_eff <- d$age

# Keep genuine retail cars with sane values. Drop the cheapest/oldest noise:
# very low prices are usually projects/scrap and distort a log fit.
keep <- with(d,
  !is.na(kontantpris) & kontantpris >= 10000 & kontantpris <= 5e6 &
  !is.na(reg_year) & reg_year >= 1990 & reg_year <= CUR_YEAR &
  !is.na(age) & age <= 30 &
  (is.na(price_type) | price_type == "Retail"))
d <- d[keep, ]

# Use the make field (canonical) for grouping; fall back to slug.
d$brand <- ifelse(is.na(d$make) | d$make == "", d$brand_slug, d$make)

cat(sprintf("Loaded %d usable listings across %d brands.\n\n",
            nrow(d), length(unique(d$brand))))

# --- (A) statistical depreciation per brand --------------------------------
MIN_N <- 15   # need a reasonable sample to fit a brand
brands <- sort(unique(d$brand))
rows <- list()

for (b in brands) {
  sub <- d[d$brand == b, ]
  if (nrow(sub) < MIN_N || length(unique(sub$age)) < 3) next

  # Model 1: age only
  m1 <- lm(log(kontantpris) ~ age, data = sub)
  b_age <- coef(m1)[["age"]]
  dep_rate <- 1 - exp(b_age)                      # fraction lost per year

  # Model 2: control for mileage (where available) to separate age from use
  sub2 <- sub[!is.na(sub$mileage_km) & sub$mileage_km > 0, ]
  dep_rate_adj <- NA_real_
  if (nrow(sub2) >= MIN_N && length(unique(sub2$age)) >= 3) {
    m2 <- lm(log(kontantpris) ~ age + log(mileage_km), data = sub2)
    dep_rate_adj <- 1 - exp(coef(m2)[["age"]])
  }

  rows[[b]] <- data.frame(
    brand          = b,
    n              = nrow(sub),
    median_price   = round(median(sub$kontantpris)),
    median_age     = median(sub$age),
    dep_pct_yr     = round(100 * dep_rate, 1),          # primary estimate
    dep_pct_yr_adj = round(100 * dep_rate_adj, 1),      # mileage-adjusted
    r2             = round(summary(m1)$r.squared, 2),
    stringsAsFactors = FALSE
  )
}

res <- do.call(rbind, rows)
res <- res[order(res$dep_pct_yr), ]
rownames(res) <- NULL

cat("=== (A) Statistical annual depreciation, by brand ===\n")
cat("   dep_pct_yr     : % of value lost per year of age (log-price model)\n")
cat("   dep_pct_yr_adj : same, holding mileage constant\n\n")
print(res, row.names = FALSE)
write.csv(res, "depreciation_by_brand.csv", row.names = FALSE)
cat("\n-> written depreciation_by_brand.csv\n")

# --- (B) direct nypris cross-check -----------------------------------------
dn <- d[!is.na(d$nypris) & d$nypris > d$kontantpris & d$age >= 1, ]
cat(sprintf("\n=== (B) Direct nypris-based cross-check ===\n%d of %d listings (%.1f%%) quote a usable nypris.\n",
            nrow(dn), nrow(d), 100 * nrow(dn) / nrow(d)))
if (nrow(dn) >= 10) {
  dn$dep_direct <- 1 - (dn$kontantpris / dn$nypris)^(1 / dn$age_eff)
  agg <- aggregate(dep_direct ~ brand, dn,
                   function(x) round(100 * median(x), 1))
  cnt <- aggregate(dep_direct ~ brand, dn, length)
  agg <- merge(agg, cnt, by = "brand", suffixes = c("_pct_yr", "_n"))
  names(agg) <- c("brand", "dep_pct_yr_direct", "n")
  print(agg[order(agg$dep_pct_yr_direct), ], row.names = FALSE)
} else {
  cat("Too few nypris values for a per-brand direct estimate (expected).\n")
}

# --- plot: price-vs-age curves per brand -----------------------------------
ok <- try({
  pdf("depreciation_curves.pdf", width = 11, height = 8)
  op <- par(mfrow = c(4, 5), mar = c(3.2, 3.2, 2, 0.6), mgp = c(1.9, 0.6, 0))
  for (b in res$brand) {
    sub <- d[d$brand == b, ]
    plot(jitter(sub$age), sub$kontantpris / 1000, pch = 16, cex = 0.4,
         col = rgb(0, 0, 0, 0.3), xlab = "age (yrs)", ylab = "price (1000 kr)",
         main = sprintf("%s (%.1f%%/yr)",
                        b, res$dep_pct_yr[res$brand == b]))
    ag <- seq(0, max(sub$age, na.rm = TRUE), length.out = 50)
    m1 <- lm(log(kontantpris) ~ age, data = sub)
    lines(ag, exp(predict(m1, data.frame(age = ag))) / 1000,
          col = "firebrick", lwd = 2)
  }
  par(op); dev.off()
}, silent = TRUE)
if (!inherits(ok, "try-error"))
  cat("-> written depreciation_curves.pdf\n")
