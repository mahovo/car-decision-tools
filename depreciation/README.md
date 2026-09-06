# Bilbasen depreciation analysis

Estimate average **annual depreciation** per car brand from used-car listings on
[bilbasen.dk](https://www.bilbasen.dk), for personal use.

## Pipeline

```
scrape_bilbasen.py   ->   bilbasen_data.csv   ->   analyze_depreciation.R
   (Python/Playwright)        (one row/car)            (base R)
```

## What & why

`kontantpris` and the first-registration year are read for each listing; `age =
current_year − reg_year`. Depreciation is estimated two ways:

- **(A) Statistical (primary).** Per brand, `lm(log(kontantpris) ~ age)`. The age
  coefficient `b` implies a constant proportional loss of `1 − e^b` per year.
  A second model adds `log(mileage)` to hold usage constant. This is the
  backbone — it needs only price + year, which every listing has.
- **(B) Direct nypris check.** `nypris` (new price) has **no structured field** on
  bilbasen; it only appears sporadically in free-text descriptions, so it's
  regex-extracted opportunistically and used only as a sparse cross-check.

## Why Playwright (not requests/rvest)

bilbasen sits behind **AWS WAF**'s JavaScript challenge — HTTP libraries get an
empty `HTTP 202`. Playwright drives a real Chromium that solves the challenge
automatically (one solve per session, cookie reused). Data is read from the
page's embedded `__NEXT_DATA__` JSON, not scraped from HTML.

## Politeness / compliance

robots.txt disallows query-string URLs (`*?*`) but allows pagination (`*page=*`).
The scraper only requests path-based brand pages (`/brugt/bil/<slug>`) and the
site's own `page=N` links, with randomised 3–6 s delays. Low volume, personal use.

## Run it

```bash
# scrape (config at top of the file; or override via env)
.venv/bin/python scrape_bilbasen.py
#   BILBASEN_BRANDS=vw,kia BILBASEN_MAXPAGES=2 .venv/bin/python scrape_bilbasen.py

# analyse
Rscript analyze_depreciation.R
```

Defaults: 20 brands, up to 10 pages (~300 cars) each.

## Outputs

- `bilbasen_data.csv` — raw listings (re-running appends; dupes skipped per run).
  **Not distributed with this repository — see below.**
- `depreciation_by_brand.csv` — per-brand annual depreciation %.
- `depreciation_curves.pdf` — price-vs-age scatter + fitted curve per brand.

## Data availability

`bilbasen_data.csv` is **not** published here. It is a bulk extract of
bilbasen.dk's listing database — around 9,700 adverts — and republishing it would
be a substantial re-utilisation of a database protected under the EU database
directive (in Denmark, ophavsretsloven § 71), quite apart from bilbasen's own
terms. What is published instead:

- the **derived aggregates** — `depreciation_by_brand.csv`,
  `../depreciation_by_fueltype.csv`, `../fuel-cost/mileage_elasticity.csv` — which
  are statistics about the market, not a copy of it;
- `solterra_bz4x_data.csv`, a ~100-row single-model extract kept for the case
  study in section 5, with the columns that point at an individual advert
  (`external_id`, `uri`) and locate its seller (`zip`, `region`) removed, and
  private-seller rows dropped;
- the rendered `analyze_depreciation.html`, which is the record of what the full
  dataset showed on the date it was pulled.

**Consequence: `analyze_depreciation.Rmd` and `analyze_depreciation.R` will not
run as shipped** — they read `bilbasen_data.csv` directly. Run
`scrape_bilbasen.py` first to regenerate an equivalent file. The same applies to
`../depreciation_by_fueltype.R`, `../fuel-cost/mileage_elasticity.R` and
`../fuel-cost/comparator_prices.R`; their committed outputs are what the other
notes actually consume, so those notes knit unchanged.

## Caveats

- **Cross-sectional, not longitudinal.** We compare *different* cars of different
  ages at one point in time, not the same car aging. Brand model-mix shifts over
  years (e.g. more EVs recently) confound the age signal somewhat.
- "modelår" here = **first-registration year** (what bilbasen exposes on cards).
- Asking prices, not transaction prices; dealer cars skew newer.
- Low-price/old outliers are filtered in the R script to stabilise the log fit.
