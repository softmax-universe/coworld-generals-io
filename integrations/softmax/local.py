"""Run a complete local Coworld episode without Docker or a Softmax account."""

import argparse
import hashlib
import json
import os
import secrets
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import urlencode

import httpx

from .config import PLAYER_NAMES
from .file_players import FileSeat, Seats, SocketSeat

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", choices=("polyworld", "jax"), default="polyworld")
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--max-turns", type=int, help="default: 50002 for FFA, 2000 for 1v1, 1200 with --human")
    parser.add_argument("--variant", choices=("competition", "ffa", "castles"), default="competition")
    parser.add_argument("--players", type=int, choices=range(3, 9), default=4, help="FFA seats (default: 4)")
    parser.add_argument("--human", action="store_true", help="control slot 0 in the browser")
    parser.add_argument("--bundled-bots", action="store_true",
                        help="explicitly use bundled Expander opponents instead of league leaders")
    parser.add_argument(
        "--basic",
        action="append",
        default=[],
        metavar="SLOT=PATH",
        help="execute a BASIC file in this zero-based seat; repeat for multiple seats",
    )
    parser.add_argument("--keep-open", action="store_true", help="keep the server open for replay inspection")
    parser.add_argument("--output", type=Path, default=ROOT / "integrations/softmax/local-output")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    # Each run gets its own directory so old success artifacts cannot mask failure.
    run_dir = output / f"episode-{time.time_ns()}"
    run_dir.mkdir(mode=0o700)
    count = args.players if args.variant == "ffa" else 2
    basic = {}
    for entry in args.basic:
        slot, separator, path = entry.partition("=")
        if not separator or not slot.isdecimal() or not 0 <= int(slot) < count or int(slot) in basic:
            parser.error("--basic requires a unique in-range SLOT=PATH")
        if args.human and int(slot) == 0:
            parser.error("human slot 0 cannot also execute a BASIC file")
        basic[int(slot)] = Path(path).resolve()
    if args.human and len(basic) < count - 1 and not args.bundled_bots:
        parser.error("local human play needs --bundled-bots or explicit --basic seats; "
                     "use python -m integrations.softmax.play_leaders for leaderboard lobbies")
    tokens = [secrets.token_urlsafe(24) for _ in range(count)]
    names = [basic[slot].stem if slot in basic else f"Bundled Expander {slot}"
             for slot in range(count)] if args.human else PLAYER_NAMES[:count]
    config = {
        "tokens": tokens,
        "players": [{"name": "You" if args.human and slot == 0 else name} for slot, name in enumerate(names)],
        "ruleset": "build_castles" if args.variant == "castles" else "classic",
        "seed": args.seed,
        "max_turns": args.max_turns or (1200 if args.human else 50002 if args.variant == "ffa" else 2000),
        "tick_interval_seconds": 0.5 if args.human else 0.0,
        "turn_timeout_seconds": 1 if args.human else 0.5,
    }
    config_file = run_dir / "config.json"
    config_file.write_text(json.dumps(config))
    config_file.chmod(0o600)
    env = {
        **os.environ,
        "JAX_PLATFORMS": "cpu",
        "GENERALS_ENGINE": args.engine,
        "COGAME_CONFIG_URI": config_file.as_uri(),
        "COGAME_HOST": "127.0.0.1",
        "COGAME_PORT": str(args.port),
        "GENERALS_KEEP_OPEN": "1",
        "COGAME_RESULTS_URI": (run_dir / "results.json").as_uri(),
        "COGAME_SAVE_REPLAY_URI": (run_dir / ("game.replay" if args.engine == "polyworld" else "replay.json")).as_uri(),
        "COGAME_PLAYER_FAILURE_URI": (run_dir / "failure.json").as_uri(),
    }
    if basic:
        seats: list[FileSeat | SocketSeat] = []
        for slot in range(count):
            if slot in basic:
                content = basic[slot].read_bytes()
                seats.append(
                    FileSeat(
                        kind="policy",
                        slot=slot,
                        file_uri=basic[slot].as_uri(),
                        content_hash="sha256:" + hashlib.sha256(content).hexdigest(),
                        size_bytes=len(content),
                        log_uri=(run_dir / f"policy_agent_{slot}.log").as_uri(),
                        artifact_uri=(run_dir / f"policy_artifact_{slot}.zip").as_uri(),
                    )
                )
            else:
                seats.append(SocketSeat(kind="human" if args.human and slot == 0 else "container", slot=slot))
        roster = run_dir / "player_seats.json"
        roster.write_text(
            Seats(
                schema="coworld-play-seats/2",
                seats=seats,
                player_status_uri=(run_dir / "game_player_status.json").as_uri(),
            ).model_dump_json(by_alias=True, exclude_none=True)
        )
        env["COGAME_PLAYER_SEATS_URI"] = roster.as_uri()
    processes = []
    base = f"http://127.0.0.1:{args.port}"
    try:
        server = subprocess.Popen([sys.executable, "-m", "integrations.softmax.server"], cwd=ROOT, env=env)
        processes.append(server)
        with httpx.Client(timeout=1) as client:
            for _ in range(600):
                if server.poll() is not None:
                    raise RuntimeError("game server exited during startup")
                try:
                    if client.get(base + "/healthz").status_code == 200:
                        break
                except httpx.TransportError:
                    pass
                time.sleep(0.1)
            else:
                raise RuntimeError("game server did not become ready within 60 seconds")
        for slot in range(count):
            if slot in basic:
                continue
            query = urlencode({"slot": slot, "token": tokens[slot]})
            if slot == 0 and args.human:
                print(f"Play: {base}/client/player?{query}", flush=True)
            else:
                player_env = {**os.environ, "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{args.port}/player?{query}"}
                module = "builder_player" if args.variant == "castles" else "player"
                processes.append(subprocess.Popen(
                    [sys.executable, "-m", f"integrations.softmax.{module}"], env=player_env, cwd=ROOT))
        print(f"Watch: {base}/client/global", flush=True)
        print(f"Artifacts: {run_dir}", flush=True)
        deadline = time.monotonic() + max(900, config["max_turns"] * config["turn_timeout_seconds"] + 180)
        while not (run_dir / "results.json").exists():
            if server.poll() is not None or (run_dir / "failure.json").exists():
                raise RuntimeError("episode failed; inspect the server output and failure artifact")
            if time.monotonic() > deadline:
                raise RuntimeError("episode exceeded the local deadline")
            time.sleep(0.1)
        print((run_dir / "results.json").read_text(), flush=True)
        for player in processes[1:]:
            if player.wait(timeout=5) != 0:
                raise RuntimeError("a bundled player failed")
        if args.keep_open or args.human:
            print(f"Replay: {base}/client/replay (Ctrl+C to stop)", flush=True)
            while server.poll() is None:
                time.sleep(1)
    except KeyboardInterrupt:
        pass
    finally:
        for process in reversed(processes):
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


if __name__ == "__main__":
    main()
