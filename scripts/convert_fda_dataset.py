"""Convert the FDA Philippines "List of Unregistered Health Products.xlsx"
advisory sheet into a compact JSON asset for the Flutter app.

Output is an array of [name, advisory_number, category, date_posted] tuples
(array-of-arrays, not array-of-objects, to avoid repeating key names 20k+
times). Re-run this whenever the xlsx is updated with new FDA advisories.
"""
import json
import re
from pathlib import Path

import openpyxl

ROOT = Path(__file__).resolve().parent.parent
xlsx_path = ROOT / "List of Unregistered Health Products.xlsx"
out_path = ROOT / "assets" / "data" / "fda_advisories.json"

_ws_re = re.compile(r"\s+")


def clean(value) -> str:
    if value is None:
        return ""
    text = str(value).replace("\xa0", " ")
    return _ws_re.sub(" ", text).strip()


def parse_date(raw: str) -> str:
    # Source dates are dd/mm/yyyy; normalize to yyyy-mm-dd, best-effort.
    m = re.match(r"^(\d{1,2})/(\d{1,2})/(\d{4})$", raw)
    if not m:
        return raw
    day, month, year = m.groups()
    return f"{year}-{month.zfill(2)}-{day.zfill(2)}"


wb = openpyxl.load_workbook(xlsx_path, read_only=True, data_only=True)
ws = wb["Sheet1"]

rows = []
seen = set()
for i, row in enumerate(ws.iter_rows(values_only=True)):
    if i == 0:
        continue  # header
    if not row or len(row) < 5:
        continue
    name = clean(row[2])
    if not name:
        continue
    advisory = clean(row[3])
    category = clean(row[4])
    date = parse_date(clean(row[1]))
    key = (name.upper(), advisory)
    if key in seen:
        continue
    seen.add(key)
    rows.append([name, advisory, category, date])

out_path.parent.mkdir(parents=True, exist_ok=True)
with out_path.open("w", encoding="utf-8") as f:
    json.dump(rows, f, separators=(",", ":"), ensure_ascii=False)

print(f"Wrote {len(rows)} FDA advisory entries to {out_path}")
