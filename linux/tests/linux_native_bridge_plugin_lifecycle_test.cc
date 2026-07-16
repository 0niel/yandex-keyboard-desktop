#include "linux_native_bridge_plugin.h"

#include <X11/Xatom.h>
#include <X11/Xutil.h>
#include <fontconfig/fontconfig.h>
#include <gdk/gdkx.h>

#include <cstdlib>
#include <cstring>
#include <iostream>

namespace {

[[noreturn]] void Fail(const char *message) {
  std::cerr << message << '\n';
  std::exit(EXIT_FAILURE);
}

Time GetServerTime(Display *display, Window window) {
  const Atom probe = XInternAtom(display, "_YKD_PLUGIN_TEST_TIMESTAMP", False);
  const unsigned char marker = 1;
  XSelectInput(display, window, PropertyChangeMask);
  XChangeProperty(display, window, probe, XA_INTEGER, 8, PropModeReplace,
                  &marker, 1);
  XEvent event{};
  XWindowEvent(display, window, PropertyChangeMask, &event);
  return event.xproperty.time;
}

bool WaitForRevision(GObject *plugin, gint64 revision) {
  for (int attempt = 0; attempt < 1000; ++attempt) {
    while (g_main_context_iteration(nullptr, false) != 0) {
    }
    if (linux_native_bridge_plugin_clipboard_revision_for_test(plugin) ==
        revision) {
      return true;
    }
    g_usleep(1000);
  }
  return false;
}

Window ReadActiveWindow(Display *display) {
  const Atom property = XInternAtom(display, "_NET_ACTIVE_WINDOW", False);
  Atom actual_type = None;
  int actual_format = 0;
  unsigned long item_count = 0;
  unsigned long bytes_after = 0;
  unsigned char *value = nullptr;
  const int status = XGetWindowProperty(
      display, DefaultRootWindow(display), property, 0, 1, False, XA_WINDOW,
      &actual_type, &actual_format, &item_count, &bytes_after, &value);
  Window active = None;
  if (status == Success && actual_type == XA_WINDOW && actual_format == 32 &&
      item_count == 1 && value != nullptr) {
    active = *reinterpret_cast<Window *>(value);
  }
  if (value != nullptr)
    XFree(value);
  return active;
}

bool WaitForActiveWindow(Display *display, Window expected) {
  for (int attempt = 0; attempt < 5000; ++attempt) {
    while (g_main_context_iteration(nullptr, false) != 0) {
    }
    XSync(display, False);
    if (ReadActiveWindow(display) == expected)
      return true;
    g_usleep(1000);
  }
  return false;
}

bool ActiveWindowStays(Display *display, Window expected,
                       gint64 dwell_milliseconds = 350) {
  const gint64 deadline = g_get_monotonic_time() +
                          dwell_milliseconds * G_TIME_SPAN_MILLISECOND;
  bool observed_after_map = false;
  while (g_get_monotonic_time() < deadline) {
    while (g_main_context_iteration(nullptr, false) != 0) {
    }
    XSync(display, False);
    observed_after_map = true;
    if (ReadActiveWindow(display) != expected)
      return false;
    g_usleep(1000);
  }
  return observed_after_map;
}

void VerifyWindowManagerFocusRetention(GObject *plugin, GtkWidget *overlay,
                                       Display *display,
                                       Window overlay_xid) {
  const bool require_window_manager =
      g_strcmp0(g_getenv("YKD_REQUIRE_WINDOW_MANAGER"), "1") == 0;
  GtkWidget *target = nullptr;
  Window target_xid = None;
  if (require_window_manager) {
    target = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    g_object_ref_sink(target);
    gtk_window_set_title(GTK_WINDOW(target), "YKD focus target");
    gtk_window_set_default_size(GTK_WINDOW(target), 320, 160);
    gtk_widget_show(target);
    gtk_window_present(GTK_WINDOW(target));
    target_xid = gdk_x11_window_get_xid(gtk_widget_get_window(target));
    if (!WaitForActiveWindow(display, target_xid))
      Fail("window manager did not activate the focus target");
  }

  if (!linux_native_bridge_plugin_show_window_inactive_for_test(plugin) ||
      !gtk_widget_get_mapped(overlay) ||
      (require_window_manager &&
       !ActiveWindowStays(display, target_xid))) {
    Fail("first overlay map did not preserve the window-manager foreground");
  }
  if (!gtk_widget_get_visible(overlay) ||
      gtk_window_get_accept_focus(GTK_WINDOW(overlay)) ||
      gtk_window_get_focus_on_map(GTK_WINDOW(overlay))) {
    Fail("inactive first map changed its focus contract");
  }
  XWMHints *wm_hints = XGetWMHints(display, overlay_xid);
  if (wm_hints == nullptr || (wm_hints->flags & InputHint) == 0 ||
      wm_hints->input != False) {
    if (wm_hints != nullptr)
      XFree(wm_hints);
    Fail("overlay X11 WM_HINTS still accept input focus");
  }
  XFree(wm_hints);

  if (!linux_native_bridge_plugin_set_window_can_activate_for_test(plugin,
                                                                   TRUE)) {
    Fail("settings activation could not be restored");
  }
  gtk_window_present(GTK_WINDOW(overlay));
  if (require_window_manager &&
      !WaitForActiveWindow(display, overlay_xid))
    Fail("restored settings window could not become active");

  if (target != nullptr) {
    gtk_widget_destroy(target);
    g_object_unref(target);
  }
  while (g_main_context_iteration(nullptr, false) != 0) {
  }
}

gint64 RequireCommittedRevision(FlMethodResponse *response) {
  if (!FL_IS_METHOD_SUCCESS_RESPONSE(response)) {
    Fail("clipboard mutation did not return success");
  }
  FlValue *result = fl_method_success_response_get_result(
      FL_METHOD_SUCCESS_RESPONSE(response));
  if (result == nullptr || fl_value_get_type(result) != FL_VALUE_TYPE_INT) {
    Fail("clipboard mutation did not return a committed revision");
  }
  return fl_value_get_int(result);
}

bool ReadCapability(FlValue *capabilities, const char *key) {
  FlValue *value = fl_value_lookup_string(capabilities, key);
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_BOOL) {
    Fail("native capability map is malformed");
  }
  return fl_value_get_bool(value);
}

