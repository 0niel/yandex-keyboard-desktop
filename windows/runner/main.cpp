#include <flutter/dart_project.h>
#include <flutter/flutter_engine.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "native_clipboard_snapshot.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  std::vector<std::string> command_line_arguments = GetCommandLineArguments();
  if (command_line_arguments.size() == 1 &&
      command_line_arguments.front() ==
          "--yandex-keyboard-native-clipboard-broker") {
    return RunNativeClipboardSnapshotBroker();
  }
  if (command_line_arguments.size() == 1 &&
      command_line_arguments.front() ==
          "--yandex-keyboard-native-clipboard-broker-stall-test") {
    ::Sleep(30000);
    return EXIT_FAILURE;
  }
  if (command_line_arguments.size() == 1 &&
      command_line_arguments.front() ==
          "--yandex-keyboard-native-clipboard-broker-no-reply-test") {
    return RunNativeClipboardBrokerNoReplyTest();
  }
  if (command_line_arguments.size() == 1 &&
      command_line_arguments.front() ==
          "--yandex-keyboard-native-clipboard-broker-integration-self-test") {
    return RunNativeClipboardBrokerIntegrationSelfTest();
  }

  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  if (!command_line_arguments.empty() &&
      command_line_arguments.front() == "--yandex-keyboard-uia-helper") {
    flutter::DartProject headless_project(L"data");
    headless_project.set_dart_entrypoint_arguments(command_line_arguments);
    flutter::FlutterEngine engine(headless_project);
    if (!engine.Run()) {
      ::CoUninitialize();
      return EXIT_FAILURE;
    }
    ::MSG msg;
    while (::GetMessage(&msg, nullptr, 0, 0)) {
      ::TranslateMessage(&msg);
      ::DispatchMessage(&msg);
    }
    ::CoUninitialize();
    return EXIT_SUCCESS;
  }

  flutter::DartProject project(L"data");

  if (command_line_arguments.size() == 1 &&
      command_line_arguments.front() ==
          "--yandex-keyboard-native-clipboard-memory-self-test") {
    const int result = RunNativeClipboardSnapshotMemorySelfTest();
    ::CoUninitialize();
    return result;
  }
  if (command_line_arguments.size() == 1 &&
      command_line_arguments.front() ==
          "--yandex-keyboard-native-clipboard-broker-timeout-self-test") {
    const int result = RunNativeClipboardBrokerTimeoutSelfTest();
    ::CoUninitialize();
    return result;
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  ::HANDLE singleton = ::CreateMutexW(
      nullptr, TRUE, L"Local\\YandexKeyboardDesktopSingleton");
  if (singleton == nullptr || ::GetLastError() == ERROR_ALREADY_EXISTS) {
    if (singleton != nullptr) ::CloseHandle(singleton);
    OutputDebugStringW(L"YKD: another instance already running; exiting\n");
    ::MessageBoxW(nullptr,
                  L"Yandex Keyboard Desktop уже запущен (значок в трее).",
                  L"Yandex Keyboard Desktop", MB_OK | MB_ICONINFORMATION);
    ::CoUninitialize();
    return EXIT_SUCCESS;
  }

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"yandex_keyboard_desktop", origin, size)) {
    ::ReleaseMutex(singleton);
    ::CloseHandle(singleton);
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
