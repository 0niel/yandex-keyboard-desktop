#include "wayland_global_shortcuts_portal.h"

#include <algorithm>
#include <map>
#include <set>
#include <utility>

namespace ykd {
namespace {

constexpr char kPortalPath[] = "/org/freedesktop/portal/desktop";
constexpr char kGlobalShortcutsInterface[] =
    "org.freedesktop.portal.GlobalShortcuts";
constexpr char kRequestInterface[] = "org.freedesktop.portal.Request";
constexpr char kSessionInterface[] = "org.freedesktop.portal.Session";
constexpr char kPropertiesInterface[] = "org.freedesktop.DBus.Properties";

std::string MakeToken() {
  g_autofree gchar *uuid = g_uuid_string_random();
  std::string token = "ykd_";
  token += uuid;
  std::replace(token.begin(), token.end(), '-', '_');
  return token;
}

std::string SenderPathElement(GDBusConnection *connection) {
  const gchar *unique_name = g_dbus_connection_get_unique_name(connection);
  if (unique_name == nullptr || unique_name[0] != ':')
    return {};
  std::string sender(unique_name + 1);
  std::replace(sender.begin(), sender.end(), '.', '_');
  return sender;
}

std::string RequestPath(const std::string &sender, const std::string &token) {
  return "/org/freedesktop/portal/desktop/request/" + sender + "/" + token;
}

std::string SessionPath(const std::string &sender, const std::string &token) {
  return "/org/freedesktop/portal/desktop/session/" + sender + "/" + token;
}

bool IsValidDefinition(const GlobalShortcutDefinition &definition) {
  return !definition.id.empty() && !definition.description.empty() &&
         !definition.preferred_trigger.empty() &&
         g_utf8_validate(definition.id.c_str(), -1, nullptr) &&
         g_utf8_validate(definition.description.c_str(), -1, nullptr) &&
         g_utf8_validate(definition.preferred_trigger.c_str(), -1, nullptr);
}

GVariant *BuildOptions(const std::string &request_token,
                       const std::string *session_token = nullptr) {
  GVariantBuilder builder;
  g_variant_builder_init(&builder, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(&builder, "{sv}", "handle_token",
                        g_variant_new_string(request_token.c_str()));
  if (session_token != nullptr) {
    g_variant_builder_add(&builder, "{sv}", "session_handle_token",
                          g_variant_new_string(session_token->c_str()));
  }
  return g_variant_builder_end(&builder);
}

GVariant *BuildShortcutDefinitions(
    const std::vector<GlobalShortcutDefinition> &definitions) {
  GVariantBuilder shortcuts;
  g_variant_builder_init(&shortcuts, G_VARIANT_TYPE("a(sa{sv})"));
  for (const auto &definition : definitions) {
    GVariantBuilder properties;
    g_variant_builder_init(&properties, G_VARIANT_TYPE_VARDICT);
    g_variant_builder_add(&properties, "{sv}", "description",
                          g_variant_new_string(definition.description.c_str()));
    g_variant_builder_add(
        &properties, "{sv}", "preferred_trigger",
        g_variant_new_string(definition.preferred_trigger.c_str()));
    g_variant_builder_add(&shortcuts, "(s@a{sv})", definition.id.c_str(),
                          g_variant_builder_end(&properties));
  }
  return g_variant_builder_end(&shortcuts);
}

bool ReadRequiredString(GVariant *dictionary, const char *key,
                        std::string *value) {
  g_autoptr(GVariant) field =
      g_variant_lookup_value(dictionary, key, G_VARIANT_TYPE_STRING);
  if (field == nullptr)
    return false;
  const gchar *text = g_variant_get_string(field, nullptr);
  if (text == nullptr || *text == '\0' || !g_utf8_validate(text, -1, nullptr)) {
    return false;
  }
  *value = text;
  return true;
}

bool ParseBindings(GVariant *shortcuts,
                   std::vector<GlobalShortcutBinding> *bindings) {
  if (shortcuts == nullptr ||
      !g_variant_is_of_type(shortcuts, G_VARIANT_TYPE("a(sa{sv})"))) {
    return false;
  }
  std::vector<GlobalShortcutBinding> parsed;
  GVariantIter iterator;
  g_variant_iter_init(&iterator, shortcuts);
  const gchar *id = nullptr;
  GVariant *properties = nullptr;
  while (g_variant_iter_next(&iterator, "(&s@a{sv})", &id, &properties)) {
    g_autoptr(GVariant) owned_properties = properties;
    GlobalShortcutBinding binding;
    if (id == nullptr || *id == '\0' || !g_utf8_validate(id, -1, nullptr) ||
        !ReadRequiredString(owned_properties, "description",
                            &binding.description)) {
      return false;
    }
    binding.id = id;
    g_autoptr(GVariant) trigger = g_variant_lookup_value(
        owned_properties, "trigger_description", G_VARIANT_TYPE_STRING);
    if (trigger != nullptr) {
      const gchar *text = g_variant_get_string(trigger, nullptr);
      if (text == nullptr || *text == '\0' ||
          !g_utf8_validate(text, -1, nullptr)) {
        return false;
      }
      binding.has_trigger_description = true;
      binding.trigger_description = text;
    }
    parsed.push_back(std::move(binding));
  }
  *bindings = std::move(parsed);
  return true;
}

}

class WaylandGlobalShortcutsPortal::Impl final
    : public std::enable_shared_from_this<Impl> {
public:
  enum class PendingKind { kCreate, kBind };

  struct SessionState {
    std::string path;
    std::int64_t generation = 0;
    std::vector<GlobalShortcutDefinition> definitions;
    std::vector<GlobalShortcutBinding> bindings;
    bool bound = false;
  };

  struct PendingRequest {
    ~PendingRequest() {
      if (late_handle_timeout_source != 0)
        g_source_remove(late_handle_timeout_source);
      g_clear_object(&cancellable);
      if (response_results != nullptr)
        g_variant_unref(response_results);
    }

    PendingKind kind = PendingKind::kCreate;
    std::int64_t generation = 0;
    std::string expected_request_path;
    std::string request_path;
    std::string expected_session_path;
    std::string candidate_path;
    std::vector<GlobalShortcutDefinition> definitions;
    guint response_subscription = 0;
    guint late_handle_timeout_source = 0;
    GCancellable *cancellable = nullptr;
    bool method_replied = false;
    bool response_received = false;
    bool completed = false;
    guint32 response_code = 2;
    GVariant *response_results = nullptr;
    CandidateCallback candidate_callback;
    BindCallback bind_callback;
  };

  struct CapabilityOperation {
    ~CapabilityOperation() { g_clear_object(&cancellable); }
    GCancellable *cancellable = nullptr;
    bool completed = false;
    bool emit_change = false;
    std::uint64_t owner_epoch = 0;
    CapabilityCallback callback;
  };

  struct CompletionOperation {
    ~CompletionOperation() { g_clear_object(&cancellable); }
    GCancellable *cancellable = nullptr;
    bool completed = false;
    CompletionCallback callback;
  };

  Impl(GDBusConnection *connection, std::string bus_name,
       std::uint32_t late_handle_timeout_ms)
      : connection_(G_DBUS_CONNECTION(g_object_ref(connection))),
        bus_name_(std::move(bus_name)), sender_(SenderPathElement(connection)),
        late_handle_timeout_ms_(late_handle_timeout_ms) {}

  void Start() {
    auto *global_context = new std::shared_ptr<Impl>(shared_from_this());
    global_signal_subscription_ = g_dbus_connection_signal_subscribe(
        connection_, bus_name_.c_str(), kGlobalShortcutsInterface, nullptr,
        kPortalPath, nullptr, G_DBUS_SIGNAL_FLAGS_NONE, GlobalSignalCallback,
        global_context, [](gpointer data) {
          delete static_cast<std::shared_ptr<Impl> *>(data);
        });
    auto *session_context = new std::shared_ptr<Impl>(shared_from_this());
    session_signal_subscription_ = g_dbus_connection_signal_subscribe(
        connection_, bus_name_.c_str(), kSessionInterface, "Closed", nullptr,
        nullptr, G_DBUS_SIGNAL_FLAGS_NONE, SessionSignalCallback,
        session_context, [](gpointer data) {
          delete static_cast<std::shared_ptr<Impl> *>(data);
        });
    auto *owner_context = new std::shared_ptr<Impl>(shared_from_this());
    owner_watch_ = g_bus_watch_name_on_connection(
        connection_, bus_name_.c_str(), G_BUS_NAME_WATCHER_FLAGS_NONE,
        OwnerAppearedCallback, OwnerVanishedCallback, owner_context,
        [](gpointer data) {
          delete static_cast<std::shared_ptr<Impl> *>(data);
        });
  }

  ~Impl() {
    Dispose();
    g_clear_object(&connection_);
  }

  void SetEventCallback(EventCallback callback) {
    event_callback_ = std::move(callback);
  }

#ifdef YKD_ENABLE_TEST_HOOKS
  std::size_t AbandonedRequestCountForTest() const {
    return abandoned_requests_.size();
  }
#endif

  void GetCapability(CapabilityCallback callback) {
    QueryCapability(std::move(callback), true);
  }

  void CreateCandidate(std::int64_t generation,
                       std::vector<GlobalShortcutDefinition> definitions,
                       CandidateCallback callback) {
    if (disposed_ || !capability_.available || sender_.empty()) {
      callback(false, {}, "portal_unavailable");
      return;
    }
    if (pending_ != nullptr) {
      callback(false, {}, "request_in_progress");
      return;
    }
    if (generation < 1 || definitions.empty()) {
      callback(false, {}, "invalid_arguments");
      return;
    }
    std::set<std::string> ids;
    for (const auto &definition : definitions) {
      if (!IsValidDefinition(definition) || !ids.insert(definition.id).second) {
        callback(false, {}, "invalid_arguments");
        return;
      }
    }

    const std::string request_token = MakeToken();
    const std::string session_token = MakeToken();
    auto pending = std::make_shared<PendingRequest>();
    pending->kind = PendingKind::kCreate;
    pending->generation = generation;
    pending->expected_request_path = RequestPath(sender_, request_token);
    pending->request_path = pending->expected_request_path;
    pending->expected_session_path = SessionPath(sender_, session_token);
    pending->definitions = std::move(definitions);
    pending->candidate_callback = std::move(callback);

    g_autoptr(GVariant) options = BuildOptions(request_token, &session_token);
    StartRequest(pending, "CreateSession",
                 g_variant_new("(@a{sv})", g_steal_pointer(&options)));
  }

  void BindCandidate(const GlobalShortcutsCandidate &candidate,
                     BindCallback callback) {
    if (disposed_ || !capability_.available) {
      callback(FailedBind("portal_unavailable"));
      return;
    }
    if (pending_ != nullptr) {
      callback(FailedBind("request_in_progress"));
      return;
    }
    auto session = sessions_.find(candidate.id);
    if (session == sessions_.end() || candidate.id == active_session_path_ ||
        candidate.generation != session->second.generation ||
        session->second.bound) {
      callback(FailedBind("unknown_candidate"));
      return;
    }

    const std::string request_token = MakeToken();
    auto pending = std::make_shared<PendingRequest>();
    pending->kind = PendingKind::kBind;
    pending->generation = candidate.generation;
    pending->expected_request_path = RequestPath(sender_, request_token);
    pending->request_path = pending->expected_request_path;
    pending->candidate_path = candidate.id;
    pending->bind_callback = std::move(callback);

    g_autoptr(GVariant) shortcuts =
        BuildShortcutDefinitions(session->second.definitions);
    g_autoptr(GVariant) options = BuildOptions(request_token);
    StartRequest(pending, "BindShortcuts",
                 g_variant_new("(o@a(sa{sv})s@a{sv})", candidate.id.c_str(),
                               g_steal_pointer(&shortcuts), "",
                               g_steal_pointer(&options)));
  }

  bool CommitCandidate(const GlobalShortcutsCandidate &candidate,
                       std::string *diagnostic_code) {
    auto session = sessions_.find(candidate.id);
    if (disposed_ || session == sessions_.end() ||
        candidate.id == active_session_path_ ||
        candidate.generation != session->second.generation) {
      return Fail("unknown_candidate", diagnostic_code);
    }
    if (!session->second.bound || !HasExactBindings(session->second)) {
      return Fail("partial_bind", diagnostic_code);
    }

    const std::string previous = active_session_path_;
    active_session_path_ = candidate.id;
    if (!previous.empty() && previous != active_session_path_) {
      CloseRemoteObject(previous, kSessionInterface);
      sessions_.erase(previous);
    }
    return true;
  }

  bool DiscardCandidate(const GlobalShortcutsCandidate &candidate,
                        std::string *diagnostic_code) {
    auto session = sessions_.find(candidate.id);
    if (disposed_ || session == sessions_.end() ||
        candidate.id == active_session_path_ ||
        candidate.generation != session->second.generation) {
      return Fail("unknown_candidate", diagnostic_code);
    }
    CloseRemoteObject(candidate.id, kSessionInterface);
    sessions_.erase(session);
    return true;
  }

  void CancelPendingRequest() { CancelPending("cancelled", true); }

  void CloseSessions() {
    CancelPending("cancelled", true);
    for (const auto &entry : sessions_) {
      CloseRemoteObject(entry.first, kSessionInterface);
    }
    sessions_.clear();
    active_session_path_.clear();
  }

  void ConfigureShortcuts(CompletionCallback callback) {
    if (disposed_ || !capability_.available || capability_.version < 2 ||
        active_session_path_.empty()) {
      callback(false, "configure_unavailable");
      return;
    }
    auto operation = std::make_shared<CompletionOperation>();
    operation->cancellable = g_cancellable_new();
    operation->callback = std::move(callback);
    completion_operations_.push_back(operation);
    auto *context = new CompletionContext{shared_from_this(), operation};
    GVariantBuilder options;
    g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
    g_dbus_connection_call(
        connection_, bus_name_.c_str(), kPortalPath, kGlobalShortcutsInterface,
        "ConfigureShortcuts",
        g_variant_new("(os@a{sv})", active_session_path_.c_str(), "",
                      g_variant_builder_end(&options)),
        G_VARIANT_TYPE_UNIT, G_DBUS_CALL_FLAGS_NONE, -1, operation->cancellable,
        ConfigureCallCallback, context);
  }

  void Dispose() {
    if (disposed_)
      return;
    disposed_ = true;
    CancelPending("disposed", false);
    for (const auto &entry : sessions_) {
      CloseRemoteObject(entry.first, kSessionInterface);
    }
    sessions_.clear();
    active_session_path_.clear();

    for (const auto &operation : capability_operations_) {
      if (!operation->completed) {
        operation->completed = true;
        g_cancellable_cancel(operation->cancellable);
        if (operation->callback)
          operation->callback({});
      }
    }
    capability_operations_.clear();
    for (const auto &operation : completion_operations_) {
      if (!operation->completed) {
        operation->completed = true;
        g_cancellable_cancel(operation->cancellable);
        if (operation->callback)
          operation->callback(false, "disposed");
      }
    }
    completion_operations_.clear();
    for (const auto &request : abandoned_requests_) {
      StopLateHandleTimeout(request);
      g_cancellable_cancel(request->cancellable);
    }
    abandoned_requests_.clear();

    if (owner_watch_ != 0) {
      g_bus_unwatch_name(owner_watch_);
      owner_watch_ = 0;
    }
    if (global_signal_subscription_ != 0) {
      g_dbus_connection_signal_unsubscribe(connection_,
                                           global_signal_subscription_);
      global_signal_subscription_ = 0;
    }
    if (session_signal_subscription_ != 0) {
      g_dbus_connection_signal_unsubscribe(connection_,
                                           session_signal_subscription_);
      session_signal_subscription_ = 0;
    }
    event_callback_ = nullptr;
  }

private:
  struct PendingSignalContext {
    std::shared_ptr<Impl> impl;
    std::shared_ptr<PendingRequest> pending;
  };

  struct PendingCallContext {
    std::shared_ptr<Impl> impl;
    std::shared_ptr<PendingRequest> pending;
  };

  struct AbandonedRequestContext {
    std::shared_ptr<Impl> impl;
    std::shared_ptr<PendingRequest> pending;
  };

  struct CapabilityContext {
    std::shared_ptr<Impl> impl;
    std::shared_ptr<CapabilityOperation> operation;
  };

  struct CompletionContext {
    std::shared_ptr<Impl> impl;
    std::shared_ptr<CompletionOperation> operation;
  };

  static GlobalShortcutsBindResult FailedBind(const std::string &diagnostic) {
    GlobalShortcutsBindResult result;
    result.status = GlobalShortcutsBindStatus::kFailed;
    result.diagnostic_code = diagnostic;
    return result;
  }

  static bool Fail(const char *diagnostic, std::string *output) {
    if (output != nullptr)
      *output = diagnostic;
    return false;
  }

  void QueryCapability(CapabilityCallback callback, bool emit_change) {
    if (disposed_) {
      if (callback)
        callback({});
      return;
    }
    auto operation = std::make_shared<CapabilityOperation>();
    operation->cancellable = g_cancellable_new();
    operation->callback = std::move(callback);
    operation->emit_change = emit_change;
    operation->owner_epoch = owner_epoch_;
    capability_operations_.push_back(operation);
    auto *context = new CapabilityContext{shared_from_this(), operation};
    g_dbus_connection_call(
        connection_, bus_name_.c_str(), kPortalPath, kPropertiesInterface,
        "Get", g_variant_new("(ss)", kGlobalShortcutsInterface, "version"),
        G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NONE, -1,
        operation->cancellable, CapabilityCallCallback, context);
  }

  void FinishCapability(const std::shared_ptr<CapabilityOperation> &operation,
                        GlobalShortcutsCapability capability) {
    if (operation->completed)
      return;
    operation->completed = true;
    capability_operations_.erase(std::remove(capability_operations_.begin(),
                                             capability_operations_.end(),
                                             operation),
                                 capability_operations_.end());
    if (!disposed_ && operation->emit_change)
      UpdateCapability(capability);
    if (operation->callback)
      operation->callback(capability);
  }

  void UpdateCapability(GlobalShortcutsCapability capability) {
    const bool changed = !capability_known_ ||
                         capability.available != capability_.available ||
                         capability.version != capability_.version;
    capability_known_ = true;
    capability_ = capability;
    if (!changed || disposed_ || !event_callback_)
      return;
    GlobalShortcutsEvent event;
    event.type = GlobalShortcutsEventType::kAvailabilityChanged;
    event.generation = ActiveGeneration();
    event.capability = capability;
    event_callback_(event);
  }

  static void CapabilityCallCallback(GObject *source, GAsyncResult *result,
                                     gpointer user_data) {
    std::unique_ptr<CapabilityContext> context(
        static_cast<CapabilityContext *>(user_data));
    auto impl = context->impl;
    auto operation = context->operation;
    if (operation->completed)
      return;
    g_autoptr(GError) error = nullptr;
    g_autoptr(GVariant) reply = g_dbus_connection_call_finish(
        G_DBUS_CONNECTION(source), result, &error);
    GlobalShortcutsCapability capability;
    if (reply != nullptr) {
      GVariant *version = nullptr;
      g_variant_get(reply, "(@v)", &version);
      g_autoptr(GVariant) owned_version = version;
      g_autoptr(GVariant) unboxed = g_variant_get_variant(owned_version);
      if (g_variant_is_of_type(unboxed, G_VARIANT_TYPE_UINT32)) {
        capability.version = g_variant_get_uint32(unboxed);
        capability.available = capability.version > 0;
      }
    }
    if (operation->owner_epoch != impl->owner_epoch_) {
      capability = {};
      operation->emit_change = false;
    }
    impl->FinishCapability(operation, capability);
  }

  void StartRequest(const std::shared_ptr<PendingRequest> &pending,
                    const char *method, GVariant *parameters) {
    pending_ = pending;
    pending->cancellable = g_cancellable_new();
    SubscribeToResponse(pending, pending->expected_request_path);
    auto *context = new PendingCallContext{shared_from_this(), pending};
    g_dbus_connection_call(
        connection_, bus_name_.c_str(), kPortalPath, kGlobalShortcutsInterface,
        method, parameters, G_VARIANT_TYPE("(o)"), G_DBUS_CALL_FLAGS_NONE, -1,
        pending->cancellable, PortalMethodCallCallback, context);
  }

  void SubscribeToResponse(const std::shared_ptr<PendingRequest> &pending,
                           const std::string &request_path) {
    if (pending->response_subscription != 0) {
      g_dbus_connection_signal_unsubscribe(connection_,
                                           pending->response_subscription);
      pending->response_subscription = 0;
    }
    auto *context = new PendingSignalContext{shared_from_this(), pending};
    pending->response_subscription = g_dbus_connection_signal_subscribe(
        connection_, bus_name_.c_str(), kRequestInterface, "Response",
        request_path.c_str(), nullptr, G_DBUS_SIGNAL_FLAGS_NONE,
        RequestResponseCallback, context, [](gpointer data) {
          delete static_cast<PendingSignalContext *>(data);
        });
  }

  static void PortalMethodCallCallback(GObject *source, GAsyncResult *result,
                                       gpointer user_data) {
    std::unique_ptr<PendingCallContext> context(
        static_cast<PendingCallContext *>(user_data));
    auto impl = context->impl;
    auto pending = context->pending;
    g_autoptr(GError) error = nullptr;
    g_autoptr(GVariant) reply = g_dbus_connection_call_finish(
        G_DBUS_CONNECTION(source), result, &error);
    if (pending->completed) {
      impl->StopLateHandleTimeout(pending);
      if (reply != nullptr) {
        const gchar *returned_path = nullptr;
        g_variant_get(reply, "(&o)", &returned_path);
        if (returned_path != nullptr &&
            g_variant_is_object_path(returned_path)) {
          impl->CloseRemoteObject(returned_path, kRequestInterface);
        }
      }
      impl->abandoned_requests_.erase(
          std::remove(impl->abandoned_requests_.begin(),
                      impl->abandoned_requests_.end(), pending),
          impl->abandoned_requests_.end());
      return;
    }
    if (reply == nullptr) {
      impl->FinishPendingFailure(
          pending,
          g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED)
              ? "cancelled"
              : "portal_call_failed",
          g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED));
      return;
    }
    const gchar *returned_path = nullptr;
    g_variant_get(reply, "(&o)", &returned_path);
    if (returned_path == nullptr || !g_variant_is_object_path(returned_path)) {
      impl->FinishPendingFailure(pending, "malformed_response", false);
      return;
    }
    if (pending->request_path != returned_path) {
      pending->request_path = returned_path;
      pending->response_received = false;
      if (pending->response_results != nullptr) {
        g_variant_unref(pending->response_results);
        pending->response_results = nullptr;
      }
      impl->SubscribeToResponse(pending, pending->request_path);
    }
    pending->method_replied = true;
    impl->TryFinishPending(pending);
  }

