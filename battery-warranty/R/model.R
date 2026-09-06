# Analytic core for the battery-warranty note.
#
# Everything here is closed-form or 1-D/2-D numerical integration; there is no
# Monte Carlo. The chat-session code simulated 1e6 draws, which is unusable for
# calibration A where gap probabilities reach ~1e-4.
#
# Model (capacity loss in percentage points, x = r * t):
#
#   L(t, x) = Z * (a * sqrt(t) + b * x),   Z ~ lognormal(-sd^2/2, sd), unit mean
#
# Failure is the first passage of L through d_crit. Conditional on a fixed usage
# rate r this is a statement about Z alone, so the conditional CDF is exact.

suppressPackageStartupMessages(library(tidyverse))

options(scipen = 999)

# --- degradation coefficients ------------------------------------------------

#' Calendar and throughput coefficients of the degradation model
#'
#' `a` is fixed by the stated calendar loss at 10 years; `b` by the requirement
#' that a vehicle at 10 years and `km_crit_pure` km sits exactly on the
#' threshold. Both are per unit of Z.
deg_coefs <- function(calendar_loss_10y, km_crit_pure, d_crit) {
  stopifnot(
    calendar_loss_10y > 0,
    calendar_loss_10y < d_crit,
    km_crit_pure > 0
  )

  list(
    a = calendar_loss_10y / sqrt(10),
    b = (d_crit - calendar_loss_10y) / km_crit_pure
  )
}

#' Odometer at which the throughput term alone exhausts the threshold budget
#'
#' Recovers `km_crit_pure` by construction, but computed from the coefficients
#' so section 4's boxed result follows the parameters rather than hardcoding.
x_crit <- function(calendar_loss_10y, km_crit_pure, d_crit) {
  co <- deg_coefs(calendar_loss_10y, km_crit_pure, d_crit)
  (d_crit - calendar_loss_10y) / co$b
}

# --- conditional first-passage distribution ----------------------------------

#' Mean loss path per unit of Z: a*sqrt(t) + b*r*t
loss_path <- function(t, rate, a, b) a * sqrt(t) + b * rate * t

#' P(T_fail <= t | R = r), exact
#'
#' Failure by t iff Z >= d_crit / (a*sqrt(t) + b*r*t). Z is lognormal, so this
#' is a normal tail probability with no simulation error.
failure_cdf <- function(t, rate, a, b, sd_unit, d_crit) {
  stopifnot(rate > 0, b > 0, sd_unit > 0)

  m <- loss_path(t, rate, a, b)
  z <- (log(m) - log(d_crit) - sd_unit^2 / 2) / sd_unit

  ifelse(t <= 0, 0, pnorm(z))
}

#' Conditional density f(t | R = r)
#'
#' d/dt pnorm(q(t)) with q(t) = (log m(t) - log d_crit - sd^2/2) / sd.
failure_pdf <- function(t, rate, a, b, sd_unit, d_crit) {
  m <- loss_path(t, rate, a, b)
  m_prime <- a / (2 * sqrt(t)) + b * rate
  q <- (log(m) - log(d_crit) - sd_unit^2 / 2) / sd_unit

  ifelse(t <= 0, 0, dnorm(q) * m_prime / (m * sd_unit))
}

#' Closed-form crossing time for a given heterogeneity draw (kept for the
#' optional simulation cross-check and for reasoning about the quadratic)
t_fail <- function(rate, unit, a, b, d_crit) {
  stopifnot(rate > 0, b > 0)
  ((-a + sqrt(a^2 + 4 * b * rate * d_crit / unit)) / (2 * b * rate))^2
}

# --- warranty geometry -------------------------------------------------------

#' Effective term in years once the mileage cap is projected onto the age axis
warranty_term <- function(rate, years, cap_km) pmin(years, cap_km / rate)

#' Distance-indexed persistency
#'
#' Checks fall due every `increment_km` beyond the base, so lapse is indexed on
#' the odometer, not the calendar. Two regimes, and they differ enormously:
#'
#' "permanent" — one missed check destroys the cover for good, so survival
#' decays geometrically in the number of checks.
#'
#' "reinstatable" — a missed check suspends cover until the next completed one,
#' which activates a fresh term. Survival is then just the probability that the
#' current window's check was done, independent of how many were missed before.
#'
#' Toyota Denmark's published terms point to the second: a new battery
#' guarantee can be activated by a health check at any time up to the ceiling,
#' and the Relax conditions state that missing a service "diskvalificerer dette
#' dig ikke til fremtidig dækning", with cover resuming 30 days after the next
#' completed service.
coverage_held <- function(km, pi_check, base_km, increment_km,
                          mode = c("reinstatable", "permanent")) {
  mode <- match.arg(mode)

  if (mode == "permanent") {
    pi_check^pmax(0, (km - base_km) / increment_km)
  } else {
    ifelse(km > base_km, pi_check, 1)
  }
}

