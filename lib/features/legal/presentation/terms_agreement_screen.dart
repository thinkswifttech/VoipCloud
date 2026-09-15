import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/route_names.dart';
import '../../../app/theme/app_theme.dart';
import '../../../shared/widgets/app_brand_icon.dart';
import '../../session/domain/service_account.dart';
import '../../session/presentation/session_controller.dart';
import '../data/terms_acceptance_repository.dart';

class TermsAgreementScreen extends ConsumerStatefulWidget {
  const TermsAgreementScreen({this.termsText, super.key});

  @visibleForTesting
  final String? termsText;

  @override
  ConsumerState<TermsAgreementScreen> createState() =>
      _TermsAgreementScreenState();
}

class _TermsAgreementScreenState extends ConsumerState<TermsAgreementScreen> {
  late final Future<String> _terms;
  bool _termsAvailable = false;
  bool _confirmed = false;
  bool _isSubmitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _terms = widget.termsText == null
        ? rootBundle.loadString(termsAgreementAsset)
        : Future<String>.value(widget.termsText);
    _terms.then((_) {
      if (mounted) setState(() => _termsAvailable = true);
    }, onError: (_) {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: isDark ? AppTheme.darkCanvas : Colors.white,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 920),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: constraints.maxWidth < 600 ? 20 : 40,
                      vertical: constraints.maxHeight < 700 ? 16 : 28,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Align(
                          alignment: Alignment.centerLeft,
                          child: AppBrandIcon(size: 54),
                        ),
                        const SizedBox(height: 18),
                        Text(
                          'Terms of Service',
                          style: theme.textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'ThinkSwift Master Services Agreement • '
                          'Version $termsAgreementVersion',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 18),
                        Expanded(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: isDark
                                  ? AppTheme.darkSurface
                                  : theme.colorScheme.surfaceContainerLowest,
                              border: Border.all(
                                color: theme.colorScheme.outlineVariant,
                              ),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: FutureBuilder<String>(
                              future: _terms,
                              builder: (context, snapshot) {
                                if (snapshot.hasError) {
                                  return const Center(
                                    child: Text(
                                      'The agreement could not be loaded.',
                                    ),
                                  );
                                }
                                if (!snapshot.hasData) {
                                  return const Center(
                                    child: CircularProgressIndicator(),
                                  );
                                }
                                return Scrollbar(
                                  child: SingleChildScrollView(
                                    primary: true,
                                    padding: const EdgeInsets.all(20),
                                    child: SelectableText(
                                      snapshot.data!,
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(height: 1.55),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        CheckboxListTile(
                          value: _confirmed,
                          onChanged: _isSubmitting || !_termsAvailable
                              ? null
                              : (value) =>
                                    setState(() => _confirmed = value ?? false),
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: const Text(
                            'I have read and agree to the Terms of Service.',
                          ),
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            _error!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.error,
                            ),
                          ),
                        ],
                        const SizedBox(height: 10),
                        Wrap(
                          alignment: WrapAlignment.end,
                          spacing: 12,
                          runSpacing: 10,
                          children: [
                            OutlinedButton(
                              onPressed: _isSubmitting ? null : _decline,
                              child: const Text('Decline and reset'),
                            ),
                            FilledButton(
                              onPressed:
                                  !_confirmed ||
                                      _isSubmitting ||
                                      !_termsAvailable
                                  ? null
                                  : _accept,
                              child: _isSubmitting
                                  ? const SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Text('Accept and continue'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Future<void> _accept() async {
    setState(() {
      _isSubmitting = true;
      _error = null;
    });
    try {
      await ref
          .read(sessionControllerProvider.notifier)
          .acceptProvisionedTerms();
      if (!mounted) return;
      final session = ref.read(sessionControllerProvider).value;
      final destination = session?.service.serviceStatus == ServiceStatus.active
          ? RoutePaths.dialer
          : RoutePaths.accountStatus;
      context.go(destination);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
        _error = 'Unable to complete activation. Please try again.';
      });
    }
  }

  Future<void> _decline() async {
    setState(() {
      _isSubmitting = true;
      _error = null;
    });
    try {
      await ref.read(sessionControllerProvider.notifier).revokeDeviceAndReset();
      if (mounted) context.go(RoutePaths.provisioning);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
        _error = 'Unable to reset the app. Please try again.';
      });
    }
  }
}
