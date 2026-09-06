# Cost core for the per-kilometre fuel-cost note.
#
# Everything here is deterministic and closed-form. The note's uncertainty is
# carried by evaluating the same functions at a low, central and high setting
# of the energy prices and the real-world consumption gap, not by simulation.
#
# TWO COST CONCEPTS, kept strictly apart:
#
#   MARGINAL  costs that a kilometre causes: energy, tyres, distance-triggered
#             servicing, consumables, repair hazard, odometer depreciation.
#             This is what "cost per km" means in sections 3-5.
#
#   FIXED     costs that a year causes regardless of distance: ejerafgift,
#             insurance, calendar depreciation, opportunity cost of capital.
#             Zero content for the ranking at a fixed car, decisive once cars
#             at different prices are compared. Section 6.
#
# The split is not cosmetic. Marginal cost alone answers "which fuel is cheaper
# to burn"; only the sum answers "which car should I buy".

suppressPackageStartupMessages(library(tidyverse))

options(scipen = 999)

# --- energy ------------------------------------------------------------------

#' Blended electricity price for a charging mix
#'
#' `mix` is a named vector of shares over the tiers in `tiers`; it must sum to
#' one, because a share that quietly fails to would silently price part of the
#' driving at zero.
blend_el <- function(mix, tiers) {
  stopifnot(
    "charging mix names must all be known tiers" = all(names(mix) %in% names(tiers)),
    "charging mix must sum to 1" = abs(sum(mix) - 1) < 1e-9,
    "charging shares must be non-negative" = all(mix >= 0)
  )
  sum(mix * tiers[names(mix)])
}

#' Real-world consumption from the type-approval figure
#'
#' WLTP is a laboratory cycle. `gap` is the multiplier that carries it to what
#' the car actually uses on Danish roads over a full year, including winter.
#' For a BEV the WLTP electric figure is already measured at the plug, so `gap`
#' must NOT be asked to cover charging losses a second time; `extra_loss` is
#' there only for losses beyond that, and defaults to none.
real_use <- function(wltp, gap, extra_loss = 0) {
  stopifnot(gap > 0, extra_loss >= 0, extra_loss < 1)
  wltp * gap / (1 - extra_loss)
}

# --- periodiske afgifter -----------------------------------------------------
#
# Denmark runs two parallel regimes, split by first registration date, and the
# note has to model both because the fleet straddles the boundary.
#
#   CO2-ejerafgift   first registered 1 July 2021 or later. Brackets on WLTP
#                    CO2 in g/km.
#   Groen ejerafgift first registered before that. Brackets on fuel economy in
#   (braendstof-      km/l. An electric car's Wh/km is converted to l/100km by
#    forbrugsafgift)  dividing by 91.25, then to km/l, which lands every modern
#                    EV in the top bracket.
#
# Diesel pays an udligningsafgift on top under both regimes, compensating for
# diesel's historically lower duty at the pump. It is temporarily cut by 30 %
# for 2025-26 and by 21 % from 2027, offsetting a 52 oere/l rise in the diesel
# duty - so the pump price and the periodic tax were deliberately moved in
# opposite directions, and the offset shrinks after 2026.
#
# NOT MODELLED: vaegtafgift, which applies to petrol cars first registered
# before 1 July 1997. No car in the fleet is that old.

#' Convert an electric car's consumption to the statutory km/l equivalent
#'
#' The divisor of 91.25 is the statutory conversion, not a physical one.
ev_km_per_litre <- function(wh_km) {
  # NA passes through: case_when() evaluates every branch, so this is called on
  # the combustion rows too, where Wh/km is legitimately absent.
  stopifnot(all(wh_km > 0, na.rm = TRUE))
  100 / (wh_km / 91.25)
}

#' Tailpipe CO2 implied by fuel consumption
#'
#' Used only where the CSV leaves co2_g_km blank. The factors are the carbon
#' content of the fuels; they are close to but not identical with the WLTP
#' figure a manufacturer publishes, so an explicit value in the CSV wins.
co2_from_consumption <- function(l_100km, fuel) {
  factor <- ifelse(fuel == "diesel", 26.4, 23.2)
  l_100km * factor
}

