# Additional offline coverage

`LiquidityCustodyInvariants.t.sol` supplements the existing launch and vault suites.
It deploys the unmodified InkPortraits, InkVault, InkLiquidity and InkRenderer in
the requested order, then configures the hook and pool locally. It uses the bundled
Uniswap PoolManager, PositionManager and swap test router, with plain 18-decimal
ERC20 fixtures at the IMD address and on either side of it. No FeeRouter or testnet
application is deployed by these new tests.

Each token ordering runs 128 sequences of 64 calls across four actors. Calls
interleave donations, buys, sells, liquidity additions, LP and hook fee collection,
owner width changes, and unauthorized attempts to move position NFTs or change
the premium. No tokens are minted after setup. The properties check:

- Every recorded position remains owned by InkLiquidity, without approvals, and
  retains its original liquidity. Ranges remain aligned and respect the price floor.
- Both token supplies are conserved across all custodians and actors.
- Donations and INK fees reconcile with compounding and the remaining balance.
- Only IMD fees go to the treasury; ownership gives no fee entitlement.
- Ownership, royalties, dependency bindings and released vault state remain intact.

Deterministic tests exercise both fee currencies, the MIN_ADD minus one / MIN_ADD
boundary, invalid collection ranges, and rollback of prefunding when PositionManager
settlement fails, followed by a successful retry.

`RendererBoundaryProperties.t.sol` adds 1,000 binary chunk round-trip fuzz cases,
the maximum EIP-170 chunk boundary, rejected writes, permanent locking, and
the two-step renderer ownership handover (no authority for the nominee before
acceptance, only the nominee can accept, and the previous owner is revoked after).

These tests need no RPC, credentials, environment mutation or new dependencies.
Run them and the existing suite with:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x5ba4a490487a4af407fdbe3b9c8ca3151a1870567475ec05d2caa23cfe03a32d forge test
```

The offline integration does not verify deployed mainnet bytecode or current chain
state. The existing guarded mainnet fork suites still need a configured RPC and a
separate live-state run; they skip in the default offline run. The optional complete
snapshot tests also skip when the external full snapshot fixture is absent.
