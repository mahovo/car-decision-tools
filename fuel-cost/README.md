# Cost per kilometre by fuel source

What a kilometre actually costs in Denmark in 2026, by powertrain, with the
**Toyota bZ4X Touring AWD** (369,990 DKK trim) as the reference car and petrol,
diesel and plug-in hybrid wagons and SUVs as comparators.

**Every car in the fleet is all-wheel drive**, matching the reference car, and
the Rmd refuses to knit if one is not. That is the right like-for-like call — a
front-wheel-drive comparator would be cheaper, lighter and more economical for
reasons that have nothing to do with its fuel — but it is not costless. It taxes
the electric car too (153 vs 140 Wh/km for the same bZ4X), and it narrows the
choice sharply: there is no AWD petrol Octavia sold in Denmark at all, and no new
AWD combustion car in this class comes in under the 370,000 DKK cap. Section 1.3
sets out what the constraint does before any number is read.

## Pipeline

```
                              ->  mileage_elasticity.R  ->  mileage_elasticity.csv
depreciation/bilbasen_data.csv  -|                                     |
                              ->  comparator_prices.R  ->  fuel-cost-cars.csv
                                          |                         |
                                comparator-listings.csv             |
                                                                    |
                     periodic-tax-rates.csv  ------------------->  +
                   energy-price-history.csv  ------------------->  +
                                                                    |
                                 R/fuel_model.R  --------------->  fuel-cost-per-km.Rmd
```

`comparator_prices.R` replaces guessed used-car prices with figures derived from
real bilbasen listings: it matches on make, model, fuel, registration-year window
and a variant pattern that identifies all-wheel drive (bilbasen has no structured
drivetrain field), then fits `log(price) ~ log(mileage)` and reads the price off
at each car's target odometer. Cars with too few matching listings are left as
placeholders and reported as such. `comparator-listings.csv` is the audit trail.

Both consumers de-duplicate the scrape by listing id, keeping the most recent
row: the scraper dedupes within a run but appends across runs, so without this a
long-standing advert would count several times — biasing towards cars that are
not selling.

**Data availability.** `depreciation/bilbasen_data.csv`, the raw scrape at the top
of that diagram, is not distributed with this repository — see
`depreciation/README.md` for why. Its two outputs, `mileage_elasticity.csv` and
`fuel-cost-cars.csv`, *are* committed, so **`fuel-cost-per-km.Rmd` knits as
shipped**; only the two scripts that regenerate them need the scrape re-run
first. `comparator-listings.csv` is published with its `uri` column removed, so
it remains an audit trail of *which cars* set each price without being a set of
pointers into bilbasen's database.

## Three questions, kept apart

The note answers three questions that are usually run together, and gives
different answers to each.

- **Marginal cost** (sections 2-6) is what a kilometre causes: energy, tyres,
  distance-triggered servicing, consumables, repair hazard, the resale value the
  odometer destroys, and the periodiske afgifter the state ties directly to fuel
  type and fuel economy. Holding the car fixed there is no trade-off, and the
  electric cars win outright.
- **Price-free running cost at matched mileage** (section 7) removes the two
  confounds in the fleet. A representative car of each fuel type, built from the
  fleet medians, is evaluated at the *same* odometer, on a cost containing no
  capital at all. This is the cleanest answer to "which powertrain is cheapest to
  run", and it is stable in the odometer rather than crossing. With only three or
  four AWD cars per fuel the median is not robust, so section 8.4 switches to one
  *named* car per powertrain — the conservative and attributable choice.
- **Total cost of ownership** (section 8) puts the capital back. The result is
  not a fuel but a **break-even cash price**: how much more an electric car may
  cost and still be no dearer to own. That premium scales with annual distance,
  and above roughly 40,000 km/yr no petrol price closes the gap at all.

Section 1.4 sets out why the odometer has to be an axis rather than a chosen
value, and which cost components are genuinely independent of the cash price.

## What is sourced and what is not

**Sourced:** pump prices (September 2026), the electricity tariff ladder and the
2026-27 elafgift cut, the bZ4X price and WLTP consumption, the Toyota service
tariff, and the CO2-ejerafgift bracket table including the diesel
udligningsafgift. These drive the headline.

