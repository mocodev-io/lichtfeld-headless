# LichtFeld Studio - headless trainingsimage, gebouwd uit de officiele broncode.
# Bron: https://github.com/MrNeRF/LichtFeld-Studio
# Versie wordt bij het bouwen meegegeven via LFS_REF (release-tag).

ARG CUDA_VERSION=12.8.0

########################################
# Stage 1: builder - compileert LichtFeld
########################################
FROM nvidia/cuda:${CUDA_VERSION}-devel-ubuntu24.04 AS builder

ARG LFS_REF
ENV DEBIAN_FRONTEND=noninteractive

# Compiler, buildtools en de -dev libs die LichtFeld en zijn vcpkg-onderdelen
# nodig hebben. cuDNN is nodig voor ONNX Runtime en zit niet in het CUDA-image.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates gnupg wget curl git zip unzip tar pkg-config \
        build-essential gcc-14 g++-14 gfortran-14 \
        ninja-build python3 python3-pip python3-venv \
        nasm autoconf autoconf-archive automake libtool libltdl-dev \
        bison flex \
        libcudnn9-cuda-12 \
        libglu1-mesa-dev libgtk-3-dev xorg-dev libgl1-mesa-dev libegl1-mesa-dev \
        libx11-dev libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev \
        libxtst-dev libxkbcommon-dev \
    && update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-14 100 \
    && update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-14 100 \
    && update-alternatives --install /usr/bin/gfortran gfortran /usr/bin/gfortran-14 100 \
    && rm -rf /var/lib/apt/lists/*

# Recente CMake (Ubuntu's eigen versie is te oud voor LichtFeld)
RUN wget -qO- https://apt.kitware.com/keys/kitware-archive-latest.asc \
        | gpg --dearmor -o /usr/share/keyrings/kitware-archive-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/kitware-archive-keyring.gpg] https://apt.kitware.com/ubuntu/ noble main" \
        > /etc/apt/sources.list.d/kitware.list \
    && apt-get update && apt-get install -y --no-install-recommends cmake \
    && rm -rf /var/lib/apt/lists/*

# vcpkg voor LichtFeld's afhankelijkheden
ENV VCPKG_ROOT=/opt/vcpkg
RUN git clone https://github.com/microsoft/vcpkg.git ${VCPKG_ROOT} \
    && ${VCPKG_ROOT}/bootstrap-vcpkg.sh -disableMetrics
ENV PATH="${VCPKG_ROOT}:${PATH}"

# Officiele broncode op de opgegeven release-tag
WORKDIR /opt/src
RUN test -n "${LFS_REF}" || (echo "LFS_REF is niet opgegeven" >&2 && exit 1) \
    && git clone --recursive --branch "${LFS_REF}" https://github.com/MrNeRF/LichtFeld-Studio.git . \
    && git submodule update --init --recursive

# Fix 1: -march=native optimaliseert voor de CPU van de buildserver en crasht op
# oudere CPU's. x86-64-v3 (AVX2/FMA/BMI2) draait op elke CPU vanaf Haswell (i5-4670).
RUN if [ -f src/core/CMakeLists.txt ]; then \
        sed -i 's/-march=native/-march=x86-64-v3/' src/core/CMakeLists.txt; \
    fi

# Configureren (hier installeert vcpkg alle onderdelen).
# Fix 2: BUILD_PYTHON_STUBS=OFF - die stap heeft een echte GPU nodig, GitHub niet.
# PTX-only + portable: CUDA-code wordt bij de eerste start voor jouw GPU gecompileerd.
# Bij een fout worden het vcpkg-log en de foutlogs van het mislukte onderdeel getoond.
RUN cmake -B build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_TOOLCHAIN_FILE=${VCPKG_ROOT}/scripts/buildsystems/vcpkg.cmake \
        -DBUILD_CUDA_PTX_ONLY=ON \
        -DBUILD_PORTABLE=ON \
        -DBUILD_CUDA_MIN_SM=75 \
        -DCUDA_DEVICE_DEBUG=OFF \
        -DBUILD_TESTS=OFF \
        -DBUILD_PYTHON_STUBS=OFF \
    || ( echo "===== vcpkg-manifest-install.log (laatste 80 regels) =====" \
         && tail -n 80 build/vcpkg-manifest-install.log 2>/dev/null; \
         for f in $(find ${VCPKG_ROOT}/buildtrees -name '*-err.log' -size +0 2>/dev/null); do \
             echo "===== $f ====="; tail -n 60 "$f"; \
         done; \
         exit 1 )

# Compileren en installeren
RUN cmake --build build -- -j$(nproc) \
    && cmake --install build --prefix /opt/lichtfeld \
    && rm -rf build ${VCPKG_ROOT}/buildtrees ${VCPKG_ROOT}/downloads

# Verzamel de gedeelde libraries die het programma nodig heeft (behalve de
# CUDA-driver, die levert de NVIDIA-runtime van de host)
RUN BIN="$(find /opt/lichtfeld/bin -maxdepth 1 -type f -executable | head -n1)" \
    && test -n "$BIN" \
    && ln -s "$BIN" /opt/lichtfeld/lichtfeld-bin \
    && mkdir -p /opt/lichtfeld/vendor-libs \
    && ldd "$BIN" | awk '{print $3}' | grep '^/' | sort -u \
        | grep -vE '/(libc|libm|libpthread|libdl|librt|ld-linux[^/]*|libstdc\+\+|libgcc_s)\.so' \
        | xargs -I{} sh -c 'cp -L {} /opt/lichtfeld/vendor-libs/ 2>/dev/null || true'

########################################
# Stage 2: runtime - alleen LichtFeld
########################################
FROM nvidia/cuda:${CUDA_VERSION}-runtime-ubuntu24.04

ENV DEBIAN_FRONTEND=noninteractive

# Runtime libs. xvfb is een vangnet voor als --headless toch een OpenGL-context wil.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libglu1-mesa libgl1 libegl1 libgtk-3-0 \
        libx11-6 libxrandr2 libxinerama1 libxcursor1 libxi6 \
        libgomp1 libgfortran5 \
        libcudnn9-cuda-12 \
        python3 \
        xvfb xauth \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/lichtfeld /opt/lichtfeld
RUN ln -s /opt/lichtfeld/lichtfeld-bin /usr/local/bin/LichtFeld-Studio

ENV LD_LIBRARY_PATH="/opt/lichtfeld/lib:/opt/lichtfeld/vendor-libs:${LD_LIBRARY_PATH}"

# Cache voor de eenmalige CUDA-compilatie bij de eerste start (wordt gemount)
ENV CUDA_CACHE_PATH=/cache/nv \
    CUDA_CACHE_MAXSIZE=4294967296

WORKDIR /workspace
CMD ["sleep", "infinity"]
