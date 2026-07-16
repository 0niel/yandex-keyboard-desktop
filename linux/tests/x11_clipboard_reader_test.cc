#include "x11_clipboard_reader.h"

#include <X11/Xatom.h>

#include <csignal>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>
#include <sys/wait.h>
#include <unistd.h>

namespace ykd {

class X11ClipboardReaderTestPeer final {
public:
  static void ForceIncrementalOffers(X11ClipboardReader &reader) {
    reader.max_request_bytes_ = 3;
  }

  static std::size_t OutgoingTransferCount(const X11ClipboardReader &reader) {
    return reader.outgoing_transfers_.size();
  }

  static void Drain(X11ClipboardReader &reader) { reader.DrainEvents(); }

  static void ExpireOutgoingTransfers(X11ClipboardReader &reader) {
    const auto expired =
        std::chrono::steady_clock::now() - std::chrono::hours(1);
    for (auto &transfer : reader.outgoing_transfers_) {
      transfer.last_progress = expired;
    }
  }

  static X11ClipboardReadStatus
  RequestWithExpiredDeadline(X11ClipboardReader &reader) {
    X11ClipboardPayload payload;
    return reader.RequestTarget(reader.utf8_atom_, 1024,
                                std::chrono::steady_clock::now() -
                                    std::chrono::milliseconds(1),
                                &payload);
  }
};

}

namespace {

constexpr char kText[] = "Hello, \xD0\xBC\xD0\xB8\xD1\x80";

enum class OwnerMode {
  kNormal,
  kTimeout,
  kOversizedIncrement,
  kMalformedIncrement,
  kOwnerChanges,
  kOversizedThenValid,
  kInvalidTargetAtom,
  kDestroysTransferWindow,
};

[[noreturn]] void Fail(const char *message) {
  std::cerr << message << '\n';
  std::exit(EXIT_FAILURE);
}

void SendSelectionNotify(Display *display,
                         const XSelectionRequestEvent &request, Atom property) {
  XEvent response{};
  response.xselection.type = SelectionNotify;
  response.xselection.display = request.display;
  response.xselection.requestor = request.requestor;
  response.xselection.selection = request.selection;
  response.xselection.target = request.target;
  response.xselection.property = property;
  response.xselection.time = request.time;
  XSendEvent(display, request.requestor, False, NoEventMask, &response);
  XFlush(display);
}

[[noreturn]] void RunOwner(const char *display_name, int ready_fd,
                           OwnerMode mode) {
  Display *display = XOpenDisplay(display_name);
  if (display == nullptr)
    _exit(10);
  const Window window = XCreateSimpleWindow(display, DefaultRootWindow(display),
                                            0, 0, 1, 1, 0, 0, 0);
  const Atom clipboard = XInternAtom(display, "CLIPBOARD", False);
  const Atom targets = XInternAtom(display, "TARGETS", False);
  const Atom timestamp = XInternAtom(display, "TIMESTAMP", False);
  const Atom utf8 = XInternAtom(display, "UTF8_STRING", False);
  const Atom custom = XInternAtom(display, "application/x-ykd-test", False);
  const Atom empty = XInternAtom(display, "application/x-ykd-empty", False);
  const Atom delete_target = XInternAtom(display, "DELETE", False);
  const Atom insert_selection = XInternAtom(display, "INSERT_SELECTION", False);
  const Atom insert_property = XInternAtom(display, "INSERT_PROPERTY", False);
  const Atom incr = XInternAtom(display, "INCR", False);
  XSetSelectionOwner(display, clipboard, window, CurrentTime);
  XSync(display, False);
  const char ready = XGetSelectionOwner(display, clipboard) == window ? 1 : 0;
  if (write(ready_fd, &ready, 1) != 1 || ready == 0)
    _exit(11);
  close(ready_fd);

  Window incremental_requestor = None;
  Atom incremental_property = None;
  std::size_t incremental_offset = 0;
  int utf8_request_count = 0;

  while (true) {
    XEvent event{};
    XNextEvent(display, &event);
    if (event.type == SelectionRequest) {
      const XSelectionRequestEvent &request = event.xselectionrequest;
      const Atom property =
          request.property == None ? request.target : request.property;
      if (mode == OwnerMode::kTimeout)
        continue;
      if (request.target == targets) {
        const Atom invalid = static_cast<Atom>(0x7fffffffUL);
        const Atom offered[] = {targets,
                                timestamp,
                                mode == OwnerMode::kInvalidTargetAtom ? invalid
                                                                      : utf8,
                                custom,
                                empty,
                                delete_target,
                                insert_selection,
                                insert_property};
        const int offered_count = mode == OwnerMode::kNormal ? 8 : 3;
        XChangeProperty(
            display, request.requestor, property, XA_ATOM, 32, PropModeReplace,
            reinterpret_cast<const unsigned char *>(offered), offered_count);
        SendSelectionNotify(display, request, property);
      } else if (request.target == custom) {
        const unsigned short values[] = {0x1234, 0xCAFE};
        XChangeProperty(display, request.requestor, property, custom, 16,
                        PropModeReplace,
                        reinterpret_cast<const unsigned char *>(values), 2);
        SendSelectionNotify(display, request, property);
      } else if (request.target == empty) {
        XChangeProperty(display, request.requestor, property, empty, 8,
                        PropModeReplace, nullptr, 0);
        SendSelectionNotify(display, request, property);
      } else if (request.target == delete_target ||
                 request.target == insert_selection ||
                 request.target == insert_property) {
        XSetSelectionOwner(display, clipboard, None, CurrentTime);
        SendSelectionNotify(display, request, None);
      } else if (request.target == utf8) {
        if (mode == OwnerMode::kDestroysTransferWindow) {
          XDestroyWindow(display, request.requestor);
          XSync(display, False);
          continue;
        }
        const bool first_recovering_request =
            mode == OwnerMode::kOversizedThenValid && utf8_request_count++ == 0;
        if (mode == OwnerMode::kOversizedIncrement ||
            first_recovering_request) {
          const unsigned long size = 4096;
          XChangeProperty(display, request.requestor, property, incr, 32,
                          PropModeReplace,
                          reinterpret_cast<const unsigned char *>(&size), 1);
          SendSelectionNotify(display, request, property);
        } else if (mode == OwnerMode::kMalformedIncrement) {
          const unsigned char invalid_size = 42;
          XChangeProperty(display, request.requestor, property, incr, 8,
                          PropModeReplace, &invalid_size, 1);
          SendSelectionNotify(display, request, property);
        } else if (mode == OwnerMode::kOwnerChanges) {
          XChangeProperty(display, request.requestor, property, utf8, 8,
                          PropModeReplace,
                          reinterpret_cast<const unsigned char *>(kText),
                          sizeof(kText) - 1);
          XSetSelectionOwner(display, clipboard, None, CurrentTime);
          SendSelectionNotify(display, request, property);
        } else if (mode == OwnerMode::kOversizedThenValid) {
          XChangeProperty(display, request.requestor, property, utf8, 8,
                          PropModeReplace,
                          reinterpret_cast<const unsigned char *>(kText),
                          sizeof(kText) - 1);
          SendSelectionNotify(display, request, property);
        } else {
          const unsigned long size = sizeof(kText) - 1;
          XSelectInput(display, request.requestor, PropertyChangeMask);
          XChangeProperty(display, request.requestor, property, incr, 32,
                          PropModeReplace,
                          reinterpret_cast<const unsigned char *>(&size), 1);
          incremental_requestor = request.requestor;
          incremental_property = property;
          incremental_offset = 0;
          SendSelectionNotify(display, request, property);
        }
      } else {
        SendSelectionNotify(display, request, None);
      }
    } else if (event.type == PropertyNotify &&
               event.xproperty.state == PropertyDelete &&
               event.xproperty.window == incremental_requestor &&
               event.xproperty.atom == incremental_property) {
      const std::size_t remaining = sizeof(kText) - 1 - incremental_offset;
      const std::size_t chunk = remaining > 3 ? 3 : remaining;
      XChangeProperty(
          display, incremental_requestor, incremental_property, utf8, 8,
          PropModeReplace,
          reinterpret_cast<const unsigned char *>(kText + incremental_offset),
          static_cast<int>(chunk));
      incremental_offset += chunk;
      if (chunk == 0) {
        incremental_requestor = None;
        incremental_property = None;
      }
      XFlush(display);
    }
  }
}

class OwnerProcess final {
public:
  explicit OwnerProcess(const char *display_name,
                        OwnerMode mode = OwnerMode::kNormal) {
    int pipe_fds[2]{};
    if (pipe(pipe_fds) != 0)
      Fail("owner readiness pipe failed");
    process_id_ = fork();
    if (process_id_ < 0)
      Fail("selection owner fork failed");
    if (process_id_ == 0) {
      close(pipe_fds[0]);
      RunOwner(display_name, pipe_fds[1], mode);
    }
    close(pipe_fds[1]);
    char ready = 0;
    const ssize_t count = read(pipe_fds[0], &ready, 1);
    close(pipe_fds[0]);
    if (count != 1 || ready != 1)
      Fail("selection owner did not start");
  }