  static void RequestResponseCallback(GDBusConnection *, const gchar *,
                                      const gchar *, const gchar *,
                                      const gchar *, GVariant *parameters,
                                      gpointer user_data) {
    auto *context = static_cast<PendingSignalContext *>(user_data);
    auto impl = context->impl;
    auto pending = context->pending;
    if (pending->completed || pending->response_received ||
        !g_variant_is_of_type(parameters, G_VARIANT_TYPE("(ua{sv})"))) {
      return;
    }
    GVariant *results = nullptr;
    g_variant_get(parameters, "(u@a{sv})", &pending->response_code, &results);
    pending->response_results = results;
    pending->response_received = true;
    impl->TryFinishPending(pending);
  }

  void TryFinishPending(const std::shared_ptr<PendingRequest> &pending) {
    if (pending->completed || !pending->method_replied ||
        !pending->response_received) {
      return;
    }
    if (pending->response_code > 2 || pending->response_results == nullptr) {
      FinishPendingFailure(pending, "malformed_response", false);
      return;
    }
    if (pending->kind == PendingKind::kCreate) {
      FinishCreate(pending);
    } else {
      FinishBind(pending);
    }
  }

  void FinishCreate(const std::shared_ptr<PendingRequest> &pending) {
    if (pending->response_code == 1) {
      FinishPendingFailure(pending, "cancelled", true);
      return;
    }
    if (pending->response_code == 2) {
      FinishPendingFailure(pending, "create_failed", false);
      return;
    }
    std::string session_path;
    if (!ReadRequiredString(pending->response_results, "session_handle",
                            &session_path) ||
        !g_variant_is_object_path(session_path.c_str()) ||
        session_path != pending->expected_session_path ||
        sessions_.find(session_path) != sessions_.end()) {
      if (g_variant_is_object_path(session_path.c_str())) {
        CloseRemoteObject(session_path, kSessionInterface);
      }
      FinishPendingFailure(pending, "malformed_response", false);
      return;
    }

    SessionState state;
    state.path = session_path;
    state.generation = pending->generation;
    state.definitions = pending->definitions;
    sessions_.emplace(session_path, std::move(state));
    GlobalShortcutsCandidate candidate{session_path, pending->generation};
    auto callback = pending->candidate_callback;
    CompletePending(pending);
    if (callback)
      callback(true, std::move(candidate), "");
  }

