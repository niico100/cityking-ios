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
const _privacyPolicyUrl = 'https://neonshard.com/policies/privacypolicy.txt';
const _savedListingsKey = 'saved_listings_v1';
const _selectedCityKey = 'selected_city_v1';
const _plannedListingIdsKey = 'planned_listing_ids_v1';
const _completedListingIdsKey = 'completed_listing_ids_v1';
const _tripNotesKey = 'trip_notes_v1';

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
    this.imageUrl,
    this.startsAt,
  });

  final String title;
  final String url;
  final DateTime savedAt;
  final String? imageUrl;
  final DateTime? startsAt;

  String get id => Uri.parse(url).removeFragment().toString();

  Map<String, Object> toJson() => {
    'title': title,
    'url': url,
    'savedAt': savedAt.toIso8601String(),
    if (imageUrl != null && imageUrl!.isNotEmpty) 'imageUrl': imageUrl!,
    if (startsAt != null) 'startsAt': startsAt!.toIso8601String(),
  };

  static SavedListing? fromJson(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final title = raw['title']?.toString().trim() ?? '';
    final url = raw['url']?.toString().trim() ?? '';
    final savedAt = DateTime.tryParse(raw['savedAt']?.toString() ?? '');
    final imageUrl = raw['imageUrl']?.toString().trim();
    final startsAt = DateTime.tryParse(raw['startsAt']?.toString() ?? '');
    if (title.isEmpty || url.isEmpty || savedAt == null) {
      return null;
    }
    return SavedListing(
      title: title,
      url: url,
      savedAt: savedAt,
      imageUrl: imageUrl == null || imageUrl.isEmpty ? null : imageUrl,
      startsAt: startsAt,
    );
  }
}

class _ListingMetadata {
  const _ListingMetadata({this.title, this.imageUrl, this.startsAt});

