# DECISIONS — auto-bump design for `ax-at/homebrew-tap`

This document records **why** the auto-bump pipeline is built the way it is, so a future
maintainer (human or agent) doesn't have to re-derive it. It was settled through an
extended design review. Overarching constraint throughout: **do not invent anything new —
only use mechanisms with no unknowns.**

If you're just trying to *use* the pipeline, read [`README.md`](README.md). This file is
the rationale and the deferred-work backlog.

---

## 1. The problem

Some apps (the motivating case: **Pencil Desktop**) ship only as arch-specific `.dmg`
files from an **unversioned, moving "latest" URL** that 302-redirects to a short-lived
signed Google Cloud Storage (GCS) object. That means:

- **No version in the URL** → Homebrew's native `livecheck` has nothing to scrape.
- **No stable checksum** → the signed URL and even the object can change, so a pinned
  `sha256` would break.
- The app has **no auto-updater** (updates are manual).

A plain `version :latest` + `sha256 :no_check` cask installs fine but is **invisible to
`brew upgrade`** (it needs `--greedy`, i.e. manual), so it never stays current hands-off.

## 2. The lever: `version "X" + sha256 :no_check`

**Verified:** Homebrew accepts a fixed `version "…"` combined with `sha256 :no_check`
(`brew info` shows the version; it installs). This is the foundation of the whole design:

- **No sha to pin → no breakage window.** With no checksum, the cask can never mismatch
  the moving URL. A fresh `brew install` always fetches current bytes and works; only the
  version *label* can lag reality until the pipeline bumps it.
