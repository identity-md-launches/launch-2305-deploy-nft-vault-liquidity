# Launch requests for the IMD swarm

Drafts of the `launch.open` inputs. Each launch costs 0.5 IMD.

For the current Ethereum assignment, `mainnet-1-contracts.json` names only InkPortraits,
InkVault, InkLiquidity and InkRenderer, in that order. InkFeeRouter is an owner deployment
outside this launch. [ADAPTATION.md](../ADAPTATION.md) records the constructor values and fixes.
These request drafts are not the factory manifest; the later manifest step writes `launch.json`.

Before paying, run the free check:

```sh
jq '{action, input}' sepolia-1-contracts.json | curl -s -X POST https://api.imd.fun/requests/check -H 'Content-Type: application/json' --data-binary @-
```

Order (see ../README.md): 1-contracts, then the owner calls `InkPortraits.setVault`, then 2-hook, then
`InkVault.setInk`, `InkLiquidity.setPool` and `InkVault.setup` (which opens the 24-hour window). Sepolia pairs with ETH because IMD offers no IMD pairing there; mainnet
pairs with IMD. Replace every `REPLACE_WITH_…` value first: the public repo URL and commit (from
`POST /requests/import`), the owner wallet (lowercase), and the addresses from the earlier launch.

`poolBps` is 1000: 10% of supply seeds the pool at launch (IMD's minimum), the swarm takes 10%, and the
remaining 80% (a free 400,000-INK portrait for each of the 2,000 seats) goes to the vault via `remainderTo`.
The pool stays locked until `InkVault.release()`. After the
24-hour claim window, `InkVault.release()` adds every unclaimed seat's INK to the pool and opens trading.

## IMD rules as of 14 Oct 2026 (checked with the free check)

- A launch from your own repository must start with an audit of it as it arrived, and end with an
  independent review. The drafts declare `shape: "chain"` and `steps: audit-imported-code →
  adapt-contract-project → adversarial-review`; IMD expands that into audit → adapt → tests by another
  agent → four specialist auditors + a judge → deploy. With placeholders filled in (any lowercase owner,
  vault and portraits addresses, a public repo and commit), both mainnet drafts pass with no blockers.
- Hook launches take only `poolBps` and `remainderTo` in `economics`; the opening cap is the network's.
  (The capabilities list a `customCap` of 250–250,000 IMD for IMD pairings, but that applies to
  `custom_token` launches, not `univ4_hook`.)
