import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/core/updates/desktop_update.dart';

class _Service implements DesktopUpdateService {
  _Service(this.answers);

  final List<Object> answers;
  int calls = 0;

  @override
  Future<DesktopUpdateResult> check() async {
    final answer = answers[calls < answers.length ? calls : answers.length - 1];
    calls++;
    if (answer is DesktopUpdateResult) return answer;
    throw answer;
  }
}

final _release = DesktopRelease(
  version: '1.0.1',
  build: 41,
  downloadUri: Uri.parse('https://updates.example.test/VoipCloud.msi'),
  sha256: 'a' * 64,
  releaseNotes: '',
);

void main() {
  late _Service service;

  Future<ProviderContainer> start(List<Object> answers) async {
    service = _Service(answers);
    final container = ProviderContainer(
      overrides: [desktopUpdateServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);
    container.listen(desktopUpdateProvider, (_, _) {});
    await container.read(desktopUpdateProvider.future);
    return container;
  }

  test('a release published while the app sat in the tray is found', () async {
    final container = await start([
      const DesktopUpdateResult.upToDate(),
      DesktopUpdateResult.available(_release),
    ]);
    expect(
      container.read(desktopUpdateProvider).value?.status,
      DesktopUpdateStatus.upToDate,
    );

    await container
        .read(desktopUpdateProvider.notifier)
        .refreshIfStale(maxAge: Duration.zero);

    expect(
      container.read(desktopUpdateProvider).value?.status,
      DesktopUpdateStatus.available,
    );
  });

  test('a recent check is not repeated every time the window opens', () async {
    final container = await start([const DesktopUpdateResult.upToDate()]);

    await container.read(desktopUpdateProvider.notifier).refreshIfStale();
    await container.read(desktopUpdateProvider.notifier).refreshIfStale();

    expect(service.calls, 1);
  });

  test('a failed re-check keeps what was already known', () async {
    final container = await start([
      DesktopUpdateResult.available(_release),
      Exception('offline'),
    ]);

    await container
        .read(desktopUpdateProvider.notifier)
        .refreshIfStale(maxAge: Duration.zero);

    final state = container.read(desktopUpdateProvider);
    expect(state.hasError, isFalse);
    expect(state.value?.status, DesktopUpdateStatus.available);
    expect(service.calls, 2);
  });

  test('the update badge does not flicker while re-checking', () async {
    final container = await start([
      DesktopUpdateResult.available(_release),
      DesktopUpdateResult.available(_release),
    ]);
    final seen = <bool>[];
    container.listen(desktopUpdateProvider, (_, next) {
      seen.add(next.isLoading);
    });

    await container
        .read(desktopUpdateProvider.notifier)
        .refreshIfStale(maxAge: Duration.zero);

    expect(seen, isNot(contains(true)));
  });
}
