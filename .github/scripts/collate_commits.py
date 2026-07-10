import os
import re
import subprocess
import sys

FIX_PREFIXES = ("fix", "fixed", "bugfix", "repair", "resolve")
IMPROVEMENT_PREFIXES = (
    "add",
    "feat",
    "feature",
    "improve",
    "optimize",
    "harden",
    "use",
    "run",
    "document",
    "update",
)


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


def get_commit_messages() -> list[str]:
    last_tag = run_git_command(["describe", "--tags", "--abbrev=0"], allow_failure=True)
    revision_range = f"{last_tag}..HEAD" if last_tag else "HEAD"
    log_output = run_git_command(["log", revision_range, "--pretty=format:%s"])
    if not log_output:
        return []
    return [message.strip() for message in log_output.splitlines() if message.strip()]


def clean_message(message: str) -> str:
    return re.sub(r":[a-zA-Z0-9_+-]+:", "", message).strip()


def classify(message: str) -> str:
    lowered = clean_message(message).lower()
    first_word = lowered.split(maxsplit=1)[0].rstrip(":") if lowered else ""

    if ":bug:" in message or first_word in FIX_PREFIXES:
        return "fixes"
    if any(marker in message for marker in (":sparkles:", ":children_crossing:", ":zap:")):
        return "improvements"
    if first_word in IMPROVEMENT_PREFIXES:
        return "improvements"
    return "other"


def main() -> None:
    buckets: dict[str, list[str]] = {
        "improvements": [],
        "fixes": [],
        "other": [],
    }
    has_robot_changes = False
    seen: set[str] = set()

    for message in reversed(get_commit_messages()):
        if message.startswith("Merge "):
            continue
        if ":robot:" in message:
            has_robot_changes = True

        cleaned = clean_message(message)
        if not cleaned or cleaned in seen:
            continue
        seen.add(cleaned)
        buckets[classify(message)].append(cleaned)

    sections = (
        ("improvements", "### New features and improvements"),
        ("fixes", "### Fixed bugs"),
        ("other", "### Other"),
    )

    output_lines: list[str] = []
    for bucket_name, heading in sections:
        entries = buckets[bucket_name]
        if not entries:
            continue
        output_lines.append(heading)
        output_lines.extend(f"- {entry}" for entry in entries)
        output_lines.append("")

    if has_robot_changes:
        if output_lines and output_lines[-1] == "":
            output_lines.pop()
        output_lines.extend(("---", "_Changes made with the help of an LLM_"))

    final_output = "\n".join(output_lines).strip()
    print(final_output)

    github_summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if github_summary:
        with open(github_summary, "a", encoding="utf-8") as summary:
            summary.write(final_output + "\n")


if __name__ == "__main__":
    main()
