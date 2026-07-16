#include "linux_native_bridge_plugin.h"

#include <algorithm>
#include <chrono>
#include <cstring>
#include <map>
#include <set>
#include <utility>

#ifdef GDK_WINDOWING_X11
#include "x11_clipboard_reader.h"
#include "x11_clipboard_transaction.h"
#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <X11/extensions/XRes.h>
#include <X11/extensions/XTest.h>
#include <X11/extensions/Xfixes.h>
#include <X11/keysym.h>
#include <gdk/gdkx.h>
#endif

#define LINUX_NATIVE_BRIDGE_PLUGIN(obj)                                        \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), linux_native_bridge_plugin_get_type(),    \
                              LinuxNativeBridgePlugin))

namespace {

constexpr char kChannelName[] =
    "io.github.oniel.yandex_keyboard_desktop/linux_native";
constexpr gint64 kMaxClipboardSnapshotBytes = 8 * 1024 * 1024;
constexpr gint64 kMaxClipboardSnapshotTargets = 64;
constexpr gint64 kMaxClipboardTransferMilliseconds = 1000;
constexpr std::size_t kMaxRetainedSnapshots = 4;

typedef struct _LinuxNativeBridgePlugin {
  GObject parent_instance;
  FlPluginRegistrar *registrar;
  GWeakRef application_window;
#ifdef GDK_WINDOWING_X11
  ykd::X11ClipboardReader *clipboard_reader;
  std::map<gint64, ykd::X11ClipboardSnapshot> *clipboard_snapshots;
  gint64 next_clipboard_snapshot_id;
#endif
} LinuxNativeBridgePlugin;

typedef struct _LinuxNativeBridgePluginClass {
  GObjectClass parent_class;
} LinuxNativeBridgePluginClass;

GType linux_native_bridge_plugin_get_type();

G_DEFINE_TYPE(LinuxNativeBridgePlugin, linux_native_bridge_plugin,
              g_object_get_type())

FlMethodResponse *SuccessResponse(FlValue *value = nullptr) {
  return FL_METHOD_RESPONSE(fl_method_success_response_new(value));
}

FlMethodResponse *Error(const char *code, const char *message) {
  return FL_METHOD_RESPONSE(
      fl_method_error_response_new(code, message, nullptr));
}

FlMethodResponse *ClipboardError(const char *code, const char *message,
                                 bool retryable) {
  g_autoptr(FlValue) details = fl_value_new_map();
  fl_value_set_string_take(details, "retryable", fl_value_new_bool(retryable));
  return FL_METHOD_RESPONSE(
      fl_method_error_response_new(code, message, details));
}

bool ReadPositiveMapInt(FlValue *map, const char *key, gint64 *value) {
  if (map == nullptr || fl_value_get_type(map) != FL_VALUE_TYPE_MAP) {
    return false;
  }
  FlValue *field = fl_value_lookup_string(map, key);
  if (field == nullptr || fl_value_get_type(field) != FL_VALUE_TYPE_INT) {
    return false;
  }
  *value = fl_value_get_int(field);
  return *value > 0;
}

bool ReadMapUtf8Bytes(FlValue *map, const char *key, std::size_t max_bytes,
                      std::string *value) {
  if (map == nullptr || fl_value_get_type(map) != FL_VALUE_TYPE_MAP) {
    return false;
  }
  FlValue *field = fl_value_lookup_string(map, key);
  if (field == nullptr ||
      fl_value_get_type(field) != FL_VALUE_TYPE_UINT8_LIST) {
    return false;
  }
  const std::size_t length = fl_value_get_length(field);
  const auto *bytes = fl_value_get_uint8_list(field);
  if (length > max_bytes || (length != 0 && bytes == nullptr)) {
    return false;
  }
  const char *text = length == 0 ? "" : reinterpret_cast<const char *>(bytes);
  if (!g_utf8_validate(text, static_cast<gssize>(length), nullptr)) {
    return false;
  }
  value->assign(text, length);
  return true;
}

bool ReadWindowArgument(FlMethodCall *call, gint64 *value) {
  FlValue *arguments = fl_method_call_get_args(call);
  if (arguments == nullptr ||
      fl_value_get_type(arguments) != FL_VALUE_TYPE_INT) {
    return false;
  }
  *value = fl_value_get_int(arguments);
  return *value > 0;
}

GtkWindow *GetApplicationWindow(LinuxNativeBridgePlugin *self) {
  GObject *object =
      static_cast<GObject *>(g_weak_ref_get(&self->application_window));
  if (object == nullptr) {
    return nullptr;
  }
  if (!GTK_IS_WINDOW(object)) {
    g_object_unref(object);
    return nullptr;
  }
  return GTK_WINDOW(object);
}

bool SetApplicationWindowCanActivate(LinuxNativeBridgePlugin *self,
                                     gboolean can_activate) {
  GtkWindow *window = GetApplicationWindow(self);
  if (window == nullptr) {
    return false;
  }
  gtk_window_set_accept_focus(window, can_activate);
  gtk_window_set_focus_on_map(window, can_activate);
  g_object_unref(window);
  return true;
}

bool ShowApplicationWindowInactive(LinuxNativeBridgePlugin *self) {
  GtkWindow *window = GetApplicationWindow(self);
  if (window == nullptr) {
    return false;
  }
  GtkWidget *widget = GTK_WIDGET(window);
  const bool must_remap = gtk_window_is_active(window) ||
                          gtk_window_get_accept_focus(window) ||
                          gtk_window_get_focus_on_map(window);
  if (must_remap && gtk_widget_get_visible(widget)) {
    gtk_widget_hide(widget);
  }
  gtk_window_set_accept_focus(window, FALSE);
  gtk_window_set_focus_on_map(window, FALSE);
  gtk_widget_show(widget);
  g_object_unref(window);
  return true;
}

#ifdef GDK_WINDOWING_X11
bool IsX11() {
  GdkDisplay *display = gdk_display_get_default();
  return display != nullptr && GDK_IS_X11_DISPLAY(display);
}

FlMethodResponse *ClipboardReadFailure(ykd::X11ClipboardReadStatus status) {
  switch (status) {
  case ykd::X11ClipboardReadStatus::kUnavailable:
    return ClipboardError("linux_clipboard_unavailable",
                          "The X11 clipboard is unavailable.", true);
  case ykd::X11ClipboardReadStatus::kOwnerChanged:
    return ClipboardError("linux_clipboard_owner_changed",
                          "The clipboard owner changed during transfer.", true);
  case ykd::X11ClipboardReadStatus::kTimeout:
    return ClipboardError("linux_clipboard_transfer_timeout",
                          "The clipboard transfer timed out.", true);
  case ykd::X11ClipboardReadStatus::kTooManyTargets:
    return ClipboardError("linux_clipboard_too_many_targets",
                          "The clipboard exposes too many targets.", false);
  case ykd::X11ClipboardReadStatus::kTooLarge:
    return ClipboardError("linux_clipboard_snapshot_too_large",
                          "The clipboard exceeds the snapshot byte limit.",
                          false);
  case ykd::X11ClipboardReadStatus::kUnsupportedFormat:
    return ClipboardError("linux_clipboard_format_unsupported",
                          "The clipboard contains an unsupported format.",
                          false);
  case ykd::X11ClipboardReadStatus::kConversionRejected:
    return ClipboardError("linux_clipboard_conversion_rejected",
                          "The clipboard owner rejected a conversion.", false);
  case ykd::X11ClipboardReadStatus::kProtocolError:
    return ClipboardError("linux_clipboard_protocol_error",
                          "The clipboard owner sent an invalid response.",
                          false);
  case ykd::X11ClipboardReadStatus::kOk:
    break;
  }
  return ClipboardError("linux_clipboard_unknown_error",
                        "The clipboard operation failed.", false);
}

bool ReadClipboardBounds(FlMethodCall *call, gint64 *max_bytes,
                         gint64 *max_targets, gint64 *timeout_milliseconds) {
  FlValue *arguments = fl_method_call_get_args(call);
  return ReadPositiveMapInt(arguments, "maxBytes", max_bytes) &&
         ReadPositiveMapInt(arguments, "maxTargets", max_targets) &&
         ReadPositiveMapInt(arguments, "timeoutMilliseconds",
                            timeout_milliseconds) &&
         *max_bytes <= kMaxClipboardSnapshotBytes &&
         *max_targets <= kMaxClipboardSnapshotTargets &&
         *timeout_milliseconds <= kMaxClipboardTransferMilliseconds;
}

bool ReadStableCopyArguments(FlMethodCall *call, gint64 *handle,
                             gint64 *max_bytes, gint64 *max_targets,
                             gint64 *timeout_milliseconds) {
  FlValue *arguments = fl_method_call_get_args(call);
  return ReadPositiveMapInt(arguments, "handle", handle) &&
         ReadPositiveMapInt(arguments, "maxBytes", max_bytes) &&
         ReadPositiveMapInt(arguments, "maxTargets", max_targets) &&
         ReadPositiveMapInt(arguments, "timeoutMilliseconds",
                            timeout_milliseconds) &&
         *max_bytes <= kMaxClipboardSnapshotBytes &&
         *max_targets <= kMaxClipboardSnapshotTargets &&
         *timeout_milliseconds <= kMaxClipboardTransferMilliseconds;
}

FlMethodResponse *ClipboardMutationError(gint64 revision,
                                         const std::string &current_text) {
  g_autoptr(FlValue) details = fl_value_new_map();
  fl_value_set_string_take(details, "revision", fl_value_new_int(revision));
  fl_value_set_string_take(
      details, "currentText",
      fl_value_new_string_sized(current_text.data(), current_text.size()));
  return FL_METHOD_RESPONSE(fl_method_error_response_new(
      "linux_clipboard_mutated",
      "Clipboard ownership changed before the transaction was verified.",
      details));
}

class ClipboardTransactionPort final : public ykd::X11ClipboardTransactionPort {
public:
  explicit ClipboardTransactionPort(LinuxNativeBridgePlugin *plugin)
      : plugin_(plugin) {}