  ~OwnerProcess() {
    if (process_id_ <= 0)
      return;
    kill(process_id_, SIGTERM);
    int status = 0;
    waitpid(process_id_, &status, 0);
  }

  OwnerProcess(const OwnerProcess &) = delete;
  OwnerProcess &operator=(const OwnerProcess &) = delete;

private:
  pid_t process_id_ = -1;
};

const ykd::X11ClipboardPayload *
FindPayload(const ykd::X11ClipboardSnapshot &snapshot, Display *display,
            const char *target_name) {
  const Atom target = XInternAtom(display, target_name, False);
  for (const auto &payload : snapshot.payloads) {
    if (payload.target == target)
      return &payload;
  }
  return nullptr;
}

void VerifyOwnedText(const char *display_name, const std::string &expected) {
  const pid_t verifier = fork();
  if (verifier < 0)
    Fail("clipboard verifier fork failed");
  if (verifier == 0) {
    ykd::X11ClipboardReader reader;
    ykd::X11ClipboardText text;
    const bool valid =
        reader.Start(display_name) &&
        reader.ReadUtf8(1024, 8, std::chrono::milliseconds(1000), &text) ==
            ykd::X11ClipboardReadStatus::kOk &&
        text.text == expected;
    _exit(valid ? 0 : 20);
  }
  int status = 0;
  for (int attempt = 0; attempt < 2000; ++attempt) {
    while (g_main_context_iteration(nullptr, false) != 0) {
    }
    const pid_t result = waitpid(verifier, &status, WNOHANG);
    if (result == verifier) {
      if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        Fail("clipboard verifier rejected the served offer");
      }
      return;
    }
    if (result < 0)
      Fail("clipboard verifier wait failed");
    g_usleep(1000);
  }
  kill(verifier, SIGKILL);
  waitpid(verifier, &status, 0);
  Fail("clipboard verifier timed out");
}

