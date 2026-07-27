# Overlay triplet: static vcpkg libs for the macOS dynamic-payload tier.
#
# The 29 non-GNOME deps link STATICALLY into the inkscape binaries and so
# drop out of the dylib closure entirely — the closure is then 100%
# Homebrew-supplied (the GNOME platform stack), which removes every
# brew/vcpkg SONAME collision by construction.
#
# VCPKG_CRT_LINKAGE is a no-op on Darwin: there is no static CRT on macOS,
# libSystem is always dynamic. (Contrast dwarfs-t-rs's *-windows-static
# triplets where the static story really has a CRT dimension — /MT. The
# payload tier here stays dynamic regardless: the GNOME stack is dylibs.)
set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_CMAKE_SYSTEM_NAME Darwin)