  void FinishBind(const std::shared_ptr<PendingRequest> &pending) {
    GlobalShortcutsBindResult result;
    if (pending->response_code == 1) {
      result.status = GlobalShortcutsBindStatus::kCancelled;
      result.diagnostic_code = "cancelled";
    } else if (pending->response_code == 2) {
      result.status = GlobalShortcutsBindStatus::kFailed;
      result.diagnostic_code = "bind_failed";
    } else {
      g_autoptr(GVariant) shortcuts = g_variant_lookup_value(
          pending->response_results, "shortcuts", G_VARIANT_TYPE("a(sa{sv})"));
      auto session = sessions_.find(pending->candidate_path);
      if (session == sessions_.end() ||
          session->second.generation != pending->generation ||
          !ParseBindings(shortcuts, &result.bindings)) {
        result.status = GlobalShortcutsBindStatus::kFailed;
        result.diagnostic_code = "malformed_response";
      } else {
        result.status = GlobalShortcutsBindStatus::kSuccess;
        session->second.bindings = result.bindings;
        session->second.bound = true;
      }
    }
    auto callback = pending->bind_callback;
    CompletePending(pending);
    if (callback)
      callback(std::move(result));
  }

  void FinishPendingFailure(const std::shared_ptr<PendingRequest> &pending,
                            const std::string &diagnostic, bool cancelled) {
    if (pending->completed)
      return;
    if (pending->kind == PendingKind::kCreate) {
      auto callback = pending->candidate_callback;
      CompletePending(pending);
      if (callback)
        callback(false, {}, diagnostic);
      return;
    }
    auto callback = pending->bind_callback;
    CompletePending(pending);
    if (callback) {
      GlobalShortcutsBindResult result;
      result.status = cancelled ? GlobalShortcutsBindStatus::kCancelled
                                : GlobalShortcutsBindStatus::kFailed;
      result.diagnostic_code = diagnostic;
      callback(std::move(result));
    }
  }

