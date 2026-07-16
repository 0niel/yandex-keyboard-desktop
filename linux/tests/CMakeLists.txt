cmake_minimum_required(VERSION 3.16)
project(yandex_keyboard_linux_native_tests LANGUAGES CXX)

option(YKD_ENABLE_SANITIZERS "Enable AddressSanitizer and UBSan" OFF)

enable_testing()
find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK REQUIRED IMPORTED_TARGET gtk+-3.0)
pkg_check_modules(GIO REQUIRED IMPORTED_TARGET gio-2.0)
pkg_check_modules(X11 REQUIRED IMPORTED_TARGET x11)
pkg_check_modules(XFIXES REQUIRED IMPORTED_TARGET xfixes)

add_executable(
  x11_clipboard_reader_test
  x11_clipboard_reader_test.cc
  ../x11_clipboard_reader.cc
)
target_include_directories(x11_clipboard_reader_test PRIVATE ..)
target_compile_features(x11_clipboard_reader_test PRIVATE cxx_std_17)
target_compile_options(x11_clipboard_reader_test PRIVATE -Wall -Wextra -Werror)
if(YKD_ENABLE_SANITIZERS)
  target_compile_options(
    x11_clipboard_reader_test PRIVATE -fsanitize=address,undefined
    -fno-omit-frame-pointer -fno-sanitize-recover=undefined
  )
  target_link_options(
    x11_clipboard_reader_test PRIVATE -fsanitize=address,undefined
  )
endif()
target_link_libraries(
  x11_clipboard_reader_test PRIVATE PkgConfig::GTK PkgConfig::X11
                                    PkgConfig::XFIXES
)
add_test(NAME x11_clipboard_reader COMMAND x11_clipboard_reader_test)

add_executable(
  x11_clipboard_transaction_test
  x11_clipboard_transaction_test.cc
  ../x11_clipboard_transaction.cc
)
target_include_directories(x11_clipboard_transaction_test PRIVATE ..)
target_compile_features(x11_clipboard_transaction_test PRIVATE cxx_std_17)
target_compile_options(
  x11_clipboard_transaction_test PRIVATE -Wall -Wextra -Werror
)
if(YKD_ENABLE_SANITIZERS)
  target_compile_options(
    x11_clipboard_transaction_test PRIVATE -fsanitize=address,undefined
    -fno-omit-frame-pointer -fno-sanitize-recover=undefined
  )
  target_link_options(
    x11_clipboard_transaction_test PRIVATE -fsanitize=address,undefined
  )
endif()
target_link_libraries(
  x11_clipboard_transaction_test PRIVATE PkgConfig::X11
)
add_test(NAME x11_clipboard_transaction COMMAND x11_clipboard_transaction_test)

add_executable(
  wayland_global_shortcuts_portal_test
  wayland_global_shortcuts_portal_test.cc
  ../wayland_global_shortcuts_portal.cc
)
target_include_directories(wayland_global_shortcuts_portal_test PRIVATE ..)
target_compile_features(wayland_global_shortcuts_portal_test PRIVATE cxx_std_17)
target_compile_options(
  wayland_global_shortcuts_portal_test PRIVATE -Wall -Wextra -Werror
)
target_compile_definitions(
  wayland_global_shortcuts_portal_test PRIVATE YKD_ENABLE_TEST_HOOKS=1
)
if(YKD_ENABLE_SANITIZERS)
  target_compile_options(
    wayland_global_shortcuts_portal_test PRIVATE -fsanitize=address,undefined
    -fno-omit-frame-pointer -fno-sanitize-recover=undefined
  )
  target_link_options(
    wayland_global_shortcuts_portal_test PRIVATE -fsanitize=address,undefined
  )
endif()
target_link_libraries(
  wayland_global_shortcuts_portal_test PRIVATE PkgConfig::GIO
)
add_test(
  NAME wayland_global_shortcuts_portal
  COMMAND wayland_global_shortcuts_portal_test
)
if(YKD_ENABLE_SANITIZERS)
  set_tests_properties(
    wayland_global_shortcuts_portal
    PROPERTIES ENVIRONMENT "ASAN_OPTIONS=detect_leaks=0:abort_on_error=1"
  )
endif()
