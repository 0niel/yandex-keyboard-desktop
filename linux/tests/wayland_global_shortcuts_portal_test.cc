#include "wayland_global_shortcuts_portal.h"

#include <gio/gio.h>

#include <algorithm>
#include <cstdint>
#include <functional>
#include <map>
#include <string>
#include <utility>
#include <vector>

namespace {

constexpr char kBusName[] = "org.freedesktop.portal.Desktop";
constexpr char kPortalPath[] = "/org/freedesktop/portal/desktop";
constexpr char kGlobalShortcutsInterface[] =
    "org.freedesktop.portal.GlobalShortcuts";
constexpr char kRequestInterface[] = "org.freedesktop.portal.Request";
constexpr char kSessionInterface[] = "org.freedesktop.portal.Session";

constexpr char kPortalXml[] = R"XML(
<node>
  <interface name='org.freedesktop.portal.GlobalShortcuts'>
    <property name='version' type='u' access='read'/>
    <method name='CreateSession'>
      <arg name='options' type='a{sv}' direction='in'/>
      <arg name='handle' type='o' direction='out'/>
    </method>
    <method name='BindShortcuts'>
      <arg name='session_handle' type='o' direction='in'/>
      <arg name='shortcuts' type='a(sa{sv})' direction='in'/>
      <arg name='parent_window' type='s' direction='in'/>
      <arg name='options' type='a{sv}' direction='in'/>
      <arg name='request_handle' type='o' direction='out'/>
    </method>
    <method name='ConfigureShortcuts'>
      <arg name='session_handle' type='o' direction='in'/>
      <arg name='parent_window' type='s' direction='in'/>
      <arg name='options' type='a{sv}' direction='in'/>
    </method>
    <signal name='Activated'>
      <arg name='session_handle' type='o'/>
      <arg name='shortcut_id' type='s'/>
      <arg name='timestamp' type='t'/>
      <arg name='options' type='a{sv}'/>
    </signal>
    <signal name='Deactivated'>
      <arg name='session_handle' type='o'/>
      <arg name='shortcut_id' type='s'/>
      <arg name='timestamp' type='t'/>
      <arg name='options' type='a{sv}'/>
    </signal>
    <signal name='ShortcutsChanged'>
      <arg name='session_handle' type='o'/>
      <arg name='shortcuts' type='a(sa{sv})'/>
    </signal>
  </interface>
</node>
)XML";

constexpr char kRequestXml[] = R"XML(
<node>
  <interface name='org.freedesktop.portal.Request'>
    <method name='Close'/>
    <signal name='Response'>
      <arg name='response' type='u'/>
      <arg name='results' type='a{sv}'/>
    </signal>
  </interface>
</node>
)XML";

constexpr char kSessionXml[] = R"XML(
<node>
  <interface name='org.freedesktop.portal.Session'>
    <method name='Close'/>
    <signal name='Closed'>
      <arg name='details' type='a{sv}'/>
    </signal>
  </interface>
</node>
)XML";

std::string SenderPathElement(const gchar *sender) {
  g_assert_nonnull(sender);
  g_assert_cmpint(sender[0], ==, ':');
  std::string result(sender + 1);
  std::replace(result.begin(), result.end(), '.', '_');
  return result;
}

std::string RequiredOption(GVariant *options, const char *key) {
  g_autoptr(GVariant) value =
      g_variant_lookup_value(options, key, G_VARIANT_TYPE_STRING);
  g_assert_nonnull(value);
  return g_variant_get_string(value, nullptr);
}

GDBusConnection *NewPrivateBusConnection(const char *address) {
  g_autoptr(GError) error = nullptr;
  GDBusConnection *connection = g_dbus_connection_new_for_address_sync(
      address,
      static_cast<GDBusConnectionFlags>(
          G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT |
          G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION),
      nullptr, nullptr, &error);
  g_assert_no_error(error);
  g_assert_nonnull(connection);
  g_dbus_connection_set_exit_on_close(connection, FALSE);
  return connection;
}

bool SpinUntil(const std::function<bool()> &predicate,
               gint64 timeout_milliseconds = 3000) {
  const gint64 deadline =
      g_get_monotonic_time() + timeout_milliseconds * G_TIME_SPAN_MILLISECOND;
  while (!predicate() && g_get_monotonic_time() < deadline) {
    while (g_main_context_iteration(nullptr, FALSE)) {
    }
    g_usleep(1000);
  }
  return predicate();
}

void DrainFor(gint64 milliseconds) {
  const gint64 deadline =
      g_get_monotonic_time() + milliseconds * G_TIME_SPAN_MILLISECOND;
  while (g_get_monotonic_time() < deadline) {
    while (g_main_context_iteration(nullptr, FALSE)) {
    }
    g_usleep(1000);
  }
}

class FakePortal final {
public:
  enum class BindMode { kFull, kPartial, kHold, kCancelled, kFailed };

