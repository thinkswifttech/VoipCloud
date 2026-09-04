# Contributing

Use pull requests for all changes and keep every contribution safe for a
fully public repository.

Before committing:

- use reserved example domains and fictional people, companies, extensions,
  phone numbers, and tenant identifiers in tests and documentation;
- never include customer, employee, support-ticket, call, message, directory,
  or provisioning data;
- never include production or private service hostnames, IP addresses,
  deployment paths, network diagrams, operational runbooks, or configuration;
- never include credentials, tokens, signing certificates, provisioning
  profiles, Firebase configuration, `.env` files, crash dumps, or logs;
- verify generated files and image/document metadata before adding them; and
- run `flutter analyze` and `flutter test`.

Treat a secret committed to Git as compromised even if the commit is later
deleted. Revoke or rotate it immediately and follow the private reporting
process in [SECURITY.md](SECURITY.md).