void VerifyMultipleOffer(const char *display_name) {
  const pid_t verifier = fork();
  if (verifier < 0)
    Fail("MULTIPLE verifier fork failed");
  if (verifier == 0) {
    Display *display = XOpenDisplay(display_name);
    if (display == nullptr)
      _exit(30);
    const Window window = XCreateSimpleWindow(
        display, DefaultRootWindow(display), 0, 0, 1, 1, 0, 0, 0);
    const Atom clipboard = XInternAtom(display, "CLIPBOARD", False);
    const Atom multiple = XInternAtom(display, "MULTIPLE", False);
    const Atom utf8 = XInternAtom(display, "UTF8_STRING", False);
    const Atom timestamp = XInternAtom(display, "TIMESTAMP", False);
    const Atom pairs_property =
        XInternAtom(display, "_YKD_TEST_MULTIPLE", False);
    const Atom text_property =
        XInternAtom(display, "_YKD_TEST_MULTIPLE_TEXT", False);
    const Atom time_property =
        XInternAtom(display, "_YKD_TEST_MULTIPLE_TIME", False);
    const Atom unsupported =
        XInternAtom(display, "application/x-ykd-unsupported", False);
    const Atom unsupported_property =
        XInternAtom(display, "_YKD_TEST_MULTIPLE_UNSUPPORTED", False);
    const unsigned long pairs[] = {utf8,        text_property,
                                   timestamp,   time_property,
                                   unsupported, unsupported_property};
    XChangeProperty(display, window, pairs_property, XA_ATOM, 32,
                    PropModeReplace,
                    reinterpret_cast<const unsigned char *>(pairs), 6);
    XConvertSelection(display, clipboard, multiple, pairs_property, window,
                      CurrentTime);
    XFlush(display);

    XEvent event{};
    do {
      XNextEvent(display, &event);
    } while (event.type != SelectionNotify);
    bool valid = event.xselection.property == pairs_property;
    Atom type = None;
    int format = 0;
    unsigned long count = 0;
    unsigned long after = 0;
    unsigned char *data = nullptr;
    valid = valid &&
            XGetWindowProperty(display, window, pairs_property, 0, 6, False,
                               XA_ATOM, &type, &format, &count, &after,
                               &data) == Success &&
            type == XA_ATOM && format == 32 && count == 6 && after == 0 &&
            data != nullptr;
    if (valid) {
      const auto *returned = reinterpret_cast<unsigned long *>(data);
      valid = returned[0] == utf8 && returned[1] == text_property &&
              returned[2] == timestamp && returned[3] == time_property;
      valid =
          valid && returned[4] == None && returned[5] == unsupported_property;
    }
    if (data != nullptr)
      XFree(data);

    data = nullptr;
    valid = valid &&
            XGetWindowProperty(display, window, text_property, 0, 1024, False,
                               AnyPropertyType, &type, &format, &count, &after,
                               &data) == Success &&
            type == utf8 && format == 8 && after == 0 && data != nullptr &&
            std::string(reinterpret_cast<const char *>(data), count) == kText;
    if (data != nullptr)
      XFree(data);

    data = nullptr;
    valid = valid &&
            XGetWindowProperty(display, window, time_property, 0, 1, False,
                               XA_INTEGER, &type, &format, &count, &after,
                               &data) == Success &&
            type == XA_INTEGER && format == 32 && count == 1 && after == 0;
    if (data != nullptr)
      XFree(data);
    XDestroyWindow(display, window);
    XCloseDisplay(display);
    _exit(valid ? 0 : 31);
  }

  int status = 0;
  for (int attempt = 0; attempt < 2000; ++attempt) {
    while (g_main_context_iteration(nullptr, false) != 0) {
    }
    const pid_t result = waitpid(verifier, &status, WNOHANG);
    if (result == verifier) {
      if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        Fail("MULTIPLE verifier rejected the served offer");
      }
      return;
    }
    if (result < 0)
      Fail("MULTIPLE verifier wait failed");
    g_usleep(1000);
  }
  kill(verifier, SIGKILL);
  waitpid(verifier, &status, 0);
  Fail("MULTIPLE verifier timed out");
}

void VerifyMultipleIncrementalOffer(const char *display_name,
                                    ykd::X11ClipboardReader &reader) {
  Display *display = XOpenDisplay(display_name);
  if (display == nullptr)
    Fail("MULTIPLE INCR display failed");
  const Window window = XCreateSimpleWindow(display, DefaultRootWindow(display),
                                            0, 0, 1, 1, 0, 0, 0);
  XSelectInput(display, window, PropertyChangeMask);
  const Atom clipboard = XInternAtom(display, "CLIPBOARD", False);
  const Atom multiple = XInternAtom(display, "MULTIPLE", False);
  const Atom utf8 = XInternAtom(display, "UTF8_STRING", False);
  const Atom timestamp = XInternAtom(display, "TIMESTAMP", False);
  const Atom incr = XInternAtom(display, "INCR", False);
  const Atom pairs_property =
      XInternAtom(display, "_YKD_TEST_MULTIPLE_INCR", False);
  const Atom text_property =
      XInternAtom(display, "_YKD_TEST_MULTIPLE_INCR_TEXT", False);
  const Atom time_property =
      XInternAtom(display, "_YKD_TEST_MULTIPLE_INCR_TIME", False);
  const unsigned long pairs[] = {utf8, text_property, timestamp, time_property};
  XChangeProperty(display, window, pairs_property, XA_ATOM, 32, PropModeReplace,
                  reinterpret_cast<const unsigned char *>(pairs), 4);
  XConvertSelection(display, clipboard, multiple, pairs_property, window,
                    CurrentTime);
  XFlush(display);

  bool notified = false;
  for (int attempt = 0; attempt < 2000 && !notified; ++attempt) {
    ykd::X11ClipboardReaderTestPeer::Drain(reader);
    while (XPending(display) != 0) {
      XEvent event{};
      XNextEvent(display, &event);
      if (event.type == SelectionNotify) {
        notified = event.xselection.property == pairs_property;
      }
    }
    if (!notified)
      g_usleep(1000);
  }
  if (!notified)
    Fail("MULTIPLE INCR request was not answered");

  Atom type = None;
  int format = 0;
  unsigned long count = 0;
  unsigned long after = 0;
  unsigned char *data = nullptr;
  bool valid =
      XGetWindowProperty(display, window, pairs_property, 0, 4, False, XA_ATOM,
                         &type, &format, &count, &after, &data) == Success &&
      type == XA_ATOM && format == 32 && count == 4 && after == 0 &&
      data != nullptr;
  if (valid) {
    const auto *returned = reinterpret_cast<unsigned long *>(data);
    valid = returned[0] == utf8 && returned[1] == text_property &&
            returned[2] == timestamp && returned[3] == time_property;
  }
  if (data != nullptr)
    XFree(data);

  data = nullptr;
  valid = valid &&
          XGetWindowProperty(display, window, text_property, 0, 1, False,
                             AnyPropertyType, &type, &format, &count, &after,
                             &data) == Success &&
          type == incr && format == 32 && count == 1;
  if (data != nullptr)
    XFree(data);

  data = nullptr;
  valid = valid &&
          XGetWindowProperty(display, window, time_property, 0, 1, False,
                             XA_INTEGER, &type, &format, &count, &after,
                             &data) == Success &&
          type == XA_INTEGER && format == 32 && count == 1 && after == 0;
  if (data != nullptr)
    XFree(data);
  if (!valid)
    Fail("MULTIPLE did not preserve its INCR pair results");

  std::string received;
  XDeleteProperty(display, window, text_property);
  XFlush(display);
  bool complete = false;
  for (int attempt = 0; attempt < 4000 && !complete; ++attempt) {
    ykd::X11ClipboardReaderTestPeer::Drain(reader);
    while (XPending(display) != 0) {
      XEvent event{};
      XNextEvent(display, &event);
      if (event.type != PropertyNotify ||
          event.xproperty.state != PropertyNewValue ||
          event.xproperty.atom != text_property) {
        continue;
      }
      data = nullptr;
      if (XGetWindowProperty(display, window, text_property, 0, 1024, True,
                             AnyPropertyType, &type, &format, &count, &after,
                             &data) != Success ||
          type != utf8 || format != 8 || after != 0) {
        if (data != nullptr)
          XFree(data);
        Fail("MULTIPLE INCR chunk was invalid");
      }
      if (count == 0) {
        complete = true;
      } else {
        received.append(reinterpret_cast<const char *>(data), count);
      }
      if (data != nullptr)
        XFree(data);
    }
    if (!complete)
      g_usleep(1000);
  }
  XDestroyWindow(display, window);
  XCloseDisplay(display);
  if (!complete || received != kText) {
    Fail("MULTIPLE INCR payload was not transferred exactly");
  }
}

