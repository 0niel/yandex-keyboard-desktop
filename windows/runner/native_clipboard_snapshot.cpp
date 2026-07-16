#include "native_clipboard_snapshot.h"
#include "native_clipboard_broker.h"

#include <windows.h>

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <cwchar>
#include <limits>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <utility>
#include <vector>

namespace {

constexpr int32_t kSuccess = 0;
constexpr int32_t kRevisionConflict = 1;
constexpr int32_t kClipboardOpenFailed = 2;
constexpr int32_t kUnsupportedFormat = 3;
constexpr int32_t kSnapshotTooLarge = 4;
constexpr int32_t kAllocationFailed = 5;
constexpr int32_t kClipboardMutationFailed = 6;
constexpr int32_t kSnapshotNotFound = 7;
constexpr int32_t kClipboardChangedDuringCapture = 8;
constexpr int32_t kRollbackFailed = 9;
constexpr size_t kMaximumFormatCount = 1024;

enum class HandleKind {
  kGlobal,
  kBitmap,
  kPalette,
  kEnhancedMetafile,
  kMetafilePicture,
};

struct ClipboardItem {
  UINT format = 0;
  HANDLE handle = nullptr;
  HandleKind kind = HandleKind::kGlobal;
  uint64_t estimated_bytes = 0;

  ClipboardItem() = default;
  ClipboardItem(UINT item_format, HANDLE item_handle, HandleKind item_kind,
                uint64_t item_bytes)
      : format(item_format), handle(item_handle), kind(item_kind),
        estimated_bytes(item_bytes) {}

  ClipboardItem(const ClipboardItem &) = delete;
  ClipboardItem &operator=(const ClipboardItem &) = delete;

  ClipboardItem(ClipboardItem &&other) noexcept { *this = std::move(other); }

  ClipboardItem &operator=(ClipboardItem &&other) noexcept {
    if (this == &other) {
      return *this;
    }
    Reset();
    format = other.format;
    handle = other.handle;
    kind = other.kind;
    estimated_bytes = other.estimated_bytes;
    other.handle = nullptr;
    return *this;
  }

  ~ClipboardItem() { Reset(); }

  void Reset() {
    if (handle == nullptr) {
      return;
    }
    switch (kind) {
    case HandleKind::kGlobal:
      ::GlobalFree(handle);
      break;
    case HandleKind::kMetafilePicture: {
      const auto *picture =
          static_cast<const METAFILEPICT *>(::GlobalLock(handle));
      if (picture != nullptr) {
        if (picture->hMF != nullptr) {
          ::DeleteMetaFile(picture->hMF);
        }
        ::GlobalUnlock(handle);
      }
      ::GlobalFree(handle);
      break;
    }
    case HandleKind::kBitmap:
    case HandleKind::kPalette:
      ::DeleteObject(handle);
      break;
    case HandleKind::kEnhancedMetafile:
      ::DeleteEnhMetaFile(static_cast<HENHMETAFILE>(handle));
      break;
    }
    handle = nullptr;
  }

