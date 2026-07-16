#ifndef RUNNER_NATIVE_CLIPBOARD_SNAPSHOT_H_
#define RUNNER_NATIVE_CLIPBOARD_SNAPSHOT_H_

#include <cstdint>

extern "C" {

__declspec(dllexport) int32_t YkdCaptureClipboardSnapshot(
    intptr_t owner_window, uint64_t maximum_bytes, uint64_t *snapshot_token,
    uint32_t *captured_revision);

__declspec(dllexport) int32_t YkdRestoreClipboardSnapshotIfRevision(
    intptr_t owner_window, uint64_t snapshot_token, uint32_t expected_revision,
    const wchar_t *rollback_text, uint32_t *resulting_revision);

__declspec(dllexport) int32_t
YkdReleaseClipboardSnapshot(uint64_t snapshot_token);
}

int32_t CaptureClipboardSnapshotInProcess(intptr_t owner_window,
                                          uint64_t maximum_bytes,
                                          uint64_t *snapshot_token,
                                          uint32_t *captured_revision);
int32_t RestoreClipboardSnapshotInProcess(intptr_t owner_window,
                                          uint64_t snapshot_token,
                                          uint32_t expected_revision,
                                          const wchar_t *rollback_text,
                                          uint32_t *resulting_revision);
int32_t ReleaseClipboardSnapshotInProcess(uint64_t snapshot_token);

int RunNativeClipboardSnapshotBroker();

int RunNativeClipboardBrokerNoReplyTest();

int RunNativeClipboardBrokerTimeoutSelfTest();

int RunNativeClipboardBrokerIntegrationSelfTest();

int RunNativeClipboardSnapshotMemorySelfTest();

#endif
