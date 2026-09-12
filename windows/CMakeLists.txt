# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(voipcloud LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "VoipCloud")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)
if(POLICY CMP0177)
  cmake_policy(SET CMP0177 NEW)
endif()

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)

if(TARGET flutter_secure_storage_windows_plugin)
  target_include_directories(flutter_secure_storage_windows_plugin PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/flutter/ephemeral/.plugin_symlinks/flutter_secure_storage_windows/windows"
    "$ENV{LOCALAPPDATA}/Pub/Cache/hosted/pub.dev/flutter_secure_storage_windows-4.1.0/windows"
    "$ENV{LOCALAPPDATA}/Pub/Cache/hosted/pub.dev/flutter_secure_storage_windows-4.2.2/windows")
  target_include_directories(${BINARY_NAME} PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/flutter/ephemeral/.plugin_symlinks/flutter_secure_storage_windows/windows/include"
    "$ENV{LOCALAPPDATA}/Pub/Cache/hosted/pub.dev/flutter_secure_storage_windows-4.1.0/windows/include"
    "$ENV{LOCALAPPDATA}/Pub/Cache/hosted/pub.dev/flutter_secure_storage_windows-4.2.2/windows/include")
endif()

# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

option(VOIPCLOUD_CPACK_INSTALL
  "Generate a relative install graph suitable for CPack" OFF)
if(VOIPCLOUD_CPACK_INSTALL)
  set(INSTALL_BUNDLE_ROOT ".")
  set(INSTALL_BUNDLE_DATA_DIR "data")
  set(INSTALL_BUNDLE_LIB_DIR ".")
else()
  set(INSTALL_BUNDLE_ROOT "${CMAKE_INSTALL_PREFIX}")
  set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
  set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")
endif()

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${INSTALL_BUNDLE_ROOT}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Bundle the locally installed Linphone SDK runtime beside VoipCloud.exe. The
# native bridge resolves liblinphone dynamically, so no import library is
# needed, but liblinphone and all of its companion DLLs must be present at
# runtime.
set(LINPHONE_SDK_BIN
  "${CMAKE_CURRENT_SOURCE_DIR}/third_party/linphone/linphone-sdk/win64/bin")
set(LINPHONE_SDK_ROOT
  "${CMAKE_CURRENT_SOURCE_DIR}/third_party/linphone/linphone-sdk/win64")
if(EXISTS "${LINPHONE_SDK_BIN}/liblinphone.dll")
  file(GLOB LINPHONE_RUNTIME_DLLS CONFIGURE_DEPENDS
    "${LINPHONE_SDK_BIN}/*.dll")
  install(FILES ${LINPHONE_RUNTIME_DLLS}
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)

  # Linphone resolves these resources relative to its configured top resource
  # directory. Missing BELR grammars cause the SDK to terminate the process
  # while creating the core, rather than returning an error.
  foreach(LINPHONE_RESOURCE_DIR belr linphone sounds images)
    if(EXISTS "${LINPHONE_SDK_ROOT}/share/${LINPHONE_RESOURCE_DIR}")
      install(DIRECTORY
        "${LINPHONE_SDK_ROOT}/share/${LINPHONE_RESOURCE_DIR}"
        DESTINATION "${INSTALL_BUNDLE_LIB_DIR}/share"
        COMPONENT Runtime)
    endif()
  endforeach()

  if(EXISTS "${LINPHONE_SDK_ROOT}/lib/mediastreamer/plugins")
    install(DIRECTORY
      "${LINPHONE_SDK_ROOT}/lib/mediastreamer/plugins"
      DESTINATION "${INSTALL_BUNDLE_LIB_DIR}/lib/mediastreamer"
      COMPONENT Runtime
      FILES_MATCHING PATTERN "*.dll")
  endif()
else()
  message(WARNING
    "Linphone SDK not found at ${LINPHONE_SDK_BIN}; SIP calling will be unavailable.")
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime
   OPTIONAL)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
if(VOIPCLOUD_CPACK_INSTALL)
  install(CODE "
    file(REMOVE_RECURSE
      \"\${CMAKE_INSTALL_PREFIX}/${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
    " COMPONENT Runtime)
else()
  install(CODE "
    file(REMOVE_RECURSE
      \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
    " COMPONENT Runtime)
endif()
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)

# Produce a signed-distribution-ready MSI from the exact CMake install graph.
# CPack/WiX therefore packages the Flutter runtime, plugins, Linphone DLLs,
# mediastreamer plugins, resources, native assets, and AOT data together.
set(CPACK_GENERATOR "WIX")
set(CPACK_PACKAGE_NAME "VoipCloud")
set(CPACK_PACKAGE_VENDOR "ThinkSwift")
set(CPACK_PACKAGE_DESCRIPTION_SUMMARY "VoipCloud business softphone")
set(CPACK_PACKAGE_VERSION_MAJOR "${FLUTTER_VERSION_MAJOR}")
set(CPACK_PACKAGE_VERSION_MINOR "${FLUTTER_VERSION_MINOR}")
set(CPACK_PACKAGE_VERSION_PATCH "${FLUTTER_VERSION_PATCH}")
set(CPACK_PACKAGE_INSTALL_DIRECTORY "VoipCloud")
set(CPACK_PACKAGE_EXECUTABLES "VoipCloud" "VoipCloud")
set(CPACK_RESOURCE_FILE_LICENSE
  "${CMAKE_CURRENT_SOURCE_DIR}/installer/terms_of_service.txt")
# The desktop shortcut remains selected by default but is conditioned by the
# custom WiX options page. Taskbar pinning itself is never performed by MSI;
# the selected option launches VoipCloud with an in-app pin offer instead.
set(CPACK_CREATE_DESKTOP_LINKS "VoipCloud")
set(CPACK_WIX_UI_REF "VoipCloud_InstallDir")
set(CPACK_WIX_EXTRA_SOURCES
  "${CMAKE_CURRENT_SOURCE_DIR}/installer/voipcloud_options.wxs")
set(CPACK_WIX_PATCH_FILE
  "${CMAKE_CURRENT_SOURCE_DIR}/installer/desktop_shortcut_patch.xml")
set(CPACK_WIX_UPGRADE_GUID "8D72D853-EE12-4E7E-A33C-9C1777F99F35")
set(CPACK_WIX_PRODUCT_ICON
  "${CMAKE_CURRENT_SOURCE_DIR}/runner/resources/app_icon.ico")
set(CPACK_WIX_PROPERTY_ARPURLINFOABOUT "https://voipcloud.ca")
set(CPACK_WIX_PROPERTY_ARPCONTACT "ThinkSwift Support")
set(CPACK_WIX_PROPERTY_ARPHELPLINK "https://voipcloud.ca")
include(CPack)
