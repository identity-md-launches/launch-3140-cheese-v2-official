# CHEESE V2 — official Sepolia handoff

Status: **prepared, not deployed or operational**. No signatures, transactions,
ownership handovers, asset configuration or activation have been performed by this
contribution. Existing mock release results are historical evidence only.

Source: [konrewz/cheese-vault-v2 at the approved commit](https://github.com/konrewz/cheese-vault-v2/tree/65924ab66aa6e2197d9a781220678c29553165cf).
All 482 upstream files matched at import. Production source, vendored dependencies,
compiler configuration, Solidity deployment scripts and original tests remain exact.
The 461-file audited input inventory still passes. Changes are listed in `ADAPTATION.md`.

## Constructor plan

Ethereum Sepolia only, chain ID **11155111**. All constructors are nonpayable and
receive **0 wei**. Deploy exactly the following five contracts in this order,
through IMD's application-contract factory, without initialization calls.

`O` means the explicitly approved address
`0xdea11b3a70b77134424d436f6eb455f1abbd4449` for all six roles.
`C`, `T`, `F_CHEESE`, `F_ETH` and `F_SIMD` mean the **new addresses from this
launch**, not previously deployed contracts or locally simulated addresses.
`CORE` is `0xfd6c166d4b8e2962e65746a13e5a0797cd4de0c4`.

| Order | Contract | Exact constructor signature | Values, in declaration order |
|---|---|---|---|
| 1 | CheeseEmissionController (`C`) | `(address owner_, address squeekCore_, address treasury_)` | `O, CORE, O` |
| 2 | CheeseToken (`T`) | `(address teamRecipient_, address treasuryRecipient_, address liquidityRecipient_, address emissionAuthority_)` | `O, O, O, C` |
| 3 | CheeseFarmERC20 (`F_CHEESE`) | `(address owner_, address controller_, address asset_)` | `O, C, T` |
| 4 | CheeseFarmETH (`F_ETH`) | `(address owner_, address controller_)` | `O, C` |
| 5 | CheeseFarmSIMD (`F_SIMD`) | `(address owner_, address controller_)` | `O, C` |

Controller Guardian defaults to `O`. The token has no owner; only `C` can mint
emission. The four Ownable contracts belong to `O` immediately, with no factory
handover or acceptance step. All dependencies point backward in deployment order.
No extra token, reserve contract, proxy, wrapper or mock is a launch target.

The exact signatures and explicit static values are also recorded in
`config/deployment-settings.template.json`. Its `$contract:Name` entries are
dependency references for IMD to resolve, not substitute addresses. The later
manifest step owns `launch.json`.

`script/Deploy.s.sol` is preserved unchanged. Its `deployContracts` helper describes
the five creations. Its `run`/`deploy`/`wire` paths also perform configuration and
may activate according to their arguments; they are **not** this factory launch
workflow. Do not broadcast them as a substitute for IMD.

## Gates before any deployment

1. IMD must confirm its authenticated, connected requester wallet is exactly `O`
   on Sepolia. An address appearing in this file or a blockchain balance is not
   proof of wallet control. This worker has no connected-wallet attestation.
2. Reproduce the build with the unchanged `foundry.toml`: solc
   `0.8.26+commit.8a97fa7a`, optimizer 200, viaIR false, Cancun compilation,
   bytecode hash none, CBOR metadata false. The release records Forge 1.8.5;
   local verification used Forge 1.8.3 and produced identical bytecode. Exact
   Forge 1.8.5 reproduction remains an admission check, not a claimed result.
3. Run `forge build`, `forge test` with the recorded assignment seed, and
   `python3 tools/verify_release.py --build`. Run the additional offline checks
   from the README. All five creation bytecodes, runtime templates and immutable
   offsets must match `release/build-manifest.json`. The eventual runtime bytes
   must match after substituting **all** deployment-specific immutables.
4. Recheck the official [Squeekchain deployment manifest](https://docs.squeekchain.com/assets/deployments/sepolia.json),
   both proxy implementation slots and implementation runtime hashes, published
   ABIs, Core clock, and Mining schedule. Run the unchanged read-only
   `script/VerifySqueekchain.s.sol` immediately before deployment and activation.
   Mining `0x2dccb11fcc2defdd188555e45acb52231e82e218` is only a schedule reference;
   never configure, deploy or mutate Squeekchain contracts.
5. IMD's independent security review, source verification and factory simulation
   must pass. Any bytecode drift, failed test, failed source/dependency verification,
   or unresolved critical/high issue blocks deployment. Local tests do not attest
   these independent gates. Explorer API inspection of the existing implementations
   returned HTTP 403 here; explorer verification was not established by that request.

Read-only dependency check (supply an approved public Sepolia RPC as `SEPOLIA_RPC`):

```sh
forge script script/VerifySqueekchain.s.sol:VerifySqueekchain --rpc-url "$SEPOLIA_RPC"
```

For the optional live-Core fork rehearsal, which never broadcasts:

```sh
FOUNDRY_TEST=checks/integration forge test --match-contract OfficialCoreCompatibilityTest \
  --fork-url "$SEPOLIA_RPC" --fork-block-number 12089271
```

The recorded block is reproducibility evidence, not a substitute for checking the
latest state before launch. The optional fork suite is excluded from offline tests.

## Owner-only Etherscan setup, after IMD deployment

Use **Sepolia Etherscan**, starting from the five confirmed addresses and receipts
in the IMD launch handoff. For each address open `Contract`, confirm verified source,
then use `Read Contract` and, for the actions below, `Write Contract` → `Connect to
Web3`. Confirm the connected wallet is `O` and the network is Sepolia for every
transaction. No Swarm agent or worker wallet may substitute for `O`.

1. **Verify before writing.** Compare all five new addresses, transaction receipts,
   constructor arguments, zero constructor value and source verification against
   the approved release. Verify runtime bytes and immutable bindings:
   `C.squeekCore() = CORE`; `T.emissionAuthority() = C`; each farm's `controller()`
   and `emissionController()` equal `C`; `F_CHEESE.asset() = T`.
   Verify `owner() = O` and empty `pendingOwner()` on all four owned contracts;
   `C.treasury() = O`, `C.guardian() = O`. The token is CHEESE/CHEESE, 18 decimals.
   Check its constructor `Transfer` logs: 63M team + 63M treasury + 84M liquidity,
   all to `O`. Their combined initial `balanceOf(O)`, `totalSupply()`, `totalMinted()`
   and `totalPreminted()` must be `210000000000000000000000000`, with
   `totalBurned() = 0`. Lifetime cap is `2100000000000000000000000000`; mining
   allowance is `1890000000000000000000000000`. Burns do not restore allowance.

   Before setup, `C.token()` is unset, `poolCount() = 0`, `activated() = false`,
   `getAllocation() = (0,0,1000)`, and all farms are unregistered. `F_SIMD.asset()`
   is unset and deposits revert. CHEESE/ETH deposits can already succeed without
   rewards; do not advertise operational readiness or invite deposits yet.

   To check all runtime bytes and this initial state at the deployment block,
   put only IMD's confirmed five addresses into a JSON object keyed by the Solidity
   names in the constructor table, then run:

   ```sh
   python3 tools/verify_deployed.py --rpc-url "$SEPOLIA_RPC" \
     --deployment confirmed-addresses.json --block "$DEPLOYMENT_BLOCK"
   ```

   This command is read-only and checks Sepolia explicitly. It verifies every
   immutable, including token EIP-712 chain ID, token address, domain separator,
   name and version caches. It checks **unconfigured initial state** and will
   reject a later configured state; use the original deployment block after setup.
   It does not authenticate the connected wallet, validate job provenance, inspect
   constructor event receipts, or perform explorer source verification.
2. On `C`, call **`bindToken(T)`** once. Read `token()` back and confirm `T`.
   Binding is irreversible. A second call must not be attempted.
3. On `C`, call **`setTreasury(O)`** and **`setGuardian(O)`** only if a verified
   read shows either differs. Both should already equal `O` from construction.
4. On `C`, call **`addPool(F_CHEESE,400)`**, **`addPool(F_ETH,200)`**, and
   **`addPool(F_SIMD,200)`**, in that order. Check the resulting IDs 0, 1 and 2,
   each farm's registration and the matching `getPoolAllocation` records. Do not
   repeat a registration that is already confirmed.
5. Verify **`getAllocation() = (800,0,200)`**: enabled weight 800, disabled weight 0,
   and unassigned reserve 200. No fourth pool is registered. Reserve emission is
   unminted and never redistributed retroactively. `activated()` must still be false.
   The sIMD pool is registered with 200 points but cannot take deposits until its
   asset is set; global emission remains inactive.
6. **Keep activation pending until real sIMD is verified.** Verify the actual
   Sepolia sIMD contract's identity, source, ABI and non-rebasing behavior; a symbol
   or nonempty code alone is insufficient. Only then use `F_SIMD.setAsset(realSIMD)`
   from `O` and confirm `asset()`. The call is write-once. Never use CHEESE, a mock,
   a guessed address or another token as sIMD. No asset address is supplied by this
   contribution. If sIMD cannot yet be verified, leave `setAsset` **and activation**
   pending. Do not change the requested 400/200/200 allocation to work around it.
7. Repeat the real-Core identity/ABI/clock and Mining schedule checks, confirm all
   setup transactions and required verifications, then—and only then—`O` may call
   **`C.activate()`**. Check the `Activated` event and `startRound()` for the next
   full Squeek round. Verify the initial height anchor excludes historical blocks.
   This action is never automatic and remains pending in this handoff.

Never call `renounceOwnership` on any contract. The inherited function exists;
renouncing controller ownership after a pause permanently removes the ability to
unpause or administer pools. There is no recovery, proxy or upgrade path.

If Swarm cannot perform an owner-only call, it remains pending for `O`. Do not
transfer ownership to an agent to get through setup. Future weight changes and new
pools require the owner and a successful checkpoint; they affect future allocation
only. The owner's ability to admit arbitrary pools is a documented trust assumption.

## Withdrawal and reward behavior retained

Deposits have no fee. Withdrawals immediately return 85% of gross compounded
principal, retain 14% for remaining shares and send 1% to Treasury, with integer
rounding as in the audited source. When the last shares leave, the full 15% fee
and residual principal dust go to Treasury. Shares are nontransferable and rewards
are claimed separately. Treasury push failure defers its payment without blocking
the user's payout. Core outages preserve withdrawal availability and known rewards;
deposits wait for synchronization. Unreadable, unaccounted emission does not have
historical share snapshots. See `docs/SECURITY.md` and `ADAPTATION.md` for the
retained-fee, certification-timing and owner-control limitations.

## Deployment receipt deliverables

| Requested item | Current status |
|---|---|
| Swarm Job URL | Not supplied by this worker context; pending IMD handoff. No URL inferred from a task ID. |
| Imported commit | `65924ab66aa6e2197d9a781220678c29553165cf` |
| Build, tests, security review | Local results in `release/official-sepolia-checks.json`; independent admission review pending. |
| Five NEW addresses, transaction hashes, contract Etherscan links | Not yet available; no deployment was performed. Obtain from confirmed IMD receipts. |
| Constructor values | Exact table and configuration above; zero ETH for each. |
| Verified deployed bytecode | Local factory runtime proof passed; live runtime verification pending the five new addresses. |
| Premint balances | Local factory proof: 210M CHEESE to `O`; live receipt logs and balances pending. |
| Explorer source verification | Pending for all five new contracts. Never claim verified from a template match alone. |
| Owner configuration | `bindToken`, any necessary role correction, three registrations, allocation check, verified `setAsset`, and finally `activate` remain pending. |

After IMD supplies receipts, contract links are formed from the **confirmed**
addresses at `https://sepolia.etherscan.io/address/` and transaction links from the
**confirmed** hashes at `https://sepolia.etherscan.io/tx/`. This document intentionally
contains no invented launch addresses or transaction links.