  final String? title;
  final String? imageUrl;
  final DateTime? startsAt;
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
  String? _loadError;
  var _currentIndex = 0;
  var _selectedCity = _cities.first;
  Uri? _currentUri;
  List<SavedListing> _savedListings = const [];
  Set<String> _plannedListingIds = const {};
  Set<String> _completedListingIds = const {};
  var _tripNotes = '';

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFFFFFFF))
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: _handleNavigationRequest,
          onWebResourceError: (error) {
            if (error.isForMainFrame == false || !mounted) {
              return;
            }
            setState(() {
              _loading = false;
              _loadError = error.description.isEmpty
                  ? 'The city guide could not be loaded.'
                  : error.description;
            });
          },
          onPageFinished: (url) {
            if (mounted) {
              setState(() {
                _loading = false;
                _loadError = null;
                _currentUri = Uri.tryParse(url);
              });
            }
          },
          onPageStarted: (url) {
            if (mounted) {
              setState(() {
                _loading = true;
                _loadError = null;
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
    final savedIds = saved.map((listing) => listing.id).toSet();
    final plannedIds =
        (prefs.getStringList(_plannedListingIdsKey) ?? const <String>[])
            .where(savedIds.contains)
            .toSet();
    final completedIds =
        (prefs.getStringList(_completedListingIdsKey) ?? const <String>[])
            .where(savedIds.contains)
            .toSet();
    if (!mounted) {
      return;
    }
    setState(() {
      _selectedCity = city;
      _savedListings = saved;
      _plannedListingIds = plannedIds;
      _completedListingIds = completedIds;
      _tripNotes = prefs.getString(_tripNotesKey) ?? '';
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

  Future<void> _persistPlannerState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _plannedListingIdsKey,
      _plannedListingIds.toList(),
    );
    await prefs.setStringList(
      _completedListingIdsKey,
      _completedListingIds.toList(),
    );
    await prefs.setString(_tripNotesKey, _tripNotes);
  }

  Future<void> _loadCity(CityOption city) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_selectedCityKey, city.path);
    final separator = city.path.contains('?') ? '&' : '?';
    await _controller.loadRequest(
      Uri.parse('$_siteOrigin${city.path}$separator$_sourceParam'),
    );
  }

  Future<void> _reloadCurrentPage() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    final url = await _controller.currentUrl();
    final uri = Uri.tryParse(url ?? '');
    if (uri != null && _shouldStayInApp(uri)) {
      await _controller.reload();
      return;
    }
    await _loadCity(_selectedCity);
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
    final metadata = await _readCurrentListingMetadata();
    final fallbackTitle = _selectedCity.name;
    final listing = SavedListing(
      title:
          metadata.title ??
          ((title == null || title.isEmpty) ? fallbackTitle : title),
      url: uri.toString(),
      savedAt: DateTime.now(),
      imageUrl: metadata.imageUrl,
      startsAt: metadata.startsAt,
    );
    setState(() {
      _savedListings = [
        listing,
        ..._savedListings.where((item) => item.id != listing.id),
      ];
      _plannedListingIds = {..._plannedListingIds, listing.id};
    });
    await _persistSavedListings();
    await _persistPlannerState();
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Saved')));
    }
  }

  Future<_ListingMetadata> _readCurrentListingMetadata() async {
    try {
      final raw = await _controller.runJavaScriptReturningResult('''
        JSON.stringify({
          title: document.querySelector('meta[property="og:title"]')?.content
            || document.querySelector('h1')?.textContent
            || document.title
            || null,
          imageUrl: document.querySelector('meta[property="og:image"]')?.content
            || document.querySelector('article img')?.src
            || document.querySelector('img')?.src
            || null,
          startsAt: document.querySelector('time[datetime]')?.getAttribute('datetime')
            || document.querySelector('[data-starts-at]')?.getAttribute('data-starts-at')
            || null
        })
      ''');
      final payload = raw is String ? jsonDecode(raw) : raw;
      if (payload is! Map) {
        return const _ListingMetadata();
      }
      final title = payload['title']?.toString().trim();
      final imageUrl = payload['imageUrl']?.toString().trim();
      return _ListingMetadata(
        title: title == null || title.isEmpty ? null : title,
        imageUrl: imageUrl == null || imageUrl.isEmpty ? null : imageUrl,
        startsAt: DateTime.tryParse(payload['startsAt']?.toString() ?? ''),
      );
    } catch (_) {
      return const _ListingMetadata();
    }
  }

  Future<void> _removeSavedListing(SavedListing listing) async {
    setState(() {
      _savedListings = [
        for (final item in _savedListings)
          if (item.id != listing.id) item,
      ];
      _plannedListingIds = {..._plannedListingIds}..remove(listing.id);
      _completedListingIds = {..._completedListingIds}..remove(listing.id);
    });
    await _persistSavedListings();
    await _persistPlannerState();
  }

  Future<void> _openSavedListing(SavedListing listing) async {
    setState(() => _currentIndex = 0);
    await _controller.loadRequest(Uri.parse(listing.url));
  }

  Future<void> _togglePlannedListing(SavedListing listing, bool planned) async {
    setState(() {
      final plannedIds = {..._plannedListingIds};
      final completedIds = {..._completedListingIds};
      if (planned) {
        plannedIds.add(listing.id);
      } else {
        plannedIds.remove(listing.id);
        completedIds.remove(listing.id);
      }
      _plannedListingIds = plannedIds;
      _completedListingIds = completedIds;
    });
    await _persistPlannerState();
  }

  Future<void> _toggleCompletedListing(
    SavedListing listing,
    bool completed,
  ) async {
    setState(() {
      final plannedIds = {..._plannedListingIds, listing.id};
      final completedIds = {..._completedListingIds};
      if (completed) {
        completedIds.add(listing.id);
      } else {
        completedIds.remove(listing.id);
      }
      _plannedListingIds = plannedIds;
      _completedListingIds = completedIds;
    });
    await _persistPlannerState();
  }

  Future<void> _updateTripNotes(String notes) async {
    setState(() => _tripNotes = notes);
    await _persistPlannerState();
  }

  Future<void> _showAboutSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Prague Today',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Browse current city listings, save events and places on this device, and build a native day plan with checklist status and trip notes.',
                ),
                const SizedBox(height: 16),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.privacy_tip_outlined),
                  title: const Text('Privacy policy'),
                  subtitle: const Text(_privacyPolicyUrl),
                  onTap: () => _openExternal(Uri.parse(_privacyPolicyUrl)),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.support_agent_outlined),
                  title: const Text('Support'),
                  subtitle: const Text(
                    'Use the privacy link for support and policy information.',
                  ),
                  onTap: () => _openExternal(Uri.parse(_privacyPolicyUrl)),
                ),
              ],
            ),
          ),
        );
      },
    );
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
        automaticallyImplyLeading: false,
        titleSpacing: 0,
        title: Row(
          children: [
            IconButton(
              tooltip: 'Back',
              icon: const Icon(Icons.arrow_back),
              onPressed: () async {
                if (await _controller.canGoBack()) {
                  await _controller.goBack();
                }
              },
            ),
            const Text(
              'Prague Today',
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
          IconButton(
            tooltip: 'About and privacy',
            icon: const Icon(Icons.info_outline),
            onPressed: _showAboutSheet,
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
                if (_loadError != null)
                  _LoadErrorView(
                    message: _loadError!,
                    onRetry: _reloadCurrentPage,
                  ),
                if (!_loading && _loadError == null && _savedListings.isEmpty)
                  _NativePlanHint(onSave: _saveCurrentPage),
              ],
            ),
          ),
          SavedListingsView(
            listings: _savedListings,
            onOpen: _openSavedListing,
            onRemove: _removeSavedListing,
            plannedListingIds: _plannedListingIds,
            onPlanChanged: _togglePlannedListing,
          ),
          PlannerView(
            listings: _savedListings,
            plannedListingIds: _plannedListingIds,
            completedListingIds: _completedListingIds,
            tripNotes: _tripNotes,
            onOpen: _openSavedListing,
            onPlannedChanged: _togglePlannedListing,
            onCompletedChanged: _toggleCompletedListing,
            onNotesChanged: _updateTripNotes,
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
          NavigationDestination(
            icon: const Icon(Icons.checklist_outlined),
            selectedIcon: const Icon(Icons.checklist),
            label: 'Plan',
          ),
        ],
      ),
    );
  }
}

