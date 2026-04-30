import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sqflite/sqflite.dart';

import '../app.dart';
import '../db/database_helper.dart';
import '../providers/app_state.dart';
import 'scan_screen.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with SingleTickerProviderStateMixin {
  final PageController _controller = PageController();
  int _currentPage = 0;
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;

  static const int _welcomePage = 0;
  static const int _totalPages = 4;

  final List<Map<String, dynamic>> _instructionPages = [
    {
      'title': 'Welcome to FSY Scanner',
      'description': 'Quickly check in participants by scanning their QR code.',
      'icon': Icons.qr_code_scanner,
    },
    {
      'title': 'Instant Feedback',
      'description':
          'A sound, vibration, and on‑screen card will confirm each check‑in.',
      'icon': Icons.notifications_active,
    },
    {
      'title': 'Ready to Go',
      'description':
          'The scanner works offline and syncs automatically when connected.',
      'icon': Icons.cloud_sync,
    },
  ];

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
    _fadeAnimation =
        CurvedAnimation(parent: _fadeController, curve: Curves.easeIn);
    _fadeController.forward();
  }

  @override
  void dispose() {
    _fadeController.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _completeOnboarding() async {
    final db = await DatabaseHelper.database;
    await db.insert(
      'app_settings',
      {'key': 'onboarding_complete', 'value': 'true'},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const ScanScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: Column(
            children: [
              Expanded(
                child: PageView.builder(
                  controller: _controller,
                  onPageChanged: (index) =>
                      setState(() => _currentPage = index),
                  itemCount: _totalPages,
                  itemBuilder: (context, index) {
                    if (index == _welcomePage) return _buildWelcomePage();
                    return _buildInstructionPage(index - 1);
                  },
                ),
              ),
              if (_currentPage > _welcomePage)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(
                    _instructionPages.length,
                    (index) => AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      width: _currentPage - 1 == index ? 24 : 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: _currentPage - 1 == index
                            ? FSYScannerApp.primaryBlue
                            : Colors.grey[300],
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
                child: Row(
                  children: [
                    if (_currentPage > _welcomePage &&
                        _currentPage < _totalPages - 1)
                      TextButton(
                        onPressed: () => _controller.previousPage(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeInOut,
                        ),
                        child: const Text('Back'),
                      )
                    else if (_currentPage == _welcomePage)
                      const Spacer(),
                    const Spacer(),
                    if (_currentPage == _welcomePage)
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: FSYScannerApp.accentGold,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 32, vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(30),
                          ),
                        ),
                        onPressed: () => _controller.animateToPage(
                          1,
                          duration: const Duration(milliseconds: 400),
                          curve: Curves.easeInOut,
                        ),
                        child: const Text('Get Started',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.bold)),
                      )
                    else if (_currentPage < _totalPages - 1)
                      ElevatedButton(
                        onPressed: () => _controller.nextPage(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeInOut,
                        ),
                        child: const Text('Next'),
                      )
                    else
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: FSYScannerApp.accentGreen,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 32, vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(30),
                          ),
                        ),
                        onPressed: _completeOnboarding,
                        child: const Text('Start Scanning',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.bold)),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWelcomePage() {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight - 48),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Image.asset('assets/fsy_logo.png', height: 200),
                const SizedBox(height: 24),
                const Text(
                  'Welcome!',
                  style: TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.bold,
                    color: FSYScannerApp.primaryBlue,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Your dedicated check‑in scanner\nfor ${context.watch<AppState>().eventName}.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 16,
                    color: Colors.grey,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 32),
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: FSYScannerApp.primaryBlue.withAlpha(25),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.lightbulb_outline,
                          color: FSYScannerApp.accentGold, size: 28),
                      SizedBox(width: 16),
                      Expanded(
                        child: Text(
                          'Tap "Get Started" to learn how the scanner works.',
                          style: TextStyle(fontSize: 14, height: 1.4),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildInstructionPage(int index) {
    final page = _instructionPages[index];
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight - 64),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Image.asset('assets/transparent_background_fsy_logo.png',
                    height: 40),
                const SizedBox(height: 40),
                Icon(page['icon'] as IconData,
                    size: 100, color: FSYScannerApp.primaryBlue),
                const SizedBox(height: 40),
                Text(
                  page['title'] as String,
                  style: const TextStyle(
                      fontSize: 26, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                Text(
                  page['description'] as String,
                  style: const TextStyle(
                      fontSize: 16, color: Colors.grey, height: 1.5),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
