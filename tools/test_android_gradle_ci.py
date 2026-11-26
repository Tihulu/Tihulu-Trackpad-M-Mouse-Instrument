import unittest
from types import SimpleNamespace
from android_gradle_ci import run, retryable

RATE = """> Task :extractDebugAnnotations FAILED
FAILURE: Build failed with an exception.
* What went wrong:
Execution failed for task ':extractDebugAnnotations'.
> Could not resolve all files for configuration ':detachedConfiguration1'.
   > Could not resolve org.codehaus.groovy:groovy:3.0.21.
     Required by:
         project : > com.android.tools.lint:lint-gradle:31.7.3
      > Could not get resource 'https://repo.maven.apache.org/maven2/a.pom'.
         > Could not GET 'https://repo.maven.apache.org/maven2/a.pom'. Received status code 429 from server: Too Many Requests
* Try:
BUILD FAILED
"""


class RetryPolicyTests(unittest.TestCase):
    def test_known_rate_limit(self):
        self.assertTrue(retryable(RATE))

    def test_never_retry_compile_or_test_failure(self):
        self.assertFalse(retryable(RATE.replace(":extractDebugAnnotations FAILED", ":testDebugUnitTest FAILED")))
        self.assertFalse(retryable(RATE + "\ne: file:///source.kt: unresolved reference"))
        self.assertFalse(retryable(RATE.replace("* Try:", "   > Unresolved compilation failure\n* Try:")))

    def test_reject_other_hosts_status_and_mixed_causes(self):
        self.assertFalse(retryable(RATE.replace("429", "403")))
        self.assertFalse(retryable(RATE.replace("repo.maven.apache.org", "example.com")))
        self.assertFalse(retryable(RATE.replace("* Try:", "   > Could not GET 'https://repo.maven.apache.org/maven2/b.pom'. Received status code 503 from server: Unavailable\n* Try:")))

    def test_bounded_retry(self):
        results = iter([SimpleNamespace(returncode=1, stdout=RATE)] * 3)
        delays = []
        self.assertEqual(run(runner=lambda *a, **k: next(results), sleep=delays.append), 1)
        self.assertEqual(delays, [15, 30])

    def test_recover_without_rerunning_test_tasks(self):
        results = iter([SimpleNamespace(returncode=1, stdout=RATE), SimpleNamespace(returncode=0, stdout="BUILD SUCCESSFUL")])
        calls, delays = [], []
        def runner(command, **kwargs):
            calls.append(command)
            return next(results)
        self.assertEqual(run(runner=runner, sleep=delays.append), 0)
        self.assertEqual(delays, [15])
        self.assertTrue(all(c[-1] == ":extractDebugAnnotations" for c in calls))

    def test_unknown_failure_stops_immediately(self):
        delays = []
        self.assertEqual(run(runner=lambda *a, **k: SimpleNamespace(returncode=2, stdout="compiler failure"), sleep=delays.append), 2)
        self.assertEqual(delays, [])


if __name__ == "__main__":
    unittest.main()
