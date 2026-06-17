import 'package:fastreminder/homepage.dart';

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:fastreminder/src/rust/api/simple.dart';
import 'package:fastreminder/src/rust/frb_generated.dart';
import 'package:path_provider/path_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );
  await RustLib.init(forceSameCodegenVersion: false);

  // Initialize DB path
  final appDocDir = await getApplicationDocumentsDirectory();
  final dbPath = "${appDocDir.path}/reminders.db";
  initDb(path: dbPath);

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Onyx',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF121318),
        canvasColor: const Color(0xFF121318),
        colorScheme: const ColorScheme.dark(
          surface: Color(0xFF121318),
          primary: Color(0xFFA8C7FA),
        ),
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: {
            TargetPlatform.android: CupertinoPageTransitionsBuilder(),
            TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          },
        ),
      ),
      home: const Homeapp(),
    );
  }
}
