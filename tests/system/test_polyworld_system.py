"""Public hosted sessions protect construction, fog, receipts and replay persistence."""

import json
import os
from contextlib import ExitStack

import pytest
from fastapi.testclient import TestClient

from competition.agents.expander_python.agent import Agent
from integrations.softmax.builder_player import choose_action
from integrations.softmax.config import GameConfig
from integrations.softmax.protocol import PASS
from integrations.softmax.replay import replay_frame
from integrations.softmax.server import create_app


def test_runner_seeds_reproduce_full_width_maps_and_binary_replays(tmp_path, monkeypatch, inspect_native_replay):
    """Runner JSON, native generation and saved replays preserve all seed bits."""
    if "GENERALS_POLYWORLD_ENGINE" not in os.environ:
        pytest.skip("Compile polyworld_bridge.nim and set GENERALS_POLYWORLD_ENGINE")
    seeds = [0, 7, (1 << 31) | 7, (1 << 32) | 7,
             (1 << 53) | 7, (1 << 63) | 7, (1 << 64) - 1]
    maps = []
    for seed in seeds:
        recordings = []
        boards = []
        for repetition in range(2):
            directory = tmp_path / f"{seed}-{repetition}"
            directory.mkdir()
            tokens = ["red", "blue", "green", "purple"]
            config = {
                "tokens": tokens,
                "players": [{"name": token} for token in tokens],
                "seed": seed,
                "max_turns": 4,
                "turn_timeout_seconds": 1,
            }
            config_path = directory / "config.json"
            config_path.write_text(json.dumps(config))
            monkeypatch.setenv("COGAME_CONFIG_URI", config_path.as_uri())
            artifacts = {key: (directory / f"{key}.json").as_uri()
                         for key in ("results", "replay", "failure")}
            with TestClient(create_app(artifacts=artifacts, engine="polyworld")) as client, ExitStack() as stack:
                sockets = [stack.enter_context(client.websocket_connect(f"/player?slot={slot}&token={token}"))
                           for slot, token in enumerate(tokens)]
                for ws in sockets:
                    assert ws.receive_json()["type"] == "hello"
                for turn in range(config["max_turns"]):
                    for ws in sockets:
                        observation = ws.receive_json()
                        assert observation["turn"] == turn
                        ws.send_json({"type": "action", "turn": turn, "action": PASS})
                result = sockets[0].receive_json()["result"]
                assert result["turns"] == 4 and result["timeouts"] == [0] * 4
                diagnostic = client.get("/replay.json").json()
                assert diagnostic["seed"] == seed
                boards.append(replay_frame(diagnostic["frames"], 0))
                response = client.get("/client/replay.data")
                assert response.status_code == 200
                recordings.append(response.content)
            path = directory / "replay.json"
            assert recordings[-1] == path.read_bytes()
            inspected = inspect_native_replay(path)
            assert inspected["seed"] == str(seed)
            assert inspected["game_version"] == 2 and inspected["turns"] == 4
            assert not (directory / "failure.json").exists()
        assert boards[0] == boards[1], f"seed {seed} generated different maps"
        assert recordings[0] == recordings[1], f"seed {seed} generated different recordings"
        maps.append(boards[0])
    fingerprints = {json.dumps(board, sort_keys=True) for board in maps}
    assert len(fingerprints) == len(seeds), "upper seed bits must affect the map"


@pytest.mark.parametrize("seed", [-1, 1 << 64])
def test_runner_rejects_seeds_outside_unsigned_64_bits(tmp_path, monkeypatch, seed):
    """Reject invalid runner input before starting the authoritative engine."""
    path = tmp_path / "config.json"
    path.write_text(json.dumps({"tokens": ["red", "blue"],
                                "players": [{"name": "Red"}, {"name": "Blue"}],
                                "seed": seed}))
    monkeypatch.setenv("COGAME_CONFIG_URI", path.as_uri())
    with pytest.raises(RuntimeError, match="cannot load game config.*ValidationError"):
        with TestClient(create_app(engine="polyworld")):
            pytest.fail("invalid seed started a game")


