#include "x11_clipboard_transaction.h"

#include <cstdlib>
#include <iostream>
#include <string>

namespace {

constexpr Window kExternalOwner = 0x100;
constexpr Window kOwnedWindow = 0x200;
constexpr Window kTakeoverOwner = 0x300;
constexpr Time kTimestamp = 42;

[[noreturn]] void Fail(const char *message) {
  std::cerr << message << '\n';
  std::exit(EXIT_FAILURE);
}

void Check(bool condition, const char *message) {
  if (!condition)
    Fail(message);
}

class FakePort final : public ykd::X11ClipboardTransactionPort {
public:
  void Drain() override { ++drain_count; }
  bool active() const override { return is_active; }
  std::int64_t revision() const override { return current_revision; }
  Window owner() const override { return current_owner; }
  Time selection_timestamp() const override { return current_timestamp; }
  Window owned_window() const override { return kOwnedWindow; }

  bool AcquireRollbackText(std::int64_t expected_revision,
                           Window expected_owner,
                           Time expected_selection_timestamp,
                           const std::string &text) override {
    ++rollback_count;
    rollback_expected_revision = expected_revision;
    rollback_expected_owner = expected_owner;
    rollback_expected_timestamp = expected_selection_timestamp;
    rollback_text = text;
    if (takeover_during_rollback) {
      current_owner = kTakeoverOwner;
      ++current_revision;
      return false;
    }
    if (!rollback_succeeds)
      return false;
    current_owner = kOwnedWindow;
    ++current_revision;
    ++current_timestamp;
    return true;
  }

