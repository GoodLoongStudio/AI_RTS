# -*- coding: utf-8 -*-
"""探针：完全复用测试里的 RuntimeFixture，逐 tick 打印下发来源。"""

import os
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(ROOT, "..", ".."))
COORD = os.path.join(REPO, "source")
sys.path.insert(0, COORD)
sys.path.insert(0, os.path.join(COORD, "adjutant_coordinator", "tests"))

from graph_test_helpers import events_for, make_batch, make_intent, make_plan
from test_graph_runtime_fake import (
    ENGINE_FALLBACK, RuntimeFixture, base_config, is_floor_intent,
)


def make_fixture():
    return RuntimeFixture(
        strategy_script=[{"behavior": "completed", "plan": make_plan()}],
        tactics_script=[
            {"behavior": "completed", "intents": make_batch(
                [make_intent("i-1", issued_tick=5, expires_tick=605)])},
            {"behavior": "completed", "intents": make_batch(
                [make_intent("i-2", issued_tick=10, expires_tick=605)])},
            {"behavior": "completed", "intents": make_batch(
                [make_intent("i-3", issued_tick=21, expires_tick=605)])},
        ],
        config=base_config(ENGINE_FALLBACK))


def dump(fixture, label):
    sent = fixture.transport.sent
    ids = [item.get("intent_id") for item in sent]
    print("%-34s total=%d model=%d floor=%d %s" % (
        label, len(ids), len([i for i in ids if not is_floor_intent(i)]),
        len([i for i in ids if is_floor_intent(i)]), ids))


fx = make_fixture()
fx.tick(0)
dump(fx, "tick0")
fx.tick(5, events=[events_for("enemy_spotted", ["Unit_1"], 5)])
dump(fx, "tick5")
fx.runtime.on_player_command(["Unit_1"], server_tick=8)
r = fx.tick(8)
dump(fx, "tick8 paused=%s route=%s" % (r.paused, r.route))
r = fx.tick(9)
dump(fx, "tick9 paused=%s" % (r.paused,))
r = fx.tick(10, events=[events_for("queue_idle", ["Unit_1"], 10)])
dump(fx, "tick10")
print("  dropped=%s" % [(d.get("intent_id"), d.get("reason")) for d in r.dropped_intents])
print("  active=%s" % [(i["intent_id"], i["state"]) for i in fx.runtime.state.active_intents])

fx.runtime.on_player_release(["Unit_1"], server_tick=20)
r = fx.tick(20)
dump(fx, "tick20 (released)")
r = fx.tick(21, events=[events_for("queue_idle", ["Unit_1"], 21)])
dump(fx, "tick21 accepted=%s" % (r.accepted_intents,))
