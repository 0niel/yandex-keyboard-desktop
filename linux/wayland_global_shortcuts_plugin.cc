#include "wayland_global_shortcuts_plugin.h"

#include "wayland_global_shortcuts_portal.h"

#include <limits>
#include <string>
#include <utility>
#include <vector>

#define WAYLAND_GLOBAL_SHORTCUTS_PLUGIN(obj)                                   \
  (G_TYPE_CHECK_INSTANCE_CAST((obj),                                           \
                              wayland_global_shortcuts_plugin_get_type(),      \
                              WaylandGlobalShortcutsPlugin))

namespace {

constexpr char kMethodChannelName[] =
    "io.github.oniel.yandex_keyboard_desktop/global_shortcuts";
constexpr char kEventChannelName[] =
    "io.github.oniel.yandex_keyboard_desktop/global_shortcuts_events";

enum class MethodKind {
  kGetCapability,
  kCreateCandidate,
  kBindCandidate,
  kCommitCandidate,
  kDiscardCandidate,
  kCancelRequest,
  kCloseSessions,
  kConfigure,
  kDispose,
  kUnknown,
};

MethodKind ClassifyMethod(const gchar *method) {
  if (g_strcmp0(method, "getGlobalShortcutsCapability") == 0)
    return MethodKind::kGetCapability;
  if (g_strcmp0(method, "createGlobalShortcutsCandidate") == 0)
    return MethodKind::kCreateCandidate;
  if (g_strcmp0(method, "bindGlobalShortcutsCandidate") == 0)
    return MethodKind::kBindCandidate;
  if (g_strcmp0(method, "commitGlobalShortcutsCandidate") == 0)
    return MethodKind::kCommitCandidate;
  if (g_strcmp0(method, "discardGlobalShortcutsCandidate") == 0)
    return MethodKind::kDiscardCandidate;
  if (g_strcmp0(method, "cancelGlobalShortcutsRequest") == 0)
    return MethodKind::kCancelRequest;
  if (g_strcmp0(method, "closeGlobalShortcutsSessions") == 0)
    return MethodKind::kCloseSessions;
  if (g_strcmp0(method, "configureGlobalShortcuts") == 0)
    return MethodKind::kConfigure;
  if (g_strcmp0(method, "disposeGlobalShortcuts") == 0)
    return MethodKind::kDispose;
  return MethodKind::kUnknown;
}

typedef struct _WaylandGlobalShortcutsPlugin {
  GObject parent_instance;
  ykd::WaylandGlobalShortcutsPortal *portal;
  FlEventChannel *event_channel;
  gboolean listening;
  gboolean explicitly_disposed;
} WaylandGlobalShortcutsPlugin;

typedef struct _WaylandGlobalShortcutsPluginClass {
  GObjectClass parent_class;
} WaylandGlobalShortcutsPluginClass;

GType wayland_global_shortcuts_plugin_get_type();

G_DEFINE_TYPE(WaylandGlobalShortcutsPlugin, wayland_global_shortcuts_plugin,
              g_object_get_type())

void Respond(FlMethodCall *call, FlMethodResponse *response) {
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(call, response, &error)) {
    g_warning("Failed to respond on GlobalShortcuts channel: %s",
              error->message);
  }
}

void RespondSuccess(FlMethodCall *call, FlValue *value = nullptr) {
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_success_response_new(value));
  Respond(call, response);
}

void RespondError(FlMethodCall *call, const char *code, const char *message) {
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_error_response_new(code, message, nullptr));
  Respond(call, response);
}

bool ReadMapInt(FlValue *map, const char *key, gint64 *value) {
  if (map == nullptr || fl_value_get_type(map) != FL_VALUE_TYPE_MAP) {
    return false;
  }
  FlValue *field = fl_value_lookup_string(map, key);
  if (field == nullptr || fl_value_get_type(field) != FL_VALUE_TYPE_INT) {
    return false;
  }
  *value = fl_value_get_int(field);
  return true;
}

