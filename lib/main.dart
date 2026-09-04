import 'app/app.dart';
import 'app/bootstrap.dart';

Future<void> main(List<String> arguments) =>
    bootstrap(() => SoftphoneApp(commandLineArguments: arguments));
