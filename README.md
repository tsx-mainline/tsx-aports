# tsx-aports

This is an apk package repository for the tsx-mainline xx60 project. It holds signed Alpine packages. A panel's `apk upgrade` then updates the kernel, sendspin, and the ES2-patched Chromium, in addition to the Alpine packages.

The xx60 packages stay separate from any future platform (for example xx70). A panel's `/etc/apk/repositories` lists the Alpine repos, the `common` repo of this project, and only its own platform repo (`xx60`). An xx60 panel can therefore never resolve an xx70 package, even on the same CPU architecture. Package names carry the platform for the same reason (`tsx-xx60-*`).

## Layout

```
common/<pkg>/APKBUILD      hardware-independent packages
xx60/<pkg>/APKBUILD        Meson8m2 (xx60/TSW-1060) packages
scripts/build.sh           build one package or all, in an armv7 container
scripts/resign.sh          re-sign the output of a BUILD_HOST build with the real key, locally
scripts/apk-split.py       split an apk into its sig/control/data members (used by resign.sh)
scripts/index.sh           prune old versions + assemble the published tree
scripts/stage-kernel.sh    stage the binaries of a prebuilt kernel for packaging
.github/workflows/build.yml   CI sketch (build + publish, chromium watch)
```

A panel fetches the published tree. It has one directory for each Alpine branch:

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

**List the repos of this project FIRST.** See "Which chromium wins" below. When two candidates have the same version, apk picks the first one in repository order. This applies to a real pkgname and to a `provides=` match. `tsx-xx60-chromium` must win this tie, so that `apk add chromium` (and the `chromium=<ver>` pin of a rootfs) gets our ES2-patched build and not the Alpine build.

This order is safe for every other package name. Only `tsx-xx60-chromium` declares a `provides=` that collides with a real Alpine package, and it does so on purpose. A plain `apk add <alpine-package>` installs the same package as before. Never list the repo of a different platform (for example `v3.24/xx70`) on an xx60 panel.

## Packages (first round)

- `common/tsx-keys` installs the public signing key of this repo into `/etc/apk/keys`. It has `arch=noarch`.
- `common/sendspin-cli` builds from source. It uses the same pinned tag and the same cmake flags as the old `rootfs/src/sendspin/build.sh` in tsx-xx60-linux.
- `xx60/tsx-xx60-boot-tools` contains these parts:
  - `tsx-update-boot` (vendored from `installer/emmc/tsx-update-boot`).
  - `tsx-kernel-flavor` (shows or switches the booted flavor, and is also the install hook of the kernel packages).
  - The `tsx_is_installed_panel()` detection helper.

  Before `tsx-update-boot` writes a boot image, it checks that the image has a DTB for the U-Boot `aml_dt` of this panel. The values are `crestron,tsw760` for the TSW-760 and `crestron,tsw1060` for the TSW-1060 and TSS-10. If the DTB is missing, it writes nothing. `--check IMG` only checks. `--any-board` skips the check.

  The boot image of the kernel packages has both board DTBs in the vendor multi-DTB container. `stage-kernel.sh` packs the container with `mkimage.sh --board-dtbs`. `scripts/check-bootimg-dtbs.py` checks it. The host test is `scripts/tests/test-board-dtbs.sh`.
- `xx60/tsx-xx60-kernel-stable` and `xx60/tsx-xx60-kernel-lts` are BINARY packages of an already-built kernel (see "Kernel packages" below). They install side by side. The rootfs of a panel has both.
- `common/tensorflow-lite-c` is the TFLite C library for the wakeword models of the voice satellite.
- `xx60/tsx-xx60-chromium` is the armv7 `chromium` .apk from Alpine, repacked with the 2-byte ES3->ES2 EGL fallback patch. The build applies the patch (see "Chromium" below). The package has `provides=chromium=<same version>`.
- `xx60/tsx-xx60-wlroots0.20` is the Alpine `wlroots0.20` recipe with one patch. The Meson CRTC has no gamma LUT. Without the patch, the first `output * power on` of sway after `output * power off` fails, and the screen stays off. The package has `provides=wlroots0.20=<same version>` and works like `tsx-xx60-chromium` (see "Which chromium wins"). Its `pkgver` and `pkgrel` must be equal to the Alpine package. Remove the package when Alpine ships a wlroots with the fix.