bool ReadMapString(FlValue *map, const char *key, std::string *value) {
  if (map == nullptr || fl_value_get_type(map) != FL_VALUE_TYPE_MAP) {
    return false;
  }
  FlValue *field = fl_value_lookup_string(map, key);
  if (field == nullptr || fl_value_get_type(field) != FL_VALUE_TYPE_STRING) {
    return false;
  }
  const gchar *text = fl_value_get_string(field);
  if (text == nullptr || *text == '\0' || !g_utf8_validate(text, -1, nullptr)) {
    return false;
  }
  *value = text;
  return true;
}

bool ReadCandidate(FlMethodCall *call,
                   ykd::GlobalShortcutsCandidate *candidate) {
  FlValue *arguments = fl_method_call_get_args(call);
  return ReadMapString(arguments, "id", &candidate->id) &&
         ReadMapInt(arguments, "generation", &candidate->generation) &&
         candidate->generation > 0;
}

bool ReadDefinitionsValue(FlValue *arguments, gint64 *generation,
                          std::vector<ykd::GlobalShortcutDefinition> *output) {
  if (!ReadMapInt(arguments, "generation", generation) || *generation < 1) {
    return false;
  }
  FlValue *shortcuts = fl_value_lookup_string(arguments, "shortcuts");
  if (shortcuts == nullptr ||
      fl_value_get_type(shortcuts) != FL_VALUE_TYPE_LIST ||
      fl_value_get_length(shortcuts) == 0) {
    return false;
  }
  std::vector<ykd::GlobalShortcutDefinition> definitions;
  for (size_t index = 0; index < fl_value_get_length(shortcuts); ++index) {
    FlValue *value = fl_value_get_list_value(shortcuts, index);
    ykd::GlobalShortcutDefinition definition;
    if (!ReadMapString(value, "id", &definition.id) ||
        !ReadMapString(value, "description", &definition.description) ||
        !ReadMapString(value, "preferredTrigger",
                       &definition.preferred_trigger)) {
      return false;
    }
    definitions.push_back(std::move(definition));
  }
  *output = std::move(definitions);
  return true;
}

bool ReadDefinitions(FlMethodCall *call, gint64 *generation,
                     std::vector<ykd::GlobalShortcutDefinition> *output) {
  return ReadDefinitionsValue(fl_method_call_get_args(call), generation,
                              output);
}

FlValue *CapabilityValue(const ykd::GlobalShortcutsCapability &capability) {
  FlValue *result = fl_value_new_map();
  fl_value_set_string_take(result, "available",
                           fl_value_new_bool(capability.available));
  fl_value_set_string_take(result, "version",
                           fl_value_new_int(capability.version));
  return result;
}

FlValue *CandidateValue(const ykd::GlobalShortcutsCandidate &candidate) {
  FlValue *result = fl_value_new_map();
  fl_value_set_string_take(result, "id",
                           fl_value_new_string(candidate.id.c_str()));
  fl_value_set_string_take(result, "generation",
                           fl_value_new_int(candidate.generation));
  return result;
}

FlValue *BindingValue(const ykd::GlobalShortcutBinding &binding) {
  FlValue *result = fl_value_new_map();
  fl_value_set_string_take(result, "id",
                           fl_value_new_string(binding.id.c_str()));
  fl_value_set_string_take(result, "description",
                           fl_value_new_string(binding.description.c_str()));
  if (binding.has_trigger_description) {
    fl_value_set_string_take(
        result, "triggerDescription",
        fl_value_new_string(binding.trigger_description.c_str()));
  }
  return result;
}

FlValue *BindResultValue(const ykd::GlobalShortcutsBindResult &bind_result) {
  FlValue *result = fl_value_new_map();
  const char *status = "failed";
  if (bind_result.status == ykd::GlobalShortcutsBindStatus::kSuccess) {
    status = "success";
  } else if (bind_result.status == ykd::GlobalShortcutsBindStatus::kCancelled) {
    status = "cancelled";
  }
  fl_value_set_string_take(result, "status", fl_value_new_string(status));
  FlValue *bindings = fl_value_new_list();
  for (const auto &binding : bind_result.bindings) {
    fl_value_append_take(bindings, BindingValue(binding));
  }
  fl_value_set_string_take(result, "bindings", bindings);
  if (!bind_result.diagnostic_code.empty()) {
    fl_value_set_string_take(
        result, "diagnosticCode",
        fl_value_new_string(bind_result.diagnostic_code.c_str()));
  }
  return result;
}

