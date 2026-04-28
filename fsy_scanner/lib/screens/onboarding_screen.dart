import 'package:flutter/material.dart';

import '../app.dart';
import '../db/database_helper.dart';
import 'scan_screen.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _controller = PageController();
  int _currentPage = 0;

  final List<Map<String, dynamic>> _pages = [
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
        child: Column(
          children: [
            Expanded(
              child: PageView.builder(
                controller: _controller,
                onPageChanged: (index) => setState(() => _currentPage = index),
                itemCount: _pages.length,
                itemBuilder: (context, index) {
                  final page = _pages[index];
                  return Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(page['icon'] as IconData,
                            size: 120, color: FSYScannerApp.primaryBlue),
                        const SizedBox(height: 40),
                        Text(
                          page['title'] as String,
                          style: const TextStyle(
                              fontSize: 28, fontWeight: FontWeight.bold),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 20),
                        Text(
                          page['description'] as String,
                          style:
                              const TextStyle(fontSize: 18, color: Colors.grey),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(
                  _pages.length,
                  (index) => AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        width: _currentPage == index ? 24 : 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: _currentPage == index
                              ? FSYScannerApp.primaryBlue
                              : Colors.grey[300],
                          borderRadius: BorderRadius.circular(4),
                        ),
                      )),
            ),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Row(
                children: [
                  if (_currentPage > 0)
                    TextButton(
                      onPressed: () => _controller.previousPage(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeInOut),
                      child: const Text('Back'),
                    )
                  else
                    const Spacer(),
                  const Spacer(),
                  ElevatedButton(
                    onPressed: () {
                      if (_currentPage == _pages.length - 1) {
                        _completeOnboarding();
                      } else {
                        _controller.nextPage(
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.easeInOut);
                      }
                    },
                    child: Text(_currentPage == _pages.length - 1
                        ? 'Get Started'
                        : 'Next'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 30),
          ],
        ),
      ),
    );
  }
}
