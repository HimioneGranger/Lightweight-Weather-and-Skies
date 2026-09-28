#!/usr/bin/env python3
"""Static release-contract checks that do not require the game runtime."""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def text(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def require(relative: str, *needles: str) -> None:
    body = text(relative)
    for needle in needles:
        assert needle in body, f"{relative}: missing {needle!r}"


manifest = json.loads(text("manifest.json"))
assert manifest["version"] == "1.0.0"
require("weather_main.lua", 'local ok, bridge = pcall(V.require, "VoxelAtmosBridge")')
assert "pcall(bridge.init)" not in text("weather_main.lua")
require("compat/BattleArtClient.lua", "bindCloudCeiling", "atmosphere_effects_draft==1")
require("compat/CloudPackets.lua", "function self:ceilingAt", "altitude-65*front-110*shelf")
require("compat/CloudsSource.lua", "Clouds.WEATHER_COVERAGE = 0.86", "RAIN_LIGHT = 0.75", "if id=='MOSTLY_CLOUDY' then target=.45 end")
require("compat/Controls.lua", "about every 6 seconds", "Natural lightning is unchanged.")
require(
    "lib/QuestStorm.lua",
    "spicy.wait=6",
    "verification=verification==true",
    "lightningRate",
    "cloudOnly=random(0,1)<0.50",
)
require("lib/QuestStormBolt.lua", "SPICY_WIDTH_BOOST=2.25", "function Bolt.vertices")
require("lib/Audio.lua", "Audio._thunderDuck=2.5", "gain=math.min(.90,gain*2)")
require("README.md", "PR #57", "Android phone/tablet", "Safari Zone outdoor areas")
print("release contract: PASS")