  void CompletePending(const std::shared_ptr<PendingRequest> &pending) {
    if (pending->completed)
      return;
    pending->completed = true;
    if (pending->response_subscription != 0) {
      const guint subscription = pending->response_subscription;
      pending->response_subscription = 0;
      g_dbus_connection_signal_unsubscribe(connection_, subscription);
    }
    if (pending_ == pending)
      pending_.reset();
  }

  void CancelPending(const std::string &diagnostic, bool cancelled) {
    auto pending = pending_;
    if (pending == nullptr || pending->completed)
      return;
    CloseRemoteObject(pending->request_path, kRequestInterface);
    if (!pending->method_replied) {
      abandoned_requests_.push_back(pending);
      auto *context = new AbandonedRequestContext{shared_from_this(), pending};
      pending->late_handle_timeout_source = g_timeout_add_full(
          G_PRIORITY_DEFAULT, late_handle_timeout_ms_,
          AbandonedRequestTimeoutCallback, context, [](gpointer data) {
            delete static_cast<AbandonedRequestContext *>(data);
          });
      FinishPendingFailure(pending, diagnostic, cancelled);
      return;
    }
    g_cancellable_cancel(pending->cancellable);
    FinishPendingFailure(pending, diagnostic, cancelled);
  }

  static gboolean AbandonedRequestTimeoutCallback(gpointer user_data) {
    auto *context = static_cast<AbandonedRequestContext *>(user_data);
    auto impl = context->impl;
    auto pending = context->pending;
    pending->late_handle_timeout_source = 0;
    if (!pending->method_replied)
      g_cancellable_cancel(pending->cancellable);
    impl->abandoned_requests_.erase(
        std::remove(impl->abandoned_requests_.begin(),
                    impl->abandoned_requests_.end(), pending),
        impl->abandoned_requests_.end());
    return G_SOURCE_REMOVE;
  }