  explicit FakePortal(GDBusConnection *connection)
      : connection_(G_DBUS_CONNECTION(g_object_ref(connection))) {
    g_autoptr(GError) error = nullptr;
    portal_info_ = g_dbus_node_info_new_for_xml(kPortalXml, &error);
    g_assert_no_error(error);
    request_info_ = g_dbus_node_info_new_for_xml(kRequestXml, &error);
    g_assert_no_error(error);
    session_info_ = g_dbus_node_info_new_for_xml(kSessionXml, &error);
    g_assert_no_error(error);

    portal_registration_ = g_dbus_connection_register_object(
        connection_, kPortalPath, portal_info_->interfaces[0], PortalVtable(),
        this, nullptr, &error);
    g_assert_no_error(error);
    g_assert_cmpuint(portal_registration_, >, 0);

    g_autoptr(GVariant) reply = g_dbus_connection_call_sync(
        connection_, "org.freedesktop.DBus", "/org/freedesktop/DBus",
        "org.freedesktop.DBus", "RequestName",
        g_variant_new("(su)", kBusName, 0u), G_VARIANT_TYPE("(u)"),
        G_DBUS_CALL_FLAGS_NONE, -1, nullptr, &error);
    g_assert_no_error(error);
    g_assert_nonnull(reply);
    guint32 result = 0;
    g_variant_get(reply, "(u)", &result);
    g_assert_cmpuint(result, ==, 1);
    owns_name_ = true;
  }

  ~FakePortal() {
    ReleaseName();
    for (const auto &entry : registrations_) {
      g_dbus_connection_unregister_object(connection_, entry.second);
    }
    registrations_.clear();
    if (portal_registration_ != 0) {
      g_dbus_connection_unregister_object(connection_, portal_registration_);
    }
    g_dbus_node_info_unref(portal_info_);
    g_dbus_node_info_unref(request_info_);
    g_dbus_node_info_unref(session_info_);
    g_clear_object(&connection_);
    if (held_results_ != nullptr)
      g_variant_unref(held_results_);
    if (held_bind_invocation_ != nullptr) {
      g_dbus_method_invocation_return_dbus_error(
          held_bind_invocation_, "org.freedesktop.DBus.Error.Cancelled",
          "Fake portal disposed");
      g_clear_object(&held_bind_invocation_);
    }
  }

  void set_bind_mode(BindMode mode) { bind_mode_ = mode; }
  void set_delayed_bind_reply(bool delayed, bool noncanonical = false) {
    delay_bind_reply_ = delayed;
    noncanonical_bind_request_ = noncanonical;
  }
  int request_close_count() const { return request_close_count_; }
  int session_close_count() const { return session_close_count_; }
  int configure_count() const { return configure_count_; }

  void EmitActivated(const std::string &session, const std::string &shortcut_id,
                     std::uint64_t timestamp = 42) {
    GVariantBuilder options;
    g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
    g_variant_builder_add(&options, "{sv}", "activation_token",
                          g_variant_new_string("opaque-token"));
    Emit(kPortalPath, kGlobalShortcutsInterface, "Activated",
         g_variant_new("(ost@a{sv})", session.c_str(), shortcut_id.c_str(),
                       timestamp, g_variant_builder_end(&options)));
  }

  void EmitChanged(const std::string &session,
                   const std::vector<std::string> &ids) {
    g_autoptr(GVariant) shortcuts = BuildBindings(ids);
    Emit(kPortalPath, kGlobalShortcutsInterface, "ShortcutsChanged",
         g_variant_new("(o@a(sa{sv}))", session.c_str(),
                       g_steal_pointer(&shortcuts)));
  }

  void EmitMalformedChanged(const std::string &session) {
    GVariantBuilder shortcuts;
    g_variant_builder_init(&shortcuts, G_VARIANT_TYPE("a(sa{sv})"));
    GVariantBuilder properties;
    g_variant_builder_init(&properties, G_VARIANT_TYPE_VARDICT);
    g_variant_builder_add(&shortcuts, "(s@a{sv})", "correct",
                          g_variant_builder_end(&properties));
    Emit(kPortalPath, kGlobalShortcutsInterface, "ShortcutsChanged",
         g_variant_new("(o@a(sa{sv}))", session.c_str(),
                       g_variant_builder_end(&shortcuts)));
  }

  void EmitWrongSignatureChanged(const std::string &session) {
    Emit(kPortalPath, kGlobalShortcutsInterface, "ShortcutsChanged",
         g_variant_new("(s)", session.c_str()));
  }

  void EmitHeldSuccess() {
    if (held_request_path_.empty() || held_results_ == nullptr)
      return;
    Emit(held_request_path_, kRequestInterface, "Response",
         g_variant_new("(u@a{sv})", 0u, g_steal_pointer(&held_results_)));
    held_request_path_.clear();
  }

  void ReplyHeldBindMethod() {
    if (held_bind_invocation_ == nullptr || held_bind_request_path_.empty())
      return;
    g_dbus_method_invocation_return_value(
        held_bind_invocation_,
        g_variant_new("(o)", held_bind_request_path_.c_str()));
    g_clear_object(&held_bind_invocation_);
    held_bind_request_path_.clear();
  }

