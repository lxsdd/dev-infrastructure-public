"""Synthetic-only public infrastructure contract smoke."""
import json
from pathlib import Path

def main():
    root = Path(__file__).resolve().parent
    fixture = json.loads((root / "synthetic_catalog.json").read_text(encoding="utf-8"))
    assert fixture["synthetic"] is True
    assert fixture["schema_version"] == 1
    assert len(fixture["tracks"]) == 3
    ids = [x["id"] for x in fixture["tracks"]]
    assert len(ids) == len(set(ids))
    assert all(x["title"].startswith("Synthetic ") for x in fixture["tracks"])
    assert all(not any(k in x for k in ("real_path", "token", "secret", "database_path")) for x in fixture["tracks"])
    print("PASS: synthetic fixture contract")

if __name__ == "__main__":
    main()