void VerifyMultipleInvalidPropertyFailure(const char *display_name,
                                          ykd::X11ClipboardReader &reader) {
  Display *display = XOpenDisplay(display_name);
  if (display == nullptr)
    Fail("MULTIPLE invalid-property display failed");
  const Window window = XCreateSimpleWindow(display, DefaultRootWindow(display),
                                            0, 0, 1, 1, 0, 0, 0);
  const Atom clipboard = XInternAtom(display, "CLIPBOARD", False);
  const Atom multiple = XInternAtom(display, "MULTIPLE", False);
  const Atom utf8 = XInternAtom(display, "UTF8_STRING", False);
  const Atom pairs_property =
      XInternAtom(display, "_YKD_TEST_MULTIPLE_BAD_PROPERTY", False);
  const Atom invalid_property = static_cast<Atom>(0x7fffffffUL);
  const unsigned long pairs[] = {utf8, invalid_property};
  XChangeProperty(display, window, pairs_property, XA_ATOM, 32, PropModeReplace,
                  reinterpret_cast<const unsigned char *>(pairs), 2);
  XConvertSelection(display, clipboard, multiple, pairs_property, window,
                    CurrentTime);
  XFlush(display);

  bool notified = false;
  for (int attempt = 0; attempt < 2000 && !notified; ++attempt) {
    ykd::X11ClipboardReaderTestPeer::Drain(reader);
    while (XPending(display) != 0) {
      XEvent event{};
      XNextEvent(display, &event);
      if (event.type == SelectionNotify) {
        notified = event.xselection.property == pairs_property;
      }
    }
    if (!notified)
      g_usleep(1000);
  }

  Atom type = None;
  int format = 0;
  unsigned long count = 0;
  unsigned long after = 0;
  unsigned char *data = nullptr;
  bool valid =
      notified &&
      XGetWindowProperty(display, window, pairs_property, 0, 2, False, XA_ATOM,
                         &type, &format, &count, &after, &data) == Success &&
      type == XA_ATOM && format == 32 && count == 2 && after == 0 &&
      data != nullptr;
  if (valid) {
    const auto *returned = reinterpret_cast<unsigned long *>(data);
    valid = returned[0] == None && returned[1] == invalid_property;
  }
  if (data != nullptr)
    XFree(data);
  XDestroyWindow(display, window);
  XCloseDisplay(display);
  if (!valid) {
    Fail("MULTIPLE invalid property was reported as a successful pair");
  }
}

void VerifyIncrementalContinuesAfterSelectionClear(
    const char *display_name, ykd::X11ClipboardReader &reader,
    const ykd::X11ClipboardSnapshot &snapshot) {
  Display *display = XOpenDisplay(display_name);
  if (display == nullptr)
    Fail("SelectionClear INCR display failed");
  const Window requestor = XCreateSimpleWindow(
      display, DefaultRootWindow(display), 0, 0, 1, 1, 0, 0, 0);
  const Window takeover = XCreateSimpleWindow(
      display, DefaultRootWindow(display), 0, 0, 1, 1, 0, 0, 0);
  XSelectInput(display, requestor, PropertyChangeMask);
  const Atom clipboard = XInternAtom(display, "CLIPBOARD", False);
  const Atom utf8 = XInternAtom(display, "UTF8_STRING", False);
  const Atom incr = XInternAtom(display, "INCR", False);
  const Atom property =
      XInternAtom(display, "_YKD_TEST_SELECTION_CLEAR_INCR", False);
  XConvertSelection(display, clipboard, utf8, property, requestor, CurrentTime);
  XFlush(display);

  bool notified = false;
  for (int attempt = 0; attempt < 2000 && !notified; ++attempt) {
    ykd::X11ClipboardReaderTestPeer::Drain(reader);
    while (XPending(display) != 0) {
      XEvent event{};
      XNextEvent(display, &event);
      if (event.type == SelectionNotify) {
        notified = event.xselection.property == property;
      }
    }
    if (!notified)
      g_usleep(1000);
  }
  if (!notified)
    Fail("SelectionClear INCR request was not answered");

  Atom type = None;
  int format = 0;
  unsigned long count = 0;
  unsigned long after = 0;
  unsigned char *data = nullptr;
  const bool incremental =
      XGetWindowProperty(display, requestor, property, 0, 1, False,
                         AnyPropertyType, &type, &format, &count, &after,
                         &data) == Success &&
      type == incr && format == 32 && count == 1;
  if (data != nullptr)
    XFree(data);
  if (!incremental)
    Fail("SelectionClear test did not start INCR");

  XSetSelectionOwner(display, clipboard, takeover, CurrentTime);
  XSync(display, False);
  for (int attempt = 0; attempt < 100; ++attempt) {
    ykd::X11ClipboardReaderTestPeer::Drain(reader);
    if (!reader.owns_clipboard())
      break;
    g_usleep(1000);
  }
  if (reader.owns_clipboard())
    Fail("SelectionClear was not observed");
  const Time takeover_timestamp = reader.observed_selection_timestamp();
  if (takeover_timestamp == CurrentTime ||
      !reader.AcquireSnapshotIfState(reader.revision(), takeover,
                                     takeover_timestamp, snapshot)) {
    Fail("snapshot could not be reacquired during retained INCR");
  }
  if (ykd::X11ClipboardReaderTestPeer::OutgoingTransferCount(reader) != 1) {
    Fail("clipboard reacquisition discarded an ongoing INCR transfer");
  }

  std::string received;
  XDeleteProperty(display, requestor, property);
  XFlush(display);
  bool complete = false;
  for (int attempt = 0; attempt < 4000 && !complete; ++attempt) {
    ykd::X11ClipboardReaderTestPeer::Drain(reader);
    while (XPending(display) != 0) {
      XEvent event{};
      XNextEvent(display, &event);
      if (event.type != PropertyNotify ||
          event.xproperty.state != PropertyNewValue ||
          event.xproperty.atom != property) {
        continue;
      }
      data = nullptr;
      if (XGetWindowProperty(display, requestor, property, 0, 1024, True,
                             AnyPropertyType, &type, &format, &count, &after,
                             &data) != Success ||
          type != utf8 || format != 8 || after != 0) {
        if (data != nullptr)
          XFree(data);
        Fail("post-SelectionClear INCR chunk was invalid");
      }
      if (count == 0) {
        complete = true;
      } else {
        received.append(reinterpret_cast<const char *>(data), count);
      }
      if (data != nullptr)
        XFree(data);
    }
    if (!complete)
      g_usleep(1000);
  }
  if (!complete || received != kText ||
      ykd::X11ClipboardReaderTestPeer::OutgoingTransferCount(reader) != 0) {
    Fail("INCR did not finish from retained offer after SelectionClear");
  }
  XDestroyWindow(display, requestor);
  XDestroyWindow(display, takeover);
  XCloseDisplay(display);
}

