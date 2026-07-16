#include "x11_clipboard_reader.h"

#include <X11/Xatom.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <mutex>
#include <poll.h>
#include <utility>

namespace ykd {
namespace {

constexpr auto kOutgoingTransferIdleTimeout = std::chrono::seconds(5);
constexpr std::size_t kMaxOutgoingTransfers = 16;
constexpr std::size_t kMaxOutgoingTransfersPerRequestor = 4;
constexpr std::size_t kMaxRetainedOutgoingOfferBytes = 16 * 1024 * 1024;

std::size_t ItemWidth(int format) {
  switch (format) {
  case 8:
    return 1;
  case 16:
    return 2;
  case 32:
    return 4;
  default:
    return 0;
  }
}

struct XErrorTrapContext final {
  Display *display = nullptr;
  unsigned long first_serial = 0;
  std::atomic_ulong last_serial{std::numeric_limits<unsigned long>::max()};
  std::atomic_bool failed{false};
};

std::mutex g_x_error_trap_mutex;
std::atomic<XErrorTrapContext *> g_x_error_trap{nullptr};
std::once_flag g_x_error_handler_once;
XErrorHandler g_previous_x_error_handler = nullptr;

int HandleTrappedXError(Display *display, XErrorEvent *event) {
  XErrorTrapContext *trap = g_x_error_trap.load(std::memory_order_acquire);
  if (trap != nullptr && display == trap->display &&
      event->serial >= trap->first_serial &&
      event->serial <= trap->last_serial.load(std::memory_order_relaxed)) {
    trap->failed.store(true, std::memory_order_relaxed);
    return 0;
  }
  if (g_previous_x_error_handler != nullptr) {
    return g_previous_x_error_handler(display, event);
  }
  std::_Exit(EXIT_FAILURE);
}

void EnsureCheckedXErrorHandler() {
  std::call_once(g_x_error_handler_once, [] {
    g_previous_x_error_handler = XSetErrorHandler(HandleTrappedXError);
  });
}

template <typename Operation>
bool RunCheckedXRequests(Display *display, Operation operation) {
  EnsureCheckedXErrorHandler();
  std::lock_guard<std::mutex> lock(g_x_error_trap_mutex);
  XSync(display, False);
  XErrorTrapContext trap;
  trap.display = display;
  trap.first_serial = NextRequest(display);
  g_x_error_trap.store(&trap, std::memory_order_release);
  operation();
  trap.last_serial.store(NextRequest(display) - 1, std::memory_order_relaxed);
  XSync(display, False);
  g_x_error_trap.store(nullptr, std::memory_order_release);
  return !trap.failed.load(std::memory_order_relaxed);
}

bool IsValidAtom(Display *display, Atom atom) {
  if (atom == None)
    return false;
  char *name = nullptr;
  const bool valid =
      RunCheckedXRequests(display, [&] { name = XGetAtomName(display, atom); });
  if (name != nullptr)
    XFree(name);
  return valid && name != nullptr;
}

std::size_t TargetListByteLimit(std::size_t max_bytes,
                                std::size_t max_targets) {
  if (max_targets >
      std::numeric_limits<std::size_t>::max() / sizeof(std::uint32_t)) {
    return max_bytes;
  }
  return std::min(max_bytes, max_targets * sizeof(std::uint32_t));
}

}

void InstallX11ErrorDispatcher() { EnsureCheckedXErrorHandler(); }

X11ClipboardReader::X11ClipboardReader() = default;

X11ClipboardReader::~X11ClipboardReader() { Stop(); }

bool X11ClipboardReader::Start(const char *display_name) {
  if (active())
    return true;
  if (display_ != nullptr)
    Stop();
  display_ = XOpenDisplay(display_name);
  if (display_ == nullptr)
    return false;
  request_window_ = XCreateSimpleWindow(display_, DefaultRootWindow(display_),
                                        0, 0, 1, 1, 0, 0, 0);
  if (request_window_ == None) {
    XCloseDisplay(display_);
    display_ = nullptr;
    return false;
  }
  XSelectInput(display_, request_window_,
               PropertyChangeMask | StructureNotifyMask);
  int xfixes_error_base = 0;
  if (XFixesQueryExtension(display_, &xfixes_event_base_, &xfixes_error_base) ==
      0) {
    XDestroyWindow(display_, request_window_);
    XCloseDisplay(display_);
    display_ = nullptr;
    request_window_ = None;
    return false;
  }
  clipboard_atom_ = XInternAtom(display_, "CLIPBOARD", False);
  targets_atom_ = XInternAtom(display_, "TARGETS", False);
  incr_atom_ = XInternAtom(display_, "INCR", False);
  transfer_property_ = XInternAtom(display_, "_YKD_CLIPBOARD_TRANSFER", False);
  timestamp_probe_property_ =
      XInternAtom(display_, "_YKD_SERVER_TIMESTAMP", False);
  timestamp_atom_ = XInternAtom(display_, "TIMESTAMP", False);
  multiple_atom_ = XInternAtom(display_, "MULTIPLE", False);
  utf8_atom_ = XInternAtom(display_, "UTF8_STRING", False);
  text_atom_ = XInternAtom(display_, "TEXT", False);
  text_plain_atom_ = XInternAtom(display_, "text/plain", False);
  text_plain_utf8_atom_ =
      XInternAtom(display_, "text/plain;charset=utf-8", False);
  delete_atom_ = XInternAtom(display_, "DELETE", False);
  insert_selection_atom_ = XInternAtom(display_, "INSERT_SELECTION", False);
  insert_property_atom_ = XInternAtom(display_, "INSERT_PROPERTY", False);
  XFixesSelectSelectionInput(display_, request_window_, clipboard_atom_,
                             XFixesSetSelectionOwnerNotifyMask |
                                 XFixesSelectionWindowDestroyNotifyMask |
                                 XFixesSelectionClientCloseNotifyMask);
  observed_selection_owner_ = XGetSelectionOwner(display_, clipboard_atom_);
  observed_selection_timestamp_ = CurrentTime;
  const long max_request_words = XMaxRequestSize(display_);
  max_request_bytes_ =
      max_request_words > 128
          ? static_cast<std::size_t>(max_request_words - 64) * 4
          : 256;
  GIOChannel *channel = g_io_channel_unix_new(ConnectionNumber(display_));
  event_source_id_ = g_io_add_watch(
      channel,
      static_cast<GIOCondition>(G_IO_IN | G_IO_ERR | G_IO_HUP | G_IO_NVAL),
      OnX11Input, this);
  g_io_channel_unref(channel);
  XSync(display_, False);
  return true;
}

void X11ClipboardReader::Stop() {
  if (display_ == nullptr)
    return;
  if (event_source_id_ != 0) {
    g_source_remove(event_source_id_);
    event_source_id_ = 0;
  }
  if (!connection_failed_) {
    RunCheckedXRequests(display_, [&] {
      if (XGetSelectionOwner(display_, clipboard_atom_) == request_window_) {
        XSetSelectionOwner(display_, clipboard_atom_, None, CurrentTime);
      }
      if (request_window_ != None && !authoritative_window_destroyed_) {
        XDestroyWindow(display_, request_window_);
      }
    });
    XCloseDisplay(display_);
  }
  display_ = nullptr;
  request_window_ = None;
  clipboard_atom_ = None;
  targets_atom_ = None;
  incr_atom_ = None;
  transfer_property_ = None;
  timestamp_probe_property_ = None;
  timestamp_atom_ = None;
  multiple_atom_ = None;
  utf8_atom_ = None;
  text_atom_ = None;
  text_plain_atom_ = None;
  text_plain_utf8_atom_ = None;
  delete_atom_ = None;
  insert_selection_atom_ = None;
  insert_property_atom_ = None;
  observed_selection_owner_ = None;
  observed_selection_timestamp_ = CurrentTime;
  selection_revision_ = 1;
  xfixes_event_base_ = 0;
  active_offer_.reset();
  outgoing_transfers_.clear();
  connection_failed_ = false;
  authoritative_window_destroyed_ = false;
}

bool X11ClipboardReader::owns_clipboard() const {
  return active() &&
         XGetSelectionOwner(display_, clipboard_atom_) == request_window_;
}

void X11ClipboardReader::Drain() { DrainEvents(); }

bool X11ClipboardReader::AcquireTextIfState(std::int64_t expected_revision,
                                            Window expected_owner,
                                            Time expected_selection_timestamp,
                                            const std::string &text) {
  if (!active())
    return false;
  std::vector<X11ClipboardPayload> offer;
  const Atom targets[] = {utf8_atom_, text_plain_utf8_atom_, text_plain_atom_,
                          text_atom_};
  offer.reserve(5);
  for (const Atom target : targets) {
    X11ClipboardPayload payload;
    payload.target = target;
    payload.type = utf8_atom_;
    payload.format = 8;
    payload.bytes.assign(text.begin(), text.end());
    offer.push_back(std::move(payload));
  }
  const bool ascii = std::all_of(text.begin(), text.end(), [](char value) {
    return static_cast<unsigned char>(value) < 0x80;
  });
  if (ascii) {
    X11ClipboardPayload payload;
    payload.target = XA_STRING;
    payload.type = XA_STRING;
    payload.format = 8;
    payload.bytes.assign(text.begin(), text.end());
    offer.push_back(std::move(payload));
  }
  return AcquireOfferIfState(expected_revision, expected_owner,
                             expected_selection_timestamp, std::move(offer));
}

bool X11ClipboardReader::AcquireSnapshotIfState(
    std::int64_t expected_revision, Window expected_owner,
    Time expected_selection_timestamp, const X11ClipboardSnapshot &snapshot) {
  if (!active())
    return false;
  return AcquireOfferIfState(expected_revision, expected_owner,
                             expected_selection_timestamp, snapshot.payloads);
}

bool X11ClipboardReader::AcquireOfferIfState(
    std::int64_t expected_revision, Window expected_owner,
    Time expected_selection_timestamp, std::vector<X11ClipboardPayload> offer) {
  if (!active() || expected_owner == None ||
      expected_selection_timestamp == CurrentTime) {
    return false;
  }
  ClipboardOffer next_offer =
      std::make_shared<const std::vector<X11ClipboardPayload>>(
          std::move(offer));
  const Time timestamp = GetServerTimestamp(std::chrono::steady_clock::now() +
                                            std::chrono::milliseconds(250));
  if (timestamp == CurrentTime)
    return false;

  XGrabServer(display_);
  XSync(display_, False);
  DrainEvents();
  if (!active() || selection_revision_ != expected_revision ||
      XGetSelectionOwner(display_, clipboard_atom_) != expected_owner ||
      observed_selection_owner_ != expected_owner ||
      observed_selection_timestamp_ != expected_selection_timestamp) {
    XUngrabServer(display_);
    XFlush(display_);
    return false;
  }
  ClipboardOffer previous_offer = active_offer_;
  const Time previous_timestamp = selection_timestamp_;
  active_offer_ = std::move(next_offer);
  selection_timestamp_ = timestamp;
  bool acquired = false;
  const bool ownership_request_valid = RunCheckedXRequests(display_, [&] {
    XSetSelectionOwner(display_, clipboard_atom_, request_window_, timestamp);
    acquired = XGetSelectionOwner(display_, clipboard_atom_) == request_window_;
  });
  acquired = ownership_request_valid && acquired;
  if (!acquired) {
    active_offer_ = std::move(previous_offer);
    selection_timestamp_ = previous_timestamp;
  }
  XUngrabServer(display_);
  XFlush(display_);
  return acquired;
}

Time X11ClipboardReader::GetServerTimestamp(Deadline deadline) {
  const unsigned char marker =
      static_cast<unsigned char>((request_serial_++ % 255) + 1);
  const bool requested = RunCheckedXRequests(display_, [&] {
    XChangeProperty(display_, request_window_, timestamp_probe_property_,
                    XA_INTEGER, 8, PropModeReplace, &marker, 1);
  });
  if (!requested)
    return CurrentTime;
  XPropertyEvent event{};
  return WaitForProperty(request_window_, timestamp_probe_property_, deadline,
                         &event)
             ? event.time
             : CurrentTime;
}

gboolean X11ClipboardReader::OnX11Input(GIOChannel *, GIOCondition condition,
                                        gpointer user_data) {
  auto *self = static_cast<X11ClipboardReader *>(user_data);
  if ((condition & (G_IO_ERR | G_IO_HUP | G_IO_NVAL)) != 0) {
    self->event_source_id_ = 0;
    self->connection_failed_ = true;
    return G_SOURCE_REMOVE;
  }
  self->DrainEvents();
  return G_SOURCE_CONTINUE;
}

void X11ClipboardReader::DrainEvents() {
  if (display_ == nullptr || connection_failed_)
    return;
  while (XPending(display_) != 0) {
    XEvent event{};
    XNextEvent(display_, &event);
    HandleEvent(event);
  }
}

void X11ClipboardReader::HandleEvent(const XEvent &event) {
  if (event.type == xfixes_event_base_ + XFixesSelectionNotify) {
    const auto *selection_event =
        reinterpret_cast<const XFixesSelectionNotifyEvent *>(&event);
    if (selection_event->selection == clipboard_atom_) {
      observed_selection_owner_ = selection_event->owner;
      observed_selection_timestamp_ = selection_event->selection_timestamp;
      ++selection_revision_;
    }
  } else if (event.type == SelectionRequest) {
    HandleSelectionRequest(event.xselectionrequest);
  } else if (event.type == SelectionClear &&
             event.xselectionclear.selection == clipboard_atom_) {
    active_offer_.reset();
  } else if (event.type == PropertyNotify &&
             event.xproperty.state == PropertyDelete) {
    HandlePropertyDelete(event.xproperty);
  } else if (event.type == DestroyNotify) {
    if (event.xdestroywindow.window == request_window_) {
      authoritative_window_destroyed_ = true;
      active_offer_.reset();
    } else {
      HandleRequestorDestroyed(event.xdestroywindow.window);
    }
  }
}

void X11ClipboardReader::HandleSelectionRequest(
    const XSelectionRequestEvent &request) {
  const Atom property =
      request.property == None ? request.target : request.property;
  const bool request_time_valid =
      request.time == CurrentTime ||
      (selection_timestamp_ != CurrentTime &&
       static_cast<std::int32_t>(request.time - selection_timestamp_) >= 0);
  const bool served = request.selection == clipboard_atom_ &&
                      request_time_valid &&
                      ServeTarget(request.requestor, request.target, property);
  const bool requestor_alive = RunCheckedXRequests(display_, [&] {
    XEvent response{};
    response.xselection.type = SelectionNotify;
    response.xselection.display = request.display;
    response.xselection.requestor = request.requestor;
    response.xselection.selection = request.selection;
    response.xselection.target = request.target;
    response.xselection.property = served ? property : None;
    response.xselection.time = request.time;
    XSendEvent(display_, request.requestor, False, NoEventMask, &response);
  });
  if (!requestor_alive)
    HandleRequestorDestroyed(request.requestor);
}

bool X11ClipboardReader::ServeTarget(Window requestor, Atom target,
                                     Atom property) {
  if (target == multiple_atom_)
    return ServeMultiple(requestor, property);
  if (target == targets_atom_) {
    if (active_offer_ == nullptr)
      return false;
    std::vector<unsigned long> targets;
    targets.reserve(active_offer_->size() + 3);
    targets.push_back(targets_atom_);
    targets.push_back(timestamp_atom_);
    targets.push_back(multiple_atom_);
    for (const auto &payload : *active_offer_) {
      if (std::find(targets.begin(), targets.end(), payload.target) ==
          targets.end()) {
        targets.push_back(payload.target);
      }
    }
    return RunCheckedXRequests(display_, [&] {
      XChangeProperty(display_, requestor, property, XA_ATOM, 32,
                      PropModeReplace,
                      reinterpret_cast<const unsigned char *>(targets.data()),
                      static_cast<int>(targets.size()));
    });
  }
  if (target == timestamp_atom_) {
    const unsigned long timestamp = selection_timestamp_;
    return RunCheckedXRequests(display_, [&] {
      XChangeProperty(display_, requestor, property, XA_INTEGER, 32,
                      PropModeReplace,
                      reinterpret_cast<const unsigned char *>(&timestamp), 1);
    });
  }
  const X11ClipboardPayload *payload = FindPayload(target, active_offer_);
  if (payload == nullptr)
    return false;
  if (payload->bytes.size() <= max_request_bytes_) {
    bool written = false;
    const bool requestor_alive = RunCheckedXRequests(display_, [&] {
      written =
          WritePayload(requestor, property, *payload, 0, payload->bytes.size());
    });
    return requestor_alive && written;
  }
  const Deadline now = std::chrono::steady_clock::now();
  PruneOutgoingTransfers(now);
  if (outgoing_transfers_.size() >= kMaxOutgoingTransfers ||
      active_offer_ == nullptr) {
    return false;
  }
  const std::size_t requestor_transfers = static_cast<std::size_t>(
      std::count_if(outgoing_transfers_.begin(), outgoing_transfers_.end(),
                    [requestor](const OutgoingTransfer &transfer) {
                      return transfer.requestor == requestor;
                    }));
  const bool duplicate_property = std::any_of(
      outgoing_transfers_.begin(), outgoing_transfers_.end(),
      [requestor, property](const OutgoingTransfer &transfer) {
        return transfer.requestor == requestor && transfer.property == property;
      });
  const bool offer_already_retained =
      std::any_of(outgoing_transfers_.begin(), outgoing_transfers_.end(),
                  [this](const OutgoingTransfer &transfer) {
                    return transfer.offer == active_offer_;
                  });
  std::size_t retained_bytes = RetainedOutgoingOfferBytes();
  if (!offer_already_retained) {
    for (const auto &candidate : *active_offer_) {
      if (candidate.bytes.size() >
          kMaxRetainedOutgoingOfferBytes -
              std::min(retained_bytes, kMaxRetainedOutgoingOfferBytes)) {
        retained_bytes = kMaxRetainedOutgoingOfferBytes + 1;
        break;
      }
      retained_bytes += candidate.bytes.size();
    }
  }
  if (requestor_transfers >= kMaxOutgoingTransfersPerRequestor ||
      duplicate_property || retained_bytes > kMaxRetainedOutgoingOfferBytes) {
    return false;
  }
  const unsigned long size = payload->bytes.size();
  const bool requestor_alive = RunCheckedXRequests(display_, [&] {
    XSelectInput(display_, requestor, PropertyChangeMask | StructureNotifyMask);
    XChangeProperty(display_, requestor, property, incr_atom_, 32,
                    PropModeReplace,
                    reinterpret_cast<const unsigned char *>(&size), 1);
  });
  if (!requestor_alive)
    return false;
  outgoing_transfers_.push_back(
      OutgoingTransfer{requestor, property, target, 0, active_offer_, now});
  return true;
}

bool X11ClipboardReader::ServeMultiple(Window requestor, Atom property) {
  Atom actual_type = None;
  int actual_format = 0;
  unsigned long item_count = 0;
  unsigned long bytes_after = 0;
  unsigned char *data = nullptr;
  int status = BadWindow;
  const bool requestor_alive = RunCheckedXRequests(display_, [&] {
    status = XGetWindowProperty(display_, requestor, property, 0, 128, False,
                                XA_ATOM, &actual_type, &actual_format,
                                &item_count, &bytes_after, &data);
  });
  if (!requestor_alive || status != Success || actual_type != XA_ATOM ||
      actual_format != 32 || bytes_after != 0 || item_count == 0 ||
      item_count > 128 || item_count % 2 != 0 || data == nullptr) {
    if (data != nullptr)
      XFree(data);
    return false;
  }

  auto *pairs = reinterpret_cast<unsigned long *>(data);
  for (unsigned long index = 0; index < item_count; index += 2) {
    const Atom target = static_cast<Atom>(pairs[index]);
    const Atom target_property = static_cast<Atom>(pairs[index + 1]);
    if (target == multiple_atom_ || target_property == None ||
        !ServeTarget(requestor, target, target_property)) {
      pairs[index] = None;
    }
  }
  const bool written = RunCheckedXRequests(display_, [&] {
    XChangeProperty(display_, requestor, property, XA_ATOM, 32, PropModeReplace,
                    data, static_cast<int>(item_count));
  });
  XFree(data);
  return written;
}

void X11ClipboardReader::HandlePropertyDelete(const XPropertyEvent &event) {
  const Deadline now = std::chrono::steady_clock::now();
  PruneOutgoingTransfers(now);
  auto transfer =
      std::find_if(outgoing_transfers_.begin(), outgoing_transfers_.end(),
                   [&event](const OutgoingTransfer &candidate) {
                     return candidate.requestor == event.window &&
                            candidate.property == event.atom;
                   });
  if (transfer == outgoing_transfers_.end())
    return;
  const X11ClipboardPayload *payload =
      FindPayload(transfer->target, transfer->offer);
  if (payload == nullptr) {
    outgoing_transfers_.erase(transfer);
    return;
  }
  if (transfer->offset >= payload->bytes.size()) {
    const bool written = RunCheckedXRequests(display_, [&] {
      WritePayload(transfer->requestor, transfer->property, *payload,
                   payload->bytes.size(), 0);
    });
    outgoing_transfers_.erase(transfer);
    if (!written)
      HandleRequestorDestroyed(event.window);
    return;
  }
  const std::size_t width = ItemWidth(payload->format);
  std::size_t chunk =
      std::min(max_request_bytes_, payload->bytes.size() - transfer->offset);
  chunk -= chunk % width;
  bool payload_written = false;
  const bool requestor_alive = RunCheckedXRequests(display_, [&] {
    payload_written =
        chunk != 0 && WritePayload(transfer->requestor, transfer->property,
                                   *payload, transfer->offset, chunk);
  });
  if (!requestor_alive || !payload_written) {
    outgoing_transfers_.erase(transfer);
    return;
  }
  transfer->offset += chunk;
  transfer->last_progress = now;
}

void X11ClipboardReader::HandleRequestorDestroyed(Window requestor) {
  outgoing_transfers_.erase(
      std::remove_if(outgoing_transfers_.begin(), outgoing_transfers_.end(),
                     [requestor](const OutgoingTransfer &transfer) {
                       return transfer.requestor == requestor;
                     }),
      outgoing_transfers_.end());
}

void X11ClipboardReader::PruneOutgoingTransfers(Deadline now) {
  outgoing_transfers_.erase(
      std::remove_if(outgoing_transfers_.begin(), outgoing_transfers_.end(),
                     [now](const OutgoingTransfer &transfer) {
                       return now - transfer.last_progress >
                              kOutgoingTransferIdleTimeout;
                     }),
      outgoing_transfers_.end());
}

bool X11ClipboardReader::WritePayload(Window requestor, Atom property,
                                      const X11ClipboardPayload &payload,
                                      std::size_t offset,
                                      std::size_t byte_count) {
  const std::size_t width = ItemWidth(payload.format);
  if (width == 0 || offset > payload.bytes.size() ||
      byte_count > payload.bytes.size() - offset || offset % width != 0 ||
      byte_count % width != 0) {
    return false;
  }
  const std::size_t item_count = byte_count / width;
  if (item_count > static_cast<std::size_t>(std::numeric_limits<int>::max())) {
    return false;
  }
  const std::uint8_t *source =
      byte_count == 0 ? nullptr : payload.bytes.data() + offset;
  if (payload.format == 8) {
    XChangeProperty(display_, requestor, property, payload.type, 8,
                    PropModeReplace, source, static_cast<int>(item_count));
    return true;
  }
  if (payload.format == 16) {
    std::vector<unsigned short> values(item_count);
    for (std::size_t index = 0; index < item_count; ++index) {
      std::memcpy(&values[index], source + index * width, width);
    }
    XChangeProperty(display_, requestor, property, payload.type, 16,
                    PropModeReplace,
                    reinterpret_cast<const unsigned char *>(values.data()),
                    static_cast<int>(item_count));
    return true;
  }
  std::vector<unsigned long> values(item_count);
  for (std::size_t index = 0; index < item_count; ++index) {
    std::uint32_t value = 0;
    std::memcpy(&value, source + index * width, width);
    values[index] = value;
  }
  XChangeProperty(display_, requestor, property, payload.type, 32,
                  PropModeReplace,
                  reinterpret_cast<const unsigned char *>(values.data()),
                  static_cast<int>(item_count));
  return true;
}

const X11ClipboardPayload *
X11ClipboardReader::FindPayload(Atom target,
                                const ClipboardOffer &offer) const {
  if (offer == nullptr)
    return nullptr;
  const auto payload =
      std::find_if(offer->begin(), offer->end(),
                   [target](const X11ClipboardPayload &candidate) {
                     return candidate.target == target;
                   });
  return payload == offer->end() ? nullptr : &*payload;
}

std::size_t X11ClipboardReader::RetainedOutgoingOfferBytes() const {
  std::vector<const void *> seen;
  std::size_t total = 0;
  for (const auto &transfer : outgoing_transfers_) {
    if (transfer.offer == nullptr ||
        std::find(seen.begin(), seen.end(), transfer.offer.get()) !=
            seen.end()) {
      continue;
    }
    seen.push_back(transfer.offer.get());
    for (const auto &payload : *transfer.offer) {
      if (payload.bytes.size() >
          std::numeric_limits<std::size_t>::max() - total) {
        return std::numeric_limits<std::size_t>::max();
      }
      total += payload.bytes.size();
    }
  }
  return total;
}

X11ClipboardReadStatus
X11ClipboardReader::Capture(std::size_t max_bytes, std::size_t max_targets,
                            std::chrono::milliseconds timeout,
                            X11ClipboardSnapshot *snapshot) {
  if (!active() || snapshot == nullptr || max_bytes == 0 || max_targets == 0 ||
      timeout.count() <= 0) {
    return X11ClipboardReadStatus::kUnavailable;
  }
  snapshot->owner = None;
  snapshot->payloads.clear();
  const Window owner = XGetSelectionOwner(display_, clipboard_atom_);
  if (owner == None)
    return X11ClipboardReadStatus::kUnavailable;
  const Deadline deadline = std::chrono::steady_clock::now() + timeout;

  X11ClipboardPayload targets;
  const std::size_t target_bytes_limit =
      TargetListByteLimit(max_bytes, max_targets);
  X11ClipboardReadStatus status =
      RequestTarget(targets_atom_, target_bytes_limit, deadline, &targets);
  DrainEvents();
  if (!active())
    return X11ClipboardReadStatus::kUnavailable;
  if (status == X11ClipboardReadStatus::kTooLarge &&
      target_bytes_limit < max_bytes) {
    return X11ClipboardReadStatus::kTooManyTargets;
  }
  if (status != X11ClipboardReadStatus::kOk)
    return status;
  if (targets.type != XA_ATOM || targets.format != 32) {
    return X11ClipboardReadStatus::kProtocolError;
  }
  std::vector<Atom> atoms = DecodeAtoms(targets);
  std::sort(atoms.begin(), atoms.end());
  atoms.erase(std::unique(atoms.begin(), atoms.end()), atoms.end());
  atoms.erase(std::remove_if(atoms.begin(), atoms.end(),
                             [this](Atom atom) {
                               return atom == None || IsSyntheticTarget(atom);
                             }),
              atoms.end());
  if (atoms.size() > max_targets) {
    return X11ClipboardReadStatus::kTooManyTargets;
  }

  std::size_t total_bytes = 0;
  std::vector<X11ClipboardPayload> payloads;
  payloads.reserve(atoms.size());
  for (const Atom atom : atoms) {
    X11ClipboardPayload payload;
    status = RequestTarget(atom, max_bytes - total_bytes, deadline, &payload);
    DrainEvents();
    if (!active())
      return X11ClipboardReadStatus::kUnavailable;
    if (status != X11ClipboardReadStatus::kOk)
      return status;
    if (payload.bytes.size() > max_bytes - total_bytes) {
      return X11ClipboardReadStatus::kTooLarge;
    }
    total_bytes += payload.bytes.size();
    payloads.push_back(std::move(payload));
  }
  DrainEvents();
  if (!active())
    return X11ClipboardReadStatus::kUnavailable;
  if (XGetSelectionOwner(display_, clipboard_atom_) != owner) {
    return X11ClipboardReadStatus::kOwnerChanged;
  }
  snapshot->owner = owner;
  snapshot->payloads = std::move(payloads);
  return X11ClipboardReadStatus::kOk;
}

X11ClipboardReadStatus
X11ClipboardReader::ReadUtf8(std::size_t max_bytes, std::size_t max_targets,
                             std::chrono::milliseconds timeout,
                             X11ClipboardText *text) {
  if (!active() || text == nullptr || max_bytes == 0 || max_targets == 0 ||
      timeout.count() <= 0) {
    return X11ClipboardReadStatus::kUnavailable;
  }
  text->owner = None;
  text->text.clear();
  const Window owner = XGetSelectionOwner(display_, clipboard_atom_);
  if (owner == None)
    return X11ClipboardReadStatus::kUnavailable;
  const Deadline deadline = std::chrono::steady_clock::now() + timeout;

  X11ClipboardPayload targets;
  const std::size_t target_bytes_limit =
      TargetListByteLimit(max_bytes, max_targets);
  X11ClipboardReadStatus status =
      RequestTarget(targets_atom_, target_bytes_limit, deadline, &targets);
  DrainEvents();
  if (!active())
    return X11ClipboardReadStatus::kUnavailable;
  if (status == X11ClipboardReadStatus::kTooLarge &&
      target_bytes_limit < max_bytes) {
    return X11ClipboardReadStatus::kTooManyTargets;
  }
  if (status != X11ClipboardReadStatus::kOk)
    return status;
  if (targets.type != XA_ATOM || targets.format != 32) {
    return X11ClipboardReadStatus::kProtocolError;
  }
  const std::vector<Atom> atoms = DecodeAtoms(targets);
  if (atoms.size() > max_targets) {
    return X11ClipboardReadStatus::kTooManyTargets;
  }
  const Atom preferred[] = {
      XInternAtom(display_, "UTF8_STRING", False),
      XInternAtom(display_, "text/plain;charset=utf-8", False),
      XInternAtom(display_, "text/plain", False),
      XInternAtom(display_, "TEXT", False),
      XA_STRING,
  };
  Atom selected = None;
  for (const Atom candidate : preferred) {
    if (std::find(atoms.begin(), atoms.end(), candidate) != atoms.end()) {
      selected = candidate;
      break;
    }
  }
  if (selected == None)
    return X11ClipboardReadStatus::kConversionRejected;

  X11ClipboardPayload payload;
  status = RequestTarget(selected, max_bytes, deadline, &payload);
  DrainEvents();
  if (!active())
    return X11ClipboardReadStatus::kUnavailable;
  if (status != X11ClipboardReadStatus::kOk)
    return status;
  if (payload.format != 8) {
    return X11ClipboardReadStatus::kUnsupportedFormat;
  }
  DrainEvents();
  if (!active())
    return X11ClipboardReadStatus::kUnavailable;
  if (XGetSelectionOwner(display_, clipboard_atom_) != owner) {
    return X11ClipboardReadStatus::kOwnerChanged;
  }
  text->owner = owner;
  text->text.assign(reinterpret_cast<const char *>(payload.bytes.data()),
                    payload.bytes.size());
  return X11ClipboardReadStatus::kOk;
}

X11ClipboardReadStatus
X11ClipboardReader::RequestTarget(Atom target, std::size_t max_bytes,
                                  Deadline deadline,
                                  X11ClipboardPayload *payload) {
  if (payload == nullptr) {
    return X11ClipboardReadStatus::kProtocolError;
  }
  if (std::chrono::steady_clock::now() >= deadline) {
    return X11ClipboardReadStatus::kTimeout;
  }
  if (!IsValidAtom(display_, target)) {
    return X11ClipboardReadStatus::kProtocolError;
  }
  if (std::chrono::steady_clock::now() >= deadline) {
    return X11ClipboardReadStatus::kTimeout;
  }
  const Window transfer_window = XCreateSimpleWindow(
      display_, DefaultRootWindow(display_), 0, 0, 1, 1, 0, 0, 0);
  if (transfer_window == None)
    return X11ClipboardReadStatus::kUnavailable;
  const auto finish = [&](X11ClipboardReadStatus status) {
    const bool destroyed = RunCheckedXRequests(
        display_, [&] { XDestroyWindow(display_, transfer_window); });
    return destroyed ? status : X11ClipboardReadStatus::kProtocolError;
  };
  ++request_serial_;
  const Time request_time = GetServerTimestamp(deadline);
  if (request_time == CurrentTime) {
    return finish(X11ClipboardReadStatus::kTimeout);
  }
  const bool requested = RunCheckedXRequests(display_, [&] {
    XSelectInput(display_, transfer_window, PropertyChangeMask);
    XDeleteProperty(display_, transfer_window, transfer_property_);
    XConvertSelection(display_, clipboard_atom_, target, transfer_property_,
                      transfer_window, request_time);
  });
  if (!requested)
    return finish(X11ClipboardReadStatus::kProtocolError);
  XSelectionEvent selection_event{};
  if (!WaitForSelectionNotify(transfer_window, target, transfer_property_,
                              deadline, &selection_event)) {
    return finish(X11ClipboardReadStatus::kTimeout);
  }
  if (selection_event.property == None) {
    return finish(X11ClipboardReadStatus::kConversionRejected);
  }
  payload->target = target;
  return finish(ReadProperty(transfer_window, transfer_property_, max_bytes,
                             deadline, payload));
}

X11ClipboardReadStatus
X11ClipboardReader::ReadProperty(Window requestor, Atom property,
                                 std::size_t max_bytes, Deadline deadline,
                                 X11ClipboardPayload *payload) {
  Atom actual_type = None;
  int actual_format = 0;
  unsigned long item_count = 0;
  unsigned long bytes_after = 0;
  unsigned char *ignored = nullptr;
  int query_status = BadWindow;
  const bool query_valid = RunCheckedXRequests(display_, [&] {
    query_status = XGetWindowProperty(
        display_, requestor, property, 0, 0, False, AnyPropertyType,
        &actual_type, &actual_format, &item_count, &bytes_after, &ignored);
  });
  if (ignored != nullptr)
    XFree(ignored);
  if (!query_valid || query_status != Success || actual_type == None) {
    return X11ClipboardReadStatus::kProtocolError;
  }
  if (actual_type == incr_atom_) {
    if (actual_format != 32 || bytes_after != sizeof(std::uint32_t)) {
      return X11ClipboardReadStatus::kProtocolError;
    }
    unsigned char *increment_data = nullptr;
    int increment_status = BadWindow;
    const bool increment_valid = RunCheckedXRequests(display_, [&] {
      increment_status = XGetWindowProperty(
          display_, requestor, property, 0, 1, True, incr_atom_, &actual_type,
          &actual_format, &item_count, &bytes_after, &increment_data);
    });
    if (!increment_valid || increment_status != Success ||
        actual_type != incr_atom_ || actual_format != 32 || item_count != 1 ||
        bytes_after != 0 || increment_data == nullptr) {
      if (increment_data != nullptr)
        XFree(increment_data);
      return X11ClipboardReadStatus::kProtocolError;
    }
    const unsigned long advertised_size =
        *reinterpret_cast<const unsigned long *>(increment_data);
    XFree(increment_data);
    if (advertised_size > max_bytes) {
      return X11ClipboardReadStatus::kTooLarge;
    }
    return ReadIncrementalProperty(requestor, property, max_bytes, deadline,
                                   payload);
  }
  if (bytes_after > max_bytes ||
      bytes_after >
          static_cast<unsigned long>(std::numeric_limits<long>::max())) {
    return X11ClipboardReadStatus::kTooLarge;
  }

  unsigned char *data = nullptr;
  const unsigned long words = (bytes_after + 3UL) / 4UL;
  int read_status = BadWindow;
  const bool read_valid = RunCheckedXRequests(display_, [&] {
    read_status = XGetWindowProperty(
        display_, requestor, property, 0, static_cast<long>(words), True,
        AnyPropertyType, &actual_type, &actual_format, &item_count,
        &bytes_after, &data);
  });
  if (!read_valid || read_status != Success || bytes_after != 0 ||
      actual_type == None) {
    if (data != nullptr)
      XFree(data);
    return X11ClipboardReadStatus::kProtocolError;
  }
  payload->type = actual_type;
  payload->format = actual_format;
  const bool normalized = NormalizeProperty(actual_format, item_count, data,
                                            max_bytes, &payload->bytes);
  if (data != nullptr)
    XFree(data);
  return normalized ? X11ClipboardReadStatus::kOk
                    : X11ClipboardReadStatus::kUnsupportedFormat;
}

X11ClipboardReadStatus X11ClipboardReader::ReadIncrementalProperty(
    Window requestor, Atom property, std::size_t max_bytes, Deadline deadline,
    X11ClipboardPayload *payload) {
  Atom type = None;
  int format = 0;
  std::vector<std::uint8_t> aggregate;
  XFlush(display_);

  while (true) {
    XPropertyEvent property_event{};
    if (!WaitForProperty(requestor, property, deadline, &property_event)) {
      return X11ClipboardReadStatus::kTimeout;
    }
    Atom chunk_type = None;
    int chunk_format = 0;
    unsigned long item_count = 0;
    unsigned long bytes_after = 0;
    unsigned char *ignored = nullptr;
    int query_status = BadWindow;
    const bool query_valid = RunCheckedXRequests(display_, [&] {
      query_status = XGetWindowProperty(
          display_, requestor, property, 0, 0, False, AnyPropertyType,
          &chunk_type, &chunk_format, &item_count, &bytes_after, &ignored);
    });
    if (ignored != nullptr)
      XFree(ignored);
    if (!query_valid || query_status != Success || chunk_type == None) {
      return X11ClipboardReadStatus::kProtocolError;
    }
    if (bytes_after == 0) {
      unsigned char *empty = nullptr;
      int empty_status = BadWindow;
      const bool empty_valid = RunCheckedXRequests(display_, [&] {
        empty_status = XGetWindowProperty(
            display_, requestor, property, 0, 0, True, AnyPropertyType,
            &chunk_type, &chunk_format, &item_count, &bytes_after, &empty);
      });
      if (empty != nullptr)
        XFree(empty);
      if (!empty_valid || empty_status != Success) {
        return X11ClipboardReadStatus::kProtocolError;
      }
      payload->type = type == None ? chunk_type : type;
      payload->format = format == 0 ? chunk_format : format;
      payload->bytes = std::move(aggregate);
      return X11ClipboardReadStatus::kOk;
    }
    if (bytes_after > max_bytes - aggregate.size() ||
        bytes_after >
            static_cast<unsigned long>(std::numeric_limits<long>::max())) {
      return X11ClipboardReadStatus::kTooLarge;
    }
    const unsigned long words = (bytes_after + 3UL) / 4UL;
    unsigned char *data = nullptr;
    int read_status = BadWindow;
    const bool read_valid = RunCheckedXRequests(display_, [&] {
      read_status = XGetWindowProperty(
          display_, requestor, property, 0, static_cast<long>(words), True,
          AnyPropertyType, &chunk_type, &chunk_format, &item_count,
          &bytes_after, &data);
    });
    if (!read_valid || read_status != Success || bytes_after != 0) {
      if (data != nullptr)
        XFree(data);
      return X11ClipboardReadStatus::kProtocolError;
    }
    if ((type != None && type != chunk_type) ||
        (format != 0 && format != chunk_format)) {
      if (data != nullptr)
        XFree(data);
      return X11ClipboardReadStatus::kProtocolError;
    }
    type = chunk_type;
    format = chunk_format;
    std::vector<std::uint8_t> normalized;
    const bool valid =
        NormalizeProperty(chunk_format, item_count, data,
                          max_bytes - aggregate.size(), &normalized);
    if (data != nullptr)
      XFree(data);
    if (!valid)
      return X11ClipboardReadStatus::kUnsupportedFormat;
    aggregate.insert(aggregate.end(), normalized.begin(), normalized.end());
  }
}

bool X11ClipboardReader::WaitForSelectionNotify(
    Window requestor, Atom target, Atom property, Deadline deadline,
    XSelectionEvent *selection_event) {
  while (std::chrono::steady_clock::now() < deadline) {
    while (XPending(display_) != 0) {
      XEvent event{};
      XNextEvent(display_, &event);
      if (event.type == SelectionNotify &&
          event.xselection.requestor == requestor &&
          event.xselection.selection == clipboard_atom_ &&
          event.xselection.target == target &&
          (event.xselection.property == property ||
           event.xselection.property == None)) {
        *selection_event = event.xselection;
        return true;
      }
      HandleEvent(event);
      if (!active())
        return false;
    }
    if (!WaitForInput(deadline))
      return false;
  }
  return false;
}

bool X11ClipboardReader::WaitForProperty(Window requestor, Atom property,
                                         Deadline deadline,
                                         XPropertyEvent *property_event) {
  while (std::chrono::steady_clock::now() < deadline) {
    while (XPending(display_) != 0) {
      XEvent event{};
      XNextEvent(display_, &event);
      if (event.type == PropertyNotify && event.xproperty.window == requestor &&
          event.xproperty.atom == property &&
          event.xproperty.state == PropertyNewValue) {
        *property_event = event.xproperty;
        return true;
      }
      HandleEvent(event);
      if (!active())
        return false;
    }
    if (!WaitForInput(deadline))
      return false;
  }
  return false;
}

bool X11ClipboardReader::WaitForInput(Deadline deadline) {
  while (true) {
    const auto now = std::chrono::steady_clock::now();
    if (now >= deadline)
      return false;
    const auto remaining =
        std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now);
    const auto bounded = std::max<std::int64_t>(1, remaining.count());
    pollfd descriptor{};
    descriptor.fd = ConnectionNumber(display_);
    descriptor.events = POLLIN;
    const int result = poll(&descriptor, 1,
                            bounded > std::numeric_limits<int>::max()
                                ? std::numeric_limits<int>::max()
                                : static_cast<int>(bounded));
    if (result > 0)
      return (descriptor.revents & POLLIN) != 0;
    if (result == 0)
      return false;
    if (errno != EINTR)
      return false;
  }
}