## Adding a package

1. Make the directory `common/<name>` (hardware-independent) or `xx60/<name>` (platform-specific). Write the `APKBUILD` in it. Third-party software keeps its own `license=`. Our own recipes and scripts use `GPL-2.0-or-later` (see LICENSE).
2. To iterate locally, run `TSX_APORTS_KEY=<path to the private key> scripts/build.sh <dir>`.
3. To build on another machine, add `BUILD_HOST=<host> BUILD_DIR=<remote path>`. Use this for any package that compiles. The workstation rule of this project is to never compile kernel, rootfs, or qemu-emulated builds locally. For these builds, run `scripts/build.sh` on the command line with `BUILD_HOST` set.
4. Commit the `APKBUILD` and any small local source files next to it. Never commit `packages/`, `repo/`, or the `src/`, `pkg/`, `extract/`, and `dist/` directories of a package. Git ignores them, and the scripts rebuild them.

## Signing key

The project has one RSA-4096 key. Generate it once with `abuild-keygen -n -b 4096`. This is the same tool and the same defaults that Alpine uses. The key files are:

- Private key: `tsx-mainline/keys/tsx-mainline-<id>.rsa`. Keep it **outside every repo** with `chmod 600`. Never commit it, never print it, and **never copy it to a remote host**, not even `BUILD_HOST` (see "Building on a remote host" below). The local path of `scripts/build.sh` mounts it read-only into the build container through `TSX_APORTS_KEY`.
- Public key: `tsx-mainline/keys/tsx-mainline-<id>.rsa.pub`. It is committed in `common/tsx-keys/`, which is the purpose of that package. The build of a panel rootfs installs it, so a fresh install already trusts it.

### Building on a remote host

`BUILD_HOST` never receives the private key. The BUILD_HOST path of `scripts/build.sh` works in these steps:

1. It pushes the repo to the build host.
2. It runs itself again over ssh with `ON_HOST=1`.
3. The build host generates a throwaway RSA keypair for that one run (`openssl genrsa`, in `mktemp -d`). The remote build deletes it when it finishes.

The packages that come back have a signature from a key that nobody else has seen. This is not the project key.

`scripts/resign.sh` re-signs these packages locally with the real key. `build.sh` calls it, and you can also call it by hand. It works in these steps:

1. It splits each `.apk` into three members with `scripts/apk-split.py`. An apk v2 package is three concatenated gzip streams: signature, control, and data.
2. It discards the old signature.
3. It re-signs `control.tar.gz` with `TSX_APORTS_KEY` in a disposable Alpine container.
4. It verifies the result with `apk verify` against a trust store that holds only the public key of the project. A package with a foreign signature fails here, and the build does not publish it.

`scripts/index.sh` then rebuilds and signs the published index locally with `TSX_APORTS_KEY`.

Two guards enforce "never copied to a remote host", in addition to the absence of code that would do it:

- `to_build_host()` is the one function that `build.sh` uses for every rsync in its BUILD_HOST path. It refuses if any argument is the path of the private key. It also refuses any argument that ends in `.rsa` and is not its own `.rsa.pub`.
- `assert_remote_cmd_safe()` refuses to give `ssh "$BUILD_HOST"` a command string that contains the local path of the private key.

`scripts/tests/test-resign.sh` tests both guards directly, and it does not need `BUILD_HOST`. It also tests the split, re-sign, and verify round trip. The fixture is a small package built with two throwaway keys. Neither key is the real project key.

Local builds (without `BUILD_HOST`) have not changed. `TSX_APORTS_KEY` signs directly in the local container. CI does not use `BUILD_HOST` either. CI restores its `TSX_APORTS_PRIVKEY` secret straight into a local `TSX_APORTS_KEY` (`.github/workflows/build.yml`).

Key rotation:

1. Generate a new keypair the same way.
2. Add a new `common/tsx-keys` version. Its `package()` installs both the old and the new `.pub`. A panel in transition then trusts the key of the index it fetches.
3. Re-sign a new index with the new key.
4. Remove the install of the old key when no supported panel can still use it.

If the key is lost or compromised, generate a new one. You cannot ship it through `tsx-keys`, because no existing key can sign it in a way that panels trust. Use a manual, out-of-band step. For example, an installer image can carry the new public key. No automatic recovery exists, because the project has a single offline signing key.

## Kernel packages

`tsx-xx60-kernel-stable` and `tsx-xx60-kernel-lts` are **binary** packages. No kernel compile happens inside `abuild`. The `source=` of each package fetches one release asset from tsx-xx60-linux: `tsx-xx60-kernel-<flavor>-bundle.tar.zst`. The bundle contains these files:

- zImage
- the board DTB
- the modules tree tarball
- the packed eMMC boot image
- `kernel.release` and `kernel.commit`

The job `kbundle` in `.github/workflows/release.yml` of that repo builds the bundle. `abuild` extracts the bundle automatically (it is a plain `.tar.zst`). `package()` then installs the already-built files. You can produce and use the bundle in two ways:

- **CI** (`build.yml`, no build host): plain `abuild` fetches the asset of the pinned `_kbundle_tag` release over the network. It verifies the asset against `sha512sums`. CI has no other way to build this package.
- **Local or `BUILD_HOST`** (a kernel with no tag or release yet): run `scripts/stage-kernel.sh stable|lts`. The script does these steps:
  1. It copies the already-built `zImage`, the board DTB, and the modules tree from the build host. On the build host, it runs `make modules_install`. This installs the compiled `.ko` files and runs `depmod`. It does not compile anything.
  2. It fetches an already-packed eMMC boot image, or packs one with `kernel/mkimage.sh` (from tsx-xx60-linux) and the switchroot initramfs. This also does not compile anything.
  3. It packs the bundle in the same format into `dist/`.
  4. It updates `pkgver`, `_kernelrelease`, and `sha512sums` in place. It never changes `_kbundle_tag`.

  The line `SRCDEST="$startdir/dist"` in each package makes `abuild` use this local file. `sha512sums` verifies it, and `abuild` never fetches it again. `_kbundle_tag` has no effect here. It is only for CI. Change it by hand when a matching tsx-xx60-linux release exists.

**pkgver scheme**: `<upstream kernel version>_git<YYYYMMDD>`, for example `7.2.8_git20260927`. The suffix of `make kernelrelease` (`-NNNNN-gHASH`, a commit count and a short hash) contains `-`. The apk version syntax does not allow `-` in `pkgver`. The staging date replaces the suffix. The `_kernelrelease` variable of the package records the exact commit for a `pkgver`. This is build provenance only, and nothing on the panel reads it. To reproduce an exact build, read that variable and not the date. Two different commits that you stage on the same day have the same `pkgver`. In that case, increase `pkgrel` or stage again the next day.

**Contents**: the package installs these files:

- `/boot/tsxboot-emmc-<flavor>.img`
- `/lib/modules/<kernelrelease>/`, without the `build` and `source` links of modules_install, because they name paths on the build machine
- `/usr/share/tsx/kernel-<flavor>.release`

The two flavors share no file, so they install side by side. The rootfs of a panel has both module trees (owned by the packages) and both boot images. A switch of the flavor (`tsx-kernel-flavor lts|stable`, no network) writes only the boot partition.

**Install hook** (`post-install` and `post-upgrade` run `tsx-kernel-flavor --hook <flavor>`): the hook writes ONLY when all of these conditions are true:

- `tsx_is_installed_panel()` (from `tsx-xx60-boot-tools`) says this is a real, installed xx60 panel. This needs these facts:
  - `/etc/tsx/emmc-root.info` exists.
  - `/dev/mmcblk1p7` and `/dev/mmcblk1p8` exist.
  - `/.dockerenv` does not exist.
  - `/` IS the eMMC root partition. The device number of `/` equals the device number of `/dev/mmcblk1p8`. A comparison of `/proc/1/root` does not work, because apk-tools 3 runs package scripts in their own PID and mount namespace.