def test_polyworld_builders_finish_and_replay_their_constructed_castles(tmp_path, inspect_native_replay):
    if "GENERALS_POLYWORLD_ENGINE" not in os.environ:
        pytest.skip("Compile polyworld_bridge.nim and set GENERALS_POLYWORLD_ENGINE")
    config = GameConfig(tokens=["red", "blue"], players=[{"name": "Red"}, {"name": "Blue"}],
                        seed=7, ruleset="build_castles", max_turns=140, turn_timeout_seconds=1)
    artifacts = {key: (tmp_path / f"{key}.json").as_uri() for key in ("results", "replay", "failure")}
    built = []
    with TestClient(create_app(config, artifacts, engine="polyworld")) as client, ExitStack() as stack:
        sockets = [stack.enter_context(client.websocket_connect(f"/player?slot={s}&token={token}"))
                   for s, token in enumerate(config.tokens)]
        hello = [ws.receive_json() for ws in sockets]
        agents = [Agent(s, h["height"], h["width"]) for s, h in enumerate(hello)]
        previous = [PASS, PASS]
        for turn in range(config.max_turns):
            for slot, ws in enumerate(sockets):
                observation = ws.receive_json()
                assert observation["turn"] == turn
                assert any(0 in row for row in observation["type_grid"]), "opposing maps must stay hidden"
                if observation["last_build_executed"]:
                    built.append((turn, slot, previous[slot][1], previous[slot][2]))
                action = choose_action(observation, agents[slot])
                ws.send_json({"type": "action", "turn": turn, "action": action})
                previous[slot] = action
        result = sockets[0].receive_json()["result"]
        assert result["turns"] == 140 and result["timeouts"] == [0, 0]
        replay = client.get("/replay.json").json()
    assert len({slot for _, slot, _, _ in built}) == 2
    saved = inspect_native_replay(tmp_path / "replay.json")
    assert saved["format"] == "POLYWORLDREPLAY" and saved["game"] == "generals_hosted"
    assert saved["turns"] == 140 and saved["actions"] > 0
    assert replay["engine"] == "polyworld"
    for turn, slot, row, col in built:
        frame = replay_frame(replay["frames"], turn)
        assert frame["type_grid"][row][col] == 3 and frame["owner_grid"][row][col] == slot + 1
    assert not (tmp_path / "failure.json").exists()


def test_polyworld_final_surrenders_persist_one_terminal_tick(tmp_path, inspect_native_replay):
    if "GENERALS_POLYWORLD_ENGINE" not in os.environ:
        pytest.skip("Compile polyworld_bridge.nim and set GENERALS_POLYWORLD_ENGINE")
    config = GameConfig(tokens=["red", "blue", "green"],
                        players=[{"name": name} for name in ("Red", "Blue", "Green")],
                        seed=1, max_turns=10, turn_timeout_seconds=1)
    artifacts = {key: (tmp_path / f"{key}.json").as_uri() for key in ("results", "replay", "failure")}
    with TestClient(create_app(config, artifacts, engine="polyworld")) as client, ExitStack() as stack:
        sockets = [stack.enter_context(client.websocket_connect(f"/player?slot={s}&token={token}"))
                   for s, token in enumerate(config.tokens)]
        for ws in sockets:
            assert ws.receive_json()["type"] == "hello"
            assert ws.receive_json()["turn"] == 0
        sockets[0].send_json({"type": "surrender"})
        sockets[1].send_json({"type": "surrender"})
        sockets[2].send_json({"type": "action", "turn": 0, "action": PASS})
        result = sockets[2].receive_json()["result"]
        replay = client.get("/replay.json").json()
    assert result["winner"] == 2 and result["turns"] == 1
    assert inspect_native_replay(tmp_path / "replay.json")["turns"] == 1
    assert result == json.loads((tmp_path / "results.json").read_text())
    assert [replay_frame(replay["frames"], i)["turn"] for i in range(2)] == [0, 1]


