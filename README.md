# tsx-aports

An apk package repository for the tsx-mainline xx60 project: signed Alpine
packages so a panel's `apk upgrade` also updates the kernel, sendspin, and
the ES2-patched Chromium -- not just Alpine's own packages.

Hard requirement: xx60 packages stay separate from any future platform
(e.g. xx70). A panel's `/etc/apk/repositories` lists Alpine's own repos, this
project's `common` repo, and ONLY its own platform repo (`xx60`), so an xx60
panel can never resolve an xx70 package even on the same CPU architecture.
Package names carry the platform for the same reason (`tsx-xx60-*`).

## Layout

```
common/<pkg>/APKBUILD      hardware-independent packages
xx60/<pkg>/APKBUILD        Meson8m2 (xx60/TSW-1060) packages
scripts/build.sh           build one package or all, in an armv7 container
scripts/index.sh           prune old versions + assemble the published tree
scripts/stage-kernel.sh    stage a prebuilt kernel's binaries for packaging
.github/workflows/build.yml   CI sketch (build + publish, chromium watch)
```

Published tree (what a panel actually fetches), one directory per Alpine
branch:

```
v3.24/common/armv7/{*.apk, APKINDEX.tar.gz}
v3.24/xx60/armv7/{*.apk, APKINDEX.tar.gz}
```

## A panel's /etc/apk/repositories

```
https://tsx-aports.unexceptional.net/v3.24/common
https://tsx-aports.unexceptional.net/v3.24/xx60
https://dl-cdn.alpinelinux.org/alpine/v3.24/main
https://dl-cdn.alpinelinux.org/alpine/v3.24/community
```

