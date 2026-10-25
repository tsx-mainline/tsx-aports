# tsx-aports

tsx-aports is the apk package repository for the TSX panels. It holds signed Alpine packages. With this repository, `apk upgrade` on a panel updates the kernel, sendspin, the ES2-patched Chromium and the patched wlroots, together with the Alpine packages.

The repository has five repos. `common` holds the hardware-independent packages. `xx60` holds the packages of the xx60 family (TSW-760, TSW-1060 and TSS-10). `xx50` holds the packages of the xx50 family (TSS-752). `xx70` holds the kernel packages of the xx70 family (TSW-570, TSW-770 and TSW-1070). `uc-pxx` holds the packages of the uc-pxx family (the Crestron UC-P10 and UC-P8 room phones). The `/etc/apk/repositories` file of a panel lists the Alpine repos, the `common` repo and the repo of its family. The name of a family package starts with the family (`tsx-xx60-*`, and `uc-pxx-*` for the uc-pxx family, which has no `tsx` prefix).

## Layout

```
common/<pkg>/APKBUILD      hardware-independent packages
xx60/<pkg>/APKBUILD        Meson8m2 packages (xx60: TSW-760, TSW-1060 and TSS-10)
xx50/<pkg>/APKBUILD        i.MX53 packages (xx50: TSS-752)
xx70/<pkg>/APKBUILD        APQ8053 kernel packages (xx70: TSW-570, TSW-770 and TSW-1070)
uc-pxx/<pkg>/APKBUILD      RK3399 packages (uc-pxx: UC-P10 and UC-P8), see "uc-pxx packages"
scripts/build.sh           build one package or all, in a container of the package architecture (armv7 or aarch64)
scripts/pin-kernel.sh      pin a kernel package to the bundle of a tsx-xx60-linux release
scripts/resign.sh          re-sign the output of a BUILD_HOST build with the real key, locally
scripts/arch-image.sh      the container image of each architecture (used by build.sh, index.sh and resign.sh)
scripts/apk-split.py       split an apk into its sig/control/data members (used by resign.sh)
scripts/index.sh           prune old versions + assemble the published tree
scripts/stage-kernel.sh    stage the binaries of a prebuilt kernel for packaging
scripts/stage-kernel-xx70.sh   stage the bundle of an xx70 kernel package on a build host
scripts/stage-kernel-uc-pxx.sh stage the bundle of the uc-pxx kernel package on a build host
scripts/stage-uc-pxx-tools.sh  stage the tools bundle of the uc-pxx recipes on a build host
scripts/uc-pxx-source.sh   the local source archive of uc-pxx-linux (a tag or a snapshot)
scripts/carry-forward.py   restore the published tree and check its signatures (CI)
scripts/channels.py        the tree logic of the testing channel: assemble, promote, compare, sort (see "Testing channel")
scripts/manifest.py        the manifest of a deploy: make, wait, verify (see "Manifest of a deploy")
scripts/live-manifest.sh   find the manifest of the last deploy (the artifact live-manifest)
scripts/trigger-testing.sh start the testing build on main from a push to testing
scripts/take-recipes.sh    for a testing build: the recipes of a commit on testing, the scripts and keys of main
scripts/decide-mode.sh     the mode of a CI run (stable, testing, promote, none)
scripts/check-testing-sha.sh   stop unless a commit is on the branch testing
scripts/assemble-site.sh   assemble both trees of the site for one deploy (CI)
scripts/source-policy.sh   which GitHub sources a channel may use (tag or commit)
scripts/check-bootimg-dtbs.py   check the board DTBs of a boot image
scripts/keep-pins.sh       keep/keep.txt for the initramfs pins of a tsx-xx60-linux tag (pin-kernel.sh runs it)
scripts/keep-alpine.sh     keep an Alpine package that Alpine removed (keep/keep-alpine.txt)
keep/                      the kept packages: never pruned, restored by index.sh (see "Kept packages")
scripts/tests/             host tests (resign, board DTBs, CI Pages, testing channel, manifest, run mode, site trees, remote deps, source pins, build order, index prune, kept packages, xx70 kernel staging and flavor, uc-pxx-update-boot)
.github/workflows/build.yml   CI: build, publish, and the daily watch jobs
```

A panel fetches the published tree. It has one directory for each Alpine branch:

```
v3.24/common/armv7/{*.apk, APKINDEX.tar.gz}
v3.24/xx60/armv7/{*.apk, APKINDEX.tar.gz}
v3.24/xx50/armv7/{*.apk, APKINDEX.tar.gz}
v3.24/common/aarch64/{*.apk, APKINDEX.tar.gz}
v3.24/xx70/aarch64/{*.apk, APKINDEX.tar.gz}
v3.24/uc-pxx/aarch64/{*.apk, APKINDEX.tar.gz}
```

## A panel's /etc/apk/repositories

```
https://tsx-aports.unexceptional.net/v3.24/common
https://tsx-aports.unexceptional.net/v3.24/xx60
https://dl-cdn.alpinelinux.org/alpine/v3.24/main
https://dl-cdn.alpinelinux.org/alpine/v3.24/community
```

An xx50 panel lists `v3.24/xx50` in place of `v3.24/xx60`. An xx70 panel lists `v3.24/xx70`. A uc-pxx panel lists `v3.24/uc-pxx`.

**List the repos of this project FIRST.** See "Which chromium wins" below. When two candidates have the same version, apk picks the first one in repository order. This applies to a real pkgname and to a `provides=` match. `tsx-xx60-chromium` must win this tie, so that `apk add chromium` (and the `chromium=<ver>` pin of a rootfs) gets the ES2-patched build of this repo and not the Alpine build.

This order is safe for every other package name. Only `tsx-xx60-chromium` and `tsx-xx60-wlroots0.20` declare a `provides=` that collides with a real Alpine package, and they do so on purpose. A plain `apk add <alpine-package>` installs the Alpine package.

## Packages

