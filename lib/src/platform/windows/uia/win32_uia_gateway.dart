import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';
import 'package:yandex_keyboard_desktop/src/platform/windows/uia/windows_uia_gateway.dart';
import 'package:yandex_keyboard_desktop/src/platform/windows/windows_target_identity.dart';

final _safeArrayDestroy = DynamicLibrary.open('oleaut32.dll').lookupFunction<
    Int32 Function(Pointer<SAFEARRAY>),
    int Function(Pointer<SAFEARRAY>)>('SafeArrayDestroy');
final _ole32 = DynamicLibrary.open('ole32.dll');
final _coEnableCallCancellation =
    _ole32.lookupFunction<Int32 Function(Pointer), int Function(Pointer)>(
        'CoEnableCallCancellation');
final _coDisableCallCancellation =
    _ole32.lookupFunction<Int32 Function(Pointer), int Function(Pointer)>(
        'CoDisableCallCancellation');
Map<String, Object?> runWin32UiaProbeSynchronously({
  required int expectedWindowHandle,
  required int expectedProcessId,
  required bool includeSelection,
  required int maxTextLength,
}) =>
    _probeUia(
      expectedWindowHandle: expectedWindowHandle,
      expectedProcessId: expectedProcessId,
      includeSelection: includeSelection,
      maxTextLength: maxTextLength,
    );

Map<String, Object?> _probeUia({
  required int expectedWindowHandle,
  required int expectedProcessId,
  required bool includeSelection,
  required int maxTextLength,
}) {
  final initializeResult = CoInitializeEx(
    nullptr,
    COINIT.COINIT_MULTITHREADED,
  );
  if (FAILED(initializeResult)) {
    return _statusMap(
      _isAccessDenied(initializeResult)
          ? WindowsUiaProbeStatus.accessDenied
          : WindowsUiaProbeStatus.providerFailure,
    );
  }

  CUIAutomation? automation;
  final cancellationEnabled = !FAILED(_coEnableCallCancellation(nullptr));
  _FocusedElementProbe? first;
  _FocusedElementProbe? second;
  try {
    automation = CUIAutomation.createInstance();
    first = _inspectFocusedElement(
      automation,
      expectedWindowHandle: expectedWindowHandle,
      expectedProcessId: expectedProcessId,
    );
    if (first.status != WindowsUiaProbeStatus.success) {
      return _statusMap(first.status);
    }
    if (!includeSelection) {
      return _successMap(first.identity!);
    }

    final selection = _readTextSelection(
      first.element!,
      maxTextLength: maxTextLength,
    );
    if (selection.status != WindowsUiaProbeStatus.success) {
      return selection.status == WindowsUiaProbeStatus.patternUnavailable
          ? _probeMap(selection.status, identity: first.identity)
          : _statusMap(selection.status);
    }

    second = _inspectFocusedElement(
      automation,
      expectedWindowHandle: expectedWindowHandle,
      expectedProcessId: expectedProcessId,
    );
    if (second.status != WindowsUiaProbeStatus.success ||
        !first.identity!.hasSameControl(second.identity!)) {
      return _statusMap(WindowsUiaProbeStatus.targetChanged);
    }
    return _successMap(first.identity!, text: selection.text);
  } on _UiaStatusException catch (error) {
    return _statusMap(error.status);
  } on WindowsException catch (error) {
    return _statusMap(
      _isAccessDenied(error.hr)
          ? WindowsUiaProbeStatus.accessDenied
          : WindowsUiaProbeStatus.providerFailure,
    );
  } catch (_) {
    return _statusMap(WindowsUiaProbeStatus.providerFailure);
  } finally {
    final secondElement = second?.element;
    if (secondElement != null) _releaseComObject(secondElement);
    final firstElement = first?.element;
    if (firstElement != null) _releaseComObject(firstElement);
    if (automation != null) _releaseComObject(automation);
    if (cancellationEnabled) _coDisableCallCancellation(nullptr);
    CoUninitialize();
  }
}

