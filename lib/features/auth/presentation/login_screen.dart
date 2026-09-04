import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/route_names.dart';
import '../../../app/theme/app_theme.dart';
import '../../../shared/icons/app_icons.dart';
import '../../../shared/widgets/brand_mark.dart';
import 'auth_providers.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  late final AnimationController _introController;
  bool _obscurePassword = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _introController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 620),
    )..forward();
  }

  @override
  void dispose() {
    _introController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final isLoading = auth.isLoading;

    return Scaffold(
      body: _LoginExperience(
        animation: _introController,
        formKey: _formKey,
        emailController: _emailController,
        passwordController: _passwordController,
        error: _error,
        isLoading: isLoading,
        obscurePassword: _obscurePassword,
        onTogglePasswordVisibility: () {
          setState(() => _obscurePassword = !_obscurePassword);
        },
        onSubmit: _submit,
      ),
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() => _error = null);
    final failure = await ref
        .read(authControllerProvider.notifier)
        .login(
          email: _emailController.text,
          password: _passwordController.text,
        );

    if (!mounted) {
      return;
    }

    if (failure != null) {
      setState(() => _error = failure.userMessage);
      return;
    }

    context.go(RoutePaths.dialer);
  }
}

class _LoginExperience extends StatelessWidget {
  const _LoginExperience({
    required this.animation,
    required this.formKey,
    required this.emailController,
    required this.passwordController,
    required this.error,
    required this.isLoading,
    required this.obscurePassword,
    required this.onTogglePasswordVisibility,
    required this.onSubmit,
  });

  final Animation<double> animation;
  final GlobalKey<FormState> formKey;
  final TextEditingController emailController;
  final TextEditingController passwordController;
  final String? error;
  final bool isLoading;
  final bool obscurePassword;
  final VoidCallback onTogglePasswordVisibility;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Stack(
      children: [
        Positioned.fill(child: _LoginBackdrop(isDark: isDark)),
        SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth >= 820;
              final padding = EdgeInsets.all(isWide ? 28 : 20);
              final contentHeight = math.max(
                0.0,
                constraints.maxHeight - padding.vertical,
              );

              return SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: padding,
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: contentHeight),
                  child: isWide
                      ? SizedBox(
                          height: contentHeight,
                          child: Row(
                            children: [
                              Expanded(
                                flex: 11,
                                child: _Reveal(
                                  animation: animation,
                                  begin: 0.00,
                                  child: const _BrandPanel(),
                                ),
                              ),
                              const SizedBox(width: 24),
                              Expanded(
                                flex: 9,
                                child: Align(
                                  alignment: Alignment.center,
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 430,
                                    ),
                                    child: _Reveal(
                                      animation: animation,
                                      begin: 0.16,
                                      child: _SignInPanel(
                                        formKey: formKey,
                                        emailController: emailController,
                                        passwordController: passwordController,
                                        error: error,
                                        isLoading: isLoading,
                                        obscurePassword: obscurePassword,
                                        onTogglePasswordVisibility:
                                            onTogglePasswordVisibility,
                                        onSubmit: onSubmit,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(
                              height: math.max(300, contentHeight * 0.42),
                              child: _Reveal(
                                animation: animation,
                                begin: 0.00,
                                child: const _BrandPanel(compact: true),
                              ),
                            ),
                            const SizedBox(height: 18),
                            _Reveal(
                              animation: animation,
                              begin: 0.14,
                              child: _SignInPanel(
                                formKey: formKey,
                                emailController: emailController,
                                passwordController: passwordController,
                                error: error,
                                isLoading: isLoading,
                                obscurePassword: obscurePassword,
                                onTogglePasswordVisibility:
                                    onTogglePasswordVisibility,
                                onSubmit: onSubmit,
                              ),
                            ),
                          ],
                        ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _LoginBackdrop extends StatelessWidget {
  const _LoginBackdrop({required this.isDark});

  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? const [Color(0xFF080A0F), Color(0xFF121016), Color(0xFF080A0F)]
              : const [Color(0xFFFFFFFF), Color(0xFFF8F8F9), Color(0xFFFFF4F5)],
        ),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topRight,
            end: Alignment.bottomLeft,
            colors: [
              theme.colorScheme.primary.withValues(alpha: isDark ? 0.07 : 0.04),
              Colors.transparent,
              AppTheme.accentBlue.withValues(alpha: isDark ? 0.04 : 0.03),
            ],
          ),
        ),
      ),
    );
  }
}

class _BrandPanel extends StatelessWidget {
  const _BrandPanel({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDark
                ? const [
                    Color(0xFF151820),
                    Color(0xFF1A0D13),
                    Color(0xFF080A0F),
                  ]
                : const [
                    Color(0xFFFFFFFF),
                    Color(0xFFFFF3F4),
                    Color(0xFFF0F3FA),
                  ],
          ),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.08)
                : AppTheme.neutralGray.withValues(alpha: 0.42),
          ),
          boxShadow: [
            BoxShadow(
              color: AppTheme.swiftRed.withValues(alpha: isDark ? 0.16 : 0.10),
              blurRadius: 34,
              offset: const Offset(0, 18),
            ),
          ],
        ),
        child: Stack(
          children: [
            Positioned(
              right: compact ? -82 : -120,
              bottom: compact ? -104 : -138,
              child: Opacity(
                opacity: isDark ? 0.11 : 0.08,
                child: BrandMark(size: compact ? 310 : 520),
              ),
            ),
            Padding(
              padding: EdgeInsets.all(compact ? 22 : 34),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _BrandLockup(),
                  const Spacer(),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Business calling that feels ready before the first ring.',
                          style:
                              (compact
                                      ? theme.textTheme.headlineSmall
                                      : theme.textTheme.displaySmall)
                                  ?.copyWith(height: 1.04),
                        ),
                        SizedBox(height: compact ? 12 : 16),
                        Text(
                          'Secure account access, fast provisioning, and clean diagnostics for teams that need dependable voice workflows.',
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            height: 1.45,
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: compact ? 18 : 30),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: const [
                      _SignalChip(label: 'Encrypted setup'),
                      _SignalChip(label: 'VoIP ready'),
                      _SignalChip(label: 'Live diagnostics'),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BrandLockup extends StatelessWidget {
  const _BrandLockup();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        Container(
          width: 50,
          height: 50,
          decoration: BoxDecoration(
            color: theme.colorScheme.surface.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: theme.colorScheme.primary.withValues(alpha: 0.18),
            ),
          ),
          child: const Center(child: BrandMark(size: 32)),
        ),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [Text('VoipCloud', style: theme.textTheme.titleMedium)],
        ),
      ],
    );
  }
}

