#include "x11_clipboard_transaction.h"

#include <thread>

namespace ykd {

bool X11ClipboardTransaction::WaitForOwnedRevision(
    std::int64_t baseline_revision,
    std::chrono::steady_clock::time_point deadline, std::int64_t *revision) {
  while (std::chrono::steady_clock::now() < deadline) {
    port_.Drain();
    if (!port_.active())
      return false;
    const std::int64_t current = port_.revision();
    if (current != baseline_revision) {
      if (port_.owner() == port_.owned_window()) {
        *revision = current;
        return true;
      }
      return false;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  port_.Drain();
  if (!port_.active())
    return false;
  return false;
}

X11ClipboardTransactionResult X11ClipboardTransaction::Run(
    std::int64_t expected_revision, std::chrono::milliseconds timeout,
    const std::string &written_text, const std::string &rollback_text,
    const AcquireOperation &acquire) {
  port_.Drain();
  if (!port_.active()) {
    return {X11ClipboardTransactionStatus::kUnavailable, 0, {}};
  }
  if (port_.revision() != expected_revision) {
    return {X11ClipboardTransactionStatus::kConflict, 0, {}};
  }

  const Window expected_owner = port_.owner();
  const Time expected_timestamp = port_.selection_timestamp();
  if (!acquire(expected_revision, expected_owner, expected_timestamp)) {
    return {X11ClipboardTransactionStatus::kConflict, 0, {}};
  }

  const auto deadline = std::chrono::steady_clock::now() + timeout;
  std::int64_t revision = expected_revision + 1;
  const bool observed =
      WaitForOwnedRevision(expected_revision, deadline, &revision);
  if (observed && port_.active() && revision == expected_revision + 1) {
    return {X11ClipboardTransactionStatus::kCommitted, revision, {}};
  }

  port_.Drain();
  if (!port_.active()) {
    return {X11ClipboardTransactionStatus::kUnavailable, 0, {}};
  }
  if (port_.owner() != port_.owned_window()) {
    return {X11ClipboardTransactionStatus::kConflict, 0, {}};
  }

  const std::int64_t rollback_baseline = port_.revision();
  if (port_.AcquireRollbackText(rollback_baseline, port_.owned_window(),
                                port_.selection_timestamp(), rollback_text)) {
    const auto rollback_deadline = std::chrono::steady_clock::now() + timeout;
    std::int64_t rollback_revision = rollback_baseline + 1;
    if (WaitForOwnedRevision(rollback_baseline, rollback_deadline,
                             &rollback_revision)) {
      return {X11ClipboardTransactionStatus::kRolledBack, rollback_revision,
              rollback_text};
    }
    port_.Drain();
    if (!port_.active()) {
      return {X11ClipboardTransactionStatus::kUnavailable, 0, {}};
    }
    if (port_.owner() != port_.owned_window()) {
      return {X11ClipboardTransactionStatus::kConflict, 0, {}};
    }
    return {X11ClipboardTransactionStatus::kRolledBack, port_.revision(),
            rollback_text};
  }

  port_.Drain();
  if (!port_.active()) {
    return {X11ClipboardTransactionStatus::kUnavailable, 0, {}};
  }
  if (port_.owner() != port_.owned_window()) {
    return {X11ClipboardTransactionStatus::kConflict, 0, {}};
  }
  return {X11ClipboardTransactionStatus::kAmbiguous, port_.revision(),
          written_text};
}

}