#' Number of health checks needed to ride coverage to odometer `km`
checks_required <- function(km, base_km, increment_km, from_zero = FALSE) {
  extra <- pmax(0, (km - base_km) / increment_km)
  if (from_zero) extra + base_km / increment_km else extra
}

# --- fleet-level claim rates -------------------------------------------------

#' Usage-rate density, integrated on the log scale
#'
#' Integrating over s = log(r) with a normal density is better behaved than
#' integrating a lognormal over (0, Inf).
integrate_over_rate <- function(fun, med_rate, sdlog_rate, ...) {
  meanlog <- log(med_rate)

  integrand <- function(s) {
    map_dbl(s, \(si) fun(exp(si))) * dnorm(s, meanlog, sdlog_rate)
  }

  integrate(
    integrand,
    lower = meanlog - 10 * sdlog_rate,
    upper = meanlog + 10 * sdlog_rate,
    ...
  )$value
}

#' Expected claims per vehicle sold, conditional on usage rate
#'
#' With full compliance this is just F(W(r) | r). With lapse the persistency
#' factor depends on the odometer at failure, so it has to sit inside the time
#' integral: int_0^W p(r*t) f(t|r) dt.
claim_rate_given_rate <- function(rate, years, cap_km, a, b, sd_unit, d_crit,
                                  pi_check = 1, base_km = 160000,
                                  increment_km = 15000,
                                  lapse_mode = "reinstatable") {
  w <- warranty_term(rate, years, cap_km)
  if (w <= 0) return(0)

  if (pi_check >= 1) {
    return(failure_cdf(w, rate, a, b, sd_unit, d_crit))
  }

  # Reinstatement puts a step in the integrand at the base odometer, which
  # integrate() handles badly. It is also unnecessary: cover is 1 below the
  # step and pi above it, so the integral is just a weighted sum of two CDF
  # differences.
  if (lapse_mode == "reinstatable") {
    t_base <- min(base_km / rate, w)
    f_base <- failure_cdf(t_base, rate, a, b, sd_unit, d_crit)
    f_w <- failure_cdf(w, rate, a, b, sd_unit, d_crit)
    return(f_base + pi_check * (f_w - f_base))
  }

  integrand <- function(t) {
    coverage_held(rate * t, pi_check, base_km, increment_km, lapse_mode) *
      failure_pdf(t, rate, a, b, sd_unit, d_crit)
  }

  integrate(integrand, lower = 0, upper = w, rel.tol = 1e-10)$value
}

#' Fleet-level expected claims per vehicle sold
claim_rate <- function(years, cap_km, a, b, sd_unit, d_crit,
                       med_rate, sdlog_rate, pi_check = 1,
                       base_km = 160000, increment_km = 15000,
                       lapse_mode = "reinstatable") {
  integrate_over_rate(
    \(r) claim_rate_given_rate(
      r, years, cap_km, a, b, sd_unit, d_crit,
      pi_check, base_km, increment_km, lapse_mode
    ),
    med_rate = med_rate,
    sdlog_rate = sdlog_rate,
    rel.tol = 1e-10
  )
}

#' Share of the fleet whose usage rate exceeds the cap-implied threshold K/T
fleet_truncated <- function(cap_km, years, med_rate, sdlog_rate) {
  plnorm(cap_km / years, log(med_rate), sdlog_rate, lower.tail = FALSE)
}

# --- buyer-level valuation ---------------------------------------------------

