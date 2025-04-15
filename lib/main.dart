import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:vocsy_epub_viewer/epub_viewer.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as path;
import 'dart:io';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:math';

class Book {
  final int? id;
  final String title;
  final String filePath;
  final String lastLocatorJson;
  final int totalReadingTime; // In seconds
  final Map<String, List<String>> highlights;
  final String? coverImagePath;

  const Book({
    this.id,
    required this.title,
    required this.filePath,
    this.lastLocatorJson = '{}',
    this.totalReadingTime = 0,
    this.highlights = const {},
    this.coverImagePath,
  });


  double get progression {
    if (lastLocatorJson.isNotEmpty && lastLocatorJson != '{}') {
      try {
        Map<String, dynamic> decodedLocatorMap = json.decode(lastLocatorJson);
        if (decodedLocatorMap.containsKey('locations') &&
            decodedLocatorMap['locations'] is Map &&
            decodedLocatorMap['locations']['progression'] is num) {
          double p = (decodedLocatorMap['locations']['progression'] as num).toDouble();
          return p.clamp(0.0, 1.0);
        }
      } catch (e) { print("Error decoding progression: $e"); }
    }
    return 0.0;
  }

  Duration? get estimatedTimeLeft {
    double currentProgression = progression;
    if (currentProgression > 0.01 && totalReadingTime > 10) {
      try {
        if (currentProgression < 0.001) return null;
        double estimatedTotalTime = totalReadingTime / currentProgression;
        double timeLeftSeconds = estimatedTotalTime * (1.0 - currentProgression);
        if (timeLeftSeconds.isFinite && timeLeftSeconds >= 0) {
          return Duration(seconds: timeLeftSeconds.round());
        }
      } catch (e) { print("Error calculating time left: $e"); }
    }
    return null;
  }

  int get highlightCount => highlights.values.fold(0, (sum, list) => sum + list.length);

  Map<String, dynamic> toMap() => {
    'id': id, 'title': title, 'filePath': filePath,
    'lastLocatorJson': lastLocatorJson, 'totalReadingTime': totalReadingTime,
    'highlights': json.encode(highlights), 'coverImagePath': coverImagePath,
  };

  static Book fromMap(Map<String, dynamic> map) {
    Map<String, List<String>> decodedHighlights = {};
    if (map['highlights'] != null) {
      try {
        var decoded = json.decode(map['highlights']);
        if (decoded is Map) {
          decodedHighlights = Map<String, List<String>>.from(
              decoded.map((key, value) => MapEntry(key.toString(), List<String>.from((value as List).map((e) => e.toString()))))
          );
        }
      } catch (e) { print("Error decoding highlights: $e"); }
    }
    return Book(
      id: map['id'] as int?,
      title: map['title'] as String? ?? 'Untitled',
      filePath: map['filePath'] as String? ?? '',
      lastLocatorJson: map['lastLocatorJson'] as String? ?? '{}',
      totalReadingTime: map['totalReadingTime'] as int? ?? 0,
      highlights: decodedHighlights,
      coverImagePath: map['coverImagePath'] as String?,
    );
  }

  Book copyWith({
    int? id, String? title, String? filePath, String? lastLocatorJson,
    int? totalReadingTime, Map<String, List<String>>? highlights, String? coverImagePath,
  }) => Book(
    id: id ?? this.id,
    title: title ?? this.title,
    filePath: filePath ?? this.filePath,
    lastLocatorJson: lastLocatorJson ?? this.lastLocatorJson,
    totalReadingTime: totalReadingTime ?? this.totalReadingTime,
    highlights: highlights ?? this.highlights,
    coverImagePath: coverImagePath ?? this.coverImagePath,
  );
}

