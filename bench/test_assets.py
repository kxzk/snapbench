import json
import struct
import unittest
from pathlib import Path
from typing import Any


class AssetContractTests(unittest.TestCase):
    def test_creature_catalogue_has_the_expected_idle_clip(self) -> None:
        assets = Path(__file__).resolve().parents[1] / "assets"
        for species in ("cat", "dog", "horse", "pig", "raccoon", "sheep", "wolf"):
            with self.subTest(species=species):
                data = (assets / f"{species}.glb").read_bytes()
                json_length = struct.unpack_from("<I", data, 12)[0]
                model: dict[str, Any] = json.loads(data[20 : 20 + json_length])
                self.assertEqual(model["animations"][2]["name"].split("|")[-1], "Idle")