#' PV of the contract gap for a buyer with a known usage rate
#'
#' Fully real: severity is stated in today's DKK and declines in real terms, so
#' it is discounted at a real rate. `t_bar` is the conditional mean crossing
#' time inside the gap window, computed by integration rather than MC.
#' `horizon_years` truncates the gap window at the point the buyer expects to
#' sell. Value falling after it is not lost, but it accrues to the next owner
#' and reaches this buyer only through the resale price.
gap_value <- function(rate, a, b, sd_unit, d_crit,
                      years, toyota_ceiling_km, subaru_ceiling_km,
                      severity_dkk, severity_decline, discount_real,
                      repair_worthy, horizon_years = Inf,
                      subaru_years = years, cover_from = 0) {
  # subaru_years lets the Subaru side carry a different age ceiling, which is
  # needed to test what happens if its extension does not in fact cover the
  # traction battery and only the shorter base term applies.
  # `cover_from` raises the start of the gap window: under a mixed servicing
  # strategy the Toyota owner has no live cover until they return to the
  # dealer, so crossings before that point are not in the gap either.
  term_subaru <- max(warranty_term(rate, subaru_years, subaru_ceiling_km),
                     cover_from)
  term_toyota <- min(warranty_term(rate, years, toyota_ceiling_km),
                     horizon_years)

  f_sub <- failure_cdf(term_subaru, rate, a, b, sd_unit, d_crit)
  f_toy <- failure_cdf(term_toyota, rate, a, b, sd_unit, d_crit)
  p_gap <- f_toy - f_sub

  # Degenerate window: the two contracts coincide at or below cap/T, so the gap
  # is exactly zero and t_bar is undefined. Return 0 rather than letting NaN
  # propagate into the tables.
  if (term_toyota - term_subaru <= .Machine$double.eps^0.5 || p_gap <= 0) {
    return(tibble(
      rate = rate,
      term_subaru = term_subaru,
      term_toyota = term_toyota,
      p_gap = 0,
      t_bar = NA_real_,
      pv_dkk = 0
    ))
  }

  t_bar <- integrate(
    \(t) t * failure_pdf(t, rate, a, b, sd_unit, d_crit),
    lower = term_subaru,
    upper = term_toyota,
    rel.tol = 1e-10
  )$value / p_gap

  tibble(
    rate = rate,
    term_subaru = term_subaru,
    term_toyota = term_toyota,
    p_gap = p_gap,
    t_bar = t_bar,
    pv_dkk = p_gap * severity_dkk * (1 - severity_decline)^t_bar /
      (1 + discount_real)^t_bar * repair_worthy
  )
}

# --- servicing cost ----------------------------------------------------------

#' The actual visit schedule: one service every `increment_km`, alternating
#'
#' Danish Toyota pricing puts a small service at odd multiples of the interval
#' and a large one at even multiples, so an owner alternates. Enumerating the
#' visits explicitly is both exact and closer to the published schedule than
#' averaging the two prices over a continuous stream.
service_schedule <- function(rate, increment_km, to_year) {
  if (rate <= 0 || to_year <= 0) {
    return(tibble(k = integer(), year = numeric(), large = logical()))
  }

  n <- floor(rate * to_year / increment_km)
  if (n < 1) return(tibble(k = integer(), year = numeric(), large = logical()))

  tibble(k = seq_len(n)) |>
    mutate(
      year = increment_km * k / rate,
      large = k %% 2 == 0
    )
}

#' PV of a set of visits priced at a given small/large pair
pv_schedule <- function(sched, price_small, price_large, discount_real) {
  if (nrow(sched) == 0) return(0)

  price <- ifelse(sched$large, price_large, price_small)
  sum(price / (1 + discount_real)^sched$year)
}