- `common/tsx-keys` installs the public signing key of this repo into `/etc/apk/keys`. It has `arch=noarch`.
- `common/sendspin-cli` builds sendspin-cli from source, at a pinned tag, with one patch (`player-volume.patch`, written for upstream). The patch adds the subcommands `player-vol` and `player-mute` and the option `--volume-file`. With them, the player volume is the volume of the panel (tsx-linux-common `docs/sendspin.md`, "Audio and volume").
- `common/tsx-sendspin` is the Sendspin player service of tsx-linux-common (`sendspin/`): the service, its settings and the key `SENDSPIN` of `tsx-config`. It depends on `sendspin-cli` and `tsx-base` only, so any panel with a sound card can install it. `tsx-ha` depends on it. Up to 0.3.4 `tsx-ha` held these files (`replaces="tsx-ha"`). Its install scripts make the user `tsx-sendspin`. It has `arch=noarch`.
- `xx60/tsx-xx60-boot-tools` contains these parts:
  - `tsx-update-boot` (a copy of `installer/emmc/tsx-update-boot` in tsx-xx60-linux).
  - `tsx-kernel-flavor` (shows or switches the booted flavor, and is also the install hook of the kernel packages).
  - The `tsx_is_installed_panel()` detection helper.

  Before `tsx-update-boot` writes a boot image, it checks that the image has a DTB for the U-Boot `aml_dt` of this panel. The values are `crestron,tsw760` for the TSW-760 and `crestron,tsw1060` for the TSW-1060 and TSS-10. If the DTB is missing, it writes nothing. `--check IMG` only checks. `--any-board` skips the check.

  The boot image of the kernel packages has both board DTBs in the vendor multi-DTB container. `stage-kernel.sh` packs the container with `mkimage.sh --board-dtbs`. `scripts/check-bootimg-dtbs.py` checks it. The host test is `scripts/tests/test-board-dtbs.sh`.
- `xx60/tsx-xx60-kernel-stable` and `xx60/tsx-xx60-kernel-lts` are BINARY packages of an already-built kernel (see "Kernel packages" below). They install side by side. The rootfs of a panel has both.
- `common/tensorflow-lite-c` is the TFLite C library for the wakeword models of the voice satellite.
- `common/tsx-panel-app` is the shared part of the panel app of tsx-linux-common (experimental): the service, the layout checker and the layout editor of the setup page. Its install scripts make the user `tsx-panel-app`, which runs the program. It has `arch=noarch`. The program itself comes from a family package. The xx60 family uses the browser kiosk and has no such package.
- `xx60/tsx-xx60-chromium` is the armv7 `chromium` .apk from Alpine, repacked with the 2-byte ES3->ES2 EGL fallback patch. The build applies the patch (see "Chromium" below). The package has `provides=chromium=<same version>`.
- `xx60/tsx-xx60-wlroots0.20` is the Alpine `wlroots0.20` recipe with one patch. The Meson CRTC has no gamma LUT. Without the patch, the first `output * power on` of sway after `output * power off` fails, and the screen stays off. The package has `provides=wlroots0.20=<same version>` and works like `tsx-xx60-chromium` (see "Which chromium wins"). Its `pkgver` and `pkgrel` must be equal to the Alpine package. The job `wlroots-watch` opens an issue when Alpine publishes another `wlroots0.20` build.

  To go back to the Alpine package when an Alpine build has the fix:
  1. Publish one more `tsx-xx60-wlroots0.20` with a higher `pkgrel`. It has no files and no `provides` or `replaces`, and it depends on `wlroots0.20>=<the fixed Alpine version>`. On the next `apk upgrade`, the panels install the Alpine package.
  2. Remove `tsx-xx60-wlroots0.20` from `rootfs/packages-tsx.txt` in tsx-xx60-linux.
  3. After all panels have upgraded, remove the package from the panels (`apk del tsx-xx60-wlroots0.20`) and remove its directory here.
- `xx50/tsx-xx50-board` is the board layer of the xx50 panels (the files of `rootfs/overlay` of tsx-xx50-linux that the board owns), with `tsx-kernel-slots`, `tsx-boot-ok` and `tsx-boot-rescue`. It depends on `tsx-autoupdate`, and its install scripts add the automatic update to the default runlevel. It has `arch=noarch`.
- `xx50/tsx-xx50-panel-app` is the panel app program of the xx50 panels. `abuild` compiles it from the panel app source archive of a tsx-xx50-linux release: the C++ project that ESPHome writes. The build installs PlatformIO with pip in `$srcdir`, and PlatformIO downloads the libraries that the project names with exact versions. So the recipe has `options="net"`.
- `xx50/tsx-xx50-kernel-lts` is a BINARY package of the xx50 kernel (see "Kernel packages" below). Its install hook writes the kernel into the normal raw slots of the boot card, and the rescue system into the rescue slot, with `tsx-kernel-slots`.
- `xx70/tsx-xx70-boot-tools` contains `tsx-update-boot` and `tsx-bootrec` (copies of `rootfs/overlay/usr/local/sbin` in tsx-xx70-linux), `tsx-kernel-flavor` (shows or switches the booted flavor, and is also the install hook of the kernel packages) and the `tsx_is_installed_panel()` detection helper. `tsx-update-boot` writes only the `boot_b` partition. Before it writes, it checks the image for a `crestron,tswxx70` DTB. The host test is `scripts/tests/test-xx70-flavor.sh`.
- `xx70/tsx-xx70-kernel-stable` and `xx70/tsx-xx70-kernel-lts` are BINARY packages of an already-built kernel (see "xx70 kernel packages" below). They install side by side.
- `uc-pxx/*` are the packages of the uc-pxx family: `uc-pxx-boot-tools` and `uc-pxx-kernel-lts` (see "uc-pxx packages" below).

## Add a package

1. Make the directory `common/<name>` (hardware-independent) or `xx60/<name>` (platform-specific). Write the `APKBUILD` in it. Third-party software keeps its own `license=`. The recipes and scripts of this repo use `GPL-2.0-or-later` (see LICENSE).
2. To iterate locally, run `TSX_APORTS_KEY=<path to the private key> scripts/build.sh <dir>`.
3. To build on another machine, add `BUILD_HOST=<host> BUILD_DIR=<remote path>`. Use a build host for any package that compiles. Set `BUILD_HOST` on the command line of `scripts/build.sh`.
4. Make `source=` a public URL, and run `abuild checksum` (see "Source of the packages").
5. Commit the `APKBUILD` and any small local source files next to it. Never commit `packages/`, `repo/`, or the `src/`, `pkg/`, `extract/`, and `dist/` directories of a package. Git ignores them, and the scripts rebuild them.