  void ReleaseName() {
    if (!owns_name_)
      return;
    g_autoptr(GError) error = nullptr;
    g_autoptr(GVariant) reply = g_dbus_connection_call_sync(
        connection_, "org.freedesktop.DBus", "/org/freedesktop/DBus",
        "org.freedesktop.DBus", "ReleaseName", g_variant_new("(s)", kBusName),
        G_VARIANT_TYPE("(u)"), G_DBUS_CALL_FLAGS_NONE, -1, nullptr, &error);
    g_assert_no_error(error);
    g_assert_nonnull(reply);
    owns_name_ = false;
  }

private:
  struct DeferredResponse {
    GDBusConnection *connection = nullptr;
    std::string object_path;
    guint32 response = 2;
    GVariant *results = nullptr;
  };

  static GDBusInterfaceVTable *PortalVtable() {
    static GDBusInterfaceVTable vtable = {};
    vtable.method_call = PortalMethodCall;
    vtable.get_property = GetProperty;
    return &vtable;
  }

  static GDBusInterfaceVTable *ObjectVtable() {
    static GDBusInterfaceVTable vtable = {};
    vtable.method_call = ObjectMethodCall;
    return &vtable;
  }

  static GVariant *GetProperty(GDBusConnection *, const gchar *, const gchar *,
                               const gchar *, const gchar *property_name,
                               GError **, gpointer) {
    if (g_strcmp0(property_name, "version") == 0) {
      return g_variant_new_uint32(2);
    }
    return nullptr;
  }

  static void PortalMethodCall(GDBusConnection *, const gchar *sender,
                               const gchar *, const gchar *,
                               const gchar *method, GVariant *parameters,
                               GDBusMethodInvocation *invocation,
                               gpointer user_data) {
    auto *self = static_cast<FakePortal *>(user_data);
    if (g_strcmp0(method, "CreateSession") == 0) {
      GVariant *options = nullptr;
      g_variant_get(parameters, "(@a{sv})", &options);
      g_autoptr(GVariant) owned_options = options;
      const std::string request_token =
          RequiredOption(owned_options, "handle_token");
      const std::string session_token =
          RequiredOption(owned_options, "session_handle_token");
      const std::string sender_path = SenderPathElement(sender);
      const std::string request = "/org/freedesktop/portal/desktop/request/" +
                                  sender_path + "/" + request_token;
      const std::string session = "/org/freedesktop/portal/desktop/session/" +
                                  sender_path + "/" + session_token;
      self->RegisterObject(request, self->request_info_->interfaces[0]);
      self->RegisterObject(session, self->session_info_->interfaces[0]);
      g_dbus_method_invocation_return_value(
          invocation, g_variant_new("(o)", request.c_str()));
      GVariantBuilder results;
      g_variant_builder_init(&results, G_VARIANT_TYPE_VARDICT);
      g_variant_builder_add(&results, "{sv}", "session_handle",
                            g_variant_new_string(session.c_str()));
      self->ScheduleResponse(request, 0, g_variant_builder_end(&results));
      return;
    }

    if (g_strcmp0(method, "BindShortcuts") == 0) {
      const gchar *session = nullptr;
      const gchar *parent = nullptr;
      GVariant *definitions = nullptr;
      GVariant *options = nullptr;
      g_variant_get(parameters, "(&o@a(sa{sv})&s@a{sv})", &session,
                    &definitions, &parent, &options);
      g_autoptr(GVariant) owned_definitions = definitions;
      g_autoptr(GVariant) owned_options = options;
      (void)session;
      (void)parent;
      const std::string request_token =
          RequiredOption(owned_options, "handle_token");
      const std::string request = "/org/freedesktop/portal/desktop/request/" +
                                  SenderPathElement(sender) + "/" +
                                  request_token;
      const std::string returned_request =
          self->noncanonical_bind_request_ ? request + "_legacy" : request;
      self->RegisterObject(returned_request,
                           self->request_info_->interfaces[0]);
      if (self->delay_bind_reply_) {
        self->held_bind_invocation_ =
            G_DBUS_METHOD_INVOCATION(g_object_ref(invocation));
        self->held_bind_request_path_ = returned_request;
      } else {
        g_dbus_method_invocation_return_value(
            invocation, g_variant_new("(o)", returned_request.c_str()));
      }

      if (self->bind_mode_ == BindMode::kCancelled) {
        self->ScheduleResponse(returned_request, 1, EmptyDictionary());
        return;
      }
      if (self->bind_mode_ == BindMode::kFailed) {
        self->ScheduleResponse(returned_request, 2, EmptyDictionary());
        return;
      }
      std::vector<std::string> ids = DefinitionIds(owned_definitions);
      if (self->bind_mode_ == BindMode::kPartial && ids.size() > 1) {
        ids.resize(1);
      }
      GVariantBuilder results;
      g_variant_builder_init(&results, G_VARIANT_TYPE_VARDICT);
      g_variant_builder_add(&results, "{sv}", "shortcuts",
                            self->BuildBindings(ids));
      GVariant *result_dictionary =
          g_variant_ref_sink(g_variant_builder_end(&results));
      if (self->bind_mode_ == BindMode::kHold) {
        self->held_request_path_ = returned_request;
        if (self->held_results_ != nullptr) {
          g_variant_unref(self->held_results_);
        }
        self->held_results_ = result_dictionary;
      } else {
        self->ScheduleResponse(returned_request, 0, result_dictionary);
        g_variant_unref(result_dictionary);
      }
      return;
    }

    if (g_strcmp0(method, "ConfigureShortcuts") == 0) {
      ++self->configure_count_;
      g_dbus_method_invocation_return_value(invocation, g_variant_new("()"));
      return;
    }
    g_dbus_method_invocation_return_dbus_error(
        invocation, "org.freedesktop.DBus.Error.UnknownMethod",
        "Unknown fake portal method");
  }