- The flavor of this package is the selected flavor. The hook reads it from `KERNEL_FLAVOR` in `tsx-config`. If that is not set, it reads `kernel_flavor=` in `emmc-root.info`. If that is not set, it uses the flavor that matches the series of the running kernel.
- The boot partition does not already hold this image.

In all other cases the hook only reports why it wrote nothing. This makes `apk add` safe in a plain container and in the `apk add --root` of a rootfs build.

The write goes through `tsx-update-boot --emmc`. This tool keeps the previous content of the boot partition at `/data/tsxboot-emmc.prev.img`. It reads the write back to verify it. If the data does not match, it restores the previous image automatically. The hook then prints "reboot to use the new kernel". If the new kernel does not start, the `boot_retry` of U-Boot falls back to the rescue system. This does not depend on the hook.

**Safety note (needs a decision)**: the eMMC write happens synchronously inside the install script of `apk add`. It has no confirmation prompt and no reboot countdown. This is by design, so that a scripted `apk upgrade` works on a fleet of panels. The safety net is the backup, verify, and restore of tsx-update-boot, and the `boot_retry` of U-Boot. The hook does not pause. If this margin is not enough, put a policy in `tsx-autoupdate`. For example, a panel can write the new image only in a maintenance window. `tsx-autoupdate` controls WHEN `apk upgrade` runs. The hook is the wrong place for this policy, because it runs only after an upgrade has happened.

## Chromium

The build does not compile Chromium from source, because a from-source build takes hours. CI tracks the `chromium` armv7 package of Alpine v3.24. For each new version it does these steps:

1. It downloads the `.apk`.
2. It applies the 2-byte ES3->ES2 EGL context fallback patch. See `xx60/tsx-xx60-chromium/patch-chromium.py` and `sigs.json`. They come from `tsx-xx60-linux/rootfs/src/chromium-es2/`, with the same tool and the same signature list.
3. It republishes the package as `tsx-xx60-chromium`, signed with the project key.

**If the build does not find the patch site, or its bytes do not match the recorded signature, the build fails. It publishes nothing.** Panels keep the previous build until a person derives a new signature. See the README of that directory, section "Re-deriving for a new Chromium package".

`depends=` is a verbatim copy of the `.PKGINFO` of the upstream package. It includes plain dependencies and `so:` soname dependencies. It is not the result of the automatic ELF scan of abuild (`options=!tracedeps`). We ship the identical binaries, so the upstream list already describes them. The scan would also need about 60 shared libraries in the build container, only to resolve names to versions.

### Which chromium wins

`tsx-xx60-chromium` sets `provides="chromium=<same version>"` and `replaces="chromium"`. With this repo listed, `apk add chromium` (or a pin in the `packages.txt` of a rootfs) resolves to it. A consumer does not need to know the real name of our package.

We tested this in a clean `alpine:3.24` armv7 container. The real `chromium` and our `tsx-xx60-chromium` were both available at the same version `152.0.7977.82-r0`. We ran `apk add chromium`. apk does **not** prefer a literal pkgname match over a `provides=` virtual match. When two candidates have the same version, it picks the one whose repository is FIRST in `/etc/apk/repositories`. With `/pkgs/xx60` (ours) before the Alpine `main` and `community`, `apk add chromium` installed `tsx-xx60-chromium`. With the Alpine repos first (the more obvious order), it installed the real `chromium` package. For this reason, the repository order above lists the repos of this project first.

### Testing

```
scripts/build.sh --all              # build everything
scripts/index.sh                    # assemble the published tree, prune old versions
```

Then do these steps in a clean `alpine:3.24` armv7 container (`docker run --rm --platform linux/arm/v7 alpine:3.24`):

1. Install the public key into `/etc/apk/keys`.
2. Append the `common` and `xx60` lines of this repo to `/etc/apk/repositories`.
3. Run `apk update`.
4. Run this command:

```
apk add tsx-keys sendspin-cli tsx-xx60-kernel-stable tsx-xx60-chromium
```

Expect these results:

- `/usr/bin/sendspin-cli` exists.
- `/boot/tsxboot-emmc-stable.img` exists.
- `/lib/modules/<kver>/` has content.
- `patch-chromium.py --check` (or `/usr/local/sbin/tsx-chromium-es2 check` on a panel) reports the chromium binary as `PATCHED`.
- The install hook of the kernel package prints "not on an installed xx60 panel (or running in a chroot/container); nothing written". A plain container is neither of these.

We tested this on a TSW-1060 that ran the stable flavor. A workstation served the published tree over HTTP. The results were:

- `apk add tsx-xx60-kernel-lts tsx-xx60-kernel-stable` takes over the unowned module trees of the rootfs. The stable hook reports that the boot partition already holds its image. The LTS hook reports that the panel boots stable.
- `tsx-config set KERNEL_FLAVOR lts && apk fix tsx-xx60-kernel-lts` writes the LTS image from inside the script namespace of apk (backup and readback verify). The panel then boots 6.18. `tsx-kernel-flavor stable` switches back.
- `apk add tsx-xx60-chromium` on a panel with the Alpine `chromium` installed removes it and installs ours. Then `apk del chromium` removes the `chromium=<ver>` world pin, which `tsx-xx60-chromium` satisfies until then.
- The package keeps an existing, unowned `/etc/tsx/chromium-es2-patched`, and its own copy arrives as `.apk-new`. Move the copy over the old file. tsx-autoupdate in tsx-xx60-linux does all three steps.

apk-tools 3 (Alpine 3.24) refuses every upgrade while a listed repository is unavailable ("Not continuing due to stale/unavailable repositories"). Until this repository is published, a panel that lists it needs `--force-missing-repositories`. It can also use `APK_URL=off` in its panel configuration. tsx-autoupdate adds the option by itself and reports the repository as unreachable.

## Hosting and size

GitHub Actions builds and publishes the packages. GitHub Pages serves them behind the custom domain `tsx-aports.unexceptional.net` (a `CNAME` file in the published tree). GitHub Pages has a soft limit of about 1 GB and no CDN-side pruning. `tsx-xx60-chromium` alone is over 100 MB for each build. It only repacks and does not compile, so a new build publishes within minutes of an Alpine release.

`scripts/index.sh --keep 2` (the CI default) keeps the newest version and one previous version of every package. It then re-signs the pruned index.

On the FIRST publish, confirm that the full tree fits well under the limit. The tree has all packages, both kernel flavors, and two chromium versions if a second one exists by then. Do this before you rely on the setup long-term. Today one version of everything is about 190 MB.

## CI

`.github/workflows/build.yml` builds and publishes the repository. It has three jobs:

- **build** runs on a push to `main` that changes `common/`, `xx60/`, `scripts/`, or the workflow. It also runs on manual runs and on pull requests. It does these steps:
  1. `scripts/carry-forward.py` restores the published tree into `packages/v3.24`. It checks every index signature against the committed public key. It checks every apk against the checksum in its signed index.
  2. `scripts/build.sh --skip-existing --skip-unreachable --all` builds only the versions that are not published yet. A kernel package is skipped with a warning when its tsx-xx60-linux release bundle does not exist yet. Its published copy stays.
  3. `scripts/index.sh --keep 2` re-indexes and signs the merged tree.

  A pull request builds with a throwaway key and publishes nothing.
- **deploy** publishes that tree with `actions/deploy-pages`.
- **chromium-watch** runs daily. It checks the Alpine v3.24 armv7 `chromium`. If that is newer, it opens a pull request that changes the pin. It needs the setting "Allow GitHub Actions to create and approve pull requests" in the Actions settings of the repo.

At the first deploy, the site is empty and nothing exists to carry forward. Put a tarball of a published tree on the release `seed` as `tsx-aports-seed.tar.gz`. The tree is `v3.24/<category>/armv7/...`, with public packages only. A run that finds the site empty uses the tarball automatically. A manual run can name another tarball with the `seed_url` input. To see the local options, run `scripts/carry-forward.py --help`. The test is `scripts/tests/test-ci-pages.sh` (host, packaging only).
