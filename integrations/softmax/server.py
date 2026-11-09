"""Authoritative, bounded Generals Coworld HTTP/WebSocket server."""

import asyncio
import base64
import gzip
import hmac
import json
import logging
import os
import secrets
from contextlib import asynccontextmanager, suppress
from pathlib import Path
from typing import TYPE_CHECKING, Literal
from urllib.parse import parse_qs, urlsplit

import uvicorn
from anyio import CancelScope
from fastapi import FastAPI, HTTPException, WebSocket
from fastapi.responses import HTMLResponse, JSONResponse, Response
from fastapi.staticfiles import StaticFiles

from .artifacts import read_json, write_bytes, write_json
from .config import GameConfig
from .file_players import PolicyFault, load_file_players
from .messages import ChatMessage, MailboxRead, MessageCommand, PolicyMessages
from .protocol import PASS, VERSION, parse_action
from .replay import REPLAY_VERSION, ReplayFrames

if TYPE_CHECKING:
    from .engine import Match
    from .polyworld_engine import Match as PolyworldMatch

STATIC = Path(__file__).parent / "static"
POLYWORLD_VIEWER = Path(os.environ.get("GENERALS_POLYWORLD_VIEWER", "/app/polyworld-viewer"))
LOG = logging.getLogger("generals.softmax")


def enqueue(queue: asyncio.Queue, message: dict):
    # Slow viewers/players must never block the authoritative clock.
    if queue.full():
        queue.get_nowait()
    queue.put_nowait(message)


