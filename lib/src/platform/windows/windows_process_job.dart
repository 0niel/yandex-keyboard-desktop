import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

const _jobObjectExtendedLimitInformation = 9;
const _jobObjectLimitKillOnJobClose = 0x00002000;
const _processTerminate = 0x0001;
const _processSetQuota = 0x0100;

final class WindowsProcessJob {
  WindowsProcessJob._(this._handle);

  int _handle;

  static WindowsProcessJob attach(int processId) {
    if (!Platform.isWindows || processId <= 0) {
      throw ArgumentError.value(processId, 'processId');
    }

    final information = calloc<_JobObjectExtendedLimitInformation>();
    var jobHandle = 0;
    var processHandle = 0;
    var attached = false;
    try {
      jobHandle = CreateJobObject(nullptr, nullptr);
      if (jobHandle == 0) {
        throw WindowsException(HRESULT_FROM_WIN32(GetLastError()));
      }
      information.ref.basicLimitInformation.limitFlags =
          _jobObjectLimitKillOnJobClose;
      if (SetInformationJobObject(
            jobHandle,
            _jobObjectExtendedLimitInformation,
            information.cast(),
            sizeOf<_JobObjectExtendedLimitInformation>(),
          ) ==
          0) {
        throw WindowsException(HRESULT_FROM_WIN32(GetLastError()));
      }

      processHandle = OpenProcess(
        _processTerminate | _processSetQuota,
        FALSE,
        processId,
      );
      if (processHandle == 0) {
        throw WindowsException(HRESULT_FROM_WIN32(GetLastError()));
      }
      if (AssignProcessToJobObject(jobHandle, processHandle) == 0) {
        throw WindowsException(HRESULT_FROM_WIN32(GetLastError()));
      }

      attached = true;
      return WindowsProcessJob._(jobHandle);
    } finally {
      if (processHandle != 0) CloseHandle(processHandle);
      if (jobHandle != 0 && !attached) CloseHandle(jobHandle);
      calloc.free(information);
    }
  }

  void close() {
    final handle = _handle;
    if (handle == 0) return;
    _handle = 0;
    CloseHandle(handle);
  }
}

final class _JobObjectBasicLimitInformation extends Struct {
  @Int64()
  external int perProcessUserTimeLimit;

  @Int64()
  external int perJobUserTimeLimit;

  @Uint32()
  external int limitFlags;

  @UintPtr()
  external int minimumWorkingSetSize;

  @UintPtr()
  external int maximumWorkingSetSize;

  @Uint32()
  external int activeProcessLimit;

  @UintPtr()
  external int affinity;

  @Uint32()
  external int priorityClass;

  @Uint32()
  external int schedulingClass;
}

final class _IoCounters extends Struct {
  @Uint64()
  external int readOperationCount;

  @Uint64()
  external int writeOperationCount;

  @Uint64()
  external int otherOperationCount;

  @Uint64()
  external int readTransferCount;

  @Uint64()
  external int writeTransferCount;

  @Uint64()
  external int otherTransferCount;
}

final class _JobObjectExtendedLimitInformation extends Struct {
  external _JobObjectBasicLimitInformation basicLimitInformation;

  external _IoCounters ioInfo;

  @UintPtr()
  external int processMemoryLimit;

  @UintPtr()
  external int jobMemoryLimit;

  @UintPtr()
  external int peakProcessMemoryUsed;

  @UintPtr()
  external int peakJobMemoryUsed;
}
