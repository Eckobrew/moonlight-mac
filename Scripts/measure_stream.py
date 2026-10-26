#!/usr/bin/env python3
"""Measure a running macOS client without sampling its stacks or changing it.

Example: python3 Scripts/measure_stream.py PID --log /tmp/stream.log --seconds 30
CPU percent uses cumulative process CPU time (100% = one logical CPU). Diagnostic
FPS values describe decoded delivery / Metal submission, not physical presentation.
Keep the renderer, host scene, frame rate, resolution, focus and visibility fixed.
Run profilers separately: their overhead makes utilization comparisons unreliable.
"""
import argparse
import json
import re
import statistics
import subprocess
import time
from pathlib import Path


def process_stats(pid):
    result = subprocess.run(
        ['ps', '-p', str(pid), '-o', 'time=,rss='],
        check=True, capture_output=True, text=True,
    ).stdout.split()
    if len(result) != 2:
        raise RuntimeError('Target process exited')
    fields = result[0].split(':')
    cpu_seconds = sum(float(value) * 60 ** power for power, value in enumerate(reversed(fields)))
    return cpu_seconds, int(result[1])


def measure(args):
    log = Path(args.log)
    offset = log.stat().st_size
    cpu_start, rss_start = process_stats(args.pid)
    start = time.monotonic()
    rss = [rss_start]
    while time.monotonic() - start < args.seconds:
        time.sleep(min(1, max(0, args.seconds - (time.monotonic() - start))))
        cpu_end, resident = process_stats(args.pid)
        rss.append(resident)
    elapsed = time.monotonic() - start
    with log.open('rb') as stream:
        stream.seek(offset)
        lines = stream.read().decode('utf-8', errors='replace').splitlines()
    diagnostics = [line for line in lines if '[STREAM-DIAGNOSTICS]' in line]
    result = dict(pid=args.pid, wall_seconds=elapsed, cpu_seconds=cpu_end - cpu_start,
                  cpu_percent=100 * (cpu_end - cpu_start) / elapsed,
                  rss_mib_min=min(rss) / 1024, rss_mib_max=max(rss) / 1024,
                  diagnostics_count=len(diagnostics),
                  all_visible=bool(diagnostics) and all('visible=true' in line for line in diagnostics),
                  all_active=bool(diagnostics) and all('active=true' in line for line in diagnostics))
    for key in ['decodeFPS', 'metalFPS', 'decodeMs', 'rttMs']:
        values = [float(match.group(1)) for line in diagnostics
                  if (match := re.search(r'\b' + key + r'=([\d.]+)', line))]
        if values:
            result[key] = dict(mean=statistics.mean(values), min=min(values), max=max(values))
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('pid', type=int)
    parser.add_argument('--log', required=True)
    parser.add_argument('--seconds', type=float, default=30)
    parser.add_argument('--output')
    args = parser.parse_args()
    if args.pid <= 0 or not 1 <= args.seconds <= 3600:
        parser.error('PID must be positive and duration must be between 1 and 3600 seconds')
    result = json.dumps(measure(args), indent=2)
    if args.output:
        Path(args.output).write_text(result + '\n')
    print(result)
