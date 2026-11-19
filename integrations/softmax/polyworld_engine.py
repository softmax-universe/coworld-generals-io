"""Coworld observations and hosted rules over the authoritative Nim engine."""

import json
import os
import subprocess
from typing import Literal

import numpy as np
from pydantic import BaseModel, ConfigDict

from .messages import PublicChat
from .protocol import VERSION


class EngineCommand(BaseModel):
    model_config = ConfigDict(extra="forbid")
    op: Literal["new", "step", "surrender", "neutralize"]
    # Decimal text preserves all bits across Nim's signed JSON integer parser.
    seed: str = "0"
    players: int = 2
    ruleset: Literal["classic", "build_castles"] = "classic"
    actions: list[list[int]] = []
    slots: list[int] = []


class EngineState(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    hash: str
    turn: int
    winner: int
    width: int
    height: int
    alive: list[bool]
    kinds: list[int]
    owners: list[int]
    armies: list[int]
    executed: list[bool]
    captured_by: list[int]
    elimination_order: list[int]
    damage: list[list[int]]


class ReplayChatCommand(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    op: Literal["chat"] = "chat"
    tick: int
    player: int
    text: str


class EngineEvent(BaseModel):
    command: EngineCommand | ReplayChatCommand
    hash: str


class Match:
    engine_name = "polyworld"

    def __init__(self, seed: int, num_players: int = 2, ruleset: str = "classic"):
        if type(seed) is not int or not 0 <= seed < 2**64:
            raise ValueError("seed must be an unsigned 64-bit integer")
        if not 2 <= num_players <= 8 or ruleset not in ("classic", "build_castles"):
            raise ValueError("expected two to eight players and a known ruleset")
        if ruleset == "build_castles" and num_players != 2:
            raise ValueError("castle-building requires two players")
        self.num_players, self.ruleset = num_players, ruleset
        self.is_ffa = num_players > 2
        self.neutralize_at = np.full(num_players, -1, dtype=np.int32)
        self.afk_warning = np.zeros(num_players, dtype=bool)
        self.captured_by = [-1] * num_players
        self.elimination_order: list[int] = []
        self.damage = np.zeros((num_players, num_players), dtype=np.int64)
        self.idle_ticks = 0
        self.end_reason = "general_capture"
        self.last_move_executed = [None] * num_players
        self.last_build_executed = [None] * num_players
        self.commands: list[EngineEvent] = []
        self.recording: list[list[EngineEvent]] = []
        self.recorded_chats = 0
        self.process = subprocess.Popen(
            [os.environ.get("GENERALS_POLYWORLD_ENGINE", "/usr/local/bin/generals-polyworld")],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
        )
        self._command(EngineCommand(op="new", seed=str(seed), players=num_players, ruleset=ruleset))
        self.width, self.height = self.state.width, self.state.height

    def _command(self, command: EngineCommand):
        self.process.stdin.write(command.model_dump_json() + "\n")
        self.process.stdin.flush()
        self.state = EngineState.model_validate_json(self.process.stdout.readline())
        self.commands.append(EngineEvent(command=command, hash=self.state.hash))
        shape = (self.state.height, self.state.width)
        self.kinds = np.asarray(self.state.kinds).reshape(shape)
        self.owners = np.asarray(self.state.owners).reshape(shape)
        self.armies = np.asarray(self.state.armies).reshape(shape)

    def record_frame(self):
        if self.turn == len(self.recording):
            self.recording.append(self.commands)
        else:
            assert self.turn == len(self.recording) - 1
            self.recording[-1].extend(self.commands)
        self.commands = []

    def record_chat(self, chat: PublicChat):
        """Append admitted public chat at its exact place among engine commands."""
        if chat.tick != self.turn or not 0 <= chat.player < self.num_players:
            raise ValueError("chat must belong to the current completed turn and a known player")
        if self.recorded_chats >= 16384:
            return
        self.commands.append(EngineEvent(
            command=ReplayChatCommand(**chat.model_dump()), hash=self.state.hash,
        ))
        self.recorded_chats += 1

    def replay_chats(self) -> list[dict]:
        """Derive the diagnostic transcript from the canonical recorded commands."""
        return [event.command.model_dump(exclude={"op"})
                for tick in self.recording for event in tick
                if isinstance(event.command, ReplayChatCommand)]

    def replay(self, metadata: dict) -> bytes:
        assert not self.commands
        recording = {**{key: value for key, value in metadata.items()
                        if key not in ("frames", "format", "version", "chats")},
                "format": "polyworld-generals-hosted", "version": 2,
                "ticks": [[event.model_dump() for event in tick] for tick in self.recording]}
        return subprocess.run(
            [self.process.args[0], "--encode-replay"],
            input=json.dumps(recording, separators=(",", ":")).encode(),
            stdout=subprocess.PIPE, check=True,
        ).stdout

    def close(self):
        self.process.stdin.close()
        self.process.stdout.close()
        if self.process.wait(timeout=5):
            raise RuntimeError("Polyworld engine failed")

    @property
    def turn(self):
        return self.state.turn

    @property
    def active_slots(self) -> list[int]:
        return [slot for slot, alive in enumerate(self.state.alive) if alive]

    @property
    def kills(self) -> list[int]:
        return [self.captured_by.count(slot) for slot in range(self.num_players)]

    def visibility(self, slot: int) -> np.ndarray:
        own = np.pad(self.owners == slot, 1)
        visible = np.zeros((self.height, self.width), dtype=bool)
        for row in range(3):
            for col in range(3):
                visible |= own[row:row + self.height, col:col + self.width]
        return visible

    def build_costs(self, slot: int) -> np.ndarray:
        rows, cols = np.indices((self.height, self.width))
        costs = np.full((self.height, self.width), 35, dtype=np.int64)
        for row, col in np.argwhere((self.owners == slot) & (self.kinds >= 2)):
            costs += np.maximum(0, 14 - 2 * (np.abs(rows - row) + np.abs(cols - col)))
        return np.where((self.owners == slot) & (self.kinds == 0), costs, 0)

    def observation(self, slot: int) -> dict:
        visible = self.visibility(slot)
        own = self.owners == slot
        opponent = (self.owners >= 0) & ~own
        return {
            "type": "observation", "protocol_version": VERSION,
            "slot": slot, "turn": self.turn, "ruleset": self.ruleset,
            "last_move_executed": self.last_move_executed[slot],
            "last_build_executed": self.last_build_executed[slot],
            "eliminated": not self.state.alive[slot], "afk_warning": bool(self.afk_warning[slot]),
            "height": self.height, "width": self.width,
            "my_land": int(own.sum()), "my_army": int(self.armies[own].sum()),
            "opp_land": int(opponent.sum()), "opp_army": int(self.armies[opponent].sum()),
            "type_grid": np.where(visible, self.kinds + 1,
                                  np.where((self.kinds == 1) | (self.kinds == 2), 5, 0)).tolist(),
            "owner_grid": np.where(visible & own, 1, np.where(visible & opponent, 2, 0)).tolist(),
            "visible_owner_grid": np.where(visible, self.owners + 1, 0).tolist(),
            "army_grid": np.where(visible, self.armies, 0).tolist(),
            **({"build_cost_grid": self.build_costs(slot).tolist()} if self.ruleset == "build_castles" else {}),
        }

    def observations(self) -> list[dict]:
        return [self.observation(slot) for slot in range(self.num_players)]

    def frame(self) -> dict:
        land = [int((self.owners == slot).sum()) for slot in range(self.num_players)]
        return {
            "turn": self.turn, "type_grid": (self.kinds + 1).tolist(),
            "owner_grid": (self.owners + 1).tolist(), "army_grid": self.armies.tolist(),
            "army": [int(self.armies[self.owners == slot].sum()) for slot in range(self.num_players)],
            "land": land, "eliminated": [not alive for alive in self.state.alive], "kills": self.kills,
            "neutralize_in": [max(-1, int(self.neutralize_at[s]) - self.turn) if land[s] else -1
                              for s in range(self.num_players)],
        }

    def standings(self, winner: int) -> dict:
        order = sorted(range(self.num_players), key=lambda slot: (
            self.kills[slot] > 0 or slot == winner, slot == winner,
            self.elimination_order.index(slot) if slot in self.elimination_order else -1,
        ), reverse=True)
        placements = [order.index(slot) + 1 for slot in range(self.num_players)]
        return {
            "placements": placements, "kills": self.kills, "captured_by": self.captured_by,
            "elimination_order": self.elimination_order.copy(),
            "scores": [1 if place == 1 else -(place - 1) / (self.num_players - 1) for place in placements],
        }

    def forfeit(self, slots: list[int]) -> int:
        for slot in slots:
            if type(slot) is not int or not 0 <= slot < self.num_players:
                raise ValueError("invalid forfeiting player")
            if slot not in self.active_slots or self.is_ffa and len(self.active_slots) <= 1:
                continue
            self._command(EngineCommand(op="surrender", slots=[slot]))
            self.elimination_order.append(slot)
            if self.is_ffa:
                self.neutralize_at[slot] = self.turn + 50
            else:
                self._command(EngineCommand(op="neutralize", slots=[slot]))
        return self.active_slots[0] if len(self.active_slots) == 1 else -1

    def adjudicate(self, frame: dict) -> int:
        order = sorted(self.active_slots, key=lambda slot: (frame["army"][slot], frame["land"][slot], slot))
        self.forfeit(order[:-1])
        winner = order[-1]
        self._credit_final_surrender(winner)
        return winner

    def _credit_final_surrender(self, winner: int):
        if self.elimination_order and self.captured_by[self.elimination_order[-1]] < 0:
            self.captured_by[self.elimination_order[-1]] = winner

    def advance(self, actions: list[list[int]]) -> int:
        if len(actions) != self.num_players:
            raise ValueError("one action per player is required")
        allowed = (0, 1, 2) if self.ruleset == "build_castles" else (0, 1)
        if any(action[0] not in allowed for action in actions):
            raise ValueError("classic rules accept only moves and passes")
        previous = self.frame()
        for slot, action in enumerate(actions):
            self.last_build_executed[slot] = (
                bool(self.state.alive[slot] and self.build_costs(slot)[action[1], action[2]] > 0 and
                     self.armies[action[1], action[2]] >= self.build_costs(slot)[action[1], action[2]])
                if action[0] == 2 else None
            )
        self._command(EngineCommand(op="step", ruleset=self.ruleset, actions=actions))
        self.last_move_executed = [self.state.executed[s] if actions[s][0] == 0 else None
                                   for s in range(self.num_players)]
        self.damage += np.asarray(self.state.damage)
        for victim in self.state.elimination_order:
            self.captured_by[victim] = self.state.captured_by[victim]
            if victim not in self.elimination_order:
                self.elimination_order.append(victim)
        winner = self.state.winner
        if self.is_ffa:
            self.afk_warning[:] = False
            if winner < 0 and 99 <= self.turn <= 121:
                for slot in self.active_slots:
                    owns_city = np.any((self.owners == slot) & (self.kinds == 2))
                    sees_opponent = np.any(self.visibility(slot) & (self.owners >= 0) & (self.owners != slot))
                    if previous["land"][slot] < 11 and not owns_city and not sees_opponent:
                        if self.turn < 121:
                            self.afk_warning[slot] = True
                        else:
                            winner = self.forfeit([slot])
                            if winner >= 0:
                                self.end_reason = "forfeit"
                                break
            for slot in np.flatnonzero(self.neutralize_at == self.turn).tolist():
                if self.captured_by[slot] < 0:
                    candidates = self.active_slots
                    captor = max(candidates, key=lambda player: (self.damage[player, slot], -player))
                    if self.damage[captor, slot] > 0:
                        self.captured_by[slot] = captor
                self._command(EngineCommand(op="neutralize", slots=[slot]))
            self.idle_ticks = 0 if any(self.last_move_executed) else self.idle_ticks + 1
            if winner < 0 and (self.idle_ticks > 2000 or self.turn > 50001):
                self.end_reason = "idle_limit" if self.idle_ticks > 2000 else "turn_limit"
                winner = self.adjudicate(previous)
            if winner >= 0:
                self._credit_final_surrender(winner)
        return winner
