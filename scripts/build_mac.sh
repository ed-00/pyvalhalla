#!/usr/bin/env bash

# Ensure we're in a virtual environment
if [[ -z "${VIRTUAL_ENV}" ]]; then
    echo "Please activate a virtual environment first"
    exit 1
fi

# Clean any previous builds
rm -rf conan_build upstream/build
rm -rf include/darwin/* lib/darwin

# Install build dependencies
pip install -r build-requirements.txt
pip install "conan<2.0.0"
pip install delocate

# Install system dependencies via brew
brew install protobuf curl geos luajit libspatialite sqlite

# Configure conan
conan profile new default --detect --force
conan config set "storage.path=${PWD}/upstream/conan_data"
conan install --install-folder conan_build .

# Create patches directory if it doesn't exist
mkdir -p upstream_patches

# apply any patches
pushd upstream
git apply ../upstream_patches/*
popd

# TODO: the env var can be omitted once geos 3.11 is released: https://github.com/libgeos/geos/issues/500
cmake -B upstream/build -S upstream/ \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=10.15 \
  -DENABLE_CCACHE=OFF \
  -DBUILD_SHARED_LIBS=OFF \
  -DENABLE_BENCHMARKS=OFF \
  -DENABLE_PYTHON_BINDINGS=ON \
  -DENABLE_TESTS=OFF \
  -DENABLE_TOOLS=OFF \
  -DENABLE_DATA_TOOLS=OFF \
  -DENABLE_SERVICES=OFF \
  -DENABLE_HTTP=OFF \
  -DENABLE_CCACHE=OFF \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CXX_FLAGS="-Wno-error=deprecated-builtins -Wno-error=unused-but-set-variable -D_LIBCPP_ENABLE_CXX17_REMOVED_UNARY_BINARY_FUNCTION" || exit 1
cmake --build upstream/build -- -j$(sysctl -n hw.logicalcpu) || exit 1

rm -r include/darwin/*
rm -r lib/darwin

echo "copying all headers except protobuf"
deps="curl geos luajit libspatialite sqlite"
for dep in $deps; do
  for path in $(brew list ${dep} -v); do
    # find and copy the headers
    if [[ ${path} == *"/include/"* ]]; then
      rel_dest=include/darwin/${path##*/include/}
      mkdir -p $(dirname ${rel_dest})
      cp $path $(dirname ${rel_dest})
      chmod 644 ${rel_dest}
    fi
  done
done

# Copy protobuf headers from the correct location (handles both Intel and ARM Macs)
if [ -d "/opt/homebrew/include/google" ]; then
    cp -rf /opt/homebrew/include/google include/darwin/
elif [ -d "/usr/local/include/google" ]; then
    cp -rf /usr/local/include/google include/darwin/
else
    echo "Error: Could not find protobuf headers"
    exit 1
fi

# copy libvalhalla
mkdir -p lib/darwin
cp -f upstream/build/src/libvalhalla.a lib/darwin

# copy dependencies
if [ -f "/opt/homebrew/lib/libprotobuf-lite.dylib" ]; then
    cp -RL /opt/homebrew/lib/libprotobuf-lite.dylib lib/darwin/libprotobuf-lite.32.dylib
elif [ -f "/usr/local/lib/libprotobuf-lite.dylib" ]; then
    cp -RL /usr/local/lib/libprotobuf-lite.dylib lib/darwin/libprotobuf-lite.32.dylib
else
    echo "Error: Could not find libprotobuf-lite.dylib"
    exit 1
fi

pushd lib/darwin
ln -s libprotobuf-lite.32.dylib libprotobuf-lite.dylib
popd

mkdir -p include/darwin/valhalla/proto
protoc --proto_path=upstream/proto --cpp_out=include/darwin/valhalla/proto upstream/proto/*.proto

# remove build folder or we'll get weird caching stuff
if [[ -d build ]]; then
  rm -r build
fi
python3 setup.py bdist_wheel

# now checkout the unpatched valhalla version again
git -C upstream checkout .

# patch the paths delocate sees
LIBRARY_PATH="$(pwd)/lib/darwin/:$LIBRARY_PATH"

for dylib in dist/*; do
  DYLD_LIBRARY_PATH=$LIBRARY_PATH delocate-wheel -w wheelhouse "${dylib}"
done