class _SignalChip extends StatelessWidget {
  const _SignalChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(
          alpha: theme.brightness == Brightness.dark ? 0.30 : 0.72,
        ),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.78),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: const BoxDecoration(
                color: AppTheme.swiftRed,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Text(label, style: theme.textTheme.labelMedium),
          ],
        ),
      ),
    );
  }
}

class _SignInPanel extends StatelessWidget {
  const _SignInPanel({
    required this.formKey,
    required this.emailController,
    required this.passwordController,
    required this.error,
    required this.isLoading,
    required this.obscurePassword,
    required this.onTogglePasswordVisibility,
    required this.onSubmit,
  });

  final GlobalKey<FormState> formKey;
  final TextEditingController emailController;
  final TextEditingController passwordController;
  final String? error;
  final bool isLoading;
  final bool obscurePassword;
  final VoidCallback onTogglePasswordVisibility;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(
          alpha: isDark ? 0.88 : 0.96,
        ),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : theme.colorScheme.outline,
        ),
        boxShadow: [
          BoxShadow(
            color: AppTheme.brandBlack.withValues(alpha: isDark ? 0.22 : 0.08),
            blurRadius: 32,
            offset: const Offset(0, 20),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Form(
          key: formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Welcome back', style: theme.textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(
                'Access your calling workspace securely.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              TextFormField(
                controller: emailController,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.email],
                enabled: !isLoading,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  prefixIcon: Icon(AppIcons.email),
                ),
                validator: (value) => value == null || value.trim().isEmpty
                    ? 'Email is required'
                    : null,
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: passwordController,
                obscureText: obscurePassword,
                textInputAction: TextInputAction.done,
                autofillHints: const [AutofillHints.password],
                enabled: !isLoading,
                decoration: InputDecoration(
                  labelText: 'Password',
                  prefixIcon: const Icon(AppIcons.password),
                  suffixIcon: IconButton(
                    tooltip: obscurePassword
                        ? 'Show password'
                        : 'Hide password',
                    onPressed: isLoading ? null : onTogglePasswordVisibility,
                    icon: Icon(
                      obscurePassword
                          ? AppIcons.passwordVisible
                          : AppIcons.passwordHidden,
                    ),
                  ),
                ),
                validator: (value) => value == null || value.isEmpty
                    ? 'Password is required'
                    : null,
                onFieldSubmitted: (_) => onSubmit(),
              ),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                child: error == null
                    ? const SizedBox.shrink()
                    : Padding(
                        key: ValueKey(error),
                        padding: const EdgeInsets.only(top: 14),
                        child: _LoginError(message: error!),
                      ),
              ),
              const SizedBox(height: 22),
              FilledButton.icon(
                onPressed: isLoading ? null : onSubmit,
                icon: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 160),
                  child: isLoading
                      ? const SizedBox(
                          key: ValueKey('loading'),
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(AppIcons.login, key: ValueKey('login')),
                ),
                label: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 160),
                  child: Text(
                    isLoading ? 'Signing in' : 'Sign in',
                    key: ValueKey(isLoading),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Need access? Contact your workspace administrator.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LoginError extends StatelessWidget {
  const _LoginError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.error.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.error.withValues(alpha: 0.18),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(AppIcons.warning, color: theme.colorScheme.error, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Reveal extends StatelessWidget {
  const _Reveal({
    required this.animation,
    required this.begin,
    required this.child,
  });

  final Animation<double> animation;
  final double begin;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Interval(begin, 1, curve: Curves.easeOutCubic),
    );

    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.035),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}
