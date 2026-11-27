#!/usr/bin/env python3
"""Offline evidence layer. Does not authenticate GitHub, logs, or attempt history."""
import argparse
import hashlib
import json
import re
import sys
from datetime import datetime
from ci_gate import assess_snapshot, load_json, positive_int, REQUIRED, valid_sha

PREFIX = re.compile(r'(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z) (.*)')
CMD = re.compile(r'\[command\]/(?:usr/bin|opt/homebrew/bin)/git log -1 --format=%H')
EXPECTED = re.compile(r'  EXPECTED_SHA: ([0-9a-f]{40})')
VERIFIED = re.compile(r'Verified checkout: ([0-9a-f]{40}); tree: ([0-9a-f]{40})')


def parse_excerpt(lines, platform):
    """Precisely the selected 3/4 checkout lines, not an arbitrary full log parser."""
    core = platform in ('core', 'macos')
    if platform not in REQUIRED or not isinstance(lines, list) or len(lines) != (4 if core else 3):
        raise ValueError('unexpected excerpt shape')
    messages, timestamps = [], []
    for line in lines:
        match = PREFIX.fullmatch(line) if isinstance(line, str) else None
        if not match:
            raise ValueError('invalid timestamped excerpt line')
        stamp, msg = match.groups()
        # datetime validates calendar fields; preserve seventh decimal for order.
        datetime.fromisoformat(stamp[:-2] + '+00:00')
        timestamps.append(stamp)
        messages.append(msg)
    if timestamps != sorted(set(timestamps)):
        raise ValueError('non-increasing log timestamps')
    expected = EXPECTED.fullmatch(messages[2])
    actual = messages[1]
    if not CMD.fullmatch(messages[0]) or not valid_sha(actual) or not expected or expected[1] != actual:
        raise ValueError('checkout and expected SHA mismatch')
    tree = None
    if core:
        verified = VERIFIED.fullmatch(messages[3])
        if not verified or verified[1] != actual or not valid_sha(verified[2]):
            raise ValueError('unproven checkout tree')
        tree = verified[2]
    return actual, tree


def digest(lines):
    return hashlib.sha256(('\n'.join(lines)+'\n').encode('utf-8')).hexdigest()


def index_unique(rows, field):
    if not isinstance(rows, list):
        raise ValueError('array required')
    result = {}
    for row in rows:
        if not isinstance(row, dict) or not positive_int(row.get(field)) or row[field] in result:
            raise ValueError(f'invalid or duplicate {field}')
        result[row[field]] = row
    return result


def optional_attempt(value):
    if value is not None and not positive_int(value):
        raise ValueError('invalid run attempt')
    return value


def review(snapshot, pins, runs, receipts):
    if pins is None:
        raise ValueError('independent candidate pins required')
    normalized = assess_snapshot(snapshot, pins)
    run_map, excerpt_map = index_unique(runs, 'run_id'), index_unique(receipts, 'job_id')
    if set(run_map) != {c['run_id'] for c in snapshot}:
        raise ValueError('run metadata set mismatch')
    all_jobs = {j['job_id'] for c in snapshot for j in c['jobs'] if positive_int(j.get('job_id'))}
    if set(excerpt_map) - all_jobs:
        raise ValueError('unexpected excerpt job')
    # Identical selected log bytes cannot stand in for multiple job receipts.
    excerpt_digests = [r.get('sha256') for r in receipts if isinstance(r.get('sha256'), str)]
    if len(set(excerpt_digests)) != len(excerpt_digests):
        raise ValueError('excerpt checksum reused across jobs')
    for candidate, row in zip(snapshot, normalized):
        run = run_map[candidate['run_id']]
        if run.get('workflow') != 'TIHULU Trackpad Instrument CI' or run.get('head') != candidate['head']:
            raise ValueError('workflow or head binding mismatch')
        attempt = optional_attempt(run.get('run_attempt'))
        checks, attempts = {}, {}
        for platform, state in row['platforms'].items():
            matches = [j for j in candidate['jobs'] if j['platform'] == platform]
            if state not in ('EXACT_PASS','TREE_ONLY_PASS'):
                checks[platform] = state
                attempts[platform] = 'NOT_APPLICABLE'
                continue
            job = matches[0]
            receipt = excerpt_map.get(job['job_id'])
            checks[platform] = 'EXCERPT_MISSING'
            attempts[platform] = 'UNKNOWN'
            if not receipt:
                continue
            if not positive_int(receipt.get('run_id')) or receipt['run_id'] != candidate['run_id'] or receipt.get('platform') != platform:
                checks[platform] = 'RECEIPT_IDENTITY_MISMATCH'; continue
            # A success without an explicit completed status is insufficient here.
            if any(not any(s.get('name') == name and s.get('status') == 'completed' and s.get('conclusion') == 'success'
                           for s in job['steps']) for name in REQUIRED[platform]):
                checks[platform] = 'STEP_STATUS_UNPROVEN'; continue
            try:
                actual, tree = parse_excerpt(receipt.get('lines'), platform)
                if digest(receipt['lines']) != receipt.get('sha256'):
                    raise ValueError('excerpt checksum mismatch')
                if actual != job.get('checkout_sha') or (tree is not None and tree != job.get('checkout_tree')):
                    raise ValueError('normalized checkout mismatch')
                r_attempt = optional_attempt(receipt.get('run_attempt'))
            except (ValueError, TypeError):
                checks[platform] = 'EXCERPT_INVALID'; continue
            # A mobile SHA-only excerpt cannot independently prove a different
            # commit has the candidate's tree. Do not upgrade normalized claims.
            if state == 'TREE_ONLY_PASS' and tree is None:
                checks[platform] = 'TREE_UNPROVEN'; continue
            checks[platform] = state
            try:
                job_attempt = optional_attempt(job.get('run_attempt'))
            except ValueError:
                attempts[platform] = 'INVALID'; continue
            known = {a for a in (attempt, job_attempt, r_attempt) if a is not None}
            if len(known) > 1:
                attempts[platform] = 'MISMATCH'
            elif all(a is not None for a in (attempt, job_attempt, r_attempt)):
                attempts[platform] = 'MATCHED'
        run_ok = run.get('status') == 'completed' and run.get('conclusion') == 'success'
        row.update(log_checks=checks, attempt_checks=attempts,
                   log_exact_count=sum(v=='EXACT_PASS' for v in checks.values()),
                   run_summary='PASS' if run_ok else 'HOLD',
                   receipt_gate='PASS' if run_ok and all(v=='EXACT_PASS' for v in checks.values()) and all(v=='MATCHED' for v in attempts.values()) else 'HOLD',
                   evidence_authentication='NOT_PERFORMED')
    return normalized


def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ('snapshot','pins','runs','receipts'):
        p.add_argument(name)
    a=p.parse_args()
    try:
        result=review(*(load_json(getattr(a,k)) for k in ('snapshot','pins','runs','receipts')))
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f'Invalid evidence: {exc}',file=sys.stderr); return 2
    print(json.dumps(result,indent=2))
    return 0 if all(r['receipt_gate']=='PASS' for r in result) else 1

if __name__=='__main__':
    sys.exit(main())
