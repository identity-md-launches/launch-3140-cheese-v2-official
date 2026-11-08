"""Verify audited inputs and compiler output offline; never access a wallet."""

import argparse
import hashlib
import json
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]


def immutable_offsets(references):
    """Ignore compilation-local AST IDs; retain offset/length groups and multiplicity."""
    return sorted(
        sorted((location["start"], location["length"]) for location in locations)
        for locations in references.values()
    )


def verify_artifact(contract, artifact):
    for key, keccak_key in (
        ("bytecode", "creationKeccak256"),
        ("deployedBytecode", "runtimeTemplateKeccak256"),
    ):
        value = bytes.fromhex(artifact[key]["object"].removeprefix("0x"))
        assert hashlib.sha256(value).hexdigest() == contract[key + "Sha256"], contract["name"] + " " + key
        assert len(value) == contract[key + "Bytes"], contract["name"] + " " + key + " length"
        actual_keccak = subprocess.check_output(["cast", "keccak", "0x" + value.hex()], text=True).strip()
        assert actual_keccak == contract[keccak_key], contract["name"] + " " + keccak_key
        assert not artifact[key].get("linkReferences"), contract["name"] + " requires linking"
    assert immutable_offsets(artifact["deployedBytecode"]["immutableReferences"]) == immutable_offsets(
        contract["immutableReferences"]
    ), contract["name"] + " immutable offsets"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--build", action="store_true")
    args = parser.parse_args()
    manifest = json.loads((ROOT / "release/audited-inputs.json").read_text())
    expected = {entry["path"] for entry in manifest["files"]}
    actual = set()
    for folder in ["src", "test", "script", "lib", "web/abi"]:
        actual.update(str(path.relative_to(ROOT)).replace("\\", "/") for path in (ROOT / folder).rglob("*") if path.is_file())
    actual.update(["foundry.toml", "remappings.txt"])
    assert actual == expected, {"missing": sorted(expected - actual), "unexpected": sorted(actual - expected)}
    for entry in manifest["files"]:
        assert hashlib.sha256((ROOT / entry["path"]).read_bytes()).hexdigest() == entry["sha256"], entry["path"]
    print(f"PASS: {len(expected)} audited input files match; production source, dependencies and deployment scripts unchanged.")
    if args.build:
        build = json.loads((ROOT / "release/build-manifest.json").read_text())
        for contract in build["contracts"]:
            artifact = json.loads((ROOT / "out" / contract["artifact"]).read_text())
            verify_artifact(contract, artifact)
            print("PASS:", contract["name"], contract["creationKeccak256"])
        print("PASS: five creation bytecodes, runtime templates and immutable offset groups match the release.")
        print("Runtime values still require deployment-specific verification; template equality alone does not prove bindings.")


if __name__ == "__main__":
    main()
