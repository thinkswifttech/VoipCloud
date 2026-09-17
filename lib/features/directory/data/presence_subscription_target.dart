final RegExp _sipNumericPresenceTarget = RegExp(r'^\+?\d{2,15}$');

/// Returns whether a company-directory number is suitable for a SIP BLF
/// subscription.
///
/// Fifteen digits covers full E.164-style PBX identities in addition to short
/// extensions. The caller remains responsible for excluding external contacts.
bool isPresenceSubscriptionTarget(String number) =>
    _sipNumericPresenceTarget.hasMatch(number.trim());
