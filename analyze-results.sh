#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNS_DIR="${SCRIPT_DIR}/runs"

# Collect CSV files to analyze
CSV_FILES=()
MD_FILES=()

if [[ $# -ge 2 ]] && [[ "$1" == "-n" ]]; then
  CSV_FILES=("${RUNS_DIR}/N=${2}_results.csv")
elif [[ $# -eq 0 ]]; then
  for f in "${RUNS_DIR}"/N=*_results.csv; do
    [[ -f "$f" ]] && CSV_FILES+=("$f")
  done
  if [[ ${#CSV_FILES[@]} -eq 0 ]]; then
    echo "No results files found in $RUNS_DIR" >&2
    exit 1
  fi
else
  echo "Usage: $0 [-n N]" >&2
  exit 1
fi

for CSV_FILE in "${CSV_FILES[@]}"; do

if [[ ! -f "$CSV_FILE" ]]; then
  echo "Error: $CSV_FILE not found" >&2
  exit 1
fi

OUT_FILE="${CSV_FILE%.csv}.md"

python3 -c "
import csv, statistics, math, sys
from collections import defaultdict

NAMES = {
    1: 'Baseline', 2: 'Medium files', 3: 'Large files',
    4: '5 files', 5: '10 files', 6: '50 files',
    7: '5 concurrent', 8: '10 concurrent',
    9: 'Fast push (1s)', 10: 'Rapid push (0s)',
    11: 'medium×5', 12: 'medium×10', 13: 'medium×50',
    14: 'large×5', 15: 'large×10', 16: 'large×50',
    17: 'medium×10+1s', 18: 'medium×10+0s',
    19: 'medium×50+1s', 20: 'medium×50+0s',
}

def pct(data, p):
    s = sorted(data)
    k = (len(s) - 1) * p / 100
    f = int(k)
    c = min(f + 1, len(s) - 1)
    return s[f] + (k - f) * (s[c] - s[f])

def welch(a, b):
    na, nb = len(a), len(b)
    if na < 2 or nb < 2: return None, None
    ma, mb = statistics.mean(a), statistics.mean(b)
    va, vb = statistics.variance(a), statistics.variance(b)
    se = (va / na + vb / nb) ** 0.5
    if se == 0: return 0, 1.0
    t = (ma - mb) / se
    p = 2 * (1 - 0.5 * (1 + math.erf(abs(t) / math.sqrt(2))))
    return t, p

def cohens_d(a, b):
    na, nb = len(a), len(b)
    if na < 2 or nb < 2: return None
    va, vb = statistics.variance(a), statistics.variance(b)
    pooled = ((va * (na - 1) + vb * (nb - 1)) / (na + nb - 2)) ** 0.5
    if pooled == 0: return 0
    return (statistics.mean(a) - statistics.mean(b)) / pooled

def fm(v):
    return f'{v:.0f}' if isinstance(v, float) else str(v)

# Load CSV
conds = defaultdict(lambda: {'delays': [], 'timeouts': 0, 'trials': 0})
with open(sys.argv[1]) as f:
    for row in csv.DictReader(f):
        c = int(row['condition'])
        conds[c]['trials'] += 1
        if row['timeout'] == 'true':
            conds[c]['timeouts'] += 1
        d = row['dispatch_delay_ms']
        if d:
            conds[c]['delays'].append(int(d))

all_d = [d for c in conds.values() for d in c['delays']]
total_t = sum(c['trials'] for c in conds.values())
total_to = sum(c['timeouts'] for c in conds.values())
o = []
o.append('# Workflow Dispatch Timing Results')
o.append(f'')

# Key findings (placed first, content inserted after computation)
o.append(f'## Key Findings')
o.append(f'')
findings_idx = len(o)

# Per-condition table
o.append(f'## Per-Condition Summary')
o.append(f'')
o.append(f'| # | Condition | N | Min | Max | Mean | Median | P95 | StdDev | CV% | Outliers |')
o.append(f'|---|-----------|---|-----|-----|------|--------|-----|--------|-----|----------|')

for cn in sorted(conds):
    ds = conds[cn]['delays']
    name = NAMES.get(cn, f'Condition {cn}')
    if not ds:
        o.append(f'| {cn} | {name} | 0 | — | — | — | — | — | — | — | — |')
        continue
    n = len(ds)
    mn, mx = min(ds), max(ds)
    mean = statistics.mean(ds)
    med = statistics.median(ds)
    p95 = pct(ds, 95)
    sd = statistics.stdev(ds) if n > 1 else 0
    cv = (sd / mean * 100) if mean > 0 else 0
    out = len([d for d in ds if sd > 0 and abs(d - mean) > 3 * sd])
    o.append(f'| {cn} | {name} | {n} | {fm(mn)} | {fm(mx)} | {fm(mean)} | '
             f'{fm(med)} | {fm(p95)} | {fm(sd)} | {cv:.1f} | {out} |')

o.append(f'')

# Comparison vs baseline
bl = conds.get(1)
if bl and len(bl['delays']) >= 2:
    o.append(f'## Comparison vs Baseline')
    o.append(f'')
    o.append(f'| # | Condition | Mean Δ | Cohen\\'s d | t-stat | p-value | Significant? |')
    o.append(f'|---|-----------|--------|-----------|--------|---------|--------------|')
    bl_d = bl['delays']
    bl_m = statistics.mean(bl_d)
    for cn in sorted(conds):
        if cn == 1: continue
        ds = conds[cn]['delays']
        name = NAMES.get(cn, f'Condition {cn}')
        if len(ds) < 2:
            o.append(f'| {cn} | {name} | — | — | — | — | — |')
            continue
        delta = statistics.mean(ds) - bl_m
        d = cohens_d(ds, bl_d)
        t, p = welch(ds, bl_d)
        sig = 'No'
        if p is not None and p < 0.05: sig = 'Yes'
        if p is not None and p < 0.01: sig = 'Yes**'
        ds_str = f'{d:.2f}' if d is not None else '—'
        ts_str = f'{t:.2f}' if t is not None else '—'
        ps_str = f'{p:.4f}' if p is not None else '—'
        o.append(f'| {cn} | {name} | {fm(delta)}ms | '
                 f'{ds_str} | {ts_str} | {ps_str} | {sig} |')
    o.append(f'')

# Insert key findings at the reserved position
findings = []
if all_d:
    findings.append(f'1. **Dispatch delay is consistently low.** '
             f'Overall mean is {fm(statistics.mean(all_d))}ms '
             f'with a range of [{min(all_d)}ms, {max(all_d)}ms].')
if bl and len(bl['delays']) >= 2:
    sig_c = []
    for cn in sorted(conds):
        if cn == 1: continue
        ds = conds[cn]['delays']
        if len(ds) < 2: continue
        _, p = welch(ds, bl['delays'])
        if p is not None and p < 0.05:
            sig_c.append(NAMES.get(cn, f'Cond {cn}'))
    if sig_c:
        findings.append(f'2. **Statistically significant differences** '
                 f'found in: {\", \".join(sig_c)}.')
    else:
        findings.append(f'2. **No statistically significant differences** '
                 f'found between any condition and baseline (p > 0.05).')
if total_to > 0:
    findings.append(f'3. **Timeouts:** {total_to}/{total_t} trials timed out.')
else:
    findings.append(f'3. **No timeouts** across all trials.')
findings.append(f'')
for i, line in enumerate(findings):
    o.insert(findings_idx + i, line)

# Summary (placed at end)
o.append(f'## Summary')
o.append(f'')
o.append(f'- **Conditions:** {len(conds)}')
o.append(f'- **Total trials:** {total_t}')
o.append(f'- **Timeouts:** {total_to}')
if all_d:
    o.append(f'- **Overall dispatch delay:** '
             f'mean={fm(statistics.mean(all_d))}ms, '
             f'median={fm(statistics.median(all_d))}ms, '
             f'range=[{min(all_d)}ms, {max(all_d)}ms]')
o.append(f'')

print('\n'.join(o))
" "$CSV_FILE" > "$OUT_FILE"

echo "Report written to $OUT_FILE"
MD_FILES+=("$OUT_FILE")

done

# Format all generated files with prettier
if command -v npx &>/dev/null; then
  npx --yes prettier --write "${MD_FILES[@]}" 2>/dev/null
fi