  void StopLateHandleTimeout(const std::shared_ptr<PendingRequest> &pending) {
    if (pending->late_handle_timeout_source == 0)
      return;
    const guint source = pending->late_handle_timeout_source;
    pending->late_handle_timeout_source = 0;
    g_source_remove(source);
  }

  bool HasExactBindings(const SessionState &session) const {
    if (session.bindings.size() != session.definitions.size())
      return false;
    std::set<std::string> expected;
    for (const auto &definition : session.definitions) {
      expected.insert(definition.id);
    }
    std::set<std::string> actual;
    for (const auto &binding : session.bindings) {
      if (!actual.insert(binding.id).second ||
          expected.find(binding.id) == expected.end()) {
        return false;
      }
    }
    return actual == expected;
  }

  void CloseRemoteObject(const std::string &path, const char *interface) {
    if (connection_ == nullptr || path.empty() ||
        !g_variant_is_object_path(path.c_str())) {
      return;
    }
    g_dbus_connection_call(connection_, bus_name_.c_str(), path.c_str(),
                           interface, "Close", nullptr, G_VARIANT_TYPE_UNIT,
                           G_DBUS_CALL_FLAGS_NO_AUTO_START, -1, nullptr,
                           nullptr, nullptr);
  }

  void RevokeActiveSession(const std::string &reason) {
    auto session = sessions_.find(active_session_path_);
    if (session == sessions_.end())
      return;
    const std::string path = session->first;
    const std::int64_t generation = session->second.generation;
    active_session_path_.clear();
    sessions_.erase(session);
    CloseRemoteObject(path, kSessionInterface);
    if (event_callback_) {
      GlobalShortcutsEvent event;
      event.type = GlobalShortcutsEventType::kSessionClosed;
      event.generation = generation;
      event.reason = reason;
      event_callback_(event);
    }
  }

