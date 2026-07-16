#ifndef RUNNER_X11_CLIPBOARD_READER_H_
#define RUNNER_X11_CLIPBOARD_READER_H_

#include <X11/Xlib.h>
#include <X11/extensions/Xfixes.h>
#include <glib.h>

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace ykd {

void InstallX11ErrorDispatcher();

enum class X11ClipboardReadStatus {
  kOk,
  kUnavailable,
  kOwnerChanged,
  kTimeout,
  kTooManyTargets,
  kTooLarge,
  kUnsupportedFormat,
  kConversionRejected,
  kProtocolError,
};

struct X11ClipboardPayload final {
  Atom target = None;
  Atom type = None;
  int format = 0;
  std::vector<std::uint8_t> bytes;
};

struct X11ClipboardSnapshot final {
  Window owner = None;
  std::vector<X11ClipboardPayload> payloads;
};

struct X11ClipboardText final {
  Window owner = None;
  std::string text;
};

class X11ClipboardReader final {
public:
  X11ClipboardReader();
  ~X11ClipboardReader();

  X11ClipboardReader(const X11ClipboardReader &) = delete;
  X11ClipboardReader &operator=(const X11ClipboardReader &) = delete;

  bool Start(const char *display_name);
  void Stop();
  bool active() const {
    return display_ != nullptr && !connection_failed_ &&
           !authoritative_window_destroyed_;
  }
  Window owner_window() const { return request_window_; }
  std::int64_t revision() const { return selection_revision_; }
  Window observed_selection_owner() const { return observed_selection_owner_; }
  Time observed_selection_timestamp() const {
    return observed_selection_timestamp_;
  }
  void Drain();
  bool owns_clipboard() const;

  X11ClipboardReadStatus Capture(std::size_t max_bytes, std::size_t max_targets,
                                 std::chrono::milliseconds timeout,
                                 X11ClipboardSnapshot *snapshot);

  X11ClipboardReadStatus ReadUtf8(std::size_t max_bytes,
                                  std::size_t max_targets,
                                  std::chrono::milliseconds timeout,
                                  X11ClipboardText *text);

  bool AcquireTextIfState(std::int64_t expected_revision, Window expected_owner,
                          Time expected_selection_timestamp,
                          const std::string &text);
  bool AcquireSnapshotIfState(std::int64_t expected_revision,
                              Window expected_owner,
                              Time expected_selection_timestamp,
                              const X11ClipboardSnapshot &snapshot);

private:
  friend class X11ClipboardReaderTestPeer;

  using Deadline = std::chrono::steady_clock::time_point;
  using ClipboardOffer =
      std::shared_ptr<const std::vector<X11ClipboardPayload>>;

  struct OutgoingTransfer final {
    Window requestor = None;
    Atom property = None;
    Atom target = None;
    std::size_t offset = 0;
    ClipboardOffer offer;
    Deadline last_progress;
  };

  static gboolean OnX11Input(GIOChannel *channel, GIOCondition condition,
                             gpointer user_data);

  X11ClipboardReadStatus RequestTarget(Atom target, std::size_t max_bytes,
                                       Deadline deadline,
                                       X11ClipboardPayload *payload);
  X11ClipboardReadStatus ReadProperty(Window requestor, Atom property,
                                      std::size_t max_bytes, Deadline deadline,
                                      X11ClipboardPayload *payload);
  X11ClipboardReadStatus ReadIncrementalProperty(Window requestor,
                                                 Atom property,
                                                 std::size_t max_bytes,
                                                 Deadline deadline,
                                                 X11ClipboardPayload *payload);
  bool WaitForSelectionNotify(Window requestor, Atom target, Atom property,
                              Deadline deadline,
                              XSelectionEvent *selection_event);
  bool WaitForProperty(Window requestor, Atom property, Deadline deadline,
                       XPropertyEvent *property_event);
  bool WaitForInput(Deadline deadline);
  bool NormalizeProperty(int format, unsigned long item_count,
                         const unsigned char *source, std::size_t max_bytes,
                         std::vector<std::uint8_t> *destination) const;
  std::vector<Atom> DecodeAtoms(const X11ClipboardPayload &payload) const;
  bool IsSyntheticTarget(Atom target) const;
  void DrainEvents();
  void HandleEvent(const XEvent &event);
  void HandleSelectionRequest(const XSelectionRequestEvent &request);
  void HandlePropertyDelete(const XPropertyEvent &event);
  void HandleRequestorDestroyed(Window requestor);
  void PruneOutgoingTransfers(Deadline now);
  bool ServeTarget(Window requestor, Atom target, Atom property);
  bool ServeMultiple(Window requestor, Atom property);
  bool WritePayload(Window requestor, Atom property,
                    const X11ClipboardPayload &payload, std::size_t offset,
                    std::size_t byte_count);
  bool AcquireOfferIfState(std::int64_t expected_revision,
                           Window expected_owner,
                           Time expected_selection_timestamp,
                           std::vector<X11ClipboardPayload> offer);
  Time GetServerTimestamp(Deadline deadline);
  const X11ClipboardPayload *FindPayload(Atom target,
                                         const ClipboardOffer &offer) const;
  std::size_t RetainedOutgoingOfferBytes() const;

  Display *display_ = nullptr;
  Window request_window_ = None;
  Atom clipboard_atom_ = None;
  Atom targets_atom_ = None;
  Atom incr_atom_ = None;
  Atom transfer_property_ = None;
  Atom timestamp_probe_property_ = None;
  Atom timestamp_atom_ = None;
  Atom multiple_atom_ = None;
  Atom utf8_atom_ = None;
  Atom text_atom_ = None;
  Atom text_plain_atom_ = None;
  Atom text_plain_utf8_atom_ = None;
  Atom delete_atom_ = None;
  Atom insert_selection_atom_ = None;
  Atom insert_property_atom_ = None;
  Time selection_timestamp_ = CurrentTime;
  std::int64_t selection_revision_ = 1;
  Window observed_selection_owner_ = None;
  Time observed_selection_timestamp_ = CurrentTime;
  int xfixes_event_base_ = 0;
  guint event_source_id_ = 0;
  std::size_t max_request_bytes_ = 0;
  ClipboardOffer active_offer_;
  std::vector<OutgoingTransfer> outgoing_transfers_;
  std::uint64_t request_serial_ = 0;
  bool connection_failed_ = false;
  bool authoritative_window_destroyed_ = false;
};

}

#endif
