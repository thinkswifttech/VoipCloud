import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/dialer/presentation/dialer_controller.dart';

void main() {
  test('backspace removes single characters or larger chunks', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(dialerControllerProvider.notifier);

    controller.append('1234567890');
    controller.backspace();
    expect(container.read(dialerControllerProvider), '123456789');

    controller.backspace(4);
    expect(container.read(dialerControllerProvider), '12345');

    controller.backspace(99);
    expect(container.read(dialerControllerProvider), isEmpty);
  });

  test('replaceRange inserts and replaces at the cursor', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(dialerControllerProvider.notifier);

    controller.append('15551212');
    expect(controller.replaceRange(4, 4, '9'), 5);
    expect(container.read(dialerControllerProvider), '155591212');

    expect(controller.replaceRange(3, 5, '7'), 4);
    expect(container.read(dialerControllerProvider), '15571212');
  });

  test('deleteBackward removes before the cursor or a selection', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(dialerControllerProvider.notifier);

    controller.append('15551212');
    expect(controller.deleteBackward(4), 3);
    expect(container.read(dialerControllerProvider), '1551212');

    expect(controller.deleteBackward(2, selectionEnd: 5), 2);
    expect(container.read(dialerControllerProvider), '1512');

    expect(controller.deleteBackward(0), 0);
    expect(container.read(dialerControllerProvider), '1512');
  });

  test('keyboard and pasted text is restricted to dial characters', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(dialerControllerProvider.notifier);

    controller.setDestination('+1 (416) 555-0123,45;6#');

    expect(container.read(dialerControllerProvider), '+14165550123,45;6#');
  });
}
