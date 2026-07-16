#include "native_clipboard_broker.h"

#include <windows.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <cwchar>
#include <future>
#include <limits>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

#include "native_clipboard_snapshot.h"

namespace {

constexpr uint32_t kProtocolMagic = 0x594B4443;
constexpr uint32_t kProtocolVersion = 1;
constexpr uint32_t kCapture = 1;
constexpr uint32_t kRestore = 2;
constexpr uint32_t kRelease = 3;
constexpr uint32_t kShutdown = 4;

constexpr int32_t kSuccess = 0;
constexpr int32_t kAllocationFailed = 5;
constexpr int32_t kSnapshotNotFound = 7;
constexpr int32_t kBrokerTimeout = 10;
constexpr DWORD kBrokerReplyTimeoutMs = 2500;
constexpr DWORD kBrokerShutdownTimeoutMs = 500;
constexpr uint32_t kMaximumRollbackCharacters = 32 * 1024 * 1024;
constexpr int kNormalBroker = 0;
constexpr int kStalledBroker = 1;
constexpr int kNoReplyBroker = 2;
std::atomic<int> g_broker_test_mode{kNormalBroker};

struct BrokerCommand {
  uint32_t magic = kProtocolMagic;
  uint32_t version = kProtocolVersion;
  uint32_t command = 0;
  uint32_t text_characters = 0;
  uint64_t argument = 0;
  uint32_t revision = 0;
  uint32_t reserved = 0;
};

struct BrokerReply {
  uint32_t magic = kProtocolMagic;
  uint32_t version = kProtocolVersion;
  int32_t status = kAllocationFailed;
  uint32_t revision = 0;
  uint64_t token = 0;
};

bool WriteExact(HANDLE pipe, const void *data, size_t length) {
  const auto *cursor = static_cast<const uint8_t *>(data);
  while (length > 0) {
    const DWORD chunk =
        static_cast<DWORD>((std::min)(length, static_cast<size_t>(MAXDWORD)));
    DWORD written = 0;
    if (::WriteFile(pipe, cursor, chunk, &written, nullptr) == 0 ||
        written == 0) {
      return false;
    }
    cursor += written;
    length -= written;
  }
  return true;
}

bool ReadExact(HANDLE pipe, void *data, size_t length) {
  auto *cursor = static_cast<uint8_t *>(data);
  while (length > 0) {
    const DWORD chunk =
        static_cast<DWORD>((std::min)(length, static_cast<size_t>(MAXDWORD)));
    DWORD read = 0;
    if (::ReadFile(pipe, cursor, chunk, &read, nullptr) == 0 || read == 0) {
      return false;
    }
    cursor += read;
    length -= read;
  }
  return true;
}

void PumpSentMessagesForClipboardOwnership() {
  MSG message{};
  ::PeekMessageW(&message, nullptr, 0, 0, PM_NOREMOVE);
}

bool ReadExactWithMessagePump(HANDLE pipe, void *data, size_t length) {
  auto *cursor = static_cast<uint8_t *>(data);
  while (length > 0) {
    DWORD available = 0;
    if (::PeekNamedPipe(pipe, nullptr, 0, nullptr, &available, nullptr) == 0) {
      return false;
    }
    if (available == 0) {
      PumpSentMessagesForClipboardOwnership();
      ::Sleep(5);
      continue;
    }
    const DWORD chunk =
        static_cast<DWORD>((std::min)(length, static_cast<size_t>(available)));
    DWORD read = 0;
    if (::ReadFile(pipe, cursor, chunk, &read, nullptr) == 0 || read == 0) {
      return false;
    }
    cursor += read;
    length -= read;
  }
  return true;
}

class ClipboardOwnerWindow {
public:
  ClipboardOwnerWindow() {
    WNDCLASSW window_class{};
    window_class.lpfnWndProc = ::DefWindowProcW;
    window_class.hInstance = ::GetModuleHandleW(nullptr);
    window_class.lpszClassName = L"YkdNativeClipboardBrokerOwner";
    atom_ = ::RegisterClassW(&window_class);
    if (atom_ == 0 && ::GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
      return;
    }
    window_ = ::CreateWindowExW(0, window_class.lpszClassName, L"",
                                WS_OVERLAPPED, 0, 0, 0, 0, nullptr, nullptr,
                                window_class.hInstance, nullptr);
  }

