# tebako-packages/inkscape

Feedstock for the **inkscape** tebako toolkit payload — metanorma's
graphics chain (SVG → PDF/PNG) as a dynamic, relocatable dwarfs image.

Part of the [tebako-packages](https://github.com/tebako-packages) org;
conventions and the feedstock template live in
[tebako-packages/index](https://github.com/tebako-packages/index)
(`docs/conventions.md`). Phase A per spec 13 §9.

- `recipe.yml` — upstream tarball (sha256-pinned), cmake build,
  `link_mode: dynamic`, `rpath_origin: true`, vcpkg + apt dep provenance,
  platforms.
- `tools/` — `emit_matrix`, `build`, `stage`, `boot_smoke`, `publish`
  (ruby; thin YAML, logic here).
- `manifests/payload.yaml` — payload manifest template (spec 03), filled
  by `tools/stage`.
- `fixtures/smoke.svg` — boot-smoke export fixture.
- `docs/build-notes.md` — version choice, dep provenance, RPATH design,
  closure layout, proof results, limitations.

## Usage (maintainers)

```console
$ tools/build recipe.yml 1.4.3 x86_64-linux-gnu   # fetch+verify, vcpkg, cmake, closure
$ tools/stage out/x86_64-linux-gnu x86_64-linux-gnu   # dwarfs image + manifest
$ tools/boot_smoke out/x86_64-linux-gnu           # --version + SVG→PNG/PDF from the image
$ git tag 1.4.3 && git push --tags                # CI builds legs, publishes the release
```

Releases carry per-triplet `*.dwarfs` payloads + `payload-*.yaml`
manifests + `SHA256SUMS` + `tpkg-registry.yaml`.
