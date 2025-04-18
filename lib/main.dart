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
import 'package:http/http.dart' as http; // Added for network requests

// Enum to represent library view types
enum LibraryViewType { grid, list }

// ====================================
// Book Class (No changes needed)
// ====================================
class Book {
  final int? id;
  final String title;
  final String filePath;
  final String lastLocatorJson;
  final int totalReadingTime; // In seconds
  final Map<String, List<String>> highlights;
  final String? coverImagePath;
  final String? openLibraryKey; // Added to potentially store OL key

  const Book({
    this.id,
    required this.title,
    required this.filePath,
    this.lastLocatorJson = '{}',
    this.totalReadingTime = 0,
    this.highlights = const {},
    this.coverImagePath,
    this.openLibraryKey, // Added
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
    'openLibraryKey': openLibraryKey, // Added
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
      openLibraryKey: map['openLibraryKey'] as String?, // Added
    );
  }

  Book copyWith({
    int? id, String? title, String? filePath, String? lastLocatorJson,
    int? totalReadingTime, Map<String, List<String>>? highlights, String? coverImagePath, String? openLibraryKey, // Added
  }) => Book(
    id: id ?? this.id,
    title: title ?? this.title,
    filePath: filePath ?? this.filePath,
    lastLocatorJson: lastLocatorJson ?? this.lastLocatorJson,
    totalReadingTime: totalReadingTime ?? this.totalReadingTime,
    highlights: highlights ?? this.highlights,
    coverImagePath: coverImagePath ?? this.coverImagePath,
    openLibraryKey: openLibraryKey ?? this.openLibraryKey, // Added
  );
}

// ====================================
// DatabaseHelper Class (Updated for new DB version and field)
// ====================================
class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  static Database? _database;
  static const int _dbVersion = 3; // Incremented DB version
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
      onCreate: (db, version) async {
        print("Creating database table 'books' version $version");
        await db.execute(
          'CREATE TABLE books(id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT, filePath TEXT, lastLocatorJson TEXT, totalReadingTime INTEGER DEFAULT 0, highlights TEXT DEFAULT \'{}\', coverImagePath TEXT)',
        );
        // Add openLibraryKey column if creating version 3 directly
        if (version >= 3) {
          await db.execute('ALTER TABLE books ADD COLUMN openLibraryKey TEXT');
          print("Column 'openLibraryKey' added during creation (v$version).");
        }
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        print("Upgrading database from version $oldVersion to $newVersion");
        if (oldVersion < 2) {
          try {
            var tableInfo = await db.rawQuery('PRAGMA table_info(books)');
            bool columnExists = tableInfo.any((column) => column['name'] == 'coverImagePath');
            if (!columnExists) {
              await db.execute('ALTER TABLE books ADD COLUMN coverImagePath TEXT');
              print("Column 'coverImagePath' added successfully.");
            } else {
              print("Column 'coverImagePath' already exists.");
            }
          } catch (e) { print("Error adding coverImagePath column: $e"); }
        }
        if (oldVersion < 3) { // Add upgrade logic for version 3
          try {
            var tableInfo = await db.rawQuery('PRAGMA table_info(books)');
            bool columnExists = tableInfo.any((column) => column['name'] == 'openLibraryKey');
            if (!columnExists) {
              await db.execute('ALTER TABLE books ADD COLUMN openLibraryKey TEXT');
              print("Column 'openLibraryKey' added successfully (upgrade to v3).");
            } else {
              print("Column 'openLibraryKey' already exists.");
            }
          } catch (e) { print("Error adding openLibraryKey column: $e"); }
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

  Future<void> updateBookHighlights(int bookId, Map<String, List<String>> newHighlights) async {
    try {
      final db = await database;
      await db.update(
        'books',
        {'highlights': json.encode(newHighlights)},
        where: 'id = ?',
        whereArgs: [bookId],
      );
      print("Updated highlights for book ID $bookId");
    } catch (e) {
      print("Error updating highlights for book ID $bookId: $e");
    }
  }

  Future<void> deleteBook(int id) async {
    try {
      final db = await database;
      await db.delete('books', where: 'id = ?', whereArgs: [id]);
      print("Deleted book record ID $id.");
    } catch (e) { print("Error deleting book ID $id: $e"); }
  }

  // Check if a book with the same Open Library key exists
  Future<bool> checkBookExistsByOLKey(String olKey) async {
    final db = await database;
    final result = await db.query(
      'books',
      where: 'openLibraryKey = ?',
      whereArgs: [olKey],
      limit: 1,
    );
    return result.isNotEmpty;
  }
}

// ====================================
// ReadingSettings Class (No changes needed)
// ====================================
class ReadingSettings extends ChangeNotifier {
  static const _themeModeKey = 'themeMode';
  static const _scrollDirectionKey = 'scrollDirection';
  static const _libraryViewTypeKey = 'libraryViewType';

  ThemeMode _themeMode = ThemeMode.system;
  EpubScrollDirection _scrollDirection = EpubScrollDirection.HORIZONTAL;
  LibraryViewType _libraryViewType = LibraryViewType.grid;

  ThemeMode get themeMode => _themeMode;
  EpubScrollDirection get scrollDirection => _scrollDirection;
  LibraryViewType get libraryViewType => _libraryViewType;

  ReadingSettings() { loadSettings(); }

  Future<void> loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedThemeModeString = prefs.getString(_themeModeKey);
      _themeMode = ThemeMode.values.firstWhere((e) => e.toString() == savedThemeModeString, orElse: () => ThemeMode.system);
      final savedDirectionName = prefs.getString(_scrollDirectionKey);
      _scrollDirection = EpubScrollDirection.values.firstWhere((e) => e.name == savedDirectionName, orElse: () => EpubScrollDirection.HORIZONTAL);
      final savedViewTypeName = prefs.getString(_libraryViewTypeKey);
      _libraryViewType = LibraryViewType.values.firstWhere((e) => e.name == savedViewTypeName, orElse: () => LibraryViewType.grid);
      print("Settings loaded: Theme=$_themeMode, Scroll=$_scrollDirection, View=$_libraryViewType");
      notifyListeners();
    } catch (e) {
      print("Error loading settings: $e");
      _themeMode = ThemeMode.system;
      _scrollDirection = EpubScrollDirection.HORIZONTAL;
      _libraryViewType = LibraryViewType.grid;
      notifyListeners();
    }
  }

  void updateSetting(String key, dynamic value) {
    bool changed = false;
    switch (key) {
      case _themeModeKey:
        if (_themeMode != value && value is ThemeMode) { _themeMode = value; changed = true; print("ThemeMode updated to: $_themeMode"); }
        break;
      case _scrollDirectionKey:
        if (_scrollDirection != value && value is EpubScrollDirection) { _scrollDirection = value; changed = true; print("Scroll Direction updated to: $_scrollDirection"); }
        break;
      case _libraryViewTypeKey:
        if (_libraryViewType != value && value is LibraryViewType) { _libraryViewType = value; changed = true; print("Library View Type updated to: $_libraryViewType"); }
        break;
    }
    if (changed) { _saveSettings(); notifyListeners(); }
  }

  Future<void> _saveSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await Future.wait([
        prefs.setString(_themeModeKey, _themeMode.toString()),
        prefs.setString(_scrollDirectionKey, _scrollDirection.name),
        prefs.setString(_libraryViewTypeKey, _libraryViewType.name),
      ]);
      print("Settings saved successfully.");
    } catch (e) { print("Error saving settings: $e"); }
  }
}

