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

| dependency | required by | served from |
|---|---|---|
| gtkmm-3.0 ≥ 3.24, gtk+-3.0, gdkmm, glibmm-2.4 ≥ 2.58, sigc++-2.0 | `pkg_check_modules(GTK3 …)` | **apt** (ubuntu-24.04 `libgtkmm-3.0-dev`) |
| pangocairo ≥ 1.44, pangoft2, harfbuzz, fontconfig, gmodule-2.0, epoxy | `INKSCAPE_DEP`/`EPOXY` | **apt** (pulled by libgtkmm-3.0-dev; epoxy must match gtk3) |
| gsl, bdw-gc, lcms2, double-conversion, libpng, zlib, libxml2, libxslt | `INKSCAPE_DEP` + `find_package` | **vcpkg** @ `cd61e1e2` (annotated tag `2026.06.24`) |
| Boost filesystem (+ stacktrace_basic) | `find_package(Boost …)` | **vcpkg** (`boost-filesystem`, `boost-stacktrace`) |
| potrace | `find_package(Potrace REQUIRED)` | **apt** (`libpotrace-dev`) — `potrace` is absent from vcpkg |
| 2geom | vendored | tarball (`WITH_INTERNAL_2GEOM=ON`) |
| Iconv / Intl | glibc | system (stays outside the closure) |

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

**Boot-smoke:** mount + `env -i inkscape --version` + SVG→PNG/PDF export +
ldd sweep: see run logs; local extract-mode evidence below.
<!-- SMOKE-RESULTS -->

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
- `tools/publish` and the release job are wired but untagged/unexercised
  until the first real tag.

## Follow-ups

- aarch64-linux-gnu + macOS legs (overlay triplets for both are in
  `tools/triplets/`; `emit_matrix` already maps runners).
- Phase B: vcpkg overlay ports for the gtkmm3 ABI family → full-vcpkg dep
  set; possibly upstream dwarfs-t release assets for stage.
- actions/cache for the vcpkg installed tree + tool cache in CI.