class Episode:
    def __init__(self, config: GameConfig, match: "Match | PolyworldMatch", artifacts: dict, shutdown=None):
        self.config, self.match = config, match
        self.artifacts, self.shutdown = artifacts, shutdown
        self.names = [p.name for p in config.players]
        self.num_players = len(self.names)
        self.player_ratings = (config.player_ratings.model_dump(mode="json")
                               if config.player_ratings is not None else None)
        self.skill_scores = [None] * self.num_players
        if config.player_ratings is not None:
            for player in config.player_ratings.players:
                self.skill_scores[player.slot] = player.score
        self.phase = "waiting"
        self.players: dict[int, asyncio.Queue] = {}
        self.reserved_slots: set[int] = set()
        self.viewers: set[asyncio.Queue] = set()
        self.senders: set[asyncio.Task[None]] = set()
        self.joined = asyncio.Event()
        self.actions_ready = asyncio.Event()
        self.pending: dict[int, list[int]] = {}
        self.timeouts = [0] * self.num_players
        self.consecutive_timeouts = [0] * self.num_players
        self.frames = ReplayFrames(match.frame())
        if match.engine_name == "polyworld":
            match.record_frame()
        self.surrenders: set[int] = set()
        self.turns = []
        self.result = None
        self.replay = None
        self.failed = False
        self.file_players = load_file_players(self.num_players)
        self.file_slots = set(self.file_players.files) if self.file_players else set()
        self.messages = PolicyMessages(self.names)

    def authorize(self, slot: str | None, token: str | None) -> int | None:
        if slot not in tuple(str(s) for s in range(self.num_players)) or token is None:
            return None
        index = int(slot)
        if index in self.file_slots:
            return None
        return index if hmac.compare_digest(token.encode(), self.config.tokens[index].encode()) else None

    def public(self):
        # This route is reachable by competing players too. Never include live
        # tiles, config, tokens, seed, pending actions, or per-player observations.
        frame = self.frames[-1]
        return {
            "type": "global",
            "protocol_version": VERSION,
            "phase": self.phase,
            "turn": frame["turn"],
            "max_turns": self.config.max_turns,
            "players": self.names,
            "player_ratings": self.player_ratings,
            "ruleset": self.config.ruleset,
            "army": frame["army"],
            "land": frame["land"],
            "has_kill": [count > 0 for count in frame["kills"]],
            "neutralize_in": frame["neutralize_in"],
            "eliminated": frame["eliminated"],
            "result": self.result,
            "board": frame if self.phase == "finished" else None,
            "chats": [chat.model_dump() for chat in self.messages.recent_chats],
            "events": [event.model_dump() for event in self.messages.events],
        }

    def publish(self):
        public = self.public()
        for queue in self.viewers:
            enqueue(queue, public)

    @property
    def turn_timeout(self) -> float:
        # The official pre-game input window also lets stdio players initialize.
        return 1.5 if self.match.is_ffa and self.match.turn == 0 else self.config.turn_timeout_seconds

    def observation(self, slot):
        return self.decorate_observation(self.match.observation(slot))

    def decorate_observation(self, observation: dict):
        if observation["eliminated"]:
            frame = self.frames[-1]
            owner = observation["slot"] + 1
            observation = {
                **observation,
                "type_grid": frame["type_grid"],
                "owner_grid": [[0 if cell == 0 else 1 if cell == owner else 2 for cell in row]
                               for row in frame["owner_grid"]],
                "visible_owner_grid": frame["owner_grid"],
                "army_grid": frame["army_grid"],
            }
        return {
            **observation,
            "players": self.names,
            "player_ratings": self.player_ratings,
            "max_turns": self.config.max_turns,
            "turn_timeout_seconds": self.turn_timeout,
            "mailbox": self.messages.mailboxes[observation["slot"]].model_dump(),
            "chats": [chat.model_dump() for chat in self.messages.recent_chats],
            "events": [event.model_dump() for event in self.messages.events],
            "public_scores": {key: self.frames[-1][key]
                              for key in ("army", "land", "eliminated", "neutralize_in")}
                             | {"has_kill": [count > 0 for count in self.frames[-1]["kills"]]},
        }

    def accept(self, slot, message):
        if (self.match.is_ffa and message == {"type": "surrender"}
                and self.phase in ("playing", "resolving") and slot in self.match.active_slots):
            self.request_surrender(slot)
            return
        if self.phase not in ("playing", "resolving"):
            raise ValueError("game is not accepting commands")
        if slot not in self.match.active_slots:
            raise ValueError("eliminated players cannot act")
        match message:
            case {"type": "chat"}:
                chat = ChatMessage.model_validate(message)
                if not self.messages.command(MessageCommand(
                    op="queue", slot=slot, target=chat.target, text=chat.text,
                )).accepted:
                    raise ValueError("chat target, text, or per-turn limit rejected")
                return
            case {"type": "mailbox"}:
                request = MailboxRead.model_validate(message)
                self.messages.command(MessageCommand(op="consume", slot=slot, count=request.count))
                return
        if self.phase != "playing":
            raise ValueError("game is not accepting actions")
        action = parse_action(message, self.match.turn, self.match.height, self.match.width, self.config.ruleset)
        if slot in self.pending:
            raise ValueError("only the first valid action per turn is accepted")
        self.pending[slot] = action
        if all(s in self.pending for s in self.match.active_slots):
            self.actions_ready.set()

    def request_surrender(self, slot: int):
        self.surrenders.add(slot)
        if all(s in self.pending or s in self.surrenders for s in self.match.active_slots):
            self.actions_ready.set()

    async def save(self, name, payload):
        uri = self.artifacts.get(name)
        if not uri:
            raise RuntimeError(f"missing {name} artifact destination")
        method = self.artifacts.get(f"{name}_method", "PUT")
        await asyncio.to_thread(write_bytes if isinstance(payload, bytes) else write_json, uri, payload, method)

    async def run(self):
        try:
            await self.play()
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001 - process boundary; redact secret-bearing library errors
            # Config and presigned URLs can occur in library exception strings.
            LOG.error("episode failed (%s)", type(exc).__name__)
            self.failed = True
            self.phase = "failed"
            self.publish()
        finally:
            if self.file_players:
                await self.file_players.close()
            await asyncio.to_thread(self.messages.close)
            if self.phase in ("finished", "failed"):
                for slot, queue in self.players.items():
                    enqueue(queue, {"type": "final" if not self.failed else "failure", "result": self.result,
                        "mailbox": self.messages.mailboxes[slot].model_dump(),
                        "events": [event.model_dump() for event in self.messages.events]})
                if self.shutdown:
                    # Drain the final messages before retiring the live server.
                    await asyncio.gather(*self.senders, return_exceptions=True)
                    self.shutdown()

    async def play(self):
        if self.file_players:
            startup = await self.file_players.start()
            if isinstance(startup, PolicyFault):
                await self.fail_policy(startup)
                return
        try:
            async with asyncio.timeout(self.config.player_connect_timeout_seconds):
                while len(self.players) + len(self.file_slots) < self.num_players:
                    self.joined.clear()
                    await self.joined.wait()
        except TimeoutError:
            missing = next(
                slot for slot in range(self.num_players) if slot not in self.players and slot not in self.file_slots
            )
            await self.save(
                "failure",
                {"message": "Player did not connect before the start deadline", "failed_policy_index": missing},
            )
            self.failed = True
            self.phase = "failed"
            self.publish()
            return

        winner, reason = -1, "turn_limit"
        while self.match.turn < self.config.max_turns:
            active = self.match.active_slots
            observations = [self.decorate_observation(obs) for obs in
                            await asyncio.to_thread(self.match.observations)]
            self.pending.clear()
            self.actions_ready.clear()
            self.phase = "playing"
            started = asyncio.get_running_loop().time()
            if self.file_players:
                for slot in sorted(self.file_slots.intersection(active)):
                    reply = await self.file_players.act(slot, observations[slot])
                    if isinstance(reply, PolicyFault):
                        await self.fail_policy(reply)
                        return
                    self.messages.command(MessageCommand(op="consume", slot=slot, count=reply.mailbox_pulled))
                    if reply.chat is not None:
                        self.accept(slot, {"type": "chat", **reply.chat.model_dump()})
                    self.accept(slot, {"type": "action", "turn": self.match.turn, "action": reply.action})
            for slot, queue in self.players.items():
                enqueue(queue, observations[slot])
            self.publish()
            try:
                async with asyncio.timeout(self.turn_timeout):
                    await self.actions_ready.wait()
            except TimeoutError:
                pass
            self.phase = "resolving"
            actions = [self.pending.get(slot, PASS.copy()) for slot in range(self.num_players)]
            previous = self.frames[-1]
            missing = [slot in active and slot not in self.pending and slot not in self.surrenders
                       for slot in range(self.num_players)]
            for slot in active:
                self.timeouts[slot] += int(missing[slot])
                self.consecutive_timeouts[slot] = self.consecutive_timeouts[slot] + 1 if missing[slot] else 0
            forfeits = sorted(self.surrenders & set(active)) if self.match.is_ffa else [
                s for s in active if self.consecutive_timeouts[s] >= self.config.max_consecutive_timeouts
            ]
            self.surrenders.difference_update(forfeits)
            attempt = {"turn": self.match.turn, "actions": actions, "timed_out": missing,
                       "forfeited": forfeits, "applied": True}
            self.turns.append(attempt)
            if forfeits:
                winner = await asyncio.to_thread(self.match.forfeit, forfeits)
                if len(self.match.active_slots) <= 1 and not self.match.is_ffa:
                    attempt["applied"] = False
                    reason = "forfeit" if winner >= 0 else "double_forfeit"
                    # Forfeits can change ownership without advancing the tick.
                    self.frames.append(await asyncio.to_thread(self.match.frame))
                    self.messages.command(MessageCommand(op="flush", turn=self.match.turn))
                    if self.match.engine_name == "polyworld":
                        self.match.record_frame()
                    break
            winner = await asyncio.to_thread(self.match.advance, actions)
            if self.match.is_ffa and winner < 0 and self.match.turn >= self.config.max_turns:
                self.match.end_reason = "turn_limit"
                winner = self.match.adjudicate(self.match.frame())
            self.frames.append(await asyncio.to_thread(self.match.frame))
            self.messages.command(MessageCommand(op="flush", turn=self.match.turn))
            current = self.frames[-1]
            for victim in range(self.num_players):
                if (not previous["eliminated"][victim] and current["eliminated"][victim]
                        and victim not in forfeits):
                    captured = any(
                        kind == 4 and previous["owner_grid"][row][column] == victim + 1
                        and current["owner_grid"][row][column] != victim + 1
                        for row, kinds in enumerate(previous["type_grid"])
                        for column, kind in enumerate(kinds)
                    )
                    if captured:
                        self.messages.command(MessageCommand(op="event", kind="capture", turn=self.match.turn,
                            slot=int(self.match.captured_by[victim]), target=victim))
            if self.match.engine_name == "polyworld":
                self.match.record_frame()
            if winner >= 0:
                reason = ("forfeit" if forfeits else self.match.end_reason) if self.match.is_ffa else "general_capture"
                break
            remaining = self.config.tick_interval_seconds - (asyncio.get_running_loop().time() - started)
            if remaining > 0:
                await asyncio.sleep(remaining)

        self.phase = "saving"
        self.messages.command(MessageCommand(op="event", kind="victory" if winner >= 0 else "draw",
            turn=self.match.turn, slot=winner))
        result = {
            "scores": ([0] * self.num_players if winner == -1 else
                       [1 if s == winner else -1 for s in range(self.num_players)]),
            "winner": winner,
            "reason": reason,
            "turns": self.match.turn,
            "army": self.frames[-1]["army"],
            "land": self.frames[-1]["land"],
            "timeouts": self.timeouts,
        }
        if self.match.is_ffa:
            result.update(self.match.standings(winner))
        replay = {
            "format": "generals-coworld",
            "version": REPLAY_VERSION,
            "engine": self.match.engine_name,
            "ruleset": self.config.ruleset,
            "seed": self.config.seed,
            "height": self.match.height,
            "width": self.match.width,
            "players": self.names,
            "player_ratings": self.player_ratings,
            "frames": self.frames.records,
            "turns": self.turns,
            "result": result,
        }
        replay["skill_scores"] = self.skill_scores
        replay["chats"] = [chat.model_dump() for chat in self.messages.chats]
        replay["skill_label"] = (f"At match start: {self.config.player_ratings.league} "
                                 f"{self.config.player_ratings.label}. — = unrated."
                                 if self.config.player_ratings is not None else "Skill: unavailable for this replay.")
        # Results are the completion marker. Never mark success without a replay.
        saved_replay = self.match.replay(replay) if self.match.engine_name == "polyworld" else replay
        await self.save("replay", saved_replay)
        if self.file_players:
            await self.file_players.close()
        await self.save("results", result)
        self.result, self.replay = result, replay
        self.saved_replay = saved_replay
        self.browser_replay = await asyncio.to_thread(lambda: {
            "encoding": "gzip+base64",
            "data": base64.b64encode(gzip.compress(
                (saved_replay if isinstance(saved_replay, bytes) else
                 json.dumps(saved_replay, separators=(",", ":")).encode()), compresslevel=1
            )).decode(),
        })
        self.phase = "finished"
        self.publish()
        LOG.info("episode complete: %s, turn %d, winner %d", reason, self.match.turn, winner)

    async def fail_policy(self, fault: PolicyFault):
        await self.file_players.close()
        await self.save("failure", fault.model_dump(by_alias=True))
        self.failed = True
        self.phase = "failed"
        self.publish()