// ====================================
// ReadingTimeTracker Class (No changes needed)
// ====================================
class ReadingTimeTracker {
  final int bookId;
  final DatabaseHelper databaseHelper;
  final VoidCallback? onTimeSaved;
  DateTime? _startTime;
  Timer? _timer;
  int _sessionSeconds = 0;

  ReadingTimeTracker({required this.bookId, required this.databaseHelper, this.onTimeSaved});

  void startTracking() {
    if (_timer?.isActive ?? false) return;
    _startTime = DateTime.now();
    _sessionSeconds = 0;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) { _sessionSeconds++; });
    print("Started time tracking for book ID $bookId.");
  }

  Future<void> stopAndSaveTracking() async {
    if (!(_timer?.isActive ?? false)) { if (_startTime == null && _sessionSeconds == 0) return; print("DEBUG: Tracker timer for $bookId inactive, session time: $_sessionSeconds. Attempting save."); }
    _timer?.cancel(); _timer = null;
    final int recordedSessionSeconds = _sessionSeconds;
    final bool wasTracking = _startTime != null;
    _resetTrackingState();
    print("DEBUG: stopAndSaveTracking called for book ID $bookId. Recorded Session Seconds: $recordedSessionSeconds, Was Tracking: $wasTracking");
    if (wasTracking && recordedSessionSeconds > 0) {
      print("DEBUG: Saving time for book ID $bookId. Session: $recordedSessionSeconds seconds.");
      try { await databaseHelper.updateBookProgressFields(bookId, addedReadingTime: recordedSessionSeconds); print("DEBUG: Time save successful for book ID $bookId."); onTimeSaved?.call(); }
      catch (e) { print("Error saving reading time for book ID $bookId: $e"); }
    } else if (wasTracking) { print("Time tracking stopped for book ID $bookId, but no time recorded."); }
    else { print("DEBUG: stopAndSaveTracking called for book ID $bookId, but wasTracking was false."); }
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

// ====================================
// Main Function (Updated to ensure settings are loaded)
// ====================================
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final readingSettings = ReadingSettings();
  // No need to await loadSettings() here, it's called in the constructor
  // and the Consumer/Provider handles updates.

  runApp(
    ChangeNotifierProvider.value(
      value: readingSettings,
      child: const EpubReaderApp(),
    ),
  );
}


// ====================================
// EpubReaderApp Widget (No changes needed)
// ====================================
class EpubReaderApp extends StatelessWidget {
  const EpubReaderApp({Key? key}) : super(key: key);
  @override
  Widget build(BuildContext context) {
    final readingSettings = context.watch<ReadingSettings>();
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Flutter EPUB Reader',
      theme: ThemeData( useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo, brightness: Brightness.light), cardTheme: CardTheme( elevation: 1.0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 5) ) ),
      darkTheme: ThemeData( useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo, brightness: Brightness.dark), cardTheme: CardTheme( elevation: 1.0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 5) ) ),
      themeMode: readingSettings.themeMode,
      home: const LibraryScreen(),
    );
  }
}