class _LoadErrorView extends StatelessWidget {
  const _LoadErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.white,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.wifi_off_outlined, size: 46),
                const SizedBox(height: 14),
                const Text(
                  'City guide unavailable',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Try again'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NativePlanHint extends StatelessWidget {
  const _NativePlanHint({required this.onSave});

  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 14,
      right: 14,
      bottom: 14,
      child: Material(
        elevation: 8,
        shadowColor: Colors.black26,
        borderRadius: BorderRadius.circular(16),
        color: Colors.white,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          child: Row(
            children: [
              const Icon(Icons.bookmark_add_outlined, color: Color(0xFFE11D48)),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Save a listing to build a native day plan.',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton(
                onPressed: onSave,
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SavedListingsView extends StatefulWidget {
  const SavedListingsView({
    required this.listings,
    required this.onOpen,
    required this.onRemove,
    required this.plannedListingIds,
    required this.onPlanChanged,
    super.key,
  });

  final List<SavedListing> listings;
  final ValueChanged<SavedListing> onOpen;
  final ValueChanged<SavedListing> onRemove;
  final Set<String> plannedListingIds;
  final void Function(SavedListing listing, bool planned) onPlanChanged;

  @override
  State<SavedListingsView> createState() => _SavedListingsViewState();
}

class _SavedListingsViewState extends State<SavedListingsView> {
  var _showPast = false;

  @override
  Widget build(BuildContext context) {
    if (widget.listings.isEmpty) {
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
    final now = DateTime.now();
    final futureListings = widget.listings
        .where(
          (listing) =>
              listing.startsAt == null || !listing.startsAt!.isBefore(now),
        )
        .toList();
    final pastListings = widget.listings
        .where(
          (listing) =>
              listing.startsAt != null && listing.startsAt!.isBefore(now),
        )
        .toList();
    final visibleListings = _showPast ? pastListings : futureListings;

    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: SegmentedButton<bool>(
              segments: [
                ButtonSegment(
                  value: false,
                  label: const Text('Future Events'),
                  icon: const Icon(Icons.event_available),
                ),
                ButtonSegment(
                  value: true,
                  label: const Text('Past Events'),
                  icon: const Icon(Icons.history),
                ),
              ],
              selected: {_showPast},
              onSelectionChanged: (selection) {
                setState(() => _showPast = selection.first);
              },
              showSelectedIcon: false,
            ),
          ),
          Expanded(
            child: visibleListings.isEmpty
                ? Center(
                    child: Text(
                      _showPast
                          ? 'No past saved events'
                          : 'No future saved events',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
                    itemBuilder: (context, index) {
                      final listing = visibleListings[index];
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
                        onDismissed: (_) => widget.onRemove(listing),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 4,
                          ),
                          leading: _SavedListingImage(
                            imageUrl: listing.imageUrl,
                          ),
                          title: Text(
                            listing.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          subtitle: Text(
                            _savedListingSubtitle(listing),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: IconButton(
                            tooltip:
                                widget.plannedListingIds.contains(listing.id)
                                ? 'Remove from plan'
                                : 'Add to plan',
                            icon: Icon(
                              widget.plannedListingIds.contains(listing.id)
                                  ? Icons.event_available
                                  : Icons.event_available_outlined,
                            ),
                            onPressed: () => widget.onPlanChanged(
                              listing,
                              !widget.plannedListingIds.contains(listing.id),
                            ),
                          ),
                          onTap: () => widget.onOpen(listing),
                        ),
                      );
                    },
                    separatorBuilder: (context, index) =>
                        const Divider(height: 1),
                    itemCount: visibleListings.length,
                  ),
          ),
        ],
      ),
    );
  }

  String _savedListingSubtitle(SavedListing listing) {
    final path = Uri.parse(listing.url).path;
    final startsAt = listing.startsAt;
    if (startsAt == null) {
      return path;
    }
    final date =
        '${startsAt.day.toString().padLeft(2, '0')}/${startsAt.month.toString().padLeft(2, '0')}/${startsAt.year}';
    return '$date · $path';
  }
}

class PlannerView extends StatefulWidget {
  const PlannerView({
    required this.listings,
    required this.plannedListingIds,
    required this.completedListingIds,
    required this.tripNotes,
    required this.onOpen,
    required this.onPlannedChanged,
    required this.onCompletedChanged,
    required this.onNotesChanged,
    super.key,
  });

  final List<SavedListing> listings;
  final Set<String> plannedListingIds;
  final Set<String> completedListingIds;
  final String tripNotes;
  final ValueChanged<SavedListing> onOpen;
  final void Function(SavedListing listing, bool planned) onPlannedChanged;
  final void Function(SavedListing listing, bool completed) onCompletedChanged;
  final ValueChanged<String> onNotesChanged;

  @override
  State<PlannerView> createState() => _PlannerViewState();
}

class _PlannerViewState extends State<PlannerView> {
  late final TextEditingController _notesController;

  @override
  void initState() {
    super.initState();
    _notesController = TextEditingController(text: widget.tripNotes);
  }

  @override
  void didUpdateWidget(covariant PlannerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tripNotes != widget.tripNotes &&
        _notesController.text != widget.tripNotes) {
      _notesController.text = widget.tripNotes;
    }
  }

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final plannedListings = [
      for (final listing in widget.listings)
        if (widget.plannedListingIds.contains(listing.id)) listing,
    ];
    plannedListings.sort((a, b) {
      final aTime = a.startsAt;
      final bTime = b.startsAt;
      if (aTime == null && bTime == null) {
        return a.savedAt.compareTo(b.savedAt);
      }
      if (aTime == null) {
        return 1;
      }
      if (bTime == null) {
        return -1;
      }
      return aTime.compareTo(bTime);
    });
    final unplannedListings = [
      for (final listing in widget.listings)
        if (!widget.plannedListingIds.contains(listing.id)) listing,
    ];

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
        children: [
          Row(
            children: [
              Expanded(
                child: _PlannerStat(
                  icon: Icons.event_note,
                  label: 'Planned',
                  value: plannedListings.length.toString(),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _PlannerStat(
                  icon: Icons.task_alt,
                  label: 'Done',
                  value: widget.completedListingIds.length.toString(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          TextField(
            controller: _notesController,
            minLines: 3,
            maxLines: 6,
            textInputAction: TextInputAction.newline,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Trip notes',
              prefixIcon: Icon(Icons.edit_note),
            ),
            onChanged: widget.onNotesChanged,
          ),
          const SizedBox(height: 22),
          Text(
            'Today Plan',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          if (plannedListings.isEmpty)
            const _PlannerEmptyState()
          else
            ...plannedListings.map(
              (listing) => _PlannerListingTile(
                listing: listing,
                planned: true,
                completed: widget.completedListingIds.contains(listing.id),
                onOpen: () => widget.onOpen(listing),
                onPlannedChanged: (planned) =>
                    widget.onPlannedChanged(listing, planned),
                onCompletedChanged: (completed) =>
                    widget.onCompletedChanged(listing, completed),
              ),
            ),
          if (unplannedListings.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text(
              'Saved Ideas',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            ...unplannedListings.map(
              (listing) => _PlannerListingTile(
                listing: listing,
                planned: false,
                completed: false,
                onOpen: () => widget.onOpen(listing),
                onPlannedChanged: (planned) =>
                    widget.onPlannedChanged(listing, planned),
                onCompletedChanged: (completed) =>
                    widget.onCompletedChanged(listing, completed),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PlannerStat extends StatelessWidget {
  const _PlannerStat({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFE5E7EB)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xFFE11D48)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          Text(
            value,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
          ),
        ],
      ),
    );
  }
}

class _PlannerEmptyState extends StatelessWidget {
  const _PlannerEmptyState();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFE5E7EB)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Column(
        children: [
          Icon(Icons.event_available_outlined, size: 42),
          SizedBox(height: 10),
          Text(
            'Add saved listings to build a day plan',
            textAlign: TextAlign.center,
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
  }
}

class _PlannerListingTile extends StatelessWidget {
  const _PlannerListingTile({
    required this.listing,
    required this.planned,
    required this.completed,
    required this.onOpen,
    required this.onPlannedChanged,
    required this.onCompletedChanged,
  });

  final SavedListing listing;
  final bool planned;
  final bool completed;
  final VoidCallback onOpen;
  final ValueChanged<bool> onPlannedChanged;
  final ValueChanged<bool> onCompletedChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: Color(0xFFE5E7EB)),
          borderRadius: BorderRadius.circular(12),
        ),
        leading: Checkbox(
          value: completed,
          onChanged: planned
              ? (value) => onCompletedChanged(value ?? false)
              : null,
        ),
        title: Text(
          listing.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: FontWeight.w800,
            decoration: completed ? TextDecoration.lineThrough : null,
          ),
        ),
        subtitle: Text(
          _plannerListingSubtitle(listing),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: IconButton(
          tooltip: planned ? 'Remove from plan' : 'Add to plan',
          icon: Icon(planned ? Icons.remove_circle_outline : Icons.add_circle),
          onPressed: () => onPlannedChanged(!planned),
        ),
        onTap: onOpen,
      ),
    );
  }

  String _plannerListingSubtitle(SavedListing listing) {
    final startsAt = listing.startsAt;
    if (startsAt == null) {
      return Uri.parse(listing.url).path;
    }
    final date =
        '${startsAt.day.toString().padLeft(2, '0')}/${startsAt.month.toString().padLeft(2, '0')}/${startsAt.year}';
    final time =
        '${startsAt.hour.toString().padLeft(2, '0')}:${startsAt.minute.toString().padLeft(2, '0')}';
    return '$date $time';
  }
}

class _SavedListingImage extends StatelessWidget {
  const _SavedListingImage({required this.imageUrl});

  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    final url = imageUrl;
    if (url == null || url.isEmpty) {
      return const CircleAvatar(child: Icon(Icons.bookmark));
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Image.network(
        url,
        width: 56,
        height: 56,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) {
          return const CircleAvatar(child: Icon(Icons.bookmark));
        },
      ),
    );
  }
}
