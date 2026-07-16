#include "wayland_global_shortcuts_plugin.h"

#include <cstdlib>
#include <cstring>
#include <initializer_list>
#include <iterator>

namespace {

void Require(bool condition, const char *message) {
  if (!condition) {
    g_printerr("%s\n", message);
    std::exit(1);
  }
}

const char *StringField(FlValue *map, const char *key) {
  FlValue *value = fl_value_lookup_string(map, key);
  Require(value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_STRING,
          "missing string field");
  return fl_value_get_string(value);
}

gint64 IntField(FlValue *map, const char *key) {
  FlValue *value = fl_value_lookup_string(map, key);
  Require(value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_INT,
          "missing integer field");
  return fl_value_get_int(value);
}

typedef struct _TestResponseHandle {
  FlBinaryMessengerResponseHandle parent_instance;
  GBytes *response;
} TestResponseHandle;

typedef struct _TestResponseHandleClass {
  FlBinaryMessengerResponseHandleClass parent_class;
} TestResponseHandleClass;

G_DEFINE_TYPE(TestResponseHandle, test_response_handle,
              fl_binary_messenger_response_handle_get_type())

void test_response_handle_dispose(GObject *object) {
  auto *self = reinterpret_cast<TestResponseHandle *>(object);
  g_clear_pointer(&self->response, g_bytes_unref);
  G_OBJECT_CLASS(test_response_handle_parent_class)->dispose(object);
}

void test_response_handle_class_init(TestResponseHandleClass *klass) {
  G_OBJECT_CLASS(klass)->dispose = test_response_handle_dispose;
}

void test_response_handle_init(TestResponseHandle *self) {
  self->response = nullptr;
}

struct Handler {
  FlBinaryMessengerMessageHandler callback;
  gpointer user_data;
  GDestroyNotify destroy_notify;
};

void FreeHandler(gpointer value) {
  auto *handler = static_cast<Handler *>(value);
  if (handler->destroy_notify != nullptr)
    handler->destroy_notify(handler->user_data);
  delete handler;
}

typedef struct _TestMessenger {
  GObject parent_instance;
  GHashTable *handlers;
  gchar *last_channel;
  GBytes *last_message;
  guint send_count;
} TestMessenger;

typedef struct _TestMessengerClass {
  GObjectClass parent_class;
} TestMessengerClass;

void test_messenger_interface_init(FlBinaryMessengerInterface *interface);

G_DEFINE_TYPE_WITH_CODE(TestMessenger, test_messenger, G_TYPE_OBJECT,
                        G_IMPLEMENT_INTERFACE(fl_binary_messenger_get_type(),
                                              test_messenger_interface_init))

void SetMessageHandler(FlBinaryMessenger *messenger, const gchar *channel,
                       FlBinaryMessengerMessageHandler callback,
                       gpointer user_data, GDestroyNotify destroy_notify) {
  auto *self = reinterpret_cast<TestMessenger *>(messenger);
  if (callback == nullptr) {
    g_hash_table_remove(self->handlers, channel);
    return;
  }
  g_hash_table_replace(self->handlers, g_strdup(channel),
                       new Handler{callback, user_data, destroy_notify});
}

gboolean SendResponse(FlBinaryMessenger *,
                      FlBinaryMessengerResponseHandle *response_handle,
                      GBytes *response, GError **) {
  auto *handle = reinterpret_cast<TestResponseHandle *>(response_handle);
  Require(handle->response == nullptr, "channel responded more than once");
  if (response != nullptr)
    handle->response = g_bytes_ref(response);
  return TRUE;
}

void SendOnChannel(FlBinaryMessenger *messenger, const gchar *channel,
                   GBytes *message, GCancellable *cancellable,
                   GAsyncReadyCallback callback, gpointer user_data) {
  auto *self = reinterpret_cast<TestMessenger *>(messenger);
  g_free(self->last_channel);
  self->last_channel = g_strdup(channel);
  g_clear_pointer(&self->last_message, g_bytes_unref);
  self->last_message = message == nullptr ? nullptr : g_bytes_ref(message);
  ++self->send_count;
  if (callback != nullptr) {
    g_autoptr(GTask) task = g_task_new(self, cancellable, callback, user_data);
    g_task_return_pointer(task, nullptr, nullptr);
  }
}

GBytes *SendOnChannelFinish(FlBinaryMessenger *, GAsyncResult *result,
                            GError **error) {
  return static_cast<GBytes *>(g_task_propagate_pointer(G_TASK(result), error));
}

void ResizeChannel(FlBinaryMessenger *, const gchar *, int64_t) {}
void SetWarnsOnOverflow(FlBinaryMessenger *, const gchar *, bool) {}

void Shutdown(FlBinaryMessenger *messenger) {
  auto *self = reinterpret_cast<TestMessenger *>(messenger);
  g_hash_table_remove_all(self->handlers);
}

void test_messenger_interface_init(FlBinaryMessengerInterface *interface) {
  interface->set_message_handler_on_channel = SetMessageHandler;
  interface->send_response = SendResponse;
  interface->send_on_channel = SendOnChannel;
  interface->send_on_channel_finish = SendOnChannelFinish;
  interface->resize_channel = ResizeChannel;
  interface->set_warns_on_channel_overflow = SetWarnsOnOverflow;
  interface->shutdown = Shutdown;
}

void test_messenger_dispose(GObject *object) {
  auto *self = reinterpret_cast<TestMessenger *>(object);
  g_clear_pointer(&self->handlers, g_hash_table_unref);
  g_clear_pointer(&self->last_message, g_bytes_unref);
  g_clear_pointer(&self->last_channel, g_free);
  G_OBJECT_CLASS(test_messenger_parent_class)->dispose(object);
}

void test_messenger_class_init(TestMessengerClass *klass) {
  G_OBJECT_CLASS(klass)->dispose = test_messenger_dispose;
}

void test_messenger_init(TestMessenger *self) {
  self->handlers =
      g_hash_table_new_full(g_str_hash, g_str_equal, g_free, FreeHandler);
  self->last_channel = nullptr;
  self->last_message = nullptr;
  self->send_count = 0;
}

FlMethodResponse *Invoke(TestMessenger *messenger, const char *channel,
                         const char *method, FlValue *arguments = nullptr) {
  auto *handler =
      static_cast<Handler *>(g_hash_table_lookup(messenger->handlers, channel));
  Require(handler != nullptr, "channel handler was not installed");
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodCodecClass *codec_class = FL_METHOD_CODEC_GET_CLASS(codec);
  g_autoptr(GError) error = nullptr;
  g_autoptr(GBytes) encoded = codec_class->encode_method_call(
      FL_METHOD_CODEC(codec), method, arguments, &error);
  Require(encoded != nullptr, "failed to encode test method call");
  auto *handle = reinterpret_cast<TestResponseHandle *>(
      g_object_new(test_response_handle_get_type(), nullptr));
  handler->callback(FL_BINARY_MESSENGER(messenger), channel, encoded,
                    FL_BINARY_MESSENGER_RESPONSE_HANDLE(handle),
                    handler->user_data);
  if (handle->response == nullptr || g_bytes_get_size(handle->response) == 0) {
    g_object_unref(handle);
    return FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  FlMethodResponse *response = codec_class->decode_response(
      FL_METHOD_CODEC(codec), handle->response, &error);
  g_object_unref(handle);
  if (response == nullptr) {
    g_printerr("method %s did not produce a valid response: %s\n", method,
               error == nullptr ? "no codec diagnostic" : error->message);
    std::exit(1);
  }
  return response;
}

FlValue *SuccessResult(FlMethodResponse *response) {
  Require(FL_IS_METHOD_SUCCESS_RESPONSE(response),
          "expected a successful method response");
  return fl_method_success_response_get_result(
      FL_METHOD_SUCCESS_RESPONSE(response));
}

void RequireError(FlMethodResponse *response, const char *code) {
  Require(FL_IS_METHOD_ERROR_RESPONSE(response),
          "expected an error method response");
  Require(std::strcmp(fl_method_error_response_get_code(
                          FL_METHOD_ERROR_RESPONSE(response)),
                      code) == 0,
          "method error code mismatch");
}

FlValue *DecodeLastEvent(TestMessenger *messenger) {
  Require(messenger->last_message != nullptr, "event was not sent");
  Require(std::strcmp(
              messenger->last_channel,
              wayland_global_shortcuts_plugin_event_channel_for_test()) == 0,
          "event was sent on the wrong channel");
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodCodecClass *codec_class = FL_METHOD_CODEC_GET_CLASS(codec);
  g_autoptr(GError) error = nullptr;
  g_autoptr(FlMethodResponse) response = codec_class->decode_response(
      FL_METHOD_CODEC(codec), messenger->last_message, &error);
  Require(response != nullptr, "failed to decode event envelope");
  FlValue *result = SuccessResult(response);
  return result == nullptr ? nullptr : fl_value_ref(result);
}

}

int main() {
  const char *method_channel =
      wayland_global_shortcuts_plugin_method_channel_for_test();
  const char *event_channel =
      wayland_global_shortcuts_plugin_event_channel_for_test();
  Require(std::strcmp(method_channel, "io.github.oniel.yandex_keyboard_desktop/"
                                      "global_shortcuts") == 0,
          "method channel name drifted");
  Require(std::strcmp(event_channel, "io.github.oniel.yandex_keyboard_desktop/"
                                     "global_shortcuts_events") == 0,
          "event channel name drifted");

  const char *methods[] = {
      "getGlobalShortcutsCapability",    "createGlobalShortcutsCandidate",
      "bindGlobalShortcutsCandidate",    "commitGlobalShortcutsCandidate",
      "discardGlobalShortcutsCandidate", "cancelGlobalShortcutsRequest",
      "closeGlobalShortcutsSessions",    "configureGlobalShortcuts",
      "disposeGlobalShortcuts",
  };
  for (std::size_t index = 0; index < std::size(methods); ++index) {
    Require(wayland_global_shortcuts_plugin_method_kind_for_test(
                methods[index]) == static_cast<gint>(index),
            "method dispatch mapping drifted");
  }
  Require(wayland_global_shortcuts_plugin_method_kind_for_test("unknown") ==
              static_cast<gint>(std::size(methods)),
          "unknown method no longer fails closed");

  g_autoptr(FlValue) capability =
      wayland_global_shortcuts_plugin_capability_value_for_test(TRUE, 2);
  Require(fl_value_get_bool(fl_value_lookup_string(capability, "available")) ==
              TRUE,
          "capability availability mismatch");
  Require(IntField(capability, "version") == 2, "capability version mismatch");

  g_autoptr(FlValue) bind =
      wayland_global_shortcuts_plugin_bind_value_for_test();
  Require(std::strcmp(StringField(bind, "status"), "success") == 0,
          "bind status mismatch");
  FlValue *bindings = fl_value_lookup_string(bind, "bindings");
  Require(bindings != nullptr && fl_value_get_length(bindings) == 1,
          "binding list mismatch");
  FlValue *binding = fl_value_get_list_value(bindings, 0);
  Require(std::strcmp(StringField(binding, "triggerDescription"),
                      "Ctrl + Alt + R") == 0,
          "trigger serialization mismatch");

  g_autoptr(FlValue) activated =
      wayland_global_shortcuts_plugin_event_value_for_test("activated");
  Require(std::strcmp(StringField(activated, "type"), "activated") == 0,
          "activated event type mismatch");
  Require(IntField(activated, "generation") == 7,
          "activated generation mismatch");
  Require(std::strcmp(StringField(activated, "shortcutId"), "rewrite") == 0,
          "activated shortcut mismatch");
  Require(IntField(activated, "timestamp") == 42,
          "activated timestamp mismatch");
  Require(std::strcmp(StringField(activated, "activationToken"),
                      "opaque-token") == 0,
          "activated token mismatch");

  g_autoptr(FlValue) changed =
      wayland_global_shortcuts_plugin_event_value_for_test("shortcutsChanged");
  Require(IntField(changed, "generation") == 7, "changed generation mismatch");
  FlValue *changed_bindings = fl_value_lookup_string(changed, "bindings");
  Require(changed_bindings != nullptr &&
              fl_value_get_length(changed_bindings) == 1,
          "changed bindings mismatch");
  Require(std::strcmp(
              StringField(fl_value_get_list_value(changed_bindings, 0), "id"),
              "rewrite") == 0,
          "changed binding id mismatch");

  g_autoptr(FlValue) closed =
      wayland_global_shortcuts_plugin_event_value_for_test("sessionClosed");
  Require(std::strcmp(StringField(closed, "reason"), "revoked") == 0,
          "session close reason mismatch");
  g_autoptr(FlValue) availability =
      wayland_global_shortcuts_plugin_event_value_for_test(
          "availabilityChanged");
  FlValue *event_capability =
      fl_value_lookup_string(availability, "capability");
  Require(event_capability != nullptr &&
              fl_value_get_bool(
                  fl_value_lookup_string(event_capability, "available")),
          "availability capability mismatch");
  Require(IntField(event_capability, "version") == 2,
          "availability version mismatch");

  g_autoptr(FlValue) arguments = fl_value_new_map();
  fl_value_set_string_take(arguments, "generation", fl_value_new_int(7));
  g_autoptr(FlValue) definitions = fl_value_new_list();
  g_autoptr(FlValue) definition = fl_value_new_map();
  fl_value_set_string_take(definition, "id", fl_value_new_string("rewrite"));
  fl_value_set_string_take(definition, "description",
                           fl_value_new_string("Rewrite text"));
  fl_value_set_string_take(definition, "preferredTrigger",
                           fl_value_new_string("CTRL+ALT+r"));
  fl_value_append_take(definitions, g_steal_pointer(&definition));
  fl_value_set_string_take(arguments, "shortcuts",
                           g_steal_pointer(&definitions));
  Require(wayland_global_shortcuts_plugin_read_definitions_for_test(arguments),
          "definition parser rejected the Dart contract");

  auto *messenger = reinterpret_cast<TestMessenger *>(
      g_object_new(test_messenger_get_type(), nullptr));
  GObject *plugin = wayland_global_shortcuts_plugin_register_for_test(
      FL_BINARY_MESSENGER(messenger));
  Require(g_hash_table_lookup(messenger->handlers, method_channel) != nullptr,
          "method handler was not registered");
  Require(g_hash_table_lookup(messenger->handlers, event_channel) != nullptr,
          "event stream handler was not registered");

  g_autoptr(FlMethodResponse) capability_response =
      Invoke(messenger, method_channel, "getGlobalShortcutsCapability");
  FlValue *unavailable = SuccessResult(capability_response);
  Require(!fl_value_get_bool(fl_value_lookup_string(unavailable, "available")),
          "detached plugin reported an available portal");

  g_autoptr(FlMethodResponse) create_response =
      Invoke(messenger, method_channel, "createGlobalShortcutsCandidate");
  RequireError(create_response, "portal_unavailable");
  g_autoptr(FlMethodResponse) bind_response =
      Invoke(messenger, method_channel, "bindGlobalShortcutsCandidate");
  Require(std::strcmp(StringField(SuccessResult(bind_response), "status"),
                      "failed") == 0,
          "detached bind response mismatch");
  g_autoptr(FlMethodResponse) unknown_response =
      Invoke(messenger, method_channel, "unknown");
  Require(FL_IS_METHOD_NOT_IMPLEMENTED_RESPONSE(unknown_response),
          "unknown method was not rejected");

  g_autoptr(FlMethodResponse) listen_response =
      Invoke(messenger, event_channel, "listen");
  SuccessResult(listen_response);
  wayland_global_shortcuts_plugin_emit_event_for_test(plugin, "activated");
  Require(messenger->send_count == 1,
          "listening did not enable event delivery");
  g_autoptr(FlValue) delivered = DecodeLastEvent(messenger);
  Require(delivered != nullptr &&
              std::strcmp(StringField(delivered, "shortcutId"), "rewrite") ==
                  0 &&
              IntField(delivered, "timestamp") == 42,
          "delivered event payload mismatch");

  g_autoptr(FlMethodResponse) cancel_response =
      Invoke(messenger, event_channel, "cancel");
  SuccessResult(cancel_response);
  wayland_global_shortcuts_plugin_emit_event_for_test(plugin, "activated");
  Require(messenger->send_count == 1, "cancel did not stop event delivery");

  g_autoptr(FlMethodResponse) relisten_response =
      Invoke(messenger, event_channel, "listen");
  SuccessResult(relisten_response);
  g_autoptr(FlMethodResponse) dispose_response =
      Invoke(messenger, method_channel, "disposeGlobalShortcuts");
  SuccessResult(dispose_response);
  Require(wayland_global_shortcuts_plugin_is_disposed_for_test(plugin),
          "dispose method did not revoke plugin state");
  wayland_global_shortcuts_plugin_emit_event_for_test(plugin, "activated");
  Require(messenger->send_count == 1,
          "disposed plugin continued delivering events");
  g_autoptr(FlMethodResponse) configure_response =
      Invoke(messenger, method_channel, "configureGlobalShortcuts");
  RequireError(configure_response, "configure_unavailable");

  g_object_run_dispose(plugin);
  g_object_unref(plugin);
  g_object_unref(messenger);
  while (g_main_context_iteration(nullptr, FALSE)) {
  }
  return 0;
}
