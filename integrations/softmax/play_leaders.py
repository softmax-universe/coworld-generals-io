"""Prepare an eight-seat human FFA lobby against the current seven league leaders."""

import argparse
import json
import subprocess
from typing import Literal
from uuid import UUID

import httpx
from pydantic import BaseModel, Field, FiniteFloat, TypeAdapter

LEAGUE = "league_f189ad01-2700-4fc8-ba89-f9de477099e4"
DIVISION = "div_ac86d8a0-7b43-41bb-b6e7-1867f7b47d08"


class Standing(BaseModel):
    rank: int = Field(ge=1)
    player_id: str
    player_name: str
    score: FiniteFloat


class Player(BaseModel):
    id: str


class PolicyVersion(BaseModel):
    id: UUID
    label: str


class Membership(BaseModel):
    player: Player
    policy_version: PolicyVersion
    status: str
    is_champion: bool


class Opponent(BaseModel):
    slot: int
    standing: Standing
    policy_version: PolicyVersion


class CreatedSession(BaseModel):
    session_id: str
    lobby_url: str


class Seat(BaseModel):
    slot: int
    slot_kind: Literal["human", "policy", "closed"]
    policy_version_id: UUID | None


class Lobby(BaseModel):
    coworld_id: str
    variant_id: str
    player_count: int
    players: list[Seat]


def league_opponents(client: httpx.Client) -> list[Opponent]:
    response = client.get(f"divisions/{DIVISION}/leaderboard", params={"include_recent_rounds": "false"})
    response.raise_for_status()
    leaders = sorted(TypeAdapter(list[Standing]).validate_json(response.content), key=lambda row: row.rank)[:7]
    if len(leaders) != 7 or len({row.player_id for row in leaders}) != 7:
        raise ValueError("The FFA leaderboard must supply seven distinct ranked opponents")
    response = client.get("league-policy-memberships", params={
        "league_id": LEAGUE, "division_id": DIVISION, "active_only": "true",
        "champions_only": "true", "limit": 1000,
    })
    response.raise_for_status()
    if "X-Next-Cursor" in response.headers:
        raise ValueError("Membership snapshot exceeds one page; cannot verify every leader")
    memberships = TypeAdapter(list[Membership]).validate_json(response.content)
    opponents = []
    for slot, leader in enumerate(leaders, 1):
        matches = [member for member in memberships if member.player.id == leader.player_id
                   and member.is_champion and member.status == "competing"]
        if len(matches) != 1:
            raise ValueError(f"Rank {leader.rank} ({leader.player_name}) needs exactly one active champion policy")
        opponents.append(Opponent(slot=slot, standing=leader, policy_version=matches[0].policy_version))
    return opponents


def create_lobby(client: httpx.Client, coworld_id: str, opponents: list[Opponent]) -> CreatedSession:
    response = client.post("coworlds/play/session", json={"coworld_id": coworld_id})
    response.raise_for_status()
    session = CreatedSession.model_validate_json(response.content)
    path = f"coworlds/play/session/{session.session_id}"
    response = client.put(path + "/config", json={"kind": "variant", "variant_id": "ffa-8-human"})
    response.raise_for_status()
    for opponent in opponents:
        response = client.put(path + f"/seat/{opponent.slot}", json={
            "kind": "policy", "policy_version_id": str(opponent.policy_version.id),
        })
        response.raise_for_status()
    response = client.get(path)
    response.raise_for_status()
    lobby = Lobby.model_validate_json(response.content)
    expected = {opponent.slot: opponent.policy_version.id for opponent in opponents}
    actual = {seat.slot: seat.policy_version_id for seat in lobby.players if seat.slot_kind == "policy"}
    if (lobby.coworld_id != coworld_id or lobby.variant_id != "ffa-8-human" or lobby.player_count != 8
            or actual != expected or not any(seat.slot == 0 and seat.slot_kind == "human" for seat in lobby.players)):
        raise ValueError(f"Lobby {session.session_id} failed roster verification; do not start it")
    return session


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--api", default="https://api.observatory.softmax-research.net/v2/")
    parser.add_argument("--create", action="store_true",
                        help="create and verify a lobby; otherwise only print opponents")
    parser.add_argument("--coworld-id", help="exact published Polyworld Coworld version to use")
    parser.add_argument("--elevated", action="store_true", help="use authorized team access to other owners' policies")
    args = parser.parse_args()
    if args.create and not args.coworld_id:
        parser.error("--create requires --coworld-id from the verified Polyworld release")
    token = subprocess.check_output(["softmax", "get-token"], text=True).strip()
    headers = {"Authorization": "Bearer " + token}
    if args.elevated:
        headers["X-Use-Elevated-Privileges"] = "true"
    with httpx.Client(base_url=args.api.rstrip("/") + "/", headers=headers, timeout=30) as client:
        opponents = league_opponents(client)
        print(json.dumps({"variant": "ffa-8-human", "human_slot": 0,
                          "opponents": [opponent.model_dump(mode="json") for opponent in opponents]}, indent=2))
        if args.create:
            session = create_lobby(client, args.coworld_id, opponents)
            print("Verified lobby: https://softmax.com" + session.lobby_url)


if __name__ == "__main__":
    main()
