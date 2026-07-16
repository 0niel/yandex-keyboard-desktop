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
}
