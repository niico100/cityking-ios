import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CityKingApp());
}

const _siteOrigin = 'https://cityking.com';
const _sourceParam = 'source=ios';
const _savedListingsKey = 'saved_listings_v1';
const _selectedCityKey = 'selected_city_v1';

const _cities = <CityOption>[
  CityOption('Prague', '/prague'),
  CityOption('London', '/london'),
  CityOption('Manchester', '/manchester'),
];

class CityOption {
  const CityOption(this.name, this.path);

  final String name;
  final String path;
}

class SavedListing {
  const SavedListing({
    required this.title,
    required this.url,
    required this.savedAt,
  });

  final String title;
  final String url;
  final DateTime savedAt;

  String get id => Uri.parse(url).removeFragment().toString();

  Map<String, Object> toJson() => {
    'title': title,
    'url': url,
    'savedAt': savedAt.toIso8601String(),
  };

  static SavedListing? fromJson(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final title = raw['title']?.toString().trim() ?? '';
    final url = raw['url']?.toString().trim() ?? '';
    final savedAt = DateTime.tryParse(raw['savedAt']?.toString() ?? '');
    if (title.isEmpty || url.isEmpty || savedAt == null) {
      return null;
    }
    return SavedListing(title: title, url: url, savedAt: savedAt);
  }
}

class CityKingApp extends StatelessWidget {
  const CityKingApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CityKing',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFE11D48),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: const CityKingHome(),
    );
  }
}

class CityKingHome extends StatefulWidget {
  const CityKingHome({super.key});

  @override
  State<CityKingHome> createState() => _CityKingHomeState();
}

