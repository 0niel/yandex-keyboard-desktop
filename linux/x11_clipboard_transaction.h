#ifndef RUNNER_X11_CLIPBOARD_TRANSACTION_H_
#define RUNNER_X11_CLIPBOARD_TRANSACTION_H_

#include <X11/Xlib.h>

#include <chrono>
#include <cstdint>
#include <functional>
#include <string>
#include <utility>

namespace ykd {

enum class X11ClipboardTransactionStatus {
  kCommitted,
  kConflict,
  kRolledBack,
  kAmbiguous,
  kUnavailable,
};

struct X11ClipboardTransactionResult final {
  X11ClipboardTransactionResult(X11ClipboardTransactionStatus result_status,
                                std::int64_t result_revision,
                                std::string result_current_text)
      : status(result_status), revision(result_revision),
        current_text(std::move(result_current_text)) {}

  X11ClipboardTransactionStatus status;
  std::int64_t revision;
  std::string current_text;
};

class X11ClipboardTransactionPort {
public:
  virtual ~X11ClipboardTransactionPort() = default;

  virtual void Drain() = 0;
  virtual bool active() const = 0;
  virtual std::int64_t revision() const = 0;
  virtual Window owner() const = 0;
  virtual Time selection_timestamp() const = 0;
  virtual Window owned_window() const = 0;
  virtual bool AcquireRollbackText(std::int64_t expected_revision,
                                   Window expected_owner,
                                   Time expected_selection_timestamp,
                                   const std::string &text) = 0;
};

class X11ClipboardTransaction final {
public:
  using AcquireOperation = std::function<bool(std::int64_t, Window, Time)>;

  explicit X11ClipboardTransaction(X11ClipboardTransactionPort &port)
      : port_(port) {}

  X11ClipboardTransactionResult Run(std::int64_t expected_revision,
                                    std::chrono::milliseconds timeout,
                                    const std::string &written_text,
                                    const std::string &rollback_text,
                                    const AcquireOperation &acquire);

private:
  bool WaitForOwnedRevision(std::int64_t baseline_revision,
                            std::chrono::steady_clock::time_point deadline,
                            std::int64_t *revision);

  X11ClipboardTransactionPort &port_;
};

}

#endif