  void Drain() override { plugin_->clipboard_reader->Drain(); }
  bool active() const override { return plugin_->clipboard_reader->active(); }
  std::int64_t revision() const override {
    return plugin_->clipboard_reader->revision();
  }
  Window owner() const override {
    return plugin_->clipboard_reader->observed_selection_owner();
  }
  Time selection_timestamp() const override {
    return plugin_->clipboard_reader->observed_selection_timestamp();
  }
  Window owned_window() const override {
    return plugin_->clipboard_reader->owner_window();
  }
  bool AcquireRollbackText(std::int64_t expected_revision,
                           Window expected_owner,
                           Time expected_selection_timestamp,
                           const std::string &text) override {
    return plugin_->clipboard_reader->AcquireTextIfState(
        expected_revision, expected_owner, expected_selection_timestamp, text);
  }

private:
  LinuxNativeBridgePlugin *plugin_;
};

FlMethodResponse *CompleteClipboardMutation(
    LinuxNativeBridgePlugin *self, gint64 expected_revision,
    gint64 timeout_milliseconds, const std::string &written_text,
    const std::string &rollback_text,
    const ykd::X11ClipboardTransaction::AcquireOperation &acquire) {
  ClipboardTransactionPort port(self);
  ykd::X11ClipboardTransaction transaction(port);
  const auto result = transaction.Run(
      expected_revision, std::chrono::milliseconds(timeout_milliseconds),
      written_text, rollback_text, acquire);
  switch (result.status) {
  case ykd::X11ClipboardTransactionStatus::kCommitted: {
    g_autoptr(FlValue) value = fl_value_new_int(result.revision);
    return SuccessResponse(value);
  }
  case ykd::X11ClipboardTransactionStatus::kConflict:
    return SuccessResponse();
  case ykd::X11ClipboardTransactionStatus::kRolledBack:
  case ykd::X11ClipboardTransactionStatus::kAmbiguous:
    return ClipboardMutationError(result.revision, result.current_text);
  case ykd::X11ClipboardTransactionStatus::kUnavailable:
    return ClipboardError("linux_clipboard_unavailable",
                          "The X11 clipboard is unavailable.", true);
  }
  return ClipboardError("linux_clipboard_unknown_error",
                        "The clipboard operation failed.", false);
}

Display *GetDisplay() {
  if (!IsX11())
    return nullptr;
  return gdk_x11_display_get_xdisplay(gdk_display_get_default());
}

template <typename Result, typename Operation>
bool RunWithXErrorTrap(Display *display, Result *result, Operation operation) {
  GdkDisplay *gdk_display = gdk_display_get_default();
  if (display == nullptr || gdk_display == nullptr ||
      !GDK_IS_X11_DISPLAY(gdk_display)) {
    return false;
  }
  gdk_x11_display_error_trap_push(gdk_display);
  *result = operation();
  XSync(display, False);
  return gdk_x11_display_error_trap_pop(gdk_display) == 0;
}

Window ReadWindowProperty(Display *display, Window window,
                          const char *property_name) {
  const Atom property = XInternAtom(display, property_name, True);
  if (property == None)
    return None;

  Atom actual_type = None;
  int actual_format = 0;
  unsigned long item_count = 0;
  unsigned long bytes_after = 0;
  unsigned char *data = nullptr;
  const int status = XGetWindowProperty(display, window, property, 0, 1, False,
                                        XA_WINDOW, &actual_type, &actual_format,
                                        &item_count, &bytes_after, &data);
  if (status != Success || data == nullptr || actual_type != XA_WINDOW ||
      actual_format != 32 || item_count != 1) {
    if (data != nullptr)
      XFree(data);
    return None;
  }
  const Window value = *reinterpret_cast<Window *>(data);
  XFree(data);
  return value;
}

Window GetActiveWindow(Display *display) {
  const Window root = DefaultRootWindow(display);
  const Window active = ReadWindowProperty(display, root, "_NET_ACTIVE_WINDOW");
  if (active != None)
    return active;

  Window focused = None;
  int revert_to = RevertToNone;
  XGetInputFocus(display, &focused, &revert_to);
  return focused == PointerRoot ? None : focused;
}

bool IsWindowValid(Display *display, Window window) {
  if (window == None)
    return false;
  XWindowAttributes attributes{};
  bool valid = false;
  if (!RunWithXErrorTrap(display, &valid, [&]() {
        return XGetWindowAttributes(display, window, &attributes) != 0;
      })) {
    return false;
  }
  return valid;
}

bool HasXTest(Display *display) {
  int event_base = 0;
  int error_base = 0;
  int major = 0;
  int minor = 0;
  return XTestQueryExtension(display, &event_base, &error_base, &major,
                             &minor) != 0;
}

bool HasXFixes(Display *display) {
  int event_base = 0;
  int error_base = 0;
  return XFixesQueryExtension(display, &event_base, &error_base) != 0;
}

bool HasXResPid(Display *display) {
  int event_base = 0;
  int error_base = 0;
  int major = 0;
  int minor = 0;
  return XResQueryExtension(display, &event_base, &error_base) != 0 &&
         XResQueryVersion(display, &major, &minor) == Success &&
         (major > 1 || (major == 1 && minor >= 2));
}

gint64 ReadClientProcessIdUnsafe(Display *display, Window resource) {
  if (resource == None || !HasXResPid(display))
    return 0;
  XResClientIdSpec spec{};
  spec.client = resource;
  spec.mask = XRES_CLIENT_ID_PID_MASK;
  long count = 0;
  XResClientIdValue *values = nullptr;
  if (XResQueryClientIds(display, 1, &spec, &count, &values) != Success ||
      values == nullptr) {
    return 0;
  }
  gint64 process_id = 0;
  for (long index = 0; index < count; ++index) {
    if (XResGetClientIdType(&values[index]) == XRES_CLIENT_ID_PID) {
      const pid_t candidate = XResGetClientPid(&values[index]);
      if (candidate > 0)
        process_id = static_cast<gint64>(candidate);
      break;
    }
  }
  XResClientIdsDestroy(count, values);
  return process_id;
}

gint64 ReadClientProcessId(Display *display, Window resource) {
  gint64 process_id = 0;
  if (!RunWithXErrorTrap(display, &process_id, [&]() {
        return ReadClientProcessIdUnsafe(display, resource);
      })) {
    return 0;
  }
  return process_id;
}

bool RequestActivation(Display *display, Window window) {
  if (!IsWindowValid(display, window))
    return false;
  const Atom active_atom = XInternAtom(display, "_NET_ACTIVE_WINDOW", False);
  XEvent event{};
  event.xclient.type = ClientMessage;
  event.xclient.serial = 0;
  event.xclient.send_event = True;
  event.xclient.display = display;
  event.xclient.window = window;
  event.xclient.message_type = active_atom;
  event.xclient.format = 32;
  event.xclient.data.l[0] = 2;
  event.xclient.data.l[1] = CurrentTime;
  event.xclient.data.l[2] = 0;
  bool sent = false;
  if (!RunWithXErrorTrap(display, &sent, [&]() {
        const int result = XSendEvent(
            display, DefaultRootWindow(display), False,
            SubstructureRedirectMask | SubstructureNotifyMask, &event);
        return result != 0;
      })) {
    return false;
  }
  return sent;
}

bool IsKeyPressed(const char keymap[32], KeyCode keycode) {
  return keycode != 0 && (keymap[keycode / 8] & (1 << (keycode % 8))) != 0;
}

bool InjectControlChord(Display *display, Window target, KeySym key_symbol) {
  if (!HasXTest(display) || GetActiveWindow(display) != target)
    return false;

  const KeyCode control = XKeysymToKeycode(display, XK_Control_L);
  const KeyCode key = XKeysymToKeycode(display, key_symbol);
  if (control == 0 || key == 0)
    return false;

  char keymap[32]{};
  XQueryKeymap(display, keymap);
  const KeySym modifier_symbols[] = {
      XK_Shift_L, XK_Shift_R, XK_Control_L, XK_Control_R,        XK_Alt_L,
      XK_Alt_R,   XK_Super_L, XK_Super_R,   XK_ISO_Level3_Shift,
  };
  std::set<KeyCode> pressed_modifiers;
  for (const KeySym symbol : modifier_symbols) {
    const KeyCode modifier = XKeysymToKeycode(display, symbol);
    if (IsKeyPressed(keymap, modifier))
      pressed_modifiers.insert(modifier);
  }

  bool success = true;
  for (const KeyCode modifier : pressed_modifiers) {
    success = XTestFakeKeyEvent(display, modifier, False, CurrentTime) != 0 &&
              success;
  }
  success =
      XTestFakeKeyEvent(display, control, True, CurrentTime) != 0 && success;
  success = XTestFakeKeyEvent(display, key, True, CurrentTime) != 0 && success;
  success = XTestFakeKeyEvent(display, key, False, CurrentTime) != 0 && success;
  success =
      XTestFakeKeyEvent(display, control, False, CurrentTime) != 0 && success;
  for (const KeyCode modifier : pressed_modifiers) {
    success =
        XTestFakeKeyEvent(display, modifier, True, CurrentTime) != 0 && success;
  }
  XFlush(display);
  return success;
}
#else
bool IsX11() { return false; }
#endif

void SetBool(FlValue *map, const char *key, bool value) {
  fl_value_set_string_take(map, key, fl_value_new_bool(value));
}

FlValue *BuildCapabilities(LinuxNativeBridgePlugin *self) {
  const bool x11 = IsX11();
#ifdef GDK_WINDOWING_X11
  Display *display = x11 ? GetDisplay() : nullptr;
  const bool x_test = display != nullptr && HasXTest(display);
  const bool xfixes = display != nullptr && HasXFixes(display);
  const bool xres_pid = display != nullptr && HasXResPid(display);
  const bool native_clipboard = x11 && self->clipboard_reader != nullptr &&
                                self->clipboard_reader->active();
#else
  const bool x_test = false;
  const bool xfixes = false;
  const bool xres_pid = false;
  const bool native_clipboard = false;
#endif
  FlValue *result = fl_value_new_map();
  fl_value_set_string_take(
      result, "displayServer",
      fl_value_new_string(x11 ? "x11"
                              : (g_getenv("WAYLAND_DISPLAY") != nullptr
                                     ? "wayland"
                                     : "unknown")));
  SetBool(result, "targetWindows", x11 && xres_pid);
  SetBool(result, "inputInjection", x11 && x_test);
  SetBool(result, "xfixes", x11 && xfixes);
  SetBool(result, "xresPid", x11 && xres_pid);
  SetBool(result, "clipboardRevision", native_clipboard && xfixes);
  SetBool(result, "clipboardOwnership", x11 && xres_pid);
  SetBool(result, "losslessTextClipboardSnapshot", native_clipboard);
  SetBool(result, "stableClipboardReads",
          native_clipboard && x_test && xres_pid);
  SetBool(result, "nativeClipboardSnapshots", native_clipboard);
  SetBool(result, "atomicClipboardTransactions", native_clipboard);
  return result;
}

void HandleMethodCall(LinuxNativeBridgePlugin *self,
                      FlMethodCall *method_call) {
  const gchar *method = fl_method_call_get_name(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;

  if (std::strcmp(method, "getCapabilities") == 0) {
    g_autoptr(FlValue) result = BuildCapabilities(self);
    response = SuccessResponse(result);
  } else if (std::strcmp(method, "setApplicationWindowCanActivate") == 0) {
    FlValue *arguments = fl_method_call_get_args(method_call);
    if (arguments == nullptr ||
        fl_value_get_type(arguments) != FL_VALUE_TYPE_BOOL) {
      response = Error("linux_window_activation_argument_invalid",
                       "A boolean activation value is required.");
    } else if (!SetApplicationWindowCanActivate(
                   self, fl_value_get_bool(arguments))) {
      response = Error("linux_application_window_unavailable",
                       "The GTK application window is unavailable.");
    } else {
      response = SuccessResponse();
    }
  } else if (std::strcmp(method, "showApplicationWindowInactive") == 0) {
    if (!ShowApplicationWindowInactive(self)) {
      response = Error("linux_application_window_unavailable",
                       "The GTK application window is unavailable.");
    } else {
      response = SuccessResponse();
    }
  } else if (std::strcmp(method, "getClipboardRevision") == 0) {
#ifdef GDK_WINDOWING_X11
    if (self->clipboard_reader != nullptr) {
      self->clipboard_reader->Drain();
    }
#endif
    gint64 revision = 1;
#ifdef GDK_WINDOWING_X11
    if (self->clipboard_reader != nullptr) {
      revision = self->clipboard_reader->revision();
    }
#endif
    g_autoptr(FlValue) result = fl_value_new_int(revision);
    response = SuccessResponse(result);
#ifdef GDK_WINDOWING_X11
  } else if (std::strcmp(method, "writeClipboardTextIfRevision") == 0) {
    FlValue *arguments = fl_method_call_get_args(method_call);
    gint64 expected_revision = 0;
    std::string text;
    std::string rollback_text;
    if (!ReadPositiveMapInt(arguments, "expectedRevision",
                            &expected_revision) ||
        !ReadMapUtf8Bytes(arguments, "text", kMaxClipboardSnapshotBytes,
                          &text) ||
        !ReadMapUtf8Bytes(arguments, "rollbackText", kMaxClipboardSnapshotBytes,
                          &rollback_text)) {
      response = Error("linux_clipboard_mutation_arguments_invalid",
                       "Clipboard mutation arguments are invalid.");
    } else if (self->clipboard_reader == nullptr ||
               !self->clipboard_reader->active()) {
      response = ClipboardError("linux_clipboard_unavailable",
                                "The X11 clipboard is unavailable.", true);
    } else {
      response = CompleteClipboardMutation(
          self, expected_revision, kMaxClipboardTransferMilliseconds, text,
          rollback_text,
          [self, &text](std::int64_t revision, Window owner, Time timestamp) {
            return self->clipboard_reader->AcquireTextIfState(revision, owner,
                                                              timestamp, text);
          });
    }
  } else if (std::strcmp(method, "restoreNativeClipboardSnapshotIfRevision") ==
             0) {
    FlValue *arguments = fl_method_call_get_args(method_call);
    gint64 expected_revision = 0;
    gint64 snapshot_id = 0;
    std::string rollback_text;
    if (!ReadPositiveMapInt(arguments, "expectedRevision",
                            &expected_revision) ||
        !ReadPositiveMapInt(arguments, "snapshotId", &snapshot_id) ||
        !ReadMapUtf8Bytes(arguments, "rollbackText", kMaxClipboardSnapshotBytes,
                          &rollback_text)) {
      response = Error("linux_clipboard_restore_arguments_invalid",
                       "Clipboard restore arguments are invalid.");
    } else if (self->clipboard_reader == nullptr ||
               !self->clipboard_reader->active()) {
      response = ClipboardError("linux_clipboard_unavailable",
                                "The X11 clipboard is unavailable.", true);
    } else {
      const auto snapshot = self->clipboard_snapshots->find(snapshot_id);
      if (snapshot == self->clipboard_snapshots->end()) {
        response =
            ClipboardError("linux_clipboard_snapshot_not_found",
                           "The clipboard snapshot was released.", false);
      } else {
        response = CompleteClipboardMutation(
            self, expected_revision, kMaxClipboardTransferMilliseconds,
            rollback_text, rollback_text,
            [self, &snapshot](std::int64_t revision, Window owner,
                              Time timestamp) {
              return self->clipboard_reader->AcquireSnapshotIfState(
                  revision, owner, timestamp, snapshot->second);
            });
      }
    }
  } else if (std::strcmp(method, "captureNativeClipboardSnapshot") == 0) {
    gint64 max_bytes = 0;
    gint64 max_targets = 0;
    gint64 timeout_milliseconds = 0;
    if (!ReadClipboardBounds(method_call, &max_bytes, &max_targets,
                             &timeout_milliseconds)) {
      response = Error("linux_clipboard_bounds_invalid",
                       "Clipboard snapshot bounds are invalid.");
    } else if (self->clipboard_reader == nullptr ||
               !self->clipboard_reader->active()) {
      response = ClipboardError("linux_clipboard_unavailable",
                                "The X11 clipboard is unavailable.", true);
    } else if (self->clipboard_snapshots->size() >= kMaxRetainedSnapshots) {
      response =
          ClipboardError("linux_clipboard_snapshot_limit",
                         "Too many clipboard snapshots are retained.", false);
    } else {
      self->clipboard_reader->Drain();
      const gint64 revision = self->clipboard_reader->revision();
      const Window owner = self->clipboard_reader->observed_selection_owner();
      ykd::X11ClipboardSnapshot snapshot;
      const auto status = self->clipboard_reader->Capture(
          static_cast<std::size_t>(max_bytes),
          static_cast<std::size_t>(max_targets),
          std::chrono::milliseconds(timeout_milliseconds), &snapshot);
      self->clipboard_reader->Drain();
      if (status != ykd::X11ClipboardReadStatus::kOk) {
        response = ClipboardReadFailure(status);
      } else if (!self->clipboard_reader->active()) {
        response = ClipboardError("linux_clipboard_unavailable",
                                  "The X11 clipboard is unavailable.", true);
      } else if (self->clipboard_reader->revision() != revision ||
                 self->clipboard_reader->observed_selection_owner() != owner ||
                 snapshot.owner != owner) {
        response = ClipboardError(
            "linux_clipboard_owner_changed",
            "The clipboard owner changed during snapshot capture.", true);
      } else {
        const gint64 snapshot_id = self->next_clipboard_snapshot_id++;
        self->clipboard_snapshots->emplace(snapshot_id, std::move(snapshot));
        g_autoptr(FlValue) result = fl_value_new_map();
        fl_value_set_string_take(result, "revision",
                                 fl_value_new_int(revision));
        fl_value_set_string_take(result, "snapshotId",
                                 fl_value_new_int(snapshot_id));
        response = SuccessResponse(result);
      }
    }
  } else if (std::strcmp(method, "releaseNativeClipboardSnapshot") == 0) {
    FlValue *arguments = fl_method_call_get_args(method_call);
    if (arguments == nullptr ||
        fl_value_get_type(arguments) != FL_VALUE_TYPE_INT ||
        fl_value_get_int(arguments) <= 0) {
      response = Error("linux_clipboard_snapshot_id_invalid",
                       "A positive clipboard snapshot ID is required.");
    } else {
      self->clipboard_snapshots->erase(fl_value_get_int(arguments));
      response = SuccessResponse();
    }
  } else if (std::strcmp(method, "copySelectionTextWithEvidence") == 0) {
    gint64 handle = 0;
    gint64 max_bytes = 0;
    gint64 max_targets = 0;
    gint64 timeout_milliseconds = 0;
    if (!ReadStableCopyArguments(method_call, &handle, &max_bytes, &max_targets,
                                 &timeout_milliseconds)) {
      response = Error("linux_clipboard_copy_arguments_invalid",
                       "Stable copy arguments are invalid.");
    } else if (self->clipboard_reader == nullptr ||
               !self->clipboard_reader->active()) {
      response = ClipboardError("linux_clipboard_unavailable",
                                "The X11 clipboard is unavailable.", true);
    } else {
      Display *display = GetDisplay();
      const Window target = static_cast<Window>(handle);
      const gint64 target_pid = ReadClientProcessId(display, target);
      const gint64 deadline =
          g_get_monotonic_time() + timeout_milliseconds * 1000;
      bool focused = RequestActivation(display, target);
      while (focused && GetActiveWindow(display) != target &&
             g_get_monotonic_time() < deadline) {
        g_usleep(5000);
      }
      focused = focused && GetActiveWindow(display) == target;
      self->clipboard_reader->Drain();
      const gint64 baseline_revision = self->clipboard_reader->revision();
      if (!focused || target_pid == 0 ||
          !InjectControlChord(display, target, XK_c)) {
        response = ClipboardError("linux_x11_input_injection_failed",
                                  "The X11 copy chord was rejected.", false);
      } else {
        bool revision_changed = false;
        while (g_get_monotonic_time() < deadline) {
          self->clipboard_reader->Drain();
          if (self->clipboard_reader->revision() != baseline_revision) {
            revision_changed = true;
            break;
          }
          g_usleep(5000);
        }
        if (!revision_changed) {
          response =
              ClipboardError("linux_clipboard_copy_timeout",
                             "Copy did not produce a fresh clipboard.", true);
        } else {
          const gint64 revision = self->clipboard_reader->revision();
          const Window owner =
              self->clipboard_reader->observed_selection_owner();
          const gint64 owner_pid = ReadClientProcessId(display, owner);
          if (owner == None || owner_pid == 0 || owner_pid != target_pid) {
            response = ClipboardError(
                "linux_clipboard_owner_mismatch",
                "The copied text cannot be attributed to the target.", false);
          } else {
            const gint64 remaining_microseconds =
                deadline - g_get_monotonic_time();
            if (remaining_microseconds <= 0) {
              response = ClipboardError("linux_clipboard_copy_timeout",
                                        "Copy did not complete in time.", true);
            } else {
              ykd::X11ClipboardText text;
              const auto status = self->clipboard_reader->ReadUtf8(
                  static_cast<std::size_t>(max_bytes),
                  static_cast<std::size_t>(max_targets),
                  std::chrono::milliseconds(
                      std::max<gint64>(1, remaining_microseconds / 1000)),
                  &text);
              self->clipboard_reader->Drain();
              if (status != ykd::X11ClipboardReadStatus::kOk) {
                response = ClipboardReadFailure(status);
              } else if (!self->clipboard_reader->active()) {
                response =
                    ClipboardError("linux_clipboard_unavailable",
                                   "The X11 clipboard is unavailable.", true);
              } else if (self->clipboard_reader->revision() != revision ||
                         self->clipboard_reader->observed_selection_owner() !=
                             owner ||
                         text.owner != owner) {
                response = ClipboardError(
                    "linux_clipboard_owner_changed",
                    "The clipboard changed while copied text was read.", true);
              } else if (!g_utf8_validate(text.text.data(), text.text.size(),
                                          nullptr)) {
                response = ClipboardError("linux_clipboard_text_invalid_utf8",
                                          "The copied text is not valid UTF-8.",
                                          false);
              } else {
                g_autoptr(FlValue) result = fl_value_new_map();
                fl_value_set_string_take(
                    result, "text",
                    fl_value_new_string_sized(text.text.data(),
                                              text.text.size()));
                fl_value_set_string_take(result, "revision",
                                         fl_value_new_int(revision));
                fl_value_set_string_take(
                    result, "ownerWindow",
                    fl_value_new_int(static_cast<gint64>(owner)));
                fl_value_set_string_take(result, "ownerProcessId",
                                         fl_value_new_int(owner_pid));
                response = SuccessResponse(result);
              }
            }
          }
        }
      }
    }
  } else if (IsX11()) {
    Display *display = GetDisplay();
    if (display == nullptr) {
      response = Error("linux_x11_display_unavailable",
                       "The X11 display is unavailable.");
    } else if (std::strcmp(method, "getForegroundWindow") == 0) {
      g_autoptr(FlValue) result =
          fl_value_new_int(static_cast<gint64>(GetActiveWindow(display)));
      response = SuccessResponse(result);
    } else if (std::strcmp(method, "getFlutterWindowHandle") == 0) {
      GtkWindow *application_window = GetApplicationWindow(self);
      GdkWindow *window =
          application_window == nullptr
              ? nullptr
              : gtk_widget_get_window(GTK_WIDGET(application_window));
      const gint64 handle =
          window == nullptr
              ? 0
              : static_cast<gint64>(gdk_x11_window_get_xid(window));
      if (application_window != nullptr) {
        g_object_unref(application_window);
      }
      g_autoptr(FlValue) result = fl_value_new_int(handle);
      response = SuccessResponse(result);
    } else {
      gint64 handle = 0;
      if (!ReadWindowArgument(method_call, &handle)) {
        response = Error("linux_invalid_window_handle",
                         "A positive X11 window handle is required.");
      } else if (std::strcmp(method, "getWindowProcessId") == 0) {
        g_autoptr(FlValue) result = fl_value_new_int(
            ReadClientProcessId(display, static_cast<Window>(handle)));
        response = SuccessResponse(result);
      } else if (std::strcmp(method, "isWindowValid") == 0) {
        g_autoptr(FlValue) result = fl_value_new_bool(
            IsWindowValid(display, static_cast<Window>(handle)));
        response = SuccessResponse(result);
      } else if (std::strcmp(method, "focusWindow") == 0) {
        g_autoptr(FlValue) result = fl_value_new_bool(
            RequestActivation(display, static_cast<Window>(handle)));
        response = SuccessResponse(result);
      } else if (std::strcmp(method, "isClipboardOwnedByTarget") == 0) {
        const Atom clipboard_atom = XInternAtom(display, "CLIPBOARD", False);
        const Window owner = XGetSelectionOwner(display, clipboard_atom);
        const gint64 owner_pid = ReadClientProcessId(display, owner);
        const gint64 target_pid =
            ReadClientProcessId(display, static_cast<Window>(handle));
        g_autoptr(FlValue) result =
            fl_value_new_bool(owner_pid != 0 && owner_pid == target_pid);
        response = SuccessResponse(result);
      } else if (std::strcmp(method, "injectCopy") == 0 ||
                 std::strcmp(method, "injectPaste") == 0) {
        const KeySym key_symbol =
            std::strcmp(method, "injectCopy") == 0 ? XK_c : XK_v;
        if (!InjectControlChord(display, static_cast<Window>(handle),
                                key_symbol)) {
          response = Error("linux_x11_input_injection_failed",
                           "The X11 copy/paste chord was rejected.");
        } else {
          response = SuccessResponse();
        }
      } else {
        response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
      }
    }
#endif
  } else {
    response =
        Error("linux_wayland_portal_required",
              "This operation requires an approved Wayland portal session.");
  }

  fl_method_call_respond(method_call, response, nullptr);
}

void MethodCallCallback(FlMethodChannel *, FlMethodCall *method_call,
                        gpointer user_data) {
  HandleMethodCall(LINUX_NATIVE_BRIDGE_PLUGIN(user_data), method_call);
}

void linux_native_bridge_plugin_dispose(GObject *object) {
  auto *self = LINUX_NATIVE_BRIDGE_PLUGIN(object);
#ifdef GDK_WINDOWING_X11
  delete self->clipboard_reader;
  self->clipboard_reader = nullptr;
  delete self->clipboard_snapshots;
  self->clipboard_snapshots = nullptr;
#endif
  g_clear_object(&self->registrar);
  G_OBJECT_CLASS(linux_native_bridge_plugin_parent_class)->dispose(object);
}

void linux_native_bridge_plugin_finalize(GObject *object) {
  auto *self = LINUX_NATIVE_BRIDGE_PLUGIN(object);
  g_weak_ref_clear(&self->application_window);
  G_OBJECT_CLASS(linux_native_bridge_plugin_parent_class)->finalize(object);
}

void linux_native_bridge_plugin_class_init(
    LinuxNativeBridgePluginClass *klass) {
  G_OBJECT_CLASS(klass)->dispose = linux_native_bridge_plugin_dispose;
  G_OBJECT_CLASS(klass)->finalize = linux_native_bridge_plugin_finalize;
}

void linux_native_bridge_plugin_init(LinuxNativeBridgePlugin *self) {
  g_weak_ref_init(&self->application_window, nullptr);
#ifdef GDK_WINDOWING_X11
  self->clipboard_reader = new ykd::X11ClipboardReader();
  self->clipboard_snapshots = new std::map<gint64, ykd::X11ClipboardSnapshot>();
  self->next_clipboard_snapshot_id = 1;
#endif
}

}

void linux_native_bridge_plugin_register_with_registrar(
    FlPluginRegistrar *registrar, GtkWindow *application_window) {
#ifdef GDK_WINDOWING_X11
  ykd::InstallX11ErrorDispatcher();
#endif
  auto *plugin = LINUX_NATIVE_BRIDGE_PLUGIN(
      g_object_new(linux_native_bridge_plugin_get_type(), nullptr));
  plugin->registrar = FL_PLUGIN_REGISTRAR(g_object_ref(registrar));
  g_weak_ref_set(&plugin->application_window, G_OBJECT(application_window));
#ifdef GDK_WINDOWING_X11
  Display *display = GetDisplay();
  if (display != nullptr) {
    plugin->clipboard_reader->Start(DisplayString(display));
  }
#endif

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                            kChannelName, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      channel, MethodCallCallback, g_object_ref(plugin), g_object_unref);
  g_object_unref(plugin);
}

