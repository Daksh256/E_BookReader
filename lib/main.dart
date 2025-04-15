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

// Enum to represent library view types
enum LibraryViewType { grid, list }

// ====================================
// Book Class
// ====================================
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

// ====================================
// DatabaseHelper Class
// ====================================
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
}

// ====================================
// ReadingSettings Class (with View Type)
// ====================================
class ReadingSettings extends ChangeNotifier {
  static const _themeModeKey = 'themeMode';
  static const _scrollDirectionKey = 'scrollDirection';
  static const _libraryViewTypeKey = 'libraryViewType'; // New key

  ThemeMode _themeMode = ThemeMode.system;
  EpubScrollDirection _scrollDirection = EpubScrollDirection.HORIZONTAL;
  LibraryViewType _libraryViewType = LibraryViewType.grid; // New field, default grid

  ThemeMode get themeMode => _themeMode;
  EpubScrollDirection get scrollDirection => _scrollDirection;
  LibraryViewType get libraryViewType => _libraryViewType; // New getter

  ReadingSettings() {
    loadSettings();
  }

  Future<void> loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Load ThemeMode
      final savedThemeModeString = prefs.getString(_themeModeKey);
      _themeMode = ThemeMode.values.firstWhere(
              (e) => e.toString() == savedThemeModeString,
          orElse: () => ThemeMode.system
      );

      // Load Scroll Direction
      final savedDirectionName = prefs.getString(_scrollDirectionKey);
      _scrollDirection = EpubScrollDirection.values.firstWhere(
            (e) => e.name == savedDirectionName,
        orElse: () => EpubScrollDirection.HORIZONTAL,
      );

      // Load Library View Type
      final savedViewTypeName = prefs.getString(_libraryViewTypeKey);
      _libraryViewType = LibraryViewType.values.firstWhere(
              (e) => e.name == savedViewTypeName,
          orElse: () => LibraryViewType.grid // Default to grid if not found
      );

      print("Settings loaded: Theme=$_themeMode, Scroll=$_scrollDirection, View=$_libraryViewType");
      notifyListeners(); // Notify once after all settings are loaded

    } catch (e) {
      print("Error loading settings: $e");
      // Set defaults on error
      _themeMode = ThemeMode.system;
      _scrollDirection = EpubScrollDirection.HORIZONTAL;
      _libraryViewType = LibraryViewType.grid;
      notifyListeners(); // Notify with defaults if error occurred
    }
  }


  void updateSetting(String key, dynamic value) {
    bool changed = false;
    switch (key) {
      case _themeModeKey:
        if (_themeMode != value && value is ThemeMode) {
          _themeMode = value;
          changed = true;
          print("ThemeMode updated to: $_themeMode");
        }
        break;
      case _scrollDirectionKey:
        if (_scrollDirection != value && value is EpubScrollDirection) {
          _scrollDirection = value;
          changed = true;
          print("Scroll Direction updated to: $_scrollDirection");
        }
        break;
    // Add case for Library View Type
      case _libraryViewTypeKey:
        if (_libraryViewType != value && value is LibraryViewType) {
          _libraryViewType = value;
          changed = true;
          print("Library View Type updated to: $_libraryViewType");
        }
        break;
    }
    if (changed) {
      _saveSettings();
      notifyListeners();
    }
  }

  Future<void> _saveSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await Future.wait([
        prefs.setString(_themeModeKey, _themeMode.toString()),
        prefs.setString(_scrollDirectionKey, _scrollDirection.name),
        // Save Library View Type using its name
        prefs.setString(_libraryViewTypeKey, _libraryViewType.name),
      ]);
      print("Settings saved successfully.");
    } catch (e) {
      print("Error saving settings: $e");
    }
  }
}

