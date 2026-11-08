# CHEESE V2 official Sepolia adaptation

The approved source is `konrewz/cheese-vault-v2` at exactly
`65924ab66aa6e2197d9a781220678c29553165cf`. Downloading that commit's archive and
comparing all 482 files found no differences at import. The archive SHA-256 was
`34fe6ea1e0fdc7902a5c6a4f45441b1aaf9c190fe35aa121017bf1c020ff9b90`.

**Revision.** The first round changed no production Solidity. An independent reviewer
then reproduced two defects in `src/CheeseFarm.sol` with Foundry proofs that failed on
that tree, and the acceptance criteria allow behaviour changes where a reproduced
finding requires one. This revision fixes exactly those two, in the shared farm base
(so all three farms), and nothing else in `src/`. `CheeseEmissionController` and
`CheeseToken` are byte-identical to the audited release; the three farms are not, by
design, and their new hashes are recorded in `release/official-sepolia-checks.json`
and asserted by `checks/launch/OfficialLaunch.t.sol`. `release/build-manifest.json`
stays as the upstream record, so `tools/verify_release.py --build` reports the three
farm hashes as changed.

Constructors, constructor arguments, dependencies, compiler settings, the deployment
scripts, ABI of every existing function, the owner model and the economics outside the
two fixed paths are unchanged. No proxy, wrapper, platform token, manifest, deployment
transaction or ownership change was created.

## Changes in this revision and why

| File | Change | Why required |
|---|---|---|
| `src/CheeseFarm.sol` | **Retained-fee cap.** `_retainedFor()` (used by `withdraw` and `previewWithdraw`): the 14% that stays in the farm is capped at 15/85 of the assets backing the remaining shares; the excess goes to the Treasury with the 1%. Last-depositor sweep unchanged. | Finding `df1f3c45` (high): a dust deposit mined just ahead of a dominant exit inherited the retained 14% and left with 85% of it (proof: Treasury 0.311 ETH instead of 1.5 ETH, attacker +1.19 ETH). 15/85 is exactly what a remaining stake will itself pay the Treasury on exit, so no stake can net more than its own Hamster Bite from another's exit (0.85 × (1 + 15/85) = 1), whatever block it arrived in. A same-block exclusion was rejected: a front-runner deposits one block earlier. |
| `src/CheeseFarm.sol` | **Waiting shares.** New `activeShares`, `rewardEpoch`, `waitingSharesOf()`. Shares deposited into a farm that already has stakers earn nothing until the next pull that priced new Squeek blocks (detected through `controller.emissionPerPoint()`); chunks are spread over `activeShares` only and waiting shares start at the accumulator value recorded when their epoch ended. The first stake into an empty farm earns immediately. A pull with no active shares forfeits through the controller exactly as an empty farm does and still activates the waiting shares. Withdrawals burn waiting shares first and are never delayed. `pendingRewards` mirrors the rule. | Finding `a4e5b610` (medium): a deposit mined just before the Reporter's settle tx earned a full pro-rata share of the round for a 15% exit fee (proof: attacker +14,396 CHEESE, honest staker halved). The brief forbids a cooldown on principal; this delays only reward eligibility by one certification. |
| `src/interfaces/ICheeseEmissionController.sol` | Declares `emissionPerPoint()`, which the controller already exposes. | The farm needs it to detect a priced pull. No controller change. |
| `test/CheeseBase.t.sol` | `warmUp(farm)` and `warmBlock(weight)` helpers. | Tests that stake a second account and certify in the same block now need one priced pull before the second stake earns. |
| `test/Farm.t.sol`, `test/FarmFuzz.t.sol`, `test/Adversarial.t.sol`, `test/independent/AccountingEdges.t.sol` | Ten tests that encoded same-block reward attribution get a warm-up block and adjusted expectations; two fee tests compute the capped retained share; the dust bound in `test_everyAccountCanClaimAfterEmissionEnds` rises from 16 to 24 wei because activation rounds a second baseline. Each edit is commented in place. | A test that encodes the fixed behaviour is changed with it. |
| `test/LaunchFindings.t.sol` | Eleven regression tests: both reviewer scenarios, the cap formula and its non-binding case, the last-depositor sweep, a fuzz that a zero-duration stake never profits from any exit split, activation after one priced pull, a forfeited pull activating waiting shares, the empty-farm case, burn order, and view/claim agreement with waiting shares. | Every change is tested. |
| `checks/launch/OfficialLaunch.t.sol`, `checks/launch/ImportedAudit.t.sol`, `release/official-sepolia-checks.json` | New farm creation and runtime-template hashes and immutable offsets; the two audit-reproduction tests now assert the fixed behaviour. | Keep the launch rehearsal and the revision's check record truthful. |
| `docs/OFFICIAL_SEPOLIA.md`, `docs/SECURITY.md`, `README.md` | Describe the two rules, the residual, and the farm hash change. | Handoff accuracy. |
| `.imd-responses.json` | Verdict and detail for every reviewer finding. | Required by the revision. |

## Reviewer findings: disposition

* **`df1f3c45` high — fixed** (above). Proof passes.
* **`a4e5b610` medium — fixed** (above). Proof passes.
* **`539a3803` low, sub-wei fee rounding — not changed.** Reproduces arithmetically, but
  the value is below 1 wei per withdrawal on 18-decimal assets and the reviewer classes
  it as precision, not loss. Rounding the Treasury share up would alter every
  withdrawal's 85/14/1 arithmetic for unexploitable amounts.
