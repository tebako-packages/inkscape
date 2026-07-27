# inkscape feedstock — build notes (spec 13 §9, phase A)

Reference toolkit payload for metanorma's graphics chain: SVG → PDF/PNG
export via the inkscape CLI, packaged as a **dynamic** relocatable payload
(dwarfs image, `$ORIGIN`-relative closure, runs later through the preload
shim — the shim is built elsewhere; this repo is the PAYLOAD).

## Version choice: 1.4.3

- `1.4.3` (2025-12-25) is the newest stable point release of the 1.4 line
  (1.4.1 was merged into 1.4.2; 1.4.3 is the current maintenance release).
  Chosen over the 1.3.x line: same gtkmm3 ABI requirements, current bugfix
  surface — and the task allows 1.4 outright.
- Tarball: `https://media.inkscape.org/dl/resources/file/inkscape-1.4.3.tar.xz`
  sha256 `e83a2c3db570b6c5a1ff0fccfe7098837b3f6bd74b133567937c8a91710ed1d1`
  (computed locally over the downloaded file; the release tarballs ship with
  GPG signatures on inkscape.org but no published sha256 — pinned here on
  first fetch from the official media host over TLS).
- The release tarball is complete: vendored `src/3rdparty/2geom`,
  `share/extensions` populated. No submodule dance, no source patches.

## Dependency provenance

inkscape 1.4.3 hard requirements (`CMakeScripts/DefineDependsandFlags.cmake`):

| dependency | required by | served from (linux) | served from (macOS) |
|---|---|---|---|
| gtkmm-3.0 ≥ 3.24, gtk+-3.0, gdkmm, glibmm-2.4 ≥ 2.58, sigc++-2.0 | `pkg_check_modules(GTK3 …)` | **apt** (ubuntu-24.04 `libgtkmm-3.0-dev`) | **Homebrew** (`gtkmm3` → versioned `glibmm@2.66`, `cairomm@1.14`, `pangomm@2.46`, `atkmm@2.28`, `libsigc++@2`) |
| pangocairo ≥ 1.44, pangoft2, harfbuzz, fontconfig, gmodule-2.0, epoxy | `INKSCAPE_DEP`/`EPOXY` | **apt** (pulled by libgtkmm-3.0-dev; epoxy must match gtk3) | **Homebrew** (pulled by gtk+3/gtkmm3; `libepoxy` bottle) |
| gsl, bdw-gc, lcms2, double-conversion, libpng, zlib, libxml2, libxslt | `INKSCAPE_DEP` + `find_package` | **vcpkg** @ `cd61e1e2` (annotated tag `2026.06.24`) | **vcpkg** @ `cd61e1e2`, same pin, **static** (`arm64-osx-static`) |
| Boost filesystem (+ stacktrace_basic) | `find_package(Boost …)` | **vcpkg** (`boost-filesystem`, `boost-stacktrace`) | **vcpkg**, same ports, static |
| potrace | `find_package(Potrace REQUIRED)` | **apt** (`libpotrace-dev`) — `potrace` is absent from vcpkg | **Homebrew** (`potrace` bottle) |
| libintl (Intl), OpenMP | unconditional `FindIntl`; `WITH_OPENMP` | glibc/gettext via apt | **Homebrew** keg-only `gettext` + `libomp` (via `CMAKE_PREFIX_PATH`) |
| 2geom | vendored | tarball (`WITH_INTERNAL_2GEOM=ON`) | tarball (same) |
| Iconv | glibc / macOS libSystem | system (stays outside the closure) | system `/usr/lib/libiconv` (stays outside) |