_FocusedElementProbe _inspectFocusedElement(
  IUIAutomation automation, {
  required int expectedWindowHandle,
  required int expectedProcessId,
}) {
  if (GetForegroundWindow() != expectedWindowHandle) {
    return _FocusedElementProbe(WindowsUiaProbeStatus.targetChanged);
  }
  final elementStorage = calloc<COMObject>();
  IUIAutomationElement? element;
  try {
    final result = automation.getFocusedElement(
      elementStorage.cast<Pointer<COMObject>>(),
    );
    if (FAILED(result) || elementStorage.ref.isNull) {
      throw _UiaStatusException(
        _isAccessDenied(result)
            ? WindowsUiaProbeStatus.accessDenied
            : WindowsUiaProbeStatus.providerFailure,
      );
    }
    element = IUIAutomationElement(elementStorage);
    final processId = element.currentProcessId;
    if (processId != expectedProcessId) {
      _releaseComObject(element);
      element = null;
      return _FocusedElementProbe(WindowsUiaProbeStatus.targetChanged);
    }
    if (element.currentIsPassword != 0) {
      _releaseComObject(element);
      element = null;
      return _FocusedElementProbe(WindowsUiaProbeStatus.passwordControl);
    }
    final nativeHandle = element.currentNativeWindowHandle;
    if (nativeHandle != 0) {
      final rootHandle = GetAncestor(
        nativeHandle,
        GET_ANCESTOR_FLAGS.GA_ROOT,
      );
      if (nativeHandle != expectedWindowHandle &&
          rootHandle != expectedWindowHandle) {
        _releaseComObject(element);
        element = null;
        return _FocusedElementProbe(WindowsUiaProbeStatus.targetChanged);
      }
    }
    final runtimeId = _readRuntimeId(element);
    if (runtimeId.isEmpty) {
      _releaseComObject(element);
      element = null;
      return _FocusedElementProbe(WindowsUiaProbeStatus.providerFailure);
    }
    final identity = WindowsTargetIdentity(
      windowHandle: expectedWindowHandle,
      processId: processId,
      runtimeId: runtimeId,
    );
    return _FocusedElementProbe(
      WindowsUiaProbeStatus.success,
      identity: identity,
      element: element,
    );
  } catch (_) {
    if (element != null) {
      _releaseComObject(element);
    } else {
      calloc.free(elementStorage);
    }
    rethrow;
  }
}

_TextSelectionProbe _readTextSelection(
  IUIAutomationElement element, {
  required int maxTextLength,
}) {
  final patternStorage = calloc<COMObject>();
  final textPatternIid = convertToIID(IID_IUIAutomationTextPattern);
  IUIAutomationTextPattern? pattern;
  IUIAutomationTextRangeArray? ranges;
  IUIAutomationTextRange? range;
  try {
    final patternResult = element.getCurrentPatternAs(
      UIA_PATTERN_ID.UIA_TextPatternId,
      textPatternIid,
      patternStorage.cast<Pointer>(),
    );
    final patternIsNull = patternStorage.ref.isNull;
    if (FAILED(patternResult) || patternIsNull) {
      calloc.free(patternStorage);
      if (patternIsNull || _isPatternUnavailable(patternResult)) {
        return const _TextSelectionProbe(
          WindowsUiaProbeStatus.patternUnavailable,
        );
      }
      throw WindowsException(patternResult);
    }
    pattern = IUIAutomationTextPattern(patternStorage);

    final rangesStorage = calloc<COMObject>();
    final rangesResult = pattern.getSelection(
      rangesStorage.cast<Pointer<COMObject>>(),
    );
    if (FAILED(rangesResult) || rangesStorage.ref.isNull) {
      calloc.free(rangesStorage);
      throw WindowsException(rangesResult);
    }
    ranges = IUIAutomationTextRangeArray(rangesStorage);
    final rangeCount = ranges.length;
    if (rangeCount == 0) {
      return const _TextSelectionProbe(WindowsUiaProbeStatus.noSelection);
    }
    if (rangeCount != 1) {
      return const _TextSelectionProbe(
        WindowsUiaProbeStatus.multipleSelection,
      );
    }

    final rangeStorage = calloc<COMObject>();
    final rangeResult = ranges.getElement(
      0,
      rangeStorage.cast<Pointer<COMObject>>(),
    );
    if (FAILED(rangeResult) || rangeStorage.ref.isNull) {
      calloc.free(rangeStorage);
      throw WindowsException(rangeResult);
    }
    range = IUIAutomationTextRange(rangeStorage);
    final text = _readBstrText(range, maxTextLength + 1);
    if (text.length > maxTextLength) {
      return const _TextSelectionProbe(
        WindowsUiaProbeStatus.selectionTooLarge,
      );
    }
    if (text.isEmpty) {
      return const _TextSelectionProbe(WindowsUiaProbeStatus.noSelection);
    }
    return _TextSelectionProbe(WindowsUiaProbeStatus.success, text: text);
  } finally {
    calloc.free(textPatternIid);
    if (range != null) _releaseComObject(range);
    if (ranges != null) _releaseComObject(ranges);
    if (pattern != null) _releaseComObject(pattern);
  }
}

