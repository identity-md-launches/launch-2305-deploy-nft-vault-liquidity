# Ethereum contracts-only launch adaptation

## Deployment handoff

This assignment prepares the sources for the later IMD factory deployment. No transaction
was signed or broadcast. No `launch.json` is supplied: that belongs to the manifest step.

Chain: Ethereum, chain ID **1**. `$owner` resolves to
**0x824e12b38cff2d3e7ad9607a0212f7f9eb6a06e3**.

| Order | Solidity contract | Constructor arguments, in order |
| --- | --- | --- |
| 1 | `InkPortraits` | `$owner` |
| 2 | `InkVault` | `$contract:InkPortraits`, `0x0000ec93127baa929e58e97dd0095a2bfb38ec1d`, `$owner` |
| 3 | `InkLiquidity` | `0x000000000004444c5dc75cb358380d2e3de08a90`, `0xbd216513d74c8cf14cf4747e6aaa6420ff64ee9e`, `$owner`, `0xbc10b3662231c830d2ee10bc6359db17bea4b3d4` |
| 4 | `InkRenderer` | `$contract:InkPortraits`, `$owner` |

These existing constructors already satisfy the required order, static argument types,
nonpayability and explicit ownership. None calls a dependency or requires dependency code
during construction. They need no constructor adaptation. All four remain direct deployments,
with no proxy, initializer, upgrade role or linked external library.

The treasury receives IMD fees only. It has no owner/admin role; royalty information still
names `$owner` at the existing **0%** rate. The factory and transaction origin receive no role.
Do not deploy `InkFeeRouter`, `InkHook`, `src/testnet`, or a new ERC-20 in this launch.
The owner deploys the existing fee router separately; the later hook launch creates INK and its pool.