class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  static Database? _database;
  static const int _dbVersion = 2;
  static const String _dbName = 'books_database.db';

  factory DatabaseHelper() => _instance;
  DatabaseHelper._internal();

  Future<Database> get database async => _database ??= await _initDatabase();

  Future<Database> _initDatabase() async {
    final dbPath = path.join(await getDatabasesPath(), _dbName);
    print("Database path: $dbPath");
    return await openDatabase(
      dbPath,
      version: _dbVersion,
      onCreate: (db, version) {
        print("Creating database table 'books' version $version");
        return db.execute(
          'CREATE TABLE books(id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT, filePath TEXT, lastLocatorJson TEXT, totalReadingTime INTEGER DEFAULT 0, highlights TEXT DEFAULT \'{}\', coverImagePath TEXT)',
        );
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        print("Upgrading database from version $oldVersion to $newVersion");
        if (oldVersion < 2) {
          try {
            await db.execute('ALTER TABLE books ADD COLUMN coverImagePath TEXT');
            print("Column 'coverImagePath' added successfully.");
          } catch (e) { print("Error adding coverImagePath column: $e"); }
        }
      },
    );
  }

  Future<void> insertBook(Book book) async {
    try {
      final db = await database;
      await db.insert('books', book.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
      print("Book inserted/replaced: ${book.title}");
    } catch (e) { print("Error inserting book ${book.title}: $e"); }
  }

  Future<List<Book>> getBooks() async {
    final db = await database;
    final maps = await db.query('books', orderBy: 'title ASC');
    if (maps.isEmpty) return [];
    List<Book> books = maps.map((map) {
      try { return Book.fromMap(map); }
      catch (e) { print("Error creating Book from map: $map, Error: $e"); return null; }
    }).whereType<Book>().toList();
    print("Loaded ${books.length} books from database.");
    return books;
  }

  Future<void> updateBookProgressFields(int bookId, {String? newLocatorJson, int? addedReadingTime}) async {
    if (newLocatorJson == null && (addedReadingTime == null || addedReadingTime <= 0)) return;
    try {
      final db = await database;
      await db.transaction((txn) async {
        final books = await txn.query('books', where: 'id = ?', whereArgs: [bookId], limit: 1);
        if (books.isNotEmpty) {
          final currentBook = Book.fromMap(books.first);
          Map<String, dynamic> updates = {};
          if (newLocatorJson != null && newLocatorJson != currentBook.lastLocatorJson) { updates['lastLocatorJson'] = newLocatorJson; }
          if (addedReadingTime != null && addedReadingTime > 0) { updates['totalReadingTime'] = currentBook.totalReadingTime + addedReadingTime; }
          if (updates.isNotEmpty) { await txn.update('books', updates, where: 'id = ?', whereArgs: [bookId]); }
        }
      });
      print("DB Update: Completed for book ID $bookId.");
    } catch (e) { print("Error updating progress fields for book ID $bookId: $e"); }
  }

  Future<void> deleteBook(int id) async {
    try {
      final db = await database;
      await db.delete('books', where: 'id = ?', whereArgs: [id]);
      print("Deleted book record ID $id.");
    } catch (e) { print("Error deleting book ID $id: $e"); }
  }
}

class ReadingSettings extends ChangeNotifier {
  static const _fontSizeKey = 'fontSize';
  static const _fontFamilyKey = 'fontFamily';
  static const _lineHeightKey = 'lineHeight';
  static const _scrollDirectionKey = 'scrollDirection';

  double _fontSize = 16;
  String _fontFamily = 'Roboto';
  double _lineHeight = 1.4;
  EpubScrollDirection _scrollDirection = EpubScrollDirection.HORIZONTAL;

  double get fontSize => _fontSize;
  String get fontFamily => _fontFamily;
  double get lineHeight => _lineHeight;
  EpubScrollDirection get scrollDirection => _scrollDirection;

  ReadingSettings() { loadSettings(); }

