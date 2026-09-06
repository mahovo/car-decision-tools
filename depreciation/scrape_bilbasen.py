#!/usr/bin/env python3
"""
Scrape used-car listings from bilbasen.dk for personal depreciation analysis.

Approach
--------
bilbasen.dk sits behind AWS WAF's JavaScript challenge, so plain HTTP clients
(requests / rvest) only ever receive an empty HTTP 202. We therefore drive a
real Chromium via Playwright, which executes the challenge JS and obtains the
`aws-waf-token` cookie automatically. One solve per browser session; the cookie
then carries across all subsequent page loads in the same context.

Data is read from the page's embedded Next.js blob (`#__NEXT_DATA__`), giving
clean structured fields instead of brittle HTML scraping.

Robots / politeness
-------------------
robots.txt disallows `*?*` (any query string) but explicitly allows `*page=*`.
We only ever request:
  * the path-based brand page  /brugt/bil/<slug>            (no query string)
  * the site's own pagination links containing  page=N      (allowed)
Requests are rate-limited with randomised delays. This is a low-volume pull for
personal use.

Output
------
Appends rows to bilbasen_data.csv (one row per listing). Re-running resumes /
adds; duplicates (same listing id) within a run are skipped.
"""

import csv
import json
import random
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from playwright.sync_api import sync_playwright

# ---------------------------------------------------------------- config -----
BRANDS = [
    # user-requested 14
    "subaru", "skoda", "kia", "hyundai", "mazda", "suzuki", "honda",
    # Citroën's landing slug keeps the diacritic, URL-encoded (ë -> %C3%AB);
    # plain "citroen"/"citro" are NOT recognised and return the unfiltered set.
    "toyota", "fiat", "renault", "peugeot", "vw", "tesla", "citro%C3%ABn",
    # 6 added to reach 20 (high-volume in DK)
    "ford", "volvo", "bmw", "mercedes", "opel", "nissan",
    # 5 added in a later pass (slugs verified to return the correct make)
    "mini", "audi", "seat", "dacia", "mitsubishi",
]

# Env overrides (handy for testing): BILBASEN_BRANDS=vw,kia  BILBASEN_MAXPAGES=2
import os
if os.environ.get("BILBASEN_BRANDS"):
    BRANDS = [b.strip() for b in os.environ["BILBASEN_BRANDS"].split(",") if b.strip()]

MAX_PAGES_PER_BRAND = int(os.environ.get("BILBASEN_MAXPAGES", "10"))  # 30/page
MIN_DELAY, MAX_DELAY = 3.0, 6.0   # seconds between page loads (jittered)
HEADLESS = True
OUT_PATH = Path(__file__).with_name("bilbasen_data.csv")
BASE = "https://www.bilbasen.dk/brugt/bil/"

FIELDS = [
    "scraped_at", "brand_slug", "external_id", "make", "model", "variant",
    "kontantpris", "price_type", "sale_type", "seller_type",
    "reg_month", "reg_year", "mileage_km", "hk", "fueltype", "geartype",
    "zip", "region", "nypris", "uri",
]

# ----------------------------------------------------------- parse helpers ---
_INT_RE = re.compile(r"\d[\d.]*")


def _int_from(text):
    """'99.000 km' / '408 hk' -> 99000 / 408 (Danish thousand separator '.')."""
    if not text:
        return None
    m = _INT_RE.search(text)
    if not m:
        return None
    try:
        return int(m.group(0).replace(".", ""))
    except ValueError:
        return None


def _reg_month_year(props):
    """firstregistrationdate '7/2022' -> (7, 2022); also handles bare '2022'."""
    node = (props or {}).get("firstregistrationdate") or {}
    txt = node.get("displayTextShort") or node.get("displayTextLong") or ""
    m = re.search(r"(\d{1,2})\s*/\s*(\d{4})", txt)
    if m:
        return int(m.group(1)), int(m.group(2))
    m = re.search(r"(\d{4})", txt)
    if m:
        return None, int(m.group(1))
    return None, None


_NYPRIS_RE = re.compile(
    r"nypris[^0-9]{0,12}?(\d{1,3}(?:\.\d{3})+|\d{4,7})", re.IGNORECASE
)


def _nypris_from(description):
    """Opportunistically pull 'Nypris: 532.832,00 Kr.' from free-text body."""
    if not description:
        return None
    m = _NYPRIS_RE.search(description)
    if not m:
        return None
    val = int(m.group(1).replace(".", ""))
    # sanity: a plausible new-car price in DKK
    return val if 30_000 <= val <= 5_000_000 else None


def _prop_short(props, key):
    node = (props or {}).get(key) or {}
    return node.get("displayTextShort") or node.get("displayTextLong")