  static void ConfigureCallCallback(GObject *source, GAsyncResult *result,
                                    gpointer user_data) {
    std::unique_ptr<CompletionContext> context(
        static_cast<CompletionContext *>(user_data));
    auto impl = context->impl;
    auto operation = context->operation;
    if (operation->completed)
      return;
    g_autoptr(GError) error = nullptr;
    g_autoptr(GVariant) reply = g_dbus_connection_call_finish(
        G_DBUS_CONNECTION(source), result, &error);
    impl->FinishCompletion(operation, reply != nullptr,
                           reply != nullptr ? "" : "configure_failed");
  }

  void FinishCompletion(const std::shared_ptr<CompletionOperation> &operation,
                        bool success, const std::string &diagnostic) {
    if (operation->completed)
      return;
    operation->completed = true;
    completion_operations_.erase(std::remove(completion_operations_.begin(),
                                             completion_operations_.end(),
                                             operation),
                                 completion_operations_.end());
    auto callback = operation->callback;
    if (callback)
      callback(success, diagnostic);
  }

  static void OwnerAppearedCallback(GDBusConnection *, const gchar *,
                                    const gchar *, gpointer user_data) {
    auto keep_alive = *static_cast<std::shared_ptr<Impl> *>(user_data);
    auto *self = keep_alive.get();
    if (self->disposed_)
      return;
    self->QueryCapability(nullptr, true);
  }

