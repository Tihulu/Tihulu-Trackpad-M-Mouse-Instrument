"""End-to-end exit-code contract using synthetic six-candidate fixtures."""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from test_snapshot_gate import candidate, pins

ROOT = Path(__file__).resolve().parent

class CliTests(unittest.TestCase):
    def run_gate(self, data, pins):
        with tempfile.TemporaryDirectory() as d:
            snap, pin = Path(d)/'snapshot.json', Path(d)/'pins.json'
            snap.write_text(json.dumps(data), encoding='utf-8')
            pin.write_text(json.dumps(pins), encoding='utf-8')
            return subprocess.run([sys.executable, str(ROOT/'ci_gate.py'), str(snap), '--pins', str(pin)], capture_output=True, text=True)
    def setUp(self):
        self.snapshot = [candidate(i,i) for i in range(1,7)]
        for idx in (3,4):
            for job in self.snapshot[idx]['jobs']: job['conclusion']='skipped'
        for job in self.snapshot[5]['jobs'][2:]: job['status']='in_progress'; job['conclusion']=None
        self.pins=pins(*self.snapshot)
    def test_all_pass_exit_zero(self):
        r=self.run_gate(self.snapshot[:2], self.pins[:2]); self.assertEqual(r.returncode,0,r.stderr)
        self.assertTrue(all(x['strict_ci']=='PASS' for x in json.loads(r.stdout)))
    def test_hold_exit_one(self):
        r=self.run_gate(self.snapshot, self.pins); self.assertEqual(r.returncode,1,r.stderr)
        self.assertEqual([x['exact_count'] for x in json.loads(r.stdout)],[4,4,4,0,0,2])
    def test_pin_mismatch_exit_two(self):
        r=self.run_gate(self.snapshot,self.pins[:-1]); self.assertEqual(r.returncode,2); self.assertFalse(r.stdout)
    def test_null_pin_exit_two(self):
        r=self.run_gate(self.snapshot,None); self.assertEqual(r.returncode,2); self.assertFalse(r.stdout)

if __name__ == '__main__': unittest.main()