#' Look up a value in a bracket table
#'
#' Brackets are half-open [lower, upper); `value` below the first lower bound
#' falls in the first bracket.
bracket_lookup <- function(value, tbl, column) {
  vapply(value, function(v) {
    hit <- which(v >= tbl$lower & v < tbl$upper)
    if (length(hit) == 0) hit <- if (v < min(tbl$lower)) 1L else nrow(tbl)
    tbl[[column]][hit[1]]
  }, numeric(1))
}

#' Annual periodiske afgifter, DKK
#'
#' Returns the full annual charge (twice the half-yearly rate). `rates` is
#' periodic-tax-rates.csv. `udligning_factor` scales the diesel surcharge, for
#' asking what happens when the temporary relief is withdrawn.
periodic_tax <- function(fuel, reg_year, l_100km, wh_km, co2_g_km, rates,
                         co2_regime_from_year = 2022, udligning_factor = 1) {
  n <- length(fuel)
  stopifnot(udligning_factor >= 0)

  co2_tbl <- rates[rates$regime == "co2", ]
  out <- numeric(n)

  for (i in seq_len(n)) {
    is_co2 <- reg_year[i] >= co2_regime_from_year
    co2 <- co2_g_km[i]
    if (is.na(co2)) {
      co2 <- if (fuel[i] == "el") 0 else co2_from_consumption(l_100km[i], fuel[i])
    }

    if (is_co2) {
      base <- bracket_lookup(co2, co2_tbl, "dkk_half_year")
    } else {
      # Electric and plug-in cars are assessed on the petrol scale after the
      # statutory conversion; a PHEV uses its petrol consumption, which is the
      # conservative reading.
      kml <- switch(fuel[i],
        el = ev_km_per_litre(wh_km[i]),
        diesel = 100 / l_100km[i],
        100 / l_100km[i]
      )
      scale <- if (fuel[i] == "diesel") "diesel" else "benzin"
      tbl <- rates[rates$regime == "kml" & rates$scale == scale, ]
      base <- bracket_lookup(kml, tbl, "dkk_half_year")
    }

    # The udligningsafgift column is only tabulated against CO2 in the source,
    # so the CO2 bracket is used to price it under both regimes. That is a
    # simplification of the statutory B1/B2 scales - see section 6.2.
    udl <- if (fuel[i] == "diesel") {
      bracket_lookup(co2, co2_tbl, "udligning_half_year") * udligning_factor
    } else {
      0
    }

    out[i] <- 2 * (base + udl)
  }
  out
}

# --- distance depreciation ---------------------------------------------------

#' Share of value destroyed by the odometer over a holding period
#'
#' Value is modelled as V(age, M) = K * exp(b_age * age) * M^e, which is the
#' functional form fitted in mileage_elasticity.R. Splitting it this way means
#' the calendar term factors out exactly, so the km-attributable loss between
#' odometer M0 and M1 is the ratio 1 - (M1/M0)^e evaluated at the END of the
#' hold. That is an ARC measure, not a derivative: the derivative at low M
#' diverges and would price a new car's first kilometres at several kroner
#' each, which is an artefact of the log form rather than a fact about cars.
#'
#' `m_floor` guards the same asymptote. Below roughly 30,000 km the fitted
#' curve has no data behind it, and a new car's early value collapse is a
#' new-car premium evaporating on the calendar, not wear on the odometer; that
#' part belongs in the fixed term and is handled by `new_premium_loss`.
km_loss_share <- function(odo_start, km_driven, elasticity, m_floor = 30000) {
  stopifnot(km_driven >= 0, elasticity <= 0, m_floor > 0)
  m0 <- pmax(odo_start, m_floor)
  m1 <- m0 + km_driven
  1 - (m1 / m0)^elasticity
}

#' Residual value at the end of the hold, before the odometer term
#'
#' `new_premium_loss` is the one-off drop that a car takes simply by ceasing to
#' be new, over and above the used-market age slope. Calibrated in the leasing
#' note, not re-estimated here.
value_calendar <- function(price, years, b_age, is_new, new_premium_loss) {
  stopifnot(years >= 0, b_age <= 0, new_premium_loss >= 0, new_premium_loss < 1)
  price * ifelse(is_new & years > 0, 1 - new_premium_loss, 1) * exp(b_age * years)
}

