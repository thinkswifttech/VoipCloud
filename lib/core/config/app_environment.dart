enum AppEnvironment {
  development,
  staging,
  production;

  static AppEnvironment parse(String value) {
    return switch (value.trim().toLowerCase()) {
      'staging' => AppEnvironment.staging,
      'production' || 'prod' => AppEnvironment.production,
      _ => AppEnvironment.development,
    };
  }
}
