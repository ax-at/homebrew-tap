# homebrew-tap

Personal [Homebrew](https://brew.sh) tap for [`ax-at`](https://github.com/ax-at) —
casks/formulae that aren't in `homebrew-cask`/`homebrew-core`.

```sh
brew tap ax-at/tap
brew install --cask ax-at/tap/<name>
```

## Casks

| Cask | App | Notes |
|------|-----|-------|
| `pencil-dev` | [Pencil Desktop](https://www.pencil.dev/) | Design-to-code canvas GUI. Not in homebrew-cask (the `pencil` token is the unrelated Evolus Pencil). The download URL is an unversioned, moving "latest" pointer, so `sha256` is `:no_check` and the version is a real-version + GCS-generation hybrid — `"<CFBundleShortVersionString>,<x-goog-generation>"`. Kept current automatically by the [auto-bump pipeline](#auto-bump), so plain `brew upgrade` catches new releases. |

## Auto-bump

Some upstreams (like Pencil) ship from an **unversioned, moving "latest" URL** — there's
no version in the URL for Homebrew's native `livecheck` to scrape, and nothing stable to
checksum. For those casks this tap runs a small pipeline
([`.github/workflows/autobump.yml`](.github/workflows/autobump.yml) +
[`scripts/autobump.sh`](scripts/autobump.sh)) that keeps the `version` field current so
`brew upgrade` behaves like it does for any normal cask.

**How it works** (per cask, weekly by default):

1. **detect** (ubuntu, header-only, no download) — a redirect-followed `HEAD` reads the
   object's content hash; if it differs from the md5 recorded in the cask, the cask is
   flagged as changed.
2. **bump** (macOS, only when something changed) — downloads the dmg once, mounts it,
   reads the real `CFBundleShortVersionString`, and rewrites the `version` to
   `"<realversion>,<generation>"`, then commits to `main`. The generation suffix keeps
   the version monotonic so even a silent same-version rebuild reaches users.

Which casks participate — and their per-cask strategy — is declared in
[`casks.json`](casks.json). The full design rationale is in [`DECISIONS.md`](DECISIONS.md).

### Configuring a cask (no file edits)

Cadence and enable/disable are **repo Variables** (Settings → Secrets and variables →
Actions → Variables, or the `gh` CLI) — changing them requires no commit. Names derive
from the cask token uppercased with non-alphanumerics as `_` (e.g. `pencil-dev` →
`PENCIL_DEV`):

```sh
gh variable set CADENCE_PENCIL_DEV --body 7      # check cadence, in days (default 7)
gh variable set ENABLED_PENCIL_DEV --body false  # pause just this cask
gh variable set AUTOBUMP_ENABLED   --body false  # global kill-switch (pauses all casks)
```

The daily base cron is the resolution floor; per-cask cadence is expressed in whole days.

### Running it on demand

```sh
# Force-bump a single cask now (bypasses cadence + the unchanged skip):
gh workflow run autobump.yml -f cask=pencil-dev

# Or trigger externally via the repository_dispatch API (type: autobump).
```

### Adding a new cask

Adding a cask is the one thing that needs a commit (its `Casks/<token>.rb` is the actual
Homebrew artifact). Create the cask, add an entry to `casks.json`, and — if it has a
**versioned** upstream — prefer a normal versioned cask with a `livecheck` block instead
of this pipeline. See the strategy ladder and the reserved `native-livecheck` path in
[`DECISIONS.md`](DECISIONS.md).