String _readBstrText(IUIAutomationTextRange range, int maxLength) {
  final output = calloc<Pointer<Utf16>>();
  try {
    final result = range.getText(maxLength, output);
    if (FAILED(result)) throw WindowsException(result);
    final value = output.value;
    if (value == nullptr) return '';
    try {
      return value.toDartString();
    } finally {
      SysFreeString(value);
    }
  } finally {
    calloc.free(output);
  }
}

List<int> _readRuntimeId(IUIAutomationElement element) {
  final output = calloc<Pointer<SAFEARRAY>>();
  try {
    final result = element.getRuntimeId(output);
    if (FAILED(result)) throw WindowsException(result);
    final safeArray = output.value;
    if (safeArray == nullptr) return const [];
    try {
      if (safeArray.ref.cDims != 1 ||
          safeArray.ref.cbElements != sizeOf<Int32>()) {
        return const [];
      }
      final length = safeArray.ref.rgsabound[0].cElements;
      if (length == 0 || safeArray.ref.pvData == nullptr) return const [];
      return List<int>.of(
        safeArray.ref.pvData.cast<Int32>().asTypedList(length),
      );
    } finally {
      _safeArrayDestroy(safeArray);
    }
  } finally {
    calloc.free(output);
  }
}

void _releaseComObject(IUnknown object) {
  object.detach();
  object.release();
  calloc.free(object.ptr);
}

bool _isPatternUnavailable(int result) =>
    result == E_NOINTERFACE || result == UIA_E_NOTSUPPORTED.toSigned(32);

bool _isAccessDenied(int result) => result == E_ACCESSDENIED;

Map<String, Object?> _statusMap(WindowsUiaProbeStatus status) =>
    <String, Object?>{'status': status.name};

Map<String, Object?> _probeMap(
  WindowsUiaProbeStatus status, {
  WindowsTargetIdentity? identity,
}) =>
    <String, Object?>{
      'status': status.name,
      if (identity != null) ...{
        'windowHandle': identity.windowHandle,
        'processId': identity.processId,
        'runtimeId': identity.runtimeId,
      },
    };

Map<String, Object?> _successMap(
  WindowsTargetIdentity identity, {
  String? text,
}) =>
    <String, Object?>{
      'status': WindowsUiaProbeStatus.success.name,
      'windowHandle': identity.windowHandle,
      'processId': identity.processId,
      'runtimeId': identity.runtimeId,
      if (text != null) 'text': text,
    };

final class _FocusedElementProbe {
  const _FocusedElementProbe(
    this.status, {
    this.identity,
    this.element,
  });

  final WindowsUiaProbeStatus status;
  final WindowsTargetIdentity? identity;
  final IUIAutomationElement? element;
}

final class _TextSelectionProbe {
  const _TextSelectionProbe(this.status, {this.text});

  final WindowsUiaProbeStatus status;
  final String? text;
}

final class _UiaStatusException implements Exception {
  const _UiaStatusException(this.status);

  final WindowsUiaProbeStatus status;
}