def subscribe_replay(ws, message):
    if message == {"type": "subscribe", "replay": True}:
        ws.state.include_replay = True
        return True
    return False


async def send_messages(ws, queue, episode):
    while True:
        message = await queue.get()
        # Browser clients need the completed recording before the hosted proxy
        # retires. Bot clients keep their bounded result-only terminal message.
        if ws.state.include_replay and (
            message["type"] == "final" or message["type"] == "global" and message["phase"] == "finished"
        ):
            message = {**message, "replay": episode.browser_replay}
        terminal = message["type"] in ("final", "failure") or (
            message["type"] == "global" and message["phase"] in ("finished", "failed")
        )
        async with asyncio.timeout(2):
            await ws.send_json(message)
            if terminal:
                await ws.close(code=1000)
        if terminal:
            return


async def socket_session(ws, queue, receive, episode):
    ws.state.include_replay = False
    sender = asyncio.create_task(send_messages(ws, queue, episode))
    episode.senders.add(sender)
    receiver = asyncio.create_task(receive())
    try:
        await asyncio.wait((sender, receiver), return_when=asyncio.FIRST_COMPLETED)
    finally:
        for task in (sender, receiver):
            task.cancel()
        with CancelScope(shield=True):
            await asyncio.gather(sender, receiver, return_exceptions=True)
        episode.senders.discard(sender)


