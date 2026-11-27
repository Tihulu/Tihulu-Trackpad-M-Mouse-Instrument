import unittest
from copy import deepcopy
from ci_gate import REQUIRED
from test_snapshot_gate import candidate,pins
from test_ci_gate import HEAD,TREE,OTHER
from receipt_gate import review,digest,parse_excerpt


def evidence():
    c=candidate()
    run={'run_id':1,'workflow':'TIHULU Trackpad Instrument CI','head':HEAD,'run_attempt':1,'status':'completed','conclusion':'success'}
    receipts=[]
    for j in c['jobs']:
        j['run_attempt']=1
        for s in j['steps']: s['status']='completed'
        p=j['platform']; lines=[f"2026-11-27T05:13:0{j['job_id']}.000000{i}Z {x}" for i,x in enumerate([
          '[command]/usr/bin/git log -1 --format=%H',HEAD,'  EXPECTED_SHA: '+HEAD]+(['Verified checkout: '+HEAD+'; tree: '+TREE] if p in ('core','macos') else []))]
        receipts.append(dict(job_id=j['job_id'],run_id=1,platform=p,run_attempt=1,lines=lines,sha256=digest(lines)))
    return [c],pins(c),[run],receipts

class ReceiptTests(unittest.TestCase):
    def test_complete_fixture(self):
        self.assertEqual(review(*evidence())[0]['receipt_gate'],'PASS')
    def test_run_summary_failure(self):
        for status,conclusion in [('completed','failure'),('in_progress',None),('queued',None),('completed','cancelled')]:
            a=evidence(); a[2][0].update(status=status,conclusion=conclusion)
            self.assertEqual(review(*a)[0]['receipt_gate'],'HOLD')
    def test_missing_attempt(self):
        for location in (2,3):
            a=evidence(); a[location][0].pop('run_attempt'); r=review(*a)[0]
            self.assertEqual(r['receipt_gate'],'HOLD');self.assertEqual(r['log_exact_count'],4)
    def test_attempt_mismatch(self):
        a=evidence(); a[3][0]['run_attempt']=2;r=review(*a)[0]
        self.assertEqual(r['attempt_checks']['core'],'MISMATCH');self.assertEqual(r['receipt_gate'],'HOLD')
    def test_invalid_attempt(self):
        for v in (True,0,-1,'1'):
            a=evidence();a[2][0]['run_attempt']=v
            with self.assertRaises(ValueError):review(*a)
    def test_step_explicit_status(self):
        a=evidence();a[0][0]['jobs'][0]['steps'][0].pop('status');r=review(*a)[0]
        self.assertEqual(r['log_checks']['core'],'STEP_STATUS_UNPROVEN');self.assertEqual(r['receipt_gate'],'HOLD')
    def test_wrong_run_head_workflow(self):
        for k,v in [('head',OTHER),('workflow','RAG'),('run_id',2)]:
            a=evidence();a[2][0][k]=v
            with self.assertRaises(ValueError):review(*a)
    def test_receipt_reuse_and_unexpected(self):
        for mode in ('duplicate','extra'):
            a=evidence(); b=deepcopy(a[3][0]);
            if mode=='extra':b['job_id']=999
            a[3].append(b)
            with self.assertRaises(ValueError):review(*a)
    def test_wrong_receipt_platform_or_run(self):
        for k,v in [('platform','ios'),('run_id',2),('run_id',True)]:
            a=evidence();a[3][0][k]=v
            self.assertEqual(review(*a)[0]['log_checks']['core'],'RECEIPT_IDENTITY_MISMATCH')
    def test_reused_excerpt_digest(self):
        a=evidence(); a[3][1]['sha256']=a[3][0]['sha256']
        with self.assertRaises(ValueError):review(*a)
    def test_missing_excerpt(self):
        a=evidence();a[3].pop(0);self.assertEqual(review(*a)[0]['log_checks']['core'],'EXCERPT_MISSING')
    def test_malformed_excerpt_matrix(self):
        for index,replacement in [(0,'other command'),(1,'0'*40),(2,'  EXPECTED_SHA: '+OTHER),(3,'Verified checkout: '+OTHER+'; tree: '+TREE),(3,'Verified checkout: '+HEAD+'; tree: '+'0'*40)]:
            a=evidence(); e=a[3][0];e['lines'][index]=e['lines'][index].split(' ',1)[0]+' '+replacement;e['sha256']=digest(e['lines'])
            self.assertEqual(review(*a)[0]['log_checks']['core'],'EXCERPT_INVALID')
    def test_reordered_or_missing_lines(self):
        for mode in ('reverse','missing','duplicate'):
            a=evidence(); e=a[3][0];l=e['lines'];e['lines']=l[::-1] if mode=='reverse' else l[:-1] if mode=='missing' else [l[0],l[0],*l[2:]];e['sha256']=digest(e['lines'])
            self.assertEqual(review(*a)[0]['log_checks']['core'],'EXCERPT_INVALID')
    def test_checksum_and_normalized_mismatch(self):
        a=evidence();a[3][0]['sha256']='bad';self.assertEqual(review(*a)[0]['log_checks']['core'],'EXCERPT_INVALID')
        a=evidence();a[0][0]['jobs'][0]['checkout_sha']=OTHER;self.assertEqual(review(*a)[0]['log_checks']['core'],'EXCERPT_INVALID')
    def test_pins_required(self):
        a=list(evidence());a[1]=None
        with self.assertRaises(ValueError):review(*a)
    def test_invalid_date(self):
        a=evidence();e=a[3][0];e['lines'][0]=e['lines'][0].replace('2026-11-27','2026-02-30');e['sha256']=digest(e['lines'])
        self.assertEqual(review(*a)[0]['log_checks']['core'],'EXCERPT_INVALID')

if __name__=='__main__':unittest.main()