  Future<void> loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _fontSize = prefs.getDouble(_fontSizeKey) ?? _fontSize;
      _fontFamily = prefs.getString(_fontFamilyKey) ?? _fontFamily;
      _lineHeight = prefs.getDouble(_lineHeightKey) ?? _lineHeight;
      final savedDirectionName = prefs.getString(_scrollDirectionKey);
      _scrollDirection = EpubScrollDirection.values.firstWhere(
            (e) => e.name == savedDirectionName, orElse: () => EpubScrollDirection.HORIZONTAL,
      );
      notifyListeners();
    } catch (e) { print("Error loading settings: $e"); }
  }

  void updateSetting(String key, dynamic value) {
    bool changed = false;
    switch (key) {
      case _fontSizeKey: if (_fontSize != value && value is double) { _fontSize = value; changed = true; } break;
      case _fontFamilyKey: if (_fontFamily != value && value is String) { _fontFamily = value; changed = true; } break;
      case _lineHeightKey: if (_lineHeight != value && value is double) { _lineHeight = value; changed = true; } break;
      case _scrollDirectionKey: if (_scrollDirection != value && value is EpubScrollDirection) { _scrollDirection = value; changed = true; } break;
    }
    if (changed) { _saveSettings(); notifyListeners(); }
  }

  Future<void> _saveSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await Future.wait([
        prefs.setDouble(_fontSizeKey, _fontSize), prefs.setString(_fontFamilyKey, _fontFamily),
        prefs.setDouble(_lineHeightKey, _lineHeight), prefs.setString(_scrollDirectionKey, _scrollDirection.name),
      ]);
    } catch (e) { print("Error saving settings: $e"); }
  }
}

class ReadingTimeTracker {
  final int bookId;
  final DatabaseHelper databaseHelper;
  final VoidCallback? onTimeSaved;
  DateTime? _startTime;
  Timer? _timer;
  int _sessionSeconds = 0;

  ReadingTimeTracker({required this.bookId, required this.databaseHelper, this.onTimeSaved});

  void startTracking() {
    if (_timer?.isActive ?? false) { return; }
    _startTime = DateTime.now();
    _sessionSeconds = 0;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) { _sessionSeconds++; });
    print("Started time tracking for book ID $bookId.");
  }

  Future<void> stopAndSaveTracking() async {
    if (!(_timer?.isActive ?? false)) {
      if(_startTime == null && _sessionSeconds == 0) return;
      // *** ADDED DEBUG LOG ***
      print("DEBUG: Tracker timer for $bookId inactive, session time: $_sessionSeconds. Attempting save.");
    }
    _timer?.cancel(); _timer = null;
    final int recordedSessionSeconds = _sessionSeconds;
    final bool wasTracking = _startTime != null;
    _resetTrackingState(); // Reset happens *before* saving check

    // *** ADDED DEBUG LOG ***
    print("DEBUG: stopAndSaveTracking called for book ID $bookId. Recorded Session Seconds: $recordedSessionSeconds, Was Tracking: $wasTracking");

    if (wasTracking && recordedSessionSeconds > 0) {
      // *** ADDED DEBUG LOG ***
      print("DEBUG: Saving time for book ID $bookId. Session: $recordedSessionSeconds seconds.");
      try {
        await databaseHelper.updateBookProgressFields(bookId, addedReadingTime: recordedSessionSeconds);
        // *** ADDED DEBUG LOG ***
        print("DEBUG: Time save successful for book ID $bookId.");
        onTimeSaved?.call();
      } catch (e) { print("Error saving reading time for book ID $bookId: $e"); }
    } else if (wasTracking) {
      print("Time tracking stopped for book ID $bookId, but no time recorded (recordedSessionSeconds was 0 or less).");
    } else {
      // *** ADDED DEBUG LOG ***
      print("DEBUG: stopAndSaveTracking called for book ID $bookId, but wasTracking was false.");
    }
  }


  void _resetTrackingState() { _sessionSeconds = 0; _startTime = null; }

  static String formatDuration(Duration? duration) {
    if (duration == null || duration.inSeconds < 0) return 'N/A';
    if (duration.inSeconds == 0) return '0m';
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    String result = '';
    if (hours > 0) result += '${hours}h ';
    if (minutes >= 0) result += '${minutes}m';
    if (result.trim().isEmpty && duration.inSeconds > 0) return '< 1m';
    if (result.trim().isEmpty) return '0m';
    return result.trim();
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ChangeNotifierProvider(
      create: (context) => ReadingSettings(),
      child: const EpubReaderApp(),
    ),
  );
}

