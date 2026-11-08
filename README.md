# CHEESE V2 — official Sepolia launch preparation

Imported from `konrewz/cheese-vault-v2` at exactly
`65924ab66aa6e2197d9a781220678c29553165cf`. Production Solidity, dependencies,
compiler configuration, original tests and Solidity deployment scripts remain unchanged.
This contribution prepares the five-contract IMD launch; it does not deploy it or
activate emissions. See [the official launch runbook](docs/OFFICIAL_SEPOLIA.md),
[adaptation and audit dispositions](ADAPTATION.md), and
[current check results](release/official-sepolia-checks.json).

Standalone Foundry project. Production Solidity, vendored dependencies, deployment
Solidity scripts, tests, ABIs and compiler settings are byte-identical to tested
commit b8350648a73b8a3c1574a07c429ef1e6a9b0e7f8. Packaging tools and public documents
were updated; no private Git history or raw audit/wallet evidence is included.

The completed isolated Sepolia test used 306 confirmed transactions and 390 passed
steps (including read-only checks), with no reverted broadcasts. It used Mock
SqueekCore and mock assets; this is not proof of completed live real-Core integration.
See release/test-results.json and release/live-test-summary.json for aggregate results.

## Reproduce

Use Foundry 1.8.5 and solc 0.8.26. Dependencies are vendored; no git submodule install
is needed. Exact settings: optimizer 200, viaIR false, Cancun compilation, no CBOR
metadata or bytecode hash. FFI is disabled. With forge/solc available:

```sh
forge build
python tools/verify_release.py --build
forge test --hardfork amsterdam
python tools/retest.py --full
```

The retest tool also accepts FORGE and SOLC executable environment paths. Full
verification checks 189 tests per configuration, extended fuzz, individual invariants
and 118 local unsigned mock actions. It never signs or broadcasts.

## What Swarm should launch

Exactly CheeseEmissionController, CheeseToken, CheeseFarmERC20 (CHEESE asset),
CheeseFarmETH and CheeseFarmSIMD on Ethereum Sepolia. No proxy wrappers or extra
platform token. The controller binds the verified official SqueekCore proxy;
Mining is a read-only issuance oracle. Mock contracts under test/ are not launch targets.
The upstream audited bytecode hashes and immutable locations are in
release/build-manifest.json. The controller and token still match them. The three
farms changed in the launch revision that fixed two reproducible reviewer findings
(retained-fee capture by a just-in-time stake, and just-in-time reward capture); their
current hashes are in release/official-sepolia-checks.json and are asserted by
`FOUNDRY_TEST=checks/launch forge test`. `tools/verify_release.py --build` therefore
reports the three farm hashes as differing from the upstream manifest, by design.
See ADAPTATION.md for the exact changes.

The requester has explicitly approved `0xdea11b3a70b77134424d436f6eb455f1abbd4449`
for Owner, Treasury, Guardian and all three premint recipients. These are now recorded
in `config/deployment-settings.template.json`, together with the exact constructor
order and dependencies. IMD must verify the connected requester wallet before launch.
The real sIMD address remains unverified: deploy its farm unconfigured, and leave
emissions inactive until the owner verifies and sets the asset. There is no root
`launch.json`; the later IMD manifest step writes it from this reviewed configuration.

script/Deploy.s.sol contains the exact tested deployment/wiring helpers. Its run()
reads explicit environment configuration; do not invoke --broadcast during import.
script/VerifySqueekchain.s.sol verifies official bindings. Owner-only wiring is
separate unless the selected Swarm workflow demonstrably supports it with the
requester's authority. Never substitute a deployment agent as permanent Owner.

The source has a 2.1B lifetime mint cap, SQK-matched issuance, 40/20/20/20 allocation
and 15% withdrawal fee. Read docs/SECURITY.md for supported-asset assumptions and
outage accounting. Coverage is measured, not 100% of all branches. Public release
summary excludes private logs, wallet associations, funding records and raw traces.

## Additional launch checks

The new checks live outside the original audited input directories so those files
and their checksum inventory remain intact. Use the project's existing Foundry
configuration and the assignment's seed:

```sh
export FOUNDRY_FUZZ_SEED=0x6f82d1d53b505d6ef746b191e2c3e79934b75cda2ed6635445ac37d7c8f3f8e7
forge build
forge test
python3 tools/verify_release.py --build
FOUNDRY_TEST=checks/launch forge test
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s checks -v
```

The release verifier compares immutable offset groups without treating compiler AST
node numbers as stable identifiers. It also checks all five creation and runtime
template Keccak hashes. The launch rehearsal verifies actual bound runtime values,
including every token permit cache, with the approved owner and Sepolia chain ID.
`tools/verify_deployed.py` provides the corresponding read-only check once IMD
supplies the five confirmed addresses; usage and outstanding gates are in the runbook.