## Source of the packages

Every recipe builds from public sources. CI and a local build download the same files. No recipe reads a tarball that a person made on a workstation.

- The recipes of `common/` (all `tsx-*` packages that have a `tsx-linux-common-$pkgver.tar.gz` source) use the GitHub archive of the signed tag `v$pkgver` of tsx-linux-common.
- `xx60/tsx-xx60-board` uses the GitHub archive of the signed tag `board-v$pkgver` of tsx-xx60-linux. The top directory of this archive is `tsx-xx60-linux-board-v$pkgver`.
- `common/tsx-ledbar-fw` uses the GitHub archive of the signed tag `v$pkgver` of tsx-ledbar-fw (panel tools, hooks, tests) and the release asset `tsx-ledbar-$pkgver.upg` of the same tag (the image). It does not compile the firmware, because the Alpine cross compiler makes a different image than the tested one.
- `xx50/tsx-xx50-board` uses the GitHub archive of the signed tag `board-v$pkgver` of tsx-xx50-linux. The top directory of this archive is `tsx-xx50-linux-board-v$pkgver`.
- `xx50/tsx-xx50-panel-app` uses the release asset `tsx-xx50-panel-app-src-$pkgver.tar.gz` of the tag `v$pkgver` of tsx-xx50-linux.
- The kernel packages use a release asset (see "Kernel packages"). The xx70 kernel packages use an asset of a tsx-aports release (see "xx70 kernel packages").
- `uc-pxx/uc-pxx-boot-tools` uses the GitHub archive of the tag `board-v$pkgver` of uc-pxx-linux and the tools bundle of a tsx-aports release. `uc-pxx-kernel-lts` uses the kernel bundle of a tsx-aports release (see "uc-pxx packages").

On the branch `testing`, a recipe can use the archive of one commit instead of a tag (see "Testing channel", "Commit sources").

The tag fixes the content of an archive. `sha512sums` fixes the bytes. GitHub makes the archive again on each request, with its own gzip. The bytes are the same on each download, but they are not the same as the output of `git archive | gzip`. A change of the GitHub gzip program changes the sum. The build then fails and nothing is signed. To fix this, run `abuild checksum` and check that the content is the same as before.

CI runs `scripts/build.sh --verify`. This option leaves out `abuild checksum`, so the build checks the sums of the APKBUILD. A build without `--verify` writes new sums. Look at the diff before you commit it.

To release a new version of a package:

1. Push the signed tag to the source repo. A tag that is not public cannot be downloaded.
2. Set `pkgver` and `pkgrel` in the recipe.
3. Run `scripts/build.sh <PKGDIR>` (it writes the new `sha512sums`).
4. Commit the recipe.

`scripts/tests/test-sources.sh` checks each recipe. Each `source=` that has a URL needs a sum, a `_kbundle_tag` must name a release, and a `pkgdesc` has at most 128 characters (abuild refuses a longer one).

## Signing key

The project has one RSA-4096 key. Generate it once with `abuild-keygen -n -b 4096`. This is the same tool and the same defaults that Alpine uses. The key files are:

- Private key: `tsx-mainline/keys/tsx-mainline-<id>.rsa`. Keep it **outside every repo** with `chmod 600`. Never commit it, never print it, and **never copy it to a remote host**, not even `BUILD_HOST` (see "Build on a remote host" below). The local path of `scripts/build.sh` mounts it read-only into the build container through `TSX_APORTS_KEY`.
- Public key: `tsx-mainline/keys/tsx-mainline-<id>.rsa.pub`. It is committed in `common/tsx-keys/`, which is the purpose of that package. The build of a panel rootfs installs it, so a fresh install already trusts it.

### Build on a remote host

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

A local build (without `BUILD_HOST`) signs directly with `TSX_APORTS_KEY` in the local container. CI does not use `BUILD_HOST`. CI restores its `TSX_APORTS_PRIVKEY` secret into a local `TSX_APORTS_KEY` (`.github/workflows/build.yml`).

To rotate the key:

1. Generate a second keypair the same way.
2. Add a `common/tsx-keys` version whose `package()` installs both `.pub` files. A panel in transition then trusts the key of the index it fetches.
3. Sign a new index with the second key.
4. When no supported panel needs the first key, remove its `.pub` from `tsx-keys`.

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
- **Local or `BUILD_HOST`** (a kernel without a tag or a release): run `scripts/stage-kernel.sh stable|lts`. The script does these steps:
  1. It copies the already-built `zImage`, the board DTB, and the modules tree from the build host. On the build host, it runs `make modules_install`. This installs the compiled `.ko` files and runs `depmod`. It does not compile anything.
  2. It fetches an already-packed eMMC boot image, or packs one with `kernel/mkimage.sh` (from tsx-xx60-linux) and the switchroot initramfs. This also does not compile anything.
  3. It packs the bundle in the same format into `dist/`.
  4. It updates `pkgver`, `_kernelrelease`, and `sha512sums` in place. It never changes `_kbundle_tag`.

  The line `SRCDEST="$startdir/dist"` in each package makes `abuild` use this local file. `sha512sums` verifies it, and `abuild` never fetches it again. `_kbundle_tag` has no effect here. It is only for CI.

To pin the packages to a release, run `scripts/pin-kernel.sh <TAG>`. The tag is a tag of tsx-xx60-linux that started `release.yml`, for example `v0.2.0`. For each flavor, the script does these steps:

1. It downloads the bundle of the release.
2. It checks `CHECKSUMS.sha256` inside the bundle.
3. It checks that `kernel.release` starts with the kernel version of `pkgver`.
4. It writes `_kbundle_tag`, `_kernelrelease` and `sha512sums` into the APKBUILD.

The bundle that CI builds and the bundle of `stage-kernel.sh` have different bytes, also for the same commit. So run `scripts/pin-kernel.sh` after each release, and do not keep the sum of a local stage. Raise `pkgrel` when the same `pkgver` is already published.

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

**No confirmation**: the eMMC write happens synchronously inside the install script of `apk add`. It has no confirmation prompt and no reboot countdown, so that a scripted `apk upgrade` works on many panels. The safety net is the backup, the readback verify and the restore of `tsx-update-boot`, and the `boot_retry` of U-Boot. `tsx-autoupdate` controls when `apk upgrade` runs, for example only in a maintenance window. Put a time policy there, not in the hook. The hook runs only after an upgrade.