  HANDLE Release() {
    HANDLE released = handle;
    handle = nullptr;
    return released;
  }
};

struct ClipboardSnapshot {
  uint32_t revision = 0;
  std::vector<ClipboardItem> items;
};

std::mutex g_snapshots_mutex;
std::unordered_map<uint64_t, std::unique_ptr<ClipboardSnapshot>> g_snapshots;
std::atomic<uint64_t> g_next_snapshot_token{1};

class ScopedClipboard {
public:
  explicit ScopedClipboard(HWND owner) : opened_(::OpenClipboard(owner) != 0) {}
  ScopedClipboard(const ScopedClipboard &) = delete;
  ScopedClipboard &operator=(const ScopedClipboard &) = delete;
  ~ScopedClipboard() {
    if (opened_) {
      ::CloseClipboard();
    }
  }
  bool opened() const { return opened_; }

private:
  bool opened_;
};

HandleKind KindForFormat(UINT format) {
  switch (format) {
  case CF_BITMAP:
  case CF_DSPBITMAP:
    return HandleKind::kBitmap;
  case CF_PALETTE:
    return HandleKind::kPalette;
  case CF_ENHMETAFILE:
  case CF_DSPENHMETAFILE:
    return HandleKind::kEnhancedMetafile;
  case CF_METAFILEPICT:
  case CF_DSPMETAFILEPICT:
    return HandleKind::kMetafilePicture;
  default:
    return HandleKind::kGlobal;
  }
}

bool IsOwnerManagedFormat(UINT format) {
  return format == CF_OWNERDISPLAY ||
         (format >= CF_PRIVATEFIRST && format <= CF_PRIVATELAST) ||
         (format >= CF_GDIOBJFIRST && format <= CF_GDIOBJLAST);
}

int32_t AddSize(uint64_t item_size, uint64_t maximum_bytes,
                uint64_t *total_bytes) {
  if (item_size > maximum_bytes || *total_bytes > maximum_bytes - item_size) {
    return kSnapshotTooLarge;
  }
  *total_bytes += item_size;
  return kSuccess;
}

int32_t CloneGlobal(UINT format, HANDLE source, uint64_t maximum_bytes,
                    uint64_t *total_bytes, ClipboardItem *output) {
  const SIZE_T size = ::GlobalSize(source);
  if (size == 0) {
    return kUnsupportedFormat;
  }
  const int32_t size_status = AddSize(size, maximum_bytes, total_bytes);
  if (size_status != kSuccess) {
    return size_status;
  }

  HGLOBAL copy = ::GlobalAlloc(GMEM_MOVEABLE, size);
  if (copy == nullptr) {
    return kAllocationFailed;
  }
  const void *source_bytes = ::GlobalLock(source);
  void *destination_bytes = ::GlobalLock(copy);
  if (source_bytes == nullptr || destination_bytes == nullptr) {
    if (source_bytes != nullptr) {
      ::GlobalUnlock(source);
    }
    if (destination_bytes != nullptr) {
      ::GlobalUnlock(copy);
    }
    ::GlobalFree(copy);
    return kUnsupportedFormat;
  }
  std::memcpy(destination_bytes, source_bytes, size);
  ::GlobalUnlock(copy);
  ::GlobalUnlock(source);
  *output = ClipboardItem(format, copy, HandleKind::kGlobal, size);
  return kSuccess;
}

int32_t CloneBitmap(UINT format, HANDLE source, uint64_t maximum_bytes,
                    uint64_t *total_bytes, ClipboardItem *output) {
  BITMAP bitmap{};
  if (::GetObject(source, sizeof(bitmap), &bitmap) != sizeof(bitmap) ||
      bitmap.bmWidth <= 0 || bitmap.bmHeight == 0 || bitmap.bmWidthBytes <= 0) {
    return kUnsupportedFormat;
  }
  const uint64_t height =
      static_cast<uint64_t>(std::abs(static_cast<int64_t>(bitmap.bmHeight)));
  const uint64_t size = static_cast<uint64_t>(bitmap.bmWidthBytes) * height;
  const int32_t size_status = AddSize(size, maximum_bytes, total_bytes);
  if (size_status != kSuccess) {
    return size_status;
  }
  HANDLE copy = ::CopyImage(source, IMAGE_BITMAP, 0, 0, LR_CREATEDIBSECTION);
  if (copy == nullptr) {
    return kAllocationFailed;
  }
  *output = ClipboardItem(format, copy, HandleKind::kBitmap, size);
  return kSuccess;
}

int32_t ClonePalette(UINT format, HANDLE source, uint64_t maximum_bytes,
                     uint64_t *total_bytes, ClipboardItem *output) {
  const UINT entry_count =
      ::GetPaletteEntries(static_cast<HPALETTE>(source), 0, 0, nullptr);
  if (entry_count == 0 || entry_count > std::numeric_limits<WORD>::max()) {
    return kUnsupportedFormat;
  }
  const size_t allocation_size =
      sizeof(LOGPALETTE) + (entry_count - 1) * sizeof(PALETTEENTRY);
  const int32_t size_status =
      AddSize(allocation_size, maximum_bytes, total_bytes);
  if (size_status != kSuccess) {
    return size_status;
  }
  std::vector<std::byte> bytes(allocation_size);
  auto *palette = reinterpret_cast<LOGPALETTE *>(bytes.data());
  palette->palVersion = 0x300;
  palette->palNumEntries = static_cast<WORD>(entry_count);
  if (::GetPaletteEntries(static_cast<HPALETTE>(source), 0, entry_count,
                          palette->palPalEntry) != entry_count) {
    return kUnsupportedFormat;
  }
  HPALETTE copy = ::CreatePalette(palette);
  if (copy == nullptr) {
    return kAllocationFailed;
  }
  *output = ClipboardItem(format, copy, HandleKind::kPalette, allocation_size);
  return kSuccess;
}

int32_t CloneEnhancedMetafile(UINT format, HANDLE source,
                              uint64_t maximum_bytes, uint64_t *total_bytes,
                              ClipboardItem *output) {
  const UINT size =
      ::GetEnhMetaFileBits(static_cast<HENHMETAFILE>(source), 0, nullptr);
  if (size == 0) {
    return kUnsupportedFormat;
  }
  const int32_t size_status = AddSize(size, maximum_bytes, total_bytes);
  if (size_status != kSuccess) {
    return size_status;
  }
  HENHMETAFILE copy =
      ::CopyEnhMetaFile(static_cast<HENHMETAFILE>(source), nullptr);
  if (copy == nullptr) {
    return kAllocationFailed;
  }
  *output = ClipboardItem(format, copy, HandleKind::kEnhancedMetafile, size);
  return kSuccess;
}

int32_t CloneMetafilePicture(UINT format, HANDLE source, uint64_t maximum_bytes,
                             uint64_t *total_bytes, ClipboardItem *output) {
  const auto *source_picture =
      static_cast<const METAFILEPICT *>(::GlobalLock(source));
  if (source_picture == nullptr || source_picture->hMF == nullptr) {
    if (source_picture != nullptr) {
      ::GlobalUnlock(source);
    }
    return kUnsupportedFormat;
  }
  const UINT metafile_size =
      ::GetMetaFileBitsEx(source_picture->hMF, 0, nullptr);
  const uint64_t estimated_size = sizeof(METAFILEPICT) + metafile_size;
  const int32_t size_status =
      AddSize(estimated_size, maximum_bytes, total_bytes);
  if (size_status != kSuccess) {
    ::GlobalUnlock(source);
    return size_status;
  }
  HMETAFILE metafile_copy = ::CopyMetaFile(source_picture->hMF, nullptr);
  if (metafile_copy == nullptr) {
    ::GlobalUnlock(source);
    return kAllocationFailed;
  }
  HGLOBAL copy = ::GlobalAlloc(GMEM_MOVEABLE, sizeof(METAFILEPICT));
  auto *destination_picture =
      copy == nullptr ? nullptr
                      : static_cast<METAFILEPICT *>(::GlobalLock(copy));
  if (destination_picture == nullptr) {
    if (copy != nullptr) {
      ::GlobalFree(copy);
    }
    ::DeleteMetaFile(metafile_copy);
    ::GlobalUnlock(source);
    return kAllocationFailed;
  }
  destination_picture->mm = source_picture->mm;
  destination_picture->xExt = source_picture->xExt;
  destination_picture->yExt = source_picture->yExt;
  destination_picture->hMF = metafile_copy;
  ::GlobalUnlock(copy);
  ::GlobalUnlock(source);
  *output =
      ClipboardItem(format, copy, HandleKind::kMetafilePicture, estimated_size);
  return kSuccess;
}

int32_t CloneClipboardItem(UINT format, HANDLE source, uint64_t maximum_bytes,
                           uint64_t *total_bytes, ClipboardItem *output) {
  if (source == nullptr || format == CF_OWNERDISPLAY) {
    return kUnsupportedFormat;
  }
  switch (KindForFormat(format)) {
  case HandleKind::kGlobal:
    return CloneGlobal(format, source, maximum_bytes, total_bytes, output);
  case HandleKind::kBitmap:
    return CloneBitmap(format, source, maximum_bytes, total_bytes, output);
  case HandleKind::kPalette:
    return ClonePalette(format, source, maximum_bytes, total_bytes, output);
  case HandleKind::kEnhancedMetafile:
    return CloneEnhancedMetafile(format, source, maximum_bytes, total_bytes,
                                 output);
  case HandleKind::kMetafilePicture:
    return CloneMetafilePicture(format, source, maximum_bytes, total_bytes,
                                output);
  }
  return kUnsupportedFormat;
}

int32_t CloneStoredItems(const ClipboardSnapshot &snapshot,
                         std::vector<ClipboardItem> *items) {
  uint64_t total_bytes = 0;
  items->reserve(snapshot.items.size());
  for (const ClipboardItem &source : snapshot.items) {
    ClipboardItem copy;
    const int32_t status = CloneClipboardItem(
        source.format, source.handle, std::numeric_limits<uint64_t>::max(),
        &total_bytes, &copy);
    if (status != kSuccess) {
      return status;
    }
    items->push_back(std::move(copy));
  }
  return kSuccess;
}

HGLOBAL AllocateClipboardText(const wchar_t *text) {
  const wchar_t *value = text == nullptr ? L"" : text;
  const size_t length = std::wcslen(value);
  if (length > (std::numeric_limits<SIZE_T>::max() / sizeof(wchar_t)) - 1) {
    return nullptr;
  }
  const SIZE_T bytes = (length + 1) * sizeof(wchar_t);
  HGLOBAL memory = ::GlobalAlloc(GMEM_MOVEABLE, bytes);
  if (memory == nullptr) {
    return nullptr;
  }
  void *destination = ::GlobalLock(memory);
  if (destination == nullptr) {
    ::GlobalFree(memory);
    return nullptr;
  }
  std::memcpy(destination, value, bytes);
  ::GlobalUnlock(memory);
  return memory;
}

bool RestoreRollbackText(HGLOBAL *rollback) {
  if (rollback == nullptr || *rollback == nullptr) {
    return false;
  }
  if (::EmptyClipboard() == 0) {
    return false;
  }
  if (::SetClipboardData(CF_UNICODETEXT, *rollback) == nullptr) {
    return false;
  }
  *rollback = nullptr;
  return true;
}

}