* **`2197bcb8` low, renounceOwnership — not changed.** Reproduced in the first round
  (`fbf13c63`). Owner-key trust assumption the brief handles procedurally; enforcing it
  would change the controller's bytecode beyond what the reproducible findings require.
  A one-line override per contract if the requester wants it on chain.
* **`597c8c76` low, mis-sent tokens unrecoverable — not changed.** Reproduces; no staker
  or Treasury funds at risk. A token sweep is a new owner power for the requester to
  decide on.
* **`c0d32533`, `ca069752`, `c9f8e956` info — acknowledged**, already documented
  (`docs/SECURITY.md` items 2, 11, 16; schedule total mirrors SqueekMining).

## Residual after the fixes

A single staker who splits their own exit into many withdrawals still recycles the
retained share into their own remaining position: the cap binds on the inheriting
stake, and the withdrawer's own remaining stake is large in that case. This is
inherent to redistributing a fee to remaining stakers, was not reported, and the
Treasury's 1% plus the final exit's full 15% are the guarantees that survive it.

Reward attribution is now at most one certification late for an honest mid-round
depositor instead of up to one certification early for a zero-duration one.

## First-round changes (unchanged in this revision)

| File | Change | Why required |
|---|---|---|
| `config/deployment-settings.template.json` | Filled the approved Owner, Treasury, Guardian and premint recipients; recorded commit, Sepolia, zero constructor value, five ordered constructors, no activation, unverified sIMD. | The brief supplies every role address. `realSIMDAsset` stays null: the brief permits one-time owner configuration later. Not `launch.json`. |
| `tools/verify_release.py` | Compare immutable offset/length groups independently of compiler AST IDs; keep hash, length and link checks. | The original verifier rejected identical bytecode over renumbered AST IDs. |
| `checks/test_release_verification.py`, `checks/test_deployed_verification.py` | Regression tests for the verifiers. | Fail-closed behaviour without synthetic deployment addresses. |
| `checks/launch/OfficialLaunch.t.sol` | Single-call CREATE2 factory rehearsal, approved roles and premint events, exact creation hashes, runtime bindings, size and opcode checks. | Factory compatibility without touching a live Core or activating. |
| `checks/launch/ImportedAudit.t.sol` | Executable reproductions of the imported audit's scenarios and the deferred-activation sequence. | Record the limits of the release. |
| `checks/integration/OfficialCore.t.sol` | Optional Sepolia fork tests against the real Core. | Real-Core compatibility without mocks or broadcasts. |
| `tools/verify_deployed.py` | Read-only verification tool for the five addresses IMD will supply. | Live runtime hashes cannot be invented before deployment. |
| `docs/OFFICIAL_SEPOLIA.md` | Constructors, owner-only Etherscan sequence, gates, pending receipt fields. | Launch handoff without readiness claims. |
| `release/official-sepolia-checks.json`, `README.md` | Check summary; imported commit and approved roles. | Separate current checks from upstream evidence. |

## Imported audit: reproduction and disposition

1. **`3079d0db` medium, post-deploy owner wiring.** Reproduced. The brief itself
   requires the owner-only sequence and the controller/token/farm references are
   circular, so constructors cannot carry them. Procedural: exact pending checklist, no
   readiness claim. The blanket claim that all unregistered deposits revert did not
   reproduce (CHEESE and ETH deposits succeed and earn nothing; sIMD reverts).
2. **`b6804f6d` low, owner-directed pool emission.** Reproduced; prospective and
   schedule-bounded; the brief permits new pools and allocation changes. Trust
   assumption, unchanged.
3. **`6c2c281a` low, retained-fee capture by a dust stake.** Reproduced; **now fixed**
   by the retained-fee cap (same root cause as `df1f3c45`): a 1-wei stake backs a cap
   of 0, so a 1000 ETH exit sends the full 150 ETH to the Treasury
   (`test_auditOneWeiStakeReceivesRetainedFeeAndFinalDustGoesToTreasury`).
4. **`b7a8c26e` low, just-in-time stake around a certification.** Reproduced; **now
   fixed** by waiting shares (same root cause as `a4e5b610`): the late stake earns
   nothing from the certification it front-runs
   (`test_auditJustInTimeStakeSharesNextCertification`).
5. **`95692ccb` low, unconfigured sIMD forfeiture.** Reproduced; procedural: do not
   activate until the verified sIMD is set. Unchanged.
6. **`fbf13c63` low, renounce after pause.** Reproduced; procedural prohibition.
   Unchanged (see `2197bcb8`).

## Verification and limits

`forge build` passes. `forge test` with
`FOUNDRY_FUZZ_SEED=0x6f82d1d53b505d6ef746b191e2c3e79934b75cda2ed6635445ac37d7c8f3f8e7`:
201 tests pass in `test/` (190 original and adjusted, 11 new), plus both reviewer
proofs copied under `test/scratch/`. `FOUNDRY_TEST=checks/launch forge test`: 14
pass. Forge 1.8.3 (release records 1.8.5); solc and settings identical. Slither and
Mythril were not run.

The unchanged read-only Squeekchain script passed against the Sepolia proxies at
block 12089271 in the first round; recheck before deployment and activation. No
connected-requester wallet, Swarm job URL, deployed addresses, transaction hashes,
live premint balances or explorer verification exist yet: they are IMD's deployment
outputs and have not been invented. No operational-readiness claim is made.
