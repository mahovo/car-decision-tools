#!/usr/bin/env Rscript
# comparator_prices.R
# ---------------------------------------------------------------------------
# Replace the placeholder prices in fuel-cost-cars.csv with figures derived from
# real bilbasen listings.
#
# WHY THIS EXISTS. Every used comparator in the note started as a plausible
# guess, and section 8's whole answer - the break-even cash price - is driven by
# those guesses. A guess that is out by 30,000 DKK moves the conclusion by more
# than any energy-price assumption in the document. This script removes the
# guessing for the cars the scrape can actually support, and says so for the
# ones it cannot.
#
# METHOD. For each comparator, listings are matched on make, model, an optional
# variant pattern (this is where all-wheel drive is identified, since bilbasen
# has no structured drivetrain field), fuel type and a registration-year window.
# The price is then taken at the car's target odometer rather than as a raw
# median, because within a matched set price still falls with mileage:
#
#     log(price) ~ log(mileage)        fitted per comparator when n is enough
#
# and evaluated at the target odometer. With too few listings to fit, the median
# price of the matched set is used instead and the odometer is set to the
# matched median so the pair stays internally consistent. Either way the result
# is an asking price from the Danish market, not an invention.
#
# WHAT IT DOES NOT DO. Asking prices are not transaction prices, and a listing
# set of a dozen cars is a thin basis. The output is written with a provenance
# note and an `n` count per car so the reader can see which figures rest on 40
# listings and which on 4.
#
# Reads  depreciation/bilbasen_data.csv   (run from the repository root)
#        fuel-cost/fuel-cost-cars.csv
# Writes fuel-cost/fuel-cost-cars.csv          (prices, odometers, notes)
#        fuel-cost/comparator-listings.csv     (the audit trail)
# ---------------------------------------------------------------------------
suppressWarnings(Sys.setlocale("LC_CTYPE", "en_US.UTF-8"))

# NOTE: the bilbasen scrape this reads is NOT distributed with the repository
# (see depreciation/README.md). Regenerate it with depreciation/scrape_bilbasen.py
# before running. The committed outputs of this script are what the notes consume.
DATA <- "depreciation/bilbasen_data.csv"
CARS <- "fuel-cost/fuel-cost-cars.csv"
AUDIT <- "fuel-cost/comparator-listings.csv"

MIN_N_FIT <- 8 # listings needed before fitting price against mileage
MIN_N_USE <- 3 # listings needed before touching a car at all

stopifnot("bilbasen scrape not found; run from the repository root" = file.exists(DATA))
stopifnot("car list not found; run from the repository root" = file.exists(CARS))

d <- read.csv(DATA, stringsAsFactors = FALSE, fileEncoding = "UTF-8")
cars <- read.csv(CARS, stringsAsFactors = FALSE, fileEncoding = "UTF-8")

# The scraper dedupes within a run but appends across runs, so a listing that
# survived from one pull to the next appears more than once. Keep the most
# recent row per listing id: without this a long-standing advert counts several
# times and a fresh one counts once, which is a bias towards cars that are not
# selling.
if ("external_id" %in% names(d)) {
  d <- d[order(d$external_id, d$scraped_at, decreasing = TRUE), ]
  before <- nrow(d)
  d <- d[!duplicated(d$external_id) | is.na(d$external_id), ]
  cat("de-duplicated", before - nrow(d), "repeat listings;", nrow(d), "remain\n\n")
}

num <- function(x) suppressWarnings(as.numeric(x))
for (v in c("kontantpris", "reg_year", "mileage_km", "hk")) d[[v]] <- num(d[[v]])
d$txt <- paste(d$make, d$model, d$variant)