### xx50 kernel package

`tsx-xx50-kernel-lts` is a binary package of the same kind. Its `source=` fetches `tsx-xx50-kernel-lts-bundle.tar.zst` of the tsx-xx50-linux release `_kbundle_tag`. The job `kernel` of `release.yml` in that repo builds the bundle. It holds the uImage, the uInitrd (the ramdisk with the boot splash), the rescue system `tsx-xx50-rescue.img` (from v0.3.3 on), the DTB, the modules tarball, `kernel.release`, `kernel.commit` and `CHECKSUMS.sha256`. `package()` checks `CHECKSUMS.sha256` and `kernel.release`.

The xx50 boots from raw slots of its SD card. The install hook runs `tsx-kernel-slots write /boot/uImage-lts /boot/uInitrd-lts` (from `tsx-xx50-board`). It does this only on a TSS-752 that runs from its card, and does nothing in a container or an image build. The command writes only the normal slots. The golden slots keep the last kernel that is known to boot, and U-Boot boots them after two failed boots. After good boots of the new kernel, `tsx-kernel-slots promote` on the panel copies it to the golden slots. `scripts/pin-kernel.sh` is for the xx60 packages only. To pin the xx50 package to a release, set `pkgver`, `_kbundle_tag` and `_kernelrelease`, then run `abuild checksum`.

### xx70 kernel packages

`tsx-xx70-kernel-lts` and `tsx-xx70-kernel-stable` are binary packages of the same kind. The source repository of the xx70 boot image, tsx-xx70-linux, is not public. So the bundle is an asset of a release of this repository: `tsx-xx70-kernel-<flavor>-bundle.tar.zst` of the release `_kbundle_tag` (`xx70-kernel-<YYYYMMDD>`, the date of `pkgver`). The bundle holds `Image.gz`, the eight board DTBs, the modules tarball, the `boot_b` image `tsx-xx70-boot.img` (lk2nd, the kernel, the eight DTBs and the boot initramfs, from `kernel/mkimage.sh` of tsx-xx70-linux), `kernel.release`, `kernel.commit` and `CHECKSUMS.sha256`. The kernel source is the public fork https://github.com/tsx-mainline/linux, branches `tsx-xx70-lts` and `tsx-xx70-stable`.

To make a new bundle:

1. Build the kernel at the pin of `kernel/KERNEL_REV.<flavor>` of tsx-xx70-linux, with `ci/build-kernel.sh` of that repository, on the build host.
2. Build lk2nd at `bootloader/LK2ND_REV` and the boot initramfs of the same tsx-xx70-linux commit (`rootfs/build-rootfs.sh qbootctl`, then `rootfs/build-rootfs.sh initramfs`). A published bundle must use an initramfs without `AUTHORIZED_KEYS` and without `TSX_DEV_RESCUE_HASH`.
3. Run `scripts/stage-kernel-xx70.sh <flavor>` with the build host variables of its header. The script packs the bundle on the build host and writes `pkgver`, `pkgrel`, `_kernelrelease` and `sha512sums` into the APKBUILD.
4. Set `_kbundle_tag` to `xx70-kernel-<date of pkgver>`.
5. Build and test the packages from the staged bundle (`scripts/build.sh`, as for a local build).
6. Make the release `xx70-kernel-<date>` on a published commit of this repository, and attach the two staged bundles without a change. Their sha512 must be the sums of the APKBUILDs.
7. Push the recipes to `main`. CI downloads the assets, checks them against `sha512sums` and builds the packages for aarch64.

The install hook is the same as for xx60: `post-install` and `post-upgrade` run `tsx-kernel-flavor --hook <flavor>` of `tsx-xx70-boot-tools`. The hook writes only when `tsx_is_installed_panel()` finds that `/` is the `system_b` partition, the flavor of the package is the selected flavor, and `boot_b` does not already hold the image. The selected flavor is `KERNEL_FLAVOR` of `tsx-config`. If that is not set, it is the installed flavor with the series of the running kernel. The hook writes `boot_b` through `tsx-update-boot`, which keeps the previous content in `/data/tsx/boot_b.prev.img` and reads the write back. It never writes `boot_a`, the GPT or the boot record. To switch the flavor, run `tsx-kernel-flavor lts|stable` and reboot.

## uc-pxx packages

The uc-pxx family is the Crestron UC-P10 (and the UC-P8, which has no unit for a test yet). Its board repository is uc-pxx-linux. The packages and their sources:

| Package | Content | Sources |
|---|---|---|
| `uc-pxx-boot-tools` | The A/B boot control: `uc-pxx-bootctl`, `uc-pxx-mark-boot.sh` with the service `uc-pxx-boot-ok`, `uc-pxx-flash-boot`, `uc-pxx-arm-slot`, `uc-pxx-reboot`, `uc-pxx-update-boot` | tag archive, tools bundle, `uc-pxx-update-boot` of this repo |
| `uc-pxx-kernel-lts` | `/boot/uc-pxx-lts.img` (no resource, see below), `/lib/modules/<release>/`, `/usr/share/uc-pxx/kernel-lts.release` and the two device trees in `/usr/share/uc-pxx/dtbs-lts/` | kernel bundle |

The image build of uc-pxx-linux (`rootfs/build-rootfs.sh` without the DEV options) installs `uc-pxx-<profile>` and the packages of its `rootfs/packages-tsx.txt` (with `uc-pxx-kernel-lts` and `uc-pxx-leds`). Its `rootfs/check-kernel-pins.sh` reads `/boot/uc-pxx-lts.img` and `/usr/share/uc-pxx/kernel-lts.release`.

All recipes have `arch="aarch64"`, also the ones without a program. A noarch recipe goes to the armv7 folder of its category when it is built on its own.

### Pinned files