  static void ObjectMethodCall(GDBusConnection *, const gchar *,
                               const gchar *object_path,
                               const gchar *interface_name, const gchar *method,
                               GVariant *, GDBusMethodInvocation *invocation,
                               gpointer user_data) {
    auto *self = static_cast<FakePortal *>(user_data);
    if (g_strcmp0(method, "Close") != 0) {
      g_dbus_method_invocation_return_dbus_error(
          invocation, "org.freedesktop.DBus.Error.UnknownMethod",
          "Unknown fake object method");
      return;
    }
    if (g_strcmp0(interface_name, kRequestInterface) == 0) {
      ++self->request_close_count_;
    } else if (g_strcmp0(interface_name, kSessionInterface) == 0) {
      ++self->session_close_count_;
      GVariantBuilder details;
      g_variant_builder_init(&details, G_VARIANT_TYPE_VARDICT);
      self->Emit(object_path, kSessionInterface, "Closed",
                 g_variant_new("(@a{sv})", g_variant_builder_end(&details)));
    }
    g_dbus_method_invocation_return_value(invocation, g_variant_new("()"));
  }

  void RegisterObject(const std::string &path, GDBusInterfaceInfo *interface) {
    if (registrations_.find(path) != registrations_.end())
      return;
    g_autoptr(GError) error = nullptr;
    const guint registration = g_dbus_connection_register_object(
        connection_, path.c_str(), interface, ObjectVtable(), this, nullptr,
        &error);
    g_assert_no_error(error);
    g_assert_cmpuint(registration, >, 0);
    registrations_.emplace(path, registration);
  }

  static GVariant *EmptyDictionary() {
    GVariantBuilder builder;
    g_variant_builder_init(&builder, G_VARIANT_TYPE_VARDICT);
    return g_variant_builder_end(&builder);
  }

  static std::vector<std::string> DefinitionIds(GVariant *definitions) {
    std::vector<std::string> ids;
    GVariantIter iterator;
    g_variant_iter_init(&iterator, definitions);
    const gchar *id = nullptr;
    GVariant *properties = nullptr;
    while (g_variant_iter_next(&iterator, "(&s@a{sv})", &id, &properties)) {
      g_variant_unref(properties);
      ids.emplace_back(id);
    }
    return ids;
  }

  static GVariant *BuildBindings(const std::vector<std::string> &ids) {
    GVariantBuilder bindings;
    g_variant_builder_init(&bindings, G_VARIANT_TYPE("a(sa{sv})"));
    for (const auto &id : ids) {
      GVariantBuilder properties;
      g_variant_builder_init(&properties, G_VARIANT_TYPE_VARDICT);
      g_variant_builder_add(&properties, "{sv}", "description",
                            g_variant_new_string(("Action " + id).c_str()));
      g_variant_builder_add(&properties, "{sv}", "trigger_description",
                            g_variant_new_string("Ctrl+Alt+R"));
      g_variant_builder_add(&bindings, "(s@a{sv})", id.c_str(),
                            g_variant_builder_end(&properties));
    }
    return g_variant_builder_end(&bindings);
  }

  void ScheduleResponse(const std::string &path, guint32 response,
                        GVariant *results) {
    auto *deferred =
        new DeferredResponse{G_DBUS_CONNECTION(g_object_ref(connection_)), path,
                             response, g_variant_ref_sink(results)};
    g_idle_add_full(
        G_PRIORITY_DEFAULT,
        [](gpointer data) -> gboolean {
          auto *item = static_cast<DeferredResponse *>(data);
          g_autoptr(GError) error = nullptr;
          g_dbus_connection_emit_signal(
              item->connection, nullptr, item->object_path.c_str(),
              kRequestInterface, "Response",
              g_variant_new("(u@a{sv})", item->response,
                            g_variant_ref(item->results)),
              &error);
          g_assert_no_error(error);
          return G_SOURCE_REMOVE;
        },
        deferred,
        [](gpointer data) {
          auto *item = static_cast<DeferredResponse *>(data);
          g_variant_unref(item->results);
          g_object_unref(item->connection);
          delete item;
        });
  }

  void Emit(const std::string &path, const char *interface, const char *signal,
            GVariant *parameters) {
    g_autoptr(GError) error = nullptr;
    const gboolean emitted =
        g_dbus_connection_emit_signal(connection_, nullptr, path.c_str(),
                                      interface, signal, parameters, &error);
    g_assert_true(emitted);
    g_assert_no_error(error);
  }

