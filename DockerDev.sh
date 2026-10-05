#!/bin/bash
# Incremental development build of Bambu Studio inside Docker.
#
# Uses the dependency image produced by `./DockerBuild.sh -d` (studio_dep_22:1.0),
# bind-mounts this source tree and keeps the build directory (build_docker/) on
# the host, so only changed files are recompiled between runs.
#
# Usage: ./DockerDev.sh build    configure (first time) and compile
#        ./DockerDev.sh run      start the GUI (X11/Wayland of the host, e.g. WSLg)
#                                DEBUG=1 prints a stack trace on crash or non-zero exit
#        ./DockerDev.sh shell    interactive shell in the build environment

set -e

PROJECT_ROOT=$(cd -P -- "$(dirname -- "$0")" && pwd -P)
IMAGE=${IMAGE:-studio_dep_22:1.0}
BUILD_DIR=build_docker
BUILD_TYPE=${BUILD_TYPE:-Release}
JOBS=${JOBS:-$(( $(nproc) * 3 / 4 ))}
# Persistent home for the containerized app (login, presets, network plugin).
HOME_VOLUME=${HOME_VOLUME:-bambustudio_dev_home}
# DeviceWeb downloads Node.js/pnpm into ${CMAKE_SOURCE_DIR}/../node-cache, i.e. /node-cache.
NODE_VOLUME=${NODE_VOLUME:-bambustudio_node_cache}

common_args=(
    --rm
    --user "$(id -u):$(id -g)"
    -v "${PROJECT_ROOT}:/BambuStudio"
    -v "${HOME_VOLUME}:/home/dev"
    -v "${NODE_VOLUME}:/node-cache"
    -e HOME=/home/dev
    -w /BambuStudio
)

prepare_home() {
    # Named volumes are created root-owned; hand them over to the calling user.
    docker run --rm -v "${HOME_VOLUME}:/home/dev" -v "${NODE_VOLUME}:/node-cache" "${IMAGE}" \
        chown "$(id -u):$(id -g)" /home/dev /node-cache
}

cmd_build() {
    prepare_home
    # The deps image was built at /BambuStudio/deps/build/destdir and moved to /destdir;
    # wx-config, pkg-config and CMake files still reference the original path.
    mkdir -p "${PROJECT_ROOT}/deps/build"
    [ -e "${PROJECT_ROOT}/deps/build/destdir" ] || ln -sfn /destdir "${PROJECT_ROOT}/deps/build/destdir"
    docker run "${common_args[@]}" "${IMAGE}" bash -c "
        set -e
        if [ ! -f ${BUILD_DIR}/build.ninja ]; then
            cmake -S . -B ${BUILD_DIR} -G Ninja \
                -DCMAKE_PREFIX_PATH=/BambuStudio/deps/build/destdir/usr/local \
                -DSLIC3R_STATIC=1 \
                -DSLIC3R_GTK=3 \
                -DCMAKE_BUILD_TYPE=${BUILD_TYPE} \
                -DBBL_RELEASE_TO_PUBLIC=1 \
                -DBBL_INTERNAL_TESTING=0
        fi
        cmake --build ${BUILD_DIR} --target BambuStudio -- -j${JOBS}
    "
}

cmd_run() {
    prepare_home
    local preload=""
    if [ "${DEBUG}" = 1 ]; then
        # Stack trace on non-zero exit or fatal signal (gdb is unusable: the network plugin
        # traps when a debugger is attached).
        docker run "${common_args[@]}" "${IMAGE}" \
            gcc -shared -fPIC -O1 -o ${BUILD_DIR}/exit_trace.so docker/exit_trace.c -ldl
        preload="-e LD_PRELOAD=/BambuStudio/${BUILD_DIR}/exit_trace.so"
    fi
    local display_args=(-e DISPLAY -e WAYLAND_DISPLAY -e XDG_RUNTIME_DIR -e PULSE_SERVER
                        -v /tmp/.X11-unix:/tmp/.X11-unix)
    # WSLg keeps its sockets under /mnt/wslg.
    [ -d /mnt/wslg ] && display_args+=(-v /mnt/wslg:/mnt/wslg -e XDG_RUNTIME_DIR=/mnt/wslg/runtime-dir)
    docker run "${common_args[@]}" \
        --net=host --ipc=host \
        "${display_args[@]}" ${preload} \
        -e LC_ALL=C \
        -e SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
        -e LD_LIBRARY_PATH=/BambuStudio/${BUILD_DIR}/src \
        "${IMAGE}" \
        bash -c "mkdir -p \$HOME/.config && exec ${BUILD_DIR}/src/bambu-studio $*"
}

cmd_shell() {
    docker run "${common_args[@]}" -ti "${IMAGE}" bash
}

case "$1" in
    build) cmd_build ;;
    run)   shift; cmd_run "$@" ;;
    shell) cmd_shell ;;
    *)     sed -n '2,12p' "$0"; exit 1 ;;
esac