  static void OwnerVanishedCallback(GDBusConnection *, const gchar *,
                                    gpointer user_data) {
    auto keep_alive = *static_cast<std::shared_ptr<Impl> *>(user_data);
    auto *self = keep_alive.get();
    if (self->disposed_)
      return;
    const std::int64_t generation = self->ActiveGeneration();
    const bool had_active = !self->active_session_path_.empty();
    ++self->owner_epoch_;
    self->CancelPending("portal_unavailable", false);
    const auto capability_operations = self->capability_operations_;
    for (const auto &operation : capability_operations) {
      if (!operation->completed) {
        g_cancellable_cancel(operation->cancellable);
        self->FinishCapability(operation, {});
      }
    }
    const auto completion_operations = self->completion_operations_;
    for (const auto &operation : completion_operations) {
      if (!operation->completed) {
        g_cancellable_cancel(operation->cancellable);
        self->FinishCompletion(operation, false, "portal_unavailable");
      }
    }
    self->sessions_.clear();
    self->active_session_path_.clear();
    if (had_active && self->event_callback_) {
      GlobalShortcutsEvent closed;
      closed.type = GlobalShortcutsEventType::kSessionClosed;
      closed.generation = generation;
      closed.reason = "portal_owner_lost";
      self->event_callback_(closed);
    }
    self->UpdateCapability({});
  }

  static void GlobalSignalCallback(GDBusConnection *, const gchar *,
                                   const gchar *, const gchar *,
                                   const gchar *signal_name,
                                   GVariant *parameters, gpointer user_data) {
    auto keep_alive = *static_cast<std::shared_ptr<Impl> *>(user_data);
    auto *self = keep_alive.get();
    if (self->disposed_ || self->event_callback_ == nullptr)
      return;
    if (g_strcmp0(signal_name, "Activated") == 0 ||
        g_strcmp0(signal_name, "Deactivated") == 0) {
      if (!g_variant_is_of_type(parameters, G_VARIANT_TYPE("(osta{sv})"))) {
        return;
      }
      const gchar *session_path = nullptr;
      const gchar *shortcut_id = nullptr;
      guint64 timestamp = 0;
      GVariant *options = nullptr;
      g_variant_get(parameters, "(&o&st@a{sv})", &session_path, &shortcut_id,
                    &timestamp, &options);
      g_autoptr(GVariant) owned_options = options;
      if (session_path == nullptr ||
          self->active_session_path_ != session_path ||
          shortcut_id == nullptr || *shortcut_id == '\0') {
        return;
      }
      const auto session = self->sessions_.find(session_path);
      if (session == self->sessions_.end())
        return;
      const bool known_shortcut = std::any_of(
          session->second.bindings.begin(), session->second.bindings.end(),
          [shortcut_id](const GlobalShortcutBinding &binding) {
            return binding.id == shortcut_id;
          });
      if (!known_shortcut)
        return;
      GlobalShortcutsEvent event;
      event.type = g_strcmp0(signal_name, "Activated") == 0
                       ? GlobalShortcutsEventType::kActivated
                       : GlobalShortcutsEventType::kDeactivated;
      event.generation = session->second.generation;
      event.shortcut_id = shortcut_id;
      event.timestamp = timestamp;
      g_autoptr(GVariant) activation_token = g_variant_lookup_value(
          owned_options, "activation_token", G_VARIANT_TYPE_STRING);
      if (activation_token != nullptr) {
        event.activation_token =
            g_variant_get_string(activation_token, nullptr);
      }
      self->event_callback_(event);
      return;
    }
    if (g_strcmp0(signal_name, "ShortcutsChanged") != 0) {
      return;
    }
    if (!g_variant_is_of_type(parameters, G_VARIANT_TYPE("(oa(sa{sv}))"))) {
      if (!self->active_session_path_.empty())
        self->RevokeActiveSession("malformed_shortcuts_changed");
      return;
    }
    const gchar *session_path = nullptr;
    GVariant *shortcuts = nullptr;
    g_variant_get(parameters, "(&o@a(sa{sv}))", &session_path, &shortcuts);
    g_autoptr(GVariant) owned_shortcuts = shortcuts;
    if (session_path == nullptr || self->active_session_path_ != session_path) {
      return;
    }
    auto session = self->sessions_.find(session_path);
    if (session == self->sessions_.end())
      return;
    std::vector<GlobalShortcutBinding> bindings;
    if (!ParseBindings(owned_shortcuts, &bindings)) {
      self->RevokeActiveSession("malformed_shortcuts_changed");
      return;
    }
    SessionState changed = session->second;
    changed.bindings = bindings;
    if (!self->HasExactBindings(changed)) {
      self->RevokeActiveSession("partial_shortcuts_changed");
      return;
    }
    session->second.bindings = bindings;
    GlobalShortcutsEvent event;
    event.type = GlobalShortcutsEventType::kShortcutsChanged;
    event.generation = session->second.generation;
    event.bindings = std::move(bindings);
    self->event_callback_(event);
  }