int32_t CaptureClipboardSnapshotInProcess(intptr_t owner_window,
                                          uint64_t maximum_bytes,
                                          uint64_t *snapshot_token,
                                          uint32_t *captured_revision) {
  if (snapshot_token == nullptr || captured_revision == nullptr ||
      maximum_bytes == 0) {
    return kAllocationFailed;
  }
  *snapshot_token = 0;
  *captured_revision = 0;

  const uint32_t before_revision = ::GetClipboardSequenceNumber();
  ScopedClipboard clipboard(reinterpret_cast<HWND>(owner_window));
  if (!clipboard.opened()) {
    return kClipboardOpenFailed;
  }

  auto snapshot = std::make_unique<ClipboardSnapshot>();
  uint64_t total_bytes = 0;
  UINT format = 0;
  while (true) {
    ::SetLastError(ERROR_SUCCESS);
    const UINT next_format = ::EnumClipboardFormats(format);
    if (next_format == 0) {
      if (::GetLastError() != ERROR_SUCCESS) {
        return kUnsupportedFormat;
      }
      break;
    }
    format = next_format;
    if (snapshot->items.size() >= kMaximumFormatCount) {
      return kSnapshotTooLarge;
    }
    if (IsOwnerManagedFormat(format)) {
      return kUnsupportedFormat;
    }
    HANDLE source = ::GetClipboardData(format);
    ClipboardItem item;
    const int32_t status =
        CloneClipboardItem(format, source, maximum_bytes, &total_bytes, &item);
    if (status != kSuccess) {
      return status;
    }
    snapshot->items.push_back(std::move(item));
  }
  const uint32_t after_revision = ::GetClipboardSequenceNumber();
  if (after_revision != before_revision) {
    return kClipboardChangedDuringCapture;
  }

  snapshot->revision = after_revision;
  uint64_t token = g_next_snapshot_token.fetch_add(1);
  if (token == 0) {
    token = g_next_snapshot_token.fetch_add(1);
  }
  {
    std::lock_guard<std::mutex> lock(g_snapshots_mutex);
    g_snapshots[token] = std::move(snapshot);
  }
  *snapshot_token = token;
  *captured_revision = after_revision;
  return kSuccess;
}