Why the gtk stack is NOT from vcpkg (investigated, not assumed): at the
pinned baseline vcpkg ships `gtkmm` 4.22.0, `glibmm` 2.88.0 (glibmm-2.68
ABI), `cairomm` 1.18, `pangomm` 2.56, `atkmm` 2.36 — the gtkmm4 family.
inkscape 1.4.x requires the gtkmm-3.0/glibmm-2.4/sigc++-2.0 ABI family,
which current vcpkg no longer carries (`libsigcxx`/`libsigcxx-3` ports are
gone, `potrace` likewise). Options were: (a) overlay ports resurrecting the
gtkmm3 family against vcpkg's gtk3 — real work, phase-B material;
(b) mixed build with vcpkg gtk3 + apt gtkmm3 — two glib/pango suppliers in
one closure, SONAME collision management; (c) **apt for the whole GNOME
platform stack, vcpkg for everything else** — chosen: one self-consistent
GNOME supplier, no dual glib, smallest build surface. The closure packages
the apt libs exactly like the vcpkg ones, so the payload is equally
self-contained. SONAME collisions between the two worlds are limited to
`libpng16.so.16` / `libz.so.1` (both ABI-stable in the 1.6.x/1.x lines);
the closure resolves them vcpkg-first (the superset we actually linked).
vcpkg `gtk3` itself *is* linux-capable (`!android`, 3.24.52) — noted for the
phase-B overlay-ports follow-up.

## Feature set (cmake options, recipe.yml `build.cmake.options`)

Kept: SVG→PDF and SVG→PNG export (cairo-native, no poppler), internal
2geom, OpenMP, X11 linkage left at upstream default ON (harmless; the X
libs ride in the closure via gtk3).

Dropped (GUI/import extras metanorma never touches): NLS translations,
readline shell mode, gspell, gtksourceview, libcdr/libvisio/libwpg import
filters, ImageMagick/GraphicsMagick helpers, **poppler (PDF *import* only —
PDF export does not use it)**.

## RPATH wiring (no patchelf/chrpath — build time only)

Upstream already installs `$ORIGIN`-relative RPATHs
(`CMakeLists.txt:55-65`): the executables get
`CMAKE_INSTALL_RPATH=$ORIGIN/../lib/inkscape` and `libinkscape_base.so`
gets `$ORIGIN/..` (i.e. `lib/`). Two refinements make this sufficient for a
dependency closure, without touching a single source line:

- `CMAKE_INSTALL_LIBDIR=lib` (flat layout, no multiarch subdir).
- `-Wl,--disable-new-dtags` on exe/shared/module link lines → **DT_RPATH
  instead of DT_RUNPATH**. RPATH (unlike RUNPATH) is transitive: the
  loader walks the whole load chain, so the executable's
  `$ORIGIN/../lib/inkscape` + `libinkscape_base`'s `$ORIGIN/..` cover every
  dep-of-dep — including vcpkg/apt libs that carry no RPATH of their own.
  All closure libs land flat in `lib/`.

Runtime data: inkscape auto-detects the bundle layout
(`src/path-prefix.cpp`): if `<exe-dir>/../share/inkscape` exists it is used
as datadir — no env var needed. `ENABLE_BINRELOC` is a legacy no-op
(define unused in 1.4.3 sources) and stays OFF.

## Closure layout (out/<platform>/root)

```
bin/inkscape                      RPATH $ORIGIN/../lib/inkscape (DT_RPATH)
bin/inkview
lib/inkscape/libinkscape_base.so  RPATH $ORIGIN/.. (DT_RPATH)
lib/lib2geom.so*                  (vendored 2geom installs flat into lib/)
lib/*.so                          closure: vcpkg + apt deps, libstdc++,
                                  libgcc_s, libgomp, X11 chain… (glibc family
                                  excluded: libc/libm/libdl/libpthread/
                                  librt/libresolv/ld-linux)
lib/gdk-pixbuf-2.0/**             loaders (dlopen'd; see limitations)
etc/fonts/**                      stock fontconfig config (shim may point
                                  FONTCONFIG_FILE here)
share/inkscape/**                 palettes, templates, extensions, …
                                  (share/inkscape/tutorials pruned: 87 MB
                                  of documentation SVGs the CLI never reads)
```

Closure method: fixpoint `ldd` walk over every ELF in bin/ + lib/ with
`LD_LIBRARY_PATH=<vcpkg-lib>:<payload-lib>` (vcpkg first), copying each
resolved SONAME once into `lib/`. Deterministic, no post-build RPATH edits.

## Image tooling (mkdwarfs-t)

