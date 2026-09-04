enum SipTransport {
  udp,
  tcp,
  tls;

  static SipTransport parse(String value) {
    return switch (value.trim().toLowerCase()) {
      'tcp' => SipTransport.tcp,
      'tls' || 'sips' => SipTransport.tls,
      _ => SipTransport.udp,
    };
  }
}