// ====================================
// LibraryScreen Widget (Updated with Search Action)
// ====================================
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
  void dispose() { _locatorSubscription?.cancel(); _timeTracker?.stopAndSaveTracking().then((_) => print("Tracker stopped on dispose.")); super.dispose(); }

  Future<void> _loadBooks() async {
    if (!mounted) return;
    await _timeTracker?.stopAndSaveTracking(); _timeTracker = null;
    setState(() { isLoading = true; });
    try {
      final loadedBooks = await _databaseHelper.getBooks();
      if (mounted) { setState(() { books = loadedBooks; isLoading = false; }); }
    } catch (e, stackTrace) {
      print("Error loading library: $e\n$stackTrace");
      if (mounted) { setState(() { isLoading = false; books = []; }); ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error loading library.'), backgroundColor: Colors.red)); }
    }
  }

  // Updated function to handle both local file picking and online search
  void _addBook() {
    showModalBottomSheet(
      context: context,
      builder: (BuildContext context) {
        return SafeArea(
          child: Wrap(
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.file_upload),
                title: const Text('Import Local EPUB File'),
                onTap: () {
                  Navigator.pop(context); // Close bottom sheet
                  _pickAndImportBook();
                },
              ),
              ListTile(
                leading: const Icon(Icons.travel_explore),
                title: const Text('Search Open Library'),
                onTap: () {
                  Navigator.pop(context); // Close bottom sheet
                  _navigateToOpenLibrarySearch();
                },
              ),
            ],
          ),
        );
      },
    );
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

        // Prevent duplicate imports based on file path
        final currentBooks = await _databaseHelper.getBooks();
        if (currentBooks.any((book) => book.filePath == newPath)) {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Book already in library.')));
          setState(() => isLoading = false); return;
        }

        // Simple cover image logic (can be expanded)
        String? coverImagePath;
        String bookNameWithoutExt = path.basenameWithoutExtension(originalFileName);
        if (bookNameWithoutExt.toLowerCase().contains('discourses')) { coverImagePath = 'assets/images/discourses_selected_cover.png'; }
        else if (bookNameWithoutExt.toLowerCase().contains('designing your life')) { coverImagePath = 'assets/images/designing your life.png'; }
        else if (bookNameWithoutExt.toLowerCase().contains('republic')) { coverImagePath = 'assets/images/the republic.png'; }

        await sourceFile.copy(newPath);
        Book newBook = Book(
          title: originalFileName.replaceAll(RegExp(r'\.epub$', caseSensitive: false), ''),
          filePath: newPath, coverImagePath: coverImagePath,
        );
        await _databaseHelper.insertBook(newBook);
        await _loadBooks(); // Reload library to show the new book
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error importing book: ${e.toString()}')));
        setState(() => isLoading = false);
      }
    } else {
      if (mounted) setState(() => isLoading = false); // Reset loading state if picker was cancelled
    }
  }


  void _openReader(Book book) async {
    if (book.id == null || book.filePath.isEmpty) { print("Error: Book ID or filePath is invalid."); if(mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Cannot open book: Invalid data.'))); return; }
    final file = File(book.filePath);
    if (!await file.exists()) { print("Error: Book file not found at ${book.filePath}"); if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: Book file not found for "${book.title}". Please re-import.'))); return; }
    await _timeTracker?.stopAndSaveTracking(); _timeTracker = null;
    _timeTracker = ReadingTimeTracker( bookId: book.id!, databaseHelper: _databaseHelper, onTimeSaved: () { if (mounted) _updateLocalBookData(book.id!); } );
    try {
      final readingSettings = Provider.of<ReadingSettings>(context, listen: false);
      final isDarkMode = Theme.of(context).brightness == Brightness.dark;
      print("Opening EPUB: ${book.filePath}"); print("Reader Settings - Scroll: ${readingSettings.scrollDirection}, NightMode: $isDarkMode");
      VocsyEpub.setConfig( themeColor: Theme.of(context).colorScheme.primary, identifier: "book_${book.id}", scrollDirection: readingSettings.scrollDirection, allowSharing: true, enableTts: false, nightMode: isDarkMode );
      EpubLocator? lastKnownLocator;
      if (book.lastLocatorJson.isNotEmpty && book.lastLocatorJson != '{}') { try { lastKnownLocator = EpubLocator.fromJson(json.decode(book.lastLocatorJson)); } catch (e) { print("Error decoding locator for ${book.title}: $e."); } }
      _setupLocatorListener(book.id!);
      VocsyEpub.open( book.filePath, lastLocation: lastKnownLocator );
      _timeTracker!.startTracking();
    } catch (e, stackTrace) { print("CRITICAL Error during VocsyEpub open: $e\n$stackTrace"); if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error opening EPUB: ${e.toString()}'), backgroundColor: Colors.red)); await _timeTracker?.stopAndSaveTracking(); _timeTracker = null; _locatorSubscription?.cancel(); _locatorSubscription = null; }
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
          bool changed = books[bookIndex].lastLocatorJson != updatedDbBook.lastLocatorJson || books[bookIndex].totalReadingTime != updatedDbBook.totalReadingTime || books[bookIndex].highlights != updatedDbBook.highlights;
          if (changed && mounted) { setState(() { books[bookIndex] = updatedDbBook; }); print("LibraryScreen: Updated local book data for ID $bookId."); }
          else { print("LibraryScreen: No local data change detected for ID $bookId."); }
        }
      }
    } catch(e) { print("LibraryScreen: Error updating local book data: $e"); }
  }

  void _setupLocatorListener(int bookId) {
    print("Setting up locator listener for book ID $bookId");
    _locatorSubscription?.cancel();
    _locatorSubscription = VocsyEpub.locatorStream.listen(
          (locatorData) async {
        print("Locator Received for $bookId: $locatorData");
        String? locatorJsonString;
        if (locatorData is String) { locatorJsonString = locatorData; }
        else if (locatorData is Map) { try { locatorJsonString = json.encode(locatorData); } catch (e) { print("Listener Error encoding map for $bookId: $e"); } }
        if (locatorJsonString != null) { if (locatorJsonString != '{}') { await _updateBookProgress(bookId, locatorJsonString); } else { print("Listener Info: Received empty locator '{}' for $bookId, skipping update."); } }
        else { print("Listener Error: Unrecognized locator format for $bookId: $locatorData"); }
      },
      onError: (error) { print("DEBUG: Listener Error for $bookId: $error. Attempting to stop/save timer."); _timeTracker?.stopAndSaveTracking(); _timeTracker = null; },
      onDone: () { print("DEBUG: Listener Done for $bookId. Attempting to stop/save timer."); _timeTracker?.stopAndSaveTracking().then((_) => _timeTracker = null); _locatorSubscription?.cancel(); _locatorSubscription = null; },
      cancelOnError: true,
    );
  }

  Future<void> _updateBookProgress(int bookId, String newLocatorJson) async {
    if (!mounted) return;
    try {
      final bookIndex = books.indexWhere((b) => b.id == bookId);
      if (bookIndex != -1 && books[bookIndex].lastLocatorJson == newLocatorJson) { return; }
      await _databaseHelper.updateBookProgressFields(bookId, newLocatorJson: newLocatorJson);
      _updateLocalBookData(bookId);
    } catch (e, stackTrace) { print("Error saving progress for $bookId: $e\n$stackTrace"); }
  }

  void _navigateToStatsScreen(Book book) async {
    if (!mounted) return; print("Navigating to Stats for book ID ${book.id}");
    Book freshBook = book;
    if (book.id != null) { try { final db = await _databaseHelper.database; final maps = await db.query('books', where: 'id = ?', whereArgs: [book.id], limit: 1); if (maps.isNotEmpty) { freshBook = Book.fromMap(maps.first); print("Fetched fresh data for book ID ${book.id} before StatsScreen."); } } catch (e) { print("Error fetching fresh book data for StatsScreen: $e"); } }
    if (!mounted) return;
    final result = await Navigator.push( context, MaterialPageRoute( builder: (context) => StatsScreen( book: freshBook, onDeleteRequested: () { if(mounted) _confirmAndDeleteBook(freshBook); }, ) ), );
    if (mounted && freshBook.id != null && result != 'deleted') { _updateLocalBookData(freshBook.id!); }
  }

  void _confirmAndDeleteBook(Book book) {
    if (!mounted) return;
    if (_timeTracker?.bookId == book.id) { _timeTracker?.stopAndSaveTracking(); _timeTracker = null; print("Stopped tracker for book ID ${book.id} due to delete confirmation."); }
    showDialog( context: context, barrierDismissible: false, builder: (BuildContext ctx) {
      return AlertDialog( title: const Text('Delete Book?'), content: Text('Are you sure you want to permanently delete "${book.title}"? This cannot be undone.'), actions: <Widget>[ TextButton( child: const Text('Cancel'), onPressed: () => Navigator.of(ctx).pop() ), TextButton( style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error), child: const Text('Delete'), onPressed: () async { Navigator.of(ctx).pop(); if (!mounted) return; await _deleteBook(book); if (mounted && Navigator.canPop(context)) { Navigator.of(context).pop('deleted'); } }, ), ], ); }, );
  }

  Future<void> _deleteBook(Book book, {bool showSnackbar = true}) async {
    print("Deleting book ID ${book.id}: ${book.title}");
    if (book.id == null) { print("Error: Cannot delete book with null ID."); return; }
    if (mounted && !isLoading) setState(() => isLoading = true);
    try {
      if (_timeTracker?.bookId == book.id) { await _timeTracker?.stopAndSaveTracking(); _timeTracker = null; print("Stopped tracker for book ID ${book.id} during deletion."); }
      if (_locatorSubscription != null && _timeTracker?.bookId == book.id ) { _locatorSubscription?.cancel(); _locatorSubscription = null; print("Cancelled locator listener for book ID ${book.id} during deletion."); }
      final file = File(book.filePath);
      if (await file.exists()) { await file.delete(); print("Deleted file: ${book.filePath}"); } else { print("File not found for deletion: ${book.filePath}"); }
      await _databaseHelper.deleteBook(book.id!);
      await _loadBooks(); // Reloads and sets isLoading to false
      if (mounted && showSnackbar) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('"${book.title}" deleted.'))); }
    } catch (e, stackTrace) {
      print("Error deleting book ID ${book.id}: $e\n$stackTrace");
      if (mounted) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error deleting "${book.title}".'))); if (isLoading) setState(() { isLoading = false; }); }
    }
    // No finally needed as _loadBooks() handles isLoading
  }

  void _toggleViewType() {
    final settings = Provider.of<ReadingSettings>(context, listen: false);
    final currentType = settings.libraryViewType;
    final nextType = currentType == LibraryViewType.grid ? LibraryViewType.list : LibraryViewType.grid;
    settings.updateSetting(ReadingSettings._libraryViewTypeKey, nextType);
  }

  // Navigate to the Open Library Search Screen
  void _navigateToOpenLibrarySearch() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => OpenLibrarySearchScreen(databaseHelper: _databaseHelper)),
    );
    // If a book was downloaded, refresh the library
    if (result == 'downloaded') {
      _loadBooks();
    }
  }

  @override
  Widget build(BuildContext context) {
    final readingSettings = context.watch<ReadingSettings>();
    final currentViewType = readingSettings.libraryViewType;

    return Scaffold(
      appBar: AppBar(
        title: const Text('My EPUB Library'),
        actions: [
          IconButton( // Open Library Search Icon
            icon: const Icon(Icons.travel_explore_outlined),
            tooltip: 'Search Open Library',
            onPressed: _navigateToOpenLibrarySearch,
          ),
          IconButton(
            icon: Icon(currentViewType == LibraryViewType.grid ? Icons.view_list_outlined : Icons.grid_view_outlined),
            tooltip: currentViewType == LibraryViewType.grid ? 'Switch to List View' : 'Switch to Grid View',
            onPressed: _toggleViewType,
          ),
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
          : RefreshIndicator(
        onRefresh: _loadBooks,
        child: currentViewType == LibraryViewType.grid ? _buildBookGridView() : _buildBookListView(),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _pickAndImportBook, // Changed FAB action to only import local files
        tooltip: 'Import Local EPUB Book',
        child: const Icon(Icons.file_upload),
      ),
    );
  }

  Widget _buildEmptyLibraryView() { /* ... (keep existing code) ... */
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
            Text('Tap the + button to import an EPUB file, or use the search icon (🔍) to find books on Open Library.', textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey)),
          ],
        ),
      ),
    );
  }
  Widget _buildBookGridView() { /* ... (keep existing code) ... */
    final screenWidth = MediaQuery.of(context).size.width;
    final crossAxisCount = max(2,(screenWidth / 160).floor());
    final double gridPadding = 12.0;
    final double crossAxisSpacing = 12.0;
    final double mainAxisSpacing = 16.0;
    final double itemWidth = (screenWidth - (gridPadding * 2) - (crossAxisSpacing * (crossAxisCount - 1))) / crossAxisCount;
    final double coverHeight = itemWidth * 1.5;
    final double textHeight = 60;
    final double progressBarHeight = 8;
    final double itemHeight = coverHeight + textHeight + progressBarHeight;
    final double childAspectRatio = itemWidth / itemHeight;

    return GridView.builder(
      key: const PageStorageKey('libraryGrid'),
      padding: EdgeInsets.all(gridPadding),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        childAspectRatio: childAspectRatio,
        crossAxisSpacing: crossAxisSpacing,
        mainAxisSpacing: mainAxisSpacing,
      ),
      itemCount: books.length,
      itemBuilder: (context, index) {
        try {
          final book = books[index];
          final double progress = book.progression;

          return Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => _openReader(book),
              onLongPress: () { _navigateToStatsScreen(book); },
              borderRadius: BorderRadius.circular(8.0),
              child: Ink(
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  borderRadius: BorderRadius.circular(8.0),
                  boxShadow: [ BoxShadow( color: Colors.black.withOpacity(0.05), blurRadius: 4, offset: const Offset(0, 2), ), ],
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.start,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ClipRRect(
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(8.0)),
                      child: Container(
                        height: coverHeight,
                        width: double.infinity,
                        color: Theme.of(context).colorScheme.surfaceVariant,
                        child: (book.coverImagePath != null && book.coverImagePath!.isNotEmpty && File(book.coverImagePath!).existsSync()) // Check if local asset exists
                            ? Image.asset( book.coverImagePath!, fit: BoxFit.cover, errorBuilder: (ctx, err, st) => Center(child: Icon(Icons.menu_book, size: 50.0, color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.6)))) // Fallback icon
                            : (book.openLibraryKey != null && book.coverImagePath != null && book.coverImagePath!.startsWith('http')) // Check if it's a network image URL
                            ? Image.network( book.coverImagePath!, fit: BoxFit.cover, errorBuilder: (ctx, err, st) => Center(child: Icon(Icons.menu_book, size: 50.0, color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.6)))) // Fallback icon
                            : Center(child: Icon(Icons.menu_book, size: 50.0, color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.6))),
                      ),
                    ),
                    const SizedBox(height: 6.0),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8.0),
                      child: Text( book.title, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500, height: 1.3), ),
                    ),
                    const Spacer(),
                    if (progress > 0.0)
                      Padding(
                        padding: const EdgeInsets.only(left: 8.0, right: 8.0, bottom: 8.0, top: 4.0),
                        child: SizedBox( height: progressBarHeight, child: LinearProgressIndicator( value: progress, backgroundColor: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.5), valueColor: AlwaysStoppedAnimation<Color>(Theme.of(context).colorScheme.primary), borderRadius: BorderRadius.circular(progressBarHeight / 2), ), ),
                      )
                    else
                      SizedBox(height: progressBarHeight + 12.0), // Consistent height even without progress bar
                  ],
                ),
              ),
            ),
          );
        } catch (e, stackTrace) {
          print("Error in Grid itemBuilder $index: $e\n$stackTrace");
          return Container( color: Colors.red.shade100, child: const Center(child: Icon(Icons.error)) );
        }
      },
    );
  }
  Widget _buildBookListView() { /* ... (keep existing code) ... */
    final double listPadding = 8.0;
    final double coverSize = 60.0;

    return ListView.builder(
      key: const PageStorageKey('libraryList'),
      padding: EdgeInsets.all(listPadding),
      itemCount: books.length,
      itemBuilder: (context, index) {
        try {
          final book = books[index];
          final double progress = book.progression;

          return Card(
            margin: const EdgeInsets.symmetric(vertical: 5.0),
            elevation: 1.5,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            child: InkWell(
              onTap: () => _openReader(book),
              onLongPress: () => _navigateToStatsScreen(book),
              borderRadius: BorderRadius.circular(8.0),
              child: Padding(
                padding: const EdgeInsets.all(10.0),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6.0),
                      child: Container(
                        width: coverSize,
                        height: coverSize * 1.4,
                        color: Theme.of(context).colorScheme.surfaceVariant,
                        child: (book.coverImagePath != null && book.coverImagePath!.isNotEmpty && File(book.coverImagePath!).existsSync()) // Check if local asset exists
                            ? Image.asset( book.coverImagePath!, fit: BoxFit.cover, errorBuilder: (ctx, err, st) => Center(child: Icon(Icons.menu_book, size: 30.0, color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.6)))) // Fallback icon
                            : (book.openLibraryKey != null && book.coverImagePath != null && book.coverImagePath!.startsWith('http')) // Check if it's a network image URL
                            ? Image.network( book.coverImagePath!, fit: BoxFit.cover, errorBuilder: (ctx, err, st) => Center(child: Icon(Icons.menu_book, size: 30.0, color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.6)))) // Fallback icon
                            : Center(child: Icon(Icons.menu_book, size: 30.0, color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.6))),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center, // Center vertically
                        children: [
                          Text( book.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w500), ),
                          if (progress > 0.0) ...[
                            const SizedBox(height: 8),
                            LinearProgressIndicator( value: progress, backgroundColor: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.5), valueColor: AlwaysStoppedAnimation<Color>(Theme.of(context).colorScheme.primary), minHeight: 5, borderRadius: BorderRadius.circular(2.5), ),
                          ] else const SizedBox(height: 13), // Add space to align text even without progress bar
                        ],
                      ),
                    ),
                    // Add PopupMenuButton for options like 'Delete'
                    PopupMenuButton<String>(
                      icon: Icon(Icons.more_vert, color: Theme.of(context).iconTheme.color?.withOpacity(0.7)),
                      tooltip: 'More options',
                      onSelected: (String result) {
                        switch (result) {
                          case 'delete':
                            _confirmAndDeleteBook(book);
                            break;
                          case 'stats':
                            _navigateToStatsScreen(book);
                            break;
                        }
                      },
                      itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                        const PopupMenuItem<String>(
                          value: 'stats',
                          child: ListTile(leading: Icon(Icons.info_outline), title: Text('Details')),
                        ),
                        const PopupMenuItem<String>(
                          value: 'delete',
                          child: ListTile(leading: Icon(Icons.delete_outline, color: Colors.red), title: Text('Delete', style: TextStyle(color: Colors.red))),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        } catch (e, stackTrace) {
          print("Error in List itemBuilder $index: $e\n$stackTrace");
          return ListTile( leading: const Icon(Icons.error, color: Colors.red), title: const Text('Error loading item'), subtitle: Text(e.toString()), );
        }
      },
    );
  }

} // End of _LibraryScreenState


