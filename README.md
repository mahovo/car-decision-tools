# Advanced Decision Tools Built with Claude Code

**Co-written by Claude Code Opus 5 · Directed by Martin Hoshi Vognsen**

Eight reproducible analyses of a single ordinary question — *which car to buy* —
worked to the point where the answer stops depending on taste.

**→ Read them at [mahovo.github.io/car-decision-tools](https://mahovo.github.io/car-decision-tools/)**

Each note is an R Markdown document that states its assumptions in one parameter
block at the top, sources what can be sourced, labels what cannot, and shows the
mileage or price at which its own conclusion reverses. They are working notes
about one purchase decision in Denmark in 2026, not advice.

## The notes

| Note | Question | Language | Source |
|---|---|---|---|
| [Cost per kilometre by fuel source](https://mahovo.github.io/car-decision-tools/fuel-cost-per-km.html) | What does a kilometre cost by powertrain, and where does the cheapest kilometre stop being the cheapest car? | English | [`fuel-cost/`](fuel-cost/) |
| [Toyota vs Subaru battery warranties](https://mahovo.github.io/car-decision-tools/warranty-analysis.html) | Two near-identical guarantees on the same hardware — what is the difference worth? | English | [`battery-warranty/`](battery-warranty/) |
| [Used-car depreciation by brand](https://mahovo.github.io/car-decision-tools/depreciation-by-brand.html) | How fast does each brand lose value, holding mileage constant? | English | [`depreciation/`](depreciation/) |
| [Leasing vs. kontant- og lånefinansieret køb](https://mahovo.github.io/car-decision-tools/leasing-vs-kontant.html) | Totaløkonomi pr. år med alternativomkostning, holdeperiode og ekstra-km | Dansk | [`leasing_vs_kontant.Rmd`](leasing_vs_kontant.Rmd) |
| [Drivetrain torque split and lateral tyre capacity](https://mahovo.github.io/car-decision-tools/drivetrain-lateral-capacity.html) | How much lateral grip does AWD actually buy on a slippery surface? | English | [`drivetrain-lateral-capacity.Rmd`](drivetrain-lateral-capacity.Rmd) |
| [Bilsammenligning — vægtet pointmodel](https://mahovo.github.io/car-decision-tools/pointmodel-store-biler.html) | Otte prioriterede kriterier, vilkårligt mange biler | Dansk | [`store_biler.Rmd`](store_biler.Rmd) |
| [Små biler — vægtet pointmodel](https://mahovo.github.io/car-decision-tools/pointmodel-smaa-biler.html) | Billige, fabriksnye automatgear-biler | Dansk | [`smaa_biler.Rmd`](smaa_biler.Rmd) |
| [Små elbiler — vægtet pointmodel](https://mahovo.github.io/car-decision-tools/pointmodel-smaa-elbiler.html) | Billige, fabriksnye små elbiler | Dansk | [`smaa_elbiler.Rmd`](smaa_elbiler.Rmd) |

Three of the modules have their own README going into the method:
[`fuel-cost/README.md`](fuel-cost/README.md) and
[`depreciation/README.md`](depreciation/README.md).

## Layout

```
battery-warranty/     warranty valuation — analytic core in R/model.R
fuel-cost/            cost per km — model in R/fuel_model.R, fleet in fuel-cost-cars.csv
depreciation/         bilbasen scraper (Python/Playwright) + depreciation analysis
docs/                 site shell (index.html) and the one render CI cannot rebuild
*.Rmd (root)          the notes that share depreciation_by_fueltype.csv
build.R               renders every note into docs/
tools/                check-publishable.sh, the gate in front of every publish
```

Root-level notes sit at the root deliberately: they read
`depreciation_by_fueltype.csv` from their own directory, so they and it stay at
the same level.

## Running it

Needs R (tested on 4.5.2) with `rmarkdown`, `knitr`, `kableExtra`, `tidyverse`,
`ggrepel` and `scales`. Nothing else, and no R package to install — the notes
`source()` their model files directly.

```bash
Rscript build.R
```

Or only the notes whose path matches:

```bash
Rscript build.R fuel-cost
```

Output lands in `docs/` for local preview. The scraper additionally needs Python
with `playwright` (and `playwright install chromium`).

## Publishing

**Push to `main`; the site updates itself.** The
[workflow](.github/workflows/deploy-site.yml) renders every note on a clean
Ubuntu runner and deploys `docs/` to GitHub Pages, typically within ten minutes.
Rendered HTML is not committed — CI is the only thing that builds the site.

Two things to know:

- **If anything fails, nothing is deployed.** A note that will not render, or a
  failed publishability check, leaves the site at its last good version. Check
  the *Actions* tab when a change does not appear.
- **`depreciation/analyze_depreciation.Rmd` is the exception.** CI cannot
  rebuild it (the raw scrape is not in the repository) and says so as a
  warning on every run. To change that note, re-scrape locally, run
  `Rscript build.R depreciation`, and commit `docs/depreciation-by-brand.html`.

Figures rendered in CI use Linux fonts, so charts on the site will not be
pixel-identical to a local render on macOS.

`tools/check-publishable.sh` runs in CI before and after rendering, and should
also run as a local pre-push hook, which stops the push itself rather than only
the deploy:

```bash
printf '#!/bin/sh\nexec tools/check-publishable.sh $(git rev-list HEAD --not --remotes)\n' > .git/hooks/pre-push && chmod +x .git/hooks/pre-push
```

## Data availability

The used-car listings behind the depreciation work — about 9,700 adverts pulled
from bilbasen.dk — are **not** distributed with this repository. Republishing
them would be a substantial re-utilisation of a protected database
(Directive 96/9/EC; in Denmark ophavsretsloven § 71), quite apart from
bilbasen's own terms.

What is published is the derived statistics — depreciation rates, mileage
elasticities, fitted comparator prices — plus two small extracts kept as audit
trails for named case studies, with the columns that point at an individual
advert or locate its seller removed. `depreciation/scrape_bilbasen.py` will
regenerate an equivalent corpus.

**Consequence:** seven of the eight notes knit as shipped;
`depreciation/analyze_depreciation.Rmd` needs the scrape re-run first, and
`build.R` skips it with a message when the file is absent. The committed render
is the record of what the full dataset showed when it was pulled. See
[`NOTICE`](NOTICE) and [`depreciation/README.md`](depreciation/README.md).

## How this was built

Every note here was written in conversation with Claude Code — Opus 5 doing the
modelling, derivation and prose, with direction, domain judgement and the
decision about what counts as a good answer supplied by a human. The interesting
part was not code generation. It was the argument: what the right question is,
which numbers are load-bearing, which are guesses wearing a decimal point, and
where an analysis is quietly rigged by the choice of comparison.

That argument left visible traces, and they are the most useful thing in the
repository. Section 2.4 of the fuel-cost note exists because a first version
confused the spread between petrol stations with the movement of prices over an
eight-year holding period. Those are different quantities by an order of
magnitude — about 0.80 DKK/l against a credible band nearly ten kroner wide —
and treating the small one as the risk understated it badly. The note now says
so in its own text. The battery-warranty note replaced a
million-draw Monte Carlo with a closed-form first-passage result because the
simulation could not resolve gap probabilities near 1e-4. The fuel-cost fleet
refuses to knit if a comparator is not all-wheel drive, because the like-for-like
constraint is easier to state than to keep.

Each note therefore carries its own limits in the open: what is sourced, what is
estimated, what is a placeholder, and which single number would most change the
answer if someone obtained it.

## Licence

Code (`.R`, `.py`) under the [MIT Licence](LICENSE). The notes, their rendered
output and the derived datasets under
[CC BY 4.0](LICENSE-CONTENT). Provenance and limits in [`NOTICE`](NOTICE).

Not affiliated with, endorsed by, or sponsored by Anthropic, bilbasen.dk, or any
vehicle manufacturer or dealer named in the analyses.
