"""Read-only verification of the five NEW contracts once IMD supplies their addresses.

Uses Python's standard library and Foundry cast; never signs, broadcasts, or reads
wallet configuration. Input is a JSON object mapping the five Solidity names to
their confirmed addresses. This checks code and initial state, not wallet control,
Swarm receipt provenance, or explorer source-verification status.
"""

import argparse
import json
import pathlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
OWNER = "0xdea11b3a70b77134424d436f6eb455f1abbd4449"
CORE = "0xfd6c166d4b8e2962e65746a13e5a0797cd4de0c4"
CHAIN_ID = 11155111
NAMES = ("CheeseEmissionController", "CheeseToken", "CheeseFarmERC20", "CheeseFarmETH", "CheeseFarmSIMD")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def keccak(data):
    return bytes.fromhex(subprocess.check_output(["cast", "keccak", "0x" + data.hex()], text=True).strip()[2:])


def address(value):
    require(isinstance(value, str) and re.fullmatch(r"0x[0-9a-fA-F]{40}", value), "invalid address")
    require(int(value, 16) != 0, "missing address")
    return value.lower()


def word(value):
    return (int(value, 16) if isinstance(value, str) else value).to_bytes(32, "big")


def validate_addresses(addresses):
    require(set(addresses) == set(NAMES), "supply exactly the five named contracts")
    result = {name: address(value) for name, value in addresses.items()}
    require(len(set(result.values())) == 5, "contract addresses must be distinct")
    require(not set(result.values()) & {OWNER, CORE, "0x2dccb11fcc2defdd188555e45acb52231e82e218"}, "dependency or owner used as a new contract")
    return result


def expected_runtime(contract, addresses):
    """Patch the pinned release template, including every ERC20Permit cache.

    Keys below belong to the pinned manifest only. Local compiler AST IDs are
    deliberately not used. Locations and grouping are checked by verify_release.
    """
    controller = word(addresses["CheeseEmissionController"])
    token = word(addresses["CheeseToken"])
    domain = keccak(b"".join((
        keccak(b"EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
        keccak(b"CHEESE"), keccak(b"1"), word(CHAIN_ID), token,
    )))
    bindings = {
        "CheeseEmissionController": {"46222": word(CORE)},
        "CheeseToken": {
            "41674": domain, "41676": word(CHAIN_ID), "41678": token,
            "41680": keccak(b"CHEESE"), "41682": keccak(b"1"),
            "41685": b"CHEESE".ljust(31, b"\0") + b"\x06",
            "41688": b"1".ljust(31, b"\0") + b"\x01", "49709": controller,
        },
        "CheeseFarmERC20": {"48438": controller, "49928": token},
        "CheeseFarmETH": {"48438": controller},
        "CheeseFarmSIMD": {"48438": controller},
    }[contract["name"]]
    references = contract["immutableReferences"]
    require(set(bindings) == set(references), "unexpected release immutable groups")
    code = bytearray.fromhex(contract["deployedBytecode"].removeprefix("0x"))
    require("0x" + keccak(code).hex() == contract["runtimeTemplateKeccak256"], "release template hash mismatch")
    for node, locations in references.items():
        for location in locations:
            offset = location["start"]
            require(location["length"] == 32 and 0 <= offset <= len(code) - 32, "invalid immutable location")
            require(code[offset:offset + 32] == bytes(32), "overlapping or nonzero template immutable")
            code[offset:offset + 32] = bindings[node]
    return bytes(code)


def verify_runtime(contract, code, addresses):
    require(code == expected_runtime(contract, addresses), contract["name"] + " runtime/binding mismatch")
    return "0x" + keccak(code).hex()


class RPC:
    def __init__(self, url):
        require(url.startswith(("http://", "https://")), "HTTP(S) RPC required")
        self.url = url

    def call(self, method, params):
        require(method in {"eth_chainId", "eth_getBlockByNumber", "eth_getCode", "eth_call"}, "read-only method required")
        # Use the same Foundry RPC transport as the audited read-only script.
        # No shell expansion, signer options or ambient wallet configuration are used.
        result = subprocess.run(
            ["cast", "rpc", "--rpc-url", self.url, "--rpc-timeout", "30", "--raw", method, json.dumps(params)],
            text=True, capture_output=True, timeout=40,
        )
        require(result.returncode == 0, "RPC read failed: " + method)
        return json.loads(result.stdout)


def verify_initial_state(rpc, block, addresses):
    def read(name, signature, args=b""):
        selector = keccak(signature.encode())[:4]
        result = rpc.call("eth_call", [{"to": addresses[name], "data": "0x" + (selector + args).hex()}, block])
        return bytes.fromhex(result.removeprefix("0x"))

    def check(name, signature, expected, args=b""):
        require(read(name, signature, args) == expected, name + "." + signature + " initial state mismatch")

    for name in (NAMES[0], *NAMES[2:]):
        check(name, "owner()", word(OWNER))
        check(name, "pendingOwner()", word(0))
    for signature in ("treasury()", "guardian()"):
        check(NAMES[0], signature, word(OWNER))
    for signature in ("token()", "poolCount()", "activated()", "totalMinted()", "emissionsPaused()"):
        check(NAMES[0], signature, word(0))
    check(NAMES[0], "getAllocation()", word(0) + word(0) + word(1000))
    for name in NAMES[2:]:
        for signature in ("registered()", "depositsPaused()", "totalShares()", "totalAssets()", "rewardReserve()", "treasuryOwed()"):
            check(name, signature, word(0))
    check(NAMES[4], "asset()", word(0))
    for signature in ("totalSupply()", "totalMinted()", "totalPreminted()"):
        check(NAMES[1], signature, word(210_000_000 * 10**18))
    check(NAMES[1], "balanceOf(address)", word(210_000_000 * 10**18), word(OWNER))
    check(NAMES[1], "totalBurned()", word(0))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rpc-url", required=True)
    parser.add_argument("--deployment", required=True, type=pathlib.Path)
    parser.add_argument("--block", type=int, help="Block to check; defaults to current latest block.")
    args = parser.parse_args()
    addresses = validate_addresses(json.loads(args.deployment.read_text()))
    rpc = RPC(args.rpc_url)
    require(int(rpc.call("eth_chainId", []), 16) == CHAIN_ID, "Sepolia only")
    require(args.block is None or args.block >= 0, "invalid block")
    header = rpc.call("eth_getBlockByNumber", [hex(args.block) if args.block is not None else "latest", False])
    require(header is not None, "block unavailable")
    block = header["number"]
    contracts = json.loads((ROOT / "release/build-manifest.json").read_text())["contracts"]
    results = []
    for contract in contracts:
        addr = addresses[contract["name"]]
        code = bytes.fromhex(rpc.call("eth_getCode", [addr, block]).removeprefix("0x"))
        runtime_hash = verify_runtime(contract, code, addresses)
        results.append({"contract": contract["name"], "address": addr, "runtimeKeccak256": runtime_hash,
                        "etherscan": "https://sepolia.etherscan.io/address/" + addr + "#code"})
    verify_initial_state(rpc, block, addresses)
    require(rpc.call("eth_getBlockByNumber", [block, False])["hash"] == header["hash"], "block changed during verification; retry")
    print(json.dumps({"status": "PASS_RUNTIME_AND_INITIAL_STATE_ONLY", "chainId": CHAIN_ID,
                      "blockNumber": int(block, 16), "blockHash": header["hash"], "contracts": results,
                      "pending": ["Swarm job and transaction provenance", "connected requester wallet verification",
                                  "explorer source verification", "owner setup and real sIMD verification"]}, indent=2))


if __name__ == "__main__":
    main()
