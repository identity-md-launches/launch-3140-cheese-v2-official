# CHEESE V2 official Sepolia adaptation

The approved source is `konrewz/cheese-vault-v2` at exactly
`65924ab66aa6e2197d9a781220678c29553165cf`. Downloading that commit's archive and
comparing all 482 files found no differences at import. The archive SHA-256 was
`34fe6ea1e0fdc7902a5c6a4f45441b1aaf9c190fe35aa121017bf1c020ff9b90`.

**No production Solidity, constructor, economic behavior, dependency, compiler
setting, original Solidity test, ABI, or Solidity deployment script changed.**
All 461 original audited input checksums still match. All five creation and runtime
template hashes match the release. No launch manifest, wrapper, proxy, platform
token, deployment transaction or ownership change was created.

The five constructors already satisfy the factory: static address arguments,
nonpayable, no external calls or code-existence requirements, explicit owners,
backward deployment dependencies, bounded init/runtime sizes, and no reachable
forbidden escape opcodes. Owner-only setup is intentionally deferred by the
specific brief. The generic fully-configured-at-construction guidance does not
justify changing this exact release's bytecode or circular wiring.

## Changes and reasons

| File | Change | Why required |
|---|---|---|
| `config/deployment-settings.template.json` | Filled the explicitly approved Owner, Treasury, Guardian and all premint recipients; recorded commit, Sepolia, zero constructor value, five ordered constructors, no activation, and unverified sIMD. | The old public template had unresolved roles. This brief supplies every role address, so no worker or factory default is needed. `realSIMDAsset` remains null because the brief explicitly permits one-time owner configuration later. This is review data, not `launch.json`. |
| `tools/verify_release.py` | Compare complete immutable offset/length groups independently of compiler AST IDs; also check creation/runtime Keccak hashes, lengths and absence of library links. Expose importable functions for regression tests. | The unchanged release built successfully and produced exact bytes, but the original verifier rejected different compilation-local AST IDs. For example, controller node `46222` became `51645` while its offsets stayed `(1885,32)` and `(10855,32)`. Renumbering is not bytecode drift. Missing, changed, duplicated or split groups still fail. No hash or original input check was relaxed. |
| `checks/test_release_verification.py` | Regression tests for the reproduced verifier failure, all five real artifacts, changed code, changed offsets/lengths and missing/duplicate/split groups. | Demonstrate that the portability correction accepts identical builds while still rejecting bytecode or immutable-layout drift. |
| `checks/launch/OfficialLaunch.t.sol` | Single-call CREATE2 factory rehearsal, approved roles and premint events, initial and owner-configured state, exact five creation hashes, actual runtime bindings, runtime size/opcode checks. | Verify factory compatibility without changing production code, touching a live Core, substituting deployment roles or activating the release. Runtime checks include all ERC20Permit cached fields, not just the public dependency getters. Correct the audit's overbroad pre-setup deposit claim. |
| `checks/launch/ImportedAudit.t.sol` | Executable reproductions of the supplied owner-allocation, dust-holder, certification-timing, sIMD forfeiture and ownership-renunciation scenarios; test the deferred-activation sequence. | Record the real limits of this exact release and verify the permitted procedural mitigation for unconfigured sIMD. Risk-reproduction tests do not claim the underlying behavior was removed. |
| `checks/integration/OfficialCore.t.sol` | Optional Sepolia fork tests using the actual Core, original dependency-verification script, activation clock and historical roundPage decoding/checkpoint behavior. | Exercise real-Core compatibility without mocks, broadcasts or Core writes. Kept separate from the offline test suite. Changing the local fork timestamp in one test only rehearses earlier activation using actual certified history. |
| `tools/verify_deployed.py` | Read-only, Sepolia-only verification tool for the five confirmed addresses IMD will supply. Patches pinned runtime templates with all real immutable values and checks initial roles, supply, combined premint balance and unconfigured state at a specified block. | Live address-dependent runtime hashes cannot be invented before IMD deploys. This gives the deployer an executable check, including EIP-712 caches and reorg detection, and reports the checks it does not perform. No wallet access, signing or transaction RPC methods exist. |
| `checks/test_deployed_verification.py` | Offline tests rejecting mutated/empty runtime, dependency substitution, bad immutable metadata, missing/duplicate/zero/dependency addresses and signing/broadcast methods. | Exercise the verifier's fail-closed behavior without presenting synthetic test fixtures as deployment addresses. |
| `docs/OFFICIAL_SEPOLIA.md` | Exact constructors and owner-only Etherscan sequence, deployment and activation gates, sIMD handling, unchanged fee/reward semantics, explicit pending receipt fields. | Fulfill the official launch handoff without claiming wallet authentication, deployed contracts, verified sources or operational readiness. All six roles use the requester's approved address. |
| `release/official-sepolia-checks.json` | This contribution's import, build, test, hash, live dependency and audit result summary; unavailable deployment fields remain pending. | Separate current checks from the upstream mock-release summaries without altering historical evidence. |
| `README.md` | Identify the exact imported commit and approved roles; link the official runbook and add reproducible offline verification commands. | Remove stale statements that the newly supplied roles are still undecided, while retaining the original release evidence. |
| `ADAPTATION.md` | This change and audit-disposition record. | Required acceptance deliverable. |