// ====================================
// ReadingTimeTracker Class
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
    if (_timer?.isActive ?? false) { return; }
    _startTime = DateTime.now();
    _sessionSeconds = 0;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) { _sessionSeconds++; });
    print("Started time tracking for book ID $bookId.");
  }

  Future<void> stopAndSaveTracking() async {
    if (!(_timer?.isActive ?? false)) {
      if(_startTime == null && _sessionSeconds == 0) return;
      print("DEBUG: Tracker timer for $bookId inactive, session time: $_sessionSeconds. Attempting save.");
    }
    _timer?.cancel(); _timer = null;
    final int recordedSessionSeconds = _sessionSeconds;
    final bool wasTracking = _startTime != null;
    _resetTrackingState();

    print("DEBUG: stopAndSaveTracking called for book ID $bookId. Recorded Session Seconds: $recordedSessionSeconds, Was Tracking: $wasTracking");

    if (wasTracking && recordedSessionSeconds > 0) {
      print("DEBUG: Saving time for book ID $bookId. Session: $recordedSessionSeconds seconds.");
      try {
        await databaseHelper.updateBookProgressFields(bookId, addedReadingTime: recordedSessionSeconds);
        print("DEBUG: Time save successful for book ID $bookId.");
        onTimeSaved?.call();
      } catch (e) { print("Error saving reading time for book ID $bookId: $e"); }
    } else if (wasTracking) {
      print("Time tracking stopped for book ID $bookId, but no time recorded.");
    } else {
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

// ====================================
// Main Function
// ====================================
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final readingSettings = ReadingSettings();
  await readingSettings.loadSettings(); // Ensure settings are loaded before building UI

  runApp(
    ChangeNotifierProvider.value(
      value: readingSettings,
      child: const EpubReaderApp(),
    ),
  );
}

// ====================================
// EpubReaderApp Widget
// ====================================
class EpubReaderApp extends StatelessWidget {
  const EpubReaderApp({Key? key}) : super(key: key);
  @override
  Widget build(BuildContext context) {
    final readingSettings = context.watch<ReadingSettings>();
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Flutter EPUB Reader',
      theme: ThemeData( // Light theme
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo, brightness: Brightness.light),
        cardTheme: CardTheme(
            elevation: 1.0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 5)
        ),
      ),
      darkTheme: ThemeData( // Dark theme
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo, brightness: Brightness.dark),
        cardTheme: CardTheme(
            elevation: 1.0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 5)
        ),
      ),
      themeMode: readingSettings.themeMode, // Use themeMode from provider
      home: const LibraryScreen(),
    );
  }
}

