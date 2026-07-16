cmake_minimum_required(VERSION 3.10)
project(runner LANGUAGES CXX)

option(YKD_ENABLE_SANITIZERS
  "Enable AddressSanitizer and UndefinedBehaviorSanitizer for native runner code"
  OFF)
option(YKD_BUILD_PLUGIN_LIFECYCLE_TESTS
  "Build the Linux native bridge GObject lifecycle test"
  OFF)

set(BINARY_NAME "yandex_keyboard_desktop")
set(APPLICATION_ID "io.github.oniel.yandex_keyboard_desktop")

cmake_policy(SET CMP0063 NEW)

set(CMAKE_INSTALL_RPATH "$ORIGIN/lib")

if(FLUTTER_TARGET_PLATFORM_SYSROOT)
  set(CMAKE_SYSROOT ${FLUTTER_TARGET_PLATFORM_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH ${CMAKE_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
  set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
endif()

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE "Debug" CACHE
    STRING "Flutter build mode" FORCE)
  set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
    "Debug" "Profile" "Release")
endif()

function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_14)
  target_compile_options(${TARGET} PRIVATE -Wall -Werror)
  target_compile_options(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:-O3>")
  target_compile_definitions(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:NDEBUG>")
endfunction()

set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK REQUIRED IMPORTED_TARGET gtk+-3.0)
pkg_check_modules(GIO REQUIRED IMPORTED_TARGET gio-2.0)
pkg_check_modules(FONTCONFIG REQUIRED IMPORTED_TARGET fontconfig)
pkg_check_modules(X11 REQUIRED IMPORTED_TARGET x11)
pkg_check_modules(XFIXES REQUIRED IMPORTED_TARGET xfixes)
pkg_check_modules(XTST REQUIRED IMPORTED_TARGET xtst)
pkg_check_modules(XRES REQUIRED IMPORTED_TARGET xres>=1.2)

add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")

add_executable(${BINARY_NAME}
  "main.cc"
  "my_application.cc"
  "linux_native_bridge_plugin.cc"
  "wayland_global_shortcuts_plugin.cc"
  "wayland_global_shortcuts_portal.cc"
  "x11_clipboard_reader.cc"
  "x11_clipboard_transaction.cc"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

apply_standard_settings(${BINARY_NAME})
if(YKD_ENABLE_SANITIZERS)
  target_compile_options(${BINARY_NAME} PRIVATE
    -fsanitize=address,undefined
    -fno-omit-frame-pointer
    -fno-sanitize-recover=undefined
  )
  target_link_options(${BINARY_NAME} PRIVATE -fsanitize=address,undefined)
endif()

target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GIO)
target_link_libraries(${BINARY_NAME} PRIVATE
  PkgConfig::X11
  PkgConfig::XFIXES
  PkgConfig::XTST
  PkgConfig::XRES
)

add_dependencies(${BINARY_NAME} flutter_assemble)

set_target_properties(${BINARY_NAME}
  PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/intermediates_do_not_run"
)


include(flutter/generated_plugins.cmake)

foreach(plugin ${FLUTTER_PLUGIN_LIST})
  if(TARGET ${plugin}_plugin)
    set_target_properties(${plugin}_plugin PROPERTIES
      BUILD_WITH_INSTALL_RPATH TRUE
      INSTALL_RPATH "$ORIGIN")
  endif()
endforeach(plugin)

if(YKD_BUILD_PLUGIN_LIFECYCLE_TESTS)
  enable_testing()
  add_executable(linux_native_bridge_plugin_lifecycle_test
    "tests/linux_native_bridge_plugin_lifecycle_test.cc"
    "linux_native_bridge_plugin.cc"
    "x11_clipboard_reader.cc"
    "x11_clipboard_transaction.cc"
  )
  target_compile_features(linux_native_bridge_plugin_lifecycle_test
    PRIVATE cxx_std_17)
  target_include_directories(linux_native_bridge_plugin_lifecycle_test
    PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
  target_compile_options(linux_native_bridge_plugin_lifecycle_test PRIVATE
    -Wall -Wextra -Werror)
  target_compile_definitions(linux_native_bridge_plugin_lifecycle_test
    PRIVATE YKD_ENABLE_TEST_HOOKS=1)
  if(YKD_ENABLE_SANITIZERS)
    target_compile_options(linux_native_bridge_plugin_lifecycle_test PRIVATE
      -fsanitize=address,undefined
      -fno-omit-frame-pointer
      -fno-sanitize-recover=undefined)
    target_link_options(linux_native_bridge_plugin_lifecycle_test PRIVATE
      -fsanitize=address,undefined)
  endif()
  target_link_libraries(linux_native_bridge_plugin_lifecycle_test PRIVATE
    flutter
    PkgConfig::GTK
    PkgConfig::FONTCONFIG
    PkgConfig::X11
    PkgConfig::XFIXES
    PkgConfig::XTST
    PkgConfig::XRES
  )
  add_dependencies(linux_native_bridge_plugin_lifecycle_test flutter_assemble)
  set_target_properties(linux_native_bridge_plugin_lifecycle_test PROPERTIES
    BUILD_RPATH "${FLUTTER_MANAGED_DIR}/ephemeral")
  add_test(NAME linux_native_bridge_plugin_lifecycle
    COMMAND linux_native_bridge_plugin_lifecycle_test)

  add_executable(wayland_global_shortcuts_plugin_contract_test
    "tests/wayland_global_shortcuts_plugin_contract_test.cc"
    "wayland_global_shortcuts_plugin.cc"
    "wayland_global_shortcuts_portal.cc"
  )
  target_compile_features(wayland_global_shortcuts_plugin_contract_test
    PRIVATE cxx_std_17)
  target_include_directories(wayland_global_shortcuts_plugin_contract_test
    PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
  target_compile_options(wayland_global_shortcuts_plugin_contract_test PRIVATE
    -Wall -Wextra -Werror)
  target_compile_definitions(wayland_global_shortcuts_plugin_contract_test
    PRIVATE YKD_ENABLE_TEST_HOOKS=1)
  if(YKD_ENABLE_SANITIZERS)
    target_compile_options(wayland_global_shortcuts_plugin_contract_test
      PRIVATE -fsanitize=address,undefined -fno-omit-frame-pointer
      -fno-sanitize-recover=undefined)
    target_link_options(wayland_global_shortcuts_plugin_contract_test
      PRIVATE -fsanitize=address,undefined)
  endif()
  target_link_libraries(wayland_global_shortcuts_plugin_contract_test PRIVATE
    flutter PkgConfig::GIO PkgConfig::GTK)
  add_dependencies(wayland_global_shortcuts_plugin_contract_test
    flutter_assemble)
  set_target_properties(wayland_global_shortcuts_plugin_contract_test
    PROPERTIES BUILD_RPATH "${FLUTTER_MANAGED_DIR}/ephemeral")
  add_test(NAME wayland_global_shortcuts_plugin_contract
    COMMAND wayland_global_shortcuts_plugin_contract_test)
endif()


set(BUILD_BUNDLE_DIR "${PROJECT_BINARY_DIR}/bundle")
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

install(CODE "
  file(REMOVE_RECURSE \"${BUILD_BUNDLE_DIR}/\")
  " COMPONENT Runtime)

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}/lib")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

foreach(bundled_library ${PLUGIN_BUNDLED_LIBRARIES})
  install(FILES "${bundled_library}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endforeach(bundled_library)

set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/linux/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

if(NOT CMAKE_BUILD_TYPE MATCHES "Debug")
  install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()
