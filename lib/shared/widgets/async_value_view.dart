import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class AsyncValueView<T> extends StatelessWidget {
  const AsyncValueView({required this.value, required this.data, super.key});

  final AsyncValue<T> value;
  final Widget Function(T value) data;

  @override
  Widget build(BuildContext context) {
    return value.when(
      data: data,
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stackTrace) => Center(
        child: Text(
          'Unable to load data.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
    );
  }
}