  std::int64_t current_revision = 5;
  Window current_owner = kExternalOwner;
  Time current_timestamp = kTimestamp;
  int drain_count = 0;
  int rollback_count = 0;
  std::int64_t rollback_expected_revision = 0;
  Window rollback_expected_owner = None;
  Time rollback_expected_timestamp = CurrentTime;
  std::string rollback_text;
  bool rollback_succeeds = true;
  bool takeover_during_rollback = false;
  bool is_active = true;
};

void RejectsStaleRevisionBeforeAcquisition() {
  FakePort port;
  ykd::X11ClipboardTransaction transaction(port);
  bool called = false;
  const auto result =
      transaction.Run(4, std::chrono::milliseconds(1), "new", "old",
                      [&called](std::int64_t, Window, Time) {
                        called = true;
                        return true;
                      });

  Check(result.status == ykd::X11ClipboardTransactionStatus::kConflict,
        "stale revision was not rejected");
  Check(!called, "stale revision invoked acquisition");
  Check(port.rollback_count == 0, "stale revision invoked rollback");
}

void BindsAcquisitionToOwnerAndTimestamp() {
  FakePort port;
  ykd::X11ClipboardTransaction transaction(port);
  bool received_evidence = false;
  const auto result = transaction.Run(
      5, std::chrono::milliseconds(1), "new", "old",
      [&received_evidence](std::int64_t revision, Window owner,
                           Time timestamp) {
        received_evidence =
            revision == 5 && owner == kExternalOwner && timestamp == kTimestamp;
        return false;
      });

  Check(received_evidence, "acquisition did not receive owner evidence");
  Check(result.status == ykd::X11ClipboardTransactionStatus::kConflict,
        "rejected owner evidence was not a conflict");
  Check(port.rollback_count == 0, "rejected acquisition invoked rollback");
}

void CommitsOnlyTheExactNextOwnedRevision() {
  FakePort port;
  ykd::X11ClipboardTransaction transaction(port);
  const auto result = transaction.Run(
      5, std::chrono::milliseconds(10), "new", "old",
      [&port](std::int64_t revision, Window owner, Time timestamp) {
        Check(revision == 5 && owner == kExternalOwner &&
                  timestamp == kTimestamp,
              "commit received wrong evidence");
        port.current_owner = kOwnedWindow;
        port.current_revision = 6;
        ++port.current_timestamp;
        return true;
      });

  Check(result.status == ykd::X11ClipboardTransactionStatus::kCommitted,
        "exact next revision did not commit");
  Check(result.revision == 6, "commit returned wrong revision");
  Check(port.rollback_count == 0, "successful commit invoked rollback");
}

void PreservesExternalTakeoverAfterAcquisition() {
  FakePort port;
  ykd::X11ClipboardTransaction transaction(port);
  const auto result =
      transaction.Run(5, std::chrono::milliseconds(10), "new", "old",
                      [&port](std::int64_t, Window, Time) {
                        port.current_owner = kTakeoverOwner;
                        port.current_revision = 6;
                        ++port.current_timestamp;
                        return true;
                      });

  Check(result.status == ykd::X11ClipboardTransactionStatus::kConflict,
        "external takeover was not a conflict");
  Check(port.current_owner == kTakeoverOwner,
        "external takeover owner was overwritten");
  Check(port.rollback_count == 0, "external takeover invoked rollback");
}

void CompensatesAnUnexpectedOwnedRevision() {
  FakePort port;
  ykd::X11ClipboardTransaction transaction(port);
  const auto result =
      transaction.Run(5, std::chrono::milliseconds(10), "new", "old",
                      [&port](std::int64_t, Window, Time) {
                        port.current_owner = kOwnedWindow;
                        port.current_revision = 7;
                        port.current_timestamp = 43;
                        return true;
                      });

  Check(result.status == ykd::X11ClipboardTransactionStatus::kRolledBack,
        "unexpected owned revision was not compensated");
  Check(result.revision == 8, "rollback returned wrong revision");
  Check(result.current_text == "old", "rollback returned wrong text");
  Check(port.rollback_count == 1, "rollback was not attempted once");
  Check(port.rollback_expected_revision == 7 &&
            port.rollback_expected_owner == kOwnedWindow &&
            port.rollback_expected_timestamp == 43,
        "rollback was not bound to current ownership evidence");
}

void ReportsAmbiguousOwnedStateWhenRollbackFails() {
  FakePort port;
  port.rollback_succeeds = false;
  ykd::X11ClipboardTransaction transaction(port);
  const auto result =
      transaction.Run(5, std::chrono::milliseconds(0), "new", "old",
                      [&port](std::int64_t, Window, Time) {
                        port.current_owner = kOwnedWindow;
                        return true;
                      });

  Check(result.status == ykd::X11ClipboardTransactionStatus::kAmbiguous,
        "failed rollback was not reported as ambiguous");
  Check(result.current_text == "new", "ambiguous state returned wrong text");
}

void DoesNotFightTakeoverDuringCompensation() {
  FakePort port;
  port.takeover_during_rollback = true;
  ykd::X11ClipboardTransaction transaction(port);
  const auto result =
      transaction.Run(5, std::chrono::milliseconds(10), "new", "old",
                      [&port](std::int64_t, Window, Time) {
                        port.current_owner = kOwnedWindow;
                        port.current_revision = 7;
                        port.current_timestamp = 43;
                        return true;
                      });

  Check(result.status == ykd::X11ClipboardTransactionStatus::kConflict,
        "takeover during compensation was not a conflict");
  Check(port.current_owner == kTakeoverOwner,
        "takeover during compensation was overwritten");
  Check(port.rollback_count == 1, "compensation was retried unexpectedly");
}

void RejectsAuthorityLossBeforeCommit() {
  FakePort port;
  ykd::X11ClipboardTransaction transaction(port);
  const auto result =
      transaction.Run(5, std::chrono::milliseconds(10), "new", "old",
                      [&port](std::int64_t, Window, Time) {
                        port.current_owner = kOwnedWindow;
                        port.current_revision = 6;
                        port.is_active = false;
                        return true;
                      });

  Check(result.status == ykd::X11ClipboardTransactionStatus::kUnavailable,
        "authority loss was reported as a committed transaction");
  Check(port.rollback_count == 0, "authority loss attempted rollback");
}

}

int main() {
  RejectsStaleRevisionBeforeAcquisition();
  BindsAcquisitionToOwnerAndTimestamp();
  CommitsOnlyTheExactNextOwnedRevision();
  PreservesExternalTakeoverAfterAcquisition();
  CompensatesAnUnexpectedOwnedRevision();
  ReportsAmbiguousOwnedStateWhenRollbackFails();
  DoesNotFightTakeoverDuringCompensation();
  RejectsAuthorityLossBeforeCommit();
  return EXIT_SUCCESS;
}