class EpubReaderApp extends StatelessWidget {
  const EpubReaderApp({Key? key}) : super(key: key);
  @override
  Widget build(BuildContext context) {
    final readingSettings = context.watch<ReadingSettings>();
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Flutter EPUB Reader',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo, brightness: Brightness.light),
        fontFamily: readingSettings.fontFamily,
        cardTheme: CardTheme(elevation: 1.0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 5)),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo, brightness: Brightness.dark),
        fontFamily: readingSettings.fontFamily,
        cardTheme: CardTheme(elevation: 1.0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 5)),
      ),
      themeMode: ThemeMode.system,
      home: const LibraryScreen(),
    );
  }
}

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({Key? key}) : super(key: key);
  @override
  _LibraryScreenState createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final DatabaseHelper _databaseHelper = DatabaseHelper();
  List<Book> books = [];
  bool isLoading = true;
  StreamSubscription? _locatorSubscription;
  ReadingTimeTracker? _timeTracker;

  @override
  void initState() { super.initState(); _loadBooks(); }
  @override
  void dispose() {
    _locatorSubscription?.cancel();
    _timeTracker?.stopAndSaveTracking().then((_) => print("Tracker stopped on dispose."));
    super.dispose();
  }

  Future<void> _loadBooks() async {
    if (!mounted) return;
    await _timeTracker?.stopAndSaveTracking(); _timeTracker = null;
    setState(() { isLoading = true; });
    try {
      final loadedBooks = await _databaseHelper.getBooks();
      if (mounted) { setState(() { books = loadedBooks; isLoading = false; }); }
    } catch (e, stackTrace) {
      if (mounted) {
        setState(() { isLoading = false; books = []; });
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error loading library.'), backgroundColor: Colors.red));
      }
    }
  }

  Future<void> _pickAndImportBook() async {
    FilePickerResult? result;
    try { result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['epub']); }
    catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error picking file: ${e.toString()}'))); return; }

    if (result != null && result.files.single.path != null) {
      File sourceFile = File(result.files.single.path!);
      String originalFileName = result.files.single.name;
      if (mounted) setState(() => isLoading = true);
      try {
        Directory appDocDir = await getApplicationDocumentsDirectory();
        String booksDir = path.join(appDocDir.path, 'epubs');
        await Directory(booksDir).create(recursive: true);
        String newPath = path.join(booksDir, originalFileName);
        final currentBooks = await _databaseHelper.getBooks();
        if (currentBooks.any((book) => book.filePath == newPath)) {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Book already in library.')));
          setState(() => isLoading = false); return;
        }

        String? coverImagePath;
        String bookNameWithoutExt = path.basenameWithoutExtension(originalFileName);
        // Example matching logic - adjust as needed
        if (bookNameWithoutExt.toLowerCase().contains('discourses')) { coverImagePath = 'assets/images/discourses_selected_cover.png'; }
        else if (bookNameWithoutExt.toLowerCase().contains('designing your life')) { coverImagePath = 'assets/images/designing your life.png'; }
        else if (bookNameWithoutExt.toLowerCase().contains('republic')) { coverImagePath = 'assets/images/the republic.png'; }

        await sourceFile.copy(newPath);
        Book newBook = Book(
          title: originalFileName.replaceAll(RegExp(r'\.epub$', caseSensitive: false), ''),
          filePath: newPath, coverImagePath: coverImagePath,
        );
        await _databaseHelper.insertBook(newBook);
        await _loadBooks();
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error importing book: ${e.toString()}')));
        setState(() => isLoading = false);
      }
    }
  }

  void _openReader(Book book) async {
    if (book.id == null || book.filePath.isEmpty) { return; }
    final file = File(book.filePath); if (!await file.exists()) { return; }
    await _timeTracker?.stopAndSaveTracking(); _timeTracker = null;
    _timeTracker = ReadingTimeTracker(
        bookId: book.id!, databaseHelper: _databaseHelper,
        onTimeSaved: () { if (mounted) _updateLocalBookData(book.id!); }
    );
    try {
      final readingSettings = Provider.of<ReadingSettings>(context, listen: false);
      final isDarkMode = Theme.of(context).brightness == Brightness.dark;
      VocsyEpub.setConfig(
          themeColor: Theme.of(context).colorScheme.primary, identifier: "book_${book.id}",
          scrollDirection: readingSettings.scrollDirection,
          allowSharing: true, enableTts: false, nightMode: isDarkMode );
      EpubLocator? lastKnownLocator;
      if (book.lastLocatorJson.isNotEmpty && book.lastLocatorJson != '{}') {
        try { lastKnownLocator = EpubLocator.fromJson(json.decode(book.lastLocatorJson)); }
        catch (e) { print("Error decoding locator: $e."); }
      }
      _setupLocatorListener(book.id!);
      VocsyEpub.open( book.filePath, lastLocation: lastKnownLocator );
      _timeTracker!.startTracking();
    } catch (e) {
      print("CRITICAL Error during VocsyEpub open: $e");
      if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error opening EPUB: ${e.toString()}'), backgroundColor: Colors.red));
      await _timeTracker?.stopAndSaveTracking(); _timeTracker = null;
      _locatorSubscription?.cancel(); _locatorSubscription = null;
    }
  }

  Future<void> _updateLocalBookData(int bookId) async {
    if (!mounted) return;
    print("Attempting to refresh local data for book ID $bookId");
    try {
      final db = await _databaseHelper.database;
      final bookDataList = await db.query('books', where: 'id = ?', whereArgs: [bookId], limit: 1);
      if(bookDataList.isNotEmpty) {
        final updatedDbBook = Book.fromMap(bookDataList.first);
        final bookIndex = books.indexWhere((b) => b.id == bookId);
        if (bookIndex != -1) {
          bool changed = books[bookIndex].lastLocatorJson != updatedDbBook.lastLocatorJson ||
              books[bookIndex].totalReadingTime != updatedDbBook.totalReadingTime;
          if (changed && mounted) {
            setState(() { books[bookIndex] = updatedDbBook; });
            print("LibraryScreen: Updated local book data for ID $bookId.");
          }
        }
      }
    } catch(e) { print("LibraryScreen: Error updating local book data: $e"); }
  }

  void _setupLocatorListener(int bookId) {
    print("Setting up listener for $bookId");
    _locatorSubscription?.cancel();
    _locatorSubscription = VocsyEpub.locatorStream.listen(
          (locatorData) async {
        String? locatorJsonString;
        if (locatorData is String) { locatorJsonString = locatorData; }
        else if (locatorData is Map) { try { locatorJsonString = json.encode(locatorData); } catch (e) { print("Listener Error encoding map: $e"); } }
        if (locatorJsonString != null) { await _updateBookProgress(bookId, locatorJsonString); }
        else { print("Listener Error: Unrecognized locator format"); }
      },
      onError: (error) {
        // *** ADDED DEBUG LOG ***
        print("DEBUG: Listener Error for $bookId: $error. Attempting to stop/save timer.");
        _timeTracker?.stopAndSaveTracking(); _timeTracker = null;
      },
      onDone: () {
        // *** ADDED DEBUG LOG ***
        print("DEBUG: Listener Done for $bookId. Attempting to stop/save timer.");
        _timeTracker?.stopAndSaveTracking().then((_) => _timeTracker = null);
        _locatorSubscription?.cancel(); _locatorSubscription = null;
      },
      cancelOnError: true, // Set to true to automatically cancel on error
    );
  }


  Future<void> _updateBookProgress(int bookId, String newLocatorJson) async {
    if (!mounted) return;
    try {
      await _databaseHelper.updateBookProgressFields(bookId, newLocatorJson: newLocatorJson);
      _updateLocalBookData(bookId);
    } catch (e, stackTrace) { print("Error saving progress: $e\n$stackTrace"); }
  }

  void _navigateToStatsScreen(Book book) async {
    if (!mounted) return;
    print("Navigating to Stats for ${book.id}");
    Book freshBook = book;
    if (book.id != null) {
      try {
        final db = await _databaseHelper.database;
        final maps = await db.query('books', where: 'id = ?', whereArgs: [book.id], limit: 1);
        if (maps.isNotEmpty) freshBook = Book.fromMap(maps.first);
      } catch (e) { print("Error fetching fresh book data: $e"); }
    }
    if (!mounted) return;
    Navigator.push(
      context, MaterialPageRoute(
        builder: (context) => StatsScreen(
          book: freshBook,
          onDeleteRequested: () { if(mounted) _confirmAndDeleteBook(freshBook); },
        )
    ),
    ).then((_) { if(mounted && freshBook.id != null) _updateLocalBookData(freshBook.id!); });
  }

  void _confirmAndDeleteBook(Book book) {
    if (!mounted) return;
    // Stop tracking if deleting the currently tracked book
    if (_timeTracker?.bookId == book.id) { _timeTracker?.stopAndSaveTracking(); _timeTracker = null; }
    showDialog( context: context, barrierDismissible: false,
      builder: (BuildContext ctx) {
        return AlertDialog(
          title: const Text('Delete Book?'),
          content: Text('Are you sure you want to permanently delete "${book.title}"?'),
          actions: <Widget>[
            TextButton(child: const Text('Cancel'), onPressed: () => Navigator.of(ctx).pop()),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.red.shade700),
              child: const Text('Delete'),
              // IMPORTANT: Pop the dialog *before* starting async delete operation
              onPressed: () async { Navigator.of(ctx).pop(); await _deleteBook(book);
              if (!mounted) return; // Important safety check

              // 4. Pop the StatsScreen using the LibraryScreen's context 'context'
              Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }


  Future<void> _deleteBook(Book book) async {
    print("Deleting book ID ${book.id}");
    if (book.id == null) { return; }
    if (mounted) setState(() => isLoading = true);
    try {
      // Ensure tracker is stopped if deleting tracked book
      if (_timeTracker?.bookId == book.id) { await _timeTracker?.stopAndSaveTracking(); _timeTracker = null; }
      _locatorSubscription?.cancel(); _locatorSubscription = null; // Cancel listener if active for this book

      final file = File(book.filePath);
      if (await file.exists()) await file.delete();
      await _databaseHelper.deleteBook(book.id!);
      await _loadBooks(); // Reload the book list
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('"${book.title}" deleted.')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error deleting "${book.title}".')));
      // Ensure loading state is reset on error
      if (mounted) setState(() { isLoading = false; });
    }
  }


  @override
  Widget build(BuildContext context) {
    final readingSettings = context.watch<ReadingSettings>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('My EPUB Library'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () { Navigator.push(context, MaterialPageRoute(builder: (context) => const SettingsScreen())); },
          ),
        ],
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : books.isEmpty
          ? _buildEmptyLibraryView()
          : RefreshIndicator( onRefresh: _loadBooks, child: _buildBookGridView(), ),
    floatingActionButton: (!isLoading && books.isNotEmpty)
    ? FloatingActionButton(
    onPressed: _pickAndImportBook,
    tooltip: 'Import EPUB Book',
    child: const Icon(Icons.add),
    )
        : null,
    );
  }

  Widget _buildEmptyLibraryView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.library_books_outlined, size: 70, color: Colors.grey),
            const SizedBox(height: 20),
            Text('Your library is empty.', style: Theme.of(context).textTheme.headlineSmall?.copyWith(color: Colors.grey)),
            const SizedBox(height: 10),
            Text('Tap the + button to import an EPUB file.', textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey)),
            const SizedBox(height: 30),
            ElevatedButton.icon(
              icon: const Icon(Icons.add_circle_outline),
              label: const Text('Import First Book'),
              onPressed: _pickAndImportBook,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                textStyle: Theme.of(context).textTheme.bodyLarge,
              ),
            )
          ],
        ),
      ),
    );
  }

  Widget _buildBookGridView() {
    final screenWidth = MediaQuery.of(context).size.width;
    final crossAxisCount = max(2,(screenWidth / 150).floor());
    final double gridPadding = 12.0;
    final double crossAxisSpacing = 12.0;
    final double mainAxisSpacing = 16.0;
    final double itemWidth = (screenWidth - (gridPadding * 2) - (crossAxisSpacing * (crossAxisCount - 1))) / crossAxisCount;
    final double coverHeight = itemWidth * 1.4;
    final double textHeight = 50; // Estimated height for title text
    final double childAspectRatio = itemWidth / (coverHeight + textHeight);

    return GridView.builder(
      key: const PageStorageKey('libraryGrid'), // Helps preserve scroll position
      padding: EdgeInsets.all(gridPadding),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount, childAspectRatio: childAspectRatio,
        crossAxisSpacing: crossAxisSpacing, mainAxisSpacing: mainAxisSpacing,
      ),
      itemCount: books.length,
      itemBuilder: (context, index) {
        try {
          final book = books[index];
          return Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => _openReader(book),
              onLongPress: () { _navigateToStatsScreen(book); }, // Navigate to stats on long press
              borderRadius: BorderRadius.circular(8.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  // Book Cover
                  Ink(
                    height: coverHeight, width: double.infinity,
                    decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceVariant, borderRadius: BorderRadius.circular(8.0)),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8.0),
                      child: (book.coverImagePath != null && book.coverImagePath!.isNotEmpty)
                          ? Image.asset( book.coverImagePath!, fit: BoxFit.cover, errorBuilder: (ctx, err, st) => const Center(child: Icon(Icons.broken_image_outlined, color: Colors.grey)))
                          : Center(child: Icon(Icons.menu_book, size: 40.0, color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.8))),
                    ),
                  ),
                  // Book Title
                  Padding(
                    padding: const EdgeInsets.only(top: 6.0, left: 4.0, right: 4.0),
                    child: Text( book.title, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500, height: 1.25)),
                  ),
                ],
              ),
            ),
          );
        } catch (e, stackTrace) {
          print("Error in Grid itemBuilder $index: $e\n$stackTrace");
          return Container( color: Colors.red.shade100, child: const Center(child: Icon(Icons.error)) ); // Error placeholder
        }
      },
    );
  }
}