`uc-pxx-bootctl`, `uc-pxx-mark-boot.sh`, `uc-pxx-boot-ok`, `uc-pxx-flash-boot` and `uc-pxx-arm-slot` may write the A/B metadata of a panel (misc LBA 49156). A review approved their exact bytes. `_pins` in `uc-pxx/uc-pxx-boot-tools/APKBUILD` holds their sha256 values. `check()` refuses the build when a source file has another sha256, and `package()` checks the installed copies again. `options="!strip"` keeps the bytes of the binary. The package also installs the list as `/usr/share/uc-pxx/boot-control.sha256` (`sha256sum -c` on the panel). Never change a value in `_pins` without a new review of that exact file. `scripts/stage-uc-pxx-tools.sh` refuses a `uc-pxx-bootctl` with another sha256, and `scripts/stage-kernel-uc-pxx.sh` refuses a `kernel/mkimage.sh` with another sha256.

### The boot image and the resource

The Android boot image of the UC-P10 has a Rockchip resource for U-Boot in its "second" part. The resource of the stock firmware (the device tree for U-Boot and the Crestron logo) derives from vendor files, so no package and no bundle holds it. The image in `uc-pxx-kernel-lts` has an empty second part. It is not a complete boot image, and nobody must write it to a partition as it is.

`uc-pxx-update-boot` (package `uc-pxx-boot-tools`) makes the complete image on the panel:

1. It checks the package image: header version 0, page size 2048, no second part, a build token, the id field, the model of its device tree and the kernel release.
2. It reads the boot image header of `boot_b` (read only) and takes its second part. The resource must start with `RSCE` and have an `rk-kernel.dtb` entry.
3. It puts the resource into a copy of the package image, in `/run/uc-pxx/boot-assembled.img`. The result has the same bytes as `kernel/mkimage.sh --resource` with that resource (tested with the v4 image of the UC-P10).
4. `uc-pxx-update-boot write` shows these checks and the A/B state. Then it runs `uc-pxx-arm-slot` and `uc-pxx-flash-boot IMAGE SHA256`. The tool itself opens every block device read only. The flash wrapper is the only writer of `boot_a`.

The install and upgrade scripts of `uc-pxx-kernel-lts` write nothing. They run `uc-pxx-update-boot --hook`, which only says if `boot_a` holds the kernel of the package. To start a new kernel, run `uc-pxx-update-boot write` and reboot. The host test is `scripts/tests/test-uc-pxx-update-boot.sh`.

### Local build while uc-pxx-linux has no tag

uc-pxx-linux has no public repository and no tag yet. The recipes name the future tag `board-v$pkgver` and the future tsx-aports releases `uc-pxx-tools-<YYYYMMDD>` and `uc-pxx-kernel-<YYYYMMDD>`. Each recipe sets `SRCDEST="$startdir/dist"`, so abuild uses a file in `dist/` with the name of the source and checks it with `sha512sums`. CI skips the recipes with a warning while the sources do not exist (`--skip-unreachable`).

1. Run `scripts/uc-pxx-source.sh REPO REF` on the workstation. It writes the archive of a uc-pxx-linux commit into the `dist/` of each recipe with that source and the sum into each recipe. A commit that is not the tag is a snapshot, and the script says so.
2. Copy the repository to the build host (BUILD_DIR).
3. On the build host, run `scripts/stage-uc-pxx-tools.sh BOOTCTL REBOOT RTL8363_INIT NOTE` with the static programs of `tools/` of uc-pxx-linux.
4. On the build host, run `scripts/stage-kernel-uc-pxx.sh KOUT UC_PXX_LINUX`. KOUT is the output folder of `ci/build-kernel.sh` of uc-pxx-linux. The script makes one boot image for each model with a new build token.
5. Copy the changed APKBUILDs back, check the diff, and build with `scripts/build.sh --arch aarch64 uc-pxx/<pkg>`.

To publish, push the tag of uc-pxx-linux, make the two releases of this repository with the staged bundles (unchanged), run `abuild checksum` for the recipes with the tag archive, and check that the content is the same.

## Chromium

The build does not compile Chromium from source, because a from-source build takes hours. CI tracks the `chromium` armv7 package of Alpine v3.24. For each new version it does these steps:

1. It downloads the `.apk`.
2. It applies the 2-byte ES3->ES2 EGL context fallback patch. See `xx60/tsx-xx60-chromium/patch-chromium.py` and `sigs.json`. They come from `tsx-xx60-linux/rootfs/src/chromium-es2/`, with the same tool and the same signature list.
3. It republishes the package as `tsx-xx60-chromium`, signed with the project key.

**If the build does not find the patch site, or its bytes do not match the recorded signature, the build fails. It publishes nothing.** Panels keep the previous build until a person derives a new signature. See the README of that directory, section "Add a new Chromium package version".

`depends=` is a verbatim copy of the `.PKGINFO` of the upstream package. It includes plain dependencies and `so:` soname dependencies. It is not the result of the automatic ELF scan of abuild (`options=!tracedeps`). The package holds the same binaries as the Alpine package, so the Alpine list describes them. The scan would also need about 60 shared libraries in the build container, only to resolve names to versions.

Alpine switched off the armv7 build of `chromium` on 2026-10-15 (see "Kept Alpine packages"). The recipe stays at 152.0.7977.82-r0. Its `fetch()` takes the Alpine `.apk` from the Alpine CDN first. If the CDN does not have the file, it takes the same file from the release `alpine-armv7-chromium-152.0.7977.82-r0` of this repo. That asset is the original Alpine file, not changed, and the `sha512sums` check is the same for both sources. To test the fallback, set `TSX_CHROMIUM_CDN_FAIL=1` for `abuild fetch`.

### Which chromium wins

`tsx-xx60-chromium` sets `provides="chromium=<same version>"` and `replaces="chromium"`. With this repo listed, `apk add chromium` (or a pin in the `packages.txt` of a rootfs) resolves to it. A consumer does not need to know the package name of this repo.

apk does **not** prefer a literal pkgname match over a `provides=` virtual match. When the Alpine `chromium` and `tsx-xx60-chromium` have the same version, apk picks the one whose repository is FIRST in `/etc/apk/repositories`:

| Repository order | `apk add chromium` installs |
|---|---|
| The repos of this project before the Alpine `main` and `community` | `tsx-xx60-chromium` |
| The Alpine repos first | The Alpine `chromium` package |

For this reason, the repository order above lists the repos of this project first.

### Test a build

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

### On an installed panel

