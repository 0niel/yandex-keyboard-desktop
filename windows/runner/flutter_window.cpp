#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"

namespace {

constexpr char kHotkeyChannel[] = "ykd/native_hotkeys";
constexpr char kOverlayChannel[] = "ykd/overlay";
constexpr UINT kOutsideClickMessage = WM_APP + 0x102;

FlutterWindow* g_hotkey_window = nullptr;

int ReadInt(const flutter::EncodableMap& map, const char* key) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return 0;
  if (const auto* value = std::get_if<int32_t>(&it->second)) return *value;
  if (const auto* value = std::get_if<int64_t>(&it->second)) {
    return static_cast<int>(*value);
  }
  return 0;
}

}

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  hotkey_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kHotkeyChannel,
          &flutter::StandardMethodCodec::GetInstance());
  hotkey_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleHotkeyMethodCall(call, std::move(result));
      });
  overlay_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kOverlayChannel,
          &flutter::StandardMethodCodec::GetInstance());
  overlay_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleOverlayMethodCall(call, std::move(result));
      });
  g_hotkey_window = this;

  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  SetOutsideClickWatch(false);
  for (const int id : hotkey_ids_) {
    ::UnregisterHotKey(GetHandle(), id);
  }
  hotkey_ids_.clear();
  if (g_hotkey_window == this) g_hotkey_window = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::SetOutsideClickWatch(bool enabled) {
  if (enabled == (mouse_hook_ != nullptr)) return;
  if (enabled) {
    mouse_hook_ = ::SetWindowsHookExW(WH_MOUSE_LL,
                                      &FlutterWindow::LowLevelMouseProc,
                                      ::GetModuleHandleW(nullptr), 0);
  } else {
    ::UnhookWindowsHookEx(mouse_hook_);
    mouse_hook_ = nullptr;
  }
}

LRESULT CALLBACK FlutterWindow::LowLevelMouseProc(int code, WPARAM wparam,
                                                  LPARAM lparam) {
  FlutterWindow* window = g_hotkey_window;
  if (code == HC_ACTION && window != nullptr &&
      (wparam == WM_LBUTTONDOWN || wparam == WM_RBUTTONDOWN ||
       wparam == WM_MBUTTONDOWN)) {
    const auto* event = reinterpret_cast<const MSLLHOOKSTRUCT*>(lparam);
    RECT bounds;
    const HWND handle = window->GetHandle();
    if (handle != nullptr && ::IsWindowVisible(handle) &&
        ::GetWindowRect(handle, &bounds) &&
        !::PtInRect(&bounds, event->pt)) {
      ::PostMessageW(handle, kOutsideClickMessage, 0, 0);
    }
  }
  return ::CallNextHookEx(nullptr, code, wparam, lparam);
}

void FlutterWindow::DispatchHotkey(int id) {
  if (hotkey_channel_) {
    hotkey_channel_->InvokeMethod(
        "onHotKey",
        std::make_unique<flutter::EncodableValue>(id));
  }
}

void FlutterWindow::HandleHotkeyMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
  if (call.method_name() == "register") {
    if (arguments == nullptr) {
      result->Error("bad_args", "Expected {id, modifiers, key}.");
      return;
    }
    const int id = ReadInt(*arguments, "id");
    const UINT modifiers = static_cast<UINT>(ReadInt(*arguments, "modifiers"));
    const UINT key = static_cast<UINT>(ReadInt(*arguments, "key"));
    if (::RegisterHotKey(GetHandle(), id, modifiers | MOD_NOREPEAT, key) != 0) {
      hotkey_ids_.insert(id);
      result->Success(flutter::EncodableValue(true));
      return;
    }
    result->Success(flutter::EncodableValue(false));
    return;
  }
  if (call.method_name() == "unregister") {
    if (arguments == nullptr) {
      result->Error("bad_args", "Expected {id}.");
      return;
    }
    const int id = ReadInt(*arguments, "id");
    const bool unregistered = ::UnregisterHotKey(GetHandle(), id) != 0;
    hotkey_ids_.erase(id);
    result->Success(flutter::EncodableValue(unregistered));
    return;
  }
  if (call.method_name() == "unregisterAll") {
    bool all_released = true;
    for (const int id : hotkey_ids_) {
      all_released = (::UnregisterHotKey(GetHandle(), id) != 0) && all_released;
    }
    hotkey_ids_.clear();
    result->Success(flutter::EncodableValue(all_released));
    return;
  }
  result->NotImplemented();
}

void FlutterWindow::HandleOverlayMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == "watchOutsideClick") {
    const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
    bool enabled = false;
    if (arguments != nullptr) {
      const auto it = arguments->find(flutter::EncodableValue("enabled"));
      if (it != arguments->end()) {
        if (const auto* value = std::get_if<bool>(&it->second)) {
          enabled = *value;
        }
      }
    }
    SetOutsideClickWatch(enabled);
    result->Success(flutter::EncodableValue(true));
    return;
  }
  result->NotImplemented();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_HOTKEY:
      DispatchHotkey(static_cast<int>(wparam));
      return 0;
    case kOutsideClickMessage:
      if (overlay_channel_) {
        overlay_channel_->InvokeMethod(
            "onOutsideClick",
            std::make_unique<flutter::EncodableValue>(nullptr));
      }
      return 0;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