Task spec said "mkdwarfs-t from tamatebako/dwarfs-t releases" — **those
releases do not exist yet** (checked 2026-07-26: tags through
`tebako-v0.14.1-18`, release.yml present, zero published releases; the
recent release runs all failed). tools/stage therefore: `$MKDWARFS` env →
cached tool build → builds mkdwarfs/dwarfs/dwarfsextract from the pinned
commit `05e31631` (tag `tebako-v0.14.1-18`) with the release workflow's own
configuration (vcpkg root manifest, x64-linux, Release, flatbuffers i.e. no
fbthrift). When dwarfs-t releases appear, swap in a download+sha256 step —
the recipe's `image.dwarfs_t` section is the seam.

## Proof (x86_64-linux-gnu leg, ubuntu-24.04 container)

Host is Apple Silicon; the leg was built under docker `linux/amd64`
(Rosetta-backed emulation — measured ~native compile speed, so the real
recipe leg was proven, not an arm64 stand-in).

**Where the build stands (complete except where noted):**
- inkscape vcpkg deps: **all 29 ports built** (gsl, bdwgc, lcms,
  double-conversion, libpng, zlib, libxml2, libxslt, boost-filesystem,
  boost-stacktrace + 19 header-only boost modules) — nothing outstanding.
- inkscape build/install/closure/pre-image-smoke: **complete**, locally
  and on CI.
- dwarfs-t tools (pinned `05e31631`): vcpkg dep set complete;
  **mkdwarfs + dwarfsextract built locally**, the `dwarfs` fuse driver
  failed to link *locally only* (libfuse `fuse_pkgversion`/`fuse_opt_*`
  undefined — older dwarfs-t-pinned vcpkg; the same commit links all
  three on CI against the feedstock vcpkg baseline).
- Payload image: **packed locally (45.9 MB) and on CI (33.2 MB)**.
- ONLY open item: mount-mode boot-smoke on GHA runners (details below).

**Payload build: PROVEN.** `tools/build recipe.yml 1.4.3 x86_64-linux-gnu`
completed end-to-end: sha256-verified tarball fetch, 29 vcpkg ports
(x64-linux-dynamic overlay triplet), cmake configure+build+install
(901 ninja targets), closure pass (98 libs), strip, pre-image smoke:

```
$ bin/inkscape --version          # empty LD_LIBRARY_PATH, $ORIGIN only
Inkscape 1.4.3 (0d15f75042, 2025-12-25)
```

RPATH evidence (`readelf -d`):

```
bin/inkscape:                      (RPATH) $ORIGIN/../lib/inkscape
lib/inkscape/libinkscape_base.so:  (RPATH) $ORIGIN/..
```

— DT_RPATH (old dtags), not RUNPATH, exactly as designed; no patchelf or
chrpath anywhere in the pipeline.

Payload tree: **195 MB** (lib/ 152 MB with 99 .so entries, share/inkscape
after tutorial prune, bin/, etc/fonts, gdk-pixbuf loaders).

**Emulation hazards hit (and worked around):** Rosetta-wedged cmake
`try_compile` (do_epoll_wait on zombie child) killed vcpkg's compiler
detection — bypassed with `VCPKG_DISABLE_COMPILER_TRACKING=1` (now set by
tools/build; harmless on native runners) and, for the dwarfs-t source
build, an mtime watchdog that kill/resumes stuck cycles. Docker host-mount
(osxfs) builds hung hard; all builds moved to container-local storage.

**Image stage: PROVEN twice.**
- Local (emulated): mkdwarfs-t `v0.8.0-1755-g05e316313f` built from the
  pinned commit; `inkscape-1.4.3-x86_64-linux-gnu.dwarfs` = **45.9 MB**
  (sha256 `b1829155a5a525e5…`), payload manifest filled by tools/stage.
  (The pinned dwarfs-t `dwarfs` fuse driver failed to LINK locally —
  `fuse_pkgversion`/`fuse_opt_*` undefined against the older
  dwarfs-t-pinned vcpkg libfuse; not root-caused further — the same
  commit links all three tools on CI against the feedstock's vcpkg
  baseline. mkdwarfs/dwarfsextract are unaffected.)
