# Local Pessimistic Prover Wrapper

This wrapper package keeps the base `kurtosis-cdk` code untouched and swaps in
an Agglayer deployment compatible with the upstream local pessimistic prover
flow.

## What it changes

- Reuses the normal CDK deployment flow and modules.
- Replaces only the Agglayer service deployment/config template.
- Configures the Agglayer node with:
  - `[certificate-orchestrator.prover.sp1-local]`
  - `[prover.cpu-prover]`

## Requirements

- A custom Agglayer image built from the upstream `agglayer` repo.
- Enough RAM/CPU for local SP1 proving.

## Example

```bash
kurtosis run --enclave cdk-local-pp --args-file wrappers/local-pessimistic-prover/pessimistic.yml wrappers/local-pessimistic-prover
```

## Notes

- This wrapper does not modify the stock `kurtosis-cdk` package files.
- The Agglayer image you provide must support:
  - `agglayer run`
  - `agglayer vkey`
  - `agglayer vkey-selector`