// ====================================
// OpenLibrarySearchScreen Widget (NEW)
// ====================================
class OpenLibrarySearchScreen extends StatefulWidget {
  final DatabaseHelper databaseHelper; // Pass DB helper for adding books

  const OpenLibrarySearchScreen({Key? key, required this.databaseHelper}) : super(key: key);

  @override
  _OpenLibrarySearchScreenState createState() => _OpenLibrarySearchScreenState();
}

class _OpenLibrarySearchScreenState extends State<OpenLibrarySearchScreen> {
  final TextEditingController _searchController = TextEditingController();
  List<Map<String, dynamic>> _searchResults = [];
  bool _isLoading = false;
  String _loadingMessage = ''; // To show download progress/status

  // Sanitize filename
  String _sanitizeFilename(String input) {
    // Remove characters that are typically invalid in filenames across platforms
    // Keep spaces and hyphens, replace others with underscore
    String sanitized = input.replaceAll(RegExp(r'[\\/:*?"<>|]+'), '_');
    // Limit length to avoid issues
    return sanitized.length > 100 ? sanitized.substring(0, 100) : sanitized;
  }


  Future<void> _searchOpenLibrary(String query) async {
    if (query.isEmpty) return;
    setState(() { _isLoading = true; _searchResults = []; _loadingMessage = 'Searching...'; });

    // Basic search fields, adding 'ia' (Internet Archive ID) and 'has_fulltext'
    // 'ebook_access' tells us if it's borrowable, public, etc.
    // 'cover_i' for cover image ID
    // 'key' for the book's unique Open Library ID (e.g., /books/OL...M)
    final url = Uri.parse('https://openlibrary.org/search.json?q=${Uri.encodeComponent(query)}&fields=key,title,author_name,cover_i,has_fulltext,ia,ebook_access&limit=20');

    try {
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final docs = data['docs'] as List? ?? [];
        setState(() {
          _searchResults = List<Map<String, dynamic>>.from(docs.map((doc) => doc as Map<String, dynamic>));
          _isLoading = false;
          _loadingMessage = '';
          if (_searchResults.isEmpty) {
            _loadingMessage = 'No results found.';
          }
        });
      } else {
        print('Error searching Open Library: ${response.statusCode}');
        if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error searching: ${response.statusCode}'), backgroundColor: Colors.orange));
        setState(() { _isLoading = false; _loadingMessage = 'Search Error ${response.statusCode}'; });
      }
    } catch (e) {
      print('Error searching Open Library: $e');
      if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Network error during search.'), backgroundColor: Colors.red));
      setState(() { _isLoading = false; _loadingMessage = 'Network Error'; });
    }
  }

  // Function to attempt download and import
  Future<void> _downloadAndImportBook(Map<String, dynamic> bookData) async {
    final String title = bookData['title'] ?? 'Unknown Title';
    final String? olKey = bookData['key'] as String?; // e.g., /books/OL...M
    final String? coverId = bookData['cover_i']?.toString();
    final List<dynamic>? iaIdentifiers = bookData['ia'] as List<dynamic>?; // Can be multiple
    final String ebookAccess = bookData['ebook_access'] ?? 'no_ebook'; // 'public', 'borrowable', 'printdisabled', 'no_ebook'

    if (olKey == null) {
      if(mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Book data is missing required key.'), backgroundColor: Colors.orange));
      return;
    }

    // Check if book already exists
    final bool exists = await widget.databaseHelper.checkBookExistsByOLKey(olKey);
    if (exists) {
      if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('"${title}" is already in your library.')));
      return;
    }

    // Prioritize 'public' access and presence of an Internet Archive ID
    if ((ebookAccess == 'public' || bookData['has_fulltext'] == true) && iaIdentifiers != null && iaIdentifiers.isNotEmpty) {
      final String iaId = iaIdentifiers.first.toString(); // Take the first IA identifier
      // Construct potential download URL (common pattern, but NOT guaranteed)
      final String downloadUrl = 'https://archive.org/download/$iaId/$iaId.epub';
      final String coverUrl = coverId != null ? 'https://covers.openlibrary.org/b/id/$coverId-L.jpg' : ''; // Large cover


      setState(() { _isLoading = true; _loadingMessage = 'Downloading "$title"...'; });

      try {
        Directory appDocDir = await getApplicationDocumentsDirectory();
        String booksDir = path.join(appDocDir.path, 'epubs');
        await Directory(booksDir).create(recursive: true);

        // Use OL Key for a more unique filename if possible, otherwise sanitize title
        String safeFileNameBase = olKey.split('/').last; // Get 'OL...M' part
        String fileName = '$safeFileNameBase.epub';
        String newPath = path.join(booksDir, fileName);

        final response = await http.get(Uri.parse(downloadUrl)).timeout(const Duration(seconds: 60)); // Add timeout

        if (response.statusCode == 200 && (response.headers['content-type']?.contains('epub') ?? false) ) {
          File file = File(newPath);
          await file.writeAsBytes(response.bodyBytes);

          Book newBook = Book(
            title: title,
            filePath: newPath,
            coverImagePath: coverUrl, // Store URL for cover
            openLibraryKey: olKey, // Store the Open Library Key
          );
          await widget.databaseHelper.insertBook(newBook);

          setState(() { _isLoading = false; _loadingMessage = ''; });
          if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Successfully downloaded "$title"!'), backgroundColor: Colors.green));
          Navigator.pop(context, 'downloaded'); // Signal success to LibraryScreen

        } else {
          print('Download failed: Status ${response.statusCode}, Content-Type: ${response.headers['content-type']}');
          setState(() { _isLoading = false; _loadingMessage = ''; });
          if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('EPUB download failed for "$title". It might not be available in this format.'), backgroundColor: Colors.orange, duration: Duration(seconds: 5)));
        }
      } catch (e) {
        print('Error downloading or importing book: $e');
        setState(() { _isLoading = false; _loadingMessage = ''; });
        if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error downloading "$title": ${e.toString()}'), backgroundColor: Colors.red));
      }

    } else {
      // Inform user if direct download is unlikely
      String reason = '';
      switch (ebookAccess) {
        case 'borrowable':
        case 'printdisabled':
          reason = 'This book is only available to borrow.';
          break;
        case 'no_ebook':
          reason = 'No EPUB format available for this book.';
          break;
        default:
          reason = 'Direct EPUB download not available for this book.';
      }
      if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(reason), backgroundColor: Colors.grey));
    }
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Search Open Library'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                labelText: 'Search by Title, Author, or ISBN',
                suffixIcon: IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: () => _searchOpenLibrary(_searchController.text),
                ),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onSubmitted: (value) => _searchOpenLibrary(value),
            ),
          ),
          if (_isLoading)
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(width: 16),
                    Expanded(child: Text(_loadingMessage)), // Show status message
                  ]
              ),
            ),
          Expanded(
            child: ListView.builder(
              itemCount: _searchResults.length,
              itemBuilder: (context, index) {
                final book = _searchResults[index];
                final title = book['title'] ?? 'No Title';
                final authors = (book['author_name'] as List?)?.join(', ') ?? 'Unknown Author';
                final coverId = book['cover_i']?.toString();
                final coverUrl = coverId != null ? 'https://covers.openlibrary.org/b/id/$coverId-M.jpg' : null; // Medium cover
                final ebookAccess = book['ebook_access'] ?? 'no_ebook';
                final hasIa = book['ia'] != null && (book['ia'] as List).isNotEmpty;
                final bool canAttemptDownload = (ebookAccess == 'public' || book['has_fulltext'] == true) && hasIa;

                return ListTile(
                  leading: coverUrl != null
                      ? Image.network(coverUrl, width: 40, fit: BoxFit.contain, errorBuilder: (c, e, s) => const Icon(Icons.book_outlined))
                      : const Icon(Icons.book_outlined, size: 40),
                  title: Text(title),
                  subtitle: Text(authors),
                  trailing: IconButton(
                    icon: Icon(
                      Icons.download_for_offline_outlined,
                      // Dim the icon if download is unlikely
                      color: canAttemptDownload ? Theme.of(context).colorScheme.primary : Colors.grey,
                    ),
                    tooltip: canAttemptDownload ? 'Download EPUB' : 'EPUB not directly available',
                    onPressed: canAttemptDownload ? () => _downloadAndImportBook(book) : null, // Disable button if cannot download
                  ),
                  onTap: () {
                    // Maybe show details on tap in the future?
                    if (canAttemptDownload) {
                      _downloadAndImportBook(book);
                    } else {
                      String reason = '';
                      switch (ebookAccess) {
                        case 'borrowable':
                        case 'printdisabled':
                          reason = 'Only available to borrow via Internet Archive.';
                          break;
                        case 'no_ebook':
                          reason = 'No known EPUB format.';
                          break;
                        default:
                          reason = 'Direct EPUB download not available.';
                      }
                      if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(reason), backgroundColor: Colors.grey));
                    }
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}


// ====================================
// StatsScreen Widget (Updated for network/asset cover image)
// ====================================
class StatsScreen extends StatelessWidget {
  final Book book;
  final VoidCallback onDeleteRequested;

  const StatsScreen({ Key? key, required this.book, required this.onDeleteRequested, }) : super(key: key);

  String _formatDurationLocal(Duration? duration) => ReadingTimeTracker.formatDuration(duration);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar( title: Text(book.title, overflow: TextOverflow.ellipsis), backgroundColor: Colors.transparent, elevation: 0, ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: ListView(
          children: [
            // Display cover image (handles local asset, network URL, or fallback)
            Center(
              child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.35),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12.0),
                    child: (book.coverImagePath != null && book.coverImagePath!.isNotEmpty && File(book.coverImagePath!).existsSync()) // Check if local asset exists
                        ? Image.asset( book.coverImagePath!, fit: BoxFit.contain, errorBuilder: (ctx, err, st) => const Icon(Icons.error, size: 60)) // Fallback
                        : (book.openLibraryKey != null && book.coverImagePath != null && book.coverImagePath!.startsWith('http')) // Check if network URL
                        ? Image.network( book.coverImagePath!, fit: BoxFit.contain, errorBuilder: (ctx, err, st) => const Icon(Icons.menu_book, size: 80, color: Colors.grey)) // Fallback icon
                        : Icon(Icons.menu_book, size: 100, color: Theme.of(context).colorScheme.primary.withOpacity(0.5)), // Default fallback
                  )
              ),
            ),
            const SizedBox(height: 24),


            Card(
              elevation: 2, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12.0, horizontal: 16.0),
                  child: Column( // Use Column for multiple stats
                    children: [
                      _buildStatRow(context, Icons.timer_outlined, 'Total Time Read', _formatDurationLocal(Duration(seconds: book.totalReadingTime))),
                      if (book.progression > 0) ...[
                        const Divider(height: 1),
                        _buildStatRow(context, Icons.data_usage, 'Progress', '${(book.progression * 100).toStringAsFixed(1)}%'),
                      ],
                      if (book.openLibraryKey != null) ...[
                        const Divider(height: 1),
                        _buildStatRow(context, Icons.link, 'Source', 'Open Library\n(${book.openLibraryKey})'),
                      ]
                    ],
                  )
              ),
            ),

            const SizedBox(height: 24),

            OutlinedButton.icon(
              icon: Icon(Icons.delete_forever_outlined, color: Theme.of(context).colorScheme.error),
              label: Text('Delete Book Permanently', style: TextStyle(color: Theme.of(context).colorScheme.error)),
              style: OutlinedButton.styleFrom( side: BorderSide(color: Theme.of(context).colorScheme.error.withOpacity(0.5)), minimumSize: const Size(double.infinity, 44), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)) ),
              onPressed: onDeleteRequested,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatRow(BuildContext context, IconData icon, String label, String value) { /* ... (keep existing code) ... */
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(icon, color: Theme.of(context).colorScheme.primary, size: 22),
          const SizedBox(width: 16),
          Text('$label:', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(width: 8),
          Expanded(
              child: Text(
                value,
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.end,
                softWrap: true,
                overflow: TextOverflow.fade,
              )
          ),
        ],
      ),
    );
  }
}