New Solidity checks are in `checks/`, not in the original checksummed `test/`
directory. Run them with `FOUNDRY_TEST=checks/launch`; the production compiler
settings and dependencies remain the project's own. No added dependency or network
fetch is needed for build or offline tests. `test/scratch/` is not part of this
deliverable.

## Supplied audit: reproduction and disposition

1. **`3079d0db...` — medium, pending owner wiring.** Reproduced: a fresh launch has
   no bound token or registered pools, `(0,0,1000)` allocation and no activation.
   `activate` before binding fails. Approved owner calls bind the token and register
   400/200/200 points, giving `(800,0,200)` without activation. A wrong sIMD contract
   with code is accepted once and cannot be replaced. **The blanket assertion that
   all unregistered deposits revert does not reproduce:** CHEESE and ETH deposits
   succeed and earn no emission; unconfigured sIMD deposits revert. Premints and
   farm/controller/token immutable linkage already exist before owner setup.
   Tests: `test_noAutomaticSetupOrActivation`,
   `test_onlyRequesterCanPerformPendingSetup`,
   `test_unregisteredCheeseAndEthDepositsDoNotRevertOrEarnRewards`, and the sIMD
   audit test. Mitigation: exact pending checklist, verify before write-once calls,
   and no operational-readiness claim. Post-deploy wiring remains by explicit request.

2. **`b6804f6d...` — low, owner-directed pool emission.** Reproduced in
   `test_auditOwnerCanRouteOnlyProspectiveScheduledEmission`: the owner's registered
   sink with 800 points receives `117586262400352419921864` base units after 40
   certified blocks. Direct owner `mintEmission` fails, pulling again yields zero,
   and total minting stays within scheduled emission. This is a material owner trust
   power, not unrestricted minting or a cap bypass. Retained because the brief
   permits new pools and prospective allocation and fixes both source and owner.
   The runbook requires reviewing every future admitted pool. No unrequested
   allowlist, timelock or alternate owner was introduced; this low risk remains.

3. **`6c2c281a...` — low, retained-fee capture.** Reproduced in
   `test_auditOneWeiStakeReceivesRetainedFeeAndFinalDustGoesToTreasury`: after a
   1000 ETH exit, a 1-wei holder has gross assets `70000000000000000001` wei,
   receives `59500000000000000001` wei on exit, and Treasury receives
   `80500000000000000000` wei on that final exit. The farm ends with no principal
   or residual balance. This follows the required 14% retention and immediate exit
   rules; no accounting invariant or fee split is violated. No minimum stake,
   cooldown or age weighting was added. The incentive/MEV risk remains documented.