class StatsScreen extends StatelessWidget {
  final Book book;
  final VoidCallback onDeleteRequested;

  const StatsScreen({ Key? key, required this.book, required this.onDeleteRequested }) : super(key: key);

  // Use the static formatter from ReadingTimeTracker
  String _formatDurationLocal(Duration? duration) => ReadingTimeTracker.formatDuration(duration);

  @override
  Widget build(BuildContext context) {
    // Calculate stats here if needed, or use getters from Book model
    double percentageComplete = book.progression * 100.0;
    Duration? timeLeft = book.estimatedTimeLeft;
    int highlightCount = book.highlightCount; // Use getter

    return Scaffold(
      appBar: AppBar(
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: ListView( // Use ListView for potentially scrollable content
          children: [
            // Optional Cover Image Display
            if (book.coverImagePath != null && book.coverImagePath!.isNotEmpty)
              Center(
                child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.3),
                    child: ClipRRect(
                        borderRadius: BorderRadius.circular(8.0),
                        child: Image.asset(
                            book.coverImagePath!,
                            fit: BoxFit.contain,
                            errorBuilder: (ctx, err, st) => const Icon(Icons.error) // Placeholder on error
                        )
                    )
                ),
              ),
            if (book.coverImagePath != null) const SizedBox(height: 20),

            // Stats Card
            Card(
              elevation: 2, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildStatRow(context, Icons.book_outlined, 'Title', book.title),
                    const Divider(),
                    _buildStatRow(context, Icons.timer_outlined, 'Total Time Read', _formatDurationLocal(Duration(seconds: book.totalReadingTime))),
                    const Divider(),

                    Padding(
                      padding: const EdgeInsets.only(top: 12.0), // Add some space above the button
                      child: Center( // Center the button if you like
                        child: TextButton.icon(
                          icon: const Icon(Icons.delete_forever_outlined, color: Colors.redAccent),
                          label: const Text('Delete Book Permanently'),
                          style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
                          onPressed: onDeleteRequested, // Use the existing callback
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 20),
            // Button to view highlights (only if highlights exist)
            if (highlightCount > 0)
              ElevatedButton.icon(
                icon: const Icon(Icons.list_alt_outlined),
                label: const Text('View Highlights'),
                style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 40)),
                onPressed: () {
                  // Ensure we pass the potentially updated book object if needed,
                  // though HighlightsScreen might just need the ID or initial data.
                  Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => HighlightsScreen(book: book))
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  // Helper widget to build a row in the stats card
  Widget _buildStatRow(BuildContext context, IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Theme.of(context).colorScheme.primary, size: 22),
          const SizedBox(width: 16),
          Text('$label:', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(width: 8),
          Expanded(child: Text(value, style: Theme.of(context).textTheme.bodyMedium, textAlign: TextAlign.end, softWrap: true)),
        ],
      ),
    );
  }
}


class SettingsScreen extends StatelessWidget {
  const SettingsScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Consumer<ReadingSettings>(
      builder: (context, readingSettings, child) {
        return Scaffold(
          appBar: AppBar(title: const Text('Settings')),
          body: ListView(
            padding: const EdgeInsets.all(8.0),
            children: [
              _buildSectionHeader(context, 'Appearance'),
              _buildScrollDirectionSetting(context, readingSettings),
              const Divider(height: 20, thickness: 1),
              _buildSectionHeader(context, 'About'),
              _buildAboutTile(context),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 16.0),
      child: Text( title, style: Theme.of(context).textTheme.titleMedium?.copyWith( color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600)),
    );
  }

  Widget _buildScrollDirectionSetting(BuildContext context, ReadingSettings settings) {
    return ListTile(
      title: const Text('Scroll Direction'),
      trailing: DropdownButton<EpubScrollDirection>(
        value: settings.scrollDirection,
        items: const [
          DropdownMenuItem(value: EpubScrollDirection.HORIZONTAL, child: Text('Horizontal')),
          DropdownMenuItem(value: EpubScrollDirection.VERTICAL, child: Text('Vertical')),
        ],
        onChanged: (value) { if (value != null) settings.updateSetting(ReadingSettings._scrollDirectionKey, value); },
      ),
    );
  }
  Widget _buildAboutTile(BuildContext context) {
    // Consider using package_info_plus for dynamic version display
    return ListTile(
      title: const Text('App Version'), subtitle: const Text('1.5.1 (Debug Build)'), // Example version
      leading: const Icon(Icons.info_outline),
      onTap: () {
        showAboutDialog( context: context, applicationName: 'Flutter EPUB Reader', applicationVersion: '1.5.1', // Example version
          applicationLegalese: '© 2024 Your Name', // Update Legalese
          children: [ const Padding( padding: EdgeInsets.only(top: 15), child: Text('Simple EPUB reader built with Flutter.')) ], // Update Description
        );
      },
    );
  }
}



class HighlightsScreen extends StatelessWidget {
  final Book book;
  const HighlightsScreen({Key? key, required this.book}) : super(key: key);

  // Safely get highlights
  Map<String, List<String>> _getValidHighlights() {
    try {
      if (book.highlights is Map<String, List<String>>) {
        return book.highlights;
      }
    } catch (e) { print("Error accessing highlights map: $e");}
    return {}; // Return empty map if data is invalid or error occurs
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, List<String>> highlights = _getValidHighlights();
    // Filter out empty chapters before getting keys
    final List<String> chapters = highlights.entries
        .where((entry) => entry.value.isNotEmpty)
        .map((entry) => entry.key)
        .toList();

    return Scaffold(
      appBar: AppBar(title: Text('Highlights: ${book.title}', overflow: TextOverflow.ellipsis)),
      body: highlights.isEmpty || chapters.isEmpty // Check if the filtered list is empty
          ? Center(child: Padding(padding: const EdgeInsets.all(20.0), child: Text('No highlights saved yet.', style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.grey))))
          : ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 10.0, horizontal: 8.0),
        itemCount: chapters.length,
        itemBuilder: (context, chapterIndex) {
          final String chapter = chapters[chapterIndex];
          // Get highlights for the chapter, defaulting to empty list if null
          final List<String> chapterHighlights = highlights[chapter] ?? [];

          // This check is technically redundant now due to filtering above, but safe to keep
          if (chapterHighlights.isEmpty) return const SizedBox.shrink();

          return Card(
            margin: const EdgeInsets.symmetric(vertical: 6.0), // Add some vertical spacing between cards
            child: ExpansionTile(
              title: Text(chapter.isNotEmpty ? chapter : 'Unknown Chapter', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              initiallyExpanded: true, // Keep chapters expanded by default
              childrenPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              children: chapterHighlights.map((text) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8.0),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.secondaryContainer.withOpacity(0.5),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Theme.of(context).colorScheme.outline.withOpacity(0.3)) // Subtle border
                    ),
                    child: SelectableText(text, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontStyle: FontStyle.italic, height: 1.4)),
                  ),
                );
              }).toList(),
            ),
          );
        },
      ),
    );
  }
}