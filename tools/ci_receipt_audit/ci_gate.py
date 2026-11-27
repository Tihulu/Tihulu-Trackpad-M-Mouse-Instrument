#!/usr/bin/env python3
"""Offline strict receipt checker. Inputs must be independently collected from trusted GitHub job logs/metadata; this does not authenticate them."""
import argparse
import json
import re
import sys
from collections import Counter

SHA = re.compile(r'[0-9a-f]{40}')
REQUIRED = {
    'core': ('Record and verify checkout provenance', 'Verify'),
    'macos': ('Record and verify checkout provenance', 'Unit tests', 'Isolated native MIDI observer and playback fixtures', 'Build Studio'),
    'android': ('Verify exact checkout', 'Compile library and run local tests'),
    'ios': ('Verify exact checkout', 'Compile isolated iOS sensor library', 'Build unsigned iOS diagnostic companion'),
}

def valid_sha(value):
    return isinstance(value, str) and SHA.fullmatch(value) is not None and value != '0'*40

def positive_int(value):
    return type(value) is int and value > 0

def assess(candidate):
    head, tree, run = candidate['head'], candidate['tree'], candidate['run_id']
    if not valid_sha(head) or not valid_sha(tree) or not positive_int(run):
        raise ValueError('invalid pinned candidate identity')
    jobs = candidate['jobs']
    if not isinstance(jobs, list) or any(not isinstance(j, dict) for j in jobs):
        raise ValueError('jobs must be an array of objects')
    if any(not isinstance(j.get('platform'), str) or j['platform'] not in REQUIRED for j in jobs):
        raise ValueError('unknown or missing platform in normalized product receipts')
    ids = Counter(j.get('job_id') for j in jobs if positive_int(j.get('job_id')))
    result = {}
    for platform, required in REQUIRED.items():
        matches = [j for j in jobs if j.get('platform') == platform]
        if len(matches) != 1:
            result[platform] = 'MISSING' if not matches else 'DUPLICATE'
            continue
        j = matches[0]
        if (type(j.get('run_id')) is not int or j.get('run_id') != run or
            not positive_int(j.get('job_id')) or ids[j['job_id']] != 1):
            result[platform] = 'IDENTITY_MISMATCH'; continue
        if j.get('status') != 'completed':
            result[platform] = 'PENDING'; continue
        conclusion = j.get('conclusion')
        if conclusion != 'success':
            result[platform] = 'SKIPPED' if conclusion == 'skipped' else 'NOT_SUCCESS'; continue
        steps = j.get('steps', [])
        if not isinstance(steps, list) or any(not isinstance(s, dict) for s in steps):
            result[platform] = 'STEP_UNPROVEN'; continue
        if any(len([s for s in steps if s.get('name') == n]) != 1 or
               not any(s.get('name') == n and s.get('conclusion') == 'success' and
                       s.get('status', 'completed') == 'completed' for s in steps)
               for n in required):
            result[platform] = 'STEP_UNPROVEN'; continue
        actual = j.get('checkout_sha')
        actual_tree = j.get('checkout_tree')
        if not valid_sha(actual):
            result[platform] = 'CHECKOUT_UNPROVEN'; continue
        if (actual_tree is None and platform in ('core', 'macos')) or (actual_tree is not None and not valid_sha(actual_tree)):
            result[platform] = 'CHECKOUT_UNPROVEN'; continue
        if actual == head:
            result[platform] = 'EXACT_PASS' if actual_tree in (None, tree) else 'TREE_MISMATCH'
        elif actual_tree == tree:
            result[platform] = 'TREE_ONLY_PASS'
        else:
            result[platform] = 'CHECKOUT_MISMATCH'
    return {'pr': candidate.get('pr'), 'head': head, 'run_id': run,
            'platforms': result, 'exact_count': sum(x == 'EXACT_PASS' for x in result.values()),
            'strict_ci': 'PASS' if all(x == 'EXACT_PASS' for x in result.values()) else 'HOLD',
            'physical_acceptance': 'NOT_ASSESSED', 'quality_acceptance': 'NOT_ASSESSED'}

def strict_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f'duplicate JSON key: {key}')
        result[key] = value
    return result


def reject_constant(value):
    raise ValueError(f'non-finite JSON constant: {value}')


def load_json(path):
    with open(path, encoding='utf-8') as f:
        return json.load(f, object_pairs_hook=strict_object, parse_constant=reject_constant)


def identity(row):
    if not isinstance(row, dict):
        raise ValueError('candidate identity must be an object')
    pr, head, tree, run = (row.get(k) for k in ('pr', 'head', 'tree', 'run_id'))
    if not positive_int(pr) or not valid_sha(head) or not valid_sha(tree) or not positive_int(run):
        raise ValueError('invalid candidate PR/head/tree/run pin')
    return pr, head, tree, run


def identity_map(rows):
    if not isinstance(rows, list) or not rows:
        raise ValueError('nonempty identity array required')
    result, runs = {}, set()
    for row in rows:
        pr, head, tree, run = identity(row)
        if pr in result or run in runs:
            raise ValueError('duplicate candidate PR or run ID')
        result[pr] = (head, tree, run)
        runs.add(run)
    return result


def assess_snapshot(candidates, pins=None):
    actual = identity_map(candidates)
    if pins is not None and actual != identity_map(pins):
        raise ValueError('snapshot candidate set differs from independently supplied pins')
    used = set()
    for c in candidates:
        jobs = c.get('jobs')
        if not isinstance(jobs, list) or any(not isinstance(j, dict) for j in jobs):
            raise ValueError('jobs must be an array of objects')
        current = {j.get('job_id') for j in jobs if positive_int(j.get('job_id'))}
        if current & used:
            raise ValueError('job ID reused across candidates')
        used.update(current)
    results = [assess(c) for c in candidates]
    for r in results:
        r['pin_status'] = 'MATCHED' if pins is not None else 'NOT_PROVIDED'
    return results


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('snapshot', help='JSON array of independently verified receipts')
    p.add_argument('--pins', help='independently supplied expected PR/head/tree/run set')
    args = p.parse_args()
    try:
        candidates = load_json(args.snapshot)
        pins = load_json(args.pins) if args.pins else None
        if args.pins and pins is None:
            raise ValueError('pins cannot be null')
        results = assess_snapshot(candidates, pins)
    except (OSError, ValueError, KeyError, TypeError) as e:
        print(f'Invalid evidence: {e}', file=sys.stderr); return 2
    print(json.dumps(results, indent=2))
    return 0 if all(r['strict_ci'] == 'PASS' for r in results) else 1

if __name__ == '__main__':
    sys.exit(main())
