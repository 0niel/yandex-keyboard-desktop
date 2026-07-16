import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

abstract interface class PosixFileModeGateway {
  Future<void> setMode(String path, int mode);
}

final class NativePosixFileModeGateway implements PosixFileModeGateway {
  const NativePosixFileModeGateway();

  static final int Function(Pointer<Utf8>, int) _chmod =
      DynamicLibrary.process().lookupFunction<
          Int32 Function(Pointer<Utf8>, Uint32),
          int Function(Pointer<Utf8>, int)>('chmod');

  @override
  Future<void> setMode(String path, int mode) async {
    if (!Platform.isLinux && !Platform.isMacOS) {
      throw UnsupportedError('POSIX file modes are unavailable.');
    }
    final nativePath = path.toNativeUtf8();
    try {
      if (_chmod(nativePath, mode) != 0) {
        throw FileSystemException(
          'Could not harden privacy data permissions.',
          path,
        );
      }
    } finally {
      malloc.free(nativePath);
    }
  }
}