@pytest.mark.parametrize("viewer", ["polyworld"], indirect=True)
@pytest.mark.parametrize("variant,count,turns,seed", [
    ("ffa", 8, 80, (1 << 64) - 1),
    ("castles", 2, 140, (1 << 63) | 7),
    ("ffa", 4, 80, (1 << 53) | 7),
])
@pytest.mark.skipif(
    os.environ.get("GENERALS_BROWSER_TESTS") != "1" or
    "GENERALS_POLYWORLD_ENGINE" not in os.environ or "GENERALS_POLYWORLD_VIEWER" not in os.environ,
    reason="requires the compiled Polyworld engine/viewer and the real browser suite",
)
def test_polyworld_tapes_verify_seek_and_reject_divergence(tmp_path, viewer, variant, count, turns, seed, native_controls, inspect_native_replay):
    """A shipped replay must reproduce hosted rules in the actual WASM viewer."""
    import gzip
    import socket
    import subprocess
    import sys
    from pathlib import Path
    from urllib.parse import urlencode

    key, click = native_controls

    page, base, bundle = viewer
    page.set_viewport_size({"width": 1280, "height": 900})
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    root = Path(__file__).resolve().parents[2]
    subprocess.run(
        [sys.executable, "-m", "integrations.softmax.local", "--variant", variant,
         *(["--players", str(count)] if variant == "ffa" else []), "--seed", str(seed), "--max-turns", str(turns),
         "--port", str(port), "--output", str(tmp_path / "episodes")],
        cwd=root, check=True, capture_output=True, text=True, timeout=180,
    )
    recording = next((tmp_path / "episodes").glob("episode-*/game.replay"))
    tape = inspect_native_replay(recording)
    assert tape["format"] == "POLYWORLDREPLAY"
    assert tape["seed"] == str(seed) and tape["game_version"] == 2
    assert json.loads((recording.parent / "results.json").read_text())["timeouts"] == [0] * count
    (bundle / "replay.gz").write_bytes(gzip.compress(recording.read_bytes()))
    scores = [-2.34, *([27.38] * (count - 2)), None]
    ratings = {"league": "Fixture standings", "label": "MMR",
               "players": [{"slot": slot, "score": score} for slot, score in enumerate(scores)]}
    page.goto(base + "/#" + urlencode({"replay": "replay.gz", "player_ratings": json.dumps(ratings)}))
    page.wait_for_function("() => failed || typeof Module.replayTick === 'number'", timeout=60000)
    assert not page.evaluate("failed"), page.locator("#status-detail").inner_text()
    assert page.evaluate("Module.replaySkillScores") == ["—" if score is None else f"{score:.1f}" for score in scores]
    assert "Result:" not in page.evaluate("Module.replayMessages"), "opening the replay must not spoil its outcome"
    page.wait_for_function("() => failed || Module.replayTick >= 1", timeout=60000)
    assert not page.evaluate("failed"), page.locator("#status-detail").inner_text()
    click(page, page, 200, 200)
    click(page, page, 420, 860)
    page.wait_for_function("() => !Module.replayRepeating")
    key(page, page, "End")
    page.wait_for_function(f"() => failed || Module.replayTick === {tape['turns']}")
    assert not page.evaluate("failed"), page.locator("#status-detail").inner_text()
    assert "Result:" in page.evaluate("Module.replayMessages")
    page.screenshot(path=str(tmp_path / f"native-{variant}-desktop.png"))
    page.set_viewport_size({"width": 390, "height": 844})
    page.wait_for_function("() => Module.canvas.width === 390 && Module.canvas.height === 844")
    page.screenshot(path=str(tmp_path / f"native-{variant}-mobile.png"))
    # Portrait controls must remain visible and usable after the panels reflow.
    scale = 390 / 520
    controls_y = 844 - (184 - 40) * scale
    click(page, page, 44 * scale, controls_y)
    page.wait_for_function(f"() => Module.replayPlaying && Module.replayTick > 0 && Module.replayTick < {turns}")
    click(page, page, 188 * scale, controls_y)
    page.wait_for_function("() => !Module.replayPlaying")
    paused_tick = page.evaluate("Module.replayTick")
    click(page, page, 188 * scale, controls_y)
    page.wait_for_function("tick => Module.replayTick > tick", arg=paused_tick)
    click(page, page, 188 * scale, controls_y)
    page.wait_for_function("() => !Module.replayPlaying")
    key(page, page, "Home")
    click(page, page, 260 * scale, controls_y)
    page.wait_for_function("() => Module.replayTick === 1")
    assert not page.evaluate("failed")
    assert "Result:" not in page.evaluate("Module.replayMessages"), "rewinding must hide the final result again"
    divergent = bytearray(recording.read_bytes())
    position = divergent.index(bytes.fromhex(tape["first_hash"])[::-1])
    divergent[position] ^= 1
    (bundle / "divergent.replay").write_bytes(divergent)
    page.goto(base + "/?divergent=1#replay=divergent.replay")
    page.wait_for_function("() => failed", timeout=60000)
    assert "diverged" in page.locator("#status-detail").inner_text()


