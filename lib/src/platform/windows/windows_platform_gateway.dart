import 'dart:async';
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:flutter/painting.dart' as painting;
import 'package:flutter/services.dart';

import 'package:win32/win32.dart';
import 'package:yandex_keyboard_desktop/src/platform/overlay/overlay_window_gateway.dart';
import 'package:yandex_keyboard_desktop/src/platform/overlay/overlay_window_controller.dart';
import 'package:yandex_keyboard_desktop/src/platform/selection/selection_platform_gateway.dart';
import 'package:yandex_keyboard_desktop/src/platform/windows/control_chord_injector.dart';
import 'package:yandex_keyboard_desktop/src/platform/windows/keyboard_input_gateway.dart';
import 'package:yandex_keyboard_desktop/src/platform/windows/windows_send_input_gateway.dart';
import 'package:yandex_keyboard_desktop/src/platform/windows/windows_native_clipboard_snapshot.dart';

final user32 = DynamicLibrary.open('user32.dll');
final shcore = DynamicLibrary.open('shcore.dll');
final GetCursorPos = user32.lookupFunction<
    Uint8 Function(Pointer<POINT> lpPoint),
    int Function(Pointer<POINT> lpPoint)>('GetCursorPos');
final GetSystemMetrics = user32.lookupFunction<Int32 Function(Int32 nIndex),
    int Function(int nIndex)>('GetSystemMetrics');
final SetWindowLongPtr = user32.lookupFunction<
    IntPtr Function(IntPtr hWnd, Int32 nIndex, IntPtr dwNewLong),
    int Function(int hWnd, int nIndex, int dwNewLong)>('SetWindowLongPtrW');
final GetWindowLongPtr = user32.lookupFunction<
    IntPtr Function(IntPtr hWnd, Int32 nIndex),
    int Function(int hWnd, int nIndex)>('GetWindowLongPtrW');
final SetForegroundWindow =
    user32.lookupFunction<Int32 Function(IntPtr hWnd), int Function(int hWnd)>(
        'SetForegroundWindow');
final GetForegroundWindow = user32
    .lookupFunction<IntPtr Function(), int Function()>('GetForegroundWindow');
final SetWindowPos = user32.lookupFunction<
    Int32 Function(IntPtr hWnd, IntPtr hWndInsertAfter, Int32 X, Int32 Y,
        Int32 cx, Int32 cy, Uint32 uFlags),
    int Function(int hWnd, int hWndInsertAfter, int X, int Y, int cx, int cy,
        int uFlags)>('SetWindowPos');
final ShowWindow = user32.lookupFunction<
    Int32 Function(IntPtr hWnd, Int32 nCmdShow),
    int Function(int hWnd, int nCmdShow)>('ShowWindow');
final GetDpiForMonitorNative = shcore.lookupFunction<
    Int32 Function(IntPtr monitor, Int32 dpiType, Pointer<Uint32> dpiX,
        Pointer<Uint32> dpiY),
    int Function(int monitor, int dpiType, Pointer<Uint32> dpiX,
        Pointer<Uint32> dpiY)>('GetDpiForMonitor');

final class _AccentPolicy extends Struct {
  @Int32()
  external int accentState;
  @Int32()
  external int flags;
  @Int32()
  external int gradientColor;
  @Int32()
  external int animationId;
}

final class _WindowCompositionAttributeData extends Struct {
  @Int32()
  external int attribute;
  external Pointer<NativeType> data;
  @IntPtr()
  external int size;
}

typedef _SetWindowCompositionAttributeNative = Int32 Function(
    IntPtr hwnd, Pointer<_WindowCompositionAttributeData> data);

final _setWindowCompositionAttribute = () {
  try {
    return user32.lookupFunction<_SetWindowCompositionAttributeNative,
            int Function(int, Pointer<_WindowCompositionAttributeData>)>(
        'SetWindowCompositionAttribute');
  } catch (_) {
    return null;
  }
}();

int _monitorForPhysicalPoint(Offset point) {
  final nativePoint = calloc<POINT>();
  try {
    nativePoint.ref
      ..x = point.dx.round()
      ..y = point.dy.round();
    return MonitorFromPoint(
      nativePoint.ref,
      const MONITOR_FROM_FLAGS(2),
    );
  } finally {
    calloc.free(nativePoint);
  }
}

