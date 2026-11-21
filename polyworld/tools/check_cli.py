"""Exercise the built Generals executable through its public CLI."""

import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]


def run(executable, arguments, success=True):
    """Check process status and retain diagnostics for a failed CLI case."""
    result = subprocess.run(
        [str(executable), *map(str, arguments)], cwd=ROOT,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, timeout=30,
    )
    assert (result.returncode == 0) == success, (arguments, result.stdout)
    for marker in ("Traceback", "IndexDefect", "OverflowDefect", "unhandled exception"):
        assert marker not in result.stdout, (arguments, result.stdout)
    return result.stdout


def main():
    """Verify shared aliases, deterministic recordings, pacing, and errors."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", type=Path, default=ROOT / "out/generals-sim")
    args = parser.parse_args()
    executable = args.executable.resolve()
    assert executable.is_file(), f"Build the executable first: {executable}"
    with tempfile.TemporaryDirectory(prefix="generals-cli-") as directory:
        folder = Path(directory)
        bot = folder / "pass policy.bas"
        bot.write_text("tick = worldTick()\n", encoding="utf-8")
        first = folder / "first.replay"
        second = folder / "second.replay"
        base = ["--headless", "--bot", f"{bot}:2", "--seed", "17", "--ticks", "8"]
        output = run(executable, [*base, "--record", first])
        assert "Seed 17, 2 players, 8 ticks." in output
        run(executable, [
            "--headless", f"--bot:{bot}:2", "--seed=17", "--ticks=8",
            f"--record:{second}",
        ])
        assert first.read_bytes() == second.read_bytes()
        print("PASS split/compact flags and byte-identical recordings")

        for replay_flags in (["--replay", first], [f"--replay={first}"]):
            output = run(executable, ["--headless", *replay_flags])
            assert "Verified 8 replay ticks in lockstep." in output
        print("PASS split/equals replay flags")

        run(executable, [
            "--headless", "--players=2", f"--seat-bot=1:{bot}", f"--seat-bot=2:{bot}",
            "--seed=17", "--turns=8", f"--record={second}",
        ])
        assert first.read_bytes() == second.read_bytes()
        print("PASS existing per-seat bot and duration aliases")

        for flags, ticks in [
            (["--seconds", "3"], 6), (["--minutes=1"], 120),
            (["--seconds=3", "--ticks", "8"], 8),
            (["--ticks=8", "--seconds", "2"], 4),
        ]:
            output = run(executable, [*base, *flags])
            assert f"2 players, {ticks} ticks." in output
        print("PASS two-Hz durations and last-flag precedence")

        config = folder / "match config.json"
        config.write_text(json.dumps({
            "players": [{"name": "Configured"}, {}], "seed": 23, "maxTicks": 99,
        }), encoding="utf-8")
        output = run(executable, [*base, "--config", config, "--seat-name", "2:Named"])
        assert "Seed 17, 2 players, 8 ticks." in output
        assert "Configured (MMR ?)" in output and "Named (MMR ?)" in output
        print("PASS engine settings and explicit CLI overrides")

        started = time.monotonic()
        run(executable, [*base, "--headless-tick-rate", "40", "--record", second])
        assert time.monotonic() - started >= 0.18
        assert first.read_bytes() == second.read_bytes()
        started = time.monotonic()
        output = run(executable, [
            "--headless", "--replay", first, "--headless-tick-rate:40",
        ])
        assert time.monotonic() - started >= 0.18
        assert "Verified 8 replay ticks" in output
        print("PASS headless pacing without replay changes")

        for seed in (2**31, 2**32 + 17, 2**63 + 17, 2**64 - 1):
            config.write_text(json.dumps({
                "players": [{}, {}], "seed": seed, "max_ticks": 8,
            }), encoding="utf-8")
            output = run(executable, [
                "--headless", "--bot", f"{bot}:2", "--config", config,
                "--record", first,
            ])
            assert f"Seed {seed}, 2 players, 8 ticks." in output
            output = run(executable, ["--headless", "--replay", first])
            assert "Verified 8 replay ticks in lockstep." in output
        print("PASS full unsigned 64-bit seeds through config and replay")

        for flags in [
            ["--player"], ["--player:10"], ["--player", "2"],
            ["--screenshot", folder / "frame.png"],
            ["--replay", first, "--record", second],
            ["--replay", first, "--bot", str(bot)],
            ["--replay", first, "--player"],
            ["--replay", first, f"--seat-bot=1:{bot}"],
            ["--bot", f"{bot}:0"], ["--bot", f"{bot}:11"],
            ["--bot", f"{bot}:99999999999999999999999999"],
            ["--bot", f"{bot}:2", "--players", "3"],
            ["--bot", f"{bot}:2", f"--seat-bot=1:{bot}"],
            ["--seconds", "50001"], ["--ticks", "0"],
            ["--seed", "2147483648"], ["--seed", "18446744073709551616"],
            ["--play=perhaps"], ["--speed", "0"],
            ["--windowSize", "0x400"], ["--vsync", "perhaps"],
            ["--headless-tick-rate", "10001"], ["--llm-mode", "unknown"],
            ["--replay"], ["--record="], ["--bot"],
        ]:
            run(executable, ["--headless", *flags], success=False)
        print("PASS invalid values, controller conflicts, and missing arguments")

        output = run(executable, ["--help"])
        for flag in ("--player", "--bot", "--replay", "--play", "--windowSize"):
            assert flag in output
        print("All executable CLI checks passed")


if __name__ == "__main__":
    main()