  GDBusConnection *connection_ = nullptr;
  GDBusNodeInfo *portal_info_ = nullptr;
  GDBusNodeInfo *request_info_ = nullptr;
  GDBusNodeInfo *session_info_ = nullptr;
  guint portal_registration_ = 0;
  std::map<std::string, guint> registrations_;
  bool owns_name_ = false;
  BindMode bind_mode_ = BindMode::kFull;
  int request_close_count_ = 0;
  int session_close_count_ = 0;
  int configure_count_ = 0;
  std::string held_request_path_;
  GVariant *held_results_ = nullptr;
  GDBusMethodInvocation *held_bind_invocation_ = nullptr;
  std::string held_bind_request_path_;
  bool delay_bind_reply_ = false;
  bool noncanonical_bind_request_ = false;
};

struct Fixture {
  GTestDBus *bus;
  GDBusConnection *service_connection;
  GDBusConnection *client_connection;
  FakePortal *fake;
  ykd::WaylandGlobalShortcutsPortal *portal;
  std::vector<ykd::GlobalShortcutsEvent> *events;
};

void FixtureSetUp(Fixture *fixture, gconstpointer) {
  fixture->bus = g_test_dbus_new(G_TEST_DBUS_NONE);
  g_test_dbus_up(fixture->bus);
  const char *address = g_test_dbus_get_bus_address(fixture->bus);
  fixture->service_connection = NewPrivateBusConnection(address);
  fixture->client_connection = NewPrivateBusConnection(address);
  fixture->fake = new FakePortal(fixture->service_connection);
  fixture->portal = new ykd::WaylandGlobalShortcutsPortal(
      fixture->client_connection, kBusName);
  fixture->events = new std::vector<ykd::GlobalShortcutsEvent>();
  fixture->portal->SetEventCallback(
      [fixture](const ykd::GlobalShortcutsEvent &event) {
        fixture->events->push_back(event);
      });

  bool completed = false;
  ykd::GlobalShortcutsCapability capability;
  fixture->portal->GetCapability(
      [&completed, &capability](ykd::GlobalShortcutsCapability value) {
        capability = value;
        completed = true;
      });
  g_assert_true(SpinUntil([&completed] { return completed; }));
  g_assert_true(capability.available);
  g_assert_cmpuint(capability.version, ==, 2);
  fixture->events->clear();
}

void FixtureTearDown(Fixture *fixture, gconstpointer) {
  fixture->portal->Dispose();
  delete fixture->portal;
  fixture->portal = nullptr;
  DrainFor(20);
  delete fixture->fake;
  fixture->fake = nullptr;
  delete fixture->events;
  fixture->events = nullptr;
  g_dbus_connection_close_sync(fixture->client_connection, nullptr, nullptr);
  g_dbus_connection_close_sync(fixture->service_connection, nullptr, nullptr);
  g_clear_object(&fixture->client_connection);
  g_clear_object(&fixture->service_connection);
  g_test_dbus_down(fixture->bus);
  g_clear_object(&fixture->bus);
}

std::vector<ykd::GlobalShortcutDefinition> Definitions() {
  return {
      {"correct", "Correct text", "CTRL+ALT+R"},
      {"translate", "Translate text", "CTRL+ALT+T"},
  };
}

ykd::GlobalShortcutsCandidate CreateCandidate(Fixture *fixture,
                                              std::int64_t generation) {
  bool completed = false;
  bool success = false;
  ykd::GlobalShortcutsCandidate candidate;
  fixture->portal->CreateCandidate(generation, Definitions(),
                                   [&](bool value,
                                       ykd::GlobalShortcutsCandidate created,
                                       const std::string &) {
                                     success = value;
                                     candidate = std::move(created);
                                     completed = true;
                                   });
  g_assert_true(SpinUntil([&completed] { return completed; }));
  g_assert_true(success);
  g_assert_cmpint(candidate.generation, ==, generation);
  return candidate;
}

ykd::GlobalShortcutsBindResult
BindCandidate(Fixture *fixture,
              const ykd::GlobalShortcutsCandidate &candidate) {
  bool completed = false;
  ykd::GlobalShortcutsBindResult result;
  fixture->portal->BindCandidate(candidate,
                                 [&](ykd::GlobalShortcutsBindResult value) {
                                   result = std::move(value);
                                   completed = true;
                                 });
  g_assert_true(SpinUntil([&completed] { return completed; }));
  return result;
}