class _CityKingHomeState extends State<CityKingHome> {
  late final WebViewController _controller;
  var _loading = true;
  var _currentIndex = 0;
  var _selectedCity = _cities.first;
  Uri? _currentUri;
  List<SavedListing> _savedListings = const [];

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFFFFFFF))
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: _handleNavigationRequest,
          onPageFinished: (url) {
            if (mounted) {
              setState(() {
                _loading = false;
                _currentUri = Uri.tryParse(url);
              });
            }
          },
          onPageStarted: (url) {
            if (mounted) {
              setState(() {
                _loading = true;
                _currentUri = Uri.tryParse(url);
              });
            }
          },
        ),
      );
    _loadLocalState();
  }

  Future<void> _loadLocalState() async {
    final prefs = await SharedPreferences.getInstance();
    final savedCityPath = prefs.getString(_selectedCityKey);
    final city = _cities.firstWhere(
      (candidate) => candidate.path == savedCityPath,
      orElse: () => _cities.first,
    );
    final saved = _decodeSavedListings(prefs.getStringList(_savedListingsKey));
    if (!mounted) {
      return;
    }
    setState(() {
      _selectedCity = city;
      _savedListings = saved;
    });
    await _loadCity(city);
  }

  List<SavedListing> _decodeSavedListings(List<String>? rawItems) {
    final decoded = <SavedListing>[];
    for (final item in rawItems ?? const <String>[]) {
      try {
        final listing = SavedListing.fromJson(jsonDecode(item));
        if (listing != null) {
          decoded.add(listing);
        }
      } catch (_) {
        // Ignore corrupt local rows; saved listings are convenience data.
      }
    }
    decoded.sort((a, b) => b.savedAt.compareTo(a.savedAt));
    return decoded;
  }

  Future<void> _persistSavedListings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _savedListingsKey,
      _savedListings.map((listing) => jsonEncode(listing.toJson())).toList(),
    );
  }

  Future<void> _loadCity(CityOption city) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_selectedCityKey, city.path);
    final separator = city.path.contains('?') ? '&' : '?';
    await _controller.loadRequest(
      Uri.parse('$_siteOrigin${city.path}$separator$_sourceParam'),
    );
  }

  Future<NavigationDecision> _handleNavigationRequest(
    NavigationRequest request,
  ) async {
    final uri = Uri.tryParse(request.url);
    if (uri == null) {
      return NavigationDecision.prevent;
    }
    if (_shouldStayInApp(uri)) {
      return NavigationDecision.navigate;
    }
    await _openExternal(uri);
    return NavigationDecision.prevent;
  }

  bool _shouldStayInApp(Uri uri) {
    if (uri.scheme != 'https' && uri.scheme != 'http') {
      return false;
    }
    final host = uri.host.toLowerCase();
    return host == 'cityking.com' || host.endsWith('.cityking.com');
  }

  Future<void> _openExternal(Uri uri) async {
    final mode = LaunchMode.externalApplication;
    final opened = await launchUrl(uri, mode: mode);
    if (!opened && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not open link')));
    }
  }

  Future<void> _saveCurrentPage() async {
    final url = await _controller.currentUrl();
    final uri = Uri.tryParse(url ?? '');
    if (uri == null || !_shouldStayInApp(uri)) {
      return;
    }
    final title = (await _controller.getTitle())?.trim();
    final fallbackTitle = _selectedCity.name;
    final listing = SavedListing(
      title: (title == null || title.isEmpty) ? fallbackTitle : title,
      url: uri.toString(),
      savedAt: DateTime.now(),
    );
    setState(() {
      _savedListings = [
        listing,
        ..._savedListings.where((item) => item.id != listing.id),
      ];
    });
    await _persistSavedListings();
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Saved')));
    }
  }

  Future<void> _removeSavedListing(SavedListing listing) async {
    setState(() {
      _savedListings = [
        for (final item in _savedListings)
          if (item.id != listing.id) item,
      ];
    });
    await _persistSavedListings();
  }

  Future<void> _openSavedListing(SavedListing listing) async {
    setState(() => _currentIndex = 0);
    await _controller.loadRequest(Uri.parse(listing.url));
  }

  bool get _isCurrentPageSaved {
    final current = _currentUri?.removeFragment().toString();
    if (current == null) {
      return false;
    }
    return _savedListings.any((listing) => listing.id == current);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 12,
        title: Row(
          children: [
            const Text(
              'CityKing',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(width: 12),
            DropdownButtonHideUnderline(
              child: DropdownButton<CityOption>(
                value: _selectedCity,
                borderRadius: BorderRadius.circular(12),
                items: [
                  for (final city in _cities)
                    DropdownMenuItem(value: city, child: Text(city.name)),
                ],
                onChanged: (city) async {
                  if (city == null) {
                    return;
                  }
                  setState(() {
                    _selectedCity = city;
                    _currentIndex = 0;
                  });
                  await _loadCity(city);
                },
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Back',
            icon: const Icon(Icons.arrow_back),
            onPressed: () async {
              if (await _controller.canGoBack()) {
                await _controller.goBack();
              }
            },
          ),
          IconButton(
            tooltip: _isCurrentPageSaved ? 'Saved' : 'Save',
            icon: Icon(
              _isCurrentPageSaved ? Icons.bookmark : Icons.bookmark_border,
            ),
            onPressed: _saveCurrentPage,
          ),
          IconButton(
            tooltip: 'Open in Safari',
            icon: const Icon(Icons.open_in_new),
            onPressed: () async {
              final url = await _controller.currentUrl();
              final uri = Uri.tryParse(url ?? '');
              if (uri != null) {
                await _openExternal(uri);
              }
            },
          ),
        ],
      ),
      body: IndexedStack(
        index: _currentIndex,
        children: [
          SafeArea(
            bottom: false,
            child: Stack(
              children: [
                WebViewWidget(controller: _controller),
                if (_loading)
                  const LinearProgressIndicator(
                    minHeight: 2,
                    backgroundColor: Color(0xFFE5E7EB),
                    color: Color(0xFFE11D48),
                  ),
              ],
            ),
          ),
          SavedListingsView(
            listings: _savedListings,
            onOpen: _openSavedListing,
            onRemove: _removeSavedListing,
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) => setState(() => _currentIndex = index),
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.explore_outlined),
            selectedIcon: Icon(Icons.explore),
            label: 'Explore',
          ),
          NavigationDestination(
            icon: const Icon(Icons.bookmarks_outlined),
            selectedIcon: const Icon(Icons.bookmarks),
            label: 'Saved (${_savedListings.length})',
          ),
        ],
      ),
    );
  }
}

class SavedListingsView extends StatelessWidget {
  const SavedListingsView({
    required this.listings,
    required this.onOpen,
    required this.onRemove,
    super.key,
  });

  final List<SavedListing> listings;
  final ValueChanged<SavedListing> onOpen;
  final ValueChanged<SavedListing> onRemove;

  @override
  Widget build(BuildContext context) {
    if (listings.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.bookmark_add_outlined, size: 46),
              SizedBox(height: 14),
              Text(
                'Save events and places',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
              SizedBox(height: 8),
              Text(
                'Use the bookmark button while browsing to keep listings on this iPhone.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    return SafeArea(
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
        itemBuilder: (context, index) {
          final listing = listings[index];
          return Dismissible(
            key: ValueKey(listing.id),
            direction: DismissDirection.endToStart,
            background: Container(
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.symmetric(horizontal: 18),
              decoration: BoxDecoration(
                color: const Color(0xFFDC2626),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.delete, color: Colors.white),
            ),
            onDismissed: (_) => onRemove(listing),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              leading: const CircleAvatar(child: Icon(Icons.bookmark)),
              title: Text(
                listing.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                Uri.parse(listing.url).path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: IconButton(
                tooltip: 'Remove',
                icon: const Icon(Icons.close),
                onPressed: () => onRemove(listing),
              ),
              onTap: () => onOpen(listing),
            ),
          );
        },
        separatorBuilder: (context, index) => const Divider(height: 1),
        itemCount: listings.length,
      ),
    );
  }
}
