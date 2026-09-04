import 'sip_account.dart';

abstract class SipProvisioningRepository {
  Future<SipAccount?> getSipAccount();
}
