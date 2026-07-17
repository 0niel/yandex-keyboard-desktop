import 'package:flutter_test/flutter_test.dart';
import 'package:yandex_keyboard_desktop/src/features/text_assistant/presentation/overlay_presenter.dart';

void main() {
  test('show invokes an attached listener directly', () async {
    final presenter = OverlayPresenter();
    var shown = 0;
    var guarded = 0;
    presenter.attach(() => shown++);
    presenter.attachHostGuard(() async {
      guarded++;
      return true;
    });

    presenter.show();

    expect(shown, 1);
    expect(guarded, 0);
  });

  test('show restores the host surface before a detached listener', () async {
    final presenter = OverlayPresenter();
    var shown = 0;
    presenter.attachHostGuard(() async {
      presenter.attach(() => shown++);
      return true;
    });

    presenter.show();
    await pumpEventQueue();

    expect(shown, 1);
  });

  test('show stays quiet when the host surface refuses to switch', () async {
    final presenter = OverlayPresenter();
    var shown = 0;
    presenter.attachHostGuard(() async {
      presenter.attach(() => shown++);
      return false;
    });

    presenter.show();
    await pumpEventQueue();

    expect(shown, 0);
  });

  test('ensureHostSurface defaults to ready without a guard', () async {
    expect(await OverlayPresenter().ensureHostSurface(), isTrue);
  });

  test('detachHostGuard only removes the identical guard', () async {
    final presenter = OverlayPresenter();
    Future<bool> guard() async => false;
    presenter.attachHostGuard(guard);
    presenter.detachHostGuard(() async => true);

    expect(await presenter.ensureHostSurface(), isFalse);

    presenter.detachHostGuard(guard);

    expect(await presenter.ensureHostSurface(), isTrue);
  });

  test('detach accepts a fresh tear-off of the attached instance method',
      () async {
    // A disposed overlay State detaches with a new tear-off of the same
    // method; it must still clear the stored callback or hotkeys keep
    // invoking a defunct State (regression: settings left open broke the
    // overlay shortcut until the settings window was closed via its button).
    final presenter = OverlayPresenter();
    final host = _ShowHost();
    presenter.attach(host.show);
    presenter.detach(host.show);
    var restored = 0;
    presenter.attachHostGuard(() async {
      restored++;
      return true;
    });

    presenter.show();
    await pumpEventQueue();

    expect(host.shown, 0);
    expect(restored, 1);
  });

  test('detach ignores a callback from a different host', () async {
    final presenter = OverlayPresenter();
    final attached = _ShowHost();
    final other = _ShowHost();
    presenter.attach(attached.show);
    presenter.detach(other.show);

    presenter.show();

    expect(attached.shown, 1);
    expect(other.shown, 0);
  });
}

final class _ShowHost {
  var shown = 0;

  void show() => shown++;
}