FlValue *EventValue(const ykd::GlobalShortcutsEvent &event) {
  FlValue *result = fl_value_new_map();
  const char *type = "availabilityChanged";
  switch (event.type) {
  case ykd::GlobalShortcutsEventType::kActivated:
    type = "activated";
    break;
  case ykd::GlobalShortcutsEventType::kDeactivated:
    type = "deactivated";
    break;
  case ykd::GlobalShortcutsEventType::kShortcutsChanged:
    type = "shortcutsChanged";
    break;
  case ykd::GlobalShortcutsEventType::kSessionClosed:
    type = "sessionClosed";
    break;
  case ykd::GlobalShortcutsEventType::kAvailabilityChanged:
    break;
  }
  fl_value_set_string_take(result, "type", fl_value_new_string(type));
  fl_value_set_string_take(result, "generation",
                           fl_value_new_int(event.generation));
  if (event.type == ykd::GlobalShortcutsEventType::kActivated ||
      event.type == ykd::GlobalShortcutsEventType::kDeactivated) {
    if (event.timestamp >
        static_cast<std::uint64_t>(std::numeric_limits<gint64>::max())) {
      fl_value_unref(result);
      return nullptr;
    }
    fl_value_set_string_take(result, "shortcutId",
                             fl_value_new_string(event.shortcut_id.c_str()));
    fl_value_set_string_take(
        result, "timestamp",
        fl_value_new_int(static_cast<gint64>(event.timestamp)));
    if (event.type == ykd::GlobalShortcutsEventType::kActivated &&
        !event.activation_token.empty()) {
      fl_value_set_string_take(
          result, "activationToken",
          fl_value_new_string(event.activation_token.c_str()));
    }
  } else if (event.type == ykd::GlobalShortcutsEventType::kShortcutsChanged) {
    FlValue *bindings = fl_value_new_list();
    for (const auto &binding : event.bindings) {
      fl_value_append_take(bindings, BindingValue(binding));
    }
    fl_value_set_string_take(result, "bindings", bindings);
  } else if (event.type == ykd::GlobalShortcutsEventType::kSessionClosed) {
    if (!event.reason.empty()) {
      fl_value_set_string_take(result, "reason",
                               fl_value_new_string(event.reason.c_str()));
    }
  } else {
    fl_value_set_string_take(result, "capability",
                             CapabilityValue(event.capability));
  }
  return result;
}

void EmitEvent(WaylandGlobalShortcutsPlugin *self,
               const ykd::GlobalShortcutsEvent &event) {
  if (!self->listening || self->event_channel == nullptr ||
      self->explicitly_disposed) {
    return;
  }
  g_autoptr(FlValue) value = EventValue(event);
  if (value == nullptr)
    return;
  g_autoptr(GError) error = nullptr;
  if (!fl_event_channel_send(self->event_channel, value, nullptr, &error)) {
    g_warning("Failed to send GlobalShortcuts event: %s", error->message);
  }
}

FlMethodErrorResponse *ListenCallback(FlEventChannel *, FlValue *,
                                      gpointer user_data) {
  auto *self = WAYLAND_GLOBAL_SHORTCUTS_PLUGIN(user_data);
  self->listening = TRUE;
  return nullptr;
}

FlMethodErrorResponse *CancelCallback(FlEventChannel *, FlValue *,
                                      gpointer user_data) {
  auto *self = WAYLAND_GLOBAL_SHORTCUTS_PLUGIN(user_data);
  self->listening = FALSE;
  return nullptr;
}