- `apk add tsx-xx60-kernel-lts tsx-xx60-kernel-stable` takes over the unowned module trees of the rootfs. The hook of the booted flavor reports that the boot partition already holds its image. The hook of the other flavor reports the flavor that the panel boots.
- `tsx-config set KERNEL_FLAVOR lts && apk fix tsx-xx60-kernel-lts` writes the LTS image from inside the script namespace of apk (backup and readback verify). The panel then boots the LTS kernel (6.18). `tsx-kernel-flavor stable` switches back.
- `apk add tsx-xx60-chromium` on a panel with the Alpine `chromium` removes the Alpine package and installs `tsx-xx60-chromium`. `tsx-xx60-chromium` satisfies the `chromium=<ver>` world pin. Then run `apk del chromium` to remove the pin.
- The package keeps an existing, unowned `/etc/tsx/chromium-es2-patched`. Its own copy arrives as `.apk-new`. Move the copy over the existing file.

`tsx-autoupdate` in tsx-xx60-linux does the three Chromium steps (install, remove the pin, move the file) by itself.

apk-tools 3 (Alpine 3.24) refuses every upgrade while a listed repository is unavailable ("Not continuing due to stale/unavailable repositories"). While this repository is not reachable, a panel that lists it needs `--force-missing-repositories`. It can also use `APK_URL=off` in its panel configuration. tsx-autoupdate adds the option by itself and reports the repository as unreachable.

## Testing channel

The site has two trees:

```
https://tsx-aports.unexceptional.net/v3.24/<category>/<arch>/            stable (branch main)
https://tsx-aports.unexceptional.net/testing/v3.24/<category>/<arch>/    testing (branch testing)
```

The testing tree is complete: it has all of stable, and for each package the testing build when it is newer than the newest stable version. A test panel needs only one URL. CI builds and signs both trees with the same key.

### Use it on a panel

Set `APK_URL` in the panel configuration and apply it:

```
tsx-config set APK_URL https://tsx-aports.unexceptional.net/testing
tsx-config apply
apk update && apk upgrade
```

`tsx-config apply` writes `https://tsx-aports.unexceptional.net/testing/v3.24/common` and `.../testing/v3.24/<category>` as the first lines of `/etc/apk/repositories`. To go back to stable, run `tsx-config unset APK_URL` and `tsx-config apply`. A panel on testing can also get a package that is older than its installed version only with `apk add package=version`.

### Flows

Every deploy starts from the live site and uploads both trees. Pages serves one artifact, so a deploy must not start from an old copy. Two things make that safe (see "Manifest of a deploy"): the run takes the files of the last deploy from its manifest and not from the CDN, and it stops before the upload if another deploy finished while it built.

- **main** (a push to `main`, or a manual run on `main`): builds the new stable versions, prunes to the newest 2 versions, indexes and signs stable. It then builds the testing tree again from the new stable tree and the testing-only packages that are still newer, and signs it. A testing package with the same or an older version than stable is dropped.
- **testing** (a push to `testing`, or a manual run on `main` with `channel` testing and a `source_sha`): a push to `testing` deploys nothing itself. The job `trigger-testing` starts the workflow on `main` (`workflow_dispatch`, with `channel=testing` and the sha of the push), because the environment `github-pages` allows deploys from `main` only. The run on `main` stops unless the sha is on the branch `testing` (`scripts/check-testing-sha.sh`). It takes the recipe folders (`common`, `xx60`, `xx50`, `xx70`, `uc-pxx`, `keep`) from that sha and keeps the scripts of `main`, so a change of `scripts/` on `testing` is not used until it is on `main`. To run a build again, start the workflow by hand on `main` with `channel` testing and the full sha. The base of the build is the live testing tree. It builds only the versions that are new. The stable tree is copied from the live site without a change, and the run stops unless it equals the stable tree of the manifest of the last deploy, file by file (`scripts/manifest.py check-tree`). The testing tree is stable plus the newer testing packages, and keeps only the newest version of each package (`TESTING_KEEP`, so that two trees stay under the size limit of Pages).
- **promote** (a manual run on `main`, action `promote`, input `packages`): `packages` has package names or apk names (as listed in the testing tree), separated by spaces or commas, or `all`. The run copies the apk files of the live testing tree into the stable tree. It promotes whole builds: with an apk it also takes every apk of the same origin and version (the subpackages, for example `tsx-xx60-board-kiosk` and `tsx-xx60-board-ha` with `tsx-xx60-board`) and every apk that it pins with an exact depend (`name=version`) when stable lacks that version. It reads this from the index of the testing tree. It fails if an exact depend is nowhere, or if the index is missing. The bytes are the same, nothing is built again. It signs the stable index again, appends the names and sha256 sums to `promoted.txt` (at the site root, `https://tsx-aports.unexceptional.net/promoted.txt`) and builds the testing tree again. A name that has nothing to promote fails the run before anything is published. There is no gate: the person who starts the run decides.
- **cron** (daily): only the two watch jobs. They publish nothing. A scheduled run uses the workflow of `main`.

Concurrency. All deploys (main, testing, promote) share the group `tsx-aports-publish`, so only one runs at a time and a new run waits for a running one. GitHub keeps ONE waiting run for a group and cancels an older waiting run. Three rules keep that harmless:

- The daily watch run, the pull-request runs and the small trigger run have their own groups. They never take the place of a waiting deploy.
- `scripts/trigger-testing.sh` does not start a testing build while another deploy waits. It checks three times, one minute apart, and then fails with a message. Push to `testing` again (or start the build by hand) when the queue is empty. A running deploy does not block it: the testing build then waits alone behind it.
- A push to `main` while a testing build waits replaces that testing build (it is the only waiting run). Then start the testing build again by hand: Actions > build > Run workflow on `main` with `channel` testing and the full sha.

The rule that a testing run never cancels a waiting stable deploy has one gap: GitHub does not offer a queue, so a person who starts a manual run on `main` while a deploy waits can still replace the waiting run. The check before the upload (see "Manifest of a deploy") stops a deploy whose base is out of date, so two deploys that run at the same time cannot publish a tree that lacks the other one.

### Manifest of a deploy

Each deploy writes `manifest.txt` at the root of the site. It lists the sha256 of every published file, and the run id. After a successful deploy, the deploy job keeps it as the artifact `live-manifest` (90 days). The CDN of Pages can serve the tree of an older deploy for up to 10 minutes. A request header or a query string does not change that (checked on the live site). So a run does not trust the CDN. It does these steps:

1. It takes the newest `live-manifest` (`scripts/live-manifest.sh`). Only an artifact of a run of this workflow counts: the run is `build.yml`, its branch is `main`, its head repository is this repository (no fork), and its event is `push` or `workflow_dispatch`. The script reads up to 5 pages of 30 artifacts. Only "no such artifact" means none. An API error stops the run at once. Without a manifest, a testing or promote run fails. A stable run trusts the live site, with a warning. This is the case for the first deploy with this workflow: run a stable build on `main` first.
2. It polls the index files, `promoted.txt` and `CNAME` of the live site until they equal the manifest (`scripts/manifest.py wait`, up to 11 minutes).
3. It fetches the trees and requires that they equal the manifest: the same files with the same bytes. A 404 for one index, which would drop a category, fails here.
4. A testing deploy checks that the stable tree it publishes equals the stable tree of the manifest. It does not compare with its own fetched copy.
5. Right before the upload, the run checks that no other deploy finished meanwhile. If one did, the run stops and you start it again.

If a deploy went live without its `live-manifest` (the deploy job failed after `deploy-pages`, or the artifact expired), start a stable build by hand on `main` with `trust_live` set. It skips the manifest check and trusts the live site, like the first deploy. `trust_live` is refused for testing and promote. Use it only after you checked that the live site is what you expect.

If the wait for the CDN ends after 700 s with an error, the live site still shows an older tree. Wait a few minutes and start the run again.

A testing or promote run never uses the seed: `seed_url` is refused for them, and the fallback seed is only for a stable run when nothing is published.

To test a change, raise `pkgrel` or `pkgver`. A package with the version that stable has is not built again, and a testing build of an existing version is dropped.

### Commit sources

On the branch `testing` only, a recipe can build from the GitHub archive of one commit, so a change that has no tag yet can be tested:

```
_commit=<40 hex characters>
source="tsx-linux-common-$_commit.tar.gz::https://github.com/<org>/tsx-linux-common/archive/$_commit.tar.gz"
builddir="$srcdir/tsx-linux-common-$_commit"
```

1. Pin the full 40-character sha. A branch name or a short sha is refused, because the bytes of such an archive change. `sha512sums` stays in the recipe as always.
2. Write `pkgver` as the next release plus `_pre<YYYYMMDD>`, for example `0.4.0_pre20261026`. In the order of apk, `0.4.0_pre20261026` is newer than `0.3.9` (stable) and older than `0.4.0`, so the tagged release is newer than the test build. For a second build on the same day, raise `pkgrel`.
3. `scripts/build.sh` refuses a commit source unless `TSX_APORTS_CHANNEL=testing` (CI sets it for the branch `testing`). On `main` and on other branches, a commit source stops the build before the first package. `scripts/tests/test-sources.sh` uses the same rule: it accepts commit sources on the branch `testing` and fails on every other branch.

Workflow:

1. Push the change to a branch of the source repository (for example tsx-linux-common) and note the commit sha.
2. On the branch `testing` of tsx-aports, put the sha and the `_pre` version in the recipe, run `abuild checksum`, and push. The trigger job starts the testing build on `main`, and it deploys the testing tree.
3. Test on a panel with `APK_URL` set to the testing URL.
4. Merge the change in the source repository, and put the signed tag on **the same commit** that you tested. If the tag is on another commit, the release is not what you tested.
5. On `main`, point the recipe at the tag (`pkgver` without `_pre`, the `refs/tags/` source) and push. CI builds the release from the tag. This is the normal way. The stable package has the clean release version, and the build from the signed tag has the same source as the tested commit.
6. Use promote only when the tested bytes must go to stable at once (for example a fix that cannot wait). Then stable gets `0.4.0_pre20261026`, built from the commit. The tag must still point at that commit. The later release `0.4.0` replaces it.

### Branches

- `main` stays linear: a fast-forward of tested commits, no merge commits, no force push.
- `testing` moves freely. Force push is allowed. Rebase it on `main` after each change of `main`, so that its workflow file (with the trigger job) is the one of `main`. Do not merge `testing` into `main`: pick the commits that go to stable.
- A push to `testing` leads to a build with the real signing key and a deploy, like a push to `main`: the recipes of the commit run in the build, and a recipe can read the key. So a commit on `testing` has the same power as a commit on `main`. Give push rights to `testing` to the same people as for `main`. The workflow stops a build whose sha is not on `testing`, but it cannot tell who pushed. The secret `TSX_APORTS_PRIVKEY` can be moved to an environment secret that only `main` may read. That is a GitHub setting for the user to decide, and the trigger flow does not need it.
- A force push of `testing` does not remove a build from the testing tree. A package stays there until a newer version of it comes in stable or testing.
- A recipe version that is not in the tree that `--skip-existing` reads is built again by every run, and then dropped or pruned. This happens when `testing` lags behind `main` for a package, or when `main` lags behind a promoted version. Keep the versions of `testing` and `main` in step, in particular for `tsx-xx60-chromium` and `tensorflow-lite-c`, which build for a long time.

### One-time GitHub step

Create the branch `testing` from `main`, after the workflow with the trigger job is on `main`. No setting changes: the deploy runs on `main`, which the environment `github-pages` already allows. The trigger job asks for the permission `actions: write` in the workflow file itself.

### Size

Two trees are in one Pages artifact. Stable keeps 2 versions of each package and testing keeps 1. Measured on a copy of the live tree: stable is 344 MiB (88 apks), and the site with both trees is 616 MiB (142 apks), which is 1.79 times stable. Pages has a soft limit of 1 GB. The site is at risk when a large package arrives: a new `tsx-xx60-chromium` adds about 127 MiB in stable (two versions), and a newer testing chromium adds 127 MiB more. A new kernel adds 27 to 38 MiB each. With a new chromium in both trees, the site can reach about 900 MiB. Watch the size (see "Hosting and size"). If it gets near the limit, lower `STABLE_KEEP` or list only the packages that are newer in testing and give a test panel two repository lines.

