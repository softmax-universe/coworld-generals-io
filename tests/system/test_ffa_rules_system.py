"""Real FFA sessions protect survival credit, surrender capture windows and long replays."""

import json
import os
from collections import deque
from contextlib import ExitStack, contextmanager

import pytest

if os.environ.get("GENERALS_BROWSER_TESTS") != "1":
    pytest.skip("requires the real browser suite", allow_module_level=True)

from fastapi.testclient import TestClient
from playwright.sync_api import expect

from integrations.softmax.config import GameConfig
from integrations.softmax.protocol import PASS
from integrations.softmax.replay import replay_frame
from integrations.softmax.server import create_app

DIRECTIONS = [(-1, 0), (1, 0), (0, -1), (0, 1)]


@contextmanager
def four_players(tmp_path, max_turns, engine="jax", seed=7):
    config = GameConfig(tokens=[f"seat-{slot}" for slot in range(4)],
                        players=[{"name": f"Player {slot}"} for slot in range(4)],
                        seed=seed, max_turns=max_turns, turn_timeout_seconds=1)
    destinations = {key: (tmp_path / f"{key}.json").as_uri() for key in ("results", "replay", "failure")}
    with TestClient(create_app(config, destinations, engine=engine)) as client, ExitStack() as stack:
        sockets = [stack.enter_context(client.websocket_connect(f"/player?slot={slot}&token=seat-{slot}"))
                   for slot in range(4)]
        yield client, sockets


def receive(ws):
    message = ws.receive_json()
    while message["type"] not in ("observation", "final"):
        message = ws.receive_json()
    return message


def route(observation, source, target):
    queue = deque([(source, [])])
    seen = {source}
    while queue:
        cell, path = queue.popleft()
        if cell == target:
            return path
        for direction, (dr, dc) in enumerate(DIRECTIONS):
            nxt = cell[0] + dr, cell[1] + dc
            r, c = nxt
            if (0 <= r < observation["height"] and 0 <= c < observation["width"] and nxt not in seen
                    and (nxt == target or observation["type_grid"][r][c] not in (2, 3, 4, 5))):
                seen.add(nxt)
                queue.append((nxt, path + [direction]))
    return []


def expand(observation):
    """A scripted player claims eleven empty plains, then stops moving."""
    if observation["my_land"] >= 11:
        return PASS
    own = [(r, c) for r, row in enumerate(observation["owner_grid"]) for c, value in enumerate(row) if value == 1]
    for source in sorted(own, key=lambda cell: observation["army_grid"][cell[0]][cell[1]], reverse=True):
        if observation["army_grid"][source[0]][source[1]] <= 1:
            continue
        for cell in own:
            for dr, dc in DIRECTIONS:
                r, c = cell[0] + dr, cell[1] + dc
                if (0 <= r < observation["height"] and 0 <= c < observation["width"]
                        and observation["type_grid"][r][c] == 1 and observation["owner_grid"][r][c] == 0
                        and observation["army_grid"][r][c] == 0):
                    path = route(observation, source, (r, c))
                    if path:
                        return [0, *source, path[0], 0]
    return PASS


