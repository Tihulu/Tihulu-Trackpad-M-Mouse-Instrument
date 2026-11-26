"""CI-only dependency preflight. Never retry a test, compiler or unknown error."""
import re
import subprocess
import sys
import time

COMMAND = ["gradle", "--no-daemon", ":extractDebugAnnotations"]
MAX_ATTEMPTS = 3
FAILED_TASK = ":extractDebugAnnotations"
RATE_LIMIT = re.compile(
    r"^\s*> Could not GET 'https://repo\.maven\.apache\.org/maven2/[^'\s]+'. "
    r"Received status code 429 from server: Too Many Requests\s*$"
)


def retryable(output):
    # Accept only the known dependency-resolution failure shape, with every
    # HTTP leaf a Maven Central 429. Unknown leaves fail closed.
    tasks = re.findall(r"^> Task (\S+) FAILED\s*$", output, re.M)
    if tasks != [FAILED_TASK]:
        return False
    if output.count("FAILURE: Build failed with an exception.") != 1:
        return False
    if "Could not resolve all files for configuration" not in output:
        return False
    if re.search(r"(?mi)^\s*(?:e: |error:|[0-9]+ tests completed, [1-9]|> Task .*Test FAILED)", output):
        return False
    lines = output.splitlines()
    try:
        start = lines.index("* What went wrong:")
        end = lines.index("* Try:", start + 1)
    except ValueError:
        return False
    block = [line.strip() for line in lines[start + 1:end] if line.strip()]
    if not block or block[0] != "Execution failed for task ':extractDebugAnnotations'.":
        return False
    rates = 0
    for line in block[1:]:
        if RATE_LIMIT.fullmatch(line):
            rates += 1
        elif (line.startswith("> Could not resolve ")
              or line.startswith("> Could not get resource 'https://repo.maven.apache.org/maven2/")
              or line == "Required by:"
              or re.fullmatch(r"project : (?:> .+)+", line)):
            continue
        else:
            return False
    return rates > 0


def run(command=COMMAND, runner=subprocess.run, sleep=time.sleep):
    for attempt in range(1, MAX_ATTEMPTS + 1):
        result = runner(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                        text=True, errors="replace", check=False)
        print(f"Android dependency preflight attempt {attempt}/{MAX_ATTEMPTS}", flush=True)
        print(result.stdout, flush=True)
        if result.returncode == 0:
            return 0
        if attempt == MAX_ATTEMPTS or not retryable(result.stdout):
            return result.returncode or 1
        print("::warning::Maven Central HTTP 429 during dependency-only preflight; "
              "preserving failed output and backing off.", flush=True)
        sleep(15 * attempt)
    return 1


if __name__ == "__main__":
    sys.exit(run())
