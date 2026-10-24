import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'firebase_options.dart';
import 'screens/home_screen.dart';
import 'services/shop_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    final auth = FirebaseAuth.instance;
    // Every phone gets its own private shop without a login screen.
    final user = auth.currentUser ?? (await auth.signInAnonymously()).user;
    if (user == null) throw StateError('Sign-in did not return a user.');
    runApp(BayanApp(repository: ShopRepository(user.uid)));
  } catch (error) {
    runApp(SetupErrorApp(error: error.toString()));
  }
}

ThemeData _theme() => ThemeData(
      useMaterial3: true,
      colorSchemeSeed: const Color(0xFF1B7F4B),
    );

class BayanApp extends StatelessWidget {
  const BayanApp({super.key, required this.repository});

  final ShopRepository repository;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BayanAI',
      debugShowCheckedModeBanner: false,
      theme: _theme(),
      home: HomeScreen(repository: repository),
    );
  }
}

/// Shown instead of a crash when Firebase is not set up yet.
class SetupErrorApp extends StatelessWidget {
  const SetupErrorApp({super.key, required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _theme(),
      home: Scaffold(
        appBar: AppBar(title: const Text('BayanAI setup')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'The app could not start Firebase.',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                const Text(
                  '1. Run `flutterfire configure` in the flutter_app folder.\n'
                  '2. In the Firebase console, turn on Authentication > '
                  'Anonymous and create a Firestore database.\n'
                  '3. Restart the app.',
                ),
                const SizedBox(height: 16),
                const Text('Details:'),
                SelectableText(error),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
