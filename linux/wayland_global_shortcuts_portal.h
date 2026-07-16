#ifndef YKD_WAYLAND_GLOBAL_SHORTCUTS_PORTAL_H_
#define YKD_WAYLAND_GLOBAL_SHORTCUTS_PORTAL_H_

#include <gio/gio.h>

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace ykd {

struct GlobalShortcutsCapability {
  bool available = false;
  std::uint32_t version = 0;
};

struct GlobalShortcutDefinition {
  std::string id;
  std::string description;
  std::string preferred_trigger;
};

struct GlobalShortcutBinding {
  std::string id;
  std::string description;
  bool has_trigger_description = false;
  std::string trigger_description;
};

struct GlobalShortcutsCandidate {
  std::string id;
  std::int64_t generation = 0;
};

enum class GlobalShortcutsBindStatus {
  kSuccess,
  kCancelled,
  kFailed,
};

struct GlobalShortcutsBindResult {
  GlobalShortcutsBindStatus status = GlobalShortcutsBindStatus::kFailed;
  std::vector<GlobalShortcutBinding> bindings;
  std::string diagnostic_code;
};

enum class GlobalShortcutsEventType {
  kActivated,
  kDeactivated,
  kShortcutsChanged,
  kSessionClosed,
  kAvailabilityChanged,
};

struct GlobalShortcutsEvent {
  GlobalShortcutsEventType type =
      GlobalShortcutsEventType::kAvailabilityChanged;
  std::int64_t generation = 0;
  std::string shortcut_id;
  std::uint64_t timestamp = 0;
  std::string activation_token;
  std::vector<GlobalShortcutBinding> bindings;
  std::string reason;
  GlobalShortcutsCapability capability;
};

class WaylandGlobalShortcutsPortal final {
public:
  using CapabilityCallback =
      std::function<void(GlobalShortcutsCapability capability)>;
  using CandidateCallback =
      std::function<void(bool success, GlobalShortcutsCandidate candidate,
                         const std::string &diagnostic_code)>;
  using BindCallback = std::function<void(GlobalShortcutsBindResult result)>;
  using CompletionCallback =
      std::function<void(bool success, const std::string &diagnostic_code)>;
  using EventCallback = std::function<void(const GlobalShortcutsEvent &event)>;

  explicit WaylandGlobalShortcutsPortal(
      GDBusConnection *connection,
      std::string bus_name = "org.freedesktop.portal.Desktop",
      std::uint32_t late_handle_timeout_ms = 10000);
  ~WaylandGlobalShortcutsPortal();

  WaylandGlobalShortcutsPortal(const WaylandGlobalShortcutsPortal &) = delete;
  WaylandGlobalShortcutsPortal &
  operator=(const WaylandGlobalShortcutsPortal &) = delete;

  void SetEventCallback(EventCallback callback);
  void GetCapability(CapabilityCallback callback);

  void CreateCandidate(std::int64_t generation,
                       std::vector<GlobalShortcutDefinition> shortcuts,
                       CandidateCallback callback);
  void BindCandidate(const GlobalShortcutsCandidate &candidate,
                     BindCallback callback);

  bool CommitCandidate(const GlobalShortcutsCandidate &candidate,
                       std::string *diagnostic_code);
  bool DiscardCandidate(const GlobalShortcutsCandidate &candidate,
                        std::string *diagnostic_code);

  void CancelPendingRequest();
  void CloseSessions();
  void ConfigureShortcuts(CompletionCallback callback);
  void Dispose();

#ifdef YKD_ENABLE_TEST_HOOKS
  std::size_t AbandonedRequestCountForTest() const;
#endif

private:
  class Impl;
  std::shared_ptr<Impl> impl_;
};

}

#endif