#' PV of the servicing cost difference between owning the Toyota and the Subaru
#'
#' Both cars need the same visits at the same intervals; what differs is where
#' they must happen and what each network charges. The Toyota owner must use a
#' Toyota dealer for every visit to keep the cover alive. The Subaru owner must
#' use a Subaru dealer only while Subaru's cover is live, and may use an
#' independent afterwards — unless they would use a franchised dealer
#' regardless, in which case they stay with Subaru to the end.
#'
#' `prices` is a list of small/large pairs named toyota, subaru and independent.
#'
#' `horizon_years` stops the clock at the sale date. A seller pays only for the
#' visits they make, even though the cover they hand on was bought with them.
#' `dealer_from` implements a mixed strategy: use an independent up to that
#' year and a franchised dealer from then on. Because cover is reinstatable, a
#' buyer can suspend and resume rather than committing for the whole term. It
#' applies to both cars, so it is the strategy being compared, not a handicap
#' given to one make.
servicing_differential <- function(rate, years, subaru_ceiling_km, increment_km,
                                   prices, discount_real, horizon_years = Inf,
                                   dealer_anyway = FALSE, dealer_from = 0) {
  end <- min(years, horizon_years)
  subaru_covered_to <- min(subaru_ceiling_km / rate, end)
  subaru_tied_to <- if (dealer_anyway) end else subaru_covered_to

  visits <- service_schedule(rate, increment_km, end)

  # Price every visit twice: once for the Toyota path, once for the Subaru one.
  # Before `dealer_from` both owners use an independent, so those visits carry
  # the same price on both paths and drop out of the difference.
  at_dealer <- visits$year >= dealer_from
  toy_side <- visits |> filter(at_dealer)
  toy_indep <- visits |> filter(!at_dealer)

  sub_side <- visits |> filter(at_dealer & year <= subaru_tied_to)
  sub_indep <- visits |> filter(!at_dealer | year > subaru_tied_to)

  pv_toy <- pv_schedule(toy_side, prices$toyota[1], prices$toyota[2], discount_real) +
    pv_schedule(toy_indep, prices$independent[1], prices$independent[2], discount_real)
  pv_sub <- pv_schedule(sub_side, prices$subaru[1], prices$subaru[2], discount_real) +
    pv_schedule(sub_indep, prices$independent[1], prices$independent[2], discount_real)

  tibble(
    rate = rate,
    visits_total = nrow(visits),
    visits_at_toyota = nrow(toy_side),
    visits_tied_subaru = nrow(sub_side),
    visits_freed = nrow(sub_indep),
    pv_toyota = pv_toy,
    pv_subaru = pv_sub,
    pv_dkk = pv_toy - pv_sub
  )
}

#' Cover given up by suspending dealer servicing until `dealer_from`
#'
#' Distinct from the Toyota-vs-Subaru gap, and it applies to whichever car is
#' bought. The base guarantee runs unconditionally to `base_km`; after that,
#' cover is live only while checks are being made. A buyer who goes independent
#' from the base expiry until `dealer_from` is uncovered in between, and this
#' is the PV of the claims that would fall in that window.
#'
#' It cancels out of the make-versus-make comparison, because both owners face
#' it equally. It does not cancel out of the decision to use an independent.
suspended_exposure <- function(rate, a, b, sd_unit, d_crit, years,
                               base_km, dealer_from, severity_dkk,
                               severity_decline, discount_real, repair_worthy) {
  t_base <- base_km / rate
  lo <- min(t_base, years)
  hi <- min(dealer_from, years)
  if (hi <= lo) return(tibble(from_year = lo, to_year = lo, p = 0, pv_dkk = 0))

  p <- failure_cdf(hi, rate, a, b, sd_unit, d_crit) -
    failure_cdf(lo, rate, a, b, sd_unit, d_crit)
  if (p <= 0) return(tibble(from_year = lo, to_year = hi, p = 0, pv_dkk = 0))

  t_bar <- integrate(
    \(t) t * failure_pdf(t, rate, a, b, sd_unit, d_crit),
    lower = lo, upper = hi, rel.tol = 1e-10
  )$value / p

  tibble(
    from_year = lo,
    to_year = hi,
    p = p,
    pv_dkk = p * severity_dkk * (1 - severity_decline)^t_bar /
      (1 + discount_real)^t_bar * repair_worthy
  )
}

#' Independent-workshop price at which the higher ceiling exactly breaks even
#'
#' Raising the independent price raises the Subaru owner's cost on the visits
#' they have been freed from, which shrinks the differential. So there is a
#' price above which the ceiling pays and below which it does not. With the
#' Toyota schedule now priced from a real tariff, this is the inversion that
#' matters: it says what an independent quote would have to beat.
#'
#' Returns the break-even price of the SMALL service; the large one scales at
#' whatever ratio the supplied independent pair has.
breakeven_independent <- function(gap_pv_dkk, rate, years, subaru_ceiling_km,
                                  increment_km, prices, discount_real,
                                  dealer_anyway = FALSE) {
  end <- min(years, Inf)
  subaru_tied_to <- if (dealer_anyway) end else min(subaru_ceiling_km / rate, end)

  visits <- service_schedule(rate, increment_km, end)
  freed <- visits |> filter(year > subaru_tied_to)
  if (nrow(freed) == 0) return(NA_real_)

  pv_toy <- pv_schedule(visits, prices$toyota[1], prices$toyota[2], discount_real)
  pv_tied <- pv_schedule(visits |> filter(year <= subaru_tied_to),
                         prices$subaru[1], prices$subaru[2], discount_real)
  # PV of the freed visits at one unit of the independent price pair.
  pv_freed_unit <- pv_schedule(freed, prices$independent[1] / prices$independent[1],
                               prices$independent[2] / prices$independent[1],
                               discount_real)

  # gap = pv_toy - (pv_tied + P_small * pv_freed_unit)  =>  solve for P_small.
  # pv_freed_unit is already per unit of the small price, so the quotient IS
  # that price and must not be rescaled again.
  (pv_toy - pv_tied - gap_pv_dkk) / pv_freed_unit
}