The tests are `scripts/tests/test-mode.sh` (the mode of a run, the check of the testing sha, the recipes of a testing run, the trigger), `scripts/tests/test-manifest.sh` (the manifest and the wait for the CDN), `scripts/tests/test-channels.sh` (assemble, promote with subpackages, apk order), these three without docker, and `scripts/tests/test-site.sh` (docker, builds fixture packages).

## Hosting and size

GitHub Actions builds and publishes the packages. GitHub Pages serves them behind the custom domain `tsx-aports.unexceptional.net` (a `CNAME` file in the published tree). GitHub Pages has a soft limit of about 1 GB and no CDN-side pruning. `tsx-xx60-chromium` alone is over 100 MB for each build. It only repacks and does not compile, so a new build publishes within minutes of an Alpine release.

`scripts/index.sh --keep 2` (the CI default) keeps the newest version and one previous version of every package. A subpackage is a package of its own: tsx-xx60-board-ha does not count as a version of tsx-xx60-board. It then re-signs the pruned index. The host test is `scripts/tests/test-index-prune.sh`.

Watch the size of the published tree. It has all packages, both kernel flavors, and two chromium versions while a second one exists. One version of everything is about 190 MB.

### Kept packages

The rescue initramfs of tsx-xx60-linux takes a few files from exact package versions: `rootfs/initramfs/packages.pin` of that repo (for example `tsx-xx60-board=0.2.0-r1`). The boot image in each kernel package carries such an initramfs, and its stamp covers `packages.pin`. So the pins move only together with new kernel packages. The release build of tsx-xx60-linux (`release.yml`) and its image build (`rootfs.yml`) take these versions from the published tree. If the prune deletes one, both builds fail.

`keep/keep.txt` lists these files with their sha256. `keep/v3.24/` holds a copy of each file, the published bytes signed with the project key. `scripts/index.sh` does these steps:

- It does not prune a kept file, and a kept file does not count as one of the `--keep N` versions.
- If the tree lacks a kept file, it copies the file from `keep/v3.24/` and checks the sha256.
- If the tree has a kept file with another sha256, it stops.

`scripts/pin-kernel.sh TAG` runs `scripts/keep-pins.sh TAG`. That script reads `packages.pin` of TAG and writes `keep/keep.txt` and `keep/v3.24/` again: a pin that the list has keeps its file, a new pin comes from the published tree, and a file that no pin names goes. Commit the changes of `keep/` with the kernel recipes. The host tests are `scripts/tests/test-index-prune.sh` and `scripts/tests/test-keep-pins.sh`.

#### Kept Alpine packages

`tsx-xx60-chromium` depends on `chromium-common=152.0.7977.82-r0`, and that package depends on `chromium-angle=152.0.7977.82-r0`. On 2026-10-15 Alpine switched off the armv7 build of `chromium` (aports commit 7e8aa9ca: the link step runs out of memory on the builders). The v3.24 armv7 index of Alpine lists no `chromium`, `chromium-common` or `chromium-angle` since then. The old files are still on the CDN, but no index lists them, so `apk add` fails with "chromium-common (no such package)".

`keep/keep-alpine.txt` lists the two armv7 files with their sha256. `keep/alpine/v3.24/` holds the original Alpine files. They keep the signature of Alpine (`alpine-devel@lists.alpinelinux.org-616adfeb`). We do not sign them again, and a panel already trusts that key. `scripts/index.sh` handles these files like the other kept files (no prune, no count, copy back with sha256 check) and lists them in the index of `xx60/armv7`. `scripts/keep-pins.sh` does not touch them. The packages carry `license=BSD-3-Clause` in their metadata and no license file.

To add or change a kept Alpine file, run `scripts/keep-alpine.sh CATEGORY URL`. It downloads the file, runs `apk verify` in the armv7 container, copies the file to `keep/alpine/v3.24/` and adds its line to `keep/keep-alpine.txt`.

## CI

`.github/workflows/build.yml` builds and publishes the repository. It has five jobs:

- **build** runs on a push to `main` that changes `common/`, `xx60/`, `xx50/`, `xx70/`, `uc-pxx/`, `scripts/`, or the workflow. It also runs on manual runs and on pull requests. It does these steps:
  1. `scripts/carry-forward.py` restores the published tree into `packages/v3.24`. It checks every index signature against the committed public key. It checks every apk against the checksum in its signed index.
  2. `scripts/build.sh --verify --skip-existing --skip-unreachable --all` builds in dependency order: a package comes after each package of the repo that it depends on or makes depends on. It builds only the versions that are not in the published tree. `--verify` makes the build fail when a download does not match the `sha512sums` of its APKBUILD. It skips a package with a warning when its tag archive or its release asset does not exist yet (a kernel bundle, the xx50 panel app source). The published copy of that package stays.
  3. `scripts/assemble-site.sh` runs `scripts/index.sh --keep 2`. It puts back a kept package that the tree lacks (see "Kept packages"), prunes, and re-indexes and signs the merged tree. It then builds the testing tree and checks both trees against the committed key.

  A pull request builds with a throwaway key and publishes nothing. A manual run on a branch other than `main` does the same: the signing key and the Pages deploy need the ref `main`. Every deploy uploads both trees (see "Testing channel").
- **trigger-testing** runs on a push to `testing`. It deploys nothing. It starts the workflow on `main` for the testing channel (see "Testing channel").
- **deploy** publishes that tree with `actions/deploy-pages`.
- **wlroots-watch** runs daily. It compares `tsx-xx60-wlroots0.20` with the Alpine v3.24 armv7 `wlroots0.20`. If Alpine has another build, it opens an issue (once for each version). A person then checks the fix and rebases the package, or switches the panels back (see "Packages" above).
- **chromium-watch** runs daily. It checks the Alpine v3.24 armv7 `chromium`. If that is newer, it opens a pull request that changes the pin. It needs the setting "Allow GitHub Actions to create and approve pull requests" in the Actions settings of the repo.

At the first deploy, the site is empty and nothing exists to carry forward. Put a tarball of a published tree on the release `seed` as `tsx-aports-seed.tar.gz`. The tree is `v3.24/<category>/armv7/...`, with public packages only. A run that finds the site empty uses the tarball automatically. A manual run can name another tarball with the `seed_url` input. To see the local options, run `scripts/carry-forward.py --help`. The test is `scripts/tests/test-ci-pages.sh` (host, packaging only).