int32_t RestoreClipboardSnapshotInProcess(intptr_t owner_window,
                                          uint64_t snapshot_token,
                                          uint32_t expected_revision,
                                          const wchar_t *rollback_text,
                                          uint32_t *resulting_revision) {
  if (resulting_revision == nullptr) {
    return kAllocationFailed;
  }
  *resulting_revision = ::GetClipboardSequenceNumber();

  std::lock_guard<std::mutex> lock(g_snapshots_mutex);
  const auto snapshot = g_snapshots.find(snapshot_token);
  if (snapshot == g_snapshots.end()) {
    return kSnapshotNotFound;
  }

  std::vector<ClipboardItem> transfer_items;
  const int32_t clone_status =
      CloneStoredItems(*snapshot->second, &transfer_items);
  if (clone_status != kSuccess) {
    return clone_status;
  }

  HGLOBAL rollback = AllocateClipboardText(rollback_text);
  if (rollback == nullptr) {
    return kAllocationFailed;
  }
  ClipboardItem rollback_owner(CF_UNICODETEXT, rollback, HandleKind::kGlobal,
                               ::GlobalSize(rollback));

  ScopedClipboard clipboard(reinterpret_cast<HWND>(owner_window));
  if (!clipboard.opened()) {
    return kClipboardOpenFailed;
  }
  if (::GetClipboardSequenceNumber() != expected_revision) {
    *resulting_revision = ::GetClipboardSequenceNumber();
    return kRevisionConflict;
  }
  if (::EmptyClipboard() == 0) {
    *resulting_revision = ::GetClipboardSequenceNumber();
    return kClipboardMutationFailed;
  }

  for (ClipboardItem &item : transfer_items) {
    if (::SetClipboardData(item.format, item.handle) == nullptr) {
      rollback = rollback_owner.handle;
      const bool rollback_succeeded = RestoreRollbackText(&rollback);
      rollback_owner.handle = rollback;
      *resulting_revision = ::GetClipboardSequenceNumber();
      return rollback_succeeded ? kClipboardMutationFailed : kRollbackFailed;
    }
    item.Release();
  }
  *resulting_revision = ::GetClipboardSequenceNumber();
  return kSuccess;
}

