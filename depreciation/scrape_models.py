#!/usr/bin/env python3
"""Scrape ALL listings for specific car MODELS from bilbasen.dk.

Reuses the WAF-solving loader and the parser from scrape_bilbasen.py, so rows
have the same columns as the brand-level dataset (plus a `query` column marking
which model search each row came from). Written for the Subaru Solterra vs
Toyota bZ4X depreciation comparison.

robots.txt: model pages are path-based (/brugt/bil/<make>/<model>) with page=N
pagination — both allowed. Randomised delays between page loads; low volume.

Output: solterra_bz4x_data.csv  (the Touring filter is applied later,
transparently, in the R analysis).

The written columns are a deliberate subset of the parser's. This file is
committed to a public repository, so the two columns that turn a row into a
pointer at an individual advert (`external_id`, `uri`) and the two that locate
its seller (`zip`, `region`) are dropped on write, along with private-seller
rows. Nothing in the R analysis reads any of them.
"""
import csv
import random
import sys
import time
from pathlib import Path

from playwright.sync_api import sync_playwright

import scrape_bilbasen as sb

MODELS = {
    "subaru-solterra": "https://www.bilbasen.dk/brugt/bil/subaru/solterra",
    "toyota-bz4x":     "https://www.bilbasen.dk/brugt/bil/toyota/bz4x",
}
OUT_PATH = Path(__file__).with_name("solterra_bz4x_data.csv")
FIELDS = [
    "query", "scraped_at", "make", "model", "variant", "kontantpris",
    "reg_month", "reg_year", "mileage_km", "hk", "fueltype", "geartype",
]


def main():
    seen = set()
    with OUT_PATH.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=FIELDS)
        writer.writeheader()
        with sync_playwright() as p:
            browser = p.chromium.launch(headless=True)
            ctx = browser.new_context(
                locale="da-DK",
                user_agent=("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                            "AppleWebKit/537.36 (KHTML, like Gecko) "
                            "Chrome/124.0 Safari/537.36"),
            )
            page = ctx.new_page()
            sb.load_results(page, "https://www.bilbasen.dk/brugt/bil/toyota")  # warm WAF

            grand = 0
            for q, url in MODELS.items():
                print(f"\n=== {q} ===")
                cur, page_no = url, 0
                while cur:
                    page_no += 1
                    listings, hits, nxt = sb.load_results(page, cur)
                    if page_no == 1:
                        print(f"  hits reported: {hits}")
                    new = 0
                    for lst in listings:
                        ext = lst.get("externalId")
                        if ext in seen:
                            continue
                        seen.add(ext)
                        row = {"query": q, **sb.parse_listing(lst, q)}
                        if row.get("seller_type") == "Privat":
                            continue
                        writer.writerow({k: row.get(k) for k in FIELDS})
                        new += 1
                    f.flush()
                    grand += new
                    print(f"  page {page_no}: {len(listings)} listings (+{new} new)")
                    cur = nxt
                    if cur:
                        time.sleep(random.uniform(2.5, 4.5))
            browser.close()
    print(f"\nDONE. {grand} rows -> {OUT_PATH.name}")


if __name__ == "__main__":
    sys.exit(main())
