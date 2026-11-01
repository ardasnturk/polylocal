# /// script
# requires-python = ">=3.11"
# ///
"""Combine tools/bench/results/*.json into one Markdown table.

    uv run tools/bench/report.py > tools/bench/RESULTS.md
"""

import json
import statistics
from pathlib import Path

HERE = Path(__file__).resolve().parent


def main() -> None:
    results = [json.loads(p.read_text()) for p in sorted((HERE / "results").glob("*.json"))]
    if not results:
        raise SystemExit("no results yet — run bench.py first")
    pairs = list(results[0]["summary"])

    print("| Model | Şablon | " + " | ".join(f"{p} chrF++" for p in pairs) + " | Ort. chrF++ | TTFT (ms) | tok/s | Bellek |")
    print("|---|---|" + "---:|" * (len(pairs) + 4))
    for r in sorted(results, key=lambda r: -statistics.mean(s["chrf"] for s in r["summary"].values())):
        s = r["summary"]
        mem = f"{r['memory_bytes'] / 1e9:.1f} GB" if r.get("memory_bytes") else "—"
        cells = [f"{s[p]['chrf']:.1f}" if p in s else "—" for p in pairs]
        print(
            f"| {r['label']} | {r['template']} | "
            + " | ".join(cells)
            + f" | **{statistics.mean(x['chrf'] for x in s.values()):.1f}**"
            + f" | {statistics.median(x['ttft_ms'] for x in s.values()):.0f}"
            + f" | {statistics.median(x['tps'] for x in s.values()):.0f}"
            + f" | {mem} |"
        )


if __name__ == "__main__":
    main()