**This project's repos come FIRST** -- see "Which chromium wins" below: apk
breaks a tie between a real pkgname and an equal-version `provides=` match by
repository order, first listed wins, and `tsx-xx60-chromium` needs to win
that tie for `apk add chromium` (and a rootfs's `chromium=<ver>` pin) to
actually get our ES2-patched build instead of Alpine's own. This is safe for
every other package name: only `tsx-xx60-chromium` declares a `provides=`
that collides with a real Alpine package on purpose, so listing this
project's repos first does not otherwise change what a plain `apk add
<alpine-package>` installs. Never list a different platform's repo (e.g.
`v3.24/xx70`) on an xx60 panel.

## Packages (first round)

- `common/tsx-keys` -- installs this repo's public signing key into
  `/etc/apk/keys`. `arch=noarch`.
- `common/sendspin-cli` -- built from source (same pinned tag, same cmake
  flags as the old `rootfs/src/sendspin/build.sh` in tsx-xx60-linux).
- `xx60/tsx-xx60-boot-tools` -- `tsx-update-boot` (vendored from
  `installer/emmc/tsx-update-boot`), `tsx-kernel-flavor` (show/switch the
  booted flavor; also the kernel packages' install hook) and the
  `tsx_is_installed_panel()` detection helper.
- `xx60/tsx-xx60-kernel-stable` / `xx60/tsx-xx60-kernel-lts` -- BINARY
  packaging of an already-built kernel (see "Kernel packages" below).
  Installable side by side; a panel's rootfs carries both.
- `common/tensorflow-lite-c` -- the TFLite C library for the voice
  satellite's wakeword models.
- `xx60/tsx-xx60-chromium` -- Alpine's own armv7 `chromium` .apk, repacked
  with the 2-byte ES3->ES2 EGL fallback patch applied at build time (see
  "Chromium" below). `provides=chromium=<same version>`.

## Adding a package

1. `mkdir common/<name>` (hardware-independent) or `xx60/<name>`
   (platform-specific), write `APKBUILD`. Third-party software keeps its own
   `license=`; our own recipes/scripts are `GPL-2.0-or-later` (see LICENSE).
2. `TSX_APORTS_KEY=<path to the private key> scripts/build.sh <dir>` locally
   to iterate (add `BUILD_HOST=<host> BUILD_DIR=<remote path>` to build on
   another machine instead -- required for anything that actually compiles:
   this project's own workstation rule is to never compile kernel/rootfs/
   qemu-emulated builds locally; only run `scripts/build.sh` on the command
   line with `BUILD_HOST` set for those).
3. Commit the `APKBUILD` (and any small local source files next to it).
   Never commit `packages/`, `repo/`, or anything under a package's own
   `src/`, `pkg/`, `extract/`, or `dist/` (all gitignored -- rebuilt by the
   scripts).

## Signing key

One RSA-4096 project key, generated once with `abuild-keygen -n -b 4096`
(the same tool and defaults Alpine itself uses). Layout:

- Private key: `tsx-mainline/keys/tsx-mainline-<id>.rsa`, **outside every
  repo**, `chmod 600`, never committed, never printed. `scripts/build.sh`
  mounts it read-only into the build container via `TSX_APORTS_KEY`.
- Public key: `tsx-mainline/keys/tsx-mainline-<id>.rsa.pub`, committed
  in `common/tsx-keys/` (that is the whole point of that package) and baked
  into a panel's rootfs at build time so a fresh install already trusts it.

Key rotation: generate a new keypair the same way, add a new
`common/tsx-keys` version whose `package()` installs both the old and new
`.pub` (so panels mid-transition still trust whichever signed the index
they're currently fetching), re-sign a new index with the new key, and drop
the old key's install once no supported panel can still be on it.

If the key is ever lost or compromised: generate a new one, ship it via
`tsx-keys` signed with... nothing you can trust automatically -- this is a
manual, out-of-band step (e.g. an installer image carries the new pubkey
directly). There is no recovery path around that; it is the nature of a
single offline signing key.

## Kernel packages

`tsx-xx60-kernel-stable` and `tsx-xx60-kernel-lts` are **binary** packages:
no kernel compile happens inside `abuild`. `scripts/stage-kernel.sh
stable|lts` copies the already-built `zImage`, board DTB, and modules tree
off the build host (running `make modules_install` there -- installing
already-compiled `.ko` files and running `depmod`, not compiling anything)
and either fetches an already-packed eMMC boot image or packs one with
`kernel/mkimage.sh` (from tsx-xx60-linux) + the switchroot initramfs, again
no compilation. It then updates that package's `pkgver` and `sha512sums` in
place.

**pkgver scheme**: `<upstream kernel version>_git<YYYYMMDD>`, e.g.
`7.2.8_git20260927`. `make kernelrelease`'s own suffix
(`-NNNNN-gHASH`, a commit count + short hash) contains `-`, which apk's
version syntax does not allow in `pkgver`, so it is replaced by the staging
date. The exact commit for a given `pkgver` is recorded in that package's
`_kernelrelease` variable (build provenance only; nothing on the panel reads
it) -- if you need to reproduce an exact build, look there, not at the date.
This means two different commits staged on the same day would collide on
`pkgver`; bump `pkgrel` in that case (or stage again the next day).

**Contents**: `/boot/tsxboot-emmc-<flavor>.img`,
`/lib/modules/<kernelrelease>/` (without modules_install's `build`/`source`
links, which name the build machine's paths), and
`/usr/share/tsx/kernel-<flavor>.release`. No file is shared between the two
flavors, so both install side by side: a panel's rootfs carries both module
trees (package-owned) and both boot images, and switching flavors writes
only the boot partition (`tsx-kernel-flavor lts|stable`, no network).

**Install hook** (`post-install`/`post-upgrade` = `tsx-kernel-flavor --hook
<flavor>`): it writes ONLY when `tsx_is_installed_panel()` (from
`tsx-xx60-boot-tools`) says this is a real, installed xx60 panel --
`/etc/tsx/emmc-root.info` exists, `/dev/mmcblk1p7` and `/dev/mmcblk1p8`
exist, no `/.dockerenv`, and `/` IS the eMMC root partition (the device
number of `/` equals that of `/dev/mmcblk1p8`; apk-tools 3 runs package
scripts in their own PID/mount namespace, so a `/proc/1/root` comparison
cannot be used) -- AND this package's flavor is the selected one
(`KERNEL_FLAVOR` from `tsx-config`, else `kernel_flavor=` in
`emmc-root.info`, else the flavor matching the running kernel's series) --
AND the boot partition does not already hold this image. Otherwise it only
reports why nothing was written; this is what lets `apk add` in a plain
container, or a rootfs build's `apk add --root`, run safely. The write goes
through `tsx-update-boot --emmc`, which keeps the previous boot partition
content at `/data/tsxboot-emmc.prev.img`, verifies the write by reading it
back, and restores the previous image automatically on a mismatch -- then
prints "reboot to use the new kernel". Rollback if the new kernel doesn't
come up: U-Boot's own `boot_retry` falls back to the rescue system,
independent of this hook.

**Safety note (needs a decision)**: the eMMC write happens synchronously
inside `apk add`'s install script, with no "are you sure" and no reboot
countdown -- by design, so a scripted `apk upgrade` on a fleet of panels
just works. The safety net is entirely tsx-update-boot's own
backup+verify+restore and U-Boot's `boot_retry`, not a pause here. If that
is not enough margin (e.g. you want a panel to only write the new image
during a maintenance window), that policy belongs in `tsx-autoupdate`
(section 21 of the plan), which controls WHEN `apk upgrade` runs at all --
not in this hook, which only ever fires because an upgrade already happened.

## Chromium

Not a source build (a from-source Chromium build takes hours). CI tracks
Alpine v3.24's `chromium` armv7 package; for each new build it downloads the
`.apk`, applies the 2-byte ES3->ES2 EGL context fallback patch (see
`xx60/tsx-xx60-chromium/patch-chromium.py` and `sigs.json`, carried over
from `tsx-xx60-linux/rootfs/src/chromium-es2/` -- same tool, same signature
list), and republishes it as `tsx-xx60-chromium`, signed with the project
key. **If the patch site is not found or its bytes don't match the recorded
signature, the build fails loudly and nothing is published** -- panels keep
the previous build until a human derives a new signature (see that
directory's README, "Re-deriving for a new Chromium package").

`depends=` is copied verbatim from the upstream package's own `.PKGINFO`
(plain deps and `so:` soname deps alike) rather than re-derived by abuild's
automatic ELF scan (`options=!tracedeps`), since we ship the identical
binaries the upstream deps list already describes, and the scan would
otherwise need every one of ~60 shared libraries actually present in the
build container just to resolve names to versions.

### Which chromium wins

`tsx-xx60-chromium` sets `provides="chromium=<same version>"` and
`replaces="chromium"`, so `apk add chromium` (or a rootfs's own
`packages.txt` pin) can resolve to it when this repo is listed, without
every consumer having to know our package's real name.

Tested directly (clean `alpine:3.24` armv7 container, both the real
`chromium` and our `tsx-xx60-chromium` available at the identical version
`152.0.7977.82-r0`, `apk add chromium`): apk does **not** prefer a literal
pkgname match over a `provides=` virtual match -- with two candidates tied
on version, it picks whichever one's repository is listed FIRST in
`/etc/apk/repositories`. With `/pkgs/xx60` (ours) listed before Alpine's
`main`/`community`, `apk add chromium` installed `tsx-xx60-chromium`. With
Alpine's repos listed first (the more "obvious" order), it installed the
real `chromium` package instead. Hence the repository order above: this
project's repos first.

### Testing

```
scripts/build.sh --all              # build everything
scripts/index.sh                    # assemble the published tree, prune old versions
```

Then, in a clean `alpine:3.24` armv7 container (`docker run --rm --platform
linux/arm/v7 alpine:3.24`): install the public key into `/etc/apk/keys`,
append this repo's `common` and `xx60` lines to `/etc/apk/repositories`,
`apk update`, then:

```
apk add tsx-keys sendspin-cli tsx-xx60-kernel-stable tsx-xx60-chromium
```

Expect: `/usr/bin/sendspin-cli`, `/boot/tsxboot-emmc-stable.img`, a
populated `/lib/modules/<kver>/`, and a chromium binary that
`patch-chromium.py --check` (or the panel's own
`/usr/local/sbin/tsx-chromium-es2 check`) reports as `PATCHED`. The kernel
package's install hook should print "not on an installed xx60 panel (or
running in a chroot/container); nothing written" (a plain container is
neither).

On a panel (tested on a TSW-1060 running the stable flavor, the published
tree served over HTTP from a workstation): `apk add tsx-xx60-kernel-lts
tsx-xx60-kernel-stable` takes over the rootfs's unowned module trees; the
stable hook reports that the boot partition already holds its image, the
LTS hook that the panel boots stable. `tsx-config set KERNEL_FLAVOR lts &&
apk fix tsx-xx60-kernel-lts` writes the LTS image from inside apk's script
namespace (backup + readback verify) and the panel boots 6.18;
`tsx-kernel-flavor stable` switches back. `apk add tsx-xx60-chromium` on a
panel with Alpine's `chromium` installed purges it and installs ours
(`apk del chromium` then drops the `chromium=<ver>` world pin, which
`tsx-xx60-chromium` satisfies until then); an existing, unowned
`/etc/tsx/chromium-es2-patched` is kept and the package's copy lands as
`.apk-new` -- move it over (tsx-autoupdate in tsx-xx60-linux does all
three steps).

apk-tools 3 (Alpine 3.24) refuses every upgrade while a listed repository
is unavailable ("Not continuing due to stale/unavailable repositories");
until this repository is actually published, a panel that lists it needs
`--force-missing-repositories` (tsx-autoupdate adds it by itself and
reports the repository as unreachable) or `APK_URL=off` in its panel
configuration.

## Hosting and size

Packages are built and published by GitHub Actions and served from GitHub
Pages behind the custom domain `tsx-aports.unexceptional.net` (a `CNAME`
file in the published tree). GitHub Pages has a soft ~1 GB size limit and no
useful CDN-side pruning of its own, and `tsx-xx60-chromium` alone is over
100 MB per build (repacking, not compiling, so a new one publishes within
minutes of Alpine's own release) -- `scripts/index.sh --keep 2` (the CI
default) keeps only the newest version and one previous version of every
package, then re-signs the pruned index. Confirm on the FIRST publish that
the full tree (all packages, both kernel flavors, two chromium versions if
a second one has landed by then) fits well under the limit before relying
on this long-term; it does today (~190 MB for one version of everything --
see the sizes below).

## CI

`.github/workflows/build.yml` is a sketch, not run: a normal job that builds
whatever packages changed on push (via `scripts/build.sh`), publishes with
`actions/upload-pages-artifact` + `actions/deploy-pages`; and a scheduled
job that checks Alpine's v3.24 armv7 `chromium` for a new build and runs the
repack (failing loudly, same as a local build, if the ES2 patch site isn't
found).