void ExactCommitDeliversOnlyActiveSession(Fixture *fixture, gconstpointer) {
  const auto candidate = CreateCandidate(fixture, 1);
  const auto bind = BindCandidate(fixture, candidate);
  g_assert_true(bind.status == ykd::GlobalShortcutsBindStatus::kSuccess);
  g_assert_cmpuint(bind.bindings.size(), ==, 2);
  g_assert_true(bind.bindings[0].has_trigger_description);

  fixture->fake->EmitActivated(candidate.id, "correct");
  DrainFor(20);
  g_assert_true(fixture->events->empty());

  std::string diagnostic;
  g_assert_true(fixture->portal->CommitCandidate(candidate, &diagnostic));
  fixture->fake->EmitActivated(candidate.id, "correct");
  g_assert_true(SpinUntil([fixture] { return !fixture->events->empty(); }));
  const auto &activation = fixture->events->back();
  g_assert_true(activation.type == ykd::GlobalShortcutsEventType::kActivated);
  g_assert_cmpint(activation.generation, ==, 1);
  g_assert_cmpstr(activation.shortcut_id.c_str(), ==, "correct");
  g_assert_cmpstr(activation.activation_token.c_str(), ==, "opaque-token");

  fixture->fake->EmitChanged(candidate.id, {"correct", "translate"});
  g_assert_true(SpinUntil([fixture] {
    return fixture->events->back().type ==
           ykd::GlobalShortcutsEventType::kShortcutsChanged;
  }));
  g_assert_cmpuint(fixture->events->back().bindings.size(), ==, 2);

  bool configured = false;
  fixture->portal->ConfigureShortcuts(
      [&configured](bool success, const std::string &) {
        configured = success;
      });
  g_assert_true(SpinUntil([&configured] { return configured; }));
  g_assert_cmpint(fixture->fake->configure_count(), ==, 1);
}

void PartialCandidateCannotReplaceActive(Fixture *fixture, gconstpointer) {
  const auto first = CreateCandidate(fixture, 1);
  g_assert_true(BindCandidate(fixture, first).status ==
                ykd::GlobalShortcutsBindStatus::kSuccess);
  std::string diagnostic;
  g_assert_true(fixture->portal->CommitCandidate(first, &diagnostic));

  fixture->fake->set_bind_mode(FakePortal::BindMode::kPartial);
  const auto partial = CreateCandidate(fixture, 2);
  const auto bind = BindCandidate(fixture, partial);
  g_assert_true(bind.status == ykd::GlobalShortcutsBindStatus::kSuccess);
  g_assert_cmpuint(bind.bindings.size(), ==, 1);
  g_assert_false(fixture->portal->CommitCandidate(partial, &diagnostic));
  g_assert_cmpstr(diagnostic.c_str(), ==, "partial_bind");

  fixture->events->clear();
  fixture->fake->EmitActivated(partial.id, "correct");
  DrainFor(20);
  g_assert_true(fixture->events->empty());
  fixture->fake->EmitActivated(first.id, "correct");
  g_assert_true(SpinUntil([fixture] { return !fixture->events->empty(); }));
  g_assert_cmpint(fixture->events->back().generation, ==, 1);
  g_assert_true(fixture->portal->DiscardCandidate(partial, &diagnostic));
}

void CandidateSwapRetiresPreviousSession(Fixture *fixture, gconstpointer) {
  const auto first = CreateCandidate(fixture, 1);
  g_assert_true(BindCandidate(fixture, first).status ==
                ykd::GlobalShortcutsBindStatus::kSuccess);
  std::string diagnostic;
  g_assert_true(fixture->portal->CommitCandidate(first, &diagnostic));

  const auto second = CreateCandidate(fixture, 2);
  g_assert_true(BindCandidate(fixture, second).status ==
                ykd::GlobalShortcutsBindStatus::kSuccess);
  g_assert_true(fixture->portal->CommitCandidate(second, &diagnostic));
  g_assert_true(SpinUntil(
      [fixture] { return fixture->fake->session_close_count() >= 1; }));

  fixture->events->clear();
  fixture->fake->EmitActivated(first.id, "correct");
  DrainFor(20);
  g_assert_true(fixture->events->empty());
  fixture->fake->EmitActivated(second.id, "translate");
  g_assert_true(SpinUntil([fixture] { return !fixture->events->empty(); }));
  g_assert_cmpint(fixture->events->back().generation, ==, 2);
}

void CancelClosesRequestAndCompletesOnce(Fixture *fixture, gconstpointer) {
  const auto candidate = CreateCandidate(fixture, 1);
  fixture->fake->set_bind_mode(FakePortal::BindMode::kHold);
  int completion_count = 0;
  ykd::GlobalShortcutsBindResult result;
  fixture->portal->BindCandidate(candidate,
                                 [&](ykd::GlobalShortcutsBindResult value) {
                                   ++completion_count;
                                   result = std::move(value);
                                 });
  DrainFor(20);
  g_assert_cmpint(completion_count, ==, 0);
  fixture->portal->CancelPendingRequest();
  g_assert_cmpint(completion_count, ==, 1);
  g_assert_true(result.status == ykd::GlobalShortcutsBindStatus::kCancelled);
  g_assert_true(SpinUntil(
      [fixture] { return fixture->fake->request_close_count() == 1; }));
  fixture->fake->EmitHeldSuccess();
  DrainFor(30);
  g_assert_cmpint(completion_count, ==, 1);
}

