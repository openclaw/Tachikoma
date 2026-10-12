# Releasing Tachikoma

Tachikoma ships as a SwiftPM library. The release workflow uses
`openclaw/release-workflows/.github/workflows/release-source.yml@v1` to publish
GitHub Releases with the exact dated changelog section, frozen-commit source ZIP
and tar archives, an asset inventory, and SHA-256 checksums. There is no npm,
Homebrew binary, or Sparkle publication.

## Prepare and rehearse

Update `VERSION` and finalize exactly one `## X.Y.Z - YYYY-MM-DD` (brackets around
the version are also accepted) section in `CHANGELOG.md`. Keep `Unreleased` above it.
Also update `tachikomaVersion` in `Sources/Tachikoma/Core/Tachikoma.swift` and the README installation version.

Merge the preparation PR and wait for every push CI check on that exact protected
`main` commit to pass. Rehearse from `main`:

```sh
gh workflow run release.yml --repo openclaw/Tachikoma --ref main -f version=X.Y.Z -F dry_run=true
```

Dispatch defaults to `dry_run: true`. It builds and tests the package, validates
version and dated notes, and independently verifies frozen source archives without
creating tags or releases. Use the current `VERSION`, including for an already
released version: a rehearsal always tests current protected `main`.

## Publish

Create an SSH-signed annotated `vX.Y.Z` tag on the verified commit, using the release
key authorized by `.github/release-allowed-signers`, and push that tag. The workflow
requires that exact commit's green push CI and an unchanged signed tag. Signing
key custody stays outside Actions; live dispatch also requires an existing signed
tag. Never move a tag or republish an existing version.

Verify the successful workflow, published notes, source archives, inventory and
checksums. Keep the next `Unreleased` section ready for subsequent changes.
The workflow replaces manual `gh release create`; there is no local publish path.
