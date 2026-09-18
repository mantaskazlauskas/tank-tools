#!/usr/bin/env python3
"""
Refuse any write into the live WoW installation.

The wow-api agent learns from the addons installed on this machine -- a
hundred-odd of them, none of which this repo owns. Reading them is the point;
writing to them would corrupt somebody else's working addon with no way to tell
what changed. The agent is told it is read-only, but "told" is not "cannot",
and its tool list includes Bash.

So this is the part that does not rely on being asked nicely. It runs as a
PreToolUse hook and denies Write/Edit outright, plus any shell command that
both names the install and looks like it mutates something.

The one write that IS legitimate -- deploy.py copying the addon in -- is run by
a person, not by a tool call, so it never passes through here.
"""

import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(os.path.dirname(HERE))

# Single source of truth: the same constant deploy.py copies into. Hardcoding
# it here would go stale the first time the install moves, and a guard that
# points at the wrong directory is worse than none -- it reports success while
# protecting nothing.
def wow_root():
    try:
        with open(os.path.join(PROJECT, "deploy.py"), encoding="utf-8") as f:
            m = re.search(r'^WOW_ROOT\s*=\s*r?["\'](.+?)["\']', f.read(), re.M)
            return m.group(1) if m else None
    except OSError:
        return None


def norm(p):
    return p.replace("\\", "/").rstrip("/").lower()


# Anything that could change a file. Read-only shell work -- cat, grep, ls,
# find, head -- is exactly what the agent is here to do, so it passes.
MUTATORS = re.compile(
    r"(^|[\s;&|(`])("
    r"rm|rmdir|mv|cp|tee|truncate|mkdir|touch|chmod|chown|unlink|del|erase|"
    r"ren|rename|move|copy|xcopy|robocopy|"
    r"Remove-Item|Set-Content|Add-Content|Out-File|New-Item|Copy-Item|"
    r"Move-Item|Rename-Item|Clear-Content"
    r")([\s]|$)"
    r"|>>?[^&]"                      # redirection
    r"|\bsed\b[^|;]*-i"              # in-place sed
    r"|\bpython\b[^|;]*\bdeploy\b",  # the deploy script itself
    re.I,
)


def deny(reason):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))
    sys.exit(0)


def main():
    try:
        payload = json.load(sys.stdin)
    except (ValueError, OSError):
        return                      # unreadable payload is not a write

    root = wow_root()
    if not root:
        return

    root_n = norm(root)
    tool = payload.get("tool_name", "")
    args = payload.get("tool_input") or {}

    if tool in ("Write", "Edit", "NotebookEdit"):
        target = norm(str(args.get("file_path", "")))
        if target.startswith(root_n):
            deny("The WoW installation is read-only. The wow-api agent learns "
                 "from the installed addons; it never modifies them. Use "
                 "deploy.py if Tank Tools itself needs installing.")

    if tool in ("Bash", "PowerShell"):
        cmd = str(args.get("command", ""))
        if root_n in norm(cmd) and MUTATORS.search(cmd):
            deny("That command would write inside the WoW installation, which "
                 "is read-only here. Reading it -- cat, grep, ls, find -- is "
                 "allowed and is the point.")


main()
