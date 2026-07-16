#ifndef FLUTTER_LINUX_NATIVE_BRIDGE_PLUGIN_H_
#define FLUTTER_LINUX_NATIVE_BRIDGE_PLUGIN_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

void linux_native_bridge_plugin_register_with_registrar(
    FlPluginRegistrar *registrar, GtkWindow *application_window);

#ifdef YKD_ENABLE_TEST_HOOKS
GObject *linux_native_bridge_plugin_new_for_test();
void linux_native_bridge_plugin_start_for_test(GObject *plugin,
                                               GtkWindow *application_window);
gint64 linux_native_bridge_plugin_clipboard_revision_for_test(GObject *plugin);
FlMethodResponse *linux_native_bridge_plugin_write_clipboard_text_for_test(
    GObject *plugin, gint64 expected_revision, gint64 timeout_milliseconds,
    const gchar *text, const gchar *rollback_text);
FlValue *linux_native_bridge_plugin_capabilities_for_test(GObject *plugin);
gboolean linux_native_bridge_plugin_set_window_can_activate_for_test(
    GObject *plugin, gboolean can_activate);
gboolean linux_native_bridge_plugin_show_window_inactive_for_test(
    GObject *plugin);
#endif

#endif
