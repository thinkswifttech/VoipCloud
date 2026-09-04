import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';

abstract interface class MessagingConnectivity {
  Future<bool> hasNetwork();

  Stream<bool> get changes;

  Future<void> dispose();
}

class PlatformMessagingConnectivity
    with WidgetsBindingObserver
    implements MessagingConnectivity {
  PlatformMessagingConnectivity({Connectivity? connectivity})
    : _connectivity = connectivity ?? Connectivity() {
    WidgetsBinding.instance.addObserver(this);
    _subscription = _connectivity.onConnectivityChanged.listen(
      (results) => _controller.add(_hasNetwork(results)),
    );
  }

  final Connectivity _connectivity;
  final _controller = StreamController<bool>.broadcast();
  StreamSubscription<List<ConnectivityResult>>? _subscription;

  @override
  Future<bool> hasNetwork() async =>
      _hasNetwork(await _connectivity.checkConnectivity());

  @override
  Stream<bool> get changes => _controller.stream.distinct();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    unawaited(
      hasNetwork().then(_controller.add).catchError((_) {
        // A failed connectivity probe is not evidence that sending is safe.
      }),
    );
  }

  @override
  Future<void> dispose() async {
    WidgetsBinding.instance.removeObserver(this);
    await _subscription?.cancel();
    await _controller.close();
  }

  bool _hasNetwork(List<ConnectivityResult> results) =>
      results.any((result) => result != ConnectivityResult.none);
}
