#!/usr/bin/env python3
"""Compare two Boxer verification summary files without third-party modules."""
import argparse
import csv
import json
import os
import statistics


def load(path):
    with open(path, encoding="utf-8") as stream:
        return json.load(stream)


def rows(summary):
    path = summary.get("csv")
    if not path or not os.path.exists(path):
        return []
    with open(path, newline="", encoding="utf-8") as stream:
        return list(csv.DictReader(stream))


def average_after_warmup(summary, column):
    values = [float(row[column]) for row in rows(summary)[5:] if row.get(column)]
    return statistics.fmean(values) if values else 0.0


def duration(summary, metric, field):
    return float(summary.get("durations_us", {}).get(metric, {}).get(field, 0))


def counter(summary, name):
    return float(summary.get("counters", {}).get(name, 0))


def show_line(name, a, b):
    print(f"{name:<38} {a:>12.2f} {b:>12.2f} {b-a:>12.2f}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("baseline")
    parser.add_argument("post_fix")
    parser.add_argument("--test", default="A", choices=["A", "B", "C", "D", "E", "F"])
    args = parser.parse_args()
    a = load(args.baseline)
    b = load(args.post_fix)
    print(f"Run A: {args.baseline} {a.get('timestamp', 'unknown')} {a.get('staging_commit', 'unknown')}")
    print(f"Run B: {args.post_fix} {b.get('timestamp', 'unknown')} {b.get('staging_commit', 'unknown')}")
    print()
    print(f"{'METRIC':<38} {'A':>12} {'B':>12} {'DELTA':>12} VERDICT")
    print("-" * 92)
    finish_a = average_after_warmup(a, "finish_frame_count")
    finish_b = average_after_warmup(b, "finish_frame_count")
    halc_a = average_after_warmup(a, "halc_message_count")
    halc_b = average_after_warmup(b, "halc_message_count")
    metrics = [
        ("finish_frame_count (total)", counter(a, "finish_frame_count"), counter(b, "finish_frame_count")),
        ("finish_frame_count (per sec avg)", finish_a, finish_b),
        ("finish_frame_us_p99", duration(a, "finish_frame", "p99"), duration(b, "finish_frame", "p99")),
        ("finish_frame_us_max", duration(a, "finish_frame", "max"), duration(b, "finish_frame", "max")),
        ("halc_message_count (per sec avg)", halc_a, halc_b),
        ("texture_creation_count", counter(a, "texture_creation_count"), counter(b, "texture_creation_count")),
        ("slot_presenting_count (final)", a.get("slot_occupancy_final", {}).get("presenting", 0), b.get("slot_occupancy_final", {}).get("presenting", 0)),
        ("next_drawable_us_p99", duration(a, "next_drawable", "p99"), duration(b, "next_drawable", "p99")),
    ]
    for name, value_a, value_b in metrics:
        show_line(name, value_a, value_b)

    p99_a = duration(a, "finish_frame", "p99")
    p99_b = duration(b, "finish_frame", "p99")
    max_a = duration(a, "finish_frame", "max")
    max_b = duration(b, "finish_frame", "max")
    finish_ok = finish_a > 0 and abs(finish_b - finish_a) / finish_a <= 0.05
    halc_ok = abs(halc_b - halc_a) <= 1.0
    p99_ok = p99_a == 0 or p99_b <= 2 * p99_a
    max_ok = max_a == 0 or max_b <= 2 * max_a
    slots_a = a.get("slot_occupancy_final", {}).get("presenting", 0)
    slots_b = b.get("slot_occupancy_final", {}).get("presenting", 0)
    slots_ok = slots_a == 0 and slots_b == 0
    print()
    print("Test A criteria (A=visible, B=occluded; first five CSV seconds excluded):")
    print(f"finish_frame_count delta: {finish_b-finish_a:.2f} frames/s")
    print(f"finish_frame_us_p99 delta: {p99_b-p99_a:.2f} us")
    print(f"halc_message_count delta: {halc_b-halc_a:.2f} messages/s")
    print(f"slot_presenting_count final delta: {slots_b-slots_a}")
    if args.test == "A":
        passed = finish_ok and halc_ok and p99_ok and max_ok and slots_ok
        print(f"PASS/FAIL: Test A: {'PASS' if passed else 'FAIL'}")
        print("PASS requires ±5% finish rate, ≤1 HALC message/s delta, ≤2× finish p99/max, and zero final presenting slots.")
    else:
        print(f"PASS/FAIL: Test {args.test}: operator judgment required")
        print("The comparison tool reports the metric deltas; apply the test-specific procedure criterion.")


if __name__ == "__main__":
    main()
