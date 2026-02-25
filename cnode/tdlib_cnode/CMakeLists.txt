cmake_minimum_required(VERSION 3.21)

project(froth_tdlib_cnode LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Threads REQUIRED)

get_filename_component(FROTH_PROJECT_ROOT "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)

# Build TDLib (JSON interface) from the git submodule.
set(TDLIB_DIR "${FROTH_PROJECT_ROOT}/vendor/tdlib")
if(NOT EXISTS "${TDLIB_DIR}/CMakeLists.txt")
  message(FATAL_ERROR "TDLib submodule not found at ${TDLIB_DIR}. Did you run `git submodule update --init --recursive`?")
endif()

set(TGCALLS_DIR "${FROTH_PROJECT_ROOT}/vendor/tgcalls")
if(NOT EXISTS "${TGCALLS_DIR}/tgcalls/Instance.cpp")
  message(FATAL_ERROR "tgcalls submodule not found at ${TGCALLS_DIR}. Did you run `git submodule update --init --recursive`?")
endif()

option(FROTH_TDLIB_CNODE_USE_CHROMIUM_TOOLCHAIN
  "Build froth_tdlib_cnode with Chromium clang/sysroot/WebRTC archives"
  OFF
)
set(FROTH_WEBRTC_OUT "" CACHE PATH "Path to WebRTC out dir (e.g. vendor/webrtc/out/froth_headless)")
set(FROTH_SYSROOT "" CACHE PATH "Path to Chromium sysroot")
set(FROTH_OVERLAY_DIR "" CACHE PATH "Path to include overlay containing base/build/third_party symlinks")
set(FROTH_TDJSON_LIBRARY "" CACHE FILEPATH "Path to prebuilt libtdjson shared library (required in Chromium mode)")
set(FROTH_TDJSON_INCLUDE_DIR "" CACHE PATH "Path to TDLib build include root containing td/telegram/tdjson_export.h (required in Chromium mode)")

option(FROTH_TGCALLS_BUILD_REGISTER_PLUGIN
  "Build a plugin exporting froth_tgcalls_register()"
  OFF
)
set(FROTH_TGCALLS_PLUGIN_EXTRA_LIBS "" CACHE STRING
  "Semicolon-separated libraries that provide tgcalls implementation symbols"
)

# TDLib's CMake uses the legacy `ZLIB_LIBRARY` + `ZLIB_INCLUDE_DIR` variables.
# On some systems/CMake versions, FindZLIB can fail to populate these even when
# zlib is installed. Provide a best-effort fallback before adding the subproject.
if(NOT ZLIB_INCLUDE_DIR OR ZLIB_INCLUDE_DIR MATCHES "NOTFOUND")
  find_path(_ZLIB_INCLUDE_DIR zlib.h PATHS
    /usr/include
    /usr/local/include
  )
  if(_ZLIB_INCLUDE_DIR)
    set(ZLIB_INCLUDE_DIR "${_ZLIB_INCLUDE_DIR}" CACHE PATH "" FORCE)
  endif()
endif()

if(NOT ZLIB_LIBRARY OR ZLIB_LIBRARY MATCHES "NOTFOUND")
  find_library(_ZLIB_LIBRARY NAMES z PATHS
    /usr/lib
    /usr/lib64
    /usr/lib/x86_64-linux-gnu
    /usr/local/lib
    /usr/local/lib64
  )
  if(_ZLIB_LIBRARY)
    set(ZLIB_LIBRARY "${_ZLIB_LIBRARY}" CACHE FILEPATH "" FORCE)
  endif()
endif()

# Same deal for gperf.
if(NOT DEFINED GPERF_EXECUTABLE)
  find_program(GPERF_EXECUTABLE NAMES gperf)
  if(GPERF_EXECUTABLE)
    set(GPERF_EXECUTABLE "${GPERF_EXECUTABLE}" CACHE FILEPATH "" FORCE)
  endif()
endif()

# Keep TDLib build a bit leaner.
set(TD_ENABLE_LTO OFF CACHE BOOL "" FORCE)
set(TD_ENABLE_JNI OFF CACHE BOOL "" FORCE)
set(TD_ENABLE_DOTNET OFF CACHE BOOL "" FORCE)

if(FROTH_TGCALLS_BUILD_REGISTER_PLUGIN)
  if(FROTH_TGCALLS_PLUGIN_EXTRA_LIBS STREQUAL "")
    message(FATAL_ERROR "FROTH_TGCALLS_BUILD_REGISTER_PLUGIN requires FROTH_TGCALLS_PLUGIN_EXTRA_LIBS")
  endif()

  add_library(froth_tgcalls_register_plugin SHARED
    src/tgcalls_register_plugin.cpp
  )

  target_include_directories(froth_tgcalls_register_plugin PRIVATE
    "${TGCALLS_DIR}"
  )

  target_link_libraries(froth_tgcalls_register_plugin PRIVATE
    ${FROTH_TGCALLS_PLUGIN_EXTRA_LIBS}
  )
endif()

# Locate Erlang/OTP "ei" headers + lib.
execute_process(
  COMMAND erl -noshell -eval "io:format(\"~s\", [code:root_dir()]), halt()."
  OUTPUT_VARIABLE ERL_ROOT
  OUTPUT_STRIP_TRAILING_WHITESPACE
)
if(NOT ERL_ROOT)
  message(FATAL_ERROR "Failed to locate Erlang root dir via `erl`")
endif()

set(EI_INCLUDE_DIR "${ERL_ROOT}/usr/include")
find_library(
  EI_LIB
  NAMES ei
  PATHS "${ERL_ROOT}/usr/lib" "${ERL_ROOT}/usr/lib64"
  NO_DEFAULT_PATH
)
if(NOT EI_LIB)
  message(FATAL_ERROR "Failed to find libei under ${ERL_ROOT}/usr/lib")
endif()

set(FROTH_TGCALLS_FULL_SOURCES
  src/tgcalls_compat_shim.cpp
  src/tgcalls_register_plugin.cpp
  "${TGCALLS_DIR}/tgcalls/Instance.cpp"
  "${TGCALLS_DIR}/tgcalls/InstanceImpl.cpp"
  "${TGCALLS_DIR}/tgcalls/Manager.cpp"
  "${TGCALLS_DIR}/tgcalls/MediaManager.cpp"
  "${TGCALLS_DIR}/tgcalls/Message.cpp"
  "${TGCALLS_DIR}/tgcalls/EncryptedConnection.cpp"
  "${TGCALLS_DIR}/tgcalls/NetworkManager.cpp"
  "${TGCALLS_DIR}/tgcalls/ThreadLocalObject.cpp"
  "${TGCALLS_DIR}/tgcalls/StaticThreads.cpp"
  "${TGCALLS_DIR}/tgcalls/FieldTrialsConfig.cpp"
  "${TGCALLS_DIR}/tgcalls/ChannelManager.cpp"
  "${TGCALLS_DIR}/tgcalls/CodecSelectHelper.cpp"
  "${TGCALLS_DIR}/tgcalls/CryptoHelper.cpp"
  "${TGCALLS_DIR}/tgcalls/SctpDataChannelProviderInterfaceImpl.cpp"
  "${TGCALLS_DIR}/tgcalls/LogSinkImpl.cpp"
  "${TGCALLS_DIR}/tgcalls/TurnCustomizerImpl.cpp"
  "${TGCALLS_DIR}/tgcalls/AudioDeviceHelper.cpp"
  "${TGCALLS_DIR}/tgcalls/VideoCaptureInterface.cpp"
  "${TGCALLS_DIR}/tgcalls/VideoCaptureInterfaceImpl.cpp"
  "${TGCALLS_DIR}/tgcalls/FakeVideoTrackSource.cpp"
  "${TGCALLS_DIR}/tgcalls/FakeAudioDeviceModule.cpp"
  "${TGCALLS_DIR}/tgcalls/third-party/json11.cpp"
  "${TGCALLS_DIR}/tgcalls/utils/gzip.cpp"
  "${TGCALLS_DIR}/tgcalls/v2/InstanceV2Impl.cpp"
  "${TGCALLS_DIR}/tgcalls/v2/ContentNegotiation.cpp"
  "${TGCALLS_DIR}/tgcalls/v2/DirectNetworkingImpl.cpp"
  "${TGCALLS_DIR}/tgcalls/v2/ExternalSignalingConnection.cpp"
  "${TGCALLS_DIR}/tgcalls/v2/NativeNetworkingImpl.cpp"
  "${TGCALLS_DIR}/tgcalls/v2/RawTcpSocket.cpp"
  "${TGCALLS_DIR}/tgcalls/v2/ReflectorPort.cpp"
  "${TGCALLS_DIR}/tgcalls/v2/ReflectorRelayPortFactory.cpp"
  "${TGCALLS_DIR}/tgcalls/v2/Signaling.cpp"
  "${TGCALLS_DIR}/tgcalls/v2/SignalingConnection.cpp"
  "${TGCALLS_DIR}/tgcalls/v2/SignalingEncryption.cpp"
  "${TGCALLS_DIR}/tgcalls/v2/SignalingSctpConnection.cpp"
  "${TGCALLS_DIR}/tgcalls/v2_4_0_0/Signaling_4_0_0.cpp"
  "${TGCALLS_DIR}/tgcalls/platform/fake/FakeInterface.cpp"
  "${TGCALLS_DIR}/tgcalls/group/AVIOContextImpl.cpp"
  "${TGCALLS_DIR}/tgcalls/group/AudioStreamingPart.cpp"
  "${TGCALLS_DIR}/tgcalls/group/AudioStreamingPartInternal.cpp"
  "${TGCALLS_DIR}/tgcalls/group/AudioStreamingPartPersistentDecoder.cpp"
  "${TGCALLS_DIR}/tgcalls/group/GroupInstanceCustomImpl.cpp"
  "${TGCALLS_DIR}/tgcalls/group/GroupJoinPayloadInternal.cpp"
  "${TGCALLS_DIR}/tgcalls/group/GroupNetworkManager.cpp"
  "${TGCALLS_DIR}/tgcalls/group/StreamingMediaContext.cpp"
  "${TGCALLS_DIR}/tgcalls/group/VideoStreamingPart.cpp"
)

if(FROTH_TDLIB_CNODE_USE_CHROMIUM_TOOLCHAIN)
  if(FROTH_WEBRTC_OUT STREQUAL "")
    message(FATAL_ERROR "FROTH_WEBRTC_OUT is required when FROTH_TDLIB_CNODE_USE_CHROMIUM_TOOLCHAIN=ON")
  endif()
  if(FROTH_SYSROOT STREQUAL "")
    message(FATAL_ERROR "FROTH_SYSROOT is required when FROTH_TDLIB_CNODE_USE_CHROMIUM_TOOLCHAIN=ON")
  endif()
  if(FROTH_OVERLAY_DIR STREQUAL "")
    message(FATAL_ERROR "FROTH_OVERLAY_DIR is required when FROTH_TDLIB_CNODE_USE_CHROMIUM_TOOLCHAIN=ON")
  endif()
  if(FROTH_TDJSON_LIBRARY STREQUAL "")
    message(FATAL_ERROR "FROTH_TDJSON_LIBRARY is required when FROTH_TDLIB_CNODE_USE_CHROMIUM_TOOLCHAIN=ON")
  endif()
  if(FROTH_TDJSON_INCLUDE_DIR STREQUAL "")
    message(FATAL_ERROR "FROTH_TDJSON_INCLUDE_DIR is required when FROTH_TDLIB_CNODE_USE_CHROMIUM_TOOLCHAIN=ON")
  endif()
  if(NOT EXISTS "${FROTH_TDJSON_LIBRARY}")
    message(FATAL_ERROR "Missing FROTH_TDJSON_LIBRARY: ${FROTH_TDJSON_LIBRARY}")
  endif()
  if(NOT EXISTS "${FROTH_TDJSON_INCLUDE_DIR}/td/telegram/tdjson_export.h")
    message(FATAL_ERROR "Missing tdjson_export.h under FROTH_TDJSON_INCLUDE_DIR: ${FROTH_TDJSON_INCLUDE_DIR}")
  endif()
  if(NOT EXISTS "${FROTH_WEBRTC_OUT}/obj/libwebrtc.a")
    message(FATAL_ERROR "Missing ${FROTH_WEBRTC_OUT}/obj/libwebrtc.a")
  endif()
  if(NOT EXISTS "${FROTH_SYSROOT}")
    message(FATAL_ERROR "Missing sysroot: ${FROTH_SYSROOT}")
  endif()

  set(FROTH_WEBRTC_ROOT "${FROTH_PROJECT_ROOT}/vendor/webrtc")
  set(FROTH_ABSEIL_DIR "${FROTH_PROJECT_ROOT}/vendor/abseil-cpp")
  set(FROTH_LIBYUV_DIR "${FROTH_PROJECT_ROOT}/vendor/libyuv")
  set(FROTH_FFMPEG_DIR "${FROTH_PROJECT_ROOT}/vendor/ffmpeg")
  set(FROTH_RNNOISE_DIR "${FROTH_PROJECT_ROOT}/vendor/rnnoise")

  if(CMAKE_SYSTEM_PROCESSOR MATCHES "^(aarch64|arm64)$")
    set(FROTH_FFMPEG_ARCH "arm64")
  else()
    set(FROTH_FFMPEG_ARCH "x64")
  endif()
  set(FROTH_FFMPEG_CONFIG_DIR "${FROTH_FFMPEG_DIR}/chromium/config/Chrome/linux/${FROTH_FFMPEG_ARCH}")
  if(NOT EXISTS "${FROTH_FFMPEG_CONFIG_DIR}")
    set(FROTH_FFMPEG_CONFIG_DIR "${FROTH_FFMPEG_DIR}/chromium/config/Chrome/linux/x64")
  endif()

  file(GLOB_RECURSE FROTH_WEBRTC_STATIC_LIBS "${FROTH_WEBRTC_OUT}/obj/*.a")
  if(NOT FROTH_WEBRTC_STATIC_LIBS)
    message(FATAL_ERROR "No WebRTC static libs found under ${FROTH_WEBRTC_OUT}/obj")
  endif()
  list(SORT FROTH_WEBRTC_STATIC_LIBS)

  file(GLOB_RECURSE FROTH_LIBCXX_OBJECTS
    "${FROTH_WEBRTC_OUT}/obj/buildtools/third_party/libc++/libc++/*.o"
  )
  if(NOT FROTH_LIBCXX_OBJECTS)
    message(FATAL_ERROR "No libc++ objects found under ${FROTH_WEBRTC_OUT}/obj/buildtools/third_party/libc++/libc++")
  endif()
  list(SORT FROTH_LIBCXX_OBJECTS)

  file(GLOB_RECURSE FROTH_LIBCXXABI_OBJECTS
    "${FROTH_WEBRTC_OUT}/obj/buildtools/third_party/libc++abi/libc++abi/*.o"
  )
  if(NOT FROTH_LIBCXXABI_OBJECTS)
    message(FATAL_ERROR "No libc++abi objects found under ${FROTH_WEBRTC_OUT}/obj/buildtools/third_party/libc++abi/libc++abi")
  endif()
  list(SORT FROTH_LIBCXXABI_OBJECTS)

  set(FROTH_FFMPEG_RUNTIME_PATHS
    /lib
    /lib64
    /usr/lib
    /usr/lib64
    /lib/x86_64-linux-gnu
    /usr/lib/x86_64-linux-gnu
    /lib/aarch64-linux-gnu
    /usr/lib/aarch64-linux-gnu
  )

  # Many environments only have FFmpeg runtime packages installed, which ship
  # versioned SONAME files (e.g. libavformat.so.60) but not unversioned
  # development symlinks (libavformat.so). Look up both forms.
  find_library(AVFORMAT_LIBRARY NAMES avformat libavformat.so.61 libavformat.so.60 libavformat.so.59
    PATHS ${FROTH_FFMPEG_RUNTIME_PATHS}
    NO_CMAKE_FIND_ROOT_PATH
  )
  find_library(AVCODEC_LIBRARY NAMES avcodec libavcodec.so.61 libavcodec.so.60 libavcodec.so.59
    PATHS ${FROTH_FFMPEG_RUNTIME_PATHS}
    NO_CMAKE_FIND_ROOT_PATH
  )
  find_library(AVUTIL_LIBRARY NAMES avutil libavutil.so.59 libavutil.so.58 libavutil.so.57
    PATHS ${FROTH_FFMPEG_RUNTIME_PATHS}
    NO_CMAKE_FIND_ROOT_PATH
  )
  find_library(SWRESAMPLE_LIBRARY NAMES swresample libswresample.so.5 libswresample.so.4 libswresample.so.3
    PATHS ${FROTH_FFMPEG_RUNTIME_PATHS}
    NO_CMAKE_FIND_ROOT_PATH
  )
  find_library(SWSCALE_LIBRARY NAMES swscale libswscale.so.8 libswscale.so.7 libswscale.so.6
    PATHS ${FROTH_FFMPEG_RUNTIME_PATHS}
    NO_CMAKE_FIND_ROOT_PATH
  )
  if(NOT AVFORMAT_LIBRARY OR NOT AVCODEC_LIBRARY OR NOT AVUTIL_LIBRARY OR NOT SWRESAMPLE_LIBRARY OR NOT SWSCALE_LIBRARY)
    message(FATAL_ERROR "Missing FFmpeg runtime libraries (avformat/avcodec/avutil/swresample/swscale)")
  endif()

  add_executable(froth_tdlib_cnode
    src/main.cpp
    ${FROTH_TGCALLS_FULL_SOURCES}
  )

  set_target_properties(froth_tdlib_cnode PROPERTIES
    CXX_STANDARD 20
    CXX_STANDARD_REQUIRED ON
  )

  target_include_directories(froth_tdlib_cnode PRIVATE
    "${EI_INCLUDE_DIR}"
    "${TDLIB_DIR}"
    "${FROTH_TDJSON_INCLUDE_DIR}"
    "${TGCALLS_DIR}"
    "${TGCALLS_DIR}/tgcalls"
    "${FROTH_WEBRTC_ROOT}"
    "${FROTH_WEBRTC_OUT}/gen"
    "${FROTH_WEBRTC_ROOT}/buildtools/third_party/libc++"
    "${FROTH_ABSEIL_DIR}"
    "${FROTH_LIBYUV_DIR}/include"
    "${FROTH_FFMPEG_DIR}"
    "${FROTH_FFMPEG_CONFIG_DIR}"
    "${FROTH_RNNOISE_DIR}/include"
    "${FROTH_OVERLAY_DIR}"
  )

  target_compile_options(froth_tdlib_cnode PRIVATE
    -fPIC
    -pthread
    -fno-delete-null-pointer-checks
    -fno-ident
    -fno-strict-aliasing
    -fstack-protector
    -funwind-tables
    -fcolor-diagnostics
    -fmerge-all-constants
    -ffp-contract=off
    -fcomplete-member-pointers
    -m64
    -msse3
    -ftrivial-auto-var-init=pattern
    -O2
    -fdata-sections
    -ffunction-sections
    -fno-unique-section-names
    -fno-math-errno
    -fno-omit-frame-pointer
    -g0
    -fvisibility=default
    -fvisibility-inlines-hidden
    -fno-exceptions
    -fno-rtti
    -Wall
    -Wextra
    -Wno-unused-parameter
    -Wno-invalid-offsetof
    -Wno-vla-extension
    -Wno-thread-safety-reference-return
    -Wshadow
    -Wno-shadow
    --sysroot=${FROTH_SYSROOT}
    -nostdinc++
    -isystem${FROTH_WEBRTC_ROOT}/third_party/libc++/src/include
    -isystem${FROTH_WEBRTC_ROOT}/third_party/libc++abi/src/include
  )

  target_compile_definitions(froth_tdlib_cnode PRIVATE
    USE_UDEV
    __STDC_CONSTANT_MACROS
    __STDC_FORMAT_MACROS
    _FORTIFY_SOURCE=2
    _FILE_OFFSET_BITS=64
    _LARGEFILE_SOURCE
    _LARGEFILE64_SOURCE
    _GNU_SOURCE
    CR_CLANG_REVISION="llvmorg-18-init-17730-gf670112a-4"
    NDEBUG
    NVALGRIND
    DYNAMIC_ANNOTATIONS_ENABLED=0
    WEBRTC_ENABLE_PROTOBUF=0
    WEBRTC_STRICT_FIELD_TRIALS=0
    RTC_ENABLE_VP9
    WEBRTC_HAVE_SCTP
    WEBRTC_ENABLE_LIBEVENT
    WEBRTC_POSIX
    WEBRTC_LINUX
    WEBRTC_LIBRARY_IMPL
    WEBRTC_ENABLE_AVX2
    WEBRTC_NON_STATIC_TRACE_EVENT_HANDLERS=0
    HAVE_NETINET_IN_H
    HAVE_SCTP
    NO_MAIN_THREAD_WRAPPING
    RTC_DISABLE_TRACE_EVENTS
    WEBRTC_APM_DEBUG_DUMP=0
    WEBRTC_HAVE_DCSCTP
    WEBRTC_OPUS_SUPPORT_120MS_PTIME=1
    WEBRTC_OPUS_VARIABLE_COMPLEXITY=0
    ABSL_ALLOCATOR_NOTHROW=1
    _LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_EXTENSIVE
    _LIBCPP_DISABLE_VISIBILITY_ANNOTATIONS
    _LIBCXXABI_DISABLE_VISIBILITY_ANNOTATIONS
    CR_LIBCXX_REVISION=9d119c1f4a097b7d27210874f4eba3fc91a83a4e
    CR_SYSROOT_KEY=20230611T210420Z-2
  )

  target_link_options(froth_tdlib_cnode PRIVATE
    -nostdlib++
  )
  if(UNIX AND NOT APPLE)
    target_link_options(froth_tdlib_cnode PRIVATE
      "-Wl,--export-dynamic"
      "-Wl,-rpath,$ORIGIN"
    )
  endif()

  target_link_libraries(froth_tdlib_cnode PRIVATE
    "${FROTH_TDJSON_LIBRARY}"
    "${EI_LIB}"
    "-Wl,--start-group"
    ${FROTH_WEBRTC_STATIC_LIBS}
    "-Wl,--end-group"
    ${FROTH_LIBCXX_OBJECTS}
    ${FROTH_LIBCXXABI_OBJECTS}
    "${AVFORMAT_LIBRARY}"
    "${AVCODEC_LIBRARY}"
    "${AVUTIL_LIBRARY}"
    "${SWRESAMPLE_LIBRARY}"
    "${SWSCALE_LIBRARY}"
    ${CMAKE_DL_LIBS}
    Threads::Threads
    z
    m
    c
    gcc_s
    gcc
  )
else()
  add_subdirectory("${TDLIB_DIR}" "${CMAKE_BINARY_DIR}/tdlib" EXCLUDE_FROM_ALL)

  add_library(froth_tgcalls_core STATIC
    "${TGCALLS_DIR}/tgcalls/Instance.cpp"
  )

  target_include_directories(froth_tgcalls_core PUBLIC
    "${TGCALLS_DIR}"
  )

  add_executable(froth_tdlib_cnode
    src/main.cpp
  )

  target_include_directories(froth_tdlib_cnode PRIVATE
    "${EI_INCLUDE_DIR}"
    "${TDLIB_DIR}"
  )

  target_link_libraries(froth_tdlib_cnode PRIVATE
    tdjson
    froth_tgcalls_core
    "${EI_LIB}"
    ${CMAKE_DL_LIBS}
    Threads::Threads
  )

  if(UNIX AND NOT APPLE)
    # Allow dlopen()-ed plugins to resolve C++ symbols from this executable.
    target_link_options(froth_tdlib_cnode PRIVATE "-Wl,--export-dynamic")
  endif()
endif()

# When packaged alongside libtdjson, load it from the executable's directory.
set_target_properties(froth_tdlib_cnode PROPERTIES
  ENABLE_EXPORTS ON
  BUILD_RPATH "$ORIGIN"
  INSTALL_RPATH "$ORIGIN"
)
