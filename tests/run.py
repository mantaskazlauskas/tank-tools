#!/usr/bin/env python3
"""
Load Tank Tools into a real Lua 5.1 interpreter against a stubbed WoW API and
run the assertion suites.

The addon is not mocked: harness.lua stubs CreateFrame, the Unit* calls, events
and the ticker, then loads every file the .toc lists, in .toc order. What runs
is the shipping code.

    pip install lupa
    python tests/run.py            # every suite, every scenario
    python tests/run.py core       # one suite
    python tests/run.py core:migrate

Scenarios set up a different world before the addon loads -- an existing v1
saved-variables table, or an extra settings page -- so the same assertions can
be run against each.
"""

import sys
import pathlib

try:
    from lupa.lua51 import LuaRuntime          # WoW runs Lua 5.1
except ImportError:
    sys.exit("tests need lupa: pip install lupa")

HERE = pathlib.Path(__file__).resolve().parent
ADDON = (HERE.parent / "TankTools").as_posix()

# suite file -> scenarios it should be run under
SUITES = {
    "core":      ["fresh", "migrate", "tabs"],
    "tankwatch": ["fresh", "secret", "engine"],
    "debuffs":   ["fresh", "secret"],
}

# A v1 (flat) saved-variables table, as it existed before the module split.
V1_DB = """
TankToolsDB = {
    npMarker = false, npMarkerWarn = true, npSize = 44,
    npAnchor = "TOP", npColor = { 0.35, 0.95, 1.00 },
    onlyTankSpec = false, sound = false,
    someDeadSettingFromV0 = "gone",
}
"""


def run(suite, scenario):
    lua = LuaRuntime(unpack_returned_tuples=True)

    if scenario == "migrate":
        lua.execute(V1_DB)

    lua.execute('SCENARIO = "%s"' % scenario)

    load = lua.eval("function(path, arg) return assert(loadfile(path))(arg) end")
    load(str(HERE / "harness.lua"), ADDON)
    load(str(HERE / ("suite_%s.lua" % suite)), None)

    return int(lua.eval("FAILED") or 0)


def main():
    wanted = sys.argv[1:] or list(SUITES)

    jobs = []
    for w in wanted:
        if ":" in w:
            suite, scenario = w.split(":", 1)
            jobs.append((suite, scenario))
        elif w in SUITES:
            jobs.extend((w, s) for s in SUITES[w])
        else:
            sys.exit("unknown suite: %s (have %s)" % (w, ", ".join(SUITES)))

    failed = 0
    for suite, scenario in jobs:
        print("\n#### %s / %s %s" % (suite, scenario, "#" * 40))
        failed += run(suite, scenario)

    print("\n" + "=" * 60)
    if failed:
        print("%d FAILED" % failed)
        return 1
    print("all suites passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