void CancelClosesLateNoncanonicalRequest(Fixture *fixture, gconstpointer) {
  const auto candidate = CreateCandidate(fixture, 1);
  fixture->fake->set_bind_mode(FakePortal::BindMode::kHold);
  fixture->fake->set_delayed_bind_reply(true, true);
  int completion_count = 0;
  fixture->portal->BindCandidate(
      candidate, [&](ykd::GlobalShortcutsBindResult result) {
        ++completion_count;
        g_assert_true(result.status ==
                      ykd::GlobalShortcutsBindStatus::kCancelled);
      });
  DrainFor(20);
  g_assert_cmpint(completion_count, ==, 0);

  fixture->portal->CancelPendingRequest();
  g_assert_cmpint(completion_count, ==, 1);
  fixture->fake->ReplyHeldBindMethod();
  g_assert_true(SpinUntil(
      [fixture] { return fixture->fake->request_close_count() == 1; }));
  fixture->fake->EmitHeldSuccess();
  DrainFor(20);
  g_assert_cmpint(completion_count, ==, 1);
}

void CancelBoundsLateHandleDiscovery(Fixture *fixture, gconstpointer) {
  fixture->portal->Dispose();
  delete fixture->portal;
  fixture->portal = new ykd::WaylandGlobalShortcutsPortal(
      fixture->client_connection, kBusName, 25);
  fixture->portal->SetEventCallback(
      [fixture](const ykd::GlobalShortcutsEvent &event) {
        fixture->events->push_back(event);
      });
  bool capability_ready = false;
  fixture->portal->GetCapability(
      [&capability_ready](ykd::GlobalShortcutsCapability capability) {
        capability_ready = capability.available;
      });
  g_assert_true(SpinUntil([&capability_ready] { return capability_ready; }));

  const auto candidate = CreateCandidate(fixture, 1);
  fixture->fake->set_bind_mode(FakePortal::BindMode::kHold);
  fixture->fake->set_delayed_bind_reply(true, true);
  int completion_count = 0;
  fixture->portal->BindCandidate(
      candidate, [&completion_count](ykd::GlobalShortcutsBindResult result) {
        ++completion_count;
        g_assert_true(result.status ==
                      ykd::GlobalShortcutsBindStatus::kCancelled);
      });
  DrainFor(20);
  fixture->portal->CancelPendingRequest();
  g_assert_cmpint(completion_count, ==, 1);
  g_assert_cmpuint(fixture->portal->AbandonedRequestCountForTest(), ==, 1);
  g_assert_true(SpinUntil(
      [fixture] {
        return fixture->portal->AbandonedRequestCountForTest() == 0;
      },
      500));
  g_assert_cmpint(completion_count, ==, 1);
}

void ResponseCodesRemainFailClosed(Fixture *fixture, gconstpointer) {
  fixture->fake->set_bind_mode(FakePortal::BindMode::kCancelled);
  const auto cancelled_candidate = CreateCandidate(fixture, 1);
  const auto cancelled = BindCandidate(fixture, cancelled_candidate);
  g_assert_true(cancelled.status == ykd::GlobalShortcutsBindStatus::kCancelled);
  g_assert_cmpstr(cancelled.diagnostic_code.c_str(), ==, "cancelled");
  std::string diagnostic;
  g_assert_false(
      fixture->portal->CommitCandidate(cancelled_candidate, &diagnostic));
  g_assert_true(
      fixture->portal->DiscardCandidate(cancelled_candidate, &diagnostic));

  fixture->fake->set_bind_mode(FakePortal::BindMode::kFailed);
  const auto failed_candidate = CreateCandidate(fixture, 2);
  const auto failed = BindCandidate(fixture, failed_candidate);
  g_assert_true(failed.status == ykd::GlobalShortcutsBindStatus::kFailed);
  g_assert_cmpstr(failed.diagnostic_code.c_str(), ==, "bind_failed");
  g_assert_false(
      fixture->portal->CommitCandidate(failed_candidate, &diagnostic));
  g_assert_true(
      fixture->portal->DiscardCandidate(failed_candidate, &diagnostic));
}

void DisposeCompletesPendingExactlyOnce(Fixture *fixture, gconstpointer) {
  const auto candidate = CreateCandidate(fixture, 1);
  fixture->fake->set_bind_mode(FakePortal::BindMode::kHold);
  int completion_count = 0;
  ykd::GlobalShortcutsBindResult result;
  fixture->portal->BindCandidate(candidate,
                                 [&](ykd::GlobalShortcutsBindResult value) {
                                   ++completion_count;
                                   result = std::move(value);
                                 });
  DrainFor(20);
  fixture->portal->Dispose();
  fixture->portal->Dispose();
  g_assert_cmpint(completion_count, ==, 1);
  g_assert_true(result.status == ykd::GlobalShortcutsBindStatus::kFailed);
  g_assert_cmpstr(result.diagnostic_code.c_str(), ==, "disposed");
  fixture->fake->EmitHeldSuccess();
  DrainFor(30);
  g_assert_cmpint(completion_count, ==, 1);
}

