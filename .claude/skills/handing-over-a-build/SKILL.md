---
name: handing-over-a-build
description: Rules for handing over a DSMT build - the required DSMT.v<version>.zip filename, which a GitHub link can never produce, plus release branch naming and building the archive locally. Use whenever a download link, build, release branch, zip archive, tag or release for DSMT-V3 is requested.
---

# Handing over a build

## The filename is `DSMT.v<version>.zip`. This is not negotiable.

`DSMT.v1.26.0.zip`. Dot before the `v`, no space, no hyphen, no repo name.
Asked for explicitly on 2026-08-08 after a GitHub branch link was handed over
instead, and it is the first thing to get right.

**A GitHub archive URL can never produce it.** GitHub always names an archive
`<repo>-<ref>.zip`, and this repo is `DSMT-V3`, so the best a branch link can
do is `DSMT-V3-1.26.0.zip`. Do not hand over a branch link and hope the name
is close enough — it is the wrong name, every time.

**So build it locally and send the file:**

    git archive --format=zip -o DSMT.v1.26.0.zip refs/heads/1.26.0

Then send it with `SendUserFile`. Two details that bite:

- Use `refs/heads/<version>`, not the bare version — git reads `1.26.0` as an
  ambiguous revision and fails with `Needed a single revision`.
- **Do not pass `--prefix`** — files go at the root of the archive, so
  extracting gives `server\`, `web\`, `docs\` directly rather than a wrapper
  folder to dig through. (GitHub's own archives always add that wrapper; ours
  must not.) Verify with `unzip -l` before sending.

A release asset would also allow a free filename, but it needs a tag and an
upload, and **tags cannot be pushed from the dev container** (the git proxy
answers 403). Tag and release creation is a request to the operator, never a
step to attempt silently.

Still cut the release branch named exactly the version number — it is how the
release is anchored in the repo, and the GitHub link stays useful as a
secondary. Just never present that link as the deliverable on its own.

---

Whenever a download link is given for this project, **name it `DSMT <version>`
first** — "DSMT 1.13.0", then the link. A bare GitHub URL does not say which
version is behind it, and branch zips move: the same URL served 1.8.1 and
1.12.0 a day apart. State the version, then the link, then which files go
where.

**The downloaded file must carry the version too.** GitHub names an archive
after the ref, so `refs/heads/main.zip` always arrives as `DSMT-V3-main.zip` —
three of those in a downloads folder are indistinguishable. So every release
gets a **branch named exactly the version number** (`1.13.0`, no `v`, no
prefix), cut from `main` at the release commit, and that is the link handed
over:

    https://github.com/Rendi1984/DSMT-V3/archive/refs/heads/1.13.0.zip
    -> DSMT-V3-1.13.0.zip

Do not name the branch `DSMT-1.13.0` — the repo name is already in the
filename and it comes out as `DSMT-V3-DSMT-1.13.0.zip`. A `v` prefix is also
pointless: **GitHub strips a leading `v` from the ref when naming an archive**,
so branch `v1.13.1` still downloads as `DSMT-V3-1.13.1.zip`.

**The archive name cannot be controlled beyond that.** GitHub always builds it
as `<repo>-<ref>.zip`, and this repo is `DSMT-V3`, so the `-V3` is unavoidable.
Two consequences worth knowing before promising a filename:

- Some browsers ignore `Content-Disposition` and save the URL's last segment
  instead, which is why `.../1.13.1.zip` can land on disk as `1.13.1.zip`.
- The only way to a freely chosen name is a **release asset**, which needs a
  tag and an upload — neither possible from the dev container.

Which is the whole reason the archive is built locally: see the top of this
file for the `git archive` recipe and the required `DSMT.v<version>.zip` name.

Deleting a remote branch is blocked by the same 403 as pushing a tag, so it is
also a request to the operator rather than a step to attempt silently.
