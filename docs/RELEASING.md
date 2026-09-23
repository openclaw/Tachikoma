# Releasing Tachikoma

Tachikoma is distributed as a Swift package. A release consists of a versioned Git tag and a published GitHub Release; there are no npm packages or signed binary assets to publish.

1. Run the checks documented in [contributing.md](contributing.md), including the hermetic test suite. The release PR must pass the complete macOS and Linux CI matrix.
2. Update `tachikomaVersion` in `Sources/Tachikoma/Core/Tachikoma.swift` and the installation version in `README.md`.
3. Finalize the accumulated `CHANGELOG.md` entries as `## X.Y.Z - YYYY-MM-DD`, with a one-line `**Highlights:**` introduction. Keep an empty `## Unreleased` section above it.
4. Merge the release PR, update local `main`, and tag the verified merge commit as `vX.Y.Z`. Push the tag.
5. Copy that version's complete changelog section into a temporary notes file. Publish with `gh release create vX.Y.Z --verify-tag --title vX.Y.Z --notes-file <notes-file>`.
6. Read back the release with `gh api repos/openclaw/Tachikoma/releases/tags/vX.Y.Z`. Verify it is not a draft, its body matches the changelog section, and the remote tag resolves to the intended commit.

There is no automatic release workflow. Pushing a tag alone does not publish a GitHub Release. Swift Package Manager consumers resolve the version from the Git tag.