void HandleMethodCall(FlMethodChannel *, FlMethodCall *call,
                      gpointer user_data) {
  auto *self = WAYLAND_GLOBAL_SHORTCUTS_PLUGIN(user_data);
  const gchar *method = fl_method_call_get_name(call);
  const MethodKind method_kind = ClassifyMethod(method);

  if (method_kind == MethodKind::kGetCapability) {
    if (self->portal == nullptr || self->explicitly_disposed) {
      g_autoptr(FlValue) result = CapabilityValue({});
      RespondSuccess(call, result);
      return;
    }
    FlMethodCall *retained = FL_METHOD_CALL(g_object_ref(call));
    self->portal->GetCapability(
        [retained](ykd::GlobalShortcutsCapability capability) {
          g_autoptr(FlMethodCall) owned_call = retained;
          g_autoptr(FlValue) result = CapabilityValue(capability);
          RespondSuccess(owned_call, result);
        });
    return;
  }

  if (method_kind == MethodKind::kCreateCandidate) {
    gint64 generation = 0;
    std::vector<ykd::GlobalShortcutDefinition> definitions;
    if (self->portal == nullptr || self->explicitly_disposed) {
      RespondError(call, "portal_unavailable",
                   "The GlobalShortcuts portal is unavailable.");
      return;
    }
    if (!ReadDefinitions(call, &generation, &definitions)) {
      RespondError(call, "invalid_arguments",
                   "Invalid GlobalShortcuts candidate definitions.");
      return;
    }
    FlMethodCall *retained = FL_METHOD_CALL(g_object_ref(call));
    self->portal->CreateCandidate(
        generation, std::move(definitions),
        [retained](bool success, ykd::GlobalShortcutsCandidate candidate,
                   const std::string &diagnostic) {
          g_autoptr(FlMethodCall) owned_call = retained;
          if (!success) {
            RespondError(owned_call, diagnostic.c_str(),
                         "Failed to create a GlobalShortcuts candidate.");
            return;
          }
          g_autoptr(FlValue) result = CandidateValue(candidate);
          RespondSuccess(owned_call, result);
        });
    return;
  }

  if (method_kind == MethodKind::kBindCandidate) {
    ykd::GlobalShortcutsCandidate candidate;
    if (self->portal == nullptr || self->explicitly_disposed) {
      ykd::GlobalShortcutsBindResult result;
      result.diagnostic_code = "portal_unavailable";
      g_autoptr(FlValue) value = BindResultValue(result);
      RespondSuccess(call, value);
      return;
    }
    if (!ReadCandidate(call, &candidate)) {
      RespondError(call, "invalid_arguments",
                   "Invalid GlobalShortcuts candidate.");
      return;
    }
    FlMethodCall *retained = FL_METHOD_CALL(g_object_ref(call));
    self->portal->BindCandidate(
        candidate, [retained](ykd::GlobalShortcutsBindResult bind_result) {
          g_autoptr(FlMethodCall) owned_call = retained;
          g_autoptr(FlValue) result = BindResultValue(bind_result);
          RespondSuccess(owned_call, result);
        });
    return;
  }

  if (method_kind == MethodKind::kCommitCandidate ||
      method_kind == MethodKind::kDiscardCandidate) {
    ykd::GlobalShortcutsCandidate candidate;
    if (self->portal == nullptr || self->explicitly_disposed ||
        !ReadCandidate(call, &candidate)) {
      RespondError(call, "invalid_arguments",
                   "Invalid GlobalShortcuts candidate.");
      return;
    }
    std::string diagnostic;
    const bool commit = method_kind == MethodKind::kCommitCandidate;
    const bool success =
        commit ? self->portal->CommitCandidate(candidate, &diagnostic)
               : self->portal->DiscardCandidate(candidate, &diagnostic);
    if (!success) {
      RespondError(call, diagnostic.c_str(),
                   commit
                       ? "The GlobalShortcuts candidate cannot be committed."
                       : "The GlobalShortcuts candidate cannot be discarded.");
      return;
    }
    RespondSuccess(call);
    return;
  }

  if (method_kind == MethodKind::kCancelRequest) {
    if (self->portal != nullptr)
      self->portal->CancelPendingRequest();
    RespondSuccess(call);
    return;
  }

  if (method_kind == MethodKind::kCloseSessions) {
    if (self->portal != nullptr)
      self->portal->CloseSessions();
    RespondSuccess(call);
    return;
  }

  if (method_kind == MethodKind::kConfigure) {
    if (self->portal == nullptr || self->explicitly_disposed) {
      RespondError(call, "configure_unavailable",
                   "GlobalShortcuts configuration is unavailable.");
      return;
    }
    FlMethodCall *retained = FL_METHOD_CALL(g_object_ref(call));
    self->portal->ConfigureShortcuts(
        [retained](bool success, const std::string &diagnostic) {
          g_autoptr(FlMethodCall) owned_call = retained;
          if (!success) {
            RespondError(owned_call, diagnostic.c_str(),
                         "Failed to open GlobalShortcuts configuration.");
          } else {
            RespondSuccess(owned_call);
          }
        });
    return;
  }

  if (method_kind == MethodKind::kDispose) {
    if (!self->explicitly_disposed) {
      self->explicitly_disposed = TRUE;
      self->listening = FALSE;
      if (self->portal != nullptr)
        self->portal->Dispose();
    }
    RespondSuccess(call);
    return;
  }

  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  Respond(call, response);
}