# --- resale of unused cover --------------------------------------------------

#' Split the gap value into what a seller realises and what they hand on
#'
#' A buyer who sells at `sale_year` claims only inside the part of the gap
#' window they still own. The rest is not destroyed: it is remaining cover the
#' next owner inherits, and a rational second-hand market pays for it.
#'
#' Note the identity this enforces. Viewed from time zero, the expected value
#' handed on is exactly the full gap value less the part captured, because the
#' seller only collects a resale premium in the states where no claim has
#' already been made. So with full capitalisation the holding period would not
#' matter at all; it matters only through the frictions applied outside this
#' function (partial capitalisation, and compliance cost paid before sale).
#'
#' `wtp_at_sale` is the same residual expressed as the extra a second owner
#' should pay at the point of sale, in year-`sale_year` money, conditional on
#' the car not having claimed yet. That is the directly checkable number: it is
#' what the Toyota ought to fetch over the Subaru on the used market.
#'
#' Simplification: a pack replaced under Subaru cover before the sale would
#' reset degradation, which is not modelled. That path requires a claim inside
#' the base term, so it is second order for the benign calibration.
resale_split <- function(rate, a, b, sd_unit, d_crit,
                         years, toyota_ceiling_km, subaru_ceiling_km,
                         severity_dkk, severity_decline, discount_real,
                         repair_worthy, sale_year) {
  args <- list(rate, a, b, sd_unit, d_crit, years, toyota_ceiling_km,
               subaru_ceiling_km, severity_dkk, severity_decline,
               discount_real, repair_worthy)

  full <- do.call(gap_value, c(args, horizon_years = Inf))$pv_dkk
  held <- do.call(gap_value, c(args, horizon_years = sale_year))$pv_dkk

  residual <- full - held
  survival <- 1 - failure_cdf(sale_year, rate, a, b, sd_unit, d_crit)

  tibble(
    sale_year = sale_year,
    gap_full = full,
    captured_pv = held,
    residual_pv = residual,
    survival = survival,
    wtp_at_sale = if (survival > 0) {
      residual * (1 + discount_real)^sale_year / survival
    } else {
      0
    }
  )
}

#' Total value of the higher ceiling to a buyer who sells at `sale_year`
#'
#' Claims made while owning it, plus the share of the handed-on cover that the
#' used-car market actually pays for, less the extra servicing paid before the
#' sale.
holding_value <- function(rate, a, b, sd_unit, d_crit,
                          years, toyota_ceiling_km, subaru_ceiling_km,
                          severity_dkk, severity_decline, discount_real,
                          repair_worthy, sale_year, increment_km,
                          prices, resale_capitalisation,
                          dealer_anyway = FALSE) {
  s <- resale_split(rate, a, b, sd_unit, d_crit, years, toyota_ceiling_km,
                    subaru_ceiling_km, severity_dkk, severity_decline,
                    discount_real, repair_worthy, sale_year)

  cost <- servicing_differential(rate, years, subaru_ceiling_km, increment_km,
                                 prices, discount_real,
                                 horizon_years = sale_year,
                                 dealer_anyway = dealer_anyway)$pv_dkk

  s |>
    mutate(
      resale_pv = residual_pv * resale_capitalisation,
      compliance_pv = cost,
      net_pv = captured_pv + resale_pv - cost
    )
}

# --- decision inversions -----------------------------------------------------

# --- optional simulation cross-check -----------------------------------------

#' Monte Carlo path, retained only to cross-check the analytic results
simulate_fleet <- function(n, a, b, sd_unit, d_crit,
                           med_rate, sdlog_rate, fixed_rate = NULL, seed = NULL) {
  if (!is.null(seed)) set.seed(seed)

  rate <- if (is.null(fixed_rate)) {
    rlnorm(n, log(med_rate), sdlog_rate)
  } else {
    rep(fixed_rate, n)
  }

  tibble(
    rate = rate,
    unit = rlnorm(n, -0.5 * sd_unit^2, sd_unit)
  ) |>
    mutate(
      t_fail = t_fail(rate, unit, a, b, d_crit),
      km_fail = rate * t_fail
    )
}