void VerifyDestroyedIncrementalRequestor(
    const char *display_name, const ykd::X11ClipboardReader &reader) {
  const pid_t verifier = fork();
  if (verifier < 0)
    Fail("destroyed requestor verifier fork failed");
  if (verifier == 0) {
    Display *display = XOpenDisplay(display_name);
    if (display == nullptr)
      _exit(40);
    const Window window = XCreateSimpleWindow(
        display, DefaultRootWindow(display), 0, 0, 1, 1, 0, 0, 0);
    const Atom clipboard = XInternAtom(display, "CLIPBOARD", False);
    const Atom utf8 = XInternAtom(display, "UTF8_STRING", False);
    const Atom property = XInternAtom(display, "_YKD_TEST_ABANDONED", False);
    const Atom incr = XInternAtom(display, "INCR", False);
    XConvertSelection(display, clipboard, utf8, property, window, CurrentTime);
    XFlush(display);
    XEvent event{};
    do {
      XNextEvent(display, &event);
    } while (event.type != SelectionNotify);
    Atom type = None;
    int format = 0;
    unsigned long count = 0;
    unsigned long after = 0;
    unsigned char *data = nullptr;
    const bool incremental =
        event.xselection.property == property &&
        XGetWindowProperty(display, window, property, 0, 1, False,
                           AnyPropertyType, &type, &format, &count, &after,
                           &data) == Success &&
        type == incr && format == 32 && count == 1;
    if (data != nullptr)
      XFree(data);
    XDestroyWindow(display, window);
    XSync(display, False);
    XCloseDisplay(display);
    _exit(incremental ? 0 : 41);
  }

  int status = 0;
  bool completed = false;
  for (int attempt = 0; attempt < 2000; ++attempt) {
    while (g_main_context_iteration(nullptr, false) != 0) {
    }
    const pid_t result = waitpid(verifier, &status, WNOHANG);
    if (result == verifier) {
      completed = true;
      break;
    }
    if (result < 0)
      Fail("destroyed requestor verifier wait failed");
    g_usleep(1000);
  }
  if (!completed || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
    if (!completed) {
      kill(verifier, SIGKILL);
      waitpid(verifier, &status, 0);
    }
    Fail("destroyed requestor did not receive an INCR offer");
  }
  for (int attempt = 0; attempt < 100; ++attempt) {
    while (g_main_context_iteration(nullptr, false) != 0) {
    }
    if (ykd::X11ClipboardReaderTestPeer::OutgoingTransferCount(reader) == 0) {
      return;
    }
    g_usleep(1000);
  }
  Fail("destroyed requestor retained an outgoing INCR transfer");
}

struct StalledIncrementalRequest final {
  Display *display = nullptr;
  Window window = None;
  Atom property = None;
  bool accepted = false;
};

StalledIncrementalRequest
StartStalledIncrementalRequest(const char *display_name,
                               ykd::X11ClipboardReader &reader) {
  StalledIncrementalRequest request;
  request.display = XOpenDisplay(display_name);
  if (request.display == nullptr)
    Fail("stalled request display failed");
  request.window = XCreateSimpleWindow(
      request.display, DefaultRootWindow(request.display), 0, 0, 1, 1, 0, 0, 0);
  const Atom clipboard = XInternAtom(request.display, "CLIPBOARD", False);
  const Atom utf8 = XInternAtom(request.display, "UTF8_STRING", False);
  request.property =
      XInternAtom(request.display, "_YKD_TEST_STALLED_INCR", False);
  XSelectInput(request.display, request.window, PropertyChangeMask);
  XConvertSelection(request.display, clipboard, utf8, request.property,
                    request.window, CurrentTime);
  XFlush(request.display);

  for (int attempt = 0; attempt < 2000; ++attempt) {
    ykd::X11ClipboardReaderTestPeer::Drain(reader);
    while (XPending(request.display) != 0) {
      XEvent event{};
      XNextEvent(request.display, &event);
      if (event.type != SelectionNotify)
        continue;
      if (event.xselection.property == None)
        return request;
      Atom type = None;
      int format = 0;
      unsigned long count = 0;
      unsigned long after = 0;
      unsigned char *data = nullptr;
      const Atom incr = XInternAtom(request.display, "INCR", False);
      request.accepted =
          XGetWindowProperty(request.display, request.window, request.property,
                             0, 1, False, AnyPropertyType, &type, &format,
                             &count, &after, &data) == Success &&
          type == incr && format == 32 && count == 1;
      if (data != nullptr)
        XFree(data);
      return request;
    }
    g_usleep(1000);
  }
  Fail("stalled INCR request timed out");
}