void ConfigureChannels(WaylandGlobalShortcutsPlugin *self,
                       FlBinaryMessenger *messenger) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) method_channel = fl_method_channel_new(
      messenger, kMethodChannelName, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(method_channel, HandleMethodCall,
                                            g_object_ref(self), g_object_unref);

  self->event_channel = fl_event_channel_new(messenger, kEventChannelName,
                                             FL_METHOD_CODEC(codec));
  fl_event_channel_set_stream_handlers(self->event_channel, ListenCallback,
                                       CancelCallback, self, nullptr);
}

void wayland_global_shortcuts_plugin_dispose(GObject *object) {
  auto *self = WAYLAND_GLOBAL_SHORTCUTS_PLUGIN(object);
  self->listening = FALSE;
  self->explicitly_disposed = TRUE;
  if (self->portal != nullptr) {
    self->portal->SetEventCallback(nullptr);
    self->portal->Dispose();
    delete self->portal;
    self->portal = nullptr;
  }
  if (self->event_channel != nullptr) {
    fl_event_channel_set_stream_handlers(self->event_channel, nullptr, nullptr,
                                         nullptr, nullptr);
  }
  g_clear_object(&self->event_channel);
  G_OBJECT_CLASS(wayland_global_shortcuts_plugin_parent_class)->dispose(object);
}

void wayland_global_shortcuts_plugin_class_init(
    WaylandGlobalShortcutsPluginClass *klass) {
  G_OBJECT_CLASS(klass)->dispose = wayland_global_shortcuts_plugin_dispose;
}

void wayland_global_shortcuts_plugin_init(WaylandGlobalShortcutsPlugin *self) {
  self->portal = nullptr;
  self->event_channel = nullptr;
  self->listening = FALSE;
  self->explicitly_disposed = FALSE;
}

}

void wayland_global_shortcuts_plugin_register_with_registrar(
    FlPluginRegistrar *registrar) {
  auto *self = WAYLAND_GLOBAL_SHORTCUTS_PLUGIN(
      g_object_new(wayland_global_shortcuts_plugin_get_type(), nullptr));

  g_autoptr(GError) bus_error = nullptr;
  g_autoptr(GDBusConnection) connection =
      g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &bus_error);
  if (connection == nullptr) {
    g_warning("GlobalShortcuts session bus is unavailable: %s",
              bus_error->message);
  } else {
    self->portal = new ykd::WaylandGlobalShortcutsPortal(connection);
    self->portal->SetEventCallback(
        [self](const ykd::GlobalShortcutsEvent &event) {
          EmitEvent(self, event);
        });
  }

  ConfigureChannels(self, fl_plugin_registrar_get_messenger(registrar));
  g_object_unref(self);
}

#ifdef YKD_ENABLE_TEST_HOOKS
FlValue *
wayland_global_shortcuts_plugin_capability_value_for_test(gboolean available,
                                                          guint32 version) {
  return CapabilityValue({available != FALSE, version});
}

