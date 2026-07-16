#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <windows.h>

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>

#include <memory>
#include <set>
#include <vector>

#include "win32_window.h"

class FlutterWindow : public Win32Window {
 public:
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  struct LowLevelHotkey {
    int id;
    UINT modifiers;
    UINT key;
    bool active;
  };

  void HandleHotkeyMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void HandleOverlayMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  bool EnsureLowLevelHook();
  void ReleaseLowLevelHook();
  void DispatchHotkey(int id);
  void SetOutsideClickWatch(bool enabled);

  static LRESULT CALLBACK LowLevelKeyboardProc(int code, WPARAM wparam,
                                               LPARAM lparam);
  static LRESULT CALLBACK LowLevelMouseProc(int code, WPARAM wparam,
                                            LPARAM lparam);

  flutter::DartProject project_;

  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      hotkey_channel_;
  std::set<int> hotkey_ids_;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      overlay_channel_;

  std::vector<LowLevelHotkey> low_level_hotkeys_;
  HHOOK keyboard_hook_ = nullptr;

  HHOOK mouse_hook_ = nullptr;
};

#endif