void CloseStalledRequest(StalledIncrementalRequest *request) {
  if (request->display == nullptr)
    return;
  if (request->window != None) {
    XDestroyWindow(request->display, request->window);
  }
  XCloseDisplay(request->display);
  request->display = nullptr;
  request->window = None;
}

void VerifyImmediateRequestorDestruction(const char *display_name,
                                         ykd::X11ClipboardReader &reader) {
  Display *display = XOpenDisplay(display_name);
  if (display == nullptr)
    Fail("immediate destruction display failed");
  const Window window = XCreateSimpleWindow(display, DefaultRootWindow(display),
                                            0, 0, 1, 1, 0, 0, 0);
  const Atom clipboard = XInternAtom(display, "CLIPBOARD", False);
  const Atom utf8 = XInternAtom(display, "UTF8_STRING", False);
  const Atom property = XInternAtom(display, "_YKD_TEST_GONE", False);
  XConvertSelection(display, clipboard, utf8, property, window, CurrentTime);
  XSync(display, False);
  XDestroyWindow(display, window);
  XSync(display, False);
  XCloseDisplay(display);
  ykd::X11ClipboardReaderTestPeer::Drain(reader);
}

void VerifyDeleteThenDestroy(const char *display_name,
                             ykd::X11ClipboardReader &reader) {
  StalledIncrementalRequest request =
      StartStalledIncrementalRequest(display_name, reader);
  if (!request.accepted)
    Fail("delete-then-destroy INCR was rejected");
  XDeleteProperty(request.display, request.window, request.property);
  XSync(request.display, False);
  XDestroyWindow(request.display, request.window);
  request.window = None;
  XSync(request.display, False);
  ykd::X11ClipboardReaderTestPeer::Drain(reader);
  XCloseDisplay(request.display);
  request.display = nullptr;
}

void VerifyOutgoingTransferExpiry(const char *display_name,
                                  ykd::X11ClipboardReader &reader) {
  std::vector<StalledIncrementalRequest> requests;
  requests.reserve(17);
  for (int index = 0; index < 16; ++index) {
    requests.push_back(StartStalledIncrementalRequest(display_name, reader));
    if (!requests.back().accepted) {
      Fail("outgoing INCR limit was reached too early");
    }
  }
  StalledIncrementalRequest rejected =
      StartStalledIncrementalRequest(display_name, reader);
  if (rejected.accepted)
    Fail("outgoing INCR limit was not enforced");
  CloseStalledRequest(&rejected);

  ykd::X11ClipboardReaderTestPeer::ExpireOutgoingTransfers(reader);
  StalledIncrementalRequest admitted =
      StartStalledIncrementalRequest(display_name, reader);
  if (!admitted.accepted ||
      ykd::X11ClipboardReaderTestPeer::OutgoingTransferCount(reader) != 1) {
    Fail("expired outgoing INCR transfers were not pruned at admission");
  }
  CloseStalledRequest(&admitted);
  for (auto &request : requests)
    CloseStalledRequest(&request);
  ykd::X11ClipboardReaderTestPeer::Drain(reader);
}

void VerifyStaleSelectionRequest(const char *display_name,
                                 ykd::X11ClipboardReader &reader) {
  Display *display = XOpenDisplay(display_name);
  if (display == nullptr)
    Fail("stale request display failed");
  const Window window = XCreateSimpleWindow(display, DefaultRootWindow(display),
                                            0, 0, 1, 1, 0, 0, 0);
  const Atom clipboard = XInternAtom(display, "CLIPBOARD", False);
  const Atom utf8 = XInternAtom(display, "UTF8_STRING", False);
  const Atom property = XInternAtom(display, "_YKD_TEST_STALE_TIME", False);
  const Time selection_time = reader.observed_selection_timestamp();
  const Time stale_time = selection_time - 1;
  XConvertSelection(display, clipboard, utf8, property, window, stale_time);
  XFlush(display);
  for (int attempt = 0; attempt < 2000; ++attempt) {
    ykd::X11ClipboardReaderTestPeer::Drain(reader);
    while (XPending(display) != 0) {
      XEvent event{};
      XNextEvent(display, &event);
      if (event.type != SelectionNotify)
        continue;
      const bool rejected = event.xselection.property == None;
      XDestroyWindow(display, window);
      XCloseDisplay(display);
      if (!rejected)
        Fail("stale SelectionRequest timestamp was accepted");
      return;
    }
    g_usleep(1000);
  }
  XDestroyWindow(display, window);
  XCloseDisplay(display);
  Fail("stale SelectionRequest was not answered");
}

}

