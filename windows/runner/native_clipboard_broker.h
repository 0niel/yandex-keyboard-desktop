#ifndef RUNNER_NATIVE_CLIPBOARD_BROKER_H_
#define RUNNER_NATIVE_CLIPBOARD_BROKER_H_

#include <cstdint>

int32_t CaptureClipboardSnapshotViaBroker(intptr_t owner_window,
                                          uint64_t maximum_bytes,
                                          uint64_t *snapshot_token,
                                          uint32_t *captured_revision);
int32_t RestoreClipboardSnapshotViaBroker(intptr_t owner_window,
                                          uint64_t snapshot_token,
                                          uint32_t expected_revision,
                                          const wchar_t *rollback_text,
                                          uint32_t *resulting_revision);
int32_t ReleaseClipboardSnapshotViaBroker(uint64_t snapshot_token);

#endif