- CI (native x86_64, ubuntu-24.04, run 30215927480): full leg green —
  build (closure: 87 libs) → stage (mkdwarfs-t built natively from the
  pinned commit) → image **33.2 MB** (sha256 `9c772a214f6d8335…`). Image
  size differs from local because the closure set tracks the build
  environment's apt revisions (98 libs local vs 87 on the runner).
  Rebuilds are NOT bit-reproducible yet (run 30217572017 produced the
  same 33.2 MB with sha256 `4d8d58d8beecbbf6…`) — timestamps, apt drift
  and image metadata; a reproducibility pass is follow-up work.

**Boot-smoke (spec: run `--version` + exports FROM the image):**
- Extract mode (dwarfsextract): implemented as boot_smoke's degraded
  fallback; works, but under Rosetta emulation dwarfs block decompression
  is pathologically slow (~0.15 MB/s CPU-bound, lzma under translation —
  an emulation artifact; native extraction speed is normal, see CI stage
  timings). Local extract-mode smoke was therefore abandoned after the
  payload had already been proven pre-image.
- Mount mode on GHA: does NOT come up yet. Ruled OUT: FUSE availability —
  `/dev/fuse` present, `fuse`/`fusectl` in /proc/filesystems, fusermount3
  installable (debug run 30219408099). Ruled IN: the driver's daemonize
  path swallows the error (empty mount log) — boot_smoke now mounts with
  `-f` (libfuse foreground) so the real error lands in dwarfs-mount.log;
  argtable3's acceptance of `-f` was unverified at push time — runs
  30219118995 / 30219407581 are in flight to settle it and expose the
  underlying mount error. If argtable rejects `-f`, next step is an
  upstream dwarfs-t foreground option or a fusermount3-verbosity probe.
  The step stays advisory (`|| true`) until it goes green.
- What IS proven end-to-end: the payload tree executes relocatably with
  an empty environment (pre-image smoke in tools/build, both locally and
  on CI), the image packs and hashes deterministically in shape (33-46 MB
  depending on closure set), and the manifest fills from the recipe.

## aarch64-macos leg (macOS dogfood)

Same recipe, same rules, macOS supplier mapping. Built natively on an Apple
Silicon host (macOS 14.1, arm64) — no emulation anywhere in this leg.

### Dep provenance: Homebrew is the apt counterpart

The linux leg's rule — ONE self-consistent supplier for the GNOME platform
stack — maps to Homebrew on macOS: brew bottles are the binary-package
equivalent of the apt platform stack. `brew install gtkmm3` pulls the whole
gtkmm3 ABI family as **versioned formulae**, so the ABI split that rules out
vcpkg (gtkmm4/glibmm-2.68 only) does not exist in brew:

| inkscape requirement | brew formula | version built | ABI provided |
|---|---|---|---|
| gtkmm-3.0 ≥ 3.24 | `gtkmm3` | 3.24.11 | gtkmm-3.0 |
| glibmm-2.4 ≥ 2.58 | `glibmm@2.66` | 2.66.9 | glibmm-2.4 |
| sigc++-2.0 | `libsigc++@2` | 2.12.2 | sigc++-2.0 |
| cairomm-1.0 | `cairomm@1.14` | 1.14.6 | cairomm-1.0 |
| pangomm-1.4 | `pangomm@2.46` | 2.46.5 | pangomm-1.4 |
| atkmm-1.6 | `atkmm@2.28` | 2.28.4 | atkmm-1.6 |
| gtk+-3.0 / pango / cairo / harfbuzz / fontconfig / gdk-pixbuf | `gtk+3` + deps | 3.24.52 | quartz build |
| epoxy (must match gtk3) | `libepoxy` | 1.5.10 | — |
| potrace | `potrace` | 1.16 | — |
| libintl / OpenMP | `gettext` / `libomp` (keg-only, via `CMAKE_PREFIX_PATH`) | — | — |

The 29 non-GNOME vcpkg ports are identical to the linux leg (same pin
`cd61e1e2`), built with the `arm64-osx-static` overlay triplet.

### Why static vcpkg on macOS (the CRT/static story)