#ifdef YKD_ENABLE_TEST_HOOKS
GObject *linux_native_bridge_plugin_new_for_test() {
  return G_OBJECT(g_object_new(linux_native_bridge_plugin_get_type(), nullptr));
}

void linux_native_bridge_plugin_start_for_test(GObject *object,
                                               GtkWindow *application_window) {
  auto *plugin = LINUX_NATIVE_BRIDGE_PLUGIN(object);
  g_weak_ref_set(&plugin->application_window, G_OBJECT(application_window));
#ifdef GDK_WINDOWING_X11
  ykd::InstallX11ErrorDispatcher();
  Display *display = GetDisplay();
  if (display != nullptr) {
    plugin->clipboard_reader->Start(DisplayString(display));
  }
#endif
}

gint64 linux_native_bridge_plugin_clipboard_revision_for_test(GObject *object) {
#ifdef GDK_WINDOWING_X11
  auto *plugin = LINUX_NATIVE_BRIDGE_PLUGIN(object);
  if (plugin->clipboard_reader == nullptr ||
      !plugin->clipboard_reader->active()) {
    return 0;
  }
  plugin->clipboard_reader->Drain();
  return plugin->clipboard_reader->revision();
#else
  return 0;
#endif
}

FlMethodResponse *linux_native_bridge_plugin_write_clipboard_text_for_test(
    GObject *object, gint64 expected_revision, gint64 timeout_milliseconds,
    const gchar *text, const gchar *rollback_text) {
#ifdef GDK_WINDOWING_X11
  auto *plugin = LINUX_NATIVE_BRIDGE_PLUGIN(object);
  if (plugin->clipboard_reader == nullptr ||
      !plugin->clipboard_reader->active() || text == nullptr ||
      rollback_text == nullptr || expected_revision <= 0 ||
      timeout_milliseconds <= 0) {
    return ClipboardError("linux_clipboard_unavailable",
                          "The X11 clipboard is unavailable.", true);
  }
  const std::string value(text);
  return CompleteClipboardMutation(
      plugin, expected_revision, timeout_milliseconds, value, rollback_text,
      [plugin, &value](std::int64_t revision, Window owner, Time timestamp) {
        return plugin->clipboard_reader->AcquireTextIfState(revision, owner,
                                                            timestamp, value);
      });
#else
  return ClipboardError("linux_clipboard_unavailable",
                        "The X11 clipboard is unavailable.", true);
#endif
}

FlValue *linux_native_bridge_plugin_capabilities_for_test(GObject *object) {
  return BuildCapabilities(LINUX_NATIVE_BRIDGE_PLUGIN(object));
}

gboolean linux_native_bridge_plugin_set_window_can_activate_for_test(
    GObject *object, gboolean can_activate) {
  return SetApplicationWindowCanActivate(LINUX_NATIVE_BRIDGE_PLUGIN(object),
                                         can_activate);
}

gboolean linux_native_bridge_plugin_show_window_inactive_for_test(
    GObject *object) {
  return ShowApplicationWindowInactive(LINUX_NATIVE_BRIDGE_PLUGIN(object));
}
#endif
