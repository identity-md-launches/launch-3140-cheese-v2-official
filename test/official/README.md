# Official release test additions

Run the whole suite offline with the existing compiler settings and dependencies:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x6f82d1d53b505d6ef746b191e2c3e79934b75cda2ed6635445ac37d7c8f3f8e7 forge test
```

To run these additions alone, add `--match-path 'test/official/*.t.sol'`.
All new configuration is inline in the test contracts. No installation, FFI, RPC,
fork, environment mutation, filesystem cheatcode, or production change is needed.

Final local result with the seed above (this revision, on the farm with the
retained-fee cap and waiting shares): `forge build` succeeded; `forge test`
reported **234 passed, 0 failed, 0 skipped** across 36 suites. The invariant
campaign completed **256 runs / 16,384 calls / 0 unexpected reverts**, with both
invariants checked together. The repeated-round-trip fuzz test completed 512 cases.

## Revision: farm fixes for findings df1f3c45 and a4e5b610

Another contributor changed `src/CheeseFarm.sol` after this suite was accepted.
Three tests here then failed, all on one handler assertion that the farm keeps
exactly 14% of gross on a non-final exit. The fix intentionally caps that amount, so
the handler now asserts the reviewed rule: retained = min(14% of gross, 15/85 of the
assets backing the remaining shares, priced before the exit). It also checks that
the Treasury receives at least 1% and that the retained part stays in principal.
No other expectation in this directory changed.

`WaitingShareEdges.t.sol` covers waiting-share cases that `test/LaunchFindings.t.sol`
does not:
- shares left unharvested for several epochs earn every later chunk pro rata;
- an account that already earns cannot top up just before a certification and earn
  on the top-up;
- waiting shares activate through a disabled-pool period, with no backdated
  emission;
- principal held in waiting shares is withdrawable immediately;
- a 256-case fuzz over random deposit, exit, claim and certify sequences. It checks
  that pulled rewards equal claims plus reserve, that the reserve is backed, and
  that only rounding dust stays unclaimed.

No defect was found in the revised farm, so no findings file is written. The
documented residual remains: a single staker who splits their own exit recycles
the retained part into their own remaining stake.

## Scope

`ReleaseAdmission.t.sol` brings the existing `checks/launch/OfficialLaunch.t.sol`
checks into the default test directory by inheritance. They compare all five
creation hashes and every runtime byte after checking and clearing the pinned
immutable locations, including the token's EIP-712 caches. They also check the
single-transaction factory rehearsal, approved wallet, three premint events,
initially unconfigured state, allocation after owner setup, runtime limits, and
forbidden opcodes. The additional cases reject nonzero constructor value,
unauthorized setup, and invalid sIMD configuration.

`AtomicRollback.t.sol` checks cross-contract state restoration when a later step
fails: overweight batch after earlier reductions, rejecting pool registration
callback, ETH recipient rejection after reward minting and Treasury payment, and
a token returning false after changing balances and allowance during deposit.
Each test checks a subsequent successful retry or another depositor's exit.

`ReserveSequences.t.sol` / `ReserveHandler.sol` extend the existing invariant
coverage to all three asset adapters, two rotating Treasury recipients, deferred
fees, principal donations, rewards, token transfers and burns. Four actors start
with funded positions in every adapter. There are 256 sequences of depth 64;
unexpected reverts fail the campaign. The withdrawal selector is deliberately
weighted twice. Bounded actions exercise partial/full exits, tiny amounts,
deposit pauses, emission pauses, outages, allocation changes, disabled pools,
and restart after emptying. Repeated round trips also have 512 fuzz cases and
explicit one-wei and maximum generated deposit cases.

The handler derives ghost deposits and payments from actual balance changes.
It keeps principal, deferred fees, donation surplus and reward reserves separate.
Every random sequence ends by withdrawing and claiming all actors while Core
reads fail and the Treasury refuses payment, then rotating to a working Treasury,
paying deferred fees, and skimming donations. A deterministic sequence asserts
that deferred payments, failed deposits, reward payouts and fee recovery were
actually exercised, rather than relying on random selection for coverage.

## Property discovery and grounding

The five Pashov discovery passes and the Trail of Bits review guidance were
applied locally. The following are intended guarantees grounded in the assignment
or accounting identities, not assumptions about how a generic vault should work.

| Discovery pass | Property and implementation under review | Test evidence |
| --- | --- | --- |
| Conservation | Deposits equal remaining principal, deferred fees and actual payouts; donations are separate. `CheeseFarm._deposit`, `withdraw`, `payTreasury`, `skimSurplus`. | Exact cash-flow and custody identities for all adapters; false-return token mutations must roll back. |
| State transitions | Failed operations restore all prior state; completion cannot reopen; new shares cannot inherit past emission. `CheeseEmissionController.addPool`, `batchSetPoolWeights`, `_sync`; `CheeseFarm._deposit`. | Atomic rollback tests, monotonic handler observations, pending rewards before/after fresh positions, completion/burn/outage case. |
| Round trips and rounding | An immediate deposit/withdraw cycle without outside inflow cannot create principal; last exit sends the fee and residual principal to Treasury. `CheeseFarm.withdraw`, `_convertToShares`, `_convertToAssets`. | Random and repeated round trips; explicit one-wei input; gross fee split and final-exit cash flow. |
| Adversarial liveness | A rejecting Treasury or unreadable Core cannot prevent withdrawal of owned shares or claim of already accounted rewards. `CheeseFarm.withdraw`, `claim`, `_tryTransferERC20`; `CheeseEmissionController.pullRewards`. | Random combined outages, exact expected deposit reverts, final drainage of every generated state, subsequent fee recovery. |
| Token and reward protocol | Supply equals all tracked balances; lifetime minted equals supply plus burns; minted rewards are either held or paid; all 1000 points are accounted for. `CheeseToken.mintEmission`, `burn`; controller settlement and allocation. | Closed actor-set balance sums, ghost burns, per-pool reward identities, independent sum of weights. |

Controller accounting has both an upper and a lower bound: minted, pending,
forfeited and reserve emission cannot exceed scheduled emission, and their deficit
is bounded by four wei per observed accounting action plus the initial allowance
for outstanding pool floors. This permits integer dust without concealing lost
emission. Reward liabilities have no rounding tolerance: the sum of pending claims
must fit in the farm reserve plus the controller's pullable amount.

An individual user can earn retained fees (at most 15/85 of their own stake per exit)
from other users' withdrawals; therefore
the suite deliberately does not claim that each user's lifetime principal payouts
are bounded by that user's deposits. The round-trip property excludes intervening
external inflows. Likewise, the suite does not assume unavailable Core history is
snapshotted per departed user: it checks already accounted rewards, reserve backing,
and exclusion of historical emission for new positions.

## Verification limits

The production sources, dependencies, scripts, compiler settings and build
manifest were compared against the archive of
`konrewz/cheese-vault-v2@65924ab66aa6e2197d9a781220678c29553165cf`:
421 files matched, archive SHA-256
`34fe6ea1e0fdc7902a5c6a4f45441b1aaf9c190fe35aa121017bf1c020ff9b90`.
The comparison archive is scratch data and is not required by these tests.
All 461 original audited input checksums remain unchanged. The release artifact
verifier's creation/runtime hashes and immutable offset-group checks also passed.
Its command-line inventory gate freezes the entire original `test/` file list,
so it will flag these authorized test additions as unexpected; this contribution
does not change that gate or the manifest. Original checksums and artifact checks
were verified independently of the file-list equality check.

Local execution used Forge 1.8.3 and solc 0.8.26. The manifest records Forge 1.8.5;
reproduction under that exact Forge executable is not claimed. Production bytecode
and runtime template equality was checked directly with the existing settings.

These are offline tests, not a deployment or live audit attestation. The release
rehearsal uses the official Core address with no code on the local test chain and
leaves sIMD unconfigured and emissions inactive. The behavioral fixtures use
explicit test doubles to exercise failures; their addresses are not deployment
outputs or verified sIMD addresses. They do not authenticate the connected wallet,
verify current proxy implementations, perform explorer source verification, or
produce a Swarm receipt. Those remain the deployment service's release gates.
