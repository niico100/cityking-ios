import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CityKingApp());
}

class CityKingApp extends StatelessWidget {
  const CityKingApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'CityKing',
      debugShowCheckedModeBanner: false,
      home: CityKingWebView(),
    );
  }
}

class CityKingWebView extends StatefulWidget {
  const CityKingWebView({super.key});

  @override
  State<CityKingWebView> createState() => _CityKingWebViewState();
}

class _CityKingWebViewState extends State<CityKingWebView> {
  late final WebViewController _controller;
  var _loading = true;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFFFFFFF))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            if (mounted) {
              setState(() => _loading = false);
            }
          },
          onPageStarted: (_) {
            if (mounted) {
              setState(() => _loading = true);
            }
          },
        ),
      )
      ..loadRequest(Uri.parse('https://cityking.com/prague?source=ios'));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            WebViewWidget(controller: _controller),
            if (_loading)
              const LinearProgressIndicator(
                minHeight: 2,
                backgroundColor: Color(0xFFE5E7EB),
                color: Color(0xFF10233F),
              ),
          ],
        ),
      ),
    );
  }
}