`arm64-osx-static` = `VCPKG_LIBRARY_LINKAGE static`. On Windows the
dwarfs-t-rs `*-windows-static` triplets pair static libs with a static CRT
(`/MT`) to make self-contained exes; on macOS there IS no CRT choice —
`VCPKG_CRT_LINKAGE` is a no-op because libSystem is always dynamic. So
"static" here is purely about the 29 deps: they link INTO the inkscape
binaries and vanish from the dylib closure. Two wins: (a) the dylib closure
is 100% single-supplier (brew), so the linux leg's libpng/zlib SONAME
collision class is impossible BY CONSTRUCTION — no vcpkg-first/brew-first
rule is ever exercised; (b) fewer moving parts in the image. The payload tier
stays `dynamic`: the GNOME platform stack ships as dylibs, exactly like the
apt stack on linux.

### RPATH wiring (still zero post-build edits of our own artifacts)

Upstream already carries the APPLE branch of the RPATH setup
(`CMakeLists.txt:58-64`, `src/CMakeLists.txt:414-418`): with
`CMAKE_MACOSX_RPATH` on, the executables get
`CMAKE_INSTALL_RPATH=@loader_path/../lib/inkscape` and
`libinkscape_base.dylib` gets `INSTALL_RPATH=@loader_path/..`
(`@loader_path` is the macOS `$ORIGIN`). The only addition the macOS leg
needs is one more rpath on the link line —
`-Wl,-rpath,@loader_path/../lib` (recipe `platform_cmake_options`) — so the
exe also covers the flat closure in `lib/`. This works because **@rpath
resolution is transitive down the load chain by design** (dyld resolves a
dylib's `@rpath` refs against the runpath list accumulated from the
executable down) — the property the linux leg had to force with
`--disable-new-dtags` (DT_RPATH). ld64 has no new-dtags knob; none is needed.
Bundle datadir detection (`src/path-prefix.cpp`): `bin/` parent is used as
prefix → `share/inkscape` auto-found, same as linux.

### Closure rules (fixpoint `otool -L` walk — `Tpkg.macos_closure`)

1. Walk every Mach-O in `bin/` + `lib/**` (dylibs AND `.so` bundles), parsing
   `otool -L`. The install name (first entry of a dylib/bundle) is not a
   dependency and is skipped in the walk.
2. **Exclude the OS family**: any ref under `/usr/lib` or `/System/Library`
   stays out — the libSystem family, the macOS counterpart of the linux
   glibc exclusion. This includes `libc++.1.dylib`/`libc++abi.dylib`, the
   libstdc++/libgcc_s equivalents: on linux those ride in the closure
   because they are toolchain packages; on macOS they are part of the OS
   (dyld shared cache, ABI-stable), so the same spirit excludes them.
