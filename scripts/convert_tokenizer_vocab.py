"""Extract the WordPiece vocab from tokenizer.json into a compact JSON asset
the Flutter app can load directly (word -> id map), so Dart doesn't need to
parse the full HuggingFace tokenizer.json format.

Re-run this if tokenizer.json is ever replaced/retrained.
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
tokenizer_path = ROOT / "tokenizer.json"
out_path = ROOT / "assets" / "tokenizer" / "vocab.json"

with tokenizer_path.open(encoding="utf-8") as f:
    data = json.load(f)

vocab = data["model"]["vocab"]
assert data["model"]["type"] == "WordPiece"

out_path.parent.mkdir(parents=True, exist_ok=True)
with out_path.open("w", encoding="utf-8") as f:
    json.dump(vocab, f, separators=(",", ":"))

print(f"Wrote {len(vocab)} vocab entries to {out_path}")