int32_t ReleaseClipboardSnapshotInProcess(uint64_t snapshot_token) {
  std::lock_guard<std::mutex> lock(g_snapshots_mutex);
  g_snapshots.erase(snapshot_token);
  return kSuccess;
}

int RunNativeClipboardSnapshotMemorySelfTest() {
  try {
    if (!IsOwnerManagedFormat(CF_PRIVATEFIRST) ||
        !IsOwnerManagedFormat(CF_PRIVATELAST) ||
        !IsOwnerManagedFormat(CF_GDIOBJFIRST) ||
        !IsOwnerManagedFormat(CF_GDIOBJLAST) ||
        !IsOwnerManagedFormat(CF_OWNERDISPLAY) ||
        IsOwnerManagedFormat(CF_UNICODETEXT)) {
      return 1;
    }
    constexpr wchar_t kText[] = L"YKD clipboard \x0416\x03A9";
    constexpr SIZE_T kTextBytes = sizeof(kText);
    HGLOBAL source = ::GlobalAlloc(GMEM_MOVEABLE, kTextBytes);
    if (source == nullptr) {
      return 2;
    }
    void *source_bytes = ::GlobalLock(source);
    if (source_bytes == nullptr) {
      ::GlobalFree(source);
      return 3;
    }
    std::memcpy(source_bytes, kText, kTextBytes);
    ::GlobalUnlock(source);

    uint64_t total_bytes = 0;
    ClipboardItem text_copy;
    const int32_t text_status = CloneClipboardItem(
        CF_UNICODETEXT, source, kTextBytes, &total_bytes, &text_copy);
    ::GlobalFree(source);
    if (text_status != kSuccess || total_bytes != kTextBytes) {
      return 4;
    }
    const auto *copied_text =
        static_cast<const wchar_t *>(::GlobalLock(text_copy.handle));
    if (copied_text == nullptr || std::wcscmp(copied_text, kText) != 0) {
      if (copied_text != nullptr) {
        ::GlobalUnlock(text_copy.handle);
      }
      return 5;
    }
    ::GlobalUnlock(text_copy.handle);

    uint64_t limited_total = 0;
    ClipboardItem rejected_copy;
    if (CloneClipboardItem(CF_UNICODETEXT, text_copy.handle, kTextBytes - 1,
                           &limited_total,
                           &rejected_copy) != kSnapshotTooLarge) {
      return 6;
    }

    constexpr uint32_t kPixels[] = {0xFF102030, 0xFF405060, 0xFF708090,
                                    0xFFA0B0C0};
    HBITMAP bitmap = ::CreateBitmap(2, 2, 1, 32, kPixels);
    if (bitmap == nullptr) {
      return 7;
    }
    uint64_t bitmap_bytes = 0;
    ClipboardItem bitmap_copy;
    const int32_t bitmap_status = CloneClipboardItem(
        CF_BITMAP, bitmap, 1024, &bitmap_bytes, &bitmap_copy);
    ::DeleteObject(bitmap);
    if (bitmap_status != kSuccess || bitmap_bytes == 0) {
      return 8;
    }
    BITMAP copied_bitmap{};
    if (::GetObject(bitmap_copy.handle, sizeof(copied_bitmap),
                    &copied_bitmap) != sizeof(copied_bitmap) ||
        copied_bitmap.bmWidth != 2 || copied_bitmap.bmHeight != 2) {
      return 9;
    }

    ClipboardSnapshot snapshot;
    snapshot.items.push_back(std::move(text_copy));
    snapshot.items.push_back(std::move(bitmap_copy));
    std::vector<ClipboardItem> second_generation;
    if (CloneStoredItems(snapshot, &second_generation) != kSuccess ||
        second_generation.size() != snapshot.items.size()) {
      return 10;
    }
    return 0;
  } catch (...) {
    return 11;
  }
}

extern "C" __declspec(dllexport) int32_t YkdCaptureClipboardSnapshot(
    intptr_t owner_window, uint64_t maximum_bytes, uint64_t *snapshot_token,
    uint32_t *captured_revision) {
  try {
    return CaptureClipboardSnapshotViaBroker(owner_window, maximum_bytes,
                                             snapshot_token, captured_revision);
  } catch (...) {
    return kAllocationFailed;
  }
}

extern "C" __declspec(dllexport) int32_t YkdRestoreClipboardSnapshotIfRevision(
    intptr_t owner_window, uint64_t snapshot_token, uint32_t expected_revision,
    const wchar_t *rollback_text, uint32_t *resulting_revision) {
  try {
    return RestoreClipboardSnapshotViaBroker(owner_window, snapshot_token,
                                             expected_revision, rollback_text,
                                             resulting_revision);
  } catch (...) {
    return kAllocationFailed;
  }
}

extern "C" __declspec(dllexport) int32_t
YkdReleaseClipboardSnapshot(uint64_t snapshot_token) {
  try {
    return ReleaseClipboardSnapshotViaBroker(snapshot_token);
  } catch (...) {
    return kAllocationFailed;
  }
}
