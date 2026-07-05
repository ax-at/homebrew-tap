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
| `pencil-dev` | [Pencil Desktop](https://www.pencil.dev/) | Design-to-code canvas GUI. Not in homebrew-cask (the `pencil` token is the unrelated Evolus Pencil). Uses `version :latest` + `sha256 :no_check` because the download URL is an unversioned "latest" pointer; the app has no auto-updater, so refresh with `brew upgrade --cask --greedy pencil-dev`. |