void VerifyMutationMethodBranches(GtkWindow *window) {
  GObject *plugin = linux_native_bridge_plugin_new_for_test();
  linux_native_bridge_plugin_start_for_test(plugin, window);
  g_autoptr(FlValue) capabilities =
      linux_native_bridge_plugin_capabilities_for_test(plugin);
  const char *required_capabilities[] = {
      "clipboardRevision", "losslessTextClipboardSnapshot",
      "nativeClipboardSnapshots", "atomicClipboardTransactions"};
  for (const char *capability : required_capabilities) {
    if (!ReadCapability(capabilities, capability)) {
      std::cerr << "Missing X11 capability: " << capability << '\n';
      Fail("complete X11 clipboard capability was not advertised");
    }
  }
  const bool expected_stable_read =
      ReadCapability(capabilities, "inputInjection") &&
      ReadCapability(capabilities, "xresPid");
  if (ReadCapability(capabilities, "stableClipboardReads") !=
      expected_stable_read) {
    Fail("stable read capability ignored XTest/XRes evidence");
  }
  Display *display = gdk_x11_display_get_xdisplay(gdk_display_get_default());
  const Atom clipboard = XInternAtom(display, "CLIPBOARD", False);
  const Window first_owner = XCreateSimpleWindow(
      display, DefaultRootWindow(display), 0, 0, 1, 1, 0, 0, 0);
  const Window takeover_owner = XCreateSimpleWindow(
      display, DefaultRootWindow(display), 0, 0, 1, 1, 0, 0, 0);

  const gint64 baseline =
      linux_native_bridge_plugin_clipboard_revision_for_test(plugin);
  XSetSelectionOwner(display, clipboard, first_owner,
                     GetServerTime(display, first_owner));
  XSync(display, False);
  if (!WaitForRevision(plugin, baseline + 1)) {
    Fail("plugin did not observe initial clipboard owner");
  }

  g_autoptr(FlMethodResponse) committed =
      linux_native_bridge_plugin_write_clipboard_text_for_test(
          plugin, baseline + 1, 1000, "replacement", "original");
  const gint64 committed_revision = RequireCommittedRevision(committed);
  if (committed_revision != baseline + 2 ||
      XGetSelectionOwner(display, clipboard) == first_owner) {
    Fail("plugin write method did not commit the exact next revision");
  }

  XSetSelectionOwner(display, clipboard, takeover_owner,
                     GetServerTime(display, takeover_owner));
  XSync(display, False);
  if (!WaitForRevision(plugin, committed_revision + 1)) {
    Fail("plugin did not observe external takeover");
  }
  g_autoptr(FlMethodResponse) conflict =
      linux_native_bridge_plugin_write_clipboard_text_for_test(
          plugin, committed_revision, 1000, "must-not-win", "replacement");
  if (!FL_IS_METHOD_SUCCESS_RESPONSE(conflict) ||
      fl_method_success_response_get_result(
          FL_METHOD_SUCCESS_RESPONSE(conflict)) != nullptr ||
      XGetSelectionOwner(display, clipboard) != takeover_owner) {
    Fail("stale plugin write did not preserve external clipboard owner");
  }

  XDestroyWindow(display, first_owner);
  XDestroyWindow(display, takeover_owner);
  XSync(display, False);
  g_object_unref(plugin);
}

}

