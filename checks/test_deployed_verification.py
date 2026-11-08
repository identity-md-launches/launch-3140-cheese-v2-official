"""Offline rejection tests for the read-only deployment verifier; no live addresses."""

import importlib.util
import json
import pathlib
import types
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("verify_deployed", ROOT / "tools/verify_deployed.py")
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)


class DeployedVerificationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.contracts = json.loads((ROOT / "release/build-manifest.json").read_text())["contracts"]
        # Synthetic offline fixtures only; never offered as official deployment addresses.
        cls.addresses = {name: "0x" + format(i + 1, "040x") for i, name in enumerate(verify.NAMES)}

    def test_all_templates_reject_one_byte_mutations_and_empty_code(self):
        for contract in self.contracts:
            with self.subTest(contract=contract["name"]):
                code = verify.expected_runtime(contract, self.addresses)
                self.assertEqual(verify.verify_runtime(contract, code, self.addresses), "0x" + verify.keccak(code).hex())
                mutated = bytes([code[0] ^ 1]) + code[1:]
                for bad in (mutated, b"", code + b"\0"):
                    with self.assertRaises(ValueError):
                        verify.verify_runtime(contract, bad, self.addresses)

    def test_dependency_or_permit_address_substitution_is_rejected(self):
        wrong = dict(self.addresses)
        wrong["CheeseEmissionController"], wrong["CheeseToken"] = wrong["CheeseToken"], wrong["CheeseEmissionController"]
        for contract in self.contracts:
            if contract["name"] == "CheeseEmissionController":
                continue  # Its sole immutable is the official Core, independent of these two addresses.
            with self.subTest(contract=contract["name"]):
                code = verify.expected_runtime(contract, wrong)
                with self.assertRaises(ValueError):
                    verify.verify_runtime(contract, code, self.addresses)

    def test_manifest_group_or_location_drift_is_rejected(self):
        original = self.contracts[0]
        for mode in ("group", "offset", "length"):
            contract = json.loads(json.dumps(original))
            refs = contract["immutableReferences"]
            if mode == "group":
                refs["unknown"] = refs.pop(next(iter(refs)))
            elif mode == "offset":
                next(iter(refs.values()))[0]["start"] = len(contract["deployedBytecode"])
            else:
                next(iter(refs.values()))[0]["length"] = 31
            with self.subTest(mode=mode), self.assertRaises(ValueError):
                verify.expected_runtime(contract, self.addresses)

    def test_missing_duplicate_zero_and_dependency_addresses_are_rejected(self):
        self.assertEqual(verify.validate_addresses(self.addresses), self.addresses)
        for value in ("0x" + "0" * 40, "not-an-address", verify.CORE, verify.OWNER, self.addresses["CheeseToken"]):
            addresses = dict(self.addresses, CheeseEmissionController=value)
            with self.subTest(value=value), self.assertRaises(ValueError):
                verify.validate_addresses(addresses)
        with self.assertRaises(ValueError):
            verify.validate_addresses({})

    def test_verifier_cannot_send_transactions(self):
        rpc = verify.RPC("http://unused.invalid")
        for method in ("eth_sendTransaction", "eth_sendRawTransaction", "personal_sign", "eth_sign"):
            with self.subTest(method=method), self.assertRaises(ValueError):
                rpc.call(method, [])

    def test_rpc_uses_json_arguments_and_fails_on_transport_errors(self):
        rpc = verify.RPC("https://unused.invalid")
        with patch.object(verify.subprocess, "run", return_value=types.SimpleNamespace(returncode=0, stdout='"0xaa36a7"')) as run:
            self.assertEqual(rpc.call("eth_chainId", []), "0xaa36a7")
            self.assertEqual(run.call_args.args[0][-3:], ["--raw", "eth_chainId", "[]"])
            self.assertNotIn("shell", run.call_args.kwargs)
        with patch.object(verify.subprocess, "run", return_value=types.SimpleNamespace(returncode=1, stdout="")):
            with self.assertRaises(ValueError):
                rpc.call("eth_chainId", [])

    def test_initial_state_rejects_changed_owner_activation_asset_and_premint(self):
        replies = {}

        def add(name, signature, result, args=b""):
            key = (self.addresses[name], "0x" + (verify.keccak(signature.encode())[:4] + args).hex())
            replies[key] = "0x" + result.hex()
            return key

        owner_key = None
        for name in (verify.NAMES[0], *verify.NAMES[2:]):
            owner_key = add(name, "owner()", verify.word(verify.OWNER))
            add(name, "pendingOwner()", verify.word(0))
        for signature in ("treasury()", "guardian()"):
            add(verify.NAMES[0], signature, verify.word(verify.OWNER))
        for signature in ("token()", "poolCount()", "totalMinted()", "emissionsPaused()"):
            add(verify.NAMES[0], signature, verify.word(0))
        activation_key = add(verify.NAMES[0], "activated()", verify.word(0))
        add(verify.NAMES[0], "getAllocation()", verify.word(0) + verify.word(0) + verify.word(1000))
        for name in verify.NAMES[2:]:
            for signature in ("registered()", "depositsPaused()", "totalShares()", "totalAssets()", "rewardReserve()", "treasuryOwed()"):
                add(name, signature, verify.word(0))
        asset_key = add(verify.NAMES[4], "asset()", verify.word(0))
        for signature in ("totalSupply()", "totalMinted()", "totalPreminted()"):
            add(verify.NAMES[1], signature, verify.word(210_000_000 * 10**18))
        balance_key = add(verify.NAMES[1], "balanceOf(address)", verify.word(210_000_000 * 10**18), verify.word(verify.OWNER))
        add(verify.NAMES[1], "totalBurned()", verify.word(0))

        class FixtureRPC:
            def call(self, method, params):
                if method != "eth_call" or params[1] != "0x123":
                    raise AssertionError("unexpected RPC or unpinned block")
                return replies[(params[0]["to"], params[0]["data"])]

        verify.verify_initial_state(FixtureRPC(), "0x123", self.addresses)
        for key in (owner_key, activation_key, asset_key, balance_key):
            original = replies[key]
            replies[key] = "0x" + verify.word(1).hex()
            with self.subTest(key=key), self.assertRaises(ValueError):
                verify.verify_initial_state(FixtureRPC(), "0x123", self.addresses)
            replies[key] = original


if __name__ == "__main__":
    unittest.main()