  static void SessionSignalCallback(GDBusConnection *, const gchar *,
                                    const gchar *object_path, const gchar *,
                                    const gchar *, GVariant *parameters,
                                    gpointer user_data) {
    auto keep_alive = *static_cast<std::shared_ptr<Impl> *>(user_data);
    auto *self = keep_alive.get();
    if (self->disposed_ || object_path == nullptr ||
        !g_variant_is_of_type(parameters, G_VARIANT_TYPE("(a{sv})"))) {
      return;
    }
    auto session = self->sessions_.find(object_path);
    if (session == self->sessions_.end())
      return;
    const bool active = self->active_session_path_ == object_path;
    const std::int64_t generation = session->second.generation;
    std::string reason = "portal_closed";
    GVariant *details = nullptr;
    g_variant_get(parameters, "(@a{sv})", &details);
    g_autoptr(GVariant) owned_details = details;
    g_autoptr(GVariant) reason_value =
        g_variant_lookup_value(owned_details, "reason", G_VARIANT_TYPE_STRING);
    if (reason_value != nullptr) {
      const gchar *text = g_variant_get_string(reason_value, nullptr);
      if (text != nullptr && *text != '\0')
        reason = text;
    }
    self->sessions_.erase(session);
    if (!active) {
      auto pending = self->pending_;
      if (pending != nullptr && pending->kind == PendingKind::kBind &&
          pending->candidate_path == object_path) {
        self->FinishPendingFailure(pending, "session_closed", false);
      }
      return;
    }
    self->active_session_path_.clear();
    if (self->event_callback_) {
      GlobalShortcutsEvent event;
      event.type = GlobalShortcutsEventType::kSessionClosed;
      event.generation = generation;
      event.reason = reason;
      self->event_callback_(event);
    }
  }

  std::int64_t ActiveGeneration() const {
    const auto active = sessions_.find(active_session_path_);
    return active == sessions_.end() ? 0 : active->second.generation;
  }

  GDBusConnection *connection_ = nullptr;
  std::string bus_name_;
  std::string sender_;
  bool disposed_ = false;
  bool capability_known_ = false;
  std::uint64_t owner_epoch_ = 0;
  GlobalShortcutsCapability capability_;
  EventCallback event_callback_;
  guint owner_watch_ = 0;
  guint global_signal_subscription_ = 0;
  guint session_signal_subscription_ = 0;
  std::map<std::string, SessionState> sessions_;
  std::string active_session_path_;
  std::uint32_t late_handle_timeout_ms_ = 10000;
  std::shared_ptr<PendingRequest> pending_;
  std::vector<std::shared_ptr<CapabilityOperation>> capability_operations_;
  std::vector<std::shared_ptr<CompletionOperation>> completion_operations_;
  std::vector<std::shared_ptr<PendingRequest>> abandoned_requests_;
};

WaylandGlobalShortcutsPortal::WaylandGlobalShortcutsPortal(
    GDBusConnection *connection, std::string bus_name,
    std::uint32_t late_handle_timeout_ms)
    : impl_(std::make_shared<Impl>(connection, std::move(bus_name),
                                   late_handle_timeout_ms)) {
  impl_->Start();
}

WaylandGlobalShortcutsPortal::~WaylandGlobalShortcutsPortal() { Dispose(); }

void WaylandGlobalShortcutsPortal::SetEventCallback(EventCallback callback) {
  impl_->SetEventCallback(std::move(callback));
}

void WaylandGlobalShortcutsPortal::GetCapability(CapabilityCallback callback) {
  impl_->GetCapability(std::move(callback));
}

void WaylandGlobalShortcutsPortal::CreateCandidate(
    std::int64_t generation, std::vector<GlobalShortcutDefinition> shortcuts,
    CandidateCallback callback) {
  impl_->CreateCandidate(generation, std::move(shortcuts), std::move(callback));
}

void WaylandGlobalShortcutsPortal::BindCandidate(
    const GlobalShortcutsCandidate &candidate, BindCallback callback) {
  impl_->BindCandidate(candidate, std::move(callback));
}

bool WaylandGlobalShortcutsPortal::CommitCandidate(
    const GlobalShortcutsCandidate &candidate, std::string *diagnostic_code) {
  return impl_->CommitCandidate(candidate, diagnostic_code);
}

bool WaylandGlobalShortcutsPortal::DiscardCandidate(
    const GlobalShortcutsCandidate &candidate, std::string *diagnostic_code) {
  return impl_->DiscardCandidate(candidate, diagnostic_code);
}

void WaylandGlobalShortcutsPortal::CancelPendingRequest() {
  impl_->CancelPendingRequest();
}

void WaylandGlobalShortcutsPortal::CloseSessions() { impl_->CloseSessions(); }

void WaylandGlobalShortcutsPortal::ConfigureShortcuts(
    CompletionCallback callback) {
  impl_->ConfigureShortcuts(std::move(callback));
}

void WaylandGlobalShortcutsPortal::Dispose() {
  if (impl_ != nullptr)
    impl_->Dispose();
}

#ifdef YKD_ENABLE_TEST_HOOKS
std::size_t WaylandGlobalShortcutsPortal::AbandonedRequestCountForTest() const {
  return impl_->AbandonedRequestCountForTest();
}
#endif

}
