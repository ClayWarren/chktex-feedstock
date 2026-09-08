#!/usr/bin/env bash
set -eux -o pipefail


# https://github.com/conda-forge/chktex-feedstock/pull/8
## maybe double-packed?
ls configure || cd "${PKG_NAME}-${PKG_VERSION}"

cp COPYING "${SRC_DIR}/COPYING" || echo "COPYING already correct"

if [[ "${target_platform}" == win-* ]]; then
    ln -s "${PREFIX}/Library/usr/bin/perl.exe" "${PREFIX}/Library/usr/bin/perl5.exe"
    # configure.ac hard-errors when it cannot link tgetent, but nothing ever
    # uses it: the termcap code in OpSys.c is gated on HAVE_LIBTERMCAP /
    # HAVE_LIBTERMLIB, and AC_SEARCH_LIBS defines neither (config.h.in has no
    # HAVE_LIB* entries at all), so USE_TERMCAP is never enabled on any
    # platform. conda-forge has no mingw-w64 termcap or ncurses to link
    # against, so short-circuit the probe via its autoconf cache variable.
    export ac_cv_search_tgetent="none required"
    # configure.ac:107 appends to whatever SCRIPTS already holds
    # (SCRIPTS="$SCRIPTS chkweb"), and the Windows build environment exports
    # SCRIPTS=%PREFIX%\Scripts. That leaks a Windows path into the Makefile,
    # so `make install` tries to install a file named after the path, the
    # backslashes get eaten by sh, and chkweb is never installed.
    unset SCRIPTS
else
    ln -s "${PREFIX}/bin/perl" "${PREFIX}/bin/perl5"
    export CFLAGS="${CFLAGS} -I${PREFIX}/include -I${PREFIX}/include/ncurses -I${PREFIX}/include/ncursesw"
    export LDFLAGS="${LDFLAGS} -L${PREFIX}/lib -L${PREFIX}/lib/ncurses -L${PREFIX}/lib/ncursesw"
    export LIBS="-lncurses"
fi

configure_platform=()
if [[ "${target_platform}" == "win-arm64" ]]; then
    # Clang targets the native MSVC ABI; the MSYS build tools run under emulation.
    export CC=clang.exe
    export CFLAGS="${CFLAGS:-} -I${LIBRARY_PREFIX_M}/include -O2 -D_CRT_SECURE_NO_WARNINGS -D_MT -D_DLL -nostdlib -Xclang --dependent-lib=msvcrt -fuse-ld=lld"
    export LDFLAGS="${LDFLAGS:-} -L${LIBRARY_PREFIX_M}/lib -nostdlib -Xclang --dependent-lib=msvcrt -fuse-ld=lld"
    # Autoconf probes stdio symbols without including the modern inline headers.
    export LIBS="-lgetopt -llegacy_stdio_definitions -loldnames"
    configure_platform=(--build=aarch64-w64-mingw32 --host=aarch64-w64-mingw32)
fi

sed -E --in-place "s/install: chktex ChkTeX.dvi/install: chktex/" Makefile.in

# TODO: probably want pcre, but keep segfaulting with 8.44
./configure "${configure_platform[@]}" \
    --disable-pcre \
    "--includedir=${PREFIX}/include" \
    "--libdir=${PREFIX}/lib" \
    "--prefix=${PREFIX}" \
    || ( \
       cat config.log \
       && exit 1 \
    )

make all

make install

if [[ "${target_platform}" == "win-arm64" ]]; then
    # This makefile hardcodes chktex without EXEEXT; Clang honors that spelling.
    mv "${PREFIX}/bin/chktex" "${PREFIX}/bin/chktex.exe"
fi

sed --in-place "s/perl5/perl/" "${PREFIX}/bin/deweb"

if [[ "${target_platform}" == win-* ]]; then
    rm "${PREFIX}/Library/usr/bin/perl5.exe"
    # deweb and chkweb are extensionless perl scripts. cmd.exe cannot execute
    # those directly -- it reports "is not recognized as an internal or
    # external command" and exits 9009 -- so ship .bat shims beside them.
    for script in deweb chkweb; do
        cat > "${PREFIX}/bin/${script}.bat" <<BATCH
@echo off
perl "%~dp0${script}" %*
BATCH
    done
else
    rm "${PREFIX}/bin/perl5"
fi

make test
