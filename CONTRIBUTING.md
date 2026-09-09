# Contributing

Thanks for helping improve EphCore.

## Development

Baseline kernels are required before the application or tests will start.
From a fresh clone, at the project root:

```sh
mix deps.get
mix eph.download_kernels
mix format --check-formatted
mix test
mix credo --strict
```

`mix test` without those files fails at application start with instructions
to run `mix eph.download_kernels`. Hipparcos stars (`mix eph.setup_stars`)
are optional.

Public functions should include `@spec` and clear documentation. Keep changes
focused, add or update tests for behavior changes, and avoid adding runtime
dependencies unless they are necessary for the library itself.

When a change affects public APIs or the modules that power them, update the
relevant Livebook tours in `notebooks/` in the same change. Prefer calling
EphCore's public functions from Livebook cells over recreating library logic in
the notebook. The tours should exercise the dependency surface directly so API
breakage is visible instead of hidden in parallel notebook-only code.