def parse_listing(lst, brand_slug):
    price = lst.get("price") or {}
    props = lst.get("properties") or {}
    loc = lst.get("location") or {}
    reg_m, reg_y = _reg_month_year(props)
    return {
        "scraped_at": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        "brand_slug": brand_slug,
        "external_id": lst.get("externalId"),
        "make": lst.get("make"),
        "model": lst.get("model"),
        "variant": lst.get("variant"),
        "kontantpris": price.get("price"),
        "price_type": price.get("priceType"),
        "sale_type": lst.get("saleType"),
        "seller_type": lst.get("sellerType"),
        "reg_month": reg_m,
        "reg_year": reg_y,
        "mileage_km": _int_from(_prop_short(props, "mileage")),
        "hk": _int_from(_prop_short(props, "hk")),
        "fueltype": _prop_short(props, "fueltype"),
        "geartype": _prop_short(props, "geartype"),
        "zip": loc.get("zipCode"),
        "region": loc.get("region"),
        "nypris": _nypris_from(lst.get("description")),
        "uri": lst.get("uri"),
    }


# ----------------------------------------------------- page-level fetching ---
def get_next_data(page):
    """Return parsed __NEXT_DATA__ JSON, or None if not present yet."""
    txt = page.evaluate(
        "() => { const e = document.getElementById('__NEXT_DATA__');"
        " return e ? e.textContent : null; }"
    )
    if not txt:
        return None
    try:
        return json.loads(txt)
    except json.JSONDecodeError:
        return None


def find_listings_block(data):
    """Locate the search-results query inside dehydratedState.

    Returns (listings:list, total_hits:int|None, next_link:str|None).
    """
    try:
        queries = data["props"]["pageProps"]["dehydratedState"]["queries"]
    except (KeyError, TypeError):
        return [], None, None
    for q in queries:
        d = (((q or {}).get("state") or {}).get("data")) or {}
        if isinstance(d, dict) and isinstance(d.get("listings"), list):
            nxt = ((d.get("pagination") or {}).get("next") or {}).get("link")
            return d["listings"], d.get("hits"), nxt
    return [], None, None


def load_results(page, url, tries=4):
    """Navigate to url and wait until __NEXT_DATA__ with listings is present.

    Handles the WAF challenge: if the first response is the challenge (no
    __NEXT_DATA__), wait and reload.
    """
    for attempt in range(1, tries + 1):
        try:
            page.goto(url, wait_until="domcontentloaded", timeout=60000)
        except Exception as e:
            print(f"    goto error ({attempt}/{tries}): {e}")
            page.wait_for_timeout(3000)
            continue
        # let the WAF challenge resolve / data hydrate
        try:
            page.wait_for_selector("#__NEXT_DATA__", timeout=20000)
        except Exception:
            pass
        page.wait_for_timeout(1500)
        data = get_next_data(page)
        if data is not None:
            listings, hits, nxt = find_listings_block(data)
            if listings or hits == 0:
                return listings, hits, nxt
        print(f"    no data yet ({attempt}/{tries}) — waiting & retrying")
        page.wait_for_timeout(4000 * attempt)
    return [], None, None


# ----------------------------------------------------------------- driver ----
def main():
    seen = set()
    existing = OUT_PATH.exists()
    f = OUT_PATH.open("a", newline="", encoding="utf-8")
    writer = csv.DictWriter(f, fieldnames=FIELDS)
    if not existing:
        writer.writeheader()

    grand_total = 0
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=HEADLESS)
        ctx = browser.new_context(
            locale="da-DK",
            user_agent=(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"
            ),
            viewport={"width": 1366, "height": 900},
        )
        page = ctx.new_page()

        for slug in BRANDS:
            url = f"{BASE}{slug}"
            brand_rows = 0
            print(f"\n=== {slug} ===")
            for page_no in range(1, MAX_PAGES_PER_BRAND + 1):
                listings, hits, nxt = load_results(page, url)
                if page_no == 1:
                    if not listings:
                        print(f"  !! no listings (bad slug or blocked?) hits={hits}")
                        break
                    print(f"  total hits reported: {hits}")
                new = 0
                for lst in listings:
                    ext = lst.get("externalId")
                    if ext in seen:
                        continue
                    seen.add(ext)
                    writer.writerow(parse_listing(lst, slug))
                    new += 1
                f.flush()
                brand_rows += new
                print(f"  page {page_no}: {len(listings)} listings (+{new} new)")
                if not nxt:
                    print("  no further pages")
                    break
                url = nxt
                if page_no < MAX_PAGES_PER_BRAND:
                    time.sleep(random.uniform(MIN_DELAY, MAX_DELAY))
            grand_total += brand_rows
            print(f"  -> {brand_rows} rows for {slug}")
            time.sleep(random.uniform(MIN_DELAY, MAX_DELAY))

        browser.close()
    f.close()
    print(f"\nDONE. {grand_total} new rows written to {OUT_PATH.name}")


if __name__ == "__main__":
    sys.exit(main())
