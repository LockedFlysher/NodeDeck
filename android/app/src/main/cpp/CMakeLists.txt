cmake_minimum_required(VERSION 3.22.1)
project(nodedeck_moonlight C)

set(MOONLIGHT_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../Sources/CMoonlightCommon")

set(MOONLIGHT_SOURCES
    "${MOONLIGHT_ROOT}/src/AudioStream.c"
    "${MOONLIGHT_ROOT}/src/ByteBuffer.c"
    "${MOONLIGHT_ROOT}/src/Connection.c"
    "${MOONLIGHT_ROOT}/src/ConnectionTester.c"
    "${MOONLIGHT_ROOT}/src/ControlStream.c"
    "${MOONLIGHT_ROOT}/src/FakeCallbacks.c"
    "${MOONLIGHT_ROOT}/src/InputStream.c"
    "${MOONLIGHT_ROOT}/src/LinkedBlockingQueue.c"
    "${MOONLIGHT_ROOT}/src/Misc.c"
    "${MOONLIGHT_ROOT}/src/Platform.c"
    "${MOONLIGHT_ROOT}/src/PlatformSockets.c"
    "${MOONLIGHT_ROOT}/src/RecorderCallbacks.c"
    "${MOONLIGHT_ROOT}/src/RtpAudioQueue.c"
    "${MOONLIGHT_ROOT}/src/RtpVideoQueue.c"
    "${MOONLIGHT_ROOT}/src/RtspConnection.c"
    "${MOONLIGHT_ROOT}/src/RtspParser.c"
    "${MOONLIGHT_ROOT}/src/SdpGenerator.c"
    "${MOONLIGHT_ROOT}/src/SimpleStun.c"
    "${MOONLIGHT_ROOT}/src/VideoDepacketizer.c"
    "${MOONLIGHT_ROOT}/src/VideoFormats.c"
    "${MOONLIGHT_ROOT}/src/VideoStream.c"
    "${MOONLIGHT_ROOT}/enet/callbacks.c"
    "${MOONLIGHT_ROOT}/enet/compress.c"
    "${MOONLIGHT_ROOT}/enet/host.c"
    "${MOONLIGHT_ROOT}/enet/list.c"
    "${MOONLIGHT_ROOT}/enet/packet.c"
    "${MOONLIGHT_ROOT}/enet/peer.c"
    "${MOONLIGHT_ROOT}/enet/protocol.c"
    "${MOONLIGHT_ROOT}/enet/unix.c"
    "${MOONLIGHT_ROOT}/nanors/rs.c"
    "${MOONLIGHT_ROOT}/nanors/deps/obl/oblas_common.c"
    "${MOONLIGHT_ROOT}/nanors/deps/obl/oblas_lite.c"
    "${CMAKE_CURRENT_SOURCE_DIR}/AndroidPlatformCrypto.c"
    "${CMAKE_CURRENT_SOURCE_DIR}/MoonlightJniBridge.c"
)

add_library(nodedeck_moonlight SHARED ${MOONLIGHT_SOURCES})

target_include_directories(nodedeck_moonlight PRIVATE
    "${MOONLIGHT_ROOT}/include"
    "${MOONLIGHT_ROOT}/src"
    "${MOONLIGHT_ROOT}/enet/include"
    "${MOONLIGHT_ROOT}/nanors"
    "${MOONLIGHT_ROOT}/nanors/deps"
    "${MOONLIGHT_ROOT}/nanors/deps/obl"
)

target_compile_options(nodedeck_moonlight PRIVATE
    -Wno-deprecated-declarations
    -Wno-unused-parameter
    -Wno-sign-compare
    -Wno-pointer-sign
    -Wno-incompatible-pointer-types-discards-qualifiers
)

find_library(log-lib log)
target_link_libraries(nodedeck_moonlight ${log-lib})