**Estimated here:** the odometer elasticity of used prices, fitted by
`mileage_elasticity.R` on the repository's own bilbasen scrape.

**Approximate:** the km/l side of `periodic-tax-rates.csv`. The statute runs four
scales (petrol and diesel, each split at 3 October 2017) and the note collapses
them to one per fuel; secondary sources also disagree with the official scale at
the most efficient bracket. Section 6.2 names both gaps. If you verify better
figures against Motorstyrelsen, correct the CSV rather than the code.

**Placeholders:** prices, consumption and service costs for every car except the
bZ4X, plus insurance throughout. These drive section 8, so replace them
before relying on it — `depreciation/scrape_bilbasen.py` pulls the listings and the
CSV columns were chosen to be fillable from them.

Section 1.1 of the rendered note carries the same table with the specific
sources.

## Run it

```bash
Rscript "fuel-cost/mileage_elasticity.R"
```

```bash
Rscript "fuel-cost/comparator_prices.R"
```

```bash
Rscript -e 'rmarkdown::render("fuel-cost/fuel-cost-per-km.Rmd")'
```

Both scripts must be run from the repository root (they read `depreciation/`); the
Rmd resolves its own paths relative to this directory. To refresh the listings
first:

```bash
cd depreciation && BILBASEN_BRANDS=vw,skoda,subaru,volvo,hyundai,toyota,tesla .venv/bin/python scrape_bilbasen.py
```

## Setting it to your own situation

Everything a reader needs to change is in the YAML parameter block, plus one
table in the `profiles` chunk:

| Where | What |
|---|---|
| `my_km_aar`, `my_years` | annual distance and holding period |
| `my_profile` | which row of the charging-mix table applies to you |
| `profiles` chunk | the charging mixes themselves, as shares over five price tiers |
| `petrol_dkk_l`, `diesel_dkk_l`, `el_*` | energy prices, each `[low, central, high]` — the range is the 8-year level, not today's station spread |
| `station_spread_dkk_l` | the separate cross-sectional spread between cheap and expensive pumps |
| `gap_ice`, `gap_ev` | how far real consumption runs above WLTP |
| `hazard_slope` | the repair ramp beyond 100,000 km — the weakest number in the note |
| `udligning_factor` | 1.0 for 2026; about 1.13 once the temporary diesel relief drops in 2027 |
| `odo_grid`, `price_panel_odo` | the odometer levels sections 7 and 8 compare at |
| `require_awd`, `price_cap_dkk` | the drivetrain and price constraints, both checked at knit time |
| `fuel-cost-cars.csv` | the fleet — every row must have `drivetrain = AWD` |
| `periodic-tax-rates.csv` | the statutory bracket tables, so they can be updated without touching code |

## Caveats

- **The energy price bands are holding-period bands, not today's spread.** Pump
  prices are at record highs, so the bands are drawn asymmetrically downwards
  from a seven-year history (section 2.4), and electricity is widened on the same
  logic — widening only the fossil side would rig the comparison. Across the
  whole petrol band the justified electric premium moves by around 130,000 DKK,
  but its sign never changes (section 9.4).
- **Charging mix is the largest lever an electric owner controls**, worth around
  50 øre/km between full home night charging and none at all. It is a separate
  axis (section 4.3), not folded into the price ranges.
- **The electric depreciation elasticity is fragile.** Its sign flips when the
  regression controls change; `mileage_elasticity.csv` reports both fits and
  section 5.4 says why the controlled one is preferred and how much rests on it.
- **Two tax measures in the note are temporary and both expire.** The elafgift
  cut runs to end-2027 (section 9.3); the 30 % cut in the diesel udligningsafgift
  drops to 21 % from 2027 (section 6.3). Road transport also enters the EU
  emissions trading system in 2027. An 8-year hold outlives all three.
- **Battery degradation is not priced here.** That question has its own note in
  `battery-warranty/`.
- Company-car taxation (*fri bil*) changes the arithmetic completely and is out
  of scope.