bool X11ClipboardReader::NormalizeProperty(
    int format, unsigned long item_count, const unsigned char *source,
    std::size_t max_bytes, std::vector<std::uint8_t> *destination) const {
  const std::size_t width = ItemWidth(format);
  if (width == 0 || item_count > max_bytes / width ||
      (item_count != 0 && source == nullptr)) {
    return false;
  }
  destination->resize(static_cast<std::size_t>(item_count) * width);
  if (format == 8) {
    if (item_count != 0) {
      std::memcpy(destination->data(), source, item_count);
    }
    return true;
  }
  if (format == 16) {
    const auto *values = reinterpret_cast<const unsigned short *>(source);
    for (unsigned long index = 0; index < item_count; ++index) {
      const std::uint16_t value = values[index];
      std::memcpy(destination->data() + index * width, &value, width);
    }
    return true;
  }
  const auto *values = reinterpret_cast<const unsigned long *>(source);
  for (unsigned long index = 0; index < item_count; ++index) {
    const std::uint32_t value = static_cast<std::uint32_t>(values[index]);
    std::memcpy(destination->data() + index * width, &value, width);
  }
  return true;
}

std::vector<Atom>
X11ClipboardReader::DecodeAtoms(const X11ClipboardPayload &payload) const {
  std::vector<Atom> atoms;
  if (payload.type != XA_ATOM || payload.format != 32 ||
      payload.bytes.size() % sizeof(std::uint32_t) != 0) {
    return atoms;
  }
  atoms.reserve(payload.bytes.size() / sizeof(std::uint32_t));
  for (std::size_t offset = 0; offset < payload.bytes.size();
       offset += sizeof(std::uint32_t)) {
    std::uint32_t value = 0;
    std::memcpy(&value, payload.bytes.data() + offset, sizeof(value));
    atoms.push_back(static_cast<Atom>(value));
  }
  return atoms;
}

bool X11ClipboardReader::IsSyntheticTarget(Atom target) const {
  const Atom timestamp = XInternAtom(display_, "TIMESTAMP", False);
  const Atom multiple = XInternAtom(display_, "MULTIPLE", False);
  const Atom save_targets = XInternAtom(display_, "SAVE_TARGETS", False);
  return target == targets_atom_ || target == timestamp || target == multiple ||
         target == save_targets || target == delete_atom_ ||
         target == insert_selection_atom_ || target == insert_property_atom_;
}

}
