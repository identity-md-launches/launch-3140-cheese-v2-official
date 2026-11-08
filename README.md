# CHEESE V2 — tested source for IMD Swarm GitHub import

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
All five bytecode hashes and immutable locations are in release/build-manifest.json.
The audited contract bytecode templates must not change during import/adaptation.

Configuration is intentionally unresolved in config/deployment-settings.template.json.
Owner must be controlled by the Swarm requester. Treasury, Guardian, three immutable
premint recipient choices and real non-rebasing sIMD require explicit confirmation.
There is no root launch.json: the earlier version silently assigned Treasury and
all premints to Owner. This package removes those unapproved defaults. Swarm must
resolve a reviewed constructor manifest without changing production Solidity.

script/Deploy.s.sol contains the exact tested deployment/wiring helpers. Its run()
reads explicit environment configuration; do not invoke --broadcast during import.
script/VerifySqueekchain.s.sol verifies official bindings. Owner-only wiring is
separate unless the selected Swarm workflow demonstrably supports it with the
requester's authority. Never substitute a deployment agent as permanent Owner.

The source has a 2.1B lifetime mint cap, SQK-matched issuance, 40/20/20/20 allocation
and 15% withdrawal fee. Read docs/SECURITY.md for supported-asset assumptions and
outage accounting. Coverage is measured, not 100% of all branches. Public release
summary excludes private logs, wallet associations, funding records and raw traces.