@pytest.mark.skipif(
    os.environ.get("GENERALS_BROWSER_TESTS") != "1" or "GENERALS_POLYWORLD_VIEWER" not in os.environ,
    reason="requires the compiled Polyworld engine/viewer and the real browser suite",
)
def test_human_ffa_uses_polyworld_for_live_orders_and_completed_replay(tmp_path, inspect_native_replay):
    """A human must move and chat through Silky without exposing the full live map."""
    import shutil
    import socket
    import subprocess
    import sys
    from pathlib import Path

    import httpx
    from playwright.sync_api import sync_playwright

    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    root = Path(__file__).resolve().parents[2]
    config = {
        "tokens": [f"system-seat-{slot}" for slot in range(8)],
        "players": [{"name": f"Seat {slot}"} for slot in range(8)],
        "player_ratings": {"league": "System FFA", "label": "MMR", "players": [
            {"slot": slot, "score": None if slot == 0 else 60.28 - slot} for slot in range(8)]},
        "seed": 7, "max_turns": 48, "tick_interval_seconds": 0.5, "turn_timeout_seconds": 1,
    }
    (tmp_path / "config.json").write_text(json.dumps(config))
    env = {**os.environ, "GENERALS_ENGINE": "polyworld", "GENERALS_KEEP_OPEN": "1",
           "COGAME_HOST": "127.0.0.1", "COGAME_PORT": str(port),
           "COGAME_CONFIG_URI": (tmp_path / "config.json").as_uri(),
           "COGAME_RESULTS_URI": (tmp_path / "results.json").as_uri(),
           "COGAME_SAVE_REPLAY_URI": (tmp_path / "game.replay").as_uri(),
           "COGAME_PLAYER_FAILURE_URI": (tmp_path / "failure.json").as_uri()}
    processes = []
    with ExitStack() as stack:
        log = stack.enter_context((tmp_path / "server.log").open("w"))
        server = subprocess.Popen([sys.executable, "-m", "integrations.softmax.server"],
                                  cwd=root, env=env, stdout=log, stderr=log)
        processes.append(server)
        try:
            with httpx.Client(transport=httpx.HTTPTransport(retries=8), timeout=2) as client:
                assert client.get(f"http://127.0.0.1:{port}/healthz").is_success
            with sync_playwright() as p:
                browser = p.chromium.launch(executable_path=os.environ.get("CHROMIUM_PATH") or shutil.which("chromium"))
                page = browser.new_page(viewport={"width": 1440, "height": 1000})
                errors, observations, actions = [], [], []
                page.on("pageerror", lambda error: errors.append(str(error)))

                def socket_opened(ws):
                    def received(raw):
                        message = json.loads(raw)
                        if message["type"] == "observation":
                            observations.append(message)
                    ws.on("framereceived", received)
                    ws.on("framesent", lambda raw: actions.append(json.loads(raw)))

                page.on("websocket", socket_opened)
                page.goto(f"http://127.0.0.1:{port}/client/player?slot=0&token=system-seat-0")
                frame = page.frame_locator("#polyworld-player")
                page.wait_for_function("typeof document.querySelector('#polyworld-player')?.contentWindow.Module?.polyworldLiveUpdate === 'function'")
                bots = []
                for slot in range(1, 8):
                    bot = subprocess.Popen([sys.executable, "-m", "integrations.softmax.player"], cwd=root,
                                           env={**env, "COWORLD_PLAYER_WS_URL":
                                                f"ws://127.0.0.1:{port}/player?slot={slot}&token=system-seat-{slot}"},
                                           stdout=log, stderr=log)
                    bots.append(bot)
                    processes.append(bot)
                page.wait_for_function("document.querySelector('#polyworld-player').contentWindow.Module.liveTick >= 2")
                native = page.locator("#polyworld-player").element_handle().content_frame()
                assert native.evaluate("Module.liveSkillScores") == ["—", "59.3", "58.3", "57.3", "56.3", "55.3", "54.3", "53.3"]
                assert any(kind == 0 for row in observations[-1]["type_grid"] for kind in row)
                assert httpx.get(f"http://127.0.0.1:{port}/client/replay.data").status_code != 200
                frame.locator("#canvas").click(position={"x": 10, "y": 50})

                def key(button):
                    before = native.evaluate("Module.liveFrameCount")
                    page.keyboard.down(button)
                    native.wait_for_function("before => Module.liveFrameCount >= before + 2", arg=before)
                    page.keyboard.up(button)
                    before = native.evaluate("Module.liveFrameCount")
                    native.wait_for_function("before => Module.liveFrameCount >= before + 2", arg=before)

                key("g")
                obs = observations[-1]
                r, c = next((r, c) for r, row in enumerate(obs["type_grid"]) for c, kind in enumerate(row)
                            if kind == 4 and obs["visible_owner_grid"][r][c] == 1)
                direction = next(button for dr, dc, button in [(-1, 0, "ArrowUp"), (1, 0, "ArrowDown"),
                                                              (0, -1, "ArrowLeft"), (0, 1, "ArrowRight")]
                                 if 0 <= r + dr < obs["height"] and 0 <= c + dc < obs["width"]
                                 and obs["type_grid"][r + dr][c + dc] == 1)
                key(direction)
                page.wait_for_function("Number(document.getElementById('land0').textContent) > 1")
                assert any(action["type"] == "action" and action["action"][0] == 0 for action in actions)
                assert any(obs["last_move_executed"] for obs in observations)
                key("Enter")
                page.keyboard.type("Human live WASM", delay=30)
                key("Enter")
                page.wait_for_function("document.getElementById('chat-messages').textContent.includes('Human live WASM')")
                page.screenshot(path=str(tmp_path / "polyworld-live-desktop.png"))
                page.set_viewport_size({"width": 390, "height": 844})
                native.wait_for_function("Module.canvas.width === 390 && Module.canvas.height === 844")
                page.screenshot(path=str(tmp_path / "polyworld-live-phone.png"))
                page.context.set_offline(True)
                page.wait_for_function("document.getElementById('mode').textContent === 'RECONNECTING'")
                page.context.set_offline(False)
                page.wait_for_function("document.getElementById('mode').textContent === 'PLAYER'")
                # FFA disconnects eliminate the seat. Rejoining must show the live
                # full board while the other seven seats continue playing.
                native.wait_for_function("""() => {
                  const state = JSON.parse(Module.pendingLiveSnapshot);
                  return !state.alive[0] && state.types.flat().every(kind => kind >= 1 && kind <= 4);
                }""")
                before_chat = len([action for action in actions if action["type"] == "chat"])
                key("Enter")
                page.keyboard.type("Eliminated spectator", delay=20)
                key("Enter")
                assert len([action for action in actions if action["type"] == "chat"]) == before_chat
                page.screenshot(path=str(tmp_path / "polyworld-eliminated-spectator.png"))
                page.wait_for_function("document.getElementById('polyworld-replay').style.display === 'block'", timeout=45000)
                replay = page.locator("#polyworld-replay").element_handle().content_frame()
                replay.wait_for_function("typeof Module.replayTick === 'number'", timeout=60000)
                assert replay.evaluate("Module.replaySkillScores") == native.evaluate("Module.liveSkillScores")
                assert all(bot.wait(timeout=10) == 0 for bot in bots)
                result = json.loads((tmp_path / "results.json").read_text())
                assert result["turns"] == 48 and result["timeouts"][1:] == [0] * 7
                assert inspect_native_replay(tmp_path / "game.replay")["turns"] == 48
                with page.expect_download() as downloaded:
                    replay.locator("#download-replay").click()
                assert Path(downloaded.value.path()).read_bytes() == (tmp_path / "game.replay").read_bytes()
                assert not errors
                browser.close()
        finally:
            for process in reversed(processes):
                if process.poll() is None:
                    process.terminate()
                process.wait(timeout=10)
    assert not (tmp_path / "failure.json").exists()
    assert not any(token in (tmp_path / "server.log").read_text() for token in config["tokens"])