// ====================================
// SettingsScreen Widget (No changes needed)
// ====================================
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
              _buildThemeSetting(context, readingSettings),
              const Divider(indent: 16, endIndent: 16),
              _buildLibraryViewSetting(context, readingSettings), // Added Library View Option
              const Divider(indent: 16, endIndent: 16),
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

  Widget _buildSectionHeader(BuildContext context, String title) { /* ... (keep existing code) ... */
    return Padding(
      padding: const EdgeInsets.only(left: 16.0, right: 16.0, top: 20.0, bottom: 8.0),
      child: Text( title, style: Theme.of(context).textTheme.titleMedium?.copyWith( color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600, ), ),
    );
  }
  Widget _buildThemeSetting(BuildContext context, ReadingSettings settings) { /* ... (keep existing code) ... */
    return ListTile(
      leading: Icon( settings.themeMode == ThemeMode.light ? Icons.wb_sunny_outlined : settings.themeMode == ThemeMode.dark ? Icons.nightlight_outlined : Icons.brightness_auto_outlined ),
      title: const Text('App Theme'),
      trailing: DropdownButton<ThemeMode>(
        value: settings.themeMode,
        underline: Container(), borderRadius: BorderRadius.circular(8),
        items: const [ DropdownMenuItem(value: ThemeMode.system, child: Text('System Default')), DropdownMenuItem(value: ThemeMode.light, child: Text('Light')), DropdownMenuItem(value: ThemeMode.dark, child: Text('Dark')), ],
        onChanged: (value) { if (value != null) { settings.updateSetting(ReadingSettings._themeModeKey, value); } },
      ),
    );
  }
  Widget _buildScrollDirectionSetting(BuildContext context, ReadingSettings settings) { /* ... (keep existing code) ... */
    return ListTile(
      leading: const Icon(Icons.swap_horiz_outlined),
      title: const Text('Reader Scroll Direction'),
      trailing: DropdownButton<EpubScrollDirection>(
        value: settings.scrollDirection,
        underline: Container(), borderRadius: BorderRadius.circular(8),
        items: const [ DropdownMenuItem(value: EpubScrollDirection.HORIZONTAL, child: Text('Horizontal')), DropdownMenuItem(value: EpubScrollDirection.VERTICAL, child: Text('Vertical')), ],
        onChanged: (value) { if (value != null) { settings.updateSetting(ReadingSettings._scrollDirectionKey, value); } },
      ),
    );
  }
  Widget _buildLibraryViewSetting(BuildContext context, ReadingSettings settings) { // Added
    return ListTile(
      leading: const Icon(Icons.view_quilt_outlined),
      title: const Text('Library Default View'),
      trailing: DropdownButton<LibraryViewType>(
        value: settings.libraryViewType,
        underline: Container(),
        borderRadius: BorderRadius.circular(8),
        items: const [
          DropdownMenuItem(value: LibraryViewType.grid, child: Text('Grid View')),
          DropdownMenuItem(value: LibraryViewType.list, child: Text('List View')),
        ],
        onChanged: (value) {
          if (value != null) {
            settings.updateSetting(ReadingSettings._libraryViewTypeKey, value);
          }
        },
      ),
    );
  }
  Widget _buildAboutTile(BuildContext context) { /* ... (keep existing code) ... */
    String appVersion = '1.7.0-OL'; // Example version update
    return ListTile(
      leading: const Icon(Icons.info_outline),
      title: const Text('App Version'),
      subtitle: Text(appVersion),
      onTap: () {
        showAboutDialog( context: context, applicationName: 'Flutter EPUB Reader', applicationVersion: appVersion, applicationLegalese: '© 2024 Your Name/Company', children: [ const Padding( padding: EdgeInsets.only(top: 15), child: Text('A simple EPUB reader application built using Flutter. Now with Open Library search!') ) ], );
      },
    );
  }
}


