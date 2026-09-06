#!/usr/bin/env Rscript
# mileage_elasticity.R
# ---------------------------------------------------------------------------
# How much of a used car's price is destroyed by the odometer rather than by
# the calendar, per fuel type.
#
# The rest of the note treats fuel, tyres and servicing as the costs that scale
# with distance. They are not the only ones: a kilometre driven also removes
# resale value, and on the numbers below that term is the same order of
# magnitude as the fuel. It cannot be read off a price list, so it is estimated
# here from the project's own bilbasen scrape.
#
#   log(price) ~ age + log(mileage) + log(hk) + brand
#
# The coefficient on log(mileage) is an elasticity: a 1 % higher odometer goes
# with e % lower price. Marginal depreciation per km at price P and odometer M
# is then |e| * P / M.
#
# WHY THE CONTROLS MATTER. Without log(hk) and brand the EV elasticity comes
# out POSITIVE (+0.10): in a market where the newest, most expensive EVs are
# also the ones with range enough to be driven, mileage proxies for quality.
# Adding a power term and brand dummies removes most of that and the sign
# flips to -0.045. That fragility is the finding, and section 5.4 of the note
# reports it rather than hiding it.
#
# Reads  depreciation/bilbasen_data.csv   (run from the repository root)
# Writes fuel-cost/mileage_elasticity.csv
# ---------------------------------------------------------------------------
suppressWarnings(Sys.setlocale("LC_CTYPE", "en_US.UTF-8"))

# NOTE: the bilbasen scrape this reads is NOT distributed with the repository
# (see depreciation/README.md). Regenerate it with depreciation/scrape_bilbasen.py
# before running. The committed outputs of this script are what the notes consume.
DATA <- "depreciation/bilbasen_data.csv"
OUT <- "fuel-cost/mileage_elasticity.csv"

CUR <- as.integer(format(Sys.Date(), "%Y"))
MIN_BRAND_N <- 15 # listings needed before a brand gets its own dummy
MIN_GROUP_N <- 100 # listings needed before a fuel group is reported at all

stopifnot("bilbasen scrape not found; run from the repository root" = file.exists(DATA))

d <- read.csv(DATA, stringsAsFactors = FALSE, fileEncoding = "UTF-8")

# The scraper dedupes within a run but appends across runs, so a listing that
# survived from one pull to the next appears more than once. Keep the most
# recent row per listing id. Without this the fit is weighted towards adverts
# that have been up longest - which is to say, towards cars that are not
# selling, exactly the ones whose asking price is least informative.
if ("external_id" %in% names(d)) {
  d <- d[order(d$external_id, d$scraped_at, decreasing = TRUE), ]
  n_before <- nrow(d)
  d <- d[!duplicated(d$external_id) | is.na(d$external_id), ]
  cat("de-duplicated", n_before - nrow(d), "repeat listings\n")
}

num <- function(x) suppressWarnings(as.numeric(x))
for (v in c("kontantpris", "reg_year", "mileage_km", "hk")) d[[v]] <- num(d[[v]])
d$age <- CUR - d$reg_year

# Trim to listings where all four variables are present and plausible. The age
# floor of 1 year drops nearly-new stock whose price is anchored to list rather
# than to the used market; the mileage floor keeps log() away from its asymptote.
keep <- with(d, !is.na(kontantpris) & kontantpris >= 20000 & kontantpris <= 2e6 &
  !is.na(age) & age >= 1 & age <= 12 &
  !is.na(mileage_km) & mileage_km > 5000 & mileage_km < 400000 &
  !is.na(hk) & hk > 40 & hk < 700 &
  (is.na(price_type) | price_type == "Retail"))
d <- d[keep, ]

# Same fuel grouping as depreciation_by_fueltype.R, except that diesel is split
# out rather than dropped: this note needs it as its own answer.
d$grp <- ifelse(grepl("El", d$fueltype), "el",
  ifelse(grepl("Diesel", d$fueltype), "diesel",
    ifelse(grepl("Benzin|Hybrid", d$fueltype) & !grepl("Plug", d$fueltype),
      "benzin", NA
    )
  )
)
d$mk <- ifelse(is.na(d$make) | d$make == "", d$brand_slug, d$make)

fit_group <- function(g) {
  s <- d[!is.na(d$grp) & d$grp == g, ]
  if (nrow(s) < MIN_GROUP_N) {
    return(NULL)
  }
  # Rare brands would each get a dummy fitted off a handful of cars, which
  # inflates R2 without identifying anything.
  s <- s[s$mk %in% names(which(table(s$mk) >= MIN_BRAND_N)), ]
  if (nrow(s) < MIN_GROUP_N || length(unique(s$mk)) < 2) {
    return(NULL)
  }

  m <- lm(log(kontantpris) ~ age + log(mileage_km) + log(hk) + factor(mk), data = s)
  co <- summary(m)$coefficients

  # The same model without the model-mix controls, reported alongside so the
  # reader can see how much of the estimate is the controls' doing.
  m0 <- lm(log(kontantpris) ~ age + log(mileage_km), data = s)

  data.frame(
    grp = g,
    n = nrow(s),
    n_brands = length(unique(s$mk)),
    b_age = co["age", 1],
    e_km = co["log(mileage_km)", 1],
    se_km = co["log(mileage_km)", 2],
    e_km_nocontrols = coef(m0)[["log(mileage_km)"]],
    b_hk = co["log(hk)", 1],
    r2 = summary(m)$r.squared,
    med_price = median(s$kontantpris),
    med_km = median(s$mileage_km),
    p25_km = unname(quantile(s$mileage_km, 0.25)),
    p75_km = unname(quantile(s$mileage_km, 0.75)),
    stringsAsFactors = FALSE
  )
}

res <- do.call(rbind, lapply(c("el", "benzin", "diesel"), fit_group))
stopifnot("no fuel group had enough listings to fit" = !is.null(res))

# Marginal DKK/km at each group's own median price and odometer, purely as a
# sanity figure for the console; the note recomputes it per car.
res$dkk_per_km_at_median <- abs(res$e_km) * res$med_price / res$med_km

res[] <- lapply(res, function(x) if (is.numeric(x)) round(x, 6) else x)
write.csv(res, OUT, row.names = FALSE)

cat("wrote ", OUT, "\n\n", sep = "")
print(res[, c("grp", "n", "e_km", "se_km", "e_km_nocontrols", "r2", "dkk_per_km_at_median")],
  row.names = FALSE
)