class WindowsPlatformGateway
    implements
        SelectionPlatformGateway,
        NativeClipboardSnapshotGateway,
        TargetInteractionPermissionGateway,
        OverlayWindowGateway,
        OverlayAnchorGateway,
        OverlayMaterialGateway,
        NativeOverlayPlacementGateway,
        NativeOverlayActivationGateway {
  WindowsPlatformGateway({
    WindowsNativeClipboardSnapshotBridge? nativeClipboardSnapshots,
    KeyboardInputGateway? keyboardInput,
  })  : _nativeClipboardSnapshots =
            nativeClipboardSnapshots ?? WindowsNativeClipboardSnapshotBridge(),
        _keyboardInput = keyboardInput ?? const WindowsSendInputGateway();

  final WindowsNativeClipboardSnapshotBridge _nativeClipboardSnapshots;
  final KeyboardInputGateway _keyboardInput;

  int _originalWindowHandle = 0;

  @override
  Future<String> getSelectedText(int targetHandle) async {
    if (!await canInteractWithTarget(targetHandle)) {
      throw StateError('The selection target has a higher integrity level.');
    }
    if (!await focusWindow(targetHandle)) {
      throw StateError('Unable to focus the selection target.');
    }
    await _sendControlChordSpaced(0x43);

    await Future.delayed(const Duration(milliseconds: 100));
    return (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
  }

  @override
  Future<painting.Size> getScreenSize() {
    final screenWidth = GetSystemMetrics(SYSTEM_METRICS_INDEX.SM_CXSCREEN);
    final screenHeight = GetSystemMetrics(SYSTEM_METRICS_INDEX.SM_CYSCREEN);
    return Future.value(
        painting.Size(screenWidth.toDouble(), screenHeight.toDouble()));
  }

  @override
  Future<painting.Rect> getWorkAreaForPoint(Offset point) async {
    final monitor = _monitorForPhysicalPoint(point);
    final info = calloc<MONITORINFO>();
    try {
      info.ref.cbSize = sizeOf<MONITORINFO>();
      if (GetMonitorInfo(monitor, info) == 0) {
        throw StateError('Unable to read the Windows monitor work area.');
      }
      final work = info.ref.rcWork;
      return painting.Rect.fromLTRB(
        work.left.toDouble(),
        work.top.toDouble(),
        work.right.toDouble(),
        work.bottom.toDouble(),
      );
    } finally {
      calloc.free(info);
    }
  }

  @override
  Future<Offset> getCursorPos() async {
    final point = calloc<POINT>();
    try {
      if (GetCursorPos(point) == 0) {
        throw StateError('Unable to read the Windows cursor position.');
      }
      return Offset(point.ref.x.toDouble(), point.ref.y.toDouble());
    } finally {
      calloc.free(point);
    }
  }

  static const _accentEnableAcrylicBlurBehind = 4;
  static const _accentEnableBlurBehind = 3;
  static const _wcaAccentPolicy = 19;
  static const _dwmwaWindowCornerPreference = 33;
  static const _dwmwcpRound = 2;
  static const _dwmwaSystemBackdropType = 38;
  static const _dwmsbtTransientWindow = 3;

  @override
  Future<bool> applyGlassMaterial() async {
    final window = await getFlutterWindowHandle();
    if (window == 0) return false;

    final preference = calloc<Int32>()..value = _dwmwcpRound;
    try {
      DwmSetWindowAttribute(
        window,
        _dwmwaWindowCornerPreference,
        preference.cast(),
        sizeOf<Int32>(),
      );
    } finally {
      calloc.free(preference);
    }

    return _applySystemBackdrop(window) || _applyAccentBackdrop(window);
  }

  bool _applySystemBackdrop(int window) {
    final margins = calloc<MARGINS>();
    final backdrop = calloc<Int32>()..value = _dwmsbtTransientWindow;
    try {
      margins.ref
        ..cxLeftWidth = -1
        ..cxRightWidth = -1
        ..cyTopHeight = -1
        ..cyBottomHeight = -1;
      if (DwmExtendFrameIntoClientArea(window, margins) != 0) return false;
      return DwmSetWindowAttribute(
            window,
            _dwmwaSystemBackdropType,
            backdrop.cast(),
            sizeOf<Int32>(),
          ) ==
          0;
    } finally {
      calloc
        ..free(margins)
        ..free(backdrop);
    }
  }

  bool _applyAccentBackdrop(int window) {
    final setAttribute = _setWindowCompositionAttribute;
    if (setAttribute == null) return false;

    bool applyAccent(int accentState) {
      final policy = calloc<_AccentPolicy>();
      final data = calloc<_WindowCompositionAttributeData>();
      try {
        policy.ref
          ..accentState = accentState
          ..flags = 2
          ..gradientColor = 0x20000000
          ..animationId = 0;
        data.ref
          ..attribute = _wcaAccentPolicy
          ..data = policy.cast()
          ..size = sizeOf<_AccentPolicy>();
        return setAttribute(window, data) != 0;
      } finally {
        calloc
          ..free(policy)
          ..free(data);
      }
    }

    return applyAccent(_accentEnableAcrylicBlurBehind) ||
        applyAccent(_accentEnableBlurBehind);
  }

  @override
  Future<Offset?> getCaretAnchorPoint(int targetWindow) async {
    if (targetWindow == 0 || IsWindow(targetWindow) == 0) return null;
    final threadId = GetWindowThreadProcessId(targetWindow, nullptr);
    if (threadId == 0) return null;
    final info = calloc<GUITHREADINFO>();
    final point = calloc<POINT>();
    try {
      info.ref.cbSize = sizeOf<GUITHREADINFO>();
      if (GetGUIThreadInfo(threadId, info) == 0) return null;
      final caretWindow = info.ref.hwndCaret;
      final caret = info.ref.rcCaret;
      if (caretWindow == 0 || caret.bottom <= caret.top) return null;
      if (GetAncestor(caretWindow, GET_ANCESTOR_FLAGS.GA_ROOT) !=
          targetWindow) {
        return null;
      }
      point.ref
        ..x = caret.left
        ..y = caret.bottom;
      if (ClientToScreen(caretWindow, point) == 0) return null;
      return Offset(point.ref.x.toDouble(), point.ref.y.toDouble());
    } finally {
      calloc
        ..free(info)
        ..free(point);
    }
  }

  @override
  Future<NativeOverlayPlacement> resolveOverlayPlacement({
    required Offset point,
    required painting.Size desiredLogicalSize,
    double logicalGap = 10,
  }) async {
    final workArea = await getWorkAreaForPoint(point);
    final monitor = _monitorForPhysicalPoint(point);
    final dpiX = calloc<Uint32>();
    final dpiY = calloc<Uint32>();
    try {
      if (GetDpiForMonitorNative(monitor, 0, dpiX, dpiY) != 0) {
        throw StateError('Unable to read the Windows monitor DPI.');
      }
      final scaleFactor = dpiX.value / 96.0;
      final bounds = physicalOverlayBoundsNearPoint(
        point: point,
        physicalWorkArea: workArea,
        desiredLogicalSize: desiredLogicalSize,
        scaleFactor: scaleFactor,
        logicalGap: logicalGap,
      );
      final window = await getFlutterWindowHandle();
      if (window == 0) {
        throw StateError('Unable to find the Windows overlay window.');
      }
      return NativeOverlayPlacement(
        nativeWindowHandle: window,
        nativeBounds: bounds,
        logicalSize: painting.Size(
          bounds.width / scaleFactor,
          bounds.height / scaleFactor,
        ),
      );
    } finally {
      calloc.free(dpiX);
      calloc.free(dpiY);
    }
  }

  @override
  void applyOverlayPlacement(NativeOverlayPlacement placement) {
    final bounds = placement.nativeBounds;
    if (SetWindowPos(
          placement.nativeWindowHandle,
          0,
          bounds.left.round(),
          bounds.top.round(),
          bounds.width.round(),
          bounds.height.round(),
          SET_WINDOW_POS_FLAGS.SWP_NOACTIVATE |
              SET_WINDOW_POS_FLAGS.SWP_NOZORDER,
        ) ==
        0) {
      throw StateError('Unable to place the Windows overlay window.');
    }
  }

  @override
  void setWindowCanActivate(int nativeWindowHandle, bool canActivate) {
    const noActivateStyle = WINDOW_EX_STYLE.WS_EX_NOACTIVATE;
    const extendedStyleIndex = WINDOW_LONG_PTR_INDEX.GWL_EXSTYLE;
    final currentStyle = GetWindowLongPtr(
      nativeWindowHandle,
      extendedStyleIndex,
    );
    final nextStyle = canActivate
        ? currentStyle & ~noActivateStyle
        : currentStyle | noActivateStyle;
    if (nextStyle == currentStyle) return;
    SetWindowLongPtr(nativeWindowHandle, extendedStyleIndex, nextStyle);
    SetWindowPos(
      nativeWindowHandle,
      0,
      0,
      0,
      0,
      0,
      SET_WINDOW_POS_FLAGS.SWP_NOMOVE |
          SET_WINDOW_POS_FLAGS.SWP_NOSIZE |
          SET_WINDOW_POS_FLAGS.SWP_NOZORDER |
          SET_WINDOW_POS_FLAGS.SWP_NOACTIVATE |
          SET_WINDOW_POS_FLAGS.SWP_FRAMECHANGED,
    );
  }

  @override
  void showWindowInactive(int nativeWindowHandle) {
    ShowWindow(nativeWindowHandle, SHOW_WINDOW_CMD.SW_SHOWNOACTIVATE);
    SetWindowPos(
      nativeWindowHandle,
      0,
      0,
      0,
      0,
      0,
      SET_WINDOW_POS_FLAGS.SWP_NOMOVE |
          SET_WINDOW_POS_FLAGS.SWP_NOSIZE |
          SET_WINDOW_POS_FLAGS.SWP_NOZORDER |
          SET_WINDOW_POS_FLAGS.SWP_NOACTIVATE |
          SET_WINDOW_POS_FLAGS.SWP_SHOWWINDOW,
    );
  }

  @override
  Future<void> replaceSelectedText(int targetHandle, String newText) async {
    if (!await canInteractWithTarget(targetHandle) ||
        targetHandle == 0 ||
        IsWindow(targetHandle) == 0 ||
        GetForegroundWindow() != targetHandle) {
      throw StateError('Unable to focus the replacement target.');
    }
    await _sendControlChordSpaced(0x56);
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }

  Future<void> _sendControlChordSpaced(int virtualKey) async {
    _releaseHeldModifiers();
    await ControlChordInjector(
      gateway: _keyboardInput,
      controlVirtualKey: VIRTUAL_KEY.VK_CONTROL,
    ).inject(virtualKey);
  }

  void _releaseHeldModifiers() {
    const modifierVirtualKeys = <int>[
      VIRTUAL_KEY.VK_SHIFT,
      VIRTUAL_KEY.VK_CONTROL,
      VIRTUAL_KEY.VK_MENU,
      VIRTUAL_KEY.VK_LWIN,
      VIRTUAL_KEY.VK_RWIN,
      VIRTUAL_KEY.VK_LSHIFT,
      VIRTUAL_KEY.VK_RSHIFT,
      VIRTUAL_KEY.VK_LCONTROL,
      VIRTUAL_KEY.VK_RCONTROL,
      VIRTUAL_KEY.VK_LMENU,
      VIRTUAL_KEY.VK_RMENU,
    ];
    final held = <KeyboardStroke>[];
    for (final virtualKey in modifierVirtualKeys) {
      if (GetAsyncKeyState(virtualKey) & 0x8000 != 0) {
        held.add(KeyboardStroke(virtualKey: virtualKey, isKeyUp: true));
      }
    }
    if (held.isEmpty) return;
    try {
      sendKeyboardStrokesChecked(_keyboardInput, held);
    } on PartialKeyboardInjectionException {
      releaseKeyboardStrokesBestEffort(_keyboardInput, held);
      rethrow;
    }
  }

  @override
  Future<int> getForegroundWindow() async {
    return GetForegroundWindow();
  }

  @override
  Future<int> getWindowProcessId(int handle) async {
    final processId = calloc<Uint32>();
    try {
      GetWindowThreadProcessId(handle, processId);
      return processId.value;
    } finally {
      calloc.free(processId);
    }
  }

  @override
  Future<bool> canInteractWithTarget(int targetHandle) async {
    final targetProcessId = await getWindowProcessId(targetHandle);
    if (targetProcessId == 0) return false;
    final targetProcess = OpenProcess(
      PROCESS_ACCESS_RIGHTS.PROCESS_QUERY_LIMITED_INFORMATION,
      FALSE,
      targetProcessId,
    );
    if (targetProcess == 0) return false;
    try {
      final currentIntegrity = _integrityRidForProcess(GetCurrentProcess());
      final targetIntegrity = _integrityRidForProcess(targetProcess);
      return currentIntegrity != null &&
          targetIntegrity != null &&
          currentIntegrity >= targetIntegrity;
    } finally {
      CloseHandle(targetProcess);
    }
  }

  int? _integrityRidForProcess(int process) {
    final token = calloc<IntPtr>();
    final requiredBytes = calloc<Uint32>();
    try {
      if (OpenProcessToken(
            process,
            TOKEN_ACCESS_MASK.TOKEN_QUERY,
            token,
          ) ==
          0) {
        return null;
      }
      try {
        GetTokenInformation(
          token.value,
          TOKEN_INFORMATION_CLASS.TokenIntegrityLevel,
          nullptr,
          0,
          requiredBytes,
        );
        if (requiredBytes.value < sizeOf<IntPtr>() + sizeOf<Uint32>()) {
          return null;
        }
        final buffer = calloc<Uint8>(requiredBytes.value);
        try {
          if (GetTokenInformation(
                token.value,
                TOKEN_INFORMATION_CLASS.TokenIntegrityLevel,
                buffer,
                requiredBytes.value,
                requiredBytes,
              ) ==
              0) {
            return null;
          }
          final sidAddress = buffer.cast<IntPtr>().value;
          if (sidAddress == 0) return null;
          final sid = Pointer<Uint8>.fromAddress(sidAddress);
          final subAuthorityCount = (sid + 1).value;
          if (subAuthorityCount == 0) return null;
          return Pointer<Uint32>.fromAddress(
            sidAddress + 8 + ((subAuthorityCount - 1) * sizeOf<Uint32>()),
          ).value;
        } finally {
          calloc.free(buffer);
        }
      } finally {
        CloseHandle(token.value);
      }
    } finally {
      calloc
        ..free(token)
        ..free(requiredBytes);
    }
  }

  @override
  int getOriginalForegroundWindow() => _originalWindowHandle;

  @override
  Future<int> getClipboardRevision() async => GetClipboardSequenceNumber();

  @override
  Future<bool> isWindowValid(int handle) async =>
      handle != 0 && IsWindow(handle) != 0;

  @override
  Future<bool> focusWindow(int handle) async {
    if (!await isWindowValid(handle) || SetForegroundWindow(handle) == 0) {
      return false;
    }
    await Future<void>.delayed(const Duration(milliseconds: 40));
    return GetForegroundWindow() == handle;
  }

  @override
  Future<bool> supportsLosslessTextClipboardSnapshot() async {
    if (OpenClipboard(0) == 0) {
      return false;
    }
    try {
      var format = 0;
      while (true) {
        format = EnumClipboardFormats(format);
        if (format == 0) {
          return true;
        }
        if (format != CLIPBOARD_FORMAT.CF_UNICODETEXT) {
          return false;
        }
      }
    } finally {
      CloseClipboard();
    }
  }

  @override
  Future<bool> supportsNativeClipboardSnapshots() async =>
      _nativeClipboardSnapshots.isAvailable;

  @override
  Future<PlatformClipboardSnapshot> captureNativeClipboardSnapshot() async {
    final owner = await getFlutterWindowHandle();
    return _nativeClipboardSnapshots.capture(ownerWindow: owner);
  }

  @override
  Future<int?> restoreNativeClipboardSnapshotIfRevision(
    Object payload, {
    required int expectedRevision,
    required String rollbackText,
  }) async {
    final owner = await getFlutterWindowHandle();
    return _nativeClipboardSnapshots.restore(
      payload,
      ownerWindow: owner,
      expectedRevision: expectedRevision,
      rollbackText: rollbackText,
    );
  }

  @override
  Future<void> releaseNativeClipboardSnapshot(Object payload) async {
    _nativeClipboardSnapshots.release(payload);
  }

  @override
  Future<bool> isClipboardOwnedByTarget(int handle) async {
    final owner = GetClipboardOwner();
    if (owner == 0 || handle == 0) {
      return false;
    }
    if (owner == handle) {
      return true;
    }
    final ownerProcess = calloc<Uint32>();
    final targetProcess = calloc<Uint32>();
    try {
      GetWindowThreadProcessId(owner, ownerProcess);
      GetWindowThreadProcessId(handle, targetProcess);
      return ownerProcess.value != 0 &&
          ownerProcess.value == targetProcess.value;
    } finally {
      calloc.free(ownerProcess);
      calloc.free(targetProcess);
    }
  }

  @override
  bool supportsAtomicTextClipboardTransactions() => true;

  @override
  Future<int?> writeClipboardTextIfRevision(
    String text, {
    required int expectedRevision,
    required String rollbackText,
  }) async {
    final clipboardOwner = await getFlutterWindowHandle();
    if (clipboardOwner == 0 || !await isWindowValid(clipboardOwner)) {
      throw const ClipboardTransactionException(
        code: 'clipboard_owner_unavailable',
        retryable: false,
      );
    }
    final desiredMemory = _allocateClipboardText(text);
    Pointer? rollbackMemory;
    var desiredTransferred = false;
    var rollbackTransferred = false;
    try {
      rollbackMemory = _allocateClipboardText(rollbackText);
      if (OpenClipboard(clipboardOwner) == 0) {
        throw const ClipboardTransactionException(
          code: 'clipboard_open_failed',
          retryable: true,
        );
      }
      var revisionMatched = false;
      var desiredWritten = false;
      var rollbackWritten = false;
      try {
        if (GetClipboardSequenceNumber() == expectedRevision) {
          revisionMatched = true;
          if (EmptyClipboard() == 0) {
            throw const ClipboardTransactionException(
              code: 'clipboard_empty_failed',
              retryable: true,
            );
          }
          if (SetClipboardData(
                CLIPBOARD_FORMAT.CF_UNICODETEXT,
                desiredMemory.address,
              ) !=
              0) {
            desiredTransferred = true;
            desiredWritten = true;
            _excludeStagedContentFromClipboardMonitors();
          } else if (SetClipboardData(
                CLIPBOARD_FORMAT.CF_UNICODETEXT,
                rollbackMemory.address,
              ) !=
              0) {
            rollbackTransferred = true;
            rollbackWritten = true;
          }
        }
      } finally {
        CloseClipboard();
      }
      if (!revisionMatched) return null;
      if (desiredWritten) return GetClipboardSequenceNumber();
      if (rollbackWritten) {
        throw AtomicClipboardMutationException(
          revision: GetClipboardSequenceNumber(),
          currentText: rollbackText,
        );
      }
      throw AtomicClipboardMutationException(
        revision: GetClipboardSequenceNumber(),
        currentText: '',
      );
    } finally {
      if (!desiredTransferred) GlobalFree(desiredMemory);
      if (!rollbackTransferred && rollbackMemory != null) {
        GlobalFree(rollbackMemory);
      }
    }
  }

  static int _clipboardHistoryExclusionFormat = 0;

  void _excludeStagedContentFromClipboardMonitors() {
    if (_clipboardHistoryExclusionFormat == 0) {
      final name =
          'ExcludeClipboardContentFromMonitorProcessing'.toNativeUtf16();
      try {
        _clipboardHistoryExclusionFormat = RegisterClipboardFormat(name);
      } finally {
        calloc.free(name);
      }
    }
    if (_clipboardHistoryExclusionFormat == 0) return;
    final marker =
        GlobalAlloc(GLOBAL_ALLOC_FLAGS.GMEM_MOVEABLE, sizeOf<Uint32>());
    if (marker == nullptr) return;
    final locked = GlobalLock(marker);
    if (locked == nullptr) {
      GlobalFree(marker);
      return;
    }
    locked.cast<Uint32>().value = 0;
    GlobalUnlock(marker);
    if (SetClipboardData(_clipboardHistoryExclusionFormat, marker.address) ==
        0) {
      GlobalFree(marker);
    }
  }

  Pointer _allocateClipboardText(String text) {
    final source = text.toNativeUtf16();
    try {
      final byteLength = (text.length + 1) * sizeOf<Uint16>();
      final memory = GlobalAlloc(
        GLOBAL_ALLOC_FLAGS.GMEM_MOVEABLE,
        byteLength,
      );
      if (memory == nullptr) {
        throw const ClipboardTransactionException(
          code: 'clipboard_allocation_failed',
          retryable: false,
        );
      }
      final destination = GlobalLock(memory);
      if (destination == nullptr) {
        GlobalFree(memory);
        throw const ClipboardTransactionException(
          code: 'clipboard_memory_lock_failed',
          retryable: false,
        );
      }
      try {
        destination.cast<Uint8>().asTypedList(byteLength).setAll(
              0,
              source.cast<Uint8>().asTypedList(byteLength),
            );
      } finally {
        GlobalUnlock(memory);
      }
      return memory;
    } finally {
      calloc.free(source);
    }
  }

  @override
  void setOriginalForegroundWindow(int handle) {
    _originalWindowHandle = handle;
  }

  @override
  Future<int> getFlutterWindowHandle() async {
    final className = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
    try {
      final currentProcessId = GetCurrentProcessId();
      var previous = 0;
      while (true) {
        final handle = FindWindowEx(0, previous, className, nullptr);
        if (handle == 0) return 0;
        if (await getWindowProcessId(handle) == currentProcessId) return handle;
        previous = handle;
      }
    } finally {
      calloc.free(className);
    }
  }
}