// ====================================
// LibraryScreen Widget (with View Toggle)
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
      print("Error loading library: $e\n$stackTrace");
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
        // TODO: Improve cover image handling
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
    } else {
      if (mounted) setState(() => isLoading = false);
    }
  }

  void _openReader(Book book) async {
    if (book.id == null || book.filePath.isEmpty) {
      print("Error: Book ID or filePath is invalid.");
      if(mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Cannot open book: Invalid data.')));
      return;
    }
    final file = File(book.filePath);
    if (!await file.exists()) {
      print("Error: Book file not found at ${book.filePath}");
      if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: Book file not found for "${book.title}". Please re-import.')));
      return;
    }

    await _timeTracker?.stopAndSaveTracking(); _timeTracker = null;

    _timeTracker = ReadingTimeTracker(
        bookId: book.id!, databaseHelper: _databaseHelper,
        onTimeSaved: () { if (mounted) _updateLocalBookData(book.id!); }
    );

    try {
      final readingSettings = Provider.of<ReadingSettings>(context, listen: false);
      final isDarkMode = Theme.of(context).brightness == Brightness.dark;

      print("Opening EPUB: ${book.filePath}");
      print("Reader Settings - Scroll: ${readingSettings.scrollDirection}, NightMode: $isDarkMode");

      VocsyEpub.setConfig(
          themeColor: Theme.of(context).colorScheme.primary, identifier: "book_${book.id}",
          scrollDirection: readingSettings.scrollDirection,
          allowSharing: true, enableTts: false, nightMode: isDarkMode
      );

      EpubLocator? lastKnownLocator;
      if (book.lastLocatorJson.isNotEmpty && book.lastLocatorJson != '{}') {
        try { lastKnownLocator = EpubLocator.fromJson(json.decode(book.lastLocatorJson)); }
        catch (e) { print("Error decoding locator for ${book.title}: $e."); }
      }

      _setupLocatorListener(book.id!);
      VocsyEpub.open( book.filePath, lastLocation: lastKnownLocator );
      _timeTracker!.startTracking();

    } catch (e, stackTrace) {
      print("CRITICAL Error during VocsyEpub open: $e\n$stackTrace");
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
              books[bookIndex].totalReadingTime != updatedDbBook.totalReadingTime ||
              books[bookIndex].highlights != updatedDbBook.highlights;
          if (changed && mounted) {
            setState(() { books[bookIndex] = updatedDbBook; });
            print("LibraryScreen: Updated local book data for ID $bookId.");
          } else {
            print("LibraryScreen: No local data change detected for ID $bookId.");
          }
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
        if (locatorData is String) {
          locatorJsonString = locatorData;
        } else if (locatorData is Map) {
          try {
            locatorJsonString = json.encode(locatorData);
          } catch (e) {
            print("Listener Error encoding map for $bookId: $e");
          }
        }

        if (locatorJsonString != null) {
          if (locatorJsonString != '{}') {
            await _updateBookProgress(bookId, locatorJsonString);
          } else {
            print("Listener Info: Received empty locator '{}' for $bookId, skipping update.");
          }
        } else {
          print("Listener Error: Unrecognized locator format for $bookId: $locatorData");
        }
      },
      onError: (error) {
        print("DEBUG: Listener Error for $bookId: $error. Attempting to stop/save timer.");
        _timeTracker?.stopAndSaveTracking(); _timeTracker = null;
      },
      onDone: () {
        print("DEBUG: Listener Done for $bookId. Attempting to stop/save timer.");
        _timeTracker?.stopAndSaveTracking().then((_) => _timeTracker = null);
        _locatorSubscription?.cancel(); _locatorSubscription = null;
      },
      cancelOnError: true,
    );
  }


  Future<void> _updateBookProgress(int bookId, String newLocatorJson) async {
    if (!mounted) return;
    try {
      final bookIndex = books.indexWhere((b) => b.id == bookId);
      if (bookIndex != -1 && books[bookIndex].lastLocatorJson == newLocatorJson) {
        return;
      }
      await _databaseHelper.updateBookProgressFields(bookId, newLocatorJson: newLocatorJson);
      _updateLocalBookData(bookId);
    } catch (e, stackTrace) { print("Error saving progress for $bookId: $e\n$stackTrace"); }
  }


  void _navigateToStatsScreen(Book book) async {
    if (!mounted) return;
    print("Navigating to Stats for book ID ${book.id}");
    Book freshBook = book;
    if (book.id != null) {
      try {
        final db = await _databaseHelper.database;
        final maps = await db.query('books', where: 'id = ?', whereArgs: [book.id], limit: 1);
        if (maps.isNotEmpty) {
          freshBook = Book.fromMap(maps.first);
          print("Fetched fresh data for book ID ${book.id} before StatsScreen.");
        }
      } catch (e) { print("Error fetching fresh book data for StatsScreen: $e"); }
    }

    if (!mounted) return;

    final result = await Navigator.push(
      context, MaterialPageRoute(
        builder: (context) => StatsScreen(
          book: freshBook,
          onDeleteRequested: () { if(mounted) _confirmAndDeleteBook(freshBook); },
        )
    ),
    );

    if (mounted && freshBook.id != null && result != 'deleted') {
      _updateLocalBookData(freshBook.id!);
    }
  }

  void _confirmAndDeleteBook(Book book) {
    if (!mounted) return;
    if (_timeTracker?.bookId == book.id) {
      _timeTracker?.stopAndSaveTracking(); _timeTracker = null;
      print("Stopped tracker for book ID ${book.id} due to delete confirmation.");
    }

    showDialog( context: context, barrierDismissible: false,
      builder: (BuildContext ctx) {
        return AlertDialog(
          title: const Text('Delete Book?'),
          content: Text('Are you sure you want to permanently delete "${book.title}"? This cannot be undone.'),
          actions: <Widget>[
            TextButton(
                child: const Text('Cancel'),
                onPressed: () => Navigator.of(ctx).pop()
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
              child: const Text('Delete'),
              onPressed: () async {
                Navigator.of(ctx).pop();
                if (!mounted) return;
                await _deleteBook(book);

                if (mounted && Navigator.canPop(context)) {
                  Navigator.of(context).pop('deleted');
                }
              },
            ),
          ],
        );
      },
    );
  }


  Future<void> _deleteBook(Book book, {bool showSnackbar = true}) async {
    print("Deleting book ID ${book.id}: ${book.title}");
    if (book.id == null) {
      print("Error: Cannot delete book with null ID.");
      return;
    }
    if (mounted && !isLoading) setState(() => isLoading = true);

    try {
      if (_timeTracker?.bookId == book.id) {
        await _timeTracker?.stopAndSaveTracking(); _timeTracker = null;
        print("Stopped tracker for book ID ${book.id} during deletion.");
      }
      if (_locatorSubscription != null && _timeTracker?.bookId == book.id ) {
        _locatorSubscription?.cancel(); _locatorSubscription = null;
        print("Cancelled locator listener for book ID ${book.id} during deletion.");
      }

      final file = File(book.filePath);
      if (await file.exists()) {
        await file.delete();
        print("Deleted file: ${book.filePath}");
      } else {
        print("File not found for deletion: ${book.filePath}");
      }

      await _databaseHelper.deleteBook(book.id!);
      await _loadBooks();

      if (mounted && showSnackbar) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('"${book.title}" deleted.')));
      }
    } catch (e, stackTrace) {
      print("Error deleting book ID ${book.id}: $e\n$stackTrace");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error deleting "${book.title}".')));
        if (isLoading) setState(() { isLoading = false; });
      }
    } finally {
      if (mounted && isLoading) {
        // loadBooks handles setting isLoading to false
      }
    }
  }

  // Method to toggle view type in ReadingSettings
  void _toggleViewType() {
    final settings = Provider.of<ReadingSettings>(context, listen: false);
    final currentType = settings.libraryViewType;
    final nextType = currentType == LibraryViewType.grid
        ? LibraryViewType.list
        : LibraryViewType.grid;
    settings.updateSetting(ReadingSettings._libraryViewTypeKey, nextType);
  }

  @override
  Widget build(BuildContext context) {
    // Watch ReadingSettings to rebuild when view type changes
    final readingSettings = context.watch<ReadingSettings>();
    final currentViewType = readingSettings.libraryViewType;

    return Scaffold(
      appBar: AppBar(
        title: const Text('My EPUB Library'),
        actions: [
          // View Toggle Button
          IconButton(
            icon: Icon(currentViewType == LibraryViewType.grid
                ? Icons.view_list_outlined // Show list icon if grid is active
                : Icons.grid_view_outlined), // Show grid icon if list is active
            tooltip: currentViewType == LibraryViewType.grid
                ? 'Switch to List View'
                : 'Switch to Grid View',
            onPressed: _toggleViewType, // Call the toggle method
          ),
          // Settings Button
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () {
              Navigator.push(context, MaterialPageRoute(builder: (context) => const SettingsScreen()));
            },
          ),
        ],
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : books.isEmpty
          ? _buildEmptyLibraryView()
      // Conditionally build Grid or List view
          : RefreshIndicator(
        onRefresh: _loadBooks,
        child: currentViewType == LibraryViewType.grid
            ? _buildBookGridView()
            : _buildBookListView(),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _pickAndImportBook,
        tooltip: 'Import EPUB Book',
        child: const Icon(Icons.add),
      ),
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
            Text('Tap the + button below to import an EPUB file.', textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey)),
          ],
        ),
      ),
    );
  }

  Widget _buildBookGridView() {
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
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.05),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
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
                        child: (book.coverImagePath != null && book.coverImagePath!.isNotEmpty)
                            ? Image.asset(
                            book.coverImagePath!,
                            fit: BoxFit.cover,
                            errorBuilder: (ctx, err, st) => const Center(child: Icon(Icons.broken_image_outlined, color: Colors.grey, size: 40))
                        )
                            : Center(child: Icon(Icons.menu_book, size: 50.0, color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.6))),
                      ),
                    ),
                    const SizedBox(height: 6.0),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8.0),
                      child: Text(
                        book.title,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500, height: 1.3),
                      ),
                    ),
                    const Spacer(),
                    if (progress > 0.0)
                      Padding(
                        padding: const EdgeInsets.only(left: 8.0, right: 8.0, bottom: 8.0, top: 4.0),
                        child: SizedBox(
                          height: progressBarHeight,
                          child: LinearProgressIndicator(
                            value: progress,
                            backgroundColor: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.5),
                            valueColor: AlwaysStoppedAnimation<Color>(Theme.of(context).colorScheme.primary),
                            borderRadius: BorderRadius.circular(progressBarHeight / 2),
                          ),
                        ),
                      )
                    else
                      SizedBox(height: progressBarHeight + 12.0),

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


  Widget _buildBookListView() {
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
                        child: (book.coverImagePath != null && book.coverImagePath!.isNotEmpty)
                            ? Image.asset(
                            book.coverImagePath!,
                            fit: BoxFit.cover,
                            errorBuilder: (ctx, err, st) => const Center(child: Icon(Icons.broken_image_outlined, size: 24, color: Colors.grey))
                        )
                            : Center(child: Icon(Icons.menu_book, size: 30.0, color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.6))),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            book.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w500),
                          ),
                          const SizedBox(height: 8),
                          if (progress > 0.0) ...[
                            const SizedBox(height: 8),
                            LinearProgressIndicator(
                              value: progress,
                              backgroundColor: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.5),
                              valueColor: AlwaysStoppedAnimation<Color>(Theme.of(context).colorScheme.primary),
                              minHeight: 5,
                              borderRadius: BorderRadius.circular(2.5),
                            ),
                          ]
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        } catch (e, stackTrace) {
          print("Error in List itemBuilder $index: $e\n$stackTrace");
          return ListTile(
            leading: const Icon(Icons.error, color: Colors.red),
            title: const Text('Error loading item'),
            subtitle: Text(e.toString()),
          );
        }
      },
    );
  }

} // End of _LibraryScreenState