- **No mirror → no redistribution/ToS problem.** We keep pointing at the vendor's own URL
  and never re-host the dmg. (Re-hosting a proprietary dmg would violate Homebrew cask
  policy and the vendor's terms.)
- **No hashing of a 320 MB download** to detect changes.

What we give up vs a fully-pinned cask: checksum verification and true rollback. Rollback
was never possible anyway given the moving URL, and `:no_check` was already unavoidable.

## 3. The version scheme: real-version + generation hybrid

`version "<CFBundleShortVersionString>,<x-goog-generation>"` — e.g. `1.1.68,1782939031301980`.

- **Real version leads** (`1.1.68`) so `brew info`/`brew upgrade` are human-meaningful and
  the tap behaves like a normal cask.
- **The generation suffix is required, not cosmetic.** GCS `x-goog-generation` is a
  monotonic (creation-time) counter that increases on *every* re-upload. Without it, a
  vendor **silent rebuild** (new bytes, same marketing version `1.1.68`) would leave the
  label unchanged, so `brew upgrade` would not re-pull and users would stay on stale bytes.
  The generation suffix makes `1.1.68,<newer>` compare **greater** than `1.1.68,<older>`,
  so every byte-change reaches users. Homebrew's `Version` comparison treats the whole
  string token-by-token; the after-comma component participates in ordering.
  - **Validated by the acceptance test:** an after-comma-only change
    (`1.1.68,1000… → 1.1.68,1782…`) must make `brew upgrade` advance. If a future Homebrew
    ever stops comparing the after-comma part, the fallback is a **dot-joined** suffix
    (`1.1.68.<generation>`) — dot tokens are always compared. (As of this writing the
    comma form works.)

## 4. Detection vs version-source are separate axes

A deliberate decoupling:

- **Detection** = "did it change?" — cheap, header-only, run every check, **no download**.
- **Version source** = "what is it now?" — the real version, extracted **only when
  detection fires**.

This is what lets us get a real version for any dmg while downloading at most once *per
release* (not once per check). The earlier mistake was chaining "real version" to
"download every check"; detection gates the download instead.

### 4a. Change-detection ladder (pick per cask, strongest-cheapest first)

| Rung | Mechanism | Cost | Certainty | Hosts |
|---|---|---|---|---|
| **A. `header-identity`** | `HEAD`, compare a header tuple | header-only | depends on header | GCS (`x-goog-generation`), S3/CloudFront (`etag`), generic (`last-modified`+`content-length`) |
| **B. `github-release`** | GitHub API latest tag | one API call | exact | anything on GitHub Releases |
| **C. `download-sha256`** | download, sha256, compare stored | full download | exact (bytes) | hosts exposing nothing trustworthy |

**Confirm gate:** when a host exposes a *content hash without download* (`x-goog-hash: md5`,
or an `etag` that *is* the md5), require the hash to differ before declaring "changed", so
a no-op re-upload (bumped `last-modified`, identical bytes) doesn't trigger a pointless bump.

**pencil-dev uses `gcs-md5`:** the GCS `x-goog-hash: md5` is a byte-exact content hash
available header-only, so it *is* the detector (stronger than generation, which bumps on
no-op re-uploads too). Zero download.

**Weak-header hosts** (only `last-modified` + `content-length`, no hash, not GitHub):
default to **best-effort** on those headers; opt a specific cask into rung C
(`download-sha256`) when byte-certainty is worth a download every check. Not needed for
pencil.

### 4b. Version-source ladder

| Rung | Source | Cost | Monotonic? |
|---|---|---|---|
| `gcs-generation` | `x-goog-generation` int | header-only | yes |
| `last-modified-ts` | `Last-Modified` → `YYYY.MM.DD.HHMMSS` | header-only | yes |
| `info-plist` | mount/extract dmg → `CFBundleShortVersionString` | needs download | usually |
| ~~`etag`/hash~~ | content hash | — | **rejected** — not monotonic, can't order |

**pencil-dev uses `info-plist` for the real version + `gcs-generation` as the suffix.**

### 4c. Self-stating principle (no state file)

For header-only casks, keep the **detection identity and the version material inside the
cask file** so the `.rb` *is* the stored state — no sidecar state file, no PAT to write
Variables:

- generation lives in the `version` line;
- the content md5 lives in a machine-written `# autobump-md5:` comment.

Both are rewritten **only on an actual change**, so idle checks touch nothing. Rung C
(`download-sha256`) casks store their sha the same way (a comment), written only on change.

## 5. Configuration split: files vs Variables

- **Structural, in files** (a commit to change — inherent to "adding a product"):
  the `Casks/<token>.rb` artifact and its `casks.json` entry (token, `type`, `detect`,
  `version_source`, URLs, `default_cadence_days`).
- **Operational, in GitHub Actions Variables** (no commit to change):
  - `CADENCE_<TOKEN>` — check cadence in days (falls back to `casks.json`
    `default_cadence_days`, then 7).
  - `ENABLED_<TOKEN>` — per-cask pause (default true).
  - `AUTOBUMP_ENABLED` — global kill-switch (default true).

Variable name = token uppercased with non-alphanumerics → `_` (`pencil-dev` → `PENCIL_DEV`).
The script reads them from `${{ toJSON(vars) }}` passed as `VARS_JSON`, so no dynamic-key
expression tricks and no token that can *write* Variables are needed.

**Why cadence can't be fully "no file, ever":** GitHub parses `on.schedule.cron`
statically from the workflow YAML — there is no way to make the scheduled tick itself read
a Variable. So there is exactly **one** `autobump.yml` with **one** fixed daily cron,
written once. All per-cask cadence is then a data-driven due-check *inside* the run
(gated by `CADENCE_<TOKEN>`), so changing any cask's cadence needs no file edit. The daily
tick is the **resolution floor**: cadences are whole days ≥ 1. Sub-daily cadence is the
only thing that would require editing the base cron; no current cask needs it.

**Due-check state = git history.** "Last bump time" is
`git log -1 --format=%ct -- Casks/<token>.rb` (requires `fetch-depth: 0` in checkout). No
PAT, no state file. Self-healing: a failed bump leaves the file uncommitted, so the cask
stays "due" and retries on the next daily tick until it succeeds.

## 6. Runner topology + why macOS, not Linux

Two-tier, so the expensive runner only starts on real work:

- **`detect` on `ubuntu-latest`** — header-only HEADs for all due casks; emits the JSON
  list of due-and-changed casks. Almost every day this is empty and the job ends in seconds.
- **`bump` on `macos-latest`** — only when the list is non-empty; a `matrix` over the
  changed casks with `fail-fast: false` and `max-parallel: 1` (serialize pushes).

**Why macOS and not Linux for extraction:** reading `CFBundleShortVersionString` reliably
means mounting the dmg with `hdiutil` + `plutil` — exactly what `brew` itself does. Modern
Electron apps ship **APFS** dmgs, and Linux extraction of APFS-in-dmg (`7z`, `dmg2img`) is
unreliable — that's the "unknown" we refuse. macOS runners are free/unlimited on public
repos, and the bump job fires only a few times a year (per real release), so cost is a
non-issue.

## 7. Commit-back: direct to `main`

The `bump` job commits directly to `main` as `github-actions[bot]` using the default
`GITHUB_TOKEN` with `permissions: contents: write` — **no PAT**. It's a personal tap, the
change is a single mechanical version-string bump, and hands-off is the whole point.

**Loop-safe** twice over: the workflow has **no `on: push`** trigger, and GitHub already
suppresses recursive workflow runs from `GITHUB_TOKEN` pushes. Triggers are `schedule`
(daily) + `workflow_dispatch` (with an optional `cask` input to force one cask) +
`repository_dispatch` (type `autobump`). Requires `main` to be **unprotected** (normal for
a personal tap). If a gate is ever wanted, switch to PR-with-auto-merge — a small change.

## 8. Migration note (one-time)

A copy installed under the old `version :latest` cask has a receipt version of `latest`.
The first comparison against the new `1.1.68,…` label may need a single
`brew reinstall pencil-dev` to re-baseline. Affects only already-installed machines, once.

---

## Deferred / TODO (documented, not built)

These are intentional gaps. Implement when the first cask needs them — each maps onto a
known, no-unknowns mechanism.

### `native-livecheck` (the preferred path whenever a version *is* discoverable)

A cask whose upstream exposes a real version (versioned URL, appcast, GitHub Releases, a
version on the download page) should **not** use this custom pipeline. It should be a
normal versioned cask with a real `sha256` and a `livecheck do … end` block, kept current
by Homebrew's own tooling — real version, real checksum, real rollback:

```sh
brew livecheck <cask>                       # report current vs latest
brew bump-cask-pr --version <X> <cask>       # update version+sha, open a PR
```

Run those on a schedule from a **brew-enabled runner** (Homebrew-on-Linux or macOS). The
config schema reserves **`type: native-livecheck`**; the current `scripts/autobump.sh`
skips any non-`autobump-header` type with a clear message. Wire this branch the day the
first natively-versioned cask is added — it's just invoking Homebrew's own commands.

### Additional `autobump-header` rungs

- **`download-sha256` detection** — for weak-header / hash-less hosts that need
  byte-certainty (see §4a rung C). Store the sha as a `# autobump-sha256:` comment,
  written only on change (self-stating, §4c).
- **`last-modified-ts` version source** — for non-GCS hosts with no generation but a
  usable `Last-Modified` (see §4b). Monotonic, header-only.

Both are specified above; add the code paths when a cask actually requires them.
