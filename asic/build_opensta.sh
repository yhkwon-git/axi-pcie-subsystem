#!/bin/bash
# Build a current OpenSTA into $HOME/.local. Ubuntu's opensta package is
# the 2019 snapshot and does not match this Sky130 liberty.
# CUDD 3.0.0 is the BDD package OpenSTA's CMake looks up via CUDD_DIR.
set -eu
prefix="${PREFIX:-$HOME/.local}"
src="${SRC:-$HOME/src}"
mkdir -p "$prefix/bin" "$src"
cd "$src"

if [ ! -d cudd/.git ]; then
  git clone --depth 1 --branch 3.0.0 https://github.com/cuddorg/cudd.git
fi
if [ ! -e "$prefix/lib/libcudd.a" ] && [ ! -e "$prefix/lib/libcudd.so" ]; then
  cd "$src/cudd"
  # The 3.0.0 tarball still calls aclocal-1.14. Regenerating avoids that.
  autoreconf -fi
  ./configure --prefix="$prefix"
  make -j"$(nproc)"
  make install
fi

if [ ! -d OpenSTA/.git ]; then
  git clone --depth 1 https://github.com/parallaxsw/OpenSTA.git "$src/OpenSTA"
fi
cd "$src/OpenSTA"
git rev-parse HEAD
mkdir -p build
cd build
cmake -DCUDD_DIR="$prefix" -DUSE_TCL_READLINE=OFF \
  -DCMAKE_BUILD_TYPE=RELEASE -DCMAKE_INSTALL_PREFIX="$prefix" ..
make -j"$(nproc)"
cp -f sta "$prefix/bin/sta"
"$prefix/bin/sta" -version || true