def test_eliminated_seat_spectates_full_board_without_chat_or_orders(tmp_path):
    """Elimination grants authenticated spectating, without leaking fog to active seats."""
    if "GENERALS_POLYWORLD_ENGINE" not in os.environ:
        pytest.skip("Compile polyworld_bridge.nim and set GENERALS_POLYWORLD_ENGINE")
    config = GameConfig(tokens=["spectator", "red", "blue"],
                        players=[{"name": name} for name in ("Human", "Red", "Blue")],
                        seed=7, max_turns=4, turn_timeout_seconds=1)
    artifacts = {key: (tmp_path / f"{key}.json").as_uri() for key in ("results", "replay", "failure")}
    viewed = []
    with TestClient(create_app(config, artifacts, engine="polyworld")) as client, ExitStack() as stack:
        sockets = [stack.enter_context(client.websocket_connect(f"/player?slot={s}&token={token}"))
                   for s, token in enumerate(config.tokens)]
        public = stack.enter_context(client.websocket_connect("/global"))
        for ws in sockets:
            assert ws.receive_json()["type"] == "hello"
            assert any(kind == 0 for row in ws.receive_json()["type_grid"] for kind in row)
        sockets[0].send_json({"type": "surrender"})
        for ws in sockets[1:]:
            ws.send_json({"type": "action", "turn": 0, "action": PASS})
        for turn in range(1, 4):
            spectator = sockets[0].receive_json()
            assert spectator["turn"] == turn and spectator["eliminated"]
            assert all(kind in (1, 2, 3, 4) for row in spectator["type_grid"] for kind in row)
            assert "PRIVATE_TO_BLUE" not in json.dumps(spectator)
            viewed.append(spectator)
            active = [ws.receive_json() for ws in sockets[1:]]
            assert all(any(kind == 0 for row in obs["type_grid"] for kind in row) for obs in active)
            if turn == 1:
                for rejected in [
                    {"type": "chat", "target": -2, "text": "ELIMINATED_PUBLIC"},
                    {"type": "chat", "target": 1, "text": "ELIMINATED_PRIVATE"},
                    {"type": "action", "turn": turn, "action": PASS},
                ]:
                    sockets[0].send_json(rejected)
                    error = sockets[0].receive_json()
                    assert error["type"] == "error" and error["message"] == "eliminated players cannot act"
                sockets[1].send_json({"type": "chat", "target": 2, "text": "PRIVATE_TO_BLUE"})
                assert client.get("/client/replay.data").status_code == 409
            for ws in sockets[1:]:
                ws.send_json({"type": "action", "turn": turn, "action": PASS})
        assert sockets[0].receive_json()["type"] == "final"
        replay = client.get("/replay.json").json()
        assert "ELIMINATED_" not in json.dumps(replay)
        assert "PRIVATE_TO_BLUE" not in json.dumps(replay)
        while True:
            update = public.receive_json()
            if update["phase"] == "finished":
                break
            assert update["board"] is None
    for observation in viewed:
        frame = replay_frame(replay["frames"], observation["turn"])
        assert observation["type_grid"] == frame["type_grid"]
        assert observation["visible_owner_grid"] == frame["owner_grid"]
        assert observation["army_grid"] == frame["army_grid"]
    assert not (tmp_path / "failure.json").exists()