int main(int argc, char **argv) {
  if (!gtk_init_check(&argc, &argv))
    Fail("GTK initialization failed");
  GtkWidget *window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_widget_realize(window);

  GObject *activation_plugin = linux_native_bridge_plugin_new_for_test();
  linux_native_bridge_plugin_start_for_test(activation_plugin,
                                            GTK_WINDOW(window));
  if (!linux_native_bridge_plugin_set_window_can_activate_for_test(
          activation_plugin, FALSE) ||
      gtk_window_get_accept_focus(GTK_WINDOW(window)) ||
      gtk_window_get_focus_on_map(GTK_WINDOW(window))) {
    Fail("overlay window still accepts focus");
  }
  Display *display = gdk_x11_display_get_xdisplay(gdk_display_get_default());
  const Window overlay = gdk_x11_window_get_xid(
      gtk_widget_get_window(GTK_WIDGET(window)));
  VerifyWindowManagerFocusRetention(activation_plugin, window, display,
                                    overlay);
  if (!gtk_window_get_accept_focus(GTK_WINDOW(window)) ||
      !gtk_window_get_focus_on_map(GTK_WINDOW(window))) {
    Fail("settings window did not restore activation");
  }
  g_object_unref(activation_plugin);

  GtkWidget *destroyed_window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  g_object_ref_sink(destroyed_window);
  gtk_widget_realize(destroyed_window);
  GObject *destroyed_window_plugin =
      linux_native_bridge_plugin_new_for_test();
  linux_native_bridge_plugin_start_for_test(
      destroyed_window_plugin, GTK_WINDOW(destroyed_window));
  gtk_widget_destroy(destroyed_window);
  g_object_unref(destroyed_window);
  while (g_main_context_iteration(nullptr, false) != 0) {
  }
  if (linux_native_bridge_plugin_set_window_can_activate_for_test(
          destroyed_window_plugin, FALSE) ||
      linux_native_bridge_plugin_show_window_inactive_for_test(
          destroyed_window_plugin)) {
    Fail("destroyed application window remained reachable");
  }
  g_object_unref(destroyed_window_plugin);

  VerifyMutationMethodBranches(GTK_WINDOW(window));

  for (int iteration = 0; iteration < 32; ++iteration) {
    GObject *plugin = linux_native_bridge_plugin_new_for_test();
    if (plugin == nullptr)
      Fail("plugin construction failed");
    linux_native_bridge_plugin_start_for_test(plugin, GTK_WINDOW(window));
    while (g_main_context_iteration(nullptr, false) != 0) {
    }
    g_object_unref(plugin);
  }

  gtk_widget_destroy(window);
  while (g_main_context_iteration(nullptr, false) != 0) {
  }
  FcFini();
  return EXIT_SUCCESS;
}