@pytest.mark.parametrize("engine", ["jax", "polyworld"])
def test_idle_ffa_runs_past_old_cap_and_saved_replay_seeks_without_full_boards(tmp_path, viewer, engine):
    observation_at_512 = None
    with four_players(tmp_path, 6000, engine=engine) as (client, sockets):
        while True:
            observations = [receive(ws) for ws in sockets]
            if observations[0]["type"] == "final":
                result = observations[0]["result"]
                break
            if observations[0]["turn"] == 512:
                observation_at_512 = observations[0]
            for ws, observation in zip(sockets, observations):
                if not observation["eliminated"]:
                    ws.send_json({"type": "action", "turn": observation["turn"], "action": expand(observation)})
        recording = client.get("/replay.json").json()
    assert result["reason"] == "idle_limit" and 2000 < result["turns"] < 6000
    assert result["timeouts"] == [0] * 4
    assert result["scores"][result["winner"]] == 1 and sorted(result["placements"]) == [1, 2, 3, 4]
    assert (tmp_path / "replay.json").stat().st_size < 2_000_000
    assert observation_at_512 is not None
    general = next((r, c) for r, row in enumerate(observation_at_512["type_grid"]) for c, kind in enumerate(row)
                   if kind == 4 and observation_at_512["owner_grid"][r][c] == 1)
    page, base, bundle = viewer
    (bundle / "replay.json").write_text(json.dumps(recording))
    page.goto(f"{base}/#replay=replay.json")
    expect(page.locator("#mode")).to_have_text("REPLAY")
    page.locator("#perspective").select_option("0")
    page.locator("#seek").fill("512")
    tile = page.locator("#board .tile").nth(general[0] * recording["width"] + general[1])
    expect(tile).to_contain_text(str(observation_at_512["army_grid"][general[0]][general[1]]))
    page.locator("#seek").fill(str(len(recording["frames"]) - 1))
    expect(page.locator("#turn")).to_have_text(str(result["turns"] // 2) + ('.' if result["turns"] % 2 else ''))
    page.locator("#seek").fill("512")
    expect(tile).to_contain_text(str(observation_at_512["army_grid"][general[0]][general[1]]))


@pytest.mark.parametrize("engine,seed,viewer", [("jax", 7, "jax"), ("polyworld", 7, "polyworld")], indirect=["viewer"])
def test_surrendered_general_stays_capturable_and_killer_outranks_later_non_killer(tmp_path, engine, seed, viewer, native_controls):
    # Seed 7 permits capture before neutralization with both JAX and SplitMix64 maps.
    with four_players(tmp_path, 400, engine=engine, seed=seed) as (client, sockets):
        generals = []
        attacker = victim = -1
        position = None
        previous = PASS
        capture_tick = None
        surrendered = set()
        while True:
            observations = [receive(ws) for ws in sockets]
            if observations[0]["type"] == "final":
                result = observations[0]["result"]
                break
            tick = observations[0]["turn"]
            if tick == 0:
                generals = [next((r, c) for r, row in enumerate(o["type_grid"]) for c, kind in enumerate(row)
                                 if kind == 4 and o["owner_grid"][r][c] == 1) for o in observations]
                attacker, victim = min(((a, v) for a in range(4) for v in range(4) if a != v),
                                       key=lambda pair: sum(abs(x - y) for x, y in zip(generals[pair[0]], generals[pair[1]])))
                position = generals[attacker]
            if tick == 151:
                position = generals[attacker]
            attacking = observations[attacker]
            if previous[0] == 0 and attacking["last_move_executed"]:
                dr, dc = DIRECTIONS[previous[3]]
                position = previous[1] + dr, previous[2] + dc
            if attacking["public_scores"]["has_kill"][attacker] and capture_tick is None:
                capture_tick = tick
            for slot, (ws, observation) in enumerate(zip(sockets, observations)):
                if observation["eliminated"]:
                    continue
                if (slot == victim and tick == 151) or (slot == attacker and capture_tick is not None):
                    if slot not in surrendered:
                        ws.send_json({"type": "surrender"})
                        surrendered.add(slot)
                    continue
                action = expand(observation) if tick < 150 else PASS
                if slot == victim and tick == 150:
                    r, c = generals[victim]
                    direction = next(d for d, (dr, dc) in enumerate(DIRECTIONS)
                                     if 0 <= r + dr < observation["height"] and 0 <= c + dc < observation["width"]
                                     and observation["owner_grid"][r + dr][c + dc] == 1)
                    action = [0, r, c, direction, 0]
                elif slot == attacker and tick >= 151 and capture_tick is None:
                    path = route(observation, position, generals[victim])
                    assert path, "generated FFA map must permit the capture route"
                    action = [0, *position, path[0], 0]
                if slot == attacker:
                    previous = action
                ws.send_json({"type": "action", "turn": tick, "action": action})
        recording = client.get("/replay.json").json()
    assert capture_tick is not None and 151 < capture_tick < 201
    assert result["captured_by"][victim] == attacker and result["kills"][attacker] == 1
    assert result["elimination_order"][:2] == [victim, attacker]
    assert result["placements"][attacker] == 2
    assert result["placements"][victim] == 4
    assert result["timeouts"] == [0] * 4
    r, c = generals[victim]
    window = replay_frame(recording["frames"], 152)
    assert window["owner_grid"][r][c] == victim + 1 and window["type_grid"][r][c] == 4
    captured = replay_frame(recording["frames"], capture_tick)
    assert captured["owner_grid"][r][c] == attacker + 1 and captured["type_grid"][r][c] == 3

    r, c = generals[attacker]
    before_neutral = replay_frame(recording["frames"], capture_tick + 49)
    neutral = replay_frame(recording["frames"], capture_tick + 50)
    after_neutral = replay_frame(recording["frames"], capture_tick + 52)
    assert before_neutral["owner_grid"][r][c] == attacker + 1 and before_neutral["type_grid"][r][c] == 4
    assert neutral["owner_grid"][r][c] == 0 and neutral["type_grid"][r][c] == 3
    assert after_neutral["army_grid"][r][c] == neutral["army_grid"][r][c]
    if engine == "polyworld":
        key, click = native_controls

        page, base, bundle = viewer
        page.set_viewport_size({"width": 1280, "height": 900})
        (bundle / "surrender.json").write_bytes((tmp_path / "replay.json").read_bytes())
        page.goto(base + "/#replay=surrender.json")
        page.wait_for_function("() => failed || Module.replayTick >= 1", timeout=60000)
        assert not page.evaluate("failed"), page.locator("#status-detail").inner_text()
        click(page, page, 420, 860)
        page.wait_for_function("() => !Module.replayRepeating")
        key(page, page, "End")
        page.wait_for_function(f"() => failed || Module.replayTick === {result['turns']}")
        assert not page.evaluate("failed"), page.locator("#status-detail").inner_text()
        page.screenshot(path=str(tmp_path / "native-surrender50tick.png"))
