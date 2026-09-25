#!/usr/bin/env python3
"""Run a command N times and print median wall time and peak RSS.

Usage: measure.py [-n N] command [args...]

Peak RSS comes from `getrusage(RUSAGE_CHILDREN)` in this fresh process, so it
reflects only this command's child (run one measurement per process).
"""
import resource
import statistics
import subprocess
import sys
import time

n = 7
args = sys.argv[1:]
if args and args[0] == "-n":
    n = int(args[1])
    args = args[2:]
if not args:
    print("usage: measure.py [-n N] command [args...]", file=sys.stderr)
    sys.exit(2)

times = []
for _ in range(n):
    t0 = time.perf_counter()
    proc = subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    t1 = time.perf_counter()
    if proc.returncode != 0:
        print(f"FAIL(exit {proc.returncode})")
        sys.exit(1)
    times.append((t1 - t0) * 1000.0)

rss_mb = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss / 1024.0
print(f"{statistics.median(times):8.1f} ms  rss={rss_mb:6.1f} MB")
