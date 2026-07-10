import os
import subprocess
import sys

RELEASE_FILES = {"build.zig", "setup.sh"}
RELEASE_PREFIXES = ("src/", "include/", "lib/")


def run_git_command(args: list[str], *, allow_failure: bool = False) -> str | None:
    result = subprocess.run(
        ["git", *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if result.returncode == 0:
        return result.stdout.strip()
    if allow_failure:
        return None

    print(result.stderr.strip() or f"git {' '.join(args)} failed", file=sys.stderr)
    raise SystemExit(result.returncode)


def is_release_input(path: str) -> bool:
    return path in RELEASE_FILES or path.startswith(RELEASE_PREFIXES)


def check_release_changes() -> bool:
    last_tag = run_git_command(["describe", "--tags", "--abbrev=0"], allow_failure=True)
    if not last_tag:
        print("No tags found; creating the initial release.")
        return True

    print(f"Comparing HEAD against last tag: {last_tag}")
    diff_output = run_git_command(["diff", "--name-only", last_tag, "HEAD"])
    if not diff_output:
        print("No file changes found.")
        return False

    changed_files = [path.strip() for path in diff_output.splitlines() if path.strip()]
    release_inputs = [path for path in changed_files if is_release_input(path)]

    if release_inputs:
        print("Release-relevant changes:")
        for path in release_inputs:
            print(f"- {path}")
        return True

    print("No release-relevant files changed.")
    return False


if __name__ == "__main__":
    should_release = check_release_changes()
    print(f"Should release: {should_release}")

    github_output = os.environ.get("GITHUB_OUTPUT")
    if github_output:
        with open(github_output, "a", encoding="utf-8") as output:
            output.write(f"should_release={'true' if should_release else 'false'}\n")