// ====================================
// StatsScreen Widget (Simplified)
// ====================================
class StatsScreen extends StatelessWidget {
  final Book book;
  final VoidCallback onDeleteRequested;

  const StatsScreen({
    Key? key,
    required this.book,
    required this.onDeleteRequested,
  }) : super(key: key);

  String _formatDurationLocal(Duration? duration) => ReadingTimeTracker.formatDuration(duration);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(book.title, overflow: TextOverflow.ellipsis),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: ListView( // Use ListView in case content overflows on small screens
          children: [
            // Optional Cover Image Display
            if (book.coverImagePath != null && book.coverImagePath!.isNotEmpty)
              Center(
                child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.3),
                    child: ClipRRect(
                        borderRadius: BorderRadius.circular(12.0),
                        child: Image.asset(
                            book.coverImagePath!,
                            fit: BoxFit.contain,
                            errorBuilder: (ctx, err, st) => const Icon(Icons.error, size: 60)
                        )
                    )
                ),
              ),
            if (book.coverImagePath != null) const SizedBox(height: 24),

            // Simple Stats Card
            Card(
              elevation: 2,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12.0, horizontal: 16.0),
                child: _buildStatRow(context, Icons.timer_outlined, 'Total Time Read', _formatDurationLocal(Duration(seconds: book.totalReadingTime))),
              ),
            ),

            const SizedBox(height: 24),

            // Delete Button
            OutlinedButton.icon(
              icon: Icon(Icons.delete_forever_outlined, color: Theme.of(context).colorScheme.error),
              label: Text('Delete Book Permanently', style: TextStyle(color: Theme.of(context).colorScheme.error)),
              style: OutlinedButton.styleFrom(
                  side: BorderSide(color: Theme.of(context).colorScheme.error.withOpacity(0.5)),
                  minimumSize: const Size(double.infinity, 44),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))
              ),
              onPressed: onDeleteRequested,
            ),
          ],
        ),
      ),
    );
  }

  // Helper widget (unchanged)
  Widget _buildStatRow(BuildContext context, IconData icon, String label, String value) {
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
// SettingsScreen Widget
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
      padding: const EdgeInsets.only(left: 16.0, right: 16.0, top: 20.0, bottom: 8.0),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildThemeSetting(BuildContext context, ReadingSettings settings) {
    return ListTile(
      leading: Icon(
          settings.themeMode == ThemeMode.light ? Icons.wb_sunny_outlined :
          settings.themeMode == ThemeMode.dark ? Icons.nightlight_outlined :
          Icons.brightness_auto_outlined
      ),
      title: const Text('App Theme'),
      trailing: DropdownButton<ThemeMode>(
        value: settings.themeMode,
        underline: Container(),
        borderRadius: BorderRadius.circular(8),
        items: const [
          DropdownMenuItem(value: ThemeMode.system, child: Text('System Default')),
          DropdownMenuItem(value: ThemeMode.light, child: Text('Light')),
          DropdownMenuItem(value: ThemeMode.dark, child: Text('Dark')),
        ],
        onChanged: (value) {
          if (value != null) {
            settings.updateSetting(ReadingSettings._themeModeKey, value);
          }
        },
      ),
    );
  }

  Widget _buildScrollDirectionSetting(BuildContext context, ReadingSettings settings) {
    return ListTile(
      leading: const Icon(Icons.swap_horiz_outlined),
      title: const Text('Reader Scroll Direction'),
      trailing: DropdownButton<EpubScrollDirection>(
        value: settings.scrollDirection,
        underline: Container(),
        borderRadius: BorderRadius.circular(8),
        items: const [
          DropdownMenuItem(value: EpubScrollDirection.HORIZONTAL, child: Text('Horizontal')),
          DropdownMenuItem(value: EpubScrollDirection.VERTICAL, child: Text('Vertical')),
        ],
        onChanged: (value) {
          if (value != null) {
            settings.updateSetting(ReadingSettings._scrollDirectionKey, value);
          }
        },
      ),
    );
  }

  Widget _buildAboutTile(BuildContext context) {
    String appVersion = '1.6.0'; // Example version
    return ListTile(
      leading: const Icon(Icons.info_outline),
      title: const Text('App Version'),
      subtitle: Text(appVersion),
      onTap: () {
        showAboutDialog(
          context: context,
          applicationName: 'Flutter EPUB Reader',
          applicationVersion: appVersion,
          applicationLegalese: '© 2024 Your Name/Company',
          children: [
            const Padding(
                padding: EdgeInsets.only(top: 15),
                child: Text('A simple EPUB reader application built using Flutter.')
            )
          ],
        );
      },
    );
  }
}