# --- per-kilometre components ------------------------------------------------

#' Tyre cost per km
#'
#' Both the price of a set and how fast it disappears scale with kerb weight,
#' which is the whole reason an EV is dearer here: a 2,065 kg bZ4X Touring is
#' 700 kg heavier than an Octavia and puts that through the same contact patch.
#' The exponents are judgement, not measurement - see section 5.2.
tyre_dkk_km <- function(kerb_kg, set_dkk_ref, life_km_ref, kerb_ref,
                        price_exp, wear_exp) {
  set_dkk <- set_dkk_ref * (kerb_kg / kerb_ref)^price_exp
  life_km <- life_km_ref * (kerb_ref / kerb_kg)^wear_exp
  set_dkk / life_km
}

#' Servicing cost per km under an alternating small/large schedule
#'
#' Danish service plans are "whichever comes first", so at low annual distance
#' the calendar binds and the per-km cost rises. Ignoring that would flatter
#' every low-mileage scenario, which is exactly the region where the answer is
#' closest, so the time limit is applied.
service_dkk_km <- function(small_dkk, large_dkk, interval_km, interval_aar, km_aar) {
  stopifnot(interval_km > 0, interval_aar > 0, km_aar > 0)
  effective_interval <- pmin(interval_km, km_aar * interval_aar)
  ((small_dkk + large_dkk) / 2) / effective_interval
}

#' Repair hazard per km, as a function of how far the car has already gone
#'
#' A linear ramp beyond a hazard-free odometer, multiplied by a powertrain
#' factor. This is the least defensible number in the note and the one that
#' decides whether a cheap old car is actually cheap, so section 5.5 inverts it
#' rather than defending the point estimate.
repair_dkk_km <- function(odo_km, hazard_free_km, slope_per_100k, fuel_mult) {
  stopifnot(hazard_free_km >= 0, slope_per_100k >= 0)
  pmax(0, odo_km - hazard_free_km) / 1e5 * slope_per_100k * fuel_mult
}

# --- assembly ----------------------------------------------------------------