# --- what to match, per car in the CSV ---------------------------------------
#
# `variant` is a regular expression over "make model variant". It is doing the
# work a drivetrain column would do if bilbasen had one: 4Motion, 4x4, AWD,
# xDrive, quattro and Subaru's permanent AWD all have to be read off the
# variant string. Subaru is the exception - essentially everything it sells is
# all-wheel drive - so no pattern is needed there.
#
# Year windows are wider than the car's own registration year, because a
# three-year band is what makes the difference between a fit and nothing at all
# at this sample size. `fuel` matches bilbasen's own fueltype labels - note that
# a plug-in hybrid is "Plug-in" there and NOT "Hybrid", which silently returned
# zero RAV4s until it was caught.
spec <- list(
  enyaq_85x       = list(pat = "Enyaq",   fuel = "El",      yr = c(2021, 2023), variant = "85x|80x|iV 80X|4x4"),
  modely_lr       = list(pat = "Model Y", fuel = "El",      yr = c(2020, 2022), variant = "Long Range|Dual|AWD|Performance"),
  tiguan_4motion  = list(pat = "Tiguan",  fuel = "Benzin",  yr = c(2017, 2022), variant = "4Motion|4-Motion|4M"),
  outback_25i     = list(pat = "Outback", fuel = "Benzin",  yr = c(2016, 2021), variant = NULL),
  forester_20     = list(pat = "Forester", fuel = "Benzin", yr = c(2011, 2016), variant = NULL),
  octavia_tdi_4x4 = list(pat = "Octavia", fuel = "Diesel",  yr = c(2015, 2021), variant = "4x4|4X4|4 x 4"),
  xc60_d4_awd     = list(pat = "XC60",    fuel = "Diesel",  yr = c(2014, 2018), variant = "AWD|D4|D5"),
  tucson_crdi_awd = list(pat = "Tucson",  fuel = "Diesel",  yr = c(2015, 2019), variant = "4WD|AWD|4x4"),
  passat_tdi_4m   = list(pat = "Passat",  fuel = "Diesel",  yr = c(2012, 2018), variant = "4Motion|4-Motion|4M"),
  rav4_phev       = list(pat = "RAV",     fuel = "Plug-in", yr = c(2020, 2022), variant = "Plug|PHV|AWD-i")
)

match_set <- function(s) {
  keep <- grepl(s$pat, d$txt, ignore.case = TRUE) &
    grepl(s$fuel, d$fueltype, ignore.case = TRUE) &
    !is.na(d$reg_year) & d$reg_year >= s$yr[1] & d$reg_year <= s$yr[2] &
    !is.na(d$kontantpris) & d$kontantpris > 20000 & d$kontantpris < 1.5e6 &
    !is.na(d$mileage_km) & d$mileage_km > 1000 & d$mileage_km < 500000 &
    (is.na(d$price_type) | d$price_type == "Retail")
  if (!is.null(s$variant)) keep <- keep & grepl(s$variant, d$txt, ignore.case = TRUE)
  d[keep, ]
}

# --- price at the car's target odometer --------------------------------------
price_at <- function(sub, target_km) {
  if (nrow(sub) >= MIN_N_FIT && length(unique(sub$mileage_km)) >= 4) {
    m <- lm(log(kontantpris) ~ log(mileage_km), data = sub)
    list(
      price = unname(exp(predict(m, newdata = data.frame(mileage_km = target_km)))),
      odo = target_km, how = "fitted on log(mileage)"
    )
  } else {
    # Too thin to fit: take the median listing and move the odometer to match,
    # so price and mileage describe the same car rather than two different ones.
    list(
      price = median(sub$kontantpris), odo = median(sub$mileage_km),
      how = "median of matched listings"
    )
  }
}

audit <- list()
report <- data.frame()

for (id in names(spec)) {
  if (!id %in% cars$id) next
  i <- which(cars$id == id)
  sub <- match_set(spec[[id]])
  n <- nrow(sub)

  old_price <- cars$price_dkk[i]
  old_odo <- cars$odo_km[i]

  if (n < MIN_N_USE) {
    report <- rbind(report, data.frame(
      id = id, n = n, old_price = old_price, new_price = NA,
      old_odo = old_odo, new_odo = NA, how = "TOO FEW - left as placeholder"
    ))
    next
  }

  est <- price_at(sub, old_odo)
  cars$price_dkk[i] <- round(est$price / 500) * 500 # listings are advertised in round numbers
  cars$odo_km[i] <- round(est$odo / 1000) * 1000
  # Logical, not the string "TRUE": assigning a character here would coerce the
  # whole column and the Rmd reads it back as a logical.
  cars$price_sourced[i] <- TRUE
  cars$note[i] <- paste0(
    "Price from ", n, " bilbasen listings (", est$how,
    "); see comparator-listings.csv. Specs remain estimates."
  )

  sub$comparator <- id
  # Deliberately no `uri` or `external_id`: the audit trail is published in this
  # repository, and those two columns are what turn a row into a pointer at an
  # individual advert. What remains describes the car and its asking price.
  audit[[id]] <- sub[, c(
    "comparator", "make", "model", "variant", "kontantpris",
    "reg_year", "mileage_km", "fueltype", "hk"
  )]

  report <- rbind(report, data.frame(
    id = id, n = n, old_price = old_price, new_price = cars$price_dkk[i],
    old_odo = old_odo, new_odo = cars$odo_km[i], how = est$how
  ))
}

write.csv(cars, CARS, row.names = FALSE, na = "NA", fileEncoding = "UTF-8")
if (length(audit)) {
  write.csv(do.call(rbind, audit), AUDIT, row.names = FALSE, fileEncoding = "UTF-8")
}

report$change_pct <- round(100 * (report$new_price / report$old_price - 1))
print(report, row.names = FALSE)
cat("\nwrote", CARS, "and", AUDIT, "\n")