FlValue *wayland_global_shortcuts_plugin_bind_value_for_test() {
  ykd::GlobalShortcutsBindResult result;
  result.status = ykd::GlobalShortcutsBindStatus::kSuccess;
  result.bindings.push_back(
      {"rewrite", "Rewrite text", true, "Ctrl + Alt + R"});
  return BindResultValue(result);
}

FlValue *
wayland_global_shortcuts_plugin_event_value_for_test(const gchar *type) {
  ykd::GlobalShortcutsEvent event;
  event.generation = 7;
  if (g_strcmp0(type, "activated") == 0) {
    event.type = ykd::GlobalShortcutsEventType::kActivated;
    event.shortcut_id = "rewrite";
    event.timestamp = 42;
    event.activation_token = "opaque-token";
  } else if (g_strcmp0(type, "shortcutsChanged") == 0) {
    event.type = ykd::GlobalShortcutsEventType::kShortcutsChanged;
    event.bindings.push_back(
        {"rewrite", "Rewrite text", true, "Ctrl + Alt + R"});
  } else if (g_strcmp0(type, "sessionClosed") == 0) {
    event.type = ykd::GlobalShortcutsEventType::kSessionClosed;
    event.reason = "revoked";
  } else {
    event.type = ykd::GlobalShortcutsEventType::kAvailabilityChanged;
    event.capability = {true, 2};
  }
  return EventValue(event);
}

gboolean
wayland_global_shortcuts_plugin_read_definitions_for_test(FlValue *arguments) {
  gint64 generation = 0;
  std::vector<ykd::GlobalShortcutDefinition> definitions;
  return ReadDefinitionsValue(arguments, &generation, &definitions) &&
         generation == 7 && definitions.size() == 1 &&
         definitions.front().id == "rewrite";
}

GObject *wayland_global_shortcuts_plugin_new_for_test() {
  return G_OBJECT(
      g_object_new(wayland_global_shortcuts_plugin_get_type(), nullptr));
}

GObject *wayland_global_shortcuts_plugin_register_for_test(
    FlBinaryMessenger *messenger) {
  auto *self = WAYLAND_GLOBAL_SHORTCUTS_PLUGIN(
      g_object_new(wayland_global_shortcuts_plugin_get_type(), nullptr));
  ConfigureChannels(self, messenger);
  return G_OBJECT(self);
}

void wayland_global_shortcuts_plugin_emit_event_for_test(GObject *plugin,
                                                         const gchar *type) {
  ykd::GlobalShortcutsEvent event;
  event.generation = 7;
  if (g_strcmp0(type, "activated") == 0) {
    event.type = ykd::GlobalShortcutsEventType::kActivated;
    event.shortcut_id = "rewrite";
    event.timestamp = 42;
    event.activation_token = "opaque-token";
  } else {
    event.type = ykd::GlobalShortcutsEventType::kSessionClosed;
    event.reason = "revoked";
  }
  EmitEvent(WAYLAND_GLOBAL_SHORTCUTS_PLUGIN(plugin), event);
}

const gchar *wayland_global_shortcuts_plugin_method_channel_for_test() {
  return kMethodChannelName;
}

const gchar *wayland_global_shortcuts_plugin_event_channel_for_test() {
  return kEventChannelName;
}

gint wayland_global_shortcuts_plugin_method_kind_for_test(const gchar *method) {
  return static_cast<gint>(ClassifyMethod(method));
}

gboolean
wayland_global_shortcuts_plugin_set_listening_for_test(GObject *plugin,
                                                       gboolean listening) {
  auto *self = WAYLAND_GLOBAL_SHORTCUTS_PLUGIN(plugin);
  if (listening) {
    ListenCallback(nullptr, nullptr, self);
  } else {
    CancelCallback(nullptr, nullptr, self);
  }
  return self->listening;
}

gboolean wayland_global_shortcuts_plugin_is_disposed_for_test(GObject *plugin) {
  return WAYLAND_GLOBAL_SHORTCUTS_PLUGIN(plugin)->explicitly_disposed;
}

void wayland_global_shortcuts_plugin_dispose_for_test(GObject *plugin) {
  g_object_run_dispose(plugin);
}
#endif
