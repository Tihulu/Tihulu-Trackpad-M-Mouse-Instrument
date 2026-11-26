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
DEPENDENCY = r"[\w.+-]+:[\w.+-]+:[\w.+-]+"
REPOSITORY_URL = r"https://(?:repo\.maven\.apache\.org/maven2|plugins\.gradle\.org/m2)/[^'\s]+"
WRAPPER = re.compile(
    rf"> (?:Could not resolve {DEPENDENCY}\.|Could not get resource '{REPOSITORY_URL}'\."
    rf"|Could not parse POM {REPOSITORY_URL})"
)


def retryable(output):
    # Accept only the known dependency-resolution failure shape, with every
    # HTTP leaf a Maven Central 429. Unknown leaves fail closed.
    tasks = re.findall(r"^> Task (\S+) FAILED\s*$", output, re.M)
    if output.count("FAILURE: Build failed with an exception.") != 1:
        return False
    if re.search(r"(?mi)^\s*(?:e: |error:|[0-9]+ tests completed, [1-9]|> Task .*Test FAILED)", output):
        return False
    lines = output.splitlines()
    try:
        start = lines.index("* What went wrong:")
        end = lines.index("* Try:", start + 1)
    except ValueError:
        return False
    block = [line.rstrip() for line in lines[start + 1:end] if line.strip()]
    annotation = (tasks == [FAILED_TASK]
                  and block[:1] == ["Execution failed for task ':extractDebugAnnotations'."]
                  and len(block) > 1
                  and re.fullmatch(r"> Could not resolve all files for configuration ':detachedConfiguration\d+'\.", block[1]))
    classpath = (not tasks and block[:2] == ["A problem occurred configuring root project 'TihuluMobileSensors'.",
                                             "> Could not resolve all artifacts for configuration ':classpath'."])
    if not (annotation or classpath):
        return False
    # Required-by metadata names requesting components. Only an indented
    # nested cause may explain a wrapper, including a plugin portal redirect.
    causes = []
    for line in block[2:]:
        detail = line.lstrip()
        if detail == "Required by:" or re.fullmatch(rf"project :(?: > {DEPENDENCY})*", detail):
            continue
        causes.append((len(line) - len(detail), detail))
    rates = 0
    for index, (depth, line) in enumerate(causes):
        if RATE_LIMIT.fullmatch(line):
            rates += 1
        elif WRAPPER.fullmatch(line) and index + 1 < len(causes) and causes[index + 1][0] > depth:
            continue
        elif (depth == 0 and index == len(causes) - 1 and rates > 0
              and re.fullmatch(r"> There (?:is 1 more failure|are [1-9]\d* more failures) with identical causes\.", line)):
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
