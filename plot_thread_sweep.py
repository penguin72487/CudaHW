#!/usr/bin/env python3
import argparse
import csv
from pathlib import Path

import matplotlib.pyplot as plt


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Plot thread sweep timing chart from CSV.")
    parser.add_argument("--input", required=True, help="Input CSV path (threads,ssd_ms,pcc_ms)")
    parser.add_argument("--output", required=True, help="Output image path, e.g. thread_sweep.png")
    parser.add_argument("--title", default="Thread Count vs Runtime", help="Chart title")
    return parser.parse_args()


def load_csv(path: Path):
    threads = []
    ssd = []
    pcc = []

    with path.open("r", newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        required = {"threads", "ssd_ms", "pcc_ms"}
        if not required.issubset(set(reader.fieldnames or [])):
            raise ValueError("CSV headers must include: threads, ssd_ms, pcc_ms")

        for row in reader:
            threads.append(int(row["threads"]))
            ssd.append(float(row["ssd_ms"]))
            pcc.append(float(row["pcc_ms"]))

    if not threads:
        raise ValueError("CSV is empty")

    return threads, ssd, pcc


def main() -> None:
    args = parse_args()
    in_path = Path(args.input)
    out_path = Path(args.output)

    threads, ssd, pcc = load_csv(in_path)

    plt.figure(figsize=(9, 5.5))
    plt.plot(threads, ssd, marker="o", linewidth=2, label="SSD")
    plt.plot(threads, pcc, marker="s", linewidth=2, label="PCC")
    plt.xticks(threads)
    plt.xlabel("Thread Count")
    plt.ylabel("Runtime (ms)")
    plt.title(args.title)
    plt.grid(True, linestyle="--", alpha=0.35)
    plt.legend()
    plt.tight_layout()

    out_path.parent.mkdir(parents=True, exist_ok=True)
    plt.savefig(out_path, dpi=150)
    print(f"Saved chart to: {out_path}")


if __name__ == "__main__":
    main()
