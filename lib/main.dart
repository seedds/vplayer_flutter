import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'providers/app_providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  final documentsDir = await getApplicationDocumentsDirectory();

  runApp(
    ProviderScope(
      overrides: [
        documentsPathProvider.overrideWithValue(documentsDir.path),
      ],
      child: const VPlayerApp(),
    ),
  );
}
