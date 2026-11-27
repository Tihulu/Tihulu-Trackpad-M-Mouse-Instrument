import unittest
from copy import deepcopy
from itertools import product
from ci_gate import assess, REQUIRED

HEAD, TREE, OTHER = 'a'*40, 'b'*40, 'c'*40

def fixture():
    return {'head': HEAD, 'tree': TREE, 'run_id': 1, 'jobs': [
        {'platform': p, 'job_id': i, 'run_id': 1, 'status': 'completed', 'conclusion': 'success',
         'checkout_sha': HEAD, 'checkout_tree': TREE,
         'steps': [{'name': n, 'conclusion': 'success'} for n in names]}
        for i, (p, names) in enumerate(REQUIRED.items(), 1)]}

class GateTests(unittest.TestCase):
    def test_full_pass(self):
        a = assess(fixture()); self.assertEqual(a['strict_ci'], 'PASS'); self.assertEqual(a['exact_count'], 4)
        self.assertEqual(a['physical_acceptance'], 'NOT_ASSESSED')
    def test_all_platform_mutations(self):
        cases = [({'status':'in_progress'}, 'PENDING'), ({'conclusion':'skipped'}, 'SKIPPED'),
                 ({'conclusion':'failure'}, 'NOT_SUCCESS'), ({'conclusion':'cancelled'}, 'NOT_SUCCESS'),
                 ({'checkout_sha':OTHER}, 'TREE_ONLY_PASS'), ({'checkout_sha':OTHER,'checkout_tree':OTHER}, 'CHECKOUT_MISMATCH'),
                 ({'checkout_sha':None}, 'CHECKOUT_UNPROVEN'), ({'checkout_tree':OTHER}, 'TREE_MISMATCH'),
                 ({'steps':[]}, 'STEP_UNPROVEN'), ({'run_id':2}, 'IDENTITY_MISMATCH'),
                 ({'job_id':0}, 'IDENTITY_MISMATCH'), ({'checkout_tree':'invalid'}, 'CHECKOUT_UNPROVEN')]
        for i, (p, _) in enumerate(REQUIRED.items()):
            for patch, expected in cases:
                with self.subTest(platform=p, expected=expected):
                    f=fixture(); f['jobs'][i].update(patch); a=assess(f)
                    self.assertEqual(a['platforms'][p],expected); self.assertEqual(a['strict_ci'],'HOLD'); self.assertEqual(a['exact_count'],3)
    def test_missing_and_duplicate(self):
        for i,p in enumerate(REQUIRED):
            f=fixture(); f['jobs'].pop(i); self.assertEqual(assess(f)['platforms'][p],'MISSING')
            f=fixture(); f['jobs'].append(deepcopy(f['jobs'][i])); self.assertEqual(assess(f)['platforms'][p],'DUPLICATE')
    def test_cross_platform_job_id_reuse(self):
        f=fixture(); f['jobs'][1]['job_id']=f['jobs'][0]['job_id']; a=assess(f)
        self.assertEqual(a['exact_count'],2); self.assertEqual(a['strict_ci'],'HOLD')
    def test_duplicate_step_even_if_pass(self):
        f=fixture(); f['jobs'][0]['steps'].append(deepcopy(f['jobs'][0]['steps'][0])); self.assertEqual(assess(f)['platforms']['core'],'STEP_UNPROVEN')
    def test_mixed_matrix(self):
        states = ['success','skipped','failure','cancelled']
        for combo in product(states, repeat=4):
            with self.subTest(combo=combo):
                f=fixture()
                for j,s in zip(f['jobs'],combo): j['conclusion']=s
                a=assess(f); self.assertEqual(a['exact_count'],combo.count('success'))
                self.assertEqual(a['strict_ci'],'PASS' if combo==('success',)*4 else 'HOLD')
    def test_invalid_pins(self):
        for patch in ({'head':'bad'},{'tree':None},{'run_id':True},{'run_id':0}):
            f=fixture(); f.update(patch)
            with self.assertRaises(ValueError): assess(f)
    def test_optional_tree_for_verified_mobile_sha(self):
        f=fixture(); f['jobs'][2].pop('checkout_tree'); self.assertEqual(assess(f)['platforms']['android'],'EXACT_PASS')

if __name__=='__main__': unittest.main()