void OwnerLossRevokesActiveGeneration(Fixture *fixture, gconstpointer) {
  const auto candidate = CreateCandidate(fixture, 7);
  g_assert_true(BindCandidate(fixture, candidate).status ==
                ykd::GlobalShortcutsBindStatus::kSuccess);
  std::string diagnostic;
  g_assert_true(fixture->portal->CommitCandidate(candidate, &diagnostic));
  fixture->events->clear();

  fixture->fake->ReleaseName();
  g_assert_true(SpinUntil([fixture] {
    bool closed = false;
    bool unavailable = false;
    for (const auto &event : *fixture->events) {
      closed = closed ||
               (event.type == ykd::GlobalShortcutsEventType::kSessionClosed &&
                event.generation == 7);
      unavailable =
          unavailable ||
          (event.type == ykd::GlobalShortcutsEventType::kAvailabilityChanged &&
           !event.capability.available);
    }
    return closed && unavailable;
  }));
}

void MalformedChangeRevokesAndClosesActiveSession(Fixture *fixture,
                                                  gconstpointer) {
  const auto candidate = CreateCandidate(fixture, 9);
  g_assert_true(BindCandidate(fixture, candidate).status ==
                ykd::GlobalShortcutsBindStatus::kSuccess);
  std::string diagnostic;
  g_assert_true(fixture->portal->CommitCandidate(candidate, &diagnostic));
  fixture->events->clear();

  fixture->fake->EmitMalformedChanged(candidate.id);
  g_assert_true(SpinUntil([fixture] {
    return !fixture->events->empty() &&
           fixture->events->back().type ==
               ykd::GlobalShortcutsEventType::kSessionClosed;
  }));
  g_assert_cmpint(fixture->events->back().generation, ==, 9);
  g_assert_cmpstr(fixture->events->back().reason.c_str(), ==,
                  "malformed_shortcuts_changed");
  g_assert_true(SpinUntil(
      [fixture] { return fixture->fake->session_close_count() >= 1; }));

  fixture->events->clear();
  fixture->fake->EmitActivated(candidate.id, "correct");
  DrainFor(20);
  g_assert_true(fixture->events->empty());
}

void WrongSignatureChangeRevokesActiveSession(Fixture *fixture, gconstpointer) {
  const auto candidate = CreateCandidate(fixture, 10);
  g_assert_true(BindCandidate(fixture, candidate).status ==
                ykd::GlobalShortcutsBindStatus::kSuccess);
  std::string diagnostic;
  g_assert_true(fixture->portal->CommitCandidate(candidate, &diagnostic));
  fixture->events->clear();

  fixture->fake->EmitWrongSignatureChanged(candidate.id);
  g_assert_true(SpinUntil([fixture] {
    return !fixture->events->empty() &&
           fixture->events->back().type ==
               ykd::GlobalShortcutsEventType::kSessionClosed;
  }));
  g_assert_cmpint(fixture->events->back().generation, ==, 10);
  g_assert_cmpstr(fixture->events->back().reason.c_str(), ==,
                  "malformed_shortcuts_changed");
}

}

int main(int argc, char **argv) {
  g_test_init(&argc, &argv, nullptr);
  g_test_add("/global-shortcuts/exact-commit", Fixture, nullptr, FixtureSetUp,
             ExactCommitDeliversOnlyActiveSession, FixtureTearDown);
  g_test_add("/global-shortcuts/partial-candidate", Fixture, nullptr,
             FixtureSetUp, PartialCandidateCannotReplaceActive,
             FixtureTearDown);
  g_test_add("/global-shortcuts/candidate-swap", Fixture, nullptr, FixtureSetUp,
             CandidateSwapRetiresPreviousSession, FixtureTearDown);
  g_test_add("/global-shortcuts/cancel", Fixture, nullptr, FixtureSetUp,
             CancelClosesRequestAndCompletesOnce, FixtureTearDown);
  g_test_add("/global-shortcuts/cancel-noncanonical", Fixture, nullptr,
             FixtureSetUp, CancelClosesLateNoncanonicalRequest,
             FixtureTearDown);
  g_test_add("/global-shortcuts/cancel-bounded-late-handle", Fixture, nullptr,
             FixtureSetUp, CancelBoundsLateHandleDiscovery, FixtureTearDown);
  g_test_add("/global-shortcuts/response-codes", Fixture, nullptr, FixtureSetUp,
             ResponseCodesRemainFailClosed, FixtureTearDown);
  g_test_add("/global-shortcuts/dispose", Fixture, nullptr, FixtureSetUp,
             DisposeCompletesPendingExactlyOnce, FixtureTearDown);
  g_test_add("/global-shortcuts/owner-loss", Fixture, nullptr, FixtureSetUp,
             OwnerLossRevokesActiveGeneration, FixtureTearDown);
  g_test_add("/global-shortcuts/malformed-change", Fixture, nullptr,
             FixtureSetUp, MalformedChangeRevokesAndClosesActiveSession,
             FixtureTearDown);
  g_test_add("/global-shortcuts/wrong-signature-change", Fixture, nullptr,
             FixtureSetUp, WrongSignatureChangeRevokesActiveSession,
             FixtureTearDown);
  return g_test_run();
}
