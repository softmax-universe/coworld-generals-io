"""Generate the Coworld template from runtime schema and game-owned docs."""

import argparse
import json
from pathlib import Path

from integrations.softmax.config import PLAYER_NAMES, GameConfig

ROOT = Path(__file__).resolve().parents[1]
SOURCE = "https://github.com/softmax-universe/coworld-generals-io/tree/main/integrations/softmax"


def document(*filenames):
    return {"type": "text", "value": "\n\n".join((ROOT / filename).read_text() for filename in filenames)}


def ffa_variant(count, human=False):
    variant_id = "ffa" if count == 4 else f"ffa-{count}"
    config = {"players": [{"name": name} for name in PLAYER_NAMES[:count]],
              "ruleset": "classic", "max_turns": 1200 if human else 50002}
    if human:
        config.update(tick_interval_seconds=0.5, turn_timeout_seconds=1)
    return {
        "id": f"{variant_id}-human" if human else variant_id,
        "name": f"{'Human play FFA' if human else 'Free-for-all'} ({count} players)",
        "description": (
            f"{count} independent generals on Polyworld maps; last survivor wins. "
            + ("Paced at two engine ticks per second." if human else
               "FFA Survival scoring; official idle and long-game adjudication.")
        ),
        "game_config": config,
    }


def template():
    scores = {"type": "array", "minItems": 2, "maxItems": 8, "items": {"type": "number"}}
    counts = {"type": "array", "minItems": 2, "maxItems": 8, "items": {"type": "integer", "minimum": 0}}
    results = {
        "type": "object",
        "additionalProperties": False,
        "required": ["scores", "winner", "reason", "turns", "army", "land", "timeouts"],
        "properties": {
            "scores": scores,
            "winner": {"type": "integer", "enum": list(range(-1, 8))},
            "reason": {"type": "string", "enum": [
                "general_capture", "turn_limit", "forfeit", "double_forfeit", "idle_limit"
            ]},
            "turns": {"type": "integer", "minimum": 0, "maximum": 50002},
            "army": counts,
            "land": counts,
            "timeouts": counts,
            "placements": counts,
            "kills": counts,
            "captured_by": {**counts, "items": {"type": "integer", "minimum": -1, "maximum": 7}},
            "elimination_order": {**counts, "minItems": 0},
        },
    }
    players = [{"name": "Red"}, {"name": "Blue"}]
    return {
        "$schema": "https://raw.githubusercontent.com/Metta-AI/coworld/main/src/coworld/coworld_manifest_schema.json",
        "tags": ["strategy", "1v1", "ffa", "fog-of-war", "territory-control"],
        "game": {
            "player_runtime": ["platform-hosted", "game-hosted"],
            "name": "generals-competition",
            "owner": "Softmax",
            "description": (
                "Three-to-eight-player free-for-all under fog of war. Grow armies, capture rival generals, "
                "and compete for Survival placement. Classic 1v1 and Build 1v1 are also available."
            ),
            "runnable": {
                "type": "game",
                "image": "{{GENERALS_GAME_IMAGE}}",
                "run": ["python", "-m", "integrations.softmax.server"],
                "env": {"GENERALS_ENGINE": "polyworld", "COWORLD_PLAYER_RATINGS": "true"},
                "source_url": SOURCE,
            },
            "config_schema": GameConfig.model_json_schema(),
            "results_schema": results,
            "protocols": {
                "player": document("PLAYER_PROTOCOL.md", "BASIC_PROTOCOL.md"),
                "global": document("GLOBAL_PROTOCOL.md"),
            },
            "docs": {"readme": document("docs/README.md")},
            "replay_viewer": {"bundle": "replay-viewer", "replay_compression": "gzip"},
        },
        "player": [
            {
                "id": "basic",
                "name": "BASIC Frontier",
                "description": "Editable BASIC frontier-expansion baseline with bounded execution.",
                "type": "player",
                "file": "players/baseline.bas",
                "source_url": SOURCE,
            },
            {
                "id": "expander",
                "name": "Expander",
                "description": "Pure-Python competition baseline through the stdio bridge.",
                "type": "player",
                "image": "{{GENERALS_PLAYER_IMAGE}}",
                "run": ["python", "-m", "integrations.softmax.player"],
                "source_url": SOURCE,
            },
            {
                "id": "builder",
                "name": "Builder",
                "description": "Funds an opening castle in building mode, then uses the Expander strategy.",
                "type": "player",
                "image": "{{GENERALS_PLAYER_IMAGE}}",
                "run": ["python", "-m", "integrations.softmax.builder_player"],
                "source_url": SOURCE,
            },
        ],
        "variants": [
            {
                "id": "competition",
                "name": "Classic 1v1",
                "description": "Regular capture-only rules, 2000-turn cap, fresh private seed; fast bot play.",
                "game_config": {"players": players, "max_turns": 2000},
            },
            {
                "id": "human",
                "name": "Human play 1v1",
                "description": "The same classic rules paced at two turns per second.",
                "game_config": {
                    "players": players, "max_turns": 1200,
                    "tick_interval_seconds": 0.5, "turn_timeout_seconds": 1,
                },
            },
            ffa_variant(4),
            {
                "id": "castles",
                "name": "Build your own castles (1v1)",
                "description": (
                    "No neutral castles: spend armies to build on owned plain land. No Deathtouch. 2000-turn cap."
                ),
                "game_config": {"players": players, "ruleset": "build_castles", "max_turns": 2000},
            },
            ffa_variant(4, human=True),
            {
                "id": "castles-human",
                "name": "Human play castle building",
                "description": "Build-your-own-castles 1v1 paced at two turns per second.",
                "game_config": {"players": players, "ruleset": "build_castles", "max_turns": 1200,
                                "tick_interval_seconds": 0.5, "turn_timeout_seconds": 1},
            },
            *[ffa_variant(count, human) for count in (3, 5, 6, 7, 8) for human in (False, True)],
        ],
        "certification": {
            "game_config": {
                "players": players + [{"name": "Green"}, {"name": "Purple"}],
                "seed": 7,
                "max_turns": 40,
                "tick_interval_seconds": 0.05,
            },
            "players": [
                {"player_id": "basic"},
                {"player_id": "expander"},
                {"player_id": "builder"},
                {"player_id": "basic"},
            ],
        },
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    output = ROOT / "coworld_manifest_template.json"
    content = json.dumps(template(), indent=2) + "\n"
    if args.check:
        if not output.exists() or output.read_text() != content:
            raise SystemExit("manifest is stale: run python -m integrations.softmax.tools.manifest")
        print("Coworld manifest matches runtime schema and docs.")
    else:
        output.write_text(content)
        print(output)


if __name__ == "__main__":
    main()