4. **`b7a8c26e...` — low, just-in-time staking.** Reproduced in
   `test_auditJustInTimeStakeSharesNextCertification`: Bob earns nothing from the
   already certified round but receives `14698282800044052490233` CHEESE base units
   from the next certification, and withdraws 8.5 ETH from a 10 ETH deposit.
   Rewards use the shares present at certified issuance, not elapsed holding time.
   This is consistent with the requested Core clock and no-cooldown design.
   Time weighting would change the audited economics and bytecode; the risk remains.

5. **`95692ccb...` — low, unconfigured sIMD forfeiture.** Reproduced in
   `test_auditUnconfiguredSIMDForfeitsAndCannotRepairWrongAsset`: premature activation
   followed by any account's claim forfeits `29396565600088104980466` CHEESE base
   units for the unconfigured 200-point pool; nothing is minted. **Procedural
   correction:** preserve the required 200 points but do not activate until verified
   real sIMD has been set. `test_runbookDefersActivationUntilAssetVerifiedAndNeverReopensHistory`
   shows the waiting period has no emission, minting or forfeiture and that its old
   blocks become the excluded start anchor. No substituted asset, automatic
   activation, retroactive reward credit or changed allocation was introduced.
   Premature activation remains possible on chain and is prohibited by the runbook.

6. **`fbf13c63...` — low, ownership renunciation after pause.** Reproduced in
   `test_auditRenounceAfterPauseIsIrrecoverableButWithdrawalWorks`: renunciation
   leaves pause permanent, rejects new deposits, and still lets the existing
   depositor withdraw 85%. The exact audited Ownable implementation still exposes
   `renounceOwnership`; overriding it would violate the explicit bytecode constraint.
   Mitigation is the requested operational prohibition: never renounce on any of
   the four owned contracts. No ownership was renounced or transferred by this work.

All six reports' core observations reproduce. The overbroad deposit statement in
the first report is the exception described above. None of these reports alleges
an unresolved critical/high defect. No new critical/high defect was identified
in this bounded review, which is not a replacement for IMD's independent audit.
Production changes that would remove these requested design/trust behaviors were
not made. The verifier's AST-ID portability bug is the reproduced implementation
defect corrected by this contribution.

## Verification and limits

Use `release/official-sepolia-checks.json` for counts, exact hashes and the public
Sepolia block identity. `forge build` and the original 189 tests passed with
`FOUNDRY_FUZZ_SEED=0x6f82d1d53b505d6ef746b191e2c3e79934b75cda2ed6635445ac37d7c8f3f8e7`.
The original suite also passed with Amsterdam execution and transaction isolation.
The release compiles for Cancun in both cases. Additional checks cover the exact
factory launch and the verification utilities. All original production bytecodes
and immutable offset groups match, and local runtime code was compared after
checking every immutable value.

Installed Forge was 1.8.3, while the release records 1.8.5. Solc and compiler
settings match exactly and all bytecode hashes agree; exact 1.8.5 execution was
not claimed. Slither/Mythril were not run. Forge lints include warnings in original
code and fixtures; a pattern warning is not reported as an independently reproduced
vulnerability. The independent review and exact release-toolchain reproduction
remain admission gates.

The official manifest and both published interface subsets matched the compiled
interfaces. The unchanged read-only Squeekchain script passed against the actual
Sepolia proxies at block 12089271, checking implementation slots/runtime hashes,
clock constants, schedule boundaries and minted issuance. Such a snapshot cannot
guarantee future proxy implementations. Recheck before deployment and activation.
The Blockscout implementation source API returned HTTP 403 for both implementations;
that source-verification attempt is explicitly unverified, not a pass.

This worker did not have an authenticated connected-requester wallet or an IMD
deployment receipt. Those are later launch checks; the owner address itself is
already specified and is not missing input. Real sIMD is deliberately owner-settable
and unconfigured, so it also does not require a guessed constructor value. No
requester-only missing constructor value blocks this source adaptation.

Swarm Job URL, five new addresses, transaction hashes, live premint balances,
deployed runtime evidence and explorer source-verification status remain pending
IMD deployment. They have not been invented, copied from V1 or copied from local
tests. No operational-readiness claim is made.