  ClipboardOwnerWindow(const ClipboardOwnerWindow &) = delete;
  ClipboardOwnerWindow &operator=(const ClipboardOwnerWindow &) = delete;

  ~ClipboardOwnerWindow() {
    if (window_ != nullptr) {
      ::DestroyWindow(window_);
    }
    if (atom_ != 0) {
      ::UnregisterClassW(L"YkdNativeClipboardBrokerOwner",
                         ::GetModuleHandleW(nullptr));
    }
  }

  HWND get() const { return window_; }

private:
  ATOM atom_ = 0;
  HWND window_ = nullptr;
};

class BrokerProcess {
public:
  BrokerProcess() = default;
  BrokerProcess(const BrokerProcess &) = delete;
  BrokerProcess &operator=(const BrokerProcess &) = delete;
  ~BrokerProcess() { Stop(); }

  bool Start() {
    SECURITY_ATTRIBUTES security{};
    security.nLength = sizeof(security);
    security.bInheritHandle = TRUE;

    HANDLE child_input = nullptr;
    HANDLE child_output = nullptr;
    HANDLE parent_input = nullptr;
    HANDLE parent_output = nullptr;
    if (::CreatePipe(&child_input, &parent_input, &security, 0) == 0 ||
        ::CreatePipe(&parent_output, &child_output, &security, 0) == 0) {
      CloseIfValid(child_input);
      CloseIfValid(parent_input);
      CloseIfValid(parent_output);
      CloseIfValid(child_output);
      return false;
    }
    ::SetHandleInformation(parent_input, HANDLE_FLAG_INHERIT, 0);
    ::SetHandleInformation(parent_output, HANDLE_FLAG_INHERIT, 0);

    HANDLE null_error =
        ::CreateFileW(L"NUL", GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                      &security, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (null_error == INVALID_HANDLE_VALUE) {
      null_error = nullptr;
    }

    wchar_t executable[MAX_PATH]{};
    if (::GetModuleFileNameW(nullptr, executable, MAX_PATH) == 0) {
      CloseIfValid(child_input);
      CloseIfValid(parent_input);
      CloseIfValid(parent_output);
      CloseIfValid(child_output);
      CloseIfValid(null_error);
      return false;
    }
    std::wstring command_line = L"\"";
    command_line += executable;
    switch (g_broker_test_mode.load()) {
    case kStalledBroker:
      command_line +=
          L"\" --yandex-keyboard-native-clipboard-broker-stall-test";
      break;
    case kNoReplyBroker:
      command_line +=
          L"\" --yandex-keyboard-native-clipboard-broker-no-reply-test";
      break;
    default:
      command_line += L"\" --yandex-keyboard-native-clipboard-broker";
      break;
    }
    std::vector<wchar_t> mutable_command(command_line.begin(),
                                         command_line.end());
    mutable_command.push_back(L'\0');

    wchar_t station_name[256]{};
    wchar_t desktop_name[256]{};
    DWORD name_bytes = 0;
    const bool desktop_resolved =
        ::GetUserObjectInformationW(::GetProcessWindowStation(), UOI_NAME,
                                    station_name, sizeof(station_name),
                                    &name_bytes) != 0 &&
        ::GetUserObjectInformationW(::GetThreadDesktop(::GetCurrentThreadId()),
                                    UOI_NAME, desktop_name,
                                    sizeof(desktop_name), &name_bytes) != 0;
    std::wstring desktop_path = station_name;
    desktop_path += L"\\";
    desktop_path += desktop_name;

    STARTUPINFOEXW startup{};
    startup.StartupInfo.cb = sizeof(startup);
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startup.StartupInfo.hStdInput = child_input;
    startup.StartupInfo.hStdOutput = child_output;
    startup.StartupInfo.hStdError = null_error;
    startup.StartupInfo.lpDesktop =
        desktop_resolved ? desktop_path.data() : nullptr;

    SIZE_T attribute_bytes = 0;
    ::InitializeProcThreadAttributeList(nullptr, 1, 0, &attribute_bytes);
    startup.lpAttributeList = static_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(
        ::HeapAlloc(::GetProcessHeap(), 0, attribute_bytes));
    HANDLE inherited[] = {child_input, child_output, null_error};
    const bool attributes_ready =
        startup.lpAttributeList != nullptr &&
        ::InitializeProcThreadAttributeList(startup.lpAttributeList, 1, 0,
                                            &attribute_bytes) != 0 &&
        ::UpdateProcThreadAttribute(
            startup.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
            inherited, sizeof(inherited), nullptr, nullptr) != 0;

    HANDLE job = ::CreateJobObjectW(nullptr, nullptr);
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION job_limits{};
    job_limits.BasicLimitInformation.LimitFlags =
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    const bool job_ready =
        job != nullptr &&
        ::SetInformationJobObject(job, JobObjectExtendedLimitInformation,
                                  &job_limits, sizeof(job_limits)) != 0;

    PROCESS_INFORMATION process{};
    const BOOL started =
        attributes_ready && job_ready && desktop_resolved
            ? ::CreateProcessW(executable, mutable_command.data(), nullptr,
                               nullptr, TRUE,
                               CREATE_NO_WINDOW | CREATE_SUSPENDED |
                                   EXTENDED_STARTUPINFO_PRESENT,
                               nullptr, nullptr, &startup.StartupInfo, &process)
            : FALSE;
    if (startup.lpAttributeList != nullptr) {
      ::DeleteProcThreadAttributeList(startup.lpAttributeList);
      ::HeapFree(::GetProcessHeap(), 0, startup.lpAttributeList);
    }
    CloseIfValid(child_input);
    CloseIfValid(child_output);
    CloseIfValid(null_error);
    if (started == FALSE) {
      CloseIfValid(parent_input);
      CloseIfValid(parent_output);
      CloseIfValid(job);
      return false;
    }

    if (::AssignProcessToJobObject(job, process.hProcess) == 0 ||
        ::ResumeThread(process.hThread) == static_cast<DWORD>(-1)) {
      ::TerminateProcess(process.hProcess, kAllocationFailed);
      ::WaitForSingleObject(process.hProcess, kBrokerShutdownTimeoutMs);
      ::CloseHandle(process.hThread);
      ::CloseHandle(process.hProcess);
      CloseIfValid(parent_input);
      CloseIfValid(parent_output);
      CloseIfValid(job);
      return false;
    }

    ::CloseHandle(process.hThread);
    process_ = process.hProcess;
    job_ = job;
    input_ = parent_input;
    output_ = parent_output;
    return true;
  }

  bool Transact(const BrokerCommand &command, const wchar_t *text,
                BrokerReply *reply) {
    const ULONGLONG deadline = ::GetTickCount64() + kBrokerReplyTimeoutMs;
    if (!WriteRequestUntil(command, text, deadline) ||
        !ReadReplyUntil(reply, deadline)) {
      Terminate();
      return false;
    }
    return true;
  }

  bool HasExitedForTest() const {
    return process_ != nullptr &&
           ::WaitForSingleObject(process_, 0) == WAIT_OBJECT_0;
  }

  bool VerifyJobCloseKillsChildForTest() {
    if (job_ == nullptr || process_ == nullptr) {
      return false;
    }
    CloseIfValid(job_);
    return ::WaitForSingleObject(process_, kBrokerReplyTimeoutMs) ==
           WAIT_OBJECT_0;
  }

  void Stop() {
    if (process_ == nullptr) {
      CloseIfValid(input_);
      CloseIfValid(output_);
      CloseIfValid(job_);
      return;
    }
    if (::WaitForSingleObject(process_, 0) != WAIT_OBJECT_0) {
      BrokerCommand shutdown;
      shutdown.command = kShutdown;
      const ULONGLONG deadline = ::GetTickCount64() + kBrokerShutdownTimeoutMs;
      WriteRequestUntil(shutdown, nullptr, deadline);
      const ULONGLONG now = ::GetTickCount64();
      const DWORD remaining =
          now < deadline ? static_cast<DWORD>(deadline - now) : 0;
      if (::WaitForSingleObject(process_, remaining) != WAIT_OBJECT_0) {
        Terminate();
      }
    }
    CloseIfValid(input_);
    CloseIfValid(output_);
    CloseIfValid(job_);
    CloseIfValid(process_);
  }

private:
  bool WriteRequestUntil(const BrokerCommand &command, const wchar_t *text,
                         ULONGLONG deadline) {
    std::packaged_task<bool()> write_task([this, &command, text]() {
      if (!WriteExact(input_, &command, sizeof(command))) {
        return false;
      }
      if (command.text_characters == 0) {
        return true;
      }
      return text != nullptr &&
             WriteExact(input_, text,
                        static_cast<size_t>(command.text_characters) *
                            sizeof(wchar_t));
    });
    auto result = write_task.get_future();
    std::thread writer(std::move(write_task));
    bool completed = false;
    while (::GetTickCount64() < deadline) {
      if (result.wait_for(std::chrono::milliseconds(5)) ==
          std::future_status::ready) {
        completed = true;
        break;
      }
      PumpSentMessagesForClipboardOwnership();
    }
    if (!completed) {
      ::CancelSynchronousIo(writer.native_handle());
      Terminate();
    }
    const bool written = result.get();
    writer.join();
    return completed && written;
  }

  bool ReadReplyUntil(BrokerReply *reply, ULONGLONG deadline) {
    while (::GetTickCount64() < deadline) {
      DWORD available = 0;
      if (::PeekNamedPipe(output_, nullptr, 0, nullptr, &available, nullptr) ==
          0) {
        return false;
      }
      if (available >= sizeof(*reply)) {
        return ReadExact(output_, reply, sizeof(*reply)) &&
               reply->magic == kProtocolMagic &&
               reply->version == kProtocolVersion;
      }
      if (::WaitForSingleObject(process_, 0) == WAIT_OBJECT_0) {
        return false;
      }
      PumpSentMessagesForClipboardOwnership();
      ::Sleep(5);
    }
    return false;
  }

  void Terminate() {
    if (process_ != nullptr &&
        ::WaitForSingleObject(process_, 0) != WAIT_OBJECT_0) {
      ::TerminateProcess(process_, kBrokerTimeout);
      ::WaitForSingleObject(process_, kBrokerShutdownTimeoutMs);
    }
  }

  static void CloseIfValid(HANDLE &handle) {
    if (handle != nullptr && handle != INVALID_HANDLE_VALUE) {
      ::CloseHandle(handle);
    }
    handle = nullptr;
  }

  HANDLE process_ = nullptr;
  HANDLE job_ = nullptr;
  HANDLE input_ = nullptr;
  HANDLE output_ = nullptr;
};

struct BrokerSnapshot {
  std::unique_ptr<BrokerProcess> process;
  uint64_t remote_token = 0;
};

std::mutex g_brokers_mutex;
std::unordered_map<uint64_t, BrokerSnapshot> g_brokers;
std::atomic<uint64_t> g_next_broker_token{1};

BrokerReply FailureReply(int32_t status) {
  BrokerReply reply;
  reply.status = status;
  return reply;
}

bool SetClipboardTextForIntegrationTest(HWND owner, const wchar_t *text) {
  const size_t characters = std::wcslen(text) + 1;
  HGLOBAL memory = ::GlobalAlloc(GMEM_MOVEABLE, characters * sizeof(wchar_t));
  if (memory == nullptr) {
    return false;
  }
  void *bytes = ::GlobalLock(memory);
  if (bytes == nullptr) {
    ::GlobalFree(memory);
    return false;
  }
  std::memcpy(bytes, text, characters * sizeof(wchar_t));
  ::GlobalUnlock(memory);
  if (::OpenClipboard(owner) == 0) {
    ::GlobalFree(memory);
    return false;
  }
  const bool emptied = ::EmptyClipboard() != 0;
  const bool stored =
      emptied && ::SetClipboardData(CF_UNICODETEXT, memory) != nullptr;
  ::CloseClipboard();
  if (!stored) {
    ::GlobalFree(memory);
  }
  return stored;
}

bool ClipboardTextEqualsForIntegrationTest(HWND owner,
                                           const wchar_t *expected) {
  if (::OpenClipboard(owner) == 0) {
    return false;
  }
  HANDLE memory = ::GetClipboardData(CF_UNICODETEXT);
  const auto *text = memory == nullptr
                         ? nullptr
                         : static_cast<const wchar_t *>(::GlobalLock(memory));
  const bool equal = text != nullptr && std::wcscmp(text, expected) == 0;
  if (text != nullptr) {
    ::GlobalUnlock(memory);
  }
  ::CloseClipboard();
  return equal;
}

}

int RunNativeClipboardSnapshotBroker() {
  HANDLE input = ::GetStdHandle(STD_INPUT_HANDLE);
  HANDLE output = ::GetStdHandle(STD_OUTPUT_HANDLE);
  if (input == nullptr || input == INVALID_HANDLE_VALUE || output == nullptr ||
      output == INVALID_HANDLE_VALUE) {
    return kAllocationFailed;
  }
  ClipboardOwnerWindow owner;
  if (owner.get() == nullptr) {
    return kAllocationFailed;
  }

  while (true) {
    BrokerCommand command;
    if (!ReadExactWithMessagePump(input, &command, sizeof(command)) ||
        command.magic != kProtocolMagic ||
        command.version != kProtocolVersion) {
      return kAllocationFailed;
    }
    if (command.command == kShutdown) {
      return 0;
    }

    BrokerReply reply;
    if (command.command == kCapture) {
      reply.status = CaptureClipboardSnapshotInProcess(
          reinterpret_cast<intptr_t>(owner.get()), command.argument,
          &reply.token, &reply.revision);
    } else if (command.command == kRestore) {
      if (command.text_characters == 0 ||
          command.text_characters > kMaximumRollbackCharacters) {
        reply.status = kAllocationFailed;
      } else {
        std::vector<wchar_t> rollback(command.text_characters);
        if (!ReadExactWithMessagePump(input, rollback.data(),
                                      rollback.size() * sizeof(wchar_t)) ||
            rollback.back() != L'\0') {
          return kAllocationFailed;
        }
        reply.status = RestoreClipboardSnapshotInProcess(
            reinterpret_cast<intptr_t>(owner.get()), command.argument,
            command.revision, rollback.data(), &reply.revision);
      }
    } else if (command.command == kRelease) {
      reply.status = ReleaseClipboardSnapshotInProcess(command.argument);
    } else {
      reply = FailureReply(kAllocationFailed);
    }
    if (!WriteExact(output, &reply, sizeof(reply))) {
      return kAllocationFailed;
    }
  }
}

int RunNativeClipboardBrokerNoReplyTest() {
  HANDLE input = ::GetStdHandle(STD_INPUT_HANDLE);
  if (input == nullptr || input == INVALID_HANDLE_VALUE) {
    return kAllocationFailed;
  }
  BrokerCommand command;
  if (!ReadExactWithMessagePump(input, &command, sizeof(command)) ||
      command.magic != kProtocolMagic || command.version != kProtocolVersion) {
    return kAllocationFailed;
  }
  if (command.text_characters > kMaximumRollbackCharacters) {
    return kAllocationFailed;
  }
  if (command.text_characters != 0) {
    std::vector<wchar_t> payload(command.text_characters);
    if (!ReadExactWithMessagePump(input, payload.data(),
                                  payload.size() * sizeof(wchar_t))) {
      return kAllocationFailed;
    }
  }
  ::Sleep(30000);
  return kAllocationFailed;
}

int RunNativeClipboardBrokerTimeoutSelfTest() {
  g_broker_test_mode.store(kStalledBroker);
  const ULONGLONG reply_started = ::GetTickCount64();
  uint64_t token = 0;
  uint32_t revision = 0;
  const int32_t status =
      CaptureClipboardSnapshotViaBroker(0, 1024, &token, &revision);
  const ULONGLONG reply_elapsed = ::GetTickCount64() - reply_started;
  if (status != kBrokerTimeout || token != 0 || revision != 0 ||
      reply_elapsed < kBrokerReplyTimeoutMs || reply_elapsed >= 6000) {
    g_broker_test_mode.store(kNormalBroker);
    return 1;
  }

  BrokerProcess stalled_receiver;
  if (!stalled_receiver.Start()) {
    g_broker_test_mode.store(kNormalBroker);
    return 2;
  }
  std::wstring large_rollback(2 * 1024 * 1024, L'x');
  BrokerCommand restore;
  restore.command = kRestore;
  restore.argument = 1;
  restore.revision = 1;
  restore.text_characters = static_cast<uint32_t>(large_rollback.size() + 1);
  BrokerReply reply;
  const ULONGLONG write_started = ::GetTickCount64();
  const bool transacted =
      stalled_receiver.Transact(restore, large_rollback.c_str(), &reply);
  const ULONGLONG write_elapsed = ::GetTickCount64() - write_started;
  if (transacted || write_elapsed < kBrokerReplyTimeoutMs ||
      write_elapsed >= 6000) {
    g_broker_test_mode.store(kNormalBroker);
    return 3;
  }

  g_broker_test_mode.store(kNoReplyBroker);
  BrokerProcess no_reply_receiver;
  if (!no_reply_receiver.Start()) {
    g_broker_test_mode.store(kNormalBroker);
    return 4;
  }
  BrokerCommand accepted_restore;
  accepted_restore.command = kRestore;
  accepted_restore.argument = 1;
  accepted_restore.revision = 1;
  accepted_restore.text_characters = 1;
  const ULONGLONG no_reply_started = ::GetTickCount64();
  const bool no_reply_transacted =
      no_reply_receiver.Transact(accepted_restore, L"", &reply);
  const ULONGLONG no_reply_elapsed = ::GetTickCount64() - no_reply_started;
  if (no_reply_transacted || !no_reply_receiver.HasExitedForTest() ||
      no_reply_elapsed < kBrokerReplyTimeoutMs || no_reply_elapsed >= 6000) {
    g_broker_test_mode.store(kNormalBroker);
    return 5;
  }

  g_broker_test_mode.store(kStalledBroker);
  BrokerProcess orphan_candidate;
  if (!orphan_candidate.Start() ||
      !orphan_candidate.VerifyJobCloseKillsChildForTest()) {
    g_broker_test_mode.store(kNormalBroker);
    return 6;
  }
  g_broker_test_mode.store(kNormalBroker);
  return 0;
}

int RunNativeClipboardBrokerIntegrationSelfTest() {
  wchar_t station_name[96]{};
  ::swprintf_s(station_name, L"YkdClipboardTest-%lu-%llu",
               ::GetCurrentProcessId(), ::GetTickCount64());
  HWINSTA station =
      ::CreateWindowStationW(station_name, 0, WINSTA_ALL_ACCESS, nullptr);
  if (station == nullptr || ::SetProcessWindowStation(station) == 0) {
    return 1;
  }
  HDESK desktop =
      ::CreateDesktopW(L"Default", nullptr, nullptr, 0, GENERIC_ALL, nullptr);
  if (desktop == nullptr || ::SetThreadDesktop(desktop) == 0) {
    return 2;
  }
  ClipboardOwnerWindow owner;
  if (owner.get() == nullptr) {
    return 3;
  }

  constexpr wchar_t kOriginal[] = L"YKD original \x0416\x03A9";
  constexpr wchar_t kStaged[] = L"YKD staged";
  if (!SetClipboardTextForIntegrationTest(owner.get(), kOriginal)) {
    return 4;
  }
  uint64_t token = 0;
  uint32_t captured_revision = 0;
  if (CaptureClipboardSnapshotViaBroker(reinterpret_cast<intptr_t>(owner.get()),
                                        1024 * 1024, &token,
                                        &captured_revision) != kSuccess ||
      token == 0) {
    return 5;
  }
  if (!SetClipboardTextForIntegrationTest(owner.get(), kStaged)) {
    ReleaseClipboardSnapshotViaBroker(token);
    return 6;
  }
  const uint32_t staged_revision = ::GetClipboardSequenceNumber();
  uint32_t restored_revision = 0;
  const int32_t restore_status = RestoreClipboardSnapshotViaBroker(
      reinterpret_cast<intptr_t>(owner.get()), token, staged_revision, kStaged,
      &restored_revision);
  const bool text_restored =
      ClipboardTextEqualsForIntegrationTest(owner.get(), kOriginal);
  auto replacement = std::async(std::launch::async, [&owner]() {
    return SetClipboardTextForIntegrationTest(owner.get(),
                                              L"YKD external replacement");
  });
  if (replacement.wait_for(std::chrono::milliseconds(kBrokerReplyTimeoutMs)) !=
      std::future_status::ready) {
    ReleaseClipboardSnapshotViaBroker(token);
    replacement.wait();
    return 82;
  }
  const bool externally_replaced = replacement.get();
  ReleaseClipboardSnapshotViaBroker(token);
  if (restore_status != kSuccess) {
    return 70 + restore_status;
  }
  if (!text_restored) {
    return 81;
  }
  return externally_replaced ? 0 : 83;
}

int32_t CaptureClipboardSnapshotViaBroker(intptr_t owner_window,
                                          uint64_t maximum_bytes,
                                          uint64_t *snapshot_token,
                                          uint32_t *captured_revision) {
  (void)owner_window;
  if (snapshot_token == nullptr || captured_revision == nullptr ||
      maximum_bytes == 0) {
    return kAllocationFailed;
  }
  *snapshot_token = 0;
  *captured_revision = 0;

  auto process = std::make_unique<BrokerProcess>();
  if (!process->Start()) {
    return kAllocationFailed;
  }
  BrokerCommand command;
  command.command = kCapture;
  command.argument = maximum_bytes;
  BrokerReply reply;
  if (!process->Transact(command, nullptr, &reply)) {
    return kBrokerTimeout;
  }
  if (reply.status != kSuccess) {
    return reply.status;
  }

  uint64_t local_token = g_next_broker_token.fetch_add(1);
  if (local_token == 0) {
    local_token = g_next_broker_token.fetch_add(1);
  }
  {
    std::lock_guard<std::mutex> lock(g_brokers_mutex);
    g_brokers.emplace(local_token,
                      BrokerSnapshot{std::move(process), reply.token});
  }
  *snapshot_token = local_token;
  *captured_revision = reply.revision;
  return kSuccess;
}

int32_t RestoreClipboardSnapshotViaBroker(intptr_t owner_window,
                                          uint64_t snapshot_token,
                                          uint32_t expected_revision,
                                          const wchar_t *rollback_text,
                                          uint32_t *resulting_revision) {
  (void)owner_window;
  if (resulting_revision == nullptr || rollback_text == nullptr) {
    return kAllocationFailed;
  }
  *resulting_revision = 0;
  const size_t length = std::wcslen(rollback_text);
  if (length >= kMaximumRollbackCharacters ||
      length >= std::numeric_limits<uint32_t>::max()) {
    return kAllocationFailed;
  }

  std::lock_guard<std::mutex> lock(g_brokers_mutex);
  const auto found = g_brokers.find(snapshot_token);
  if (found == g_brokers.end()) {
    return kSnapshotNotFound;
  }
  BrokerCommand command;
  command.command = kRestore;
  command.argument = found->second.remote_token;
  command.revision = expected_revision;
  command.text_characters = static_cast<uint32_t>(length + 1);
  BrokerReply reply;
  if (!found->second.process->Transact(command, rollback_text, &reply)) {
    *resulting_revision = ::GetClipboardSequenceNumber();
    return kBrokerTimeout;
  }
  *resulting_revision = reply.revision;
  return reply.status;
}

int32_t ReleaseClipboardSnapshotViaBroker(uint64_t snapshot_token) {
  std::unique_ptr<BrokerProcess> process;
  uint64_t remote_token = 0;
  {
    std::lock_guard<std::mutex> lock(g_brokers_mutex);
    const auto found = g_brokers.find(snapshot_token);
    if (found == g_brokers.end()) {
      return kSuccess;
    }
    process = std::move(found->second.process);
    remote_token = found->second.remote_token;
    g_brokers.erase(found);
  }
  BrokerCommand release;
  release.command = kRelease;
  release.argument = remote_token;
  BrokerReply reply;
  process->Transact(release, nullptr, &reply);
  return kSuccess;
}
