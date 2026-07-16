#ifndef YKD_WAYLAND_GLOBAL_SHORTCUTS_PLUGIN_H_
#define YKD_WAYLAND_GLOBAL_SHORTCUTS_PLUGIN_H_

#include <flutter_linux/flutter_linux.h>

void wayland_global_shortcuts_plugin_register_with_registrar(
    FlPluginRegistrar *registrar);

#ifdef YKD_ENABLE_TEST_HOOKS
FlValue *
wayland_global_shortcuts_plugin_capability_value_for_test(gboolean available,
                                                          guint32 version);
FlValue *wayland_global_shortcuts_plugin_bind_value_for_test();
FlValue *
wayland_global_shortcuts_plugin_event_value_for_test(const gchar *type);
gboolean
wayland_global_shortcuts_plugin_read_definitions_for_test(FlValue *arguments);
GObject *wayland_global_shortcuts_plugin_new_for_test();
GObject *
wayland_global_shortcuts_plugin_register_for_test(FlBinaryMessenger *messenger);
void wayland_global_shortcuts_plugin_emit_event_for_test(GObject *plugin,
                                                         const gchar *type);
const gchar *wayland_global_shortcuts_plugin_method_channel_for_test();
const gchar *wayland_global_shortcuts_plugin_event_channel_for_test();
gint wayland_global_shortcuts_plugin_method_kind_for_test(const gchar *method);
gboolean
wayland_global_shortcuts_plugin_set_listening_for_test(GObject *plugin,
                                                       gboolean listening);
gboolean wayland_global_shortcuts_plugin_is_disposed_for_test(GObject *plugin);
void wayland_global_shortcuts_plugin_dispose_for_test(GObject *plugin);
#endif

#endif