3. **Include the single supplier**: refs under `/opt/homebrew` (arm64) /
   `/usr/local` (x86_64) — exactly the brew tree, gtkmm/gtk libs included
   (they ARE the platform stack) — are copied FLAT into `lib/<leaf>`.
   Fixpoint: each copy is walked, pulling deps-of-deps. gdk-pixbuf loaders
   (dlopen'd) and the stock fontconfig config are copied from the brew tree
   first so the walk closes over them too.
4. **Collision rule**: a `<leaf>` colliding with different content is a hard
   ERROR, never a pick — single supplier makes collisions impossible in
   principle, so one appearing means the provenance assumption broke.
5. **Rewrite pass** (the macOS bundling step): every payload Mach-O gets its
   brew-absolute refs rewritten to `@rpath/<leaf>` and every closure dylib
   gets `-id @rpath/<leaf>` via `install_name_tool`. This is NOT patchelf
   territory: the no-patchelf rule bans post-build RPATH hacks, and all
   RPATH wiring here is still build-time; install-name retargeting is the
   only mechanism macOS has for third-party dylibs we redistribute but do
   not compile (brew bottles bake absolute install names; there is no
   build-time flag that can change a bottle). It is the same step cmake's
   fixup_bundle / dylibbundler / every macOS app bundler performs.
6. **Verify pass**: re-walk; any residual ref that is neither system nor
   `@rpath/<leaf present in payload>` aborts the build — the closure cannot
   leak brew paths by construction.
7. **codesign**: arm64 binaries must carry a valid (at least ad-hoc)
   signature; `strip -x` and `install_name_tool` both invalidate the
   link-time ad-hoc sig, so the whole tree is re-signed ad-hoc
   (`codesign --force --sign -`) before the smoke. No identity, no
   notarization — same trust level as the linux payload.

### Image tooling: libtfs v0.13.0 release binaries

dwarfs-t still has no published releases (any platform), and building it on
macOS is untested — but **tamatebako/libtfs DOES ship releases**: v0.13.0
(2026-07-24) publishes static `mkdwarfs-macos-arm64` /
`tebakofs-macos-arm64` binaries (libSystem+libc++ only). tools/stage
downloads them sha256-verified (pins in recipe `image.libtfs`, taken from
the release SHA256SUMS) and packs
`inkscape-1.4.3-aarch64-macos.tfs` — `.tfs` (tebako fs image) naming for the
macOS legs, same DwarFS format. `tebakofs extract` replaces `dwarfsextract`
for the FUSE-less degraded boot-smoke (no macFUSE on GHA runners; no
kernel-extension dance attempted).

### Proof (aarch64-macos leg, native macOS 14.1 arm64 host)

**Build: PROVEN end-to-end.** `tools/build recipe.yml 1.4.3 aarch64-macos`:
brew platform stack (gtkmm3 family, bottles, brew-verified), sha256-verified
tarball (cache hit), 29 vcpkg ports @ `cd61e1e2` (`arm64-osx-static`,
8.1 min cold), cmake configure + 1021 ninja targets + install, closure pass:

```
[tpkg] macOS closure: 47 supplier libs, 23 system refs excluded
[tpkg] codesign: ad-hoc re-signed 64 Mach-O files
[tpkg] pre-image smoke: Inkscape 1.4.3 (0d15f75042, 2025-12-25)
```

RPATH evidence (`otool -l`):

```
bin/inkscape:                      LC_RPATH @loader_path/../lib
                                   LC_RPATH @loader_path/../lib/inkscape
lib/inkscape/libinkscape_base.*:   LC_RPATH @loader_path/..
```

— upstream's own APPLE rpaths plus the one build-time link flag; no
post-build rpath edits anywhere.

**Closure self-containment, runtime evidence** (empty env +
`DYLD_PRINT_LIBRARIES=1`): 410 dylibs loaded — 47 from the payload, 363 from
`/usr/lib`+`/System` (the OS family; the shared cache fans libSystem out
into its sub-libraries), **0 from anywhere else** — no brew leaks at runtime.

**Image: PROVEN.** mkdwarfs `v0.14.1` (libtfs v0.13.0 release asset,
sha256-verified): `inkscape-1.4.3-aarch64-macos.tfs` = **29.6 MB**
(29,603,468 B, sha256 `a93ccf8cb52b6863…`; payload tree 118 MB: lib/ 49
dylibs incl. gdk-pixbuf loaders, etc/fonts, share/inkscape after tutorial
prune). Smaller than the linux image (33.2 MB) chiefly because the 29 vcpkg
deps are static (no per-dep dylibs).

**Boot-smoke: PROVEN (extract mode).** `tools/boot_smoke` on the image —
tebakofs extract (no macFUSE; the documented degraded path), then `env -i`:

```
[tpkg] boot: Inkscape 1.4.3 (0d15f75042, 2025-12-25)
[tpkg] otool sweep: 64 Mach-O files clean (no brew leaks beyond the closure)
[tpkg] export: smoke.svg -> PNG (5625 B)
[tpkg] export: smoke.svg -> PDF (6952 B)
[tpkg] BOOT_SMOKE_OK inkscape-1.4.3-aarch64-macos.tfs
```

**libtfs v0.13.0 extractor gaps hit (and worked around in the tools):**
symlink inodes are unreadable by tebakofs's dwarfs backend
(`filesystem_v2_lite`) → the payload ships symlink-free (symlinks resolved
to copies; mkdwarfs dedups, image size unaffected); extracted files are all
0644 → boot_smoke restores exec bits on bin/. Both are extractor-side, not
image-side; upstream follow-up noted in Follow-ups. Mount-mode smoke was not
attempted (no macFUSE on the host/runners; the driver side is libtfs
territory, not this feedstock).

**macOS build quirks found (all solved at build time, zero source patches):**
- OpenMP: cmake's FindOpenMP locates brew libomp, but upstream only folds
  `OpenMP_{C,CXX}_FLAGS` into the compile lines, never
  `OpenMP_{C,CXX}_INCLUDE_DIR` — invisible on linux where gcc ships omp.h
  on the default path. tools/build injects `-I<libomp>/include` +
  `-L<libomp>/lib` via `CMAKE_{C,CXX}_FLAGS`/linker flags. WITH_OPENMP
  parity with the linux leg.
- FindIntl is unconditional upstream even with WITH_NLS=OFF → keg-only
  `gettext` + `libomp` are passed through `CMAKE_PREFIX_PATH`.
- inkscape's profile bootstrap writes `.config/.cache` into the payload
  root on first run — cleaned after the pre-image smoke (runtime writes are
  the shim's/HOME's business, not the image's).
- brew bottles are read-only (0444): copies get `u+w` before
  strip/install_name_tool/codesign; closure copies are normalized to 0755.
- boot_smoke's PNG magic check compared an ASCII-8BIT read against a UTF-8
  "\x89PNG" literal — always false on any platform (latent pre-existing
  bug; the linux leg never got far enough to notice). Fixed with `.b`.

## Known limitations (phase A, honest list)

- **Fonts**: text export resolves fonts through the host's fontconfig; the
  payload ships the stock `/etc/fonts` but no font files. Metanorma SVGs
  relying on specific fonts need them mounted/provided at run time.
- **gdk-pixbuf loaders**: copied into the image, but their `loaders.cache`
  holds absolute paths; SVGs with embedded raster images need the shim to
  set `GDK_PIXBUF_MODULE_FILE`/`GDK_PIXBUF_MODULEDIR` at run time. Plain
  SVG→PNG/PDF export does not touch the loaders (cairo writes PNG/PDF
  natively) — verified in boot-smoke.
- **PDF/PS/EPS import disabled** (poppler/ghostscript out of scope).
- glibc family stays outside the closure: the payload needs a host glibc ≥
  ubuntu-24.04's (2.39) — standard for the dynamic tier.
- macOS leg: the libSystem family (incl. libc++/libc++abi) stays outside the
  closure the same way; the payload floor is macOS 14/arm64 (brew
  `arm64_sonoma` bottles + host SDK target). No mount-mode smoke: mounting
  needs macFUSE (system extension, unavailable on GHA and not assumed on
  user hosts) — `tebakofs extract` is the documented degraded path.
- `tools/publish` and the release job are wired but untagged/unexercised
  until the first real tag.

## Follow-ups

- aarch64-linux-gnu + x86_64-macos legs (the arm64-linux overlay triplet is
  in `tools/triplets/`; `emit_matrix` already maps runners). x86_64-macos
  should be a mechanical port of the aarch64-macos work: brew at /usr/local,
  x64-osx-static triplet (mapped in `PLATFORM_MAP`, file not written yet),
  libtfs `*-macos-x86_64` assets to pin.
- Phase B: vcpkg overlay ports for the gtkmm3 ABI family → full-vcpkg dep
  set; possibly upstream dwarfs-t release assets for stage.
- actions/cache for the vcpkg installed tree + tool cache in CI.
- macOS mount-mode smoke: needs macFUSE on the runner (system-extension
  approval — not available on GHA). Extract mode via `tebakofs` is the
  documented degraded path; revisit if tebako's own runtime gains a fuse-free
  reader.
- libtfs extractor gaps (worked around in tools/build + tools/boot_smoke;
  drop the workarounds once fixed upstream): tebakofs v0.13.0's dwarfs
  backend cannot read symlink inodes (payload ships symlink-free) and
  extract applies no file modes (boot_smoke restores exec bits on bin/).