// ====================================
// HighlightsScreen Widget
// ====================================
class HighlightsScreen extends StatelessWidget {
  final Book book;
  const HighlightsScreen({Key? key, required this.book}) : super(key: key);

  Map<String, List<String>> _getValidHighlights() {
    try {
      if (book.highlights is Map) {
        final potentialMap = book.highlights;
        if (potentialMap.keys.every((k) => k is String) &&
            potentialMap.values.every((v) => v is List && v.every((item) => item is String))) {
          return Map<String, List<String>>.from(potentialMap);
        }
      }
    } catch (e) { print("Error accessing or casting highlights map: $e");}
    return {};
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, List<String>> highlights = _getValidHighlights();
    final List<MapEntry<String, List<String>>> chapterEntries = highlights.entries
        .where((entry) => entry.value.isNotEmpty)
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: Text('Highlights: ${book.title}', overflow: TextOverflow.ellipsis),
      ),
      body: chapterEntries.isEmpty
          ? Center(
          child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: Text(
                'No highlights saved for this book yet.',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.grey),
                textAlign: TextAlign.center,
              )
          )
      )
          : ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 10.0, horizontal: 8.0),
        itemCount: chapterEntries.length,
        itemBuilder: (context, chapterIndex) {
          final entry = chapterEntries[chapterIndex];
          final String chapter = entry.key;
          final List<String> chapterHighlights = entry.value;

          if (chapterHighlights.isEmpty) return const SizedBox.shrink();

          return Card(
            margin: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4.0),
            elevation: 1,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            child: ExpansionTile(
              title: Text(
                  chapter.isNotEmpty ? chapter : 'Chapter Highlights',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)
              ),
              initiallyExpanded: true,
              childrenPadding: const EdgeInsets.only(left: 16, right: 16, bottom: 16, top: 0),
              tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              shape: const Border(),
              children: chapterHighlights.map((text) {
                return Padding(
                  padding: const EdgeInsets.only(top: 10.0),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.secondaryContainer.withOpacity(0.7),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SelectableText(
                        text.trim(),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.4)
                    ),
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