int main() {
  const char *display_name = std::getenv("DISPLAY");
  if (display_name == nullptr)
    Fail("DISPLAY is missing");

  {
    OwnerProcess preexisting_owner(display_name);
    ykd::X11ClipboardReader preexisting_reader;
    if (!preexisting_reader.Start(display_name)) {
      Fail("reader did not start with a pre-existing owner");
    }
    ykd::X11ClipboardText preexisting_text;
    if (preexisting_reader.ReadUtf8(1024, 8, std::chrono::milliseconds(1000),
                                    &preexisting_text) !=
            ykd::X11ClipboardReadStatus::kOk ||
        preexisting_text.text != kText) {
      Fail("pre-existing owner could not be read safely");
    }
    if (preexisting_reader.AcquireTextIfState(
            preexisting_reader.revision(), preexisting_text.owner,
            preexisting_reader.observed_selection_timestamp(),
            "must remain fail-closed")) {
      Fail("unknown startup timestamp allowed clipboard acquisition");
    }
    preexisting_reader.Stop();
  }
  {
    ykd::X11ClipboardReader destroyed_reader;
    if (!destroyed_reader.Start(display_name)) {
      Fail("authoritative-window reader did not start");
    }
    Display *destroyer = XOpenDisplay(display_name);
    if (destroyer == nullptr)
      Fail("authoritative-window destroyer failed");
    const Atom clipboard = XInternAtom(destroyer, "CLIPBOARD", False);
    const Window source = XCreateSimpleWindow(
        destroyer, DefaultRootWindow(destroyer), 0, 0, 1, 1, 0, 0, 0);
    XSetSelectionOwner(destroyer, clipboard, source, CurrentTime);
    XSync(destroyer, False);
    for (int attempt = 0; attempt < 1000 &&
                          destroyed_reader.observed_selection_owner() != source;
         ++attempt) {
      destroyed_reader.Drain();
      g_usleep(1000);
    }
    if (!destroyed_reader.AcquireTextIfState(
            destroyed_reader.revision(), source,
            destroyed_reader.observed_selection_timestamp(), "owned")) {
      Fail("authoritative-window reader could not acquire clipboard");
    }
    if (XGetSelectionOwner(destroyer, clipboard) !=
        destroyed_reader.owner_window()) {
      Fail("authoritative window did not own CLIPBOARD before destruction");
    }
    XDestroyWindow(destroyer, destroyed_reader.owner_window());
    XSync(destroyer, False);
    for (int attempt = 0; attempt < 1000 && destroyed_reader.active();
         ++attempt) {
      destroyed_reader.Drain();
      g_usleep(1000);
    }
    if (destroyed_reader.active()) {
      Fail("destroyed authoritative window left capabilities active");
    }
    destroyed_reader.Stop();
    XDestroyWindow(destroyer, source);
    XCloseDisplay(destroyer);
  }
  {
    ykd::X11ClipboardReader immediate_stop_reader;
    if (!immediate_stop_reader.Start(display_name)) {
      Fail("immediate-stop reader did not start");
    }
    Display *destroyer = XOpenDisplay(display_name);
    if (destroyer == nullptr)
      Fail("immediate-stop destroyer failed");
    XDestroyWindow(destroyer, immediate_stop_reader.owner_window());
    XSync(destroyer, False);
    immediate_stop_reader.Stop();
    XCloseDisplay(destroyer);
  }
  {
    OwnerProcess timeout_owner(display_name, OwnerMode::kTimeout);
    ykd::X11ClipboardReader interrupted_reader;
    if (!interrupted_reader.Start(display_name)) {
      Fail("mid-capture reader did not start");
    }
    const Window authority = interrupted_reader.owner_window();
    const pid_t destroyer = fork();
    if (destroyer < 0)
      Fail("mid-capture destroyer fork failed");
    if (destroyer == 0) {
      Display *display = XOpenDisplay(display_name);
      if (display == nullptr)
        _exit(50);
      g_usleep(5000);
      XDestroyWindow(display, authority);
      XSync(display, False);
      XCloseDisplay(display);
      _exit(0);
    }
    ykd::X11ClipboardSnapshot interrupted_snapshot;
    const auto status = interrupted_reader.Capture(
        1024, 8, std::chrono::milliseconds(1000), &interrupted_snapshot);
    int destroyer_status = 0;
    waitpid(destroyer, &destroyer_status, 0);
    if (status != ykd::X11ClipboardReadStatus::kUnavailable ||
        !WIFEXITED(destroyer_status) || WEXITSTATUS(destroyer_status) != 0) {
      Fail("authority loss during capture was not fail-closed");
    }
    interrupted_reader.Stop();
  }

  ykd::X11ClipboardReader reader;
  if (!reader.Start(display_name))
    Fail("clipboard reader did not start");
  OwnerProcess owner(display_name);

  if (ykd::X11ClipboardReaderTestPeer::RequestWithExpiredDeadline(reader) !=
      ykd::X11ClipboardReadStatus::kTimeout) {
    Fail("expired operation deadline started an incoming request");
  }

  ykd::X11ClipboardSnapshot snapshot;
  const auto capture_status =
      reader.Capture(1024, 8, std::chrono::milliseconds(1000), &snapshot);
  if (capture_status != ykd::X11ClipboardReadStatus::kOk) {
    Fail("bounded snapshot capture failed");
  }
  if (snapshot.owner == None || snapshot.payloads.size() != 3) {
    Fail("snapshot did not retain the offered data targets");
  }

  Display *inspection_display = XOpenDisplay(display_name);
  if (inspection_display == nullptr)
    Fail("inspection display failed");
  const auto *utf8 = FindPayload(snapshot, inspection_display, "UTF8_STRING");
  const auto *custom =
      FindPayload(snapshot, inspection_display, "application/x-ykd-test");
  const auto *empty =
      FindPayload(snapshot, inspection_display, "application/x-ykd-empty");
  if (utf8 == nullptr || utf8->format != 8 ||
      std::string(reinterpret_cast<const char *>(utf8->bytes.data()),
                  utf8->bytes.size()) != kText) {
    Fail("INCR UTF-8 payload was not assembled exactly");
  }
  if (custom == nullptr || custom->format != 16 || custom->bytes.size() != 4) {
    Fail("custom 16-bit payload was not preserved");
  }
  if (empty == nullptr || empty->format != 8 || !empty->bytes.empty()) {
    Fail("empty clipboard payload was not preserved");
  }
  XCloseDisplay(inspection_display);

  ykd::X11ClipboardText text;
  if (reader.ReadUtf8(1024, 8, std::chrono::milliseconds(1000), &text) !=
          ykd::X11ClipboardReadStatus::kOk ||
      text.text != kText || text.owner != snapshot.owner) {
    Fail("stable UTF-8 read failed");
  }
  if (reader.ReadUtf8(1024, 1, std::chrono::milliseconds(1000), &text) !=
      ykd::X11ClipboardReadStatus::kTooManyTargets) {
    Fail("stable UTF-8 read ignored the target-count limit");
  }

  const Time source_timestamp = reader.observed_selection_timestamp();
  if (source_timestamp == CurrentTime ||
      !reader.AcquireSnapshotIfState(reader.revision(), snapshot.owner,
                                     source_timestamp, snapshot) ||
      !reader.owns_clipboard()) {
    Fail("snapshot compare-and-swap ownership failed");
  }
  VerifyMultipleOffer(display_name);
  VerifyMultipleInvalidPropertyFailure(display_name, reader);
  ykd::X11ClipboardReaderTestPeer::ForceIncrementalOffers(reader);
  VerifyMultipleIncrementalOffer(display_name, reader);
  VerifyOwnedText(display_name, kText);
  VerifyIncrementalContinuesAfterSelectionClear(display_name, reader, snapshot);
  VerifyDestroyedIncrementalRequestor(display_name, reader);
  VerifyImmediateRequestorDestruction(display_name, reader);
  VerifyDeleteThenDestroy(display_name, reader);
  VerifyOutgoingTransferExpiry(display_name, reader);
  VerifyStaleSelectionRequest(display_name, reader);
  if (reader.AcquireTextIfState(reader.revision(), snapshot.owner,
                                source_timestamp, "stale overwrite")) {
    Fail("compare-and-swap accepted a stale owner");
  }
  VerifyOwnedText(display_name, kText);
  const Time snapshot_offer_timestamp = reader.observed_selection_timestamp();
  if (snapshot_offer_timestamp == CurrentTime ||
      !reader.AcquireTextIfState(reader.revision(), reader.owner_window(),
                                 snapshot_offer_timestamp, "replacement")) {
    Fail("text compare-and-swap ownership failed");
  }
  VerifyOwnedText(display_name, "replacement");
  const Time replacement_timestamp = reader.observed_selection_timestamp();
  if (replacement_timestamp == CurrentTime ||
      !reader.AcquireSnapshotIfState(reader.revision(), reader.owner_window(),
                                     replacement_timestamp, snapshot)) {
    Fail("snapshot restore compare-and-swap failed");
  }
  VerifyOwnedText(display_name, kText);

  ykd::X11ClipboardSnapshot rejected;
  if (reader.Capture(1024, 1, std::chrono::milliseconds(1000), &rejected) !=
      ykd::X11ClipboardReadStatus::kTooManyTargets) {
    Fail("target-count limit was not enforced");
  }
  if (reader.Capture(4, 8, std::chrono::milliseconds(1000), &rejected) !=
      ykd::X11ClipboardReadStatus::kTooLarge) {
    Fail("byte limit was not enforced before payload allocation");
  }

  {
    OwnerProcess oversized(display_name, OwnerMode::kOversizedIncrement);
    if (reader.ReadUtf8(128, 8, std::chrono::milliseconds(1000), &text) !=
        ykd::X11ClipboardReadStatus::kTooLarge) {
      Fail("oversized INCR advertisement bypassed the byte limit");
    }
  }
  {
    OwnerProcess malformed(display_name, OwnerMode::kMalformedIncrement);
    if (reader.ReadUtf8(128, 8, std::chrono::milliseconds(1000), &text) !=
        ykd::X11ClipboardReadStatus::kProtocolError) {
      Fail("malformed INCR header was accepted");
    }
  }
  {
    OwnerProcess recovering(display_name, OwnerMode::kOversizedThenValid);
    if (reader.ReadUtf8(128, 8, std::chrono::milliseconds(1000), &text) !=
            ykd::X11ClipboardReadStatus::kTooLarge ||
        reader.ReadUtf8(128, 8, std::chrono::milliseconds(1000), &text) !=
            ykd::X11ClipboardReadStatus::kOk ||
        text.text != kText) {
      Fail("failed INCR contaminated the next same-owner read");
    }
  }
  {
    OwnerProcess timeout(display_name, OwnerMode::kTimeout);
    if (reader.ReadUtf8(128, 8, std::chrono::milliseconds(25), &text) !=
        ykd::X11ClipboardReadStatus::kTimeout) {
      Fail("selection timeout was not bounded");
    }
  }
  {
    OwnerProcess changing(display_name, OwnerMode::kOwnerChanges);
    if (reader.ReadUtf8(128, 8, std::chrono::milliseconds(1000), &text) !=
        ykd::X11ClipboardReadStatus::kOwnerChanged) {
      Fail("owner change during transfer was not rejected");
    }
  }
  {
    OwnerProcess invalid_target(display_name, OwnerMode::kInvalidTargetAtom);
    ykd::X11ClipboardSnapshot invalid_snapshot;
    if (reader.Capture(1024, 8, std::chrono::milliseconds(1000),
                       &invalid_snapshot) !=
        ykd::X11ClipboardReadStatus::kProtocolError) {
      Fail("invalid TARGETS atom was not rejected safely");
    }
  }
  {
    OwnerProcess destructive(display_name, OwnerMode::kDestroysTransferWindow);
    if (reader.ReadUtf8(128, 8, std::chrono::milliseconds(1000), &text) !=
        ykd::X11ClipboardReadStatus::kProtocolError) {
      Fail("destroyed incoming transfer window was not rejected safely");
    }
  }

  Display *aba_display = XOpenDisplay(display_name);
  if (aba_display == nullptr)
    Fail("ABA display failed");
  const Window aba_window = XCreateSimpleWindow(
      aba_display, DefaultRootWindow(aba_display), 0, 0, 1, 1, 0, 0, 0);
  const Atom clipboard = XInternAtom(aba_display, "CLIPBOARD", False);
  XSetSelectionOwner(aba_display, clipboard, aba_window, CurrentTime);
  XSync(aba_display, False);
  const Time before_aba = reader.observed_selection_timestamp();
  for (int attempt = 0;
       attempt < 1000 && reader.observed_selection_timestamp() == before_aba;
       ++attempt) {
    ykd::X11ClipboardReaderTestPeer::Drain(reader);
    g_usleep(1000);
  }
  const Time first_aba_timestamp = reader.observed_selection_timestamp();
  if (first_aba_timestamp == CurrentTime || first_aba_timestamp == before_aba) {
    Fail("reader did not observe the first ABA owner timestamp");
  }
  const std::int64_t first_aba_revision = reader.revision();
  XSetSelectionOwner(aba_display, clipboard, aba_window, first_aba_timestamp);
  XSync(aba_display, False);
  if (reader.AcquireTextIfState(first_aba_revision, aba_window,
                                first_aba_timestamp,
                                "must not overwrite same-owner ABA")) {
    Fail("equal-timestamp same-owner ABA bypassed revision-bound CAS");
  }
  XDestroyWindow(aba_display, aba_window);
  XCloseDisplay(aba_display);

  reader.Stop();
  if (reader.active())
    Fail("clipboard reader did not stop");
  return EXIT_SUCCESS;
}