// ====================================
// HighlightsScreen Widget (No changes needed)
// ====================================
class HighlightsScreen extends StatelessWidget {
  final Book book;
  const HighlightsScreen({Key? key, required this.book}) : super(key: key);

  Map<String, List<String>> _getValidHighlights() { try { if (book.highlights is Map) { final potentialMap = book.highlights; if (potentialMap.keys.every((k) => k is String) && potentialMap.values.every((v) => v is List && v.every((item) => item is String))) { return Map<String, List<String>>.from(potentialMap); } } } catch (e) { print("Error accessing or casting highlights map: $e");} return {}; }

  @override
  Widget build(BuildContext context) {
    final Map<String, List<String>> highlights = _getValidHighlights();
    final List<MapEntry<String, List<String>>> chapterEntries = highlights.entries .where((entry) => entry.value.isNotEmpty) .toList();
    return Scaffold(
      appBar: AppBar( title: Text('Highlights: ${book.title}', overflow: TextOverflow.ellipsis), ),
      body: chapterEntries.isEmpty
          ? Center( child: Padding( padding: const EdgeInsets.all(20.0), child: Text( 'No highlights saved for this book yet.', style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.grey), textAlign: TextAlign.center, ) ) )
          : ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 10.0, horizontal: 8.0),
        itemCount: chapterEntries.length,
        itemBuilder: (context, chapterIndex) {
          final entry = chapterEntries[chapterIndex];
          final String chapter = entry.key;
          final List<String> chapterHighlights = entry.value;
          if (chapterHighlights.isEmpty) return const SizedBox.shrink();
          return Card(
            margin: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4.0), elevation: 1, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            child: ExpansionTile(
              title: Text( chapter.isNotEmpty ? chapter : 'Chapter Highlights', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600) ),
              initiallyExpanded: true, childrenPadding: const EdgeInsets.only(left: 16, right: 16, bottom: 16, top: 0), tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), shape: const Border(),
              children: chapterHighlights.map((text) { return Padding( padding: const EdgeInsets.only(top: 10.0), child: Container( padding: const EdgeInsets.all(12), decoration: BoxDecoration( color: Theme.of(context).colorScheme.secondaryContainer.withOpacity(0.7), borderRadius: BorderRadius.circular(8), ), child: SelectableText( text.trim(), style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.4) ), ), ); }).toList(),
            ),
          );
        },
      ),
    );
  }
}