#' Full per-kilometre cost for every car under one scenario
#'
#' `cars` is the CSV; `sc` is a flat list of scenario settings. Returns one row
#' per car with each marginal component separated, the fixed annual costs, and
#' the total at the given annual distance. Components are kept as columns
#' rather than summed away so that section 4 can decompose the bars.
cost_per_km <- function(cars, sc, km_aar, years) {
  stopifnot(km_aar > 0, years > 0)

  cars |>
    mutate(
      # --- energy -----------------------------------------------------------
      # A PHEV burns both, split by ev_share. A BEV's l/100km and an ICE car's
      # Wh/km are NA in the CSV; coalesce to zero AFTER the split so that a
      # missing figure on a car that needs it still surfaces as NA upstream.
      share_el = case_when(
        fuel == "el" ~ 1,
        fuel == "phev" ~ ev_share,
        TRUE ~ 0
      ),
      use_wh_km = real_use(wltp_wh_km, sc$gap_ev, sc$el_extra_loss),
      use_l_100 = real_use(wltp_l_100km, sc$gap_ice),
      price_fuel_l = if_else(fuel == "diesel", sc$diesel_dkk_l, sc$petrol_dkk_l),
      c_energy_el = share_el * coalesce(use_wh_km, 0) / 1000 * sc$el_dkk_kwh,
      c_energy_fuel = (1 - share_el) * coalesce(use_l_100, 0) / 100 * price_fuel_l,
      c_energy = c_energy_el + c_energy_fuel,

      # --- tyres, servicing, consumables -----------------------------------
      c_tyres = tyre_dkk_km(
        kerb_kg, sc$tyre_set_dkk, sc$tyre_life_km,
        sc$tyre_kerb_ref, sc$tyre_price_exp, sc$tyre_wear_exp
      ),
      c_service = service_dkk_km(
        service_small_dkk, service_large_dkk,
        service_interval_km, service_interval_aar, km_aar
      ),
      # Lookups are by fuel name; unname() so the vector names do not leak into
      # the column and confuse downstream joins.
      c_consum = unname(sc$consum_dkk_km[fuel]) + if_else(adblue, sc$adblue_dkk_km, 0),

      # --- repair hazard, evaluated at the mid-hold odometer ----------------
      odo_mid = odo_km + km_aar * years / 2,
      c_repair = repair_dkk_km(
        odo_mid, sc$hazard_free_km, sc$hazard_slope, unname(sc$hazard_mult[fuel])
      ),

      # --- odometer depreciation -------------------------------------------
      b_age = unname(sc$b_age[fuel]),
      e_km = unname(sc$e_km[fuel]) * sc$e_km_scale,
      v_end_calendar = value_calendar(
        price_dkk, years, b_age, condition == "ny", sc$new_premium_loss
      ),
      km_total = km_aar * years,
      c_dep_km = v_end_calendar * km_loss_share(odo_km, km_total, e_km, sc$dep_m_floor) /
        km_total,

      # Everything above is independent of what the car cost to buy. That is the
      # cleanly price-free part of running a car, and section 7 compares fuel
      # types on it precisely because it carries no capital in it at all.
      c_running = c_energy + c_tyres + c_service + c_consum + c_repair,

      marginal_dkk_km = c_running + c_dep_km,

      # --- periodiske afgifter ---------------------------------------------
      # Computed from the statutory bracket tables rather than entered per car,
      # because the charge is a deterministic function of fuel type, fuel
      # economy and first registration date. An explicit ejerafgift_override in
      # the CSV wins, for a car whose actual assessment is known.
      # NB: assessed on the TYPE-APPROVAL figures, not the real-world ones. The
      # bracket a car falls in is a matter of what is on its registration
      # document; how it is actually driven does not change the bill.
      ejerafgift_dkk_aar = if_else(
        is.na(ejerafgift_override),
        periodic_tax(
          fuel, reg_year, wltp_l_100km, wltp_wh_km, co2_g_km, sc$tax_rates,
          sc$co2_regime_from_year, sc$udligning_factor
        ),
        as.numeric(ejerafgift_override)
      ),
      tax_dkk_km = ejerafgift_dkk_aar / km_aar,

      # Price-free running cost INCLUDING the periodic tax. Not additive with
      # total_dkk_km - the tax appears there inside fixed_dkk_aar - so this is a
      # separate view of the same car, not another component.
      running_incl_tax_dkk_km = c_running + tax_dkk_km,

      # --- fixed annual costs ----------------------------------------------
      # Calendar depreciation is the loss the car takes standing still; the
      # odometer part is already in c_dep_km and must not be counted twice.
      dep_calendar_aar = (price_dkk - v_end_calendar) / years,
      v_end = v_end_calendar * (1 - km_loss_share(odo_km, km_total, e_km, sc$dep_m_floor)),
      capital_aar = sc$capital_rate * (price_dkk + v_end) / 2,
      fixed_dkk_aar = ejerafgift_dkk_aar + insurance_dkk_aar +
        dep_calendar_aar + capital_aar,

      fixed_dkk_km = fixed_dkk_aar / km_aar,
      total_dkk_km = marginal_dkk_km + fixed_dkk_km,
      total_dkk_aar = total_dkk_km * km_aar,
      km_aar = km_aar,
      years = years
    )
}

# --- like-for-like comparison ------------------------------------------------
#
# The fleet in the CSV confounds two things the decision needs kept apart: a
# 2014 petrol car at 215,000 km differs from a new electric one in powertrain
# AND in odometer AND in price. These helpers build a synthetic car so that one
# attribute can be varied while the others are pinned.

