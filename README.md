# Ink & Inference — portable launch source

This is launch source. Original packaging did not audit, upload, pay for or deploy these
contracts. The package does not include the real snapshot, private cutoff, keys,
RPC credentials or confirmed deployed application addresses.

The Ethereum contracts-only adaptation is documented in [ADAPTATION.md](ADAPTATION.md),
including the supplied owner, the four-contract deployment order, reproduced audit fixes,
and validation results. INK and its hook/pool belong to the later launch; the owner deploys
InkFeeRouter separately. Original packaging fingerprints (`SHA256SUMS`,
`BYTECODE_HASHES.json`, `SOURCE_PROVENANCE.json`, `VALIDATION.txt`) describe the imported
baseline, not this adapted source.

## Included

- All five production contracts and the test-only TestSeats helper.
- Every current Foundry test, fixed trait cases and synthetic snapshot proofs.
- Exact installed Solidity dependencies and available license/config metadata.
- `art/original-art.js`: the original algorithm, byte-for-byte, NOT replacement artwork.
- `script/UploadRenderer.s.sol`: uploads that file after stripping its module export line.
- `launch/`: draft Sepolia/Ethereum request bodies and deployment-order notes.
- `SETUP.md`, audit brief, provenance, hashes and isolated validation results.

This directory is the root of a self-contained Foundry repository. No sibling web app
or other workspace directory is needed. No unpinned dependency install script is used.

## Build and test

Install Foundry using https://getfoundry.sh/ and use the version recorded in VALIDATION.txt.
Run at this directory's root:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x5ba4a490487a4af407fdbe3b9c8ca3151a1870567475ec05d2caa23cfe03a32d forge test -vv
```

Solidity 0.8.26 may be downloaded by Foundry if not already installed. No RPC, wallet,
real metrics, Node dependencies or funded account is required to build/test.
The default profile is read-only. `FOUNDRY_PROFILE=preview forge test --mt test_writeTokenURIs` also writes
the rendered tokenURIs to `out-preview/` to open by eye; it is ignored and excluded from the archive.

The build uses Cancun, optimizer 200, no via-IR and bytecode_hash none, as in the source project.
Imported production bytecode was compared across two clean builds; see the historical BYTECODE_HASHES.json.
Renderer/preview tests use the real original art; snapshot tests use invented metrics.
Do not claim this validates the actual mainnet snapshot or original snapshot-fetching pipeline.

## Publication and ownership

Publishing this directory makes the original art algorithm public, as well as contracts,
tests, dependency source and launch drafts. Review this boundary before GitHub upload.
Review owner-authored source licensing separately; no blanket project license was invented.
Retain dependency licenses. Do not deploy TestSeats on mainnet.

Read SETUP.md before signing anything. Read PACKAGING.md for portability changes.
The website/API and marketplace image-hosting service are not included in this package.