The manager addresses agree with the Ethereum entry in
[Uniswap's official deployment reference](https://developers.uniswap.org/docs/protocols/v4/deployments).
Ethereum RPC reads at block **26,234,564**, using the task's Ethereum provider
(public source: `https://ethereum-rpc.publicnode.com`), confirmed:

- PoolManager: 24,009 bytes of code.
- PositionManager: 23,877 bytes; `poolManager()` returns the above PoolManager.
- The supplied seat contract: 5,231 bytes; `name()` returns `identity.md`.
- IMD `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`: 22,990 bytes;
  `name()` returns `Identity.md`.

No address was substituted for the future INK token, hook, pool, snapshot root or deployed
application addresses. Those remain the existing owner-configured values.

## Imported audit findings

### 7a54cd1bfe87 — free replacement draws after expiry (medium): reproduced and fixed

Both supplied proof tests failed on the imported code: a trait reroll renewed at a later
block without a second fee, then applied a different seed for that same payment.
A separate test against an unchanged copy also reproduced the analogous pull renewal.

Changes in `src/InkVault.sol`:

- An expired trait reroll now clears the pending request, retains the old seed and emits
  `TraitRerollExpired`. The paid fee remains with liquidity. A further draw requires a new
  `rerollTraits` payment. Anyone can clear the expired request and its transfer lock.
- A pull never receives a replacement entropy block. If its original hash expires before
  being recorded, it closes, releases its reservation, returns its 400,000 INK backing minus
  the existing reroll fee, and sends that fee to liquidity. This gives a discarded draw the
  same cost as returning an unwanted swarm portrait. The fee and agent-holder discount are
  fixed at purchase, so later owner fee changes cannot alter an outstanding pull's refund.
  No new fee rate, price or fee recipient was introduced.
- If a reveal begins while the original hash is available, that hash is saved across bounded
  admission batches. Delaying the remaining batches cannot change the draw. Deposit cutoffs
  remain the original request block.
- `PullExpired`, `pullExpired(id)` and `pullExpiryFee(id)` expose the outcome. `pulls(id).done`
  means the request is closed, including expiry. `reveal(id)` returns false on expiry;
  `revealNext(max)` processes at most `max` requests and returns only the number of portraits
  revealed. Keepers must use `nextReveal < pullCount` to identify remaining work, rather than
  treating a zero reveal count as an empty queue.

For a request in block `b`, its hash is usable from `b + 2` through `b + 257`, inclusive.
Without a saved hash, `b + 258` expires it. An owner-chosen zero reroll fee still means zero
cost, as in the original fee policy; the fix does not override that choice.

Tests: `test/LaunchSafety.t.sol` covers paid retry, exact expiry boundaries, discounted and
changing fees, refund/backing conservation, batch limits and a live pull behind an expired one.
`test/AuditRegression.t.sol` retains admission/candidate-set tests and now expects closure or
the recorded original draw instead of renewal. `test/InkSystem.t.sol` updates the expired-trait
expectation. `test/VaultInvariants.t.sol` accounts for expiry fees independently.

### 8ff058a5ba34 — invalid irreversible configuration (medium): reproduced and fixed

Both supplied setter proofs failed on the imported code: a code-free vault became permanent,
and a code-free INK address stranded the funded vault. Additional tests against unchanged
source confirmed that a hookless native-currency pool was accepted, setup accepted unconfigured
liquidity, and all four owners could renounce before configuration.

Changes:

- `src/InkPortraits.sol`: `setVault` and `setRenderer` require deployed code and a `portraits()`
  reference to this collection. The vault must expose a nonzero seat contract, and the renderer
  must expose its chunk count, so accidentally swapping the two addresses also fails.
  Failed checks leave the setter usable. Renunciation requires both references to be configured.
- `src/InkVault.sol`: `setInk` requires token code and at least `SEATS * PORTRAIT`
  (**800,000,000 INK**) already in the vault. `setup` additionally requires liquidity configured
  for that same INK and `poolSet() == true`. Renunciation requires completed setup.
- `src/InkLiquidity.sol`: `setPool` retains its initialized-pool check and validates the hook's
  recorded token, paired currency, manager, treasury, collection and vault bindings. The vault
  must use the same INK, point back from its collection, and share the liquidity owner's address.
  On chain 1, the other currency must be the verified IMD address (`MAINNET_IMD`). PositionManager
  must report the same PoolManager. All validation precedes the permanent pool/floor assignment.
  Renunciation requires a configured pool.
- `src/InkRenderer.sol`: renunciation requires at least one nonempty art chunk. Empty chunks
  are rejected so they cannot bypass that readiness check or the existing empty-art lock check.

The bindings check consistency and obvious configuration mistakes, not the honesty of arbitrary
contracts that intentionally impersonate those interfaces. The owner must still verify the actual
later launch addresses, snapshot, art bytes and schedule. No owner privilege was added.

Tests: `test/LaunchSafety.t.sol`, `test/InkSystem.t.sol` and `test/AuditRegression.t.sol` exercise
wrong/code-free/unfunded dependencies, wrong collection/token/hook/treasury/manager bindings,
mainnet currency enforcement, uninitialized and zero-tick pools, failure recovery, and guarded
renunciation. `test/helpers/ConfiguredLiquidity.sol` is a token-bound test double used only by
vault-focused tests. Existing renderer, snapshot, preview and invariant fixtures were updated
to use that double; direct mint unit tests now use an actual bound vault.

### f6efe85d4b38 — portraits lost through direct transfers (low): reproduced and fixed

Against unchanged source, a plain `transferFrom` left a portrait owned by the vault without
changing its inventory, paying INK or providing an exit. A safe transfer to InkLiquidity
was also accepted and stranded the portrait.

- `src/InkPortraits.sol`: `_update` rejects transfers into the vault unless the vault is the
  caller, allowing the accounted `deposit` path. It also rejects transfers into the configured
  liquidity address, for both agent and swarm portraits.
- `src/InkLiquidity.sol`: `onERC721Received` accepts only the configured PositionManager,
  preserving intended position custody while rejecting unrelated safe NFT transfers.

Tests: `test/LaunchSafety.t.sol` covers plain transfers, both safe-transfer overloads, approved
operators, both portrait types, unchanged custody/balances on failure, and successful deposits.
`test/InkSystem.t.sol` checks rejection of an unrelated NFT and continued custody of real
PositionManager positions. Existing safe-transfer tests now expect rejection at the NFT layer.
Arbitrary third-party NFTs can still bypass their receiver with their own unsafe transfer
functions; no general rescue or seizure power was added.

### 5a7763c36197 — coverage note (informational)

This was not a defect and required no behavior change. The original constructors already
met the factory requirements. The required two-stage launch cannot know INK, its hook/pool,
the final snapshot or uploaded art during this four-contract deployment. The existing owner
wiring remains, with the validation above, and is not called by the factory. No reported
defect was rejected as non-reproducible.

Existing assumptions remain: plain 18-decimal INK transfers; builder-influenceable blockhash
randomness; permissionless liquidity placement at spot subject to the existing floor; owner
control over bounded fees, liquidity parameters and presentation until the existing locks;
and no time fallback if the owner never completes setup. These were not redesigned.

## Other changed files and reasons

- `test/MainnetContractsLaunch.t.sol`: rehearses exactly the four requested deployments in
  one CREATE2 factory call on an empty chain, checks references, owners, royalties, unauthorized
  administrative calls, init/runtime sizes and forbidden runtime opcodes.
- `test/InkRenderer.t.sol`, `test/SnapshotProofs.t.sol`, `test/SnapshotAllSeats.t.sol`,
  `test/TokenURIPreview.t.sol`: replace previously unconstrained liquidity/vault fixtures with
  valid bindings required by the setter fix. Their art/trait/proof assertions are retained.
- `launch/mainnet-1-contracts.json`: removes the old fifth fee-router deployment from the
  request draft and explicitly leaves it to the owner, matching this assignment.
- `README.md`, `SETUP.md`, `launch/README.md`: record the current scope, correct owner/treasury
  distinction, configuration order, expiry semantics and validation entry point.
- `script/InkSteps.sol`: corrects only the treasury comment; it does not change script logic.
- `ADAPTATION.md`: this change log and deployment handoff.

The existing build configuration, dependencies, artwork, hook and fee-router logic remain
unchanged. Packaging fingerprints in the imported repository remain historical evidence of
that baseline, not fingerprints of this adaptation. No dependency was installed or added.

## Verification

Toolchain: Forge **1.8.3**, Solidity **0.8.26**, original Cancun/optimizer-200/non-via-IR
configuration with `bytecode_hash = "none"`. Seed:
`0x5ba4a490487a4af407fdbe3b9c8ca3151a1870567475ec05d2caa23cfe03a32d`.

The imported suite passed before changes: **75 passed, 0 failed, 28 skipped**. The supplied
audit proofs then produced **4 expected failures**; six additional exploit assertions
against unchanged source passed. Those temporary reproductions were confined to scratch
and are not part of the deliverable.

The new factory rehearsal reports runtimes of **8,920 / 12,063 / 11,898 / 12,804 bytes**,
in deployment order, each below EIP-170. All init codes including arguments fit EIP-3860.
No bytecode contains an external library link; the deployed runtime scan passes for
DELEGATECALL, CALLCODE and SELFDESTRUCT exclusions.

Final `forge build` passed, including a clean rebuild during validation. Compiler warnings
are the existing uint128 shift in the liquidity ladder and shadowed names in `LocalStack.s.sol`.

The final full seeded `forge test -vv` run passed: **96 passed, 0 failed, 28 skipped** across
17 suites. Fuzz tests ran 256 cases each; the original seven vault invariants passed at
64 runs × 120 calls with zero handler reverts. Skips are the existing optional fork/snapshot
tests; no new regression or factory test skips. The default suite remains network-independent.

The mainnet integration command uses the same seed, `FORK_BLOCK=26234564` and
`--match-contract 'MainnetForkInkIs[01]Test'`. It covers both token orderings with the actual
PoolManager, PositionManager, Permit2, Universal Router, seat contract and IMD.
The final fork run passed: **14 passed, 0 failed, 0 skipped**. The two suites exercised
both token orderings, including full lifecycle, trading lock, fee routing and router swaps.
These are local fork simulations; no live transaction was submitted.

`git diff --check` passed. A changed-path check confirmed that no protected build,
dependency, environment or repository-control path was modified. The updated request
draft parses as JSON and names exactly the four contracts in the required order.

No Slither or Mythril run is claimed. Tests are local evidence, not a replacement for the
assignment's independent review. Deployment, source verification and real snapshot/art
configuration remain with the later deployer and owner.
