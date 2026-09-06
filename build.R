# ---------------------------------------------------------------------------
# build.R — render every note into docs/, which is what GitHub Pages serves.
#
# Each .Rmd resolves its data paths relative to its own directory, so each is
# rendered in place and the output is written straight into docs/ under the
# name the site links to. Run from the repository root:
#
#   Rscript build.R            # everything
#   Rscript build.R fuel-cost  # only notes whose path matches "fuel-cost"
#
# NOTE: depreciation/analyze_depreciation.Rmd reads the raw bilbasen scrape,
# which is not distributed with this repository (see NOTICE). It is skipped
# unless that file is present; the committed docs/depreciation-by-brand.html is
# the record of what it produced.
# ---------------------------------------------------------------------------

NOTES <- list(
  c("battery-warranty/warranty-analysis.Rmd",      "warranty-analysis.html"),
  c("fuel-cost/fuel-cost-per-km.Rmd",              "fuel-cost-per-km.html"),
  c("depreciation/analyze_depreciation.Rmd",       "depreciation-by-brand.html"),
  c("leasing_vs_kontant.Rmd",                      "leasing-vs-kontant.html"),
  c("drivetrain-lateral-capacity.Rmd",             "drivetrain-lateral-capacity.html"),
  c("store_biler.Rmd",                             "pointmodel-store-biler.html"),
  c("smaa_biler.Rmd",                              "pointmodel-smaa-biler.html"),
  c("smaa_elbiler.Rmd",                            "pointmodel-smaa-elbiler.html")
)

REQUIRES_SCRAPE <- "depreciation/analyze_depreciation.Rmd"
SCRAPE <- "depreciation/bilbasen_data.csv"

filter <- commandArgs(trailingOnly = TRUE)
docs <- normalizePath("docs", mustWork = TRUE)

for (note in NOTES) {
  src <- note[1]
  out <- note[2]
  if (length(filter) && !any(vapply(filter, grepl, logical(1), x = src, fixed = TRUE))) next
  if (src == REQUIRES_SCRAPE && !file.exists(SCRAPE)) {
    message("SKIP  ", src, " — needs ", SCRAPE, " (see NOTICE)")
    next
  }
  message("BUILD ", src, " -> docs/", out)
  rmarkdown::render(src, output_file = out, output_dir = docs, quiet = TRUE)
}

message("\nDone. Open docs/index.html.")