#' A representative car of one fuel type
#'
#' Specs come from the fleet median for that fuel, so the synthetic car is
#' anchored to the CSV rather than invented. Any field can be overridden.
#'
#' `spec_from` takes the specs from ONE named car instead of the median. Use it
#' whenever the answer needs to be concrete and attributable rather than
#' typical: with only three or four cars per fuel type the median is not robust,
#' and a fleet that happens to hold three thirsty used SUVs and one efficient
#' hybrid produces a "representative" petrol car that nobody would buy. Section
#' 8.4 uses this for exactly that reason.
representative_car <- function(cars, which_fuel, price_dkk, odo_km, reg_year,
                               spec_from = NULL, ...) {
  sub <- cars[cars$fuel == which_fuel, ]
  stopifnot("no car of that fuel type in the CSV" = nrow(sub) > 0)

  if (!is.null(spec_from)) {
    stopifnot("spec_from must name a car in the CSV" = spec_from %in% cars$id)
    sub <- cars[cars$id == spec_from, ]
    stopifnot("spec_from names a car of a different fuel type" = sub$fuel == which_fuel)
  }

  med <- function(col) median(sub[[col]], na.rm = TRUE)

  base <- tibble(
    id = paste0("synth_", which_fuel),
    name = paste0("Representative ", which_fuel),
    fuel = which_fuel,
    body = "SUV",
    condition = if (odo_km < 1000) "ny" else "brugt",
    reg_year = reg_year,
    odo_km = odo_km,
    price_dkk = price_dkk,
    wltp_wh_km = med("wltp_wh_km"),
    wltp_l_100km = med("wltp_l_100km"),
    ev_share = med("ev_share"),
    kerb_kg = med("kerb_kg"),
    service_small_dkk = med("service_small_dkk"),
    service_large_dkk = med("service_large_dkk"),
    service_interval_km = med("service_interval_km"),
    service_interval_aar = med("service_interval_aar"),
    adblue = which_fuel == "diesel",
    co2_g_km = med("co2_g_km"),
    ejerafgift_override = NA_real_,
    insurance_dkk_aar = med("insurance_dkk_aar"),
    price_sourced = FALSE,
    spec_sourced = FALSE,
    note = "synthetic"
  )

  over <- list(...)
  for (nm in names(over)) base[[nm]] <- over[[nm]]
  base
}

#' Cash price at which two fuel types cost the same per year in total
#'
#' Holds the comparator's specs and odometer fixed and solves for its price.
#' This is the inversion the buying decision actually turns on: how much more
#' is the cheaper-to-run car worth paying for. Returns NA when no price inside
#' the bracket equalises them.
break_even_price <- function(target_aar, comparator, sc, km_aar, years,
                             lo = 20000, hi = 1.2e6) {
  f <- function(p) {
    car <- comparator
    car$price_dkk <- p
    cost_per_km(car, sc, km_aar, years)$total_dkk_aar - target_aar
  }
  if (sign(f(lo)) == sign(f(hi))) {
    return(NA_real_)
  }
  uniroot(f, c(lo, hi), tol = 1)$root
}

#' The same table across the low / central / high settings
#'
#' `scenarios` is a named list of scenario lists. Bound into one long frame with
#' a `setting` column so the range charts can pivot on it.
cost_across <- function(cars, scenarios, km_aar, years) {
  imap_dfr(scenarios, \(sc, nm) cost_per_km(cars, sc, km_aar, years) |>
    mutate(setting = nm, .before = 1))
}

#' Annual distance at which two cars cost the same in total
#'
#' Total cost per km is fixed/d + marginal(d). Marginal depends on d only
#' weakly, through the mid-hold odometer and the service interval, so the
#' crossing is found numerically rather than solved. Returns NA when the two
#' never cross inside the bracket, which is the common and informative case:
#' one car simply dominates.
break_even_km <- function(cars, sc, id_a, id_b, years, lo = 2000, hi = 80000) {
  gap <- function(d) {
    x <- cost_per_km(cars, sc, d, years)
    a <- x$total_dkk_km[x$id == id_a]
    b <- x$total_dkk_km[x$id == id_b]
    a - b
  }
  if (sign(gap(lo)) == sign(gap(hi))) {
    return(NA_real_)
  }
  uniroot(gap, c(lo, hi), tol = 1)$root
}

#' Electricity price at which a BEV's ENERGY cost per km equals a comparator's
#'
#' The single most useful inversion in the note: it turns "is electric cheaper"
#' into a number the reader can check against a charging tariff.
el_price_break_even <- function(wh_km_real, l_100_real, fuel_dkk_l) {
  stopifnot(wh_km_real > 0)
  (l_100_real / 100 * fuel_dkk_l) / (wh_km_real / 1000)
}
