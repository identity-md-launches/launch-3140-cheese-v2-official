"""Regression checks for release validation; python3 -m unittest discover -s checks."""

import copy
import importlib.util
import json
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("verify_release", ROOT / "tools/verify_release.py")
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)


class ReleaseVerificationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.contracts = json.loads((ROOT / "release/build-manifest.json").read_text())["contracts"]

    def test_ast_renumbering_preserves_offsets_but_not_merging(self):
        refs = {"1": [{"start": 10, "length": 32}, {"start": 90, "length": 32}], "2": [{"start": 42, "length": 32}]}
        renumbered = {"999": list(reversed(refs["1"])), "123": refs["2"]}
        self.assertEqual(verify.immutable_offsets(refs), verify.immutable_offsets(renumbered))
        self.assertNotEqual(verify.immutable_offsets(refs), verify.immutable_offsets({"1": refs["1"] + refs["2"]}))

    def test_every_original_bytecode_matches_with_current_ast_ids(self):
        for contract in self.contracts:
            with self.subTest(contract=contract["name"]):
                artifact = json.loads((ROOT / "out" / contract["artifact"]).read_text())
                verify.verify_artifact(contract, artifact)

    def test_changed_creation_or_runtime_bytes_are_rejected(self):
        contract = self.contracts[0]
        original = json.loads((ROOT / "out" / contract["artifact"]).read_text())
        for key in ("bytecode", "deployedBytecode"):
            with self.subTest(key=key):
                artifact = copy.deepcopy(original)
                encoded = bytearray.fromhex(artifact[key]["object"].removeprefix("0x"))
                encoded[0] ^= 1
                artifact[key]["object"] = "0x" + encoded.hex()
                with self.assertRaises(AssertionError):
                    verify.verify_artifact(contract, artifact)

    def test_changed_missing_or_duplicated_immutable_locations_are_rejected(self):
        contract = self.contracts[0]
        original = json.loads((ROOT / "out" / contract["artifact"]).read_text())
        for mode in ("offset", "length", "missing", "duplicate", "split"):
            with self.subTest(mode=mode):
                artifact = copy.deepcopy(original)
                refs = artifact["deployedBytecode"]["immutableReferences"]
                locations = next(iter(refs.values()))
                if mode == "offset":
                    locations[0]["start"] += 1
                elif mode == "length":
                    locations[0]["length"] -= 1
                elif mode == "missing":
                    locations.pop()
                elif mode == "duplicate":
                    locations.append(locations[0].copy())
                else:
                    refs["new"] = [locations.pop()]
                with self.assertRaises(AssertionError):
                    verify.verify_artifact(contract, artifact)


if __name__ == "__main__":
    unittest.main()