def create_app(config: GameConfig | None = None, artifacts: dict | None = None, shutdown=None,
               engine: Literal["jax", "polyworld"] | None = None):
    @asynccontextmanager
    async def lifespan(app):
        try:
            cfg = config or GameConfig.model_validate(
                await asyncio.to_thread(read_json, os.environ["COGAME_CONFIG_URI"])
            )
        except Exception as exc:  # noqa: BLE001 - startup tracebacks must not expose config URLs or tokens
            raise RuntimeError(f"cannot load game config ({type(exc).__name__})") from None
        engine_name = engine or os.environ.get("GENERALS_ENGINE", "jax")
        if cfg.seed is None:
            seed_bits = 64 if engine_name == "polyworld" else 32
            cfg = cfg.model_copy(update={"seed": secrets.randbits(seed_bits)})
        destinations = (
            artifacts
            if artifacts is not None
            else {
                "results": os.environ["COGAME_RESULTS_URI"],
                "replay": os.environ["COGAME_SAVE_REPLAY_URI"],
                "failure": os.environ.get("COGAME_PLAYER_FAILURE_URI"),
                "results_method": os.environ.get("COGAME_RESULTS_METHOD", "PUT"),
                "replay_method": os.environ.get("COGAME_SAVE_REPLAY_METHOD", "PUT"),
                "failure_method": os.environ.get("COGAME_PLAYER_FAILURE_METHOD", "PUT"),
            }
        )
        if engine_name == "polyworld":
            from .polyworld_engine import Match as PolyworldMatch

            match_class = PolyworldMatch
        elif engine_name == "jax":
            from .engine import Match

            match_class = Match
        else:
            raise ValueError("GENERALS_ENGINE must be jax or polyworld")
        match = await asyncio.to_thread(match_class, cfg.seed, num_players=len(cfg.players), ruleset=cfg.ruleset)
        try:
            episode = Episode(cfg, match, destinations, shutdown)
            app.state.episode = episode
            task = asyncio.create_task(episode.run())
            try:
                yield
            finally:
                task.cancel()
                with suppress(asyncio.CancelledError):
                    await task
        finally:
            if engine_name == "polyworld":
                await asyncio.to_thread(match.close)

    app = FastAPI(lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)
    app.mount("/client/polyworld", StaticFiles(directory=POLYWORLD_VIEWER, check_dir=False))

    def client_page():
        return HTMLResponse((STATIC / "index.html").read_text().replace(
            "<head>", f'<head><meta name="generals-engine" content="{app.state.episode.match.engine_name}">', 1
        ))
    # Use the engine's original sprites; the replay build copies the same files.
    # Hosted play forwards /client/*, but does not forward arbitrary /static/*.
    for prefix in ("/static", "/client/static"):
        app.mount(
            prefix + "/assets", StaticFiles(directory=Path(__file__).parents[2] / "generals/assets/images")
        )
        app.mount(prefix + "/fonts", StaticFiles(directory=Path(__file__).parents[2] / "generals/assets/fonts"))
        app.mount(prefix, StaticFiles(directory=STATIC))

    @app.middleware("http")
    async def privacy_headers(request, call_next):
        response = await call_next(request)
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        return response

    @app.get("/healthz")
    async def health():
        return {"ready": True}

    @app.get("/client/player")
    async def player_client(slot: str = "", token: str = "", address: str | None = None):
        # Hosted play wraps the full proxied WebSocket URL in `address`.
        # Validate its credentials without making any request to that URL.
        if address is not None:
            try:
                url = urlsplit(address)
                query = parse_qs(url.query)
                if url.scheme not in ("ws", "wss") or not url.netloc:
                    raise ValueError("invalid address")
                [slot], [token] = query.get("slot", []), query.get("token", [])
            except ValueError:
                raise HTTPException(403, "invalid player credentials") from None
        if app.state.episode.authorize(slot, token) is None:
            raise HTTPException(403, "invalid player credentials")
        return client_page()

    @app.get("/client/launch")
    @app.get("/client/global")
    @app.get("/client/replay")
    async def global_client():
        return client_page()

    @app.get("/replay.json")
    async def replay_frames():
        episode = app.state.episode
        if episode.phase != "finished":
            raise HTTPException(409, "replay is available when the episode completes")
        return JSONResponse(episode.replay)

    @app.get("/client/replay.data")
    async def replay_data():
        episode = app.state.episode
        if episode.phase != "finished":
            raise HTTPException(409, "replay is available when the episode completes")
        if isinstance(episode.saved_replay, bytes):
            return Response(episode.saved_replay, media_type="application/octet-stream")
        return JSONResponse(episode.saved_replay)

    @app.websocket("/player")
    async def player(ws: WebSocket):
        episode = app.state.episode
        slot = episode.authorize(ws.query_params.get("slot"), ws.query_params.get("token"))
        if slot is None or slot in episode.reserved_slots or episode.phase in ("saving", "finished", "failed"):
            await ws.close(code=1008)
            return
        queue = asyncio.Queue(maxsize=4)
        episode.reserved_slots.add(slot)
        try:
            await ws.accept()
        except Exception:
            episode.reserved_slots.discard(slot)
            raise
        episode.players[slot] = queue
        enqueue(
            queue,
            {
                "type": "hello",
                "protocol_version": VERSION,
                "slot": slot,
                "height": episode.match.height,
                "width": episode.match.width,
                "players": episode.names,
                "player_ratings": episode.player_ratings,
                "ruleset": episode.config.ruleset,
            },
        )
        if episode.phase == "playing":
            enqueue(queue, episode.observation(slot))
        episode.joined.set()

        async def receive():
            while True:
                raw = await ws.receive_text()
                if len(raw) > 2048:
                    await ws.close(code=1009)
                    return
                try:
                    message = json.loads(raw)
                    if not subscribe_replay(ws, message):
                        episode.accept(slot, message)
                except (ValueError, TypeError) as exc:
                    enqueue(
                        queue,
                        {
                            "type": "error",
                            "message": str(exc) if not isinstance(exc, json.JSONDecodeError) else "invalid JSON",
                        },
                    )

        try:
            await socket_session(ws, queue, receive, episode)
        finally:
            if episode.players.get(slot) is queue:
                del episode.players[slot]
                if (episode.match.is_ffa and episode.phase in ("playing", "resolving")
                        and slot in episode.match.active_slots):
                    episode.request_surrender(slot)
            episode.reserved_slots.discard(slot)

    @app.websocket("/global")
    async def global_viewer(ws: WebSocket):
        episode = app.state.episode
        await ws.accept()
        queue = asyncio.Queue(maxsize=1)
        episode.viewers.add(queue)
        enqueue(queue, episode.public())

        async def receive():
            # Spectators cannot pause the engine, alter pacing, or choose seeds.
            while True:
                subscribe_replay(ws, json.loads(await ws.receive_text()))

        try:
            await socket_session(ws, queue, receive, episode)
        finally:
            episode.viewers.discard(queue)

    return app


def main():
    keep_open = os.environ.get("GENERALS_KEEP_OPEN") == "1"
    app = create_app(shutdown=None if keep_open else lambda: setattr(server, "should_exit", True))
    server = uvicorn.Server(
        uvicorn.Config(
            app,
            host=os.environ.get("COGAME_HOST", "0.0.0.0"),
            port=int(os.environ.get("COGAME_PORT", "8080")),
            # Uvicorn's websocket INFO messages contain query strings even when
            # access_log=False. Suppress them so slot tokens never reach game logs.
            access_log=False,
            log_level="warning",
            ws="websockets",
            ws_max_size=2048,
            ws_max_queue=8,
        )
    )
    server.run()
    raise SystemExit(1 if not hasattr(app.state, "episode") or app.state.episode.failed else 0)


if __name__ == "__main__":
    main()
