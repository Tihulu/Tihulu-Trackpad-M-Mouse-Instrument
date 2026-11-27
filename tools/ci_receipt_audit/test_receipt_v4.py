import unittest
from test_receipt_gate import evidence
from test_ci_gate import HEAD, TREE, OTHER
from receipt_gate import review, digest

class ReceiptV4Tests(unittest.TestCase):
    def test_missing_job_attempt_does_not_pass(self):
        a=evidence()
        for j in a[0][0]['jobs']: j.pop('run_attempt',None)
        r=review(*a)[0]
        self.assertEqual(r['receipt_gate'],'HOLD')
        self.assertEqual(r['log_exact_count'],4)
    def test_job_attempt_mismatch(self):
        a=evidence()
        for j in a[0][0]['jobs']: j['run_attempt']=1
        a[0][0]['jobs'][0]['run_attempt']=2
        r=review(*a)[0]
        self.assertEqual(r['attempt_checks']['core'],'MISMATCH')
        self.assertEqual(r['receipt_gate'],'HOLD')
    def test_invalid_job_attempt(self):
        for val in (0, True, -1, '1'):
            with self.subTest(val=val):
                a=evidence(); a[0][0]['jobs'][0]['run_attempt']=val
                r=review(*a)[0]
                self.assertEqual(r['attempt_checks']['core'],'INVALID')
                self.assertEqual(r['receipt_gate'],'HOLD')
    def test_mobile_tree_only_cannot_be_proven_by_sha_excerpt(self):
        for index in (2,3):
            with self.subTest(index=index):
                a=evidence(); j=a[0][0]['jobs'][index]; e=a[3][index]
                j['checkout_sha']=OTHER
                j['checkout_tree']=TREE
                e['lines']=[x.replace(HEAD,OTHER) for x in e['lines']]
                e['sha256']=digest(e['lines'])
                r=review(*a)[0]
                self.assertEqual(r['log_checks'][j['platform']],'TREE_UNPROVEN')
                self.assertEqual(r['receipt_gate'],'HOLD')
    def test_all_attempts_match(self):
        a=evidence()
        for j in a[0][0]['jobs']: j['run_attempt']=1
        self.assertEqual(review(*a)[0]['receipt_gate'],'PASS')
    def test_unverified_attempt_mismatch_even_if_third_unknown(self):
        a=evidence(); a[2][0]['run_attempt']=2
        a[0][0]['jobs'][0].pop('run_attempt',None)
        r=review(*a)[0]
        self.assertEqual(r['attempt_checks']['core'],'MISMATCH')
        self.assertEqual(r['receipt_gate'],'HOLD')
