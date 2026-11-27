"""Regression tests for the strict snapshot boundary; no network."""
import unittest
import tempfile
from pathlib import Path
from copy import deepcopy
from test_ci_gate import fixture, HEAD, TREE, OTHER
import ci_gate


def candidate(pr=1, run=1):
    f=fixture(); f.update(pr=pr,run_id=run)
    for j in f['jobs']:
        j['run_id']=run; j['job_id'] += (run-1)*10
    return f


def pins(*candidates):
    return [{k:c[k] for k in ('pr','head','tree','run_id')} for c in candidates]


class SnapshotTests(unittest.TestCase):
    def test_tree_required_for_core_and_macos(self):
        for i in (0,1):
            f=candidate(); f['jobs'][i].pop('checkout_tree')
            self.assertEqual(ci_gate.assess(f)['strict_ci'],'HOLD')
    def test_unknown_job_is_rejected(self):
        f=candidate(); f['jobs'].append({'platform':'unknown','job_id':99,'run_id':1})
        with self.assertRaises(ValueError): ci_gate.assess(f)
    def test_zero_hash_is_invalid(self):
        f=candidate(); f['head']='0'*40
        with self.assertRaises(ValueError): ci_gate.assess(f)
    def test_cross_candidate_identity_reuse(self):
        a,b=candidate(1,1),candidate(2,2)
        for key in ('pr','run_id','job_id'):
            with self.subTest(key=key):
                c=deepcopy(b)
                if key=='job_id': c['jobs'][0]['job_id']=a['jobs'][0]['job_id']
                else: c[key]=a[key]
                with self.assertRaises(ValueError): ci_gate.assess_snapshot([a,c])
    def test_pinned_snapshot(self):
        a,b=candidate(1,1),candidate(2,2)
        result=ci_gate.assess_snapshot([b,a],pins(a,b))
        self.assertEqual(len(result),2)
        self.assertTrue(all(r['strict_ci']=='PASS' for r in result))
        self.assertTrue(all(r['pin_status']=='MATCHED' for r in result))
    def test_pin_missing_extra_or_stale(self):
        a,b=candidate(1,1),candidate(2,2)
        for rows,expected in (([a],pins(a,b)),([a,b],pins(a)),([a],[dict(pins(a)[0],head=OTHER)]),([a],[dict(pins(a)[0],tree=OTHER)]),([a],[dict(pins(a)[0],run_id=2)])):
            with self.subTest(rows=len(rows),expected=expected):
                with self.assertRaises(ValueError): ci_gate.assess_snapshot(rows,expected)
    def test_invalid_shape_or_pr(self):
        for rows in ([],{},[None],[dict(candidate(),pr=True)],[dict(candidate(),pr=0)]):
            with self.assertRaises(ValueError): ci_gate.assess_snapshot(rows)
    def test_duplicate_json_key_and_nonfinite(self):
        for raw in ('{"head":"bad","head":"good"}','{"nested":{"id":1,"id":2}}','[NaN]','[Infinity]','[-Infinity]'):
            with tempfile.TemporaryDirectory() as d:
                p=Path(d)/'input.json'; p.write_text(raw)
                with self.assertRaises(ValueError): ci_gate.load_json(p)
    def test_duplicate_pin(self):
        a=candidate(); p=pins(a)
        with self.assertRaises(ValueError): ci_gate.assess_snapshot([a],p+p)
    def test_invalid_pin_shape(self):
        a=candidate()
        for p in ({},[],[None],[dict(pins(a)[0],pr=True)],[dict(pins(a)[0],run_id=True)]):
            with self.assertRaises(ValueError): ci_gate.assess_snapshot([a],p)
    def test_optional_pins_not_claimed(self):
        self.assertEqual(ci_gate.assess_snapshot([candidate()])[0]['pin_status'],'NOT_PROVIDED')
    def test_completed_step_cannot_be_pending(self):
        f=candidate(); f['jobs'][0]['steps'][0]['status']='in_progress'
        self.assertEqual(ci_gate.assess(f)['platforms']['core'],'STEP_UNPROVEN')

if __name__=='__main__': unittest.main()
