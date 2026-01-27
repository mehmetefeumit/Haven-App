import 'package:flutter/material.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const HavenApp());
}

class HavenApp extends StatelessWidget {
  const HavenApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Haven',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool? _isInitialized;

  @override
  void initState() {
    super.initState();
    _checkRustCore();
  }

  Future<void> _checkRustCore() async {
    try {
      final core = await HavenCore.newInstance();
      final initialized = core.isInitialized();
      if (mounted) {
        setState(() {
          _isInitialized = initialized;
        });
      }
    } catch (e) {
      debugPrint('Error initializing Rust core: $e');
      if (mounted) {
        setState(() {
          _isInitialized = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Haven'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('Welcome to Haven'),
            const SizedBox(height: 16),
            Text(
              'Rust Core: ${_isInitialized == null
                  ? 'Loading...'
                  : _isInitialized!
                  ? 'Initialized'
                  : 'Not initialized'}',
            ),
          ],
        ),
      ),
    );
  }
}
