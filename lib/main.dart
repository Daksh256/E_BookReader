import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:vocsy_epub_viewer/epub_viewer.dart'; // For reader and scroll direction enum
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:provider/provider.dart'; // For state management
import 'package:path/path.dart' as path; // Use alias 'path' for clarity
import 'dart:io';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert'; // Needed for json encoding/decoding

// --- Book Model ---
// Updated Book model with coverImagePath
class Book {
  final int? id;
  final String title;
  final String filePath;
  final String lastLocatorJson;
  final int totalReadingTime; // In seconds
  final Map<String, List<String>> highlights;
  final String? coverImagePath; // Added: Path to the cover image asset

  const Book({
    this.id,
    required this.title,
    required this.filePath,
    this.lastLocatorJson = '{}',
    this.totalReadingTime = 0,
    this.highlights = const {},
    this.coverImagePath, // Added: Constructor parameter
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'title': title,
    'filePath': filePath,
    'lastLocatorJson': lastLocatorJson,
    'totalReadingTime': totalReadingTime,
    'highlights': json.encode(highlights),
    'coverImagePath': coverImagePath, // Added: Include in map
  };

  static Book fromMap(Map<String, dynamic> map) {
    Map<String, List<String>> decodedHighlights = {};
    if (map['highlights'] != null) {
      try {
        var decoded = json.decode(map['highlights']);
        if (decoded is Map) {
          decodedHighlights = Map<String, List<String>>.from(
            decoded.map((key, value) {
              if (value is List) {
                return MapEntry(key.toString(),
                    List<String>.from(value.map((e) => e.toString())));
              }
              return MapEntry(key.toString(), <String>[]);
            }),
          );
        }
      } catch (e) {
        print("Error decoding highlights for book ID ${map['id']}: $e");
        decodedHighlights = {};
      }
    }

    return Book(
      id: map['id'] as int?, // Cast for safety
      title: map['title'] as String? ?? 'Untitled',
      filePath: map['filePath'] as String? ?? '',
      lastLocatorJson: map['lastLocatorJson'] as String? ?? '{}',
      totalReadingTime: map['totalReadingTime'] as int? ?? 0,
      highlights: decodedHighlights,
      coverImagePath: map['coverImagePath'] as String?, // Added: Load from map
    );
  }

  Book copyWith({
    int? id,
    String? title,
    String? filePath,
    String? lastLocatorJson,
    int? totalReadingTime,
    Map<String, List<String>>? highlights,
    String? coverImagePath, // Added: copyWith parameter
  }) =>
      Book(
        id: id ?? this.id,
        title: title ?? this.title,
        filePath: filePath ?? this.filePath,
        lastLocatorJson: lastLocatorJson ?? this.lastLocatorJson,
        totalReadingTime: totalReadingTime ?? this.totalReadingTime,
        highlights: highlights ?? this.highlights,
        coverImagePath: coverImagePath ?? this.coverImagePath, // Added: Update copyWith
      );
}

// --- Database Helper ---
// Singleton Database Helper - Updated for coverImagePath and migration
class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  static Database? _database;

  // Increment DB version for schema change
  static const int _dbVersion = 2;
  static const String _dbName = 'books_database.db';

  factory DatabaseHelper() => _instance;
  DatabaseHelper._internal();

  Future<Database> get database async {
    return _database ??= await _initDatabase();
  }

  Future<Database> _initDatabase() async {
    final dbPath = path.join(await getDatabasesPath(), _dbName);
    print("Database path: $dbPath"); // Log database path
    return await openDatabase(
      dbPath,
      version: _dbVersion, // Use updated version
      onCreate: (db, version) {
        print("Creating database table 'books' version $version");
        // Added coverImagePath column
        return db.execute(
          'CREATE TABLE books(id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT, filePath TEXT, lastLocatorJson TEXT, totalReadingTime INTEGER DEFAULT 0, highlights TEXT DEFAULT \'{}\', coverImagePath TEXT)',
        );
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        print("Upgrading database from version $oldVersion to $newVersion");
        if (oldVersion < 2) {
          try {
            print("Adding coverImagePath column to books table...");
            // Use try-catch for safety during ALTER TABLE
            await db.execute('ALTER TABLE books ADD COLUMN coverImagePath TEXT');
            print("Column 'coverImagePath' added successfully.");
          } catch (e) {
            print("Error adding coverImagePath column during upgrade: $e");
            // Handle potential errors, e.g., column already exists (though unlikely with version check)
            // Consider recovery steps if necessary, or log the error.
          }
        }
        // Add more upgrade steps for future versions here (e.g., if (oldVersion < 3) ...)
      },
      onDowngrade: (db, oldVersion, newVersion) {
        // Optional: handle downgrades if necessary, though often avoided
        print("Downgrading database from version $oldVersion to $newVersion - NOT IMPLEMENTED");
        // Typically, you might delete the table and recreate it, or raise an error.
      },
    );
  }

  Future<void> insertBook(Book book) async {
    try {
      final db = await database;
      int id = await db.insert(
        'books',
        book.toMap(), // Now includes coverImagePath if present
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      print("Book inserted/replaced: ${book.title} with new ID: $id");
    } catch (e) {
      print("Error inserting book ${book.title}: $e");
    }
  }

  Future<List<Book>> getBooks() async {
    final db = await database;
    final maps = await db.query('books', orderBy: 'title ASC');
    if (maps.isEmpty) {
      print("No books found in database.");
      return [];
    }
    List<Book> books = List.generate(maps.length, (i) {
      try {
        return Book.fromMap(maps[i]); // Now parses coverImagePath
      } catch (e) {
        print("Error creating Book object from map: ${maps[i]}, Error: $e");
        return null;
      }
    })
        .where((book) => book != null)
        .cast<Book>()
        .toList();

    print("Loaded ${books.length} books from database.");
    return books;
  }

  Future<void> updateBook(Book book) async {
    if (book.id == null) {
      print("Error updating book: ID is null for title '${book.title}'");
      return;
    }
    try {
      final db = await database;
      int count = await db.update(
        'books',
        book.toMap(), // Includes coverImagePath
        where: 'id = ?',
        whereArgs: [book.id],
      );
      print("Updated book ID ${book.id}. Rows affected: $count");
    } catch (e) {
      print("Error updating book ID ${book.id}: $e");
    }
  }

  // Specific method to update metadata like reading time and highlights
  Future<void> updateBookMetadata(int bookId,
      {int? readingTime, String? chapter, String? highlight}) async {
    try {
      final db = await database;
      final books =
      await db.query('books', where: 'id = ?', whereArgs: [bookId]);

      if (books.isNotEmpty) {
        final book = Book.fromMap(books.first); // Create Book object from DB data

        final updatedBook = book.copyWith(
          totalReadingTime: (book.totalReadingTime) + (readingTime ?? 0),
          highlights: highlight != null && chapter != null
              ? _addHighlight(book.highlights, chapter, highlight)
              : book.highlights,
          // coverImagePath is not updated here, only on insert or general update
        );

        await updateBook(updatedBook); // Use the general updateBook method
        print(
            "Updated metadata for book ID $bookId. New time: ${updatedBook.totalReadingTime}, Highlight added: ${highlight != null}");
      } else {
        print("Attempted to update metadata, but book ID $bookId not found.");
      }
    } catch (e) {
      print("Error fetching book for metadata update (ID: $bookId): $e");
    }
  }

  // Helper to add a highlight to the map (returns a new map)
  Map<String, List<String>> _addHighlight(
      Map<String, List<String>> highlights, String chapter, String text) {
    final updatedHighlights = Map<String, List<String>>.from(highlights.map(
          (key, value) => MapEntry(key, List<String>.from(value)),
    ));
    updatedHighlights.update(
      chapter,
          (list) => list..add(text),
      ifAbsent: () => [text],
    );
    print(
        "Highlight added for chapter '$chapter'. Total chapters with highlights: ${updatedHighlights.length}");
    return updatedHighlights;
  }

  // Method to delete a book
  Future<void> deleteBook(int id) async {
    try {
      final db = await database;
      int count = await db.delete(
        'books',
        where: 'id = ?',
        whereArgs: [id],
      );
      print("Deleted book record ID $id from database. Rows affected: $count");
    } catch (e) {
      print("Error deleting book record ID $id from database: $e");
    }
  }
}

// --- Reading Settings Provider ---
// (No changes needed in this class for the image feature)
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

  ReadingSettings() {
    loadSettings();
  }

  Future<void> loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _fontSize = prefs.getDouble(_fontSizeKey) ?? _fontSize;
      _fontFamily = prefs.getString(_fontFamilyKey) ?? _fontFamily;
      _lineHeight = prefs.getDouble(_lineHeightKey) ?? _lineHeight;
      final savedDirectionName = prefs.getString(_scrollDirectionKey);
      _scrollDirection = EpubScrollDirection.values.firstWhere(
            (e) => e.name == savedDirectionName,
        orElse: () => EpubScrollDirection.HORIZONTAL,
      );
      print(
          "Loaded settings: Size=$_fontSize, Family=$_fontFamily, LineHeight=$_lineHeight, Scroll=$_scrollDirection");
      notifyListeners();
    } catch (e) {
      print("Error loading settings: $e");
      // Reset to defaults on error
      _fontSize = 16;
      _fontFamily = 'Roboto';
      _lineHeight = 1.4;
      _scrollDirection = EpubScrollDirection.HORIZONTAL;
    }
  }

  void updateSetting(String key, dynamic value) {
    bool changed = false;
    switch (key) {
      case _fontSizeKey:
        if (_fontSize != value && value is double) { _fontSize = value; changed = true; } break;
      case _fontFamilyKey:
        if (_fontFamily != value && value is String) { _fontFamily = value; changed = true; } break;
      case _lineHeightKey:
        if (_lineHeight != value && value is double) { _lineHeight = value; changed = true; } break;
      case _scrollDirectionKey:
        if (_scrollDirection != value && value is EpubScrollDirection) { _scrollDirection = value; changed = true; } break;
    }
    if (changed) {
      _saveSettings();
      notifyListeners();
      print("Updated setting: $key = $value");
    }
  }

  Future<void> _saveSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await Future.wait([
        prefs.setDouble(_fontSizeKey, _fontSize),
        prefs.setString(_fontFamilyKey, _fontFamily),
        prefs.setDouble(_lineHeightKey, _lineHeight),
        prefs.setString(_scrollDirectionKey, _scrollDirection.name),
      ]);
      print("Settings saved.");
    } catch (e) {
      print("Error saving settings: $e");
    }
  }
}

// --- Reading Time Tracker ---
// (No changes needed in this class for the image feature)
class ReadingTimeTracker {
  final int bookId;
  final DatabaseHelper databaseHelper;

  DateTime? _startTime;
  Timer? _timer;
  int _sessionSeconds = 0;

  ReadingTimeTracker({required this.bookId, required this.databaseHelper});

  void startTracking() {
    if (_timer?.isActive ?? false) return;
    _startTime = DateTime.now();
    _sessionSeconds = 0;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) { _sessionSeconds++; });
    print("Started time tracking for book ID $bookId.");
  }

  Future<void> stopAndSaveTracking() async {
    if (!(_timer?.isActive ?? false) && _sessionSeconds == 0) {
      print("Time tracking stop called for book ID $bookId, but no active session or time recorded.");
      _timer?.cancel(); _timer = null; _resetTrackingState(); return;
    }
    _timer?.cancel(); _timer = null;
    if (_startTime != null && _sessionSeconds > 0) {
      print("Stopping time tracking for book ID $bookId. Session duration: $_sessionSeconds seconds.");
      try {
        await databaseHelper.updateBookMetadata(bookId, readingTime: _sessionSeconds);
        print("Saved session time ($_sessionSeconds s) for book ID $bookId.");
      } catch (e) { print("Error saving reading time for book ID $bookId: $e"); }
      _resetTrackingState();
    } else {
      print("Time tracking stopped for book ID $bookId, but no time was recorded in this session.");
      _resetTrackingState();
    }
  }

  void _resetTrackingState() { _sessionSeconds = 0; _startTime = null; }

  static String formatTotalReadingTime(int totalSeconds) {
    if (totalSeconds <= 0) return '0 minutes';
    final duration = Duration(seconds: totalSeconds);
    final hours = duration.inHours; final minutes = duration.inMinutes.remainder(60);
    String result = '';
    if (hours > 0) { result += '$hours hour${hours == 1 ? '' : 's'} '; }
    if (minutes > 0 || hours == 0) { result += '$minutes minute${minutes == 1 ? '' : 's'}'; }
    if (result.trim().isEmpty && totalSeconds > 0) { return '< 1 minute'; }
    return result.trim();
  }
}

// --- Main Application Entry Point ---
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Trigger DB initialization early (optional, but can help catch issues sooner)
  // await DatabaseHelper().database;
  runApp(
    ChangeNotifierProvider(
      create: (context) => ReadingSettings(),
      child: const EpubReaderApp(),
    ),
  );
}

// --- Main App Widget (MaterialApp) ---
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
        cardTheme: CardTheme( elevation: 1.0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 5), ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo, brightness: Brightness.dark),
        fontFamily: readingSettings.fontFamily,
        cardTheme: CardTheme( elevation: 1.0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 5), ),
      ),
      themeMode: ThemeMode.system,
      home: const LibraryScreen(),
    );
  }
}

// --- Library Screen ---
// Displays the list of imported books - Updated for Image Loading
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({Key? key}) : super(key: key);

  @override
  _LibraryScreenState createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final DatabaseHelper _databaseHelper = DatabaseHelper();
  List<Book> books = [];
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    print("LibraryScreen: initState - Calling _loadBooks");
    _loadBooks();
  }

  Future<void> _loadBooks() async {
    print("LibraryScreen: _loadBooks - Start. Mounted: $mounted");
    if (!mounted) return;
    setState(() { isLoading = true; });
    try {
      print("LibraryScreen: _loadBooks - Calling databaseHelper.getBooks");
      final loadedBooks = await _databaseHelper.getBooks();
      print("LibraryScreen: _loadBooks - Got ${loadedBooks.length} books from DB.");
      if (mounted) {
        print("LibraryScreen: _loadBooks - Widget is mounted. Calling setState.");
        setState(() { books = loadedBooks; isLoading = false; });
      } else {
        print("LibraryScreen: _loadBooks - Load books completed but widget was disposed.");
      }
    } catch (e, stackTrace) {
      print("LibraryScreen: _loadBooks - Error loading books: $e"); print(stackTrace);
      if (mounted) {
        setState(() { isLoading = false; books = []; });
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar( content: Text('Error loading library. Please try again.'), backgroundColor: Colors.red));
      }
    }
  }

  // Pick an EPUB file and import it - Updated for Image Check
  Future<void> _pickAndImportBook() async {
    print("LibraryScreen: Picking file...");
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles( type: FileType.custom, allowedExtensions: ['epub'], );
    } catch (e) {
      print("LibraryScreen: File picking error: $e");
      if (mounted) { ScaffoldMessenger.of(context).showSnackBar( SnackBar(content: Text('Error picking file: ${e.toString()}'))); }
      return;
    }

    if (result != null && result.files.single.path != null) {
      File sourceFile = File(result.files.single.path!);
      String originalFileName = result.files.single.name;
      print("LibraryScreen: File picked: $originalFileName at ${sourceFile.path}");

      if (mounted) setState(() => isLoading = true); // Show loading

      try {
        Directory appDocDir = await getApplicationDocumentsDirectory();
        String booksDir = path.join(appDocDir.path, 'epubs');
        Directory dir = Directory(booksDir);
        if (!await dir.exists()) { await dir.create(recursive: true); }
        String newPath = path.join(booksDir, originalFileName);

        final currentBooksInDb = await _databaseHelper.getBooks();
        bool bookExists = currentBooksInDb.any((book) => book.filePath == newPath);

        if (bookExists) {
          print("LibraryScreen: Book file path already exists in library: $newPath. Skipping import.");
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar( const SnackBar(content: Text('This book is already in your library.')), );
            setState(() => isLoading = false); // Stop loading
          }
          return;
        }

        // --- Start Hardcoded Image Check ---
        String? coverImagePath; // Initialize cover image path as null
        // Extract filename without extension for robust comparison
        String bookNameWithoutExt = path.basenameWithoutExtension(originalFileName);

        // Check if the book name *starts with* "Discourses and selected" (case-insensitive)
        if (bookNameWithoutExt.toLowerCase().startsWith('discourses and selected')) {
          // Assign the hardcoded image path
          coverImagePath = 'assets/images/discourses_selected_cover.png'; // <<< YOUR IMAGE PATH HERE
          print('Match found for "$originalFileName"! Assigning cover: $coverImagePath');
        } else {
          print('No match for "$originalFileName". No specific cover assigned.');
          // Optionally, assign a default cover for other books here
          // coverImagePath = 'assets/images/default_cover.png';
        }
        // --- End Hardcoded Image Check ---


        print("LibraryScreen: Copying from ${sourceFile.path} to $newPath");
        await sourceFile.copy(newPath);
        print("LibraryScreen: File copied successfully.");

        // Create Book object including the determined coverImagePath
        Book newBook = Book(
          title: originalFileName.replaceAll( RegExp(r'\.epub$', caseSensitive: false), ''),
          filePath: newPath,
          lastLocatorJson: '{}',
          totalReadingTime: 0,
          highlights: {},
          coverImagePath: coverImagePath, // Pass the determined path (null or specific)
        );
        await _databaseHelper.insertBook(newBook);
        print("LibraryScreen: Book saved to database.");
        await _loadBooks(); // Reload the list (this will set isLoading = false)

      } catch (e) {
        print("LibraryScreen: Error copying or saving book: $e");
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar( SnackBar(content: Text('Error importing book: ${e.toString()}')));
          setState(() => isLoading = false); // Stop loading on error
        }
      }
    } else {
      print("LibraryScreen: File picking cancelled.");
    }
  }


  void _confirmAndDeleteBook(Book book) {
    if (!mounted) return;
    showDialog(
      context: context, barrierDismissible: false,
      builder: (BuildContext ctx) {
        return AlertDialog(
          title: const Text('Delete Book?'),
          content: Text('Are you sure you want to permanently delete "${book.title}"?\n\nThis will remove the book file, reading progress, and all associated highlights.'),
          actions: <Widget>[
            TextButton( child: const Text('Cancel'), onPressed: () => Navigator.of(ctx).pop(), ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.red.shade700),
              child: const Text('Delete Permanently'),
              onPressed: () async { Navigator.of(ctx).pop(); await _deleteBook(book); },
            ),
          ],
        );
      },
    );
  }

  Future<void> _deleteBook(Book book) async {
    print("LibraryScreen: Deleting book ID ${book.id} - ${book.title}");
    if (book.id == null) {
      print("Error: Cannot delete book with null ID.");
      if (mounted) { ScaffoldMessenger.of(context).showSnackBar( const SnackBar(content: Text('Error: Cannot delete book without an ID.')), ); } return;
    }
    if (mounted) setState(() { isLoading = true; });
    try {
      final file = File(book.filePath);
      if (await file.exists()) { await file.delete(); print("LibraryScreen: Deleted file ${book.filePath}"); }
      else { print("LibraryScreen: File not found for deletion, proceeding to delete DB record: ${book.filePath}"); }
      await _databaseHelper.deleteBook(book.id!);
      print("LibraryScreen: Deleted book record from database (ID: ${book.id}).");
      await _loadBooks();
      if (mounted) { ScaffoldMessenger.of(context).showSnackBar( SnackBar(content: Text('"${book.title}" deleted successfully.')), ); }
    } catch (e) {
      print("LibraryScreen: Error deleting book ID ${book.id}: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar( SnackBar(content: Text('Error deleting "${book.title}".')), );
        setState(() { isLoading = false; });
      }
    }
  }

  void _openReader(Book book) {
    if (book.id == null) {
      print("LibraryScreen: Cannot open book, ID is null for title '${book.title}'");
      ScaffoldMessenger.of(context).showSnackBar( const SnackBar(content: Text('Error: Book data is incomplete. Cannot open.')), ); return;
    }
    final file = File(book.filePath);
    if (!file.existsSync()) {
      print("LibraryScreen: Error - Book file not found at ${book.filePath} before opening reader.");
      ScaffoldMessenger.of(context).showSnackBar( const SnackBar(content: Text('Error: Book file is missing or moved. Cannot open.')), ); return;
    }
    print("LibraryScreen: Opening reader for book ID ${book.id} - ${book.title}");
    Navigator.push( context, MaterialPageRoute( builder: (context) => ReaderScreen(book: book), ), ).then((_) { print("LibraryScreen: Returned from ReaderScreen. Reloading books."); _loadBooks(); });
  }

  @override
  Widget build(BuildContext context) {
    print("LibraryScreen: build - isLoading: $isLoading, books.length: ${books.length}");
    return Scaffold(
      appBar: AppBar(
        title: const Text('My EPUB Library'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined), tooltip: 'Settings',
            onPressed: () { Navigator.push( context, MaterialPageRoute(builder: (context) => const SettingsScreen()), ); },
          ),
        ],
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : books.isEmpty
          ? _buildEmptyLibraryView()
          : RefreshIndicator( onRefresh: _loadBooks, child: _buildBookGridView(), ),
      floatingActionButton: FloatingActionButton(
        onPressed: _pickAndImportBook, tooltip: 'Import EPUB Book', child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildEmptyLibraryView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column( mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.library_books_outlined, size: 70, color: Colors.grey), const SizedBox(height: 20),
          Text( 'Your library is empty.', style: Theme.of(context).textTheme.headlineSmall?.copyWith(color: Colors.grey), ), const SizedBox(height: 10),
          Text( 'Tap the "+" button below to import an EPUB file from your device.', textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey), ), const SizedBox(height: 30),
          ElevatedButton.icon( icon: const Icon(Icons.add_circle_outline), label: const Text('Import First Book'), onPressed: _pickAndImportBook, style: ElevatedButton.styleFrom( padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12), textStyle: Theme.of(context).textTheme.bodyLarge, ), )
        ],
        ),
      ),
    );
  }

  // Widget to display the grid of books - Updated for Image Display
  Widget _buildBookGridView() {
    final screenWidth = MediaQuery.of(context).size.width;
    final crossAxisCount = (screenWidth / 140).floor().clamp(2, 5);
    final double gridPadding = 12.0;
    final double crossAxisSpacing = 12.0;
    final double mainAxisSpacing = 16.0;
    final double itemWidth = (screenWidth - (gridPadding * 2) - (crossAxisSpacing * (crossAxisCount - 1))) / crossAxisCount;
    final double coverHeight = itemWidth * 1.4; // Cover aspect ratio
    final double textHeight = 50; // Estimated text height
    final double childAspectRatio = itemWidth / (coverHeight + textHeight);

    print("LibraryScreen: Grid - ScreenWidth: $screenWidth, Cols: $crossAxisCount, ItemWidth: $itemWidth, CoverHeight: $coverHeight, TextHeightEst: $textHeight, ChildAspect: $childAspectRatio");

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
          return Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => _openReader(book),
              onLongPress: () => _confirmAndDeleteBook(book),
              borderRadius: BorderRadius.circular(8.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  // --- Cover Area (Shows Image or Placeholder) ---
                  Ink(
                    height: coverHeight,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      // Background color serves as fallback if image loading fails or no image exists
                      color: Theme.of(context).colorScheme.surfaceVariant,
                      borderRadius: BorderRadius.circular(8.0),
                      // Optional border
                      // border: Border.all(color: Theme.of(context).dividerColor, width: 0.5),
                    ),
                    // --- Conditional Image/Placeholder Display ---
                    child: ClipRRect( // Clip the image to the rounded corners
                      borderRadius: BorderRadius.circular(8.0),
                      child: (book.coverImagePath != null && book.coverImagePath!.isNotEmpty)
                          ? Image.asset(
                        book.coverImagePath!,
                        fit: BoxFit.cover, // Make image fill the container
                        // Add error builder for robustness
                        errorBuilder: (context, error, stackTrace) {
                          print("Error loading asset: ${book.coverImagePath} - $error");
                          // Fallback placeholder on asset load error
                          return Center(
                            child: Icon(
                              Icons.broken_image_outlined, // Icon indicating load error
                              size: 40.0,
                              color: Theme.of(context).colorScheme.error.withOpacity(0.7),
                            ),
                          );
                        },
                      )
                          : Center( // Default placeholder if no coverImagePath
                        child: Icon(
                          Icons.menu_book, // Standard book icon
                          size: 40.0,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurfaceVariant
                              .withOpacity(0.8),
                        ),
                      ),
                    ),
                    // --- End Conditional Image/Placeholder Display ---
                  ),
                  // --- Title ---
                  Padding(
                    padding: const EdgeInsets.only(top: 6.0, left: 4.0, right: 4.0),
                    child: Text(
                      book.title,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                        height: 1.25,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        } catch (e, stackTrace) {
          print("LibraryScreen: Error in Grid itemBuilder at index $index: $e"); print(stackTrace);
          return Container( // Error placeholder for the grid item itself
            decoration: BoxDecoration( color: Colors.red.withOpacity(0.1), borderRadius: BorderRadius.circular(8.0), border: Border.all(color: Colors.red), ),
            child: const Center( child: Icon(Icons.error_outline, color: Colors.red, size: 30)),
          );
        }
      },
    );
  }
}


// --- Settings Screen ---
// (No changes needed in this class for the image feature)
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Consumer<ReadingSettings>(
      builder: (context, readingSettings, child) {
        return Scaffold(
          appBar: AppBar(title: const Text('Settings')),
          body: ListView( padding: const EdgeInsets.all(8.0), children: [
            _buildSectionHeader(context, 'Appearance'),
            _buildFontSizeSetting(context, readingSettings),
            _buildLineHeightSetting(context, readingSettings),
            _buildFontFamilySetting(context, readingSettings),
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
      child: Text( title, style: Theme.of(context).textTheme.titleMedium?.copyWith( color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600, ), ),
    );
  }

  Widget _buildFontSizeSetting(BuildContext context, ReadingSettings settings) {
    return ListTile(
      title: const Text('Font Size'), subtitle: Text('${settings.fontSize.toInt()} pt'),
      trailing: SizedBox( width: MediaQuery.of(context).size.width * 0.5,
        child: Slider( value: settings.fontSize, min: 12, max: 32, divisions: 20, label: '${settings.fontSize.toInt()}',
          onChanged: (value) { settings.updateSetting(ReadingSettings._fontSizeKey, value); },
        ),
      ),
    );
  }

  Widget _buildLineHeightSetting( BuildContext context, ReadingSettings settings) {
    return ListTile(
      title: const Text('Line Height'), subtitle: Text(settings.lineHeight.toStringAsFixed(1)),
      trailing: SizedBox( width: MediaQuery.of(context).size.width * 0.5,
        child: Slider( value: settings.lineHeight, min: 1.0, max: 2.0, divisions: 10, label: settings.lineHeight.toStringAsFixed(1),
          onChanged: (value) { settings.updateSetting(ReadingSettings._lineHeightKey, value); },
        ),
      ),
    );
  }

  Widget _buildFontFamilySetting( BuildContext context, ReadingSettings settings) {
    const List<String> availableFonts = [ 'Roboto', 'Merriweather', 'OpenSans', 'Lato', 'Lora', 'SourceSerifPro' ];
    return ListTile(
      title: const Text('Font Family'),
      trailing: DropdownButton<String>(
        value: settings.fontFamily,
        items: availableFonts.map((String fontName) { return DropdownMenuItem<String>( value: fontName, child: Text(fontName), ); }).toList(),
        onChanged: (value) { if (value != null) { settings.updateSetting(ReadingSettings._fontFamilyKey, value); } },
      ),
    );
  }

  Widget _buildScrollDirectionSetting( BuildContext context, ReadingSettings settings) {
    return ListTile(
      title: const Text('Scroll Direction'),
      trailing: DropdownButton<EpubScrollDirection>(
        value: settings.scrollDirection,
        items: const [
          DropdownMenuItem( value: EpubScrollDirection.HORIZONTAL, child: Text('Horizontal (Pages)'), ),
          DropdownMenuItem( value: EpubScrollDirection.VERTICAL, child: Text('Vertical (Scroll)'), ),
        ],
        onChanged: (value) { if (value != null) { settings.updateSetting(ReadingSettings._scrollDirectionKey, value); } },
      ),
    );
  }

  Widget _buildAboutTile(BuildContext context) {
    return ListTile(
      title: const Text('App Version'), subtitle: const Text('1.2.1 (Image Cover)'), // Updated version example
      leading: const Icon(Icons.info_outline),
      onTap: () {
        showAboutDialog( context: context, applicationName: 'Flutter EPUB Reader', applicationVersion: '1.2.1', applicationLegalese: '© 2025 Your Name/Company',
          children: [ const Padding( padding: EdgeInsets.only(top: 15), child: Text('A simple EPUB reader built with Flutter and Vocsy EPUB Viewer.'), ) ],
        );
      },
    );
  }
}


// --- Highlights Screen ---
// (No changes needed in this class for the image feature)
class HighlightsScreen extends StatelessWidget {
  final Book book;
  const HighlightsScreen({Key? key, required this.book}) : super(key: key);

  Map<String, List<String>> _getValidHighlights() {
    if (book.highlights is Map<String, List<String>>) { return book.highlights; }
    else { print("Warning: Highlights data is not Map<String, List<String>> for book ${book.id}. Returning empty."); return {}; }
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, List<String>> highlights = _getValidHighlights();
    final List<String> chapters = highlights.keys.toList();
    print("HighlightsScreen: Displaying highlights for book ${book.id}. Chapters: ${chapters.length}");
    return Scaffold(
      appBar: AppBar( title: Text('Highlights: ${book.title}', overflow: TextOverflow.ellipsis)),
      body: highlights.isEmpty
          ? Center( child: Padding( padding: const EdgeInsets.all(20.0), child: Text( 'No highlights saved for this book yet.', textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.grey), ), ), )
          : ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 10.0, horizontal: 8.0),
        itemCount: chapters.length,
        itemBuilder: (context, chapterIndex) {
          final String chapter = chapters[chapterIndex];
          final List<String> chapterHighlights = highlights[chapter] ?? [];
          if (chapterHighlights.isEmpty) { return const SizedBox.shrink(); }
          return Card(
            child: ExpansionTile(
              title: Text(chapter.isNotEmpty ? chapter : 'Unknown Chapter', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              initiallyExpanded: true, childrenPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              children: chapterHighlights.map((text) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8.0),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration( color: Theme.of(context).colorScheme.secondaryContainer.withOpacity(0.5), borderRadius: BorderRadius.circular(8), border: Border.all(color: Theme.of(context).colorScheme.outline.withOpacity(0.3))),
                    child: SelectableText( text, style: Theme.of(context).textTheme.bodyMedium?.copyWith( fontStyle: FontStyle.italic, height: 1.4, ), ),
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


// --- Reader Screen ---
// (No changes needed in this class for the image feature, but includes necessary checks)
class ReaderScreen extends StatefulWidget {
  final Book book;
  const ReaderScreen({Key? key, required this.book}) : super(key: key);
  @override
  _ReaderScreenState createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> with WidgetsBindingObserver {
  bool isLoading = true;
  late ReadingTimeTracker _timeTracker;
  late DatabaseHelper _databaseHelper;
  bool _epubOpenedSuccessfully = false;
  StreamSubscription? _locatorSubscription;

  @override
  void initState() {
    super.initState();
    print("ReaderScreen: initState for book ID ${widget.book.id} - ${widget.book.title}");
    WidgetsBinding.instance.addObserver(this);
    _databaseHelper = DatabaseHelper();

    if (widget.book.id == null) {
      print("ReaderScreen: FATAL ERROR - Book ID is null. Cannot initialize reader.");
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) { ScaffoldMessenger.of(context).showSnackBar( const SnackBar(content: Text('Error: Cannot open book due to missing data.'), backgroundColor: Colors.red), ); Navigator.pop(context); }
      });
      setState(() { isLoading = false; }); return;
    }

    final file = File(widget.book.filePath);
    if (!file.existsSync()) {
      print("ReaderScreen: FATAL ERROR - Book file not found at ${widget.book.filePath}.");
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) { ScaffoldMessenger.of(context).showSnackBar( const SnackBar(content: Text('Error: Book file is missing or moved.'), backgroundColor: Colors.red), ); Navigator.pop(context); }
      });
      setState(() { isLoading = false; }); return;
    }

    _timeTracker = ReadingTimeTracker( bookId: widget.book.id!, databaseHelper: _databaseHelper, );
    _openEpub();
  }

  @override
  void dispose() {
    print("ReaderScreen: dispose for book ID ${widget.book.id}");
    WidgetsBinding.instance.removeObserver(this);
    _locatorSubscription?.cancel(); print("ReaderScreen: Locator stream listener cancelled.");
    if (widget.book.id != null && _epubOpenedSuccessfully) {
      print("ReaderScreen: Stopping and saving time tracking before dispose.");
      _timeTracker.stopAndSaveTracking(); // Fire and forget in dispose
    } else {
      print("ReaderScreen: Skipping time save on dispose (book ID null or EPUB not opened).");
    }
    print("ReaderScreen: Disposed.");
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    print("ReaderScreen: AppLifecycleState changed to $state for book ID ${widget.book.id}");
    if (widget.book.id == null || !_epubOpenedSuccessfully) { print("ReaderScreen: Ignoring lifecycle change (book ID null or EPUB not opened)."); return; }
    switch (state) {
      case AppLifecycleState.resumed: print("ReaderScreen: App resumed, starting time tracking."); _timeTracker.startTracking(); break;
      case AppLifecycleState.inactive: case AppLifecycleState.paused: case AppLifecycleState.detached: case AppLifecycleState.hidden:
      print("ReaderScreen: App inactive/paused/detached/hidden, stopping and saving time tracking.");
      _timeTracker.stopAndSaveTracking(); break;
    }
  }

  Future<void> _openEpub() async {
    print("ReaderScreen: _openEpub called.");
    if (widget.book.id == null) { /* Handled in initState */ if (mounted) setState(() {isLoading = false;}); return; }
    final file = File(widget.book.filePath);
    if (!await file.exists()) { /* Handled in initState */ if (mounted) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error: Book file is missing.'), backgroundColor: Colors.red)); Navigator.pop(context); setState(() {isLoading = false;}); } return; }

    final readingSettings = Provider.of<ReadingSettings>(context, listen: false);
    final bool isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final EpubScrollDirection scrollDirection = readingSettings.scrollDirection;

    print("ReaderScreen: Configuring VocsyEpub..."); print("  - Identifier: book_${widget.book.id}"); print("  - Scroll Direction: $scrollDirection"); print("  - Night Mode: $isDarkMode");

    try {
      VocsyEpub.setConfig( themeColor: Theme.of(context).colorScheme.primary, identifier: "book_${widget.book.id}", scrollDirection: scrollDirection, allowSharing: true, enableTts: false, nightMode: isDarkMode, );
      print("ReaderScreen: Configuration set. Attempting to load last location...");
      EpubLocator? lastKnownLocator;
      if (widget.book.lastLocatorJson.isNotEmpty && widget.book.lastLocatorJson != '{}') {
        print("ReaderScreen: Found saved locator JSON: ${widget.book.lastLocatorJson}");
        try {
          Map<String, dynamic> decodedLocatorMap = json.decode(widget.book.lastLocatorJson);
          if (decodedLocatorMap.containsKey('bookId') && decodedLocatorMap.containsKey('href') && decodedLocatorMap.containsKey('created') && decodedLocatorMap.containsKey('locations') && decodedLocatorMap['locations'] is Map && decodedLocatorMap['locations'].containsKey('cfi')) {
            lastKnownLocator = EpubLocator.fromJson(decodedLocatorMap); print("ReaderScreen: Successfully decoded last location.");
          } else { print("ReaderScreen: Warning - Saved locator JSON has missing/invalid fields. Opening from start."); }
        } catch (e) { print("ReaderScreen: Error decoding locator JSON '${widget.book.lastLocatorJson}': $e. Opening from start."); lastKnownLocator = null; }
      } else { print("ReaderScreen: No valid saved location found. Opening from start."); }

      print("ReaderScreen: Calling VocsyEpub.open with path: ${widget.book.filePath} and locator: ${lastKnownLocator != null}");
      VocsyEpub.open( widget.book.filePath, lastLocation: lastKnownLocator, );

      _epubOpenedSuccessfully = true;
      print("ReaderScreen: VocsyEpub.open called. Setting up listeners and starting timer.");
      _setupLocatorListener();
      _timeTracker.startTracking();

      if (mounted) { setState(() { isLoading = false; }); }
      print("ReaderScreen: EPUB should now be visible.");

    } catch (e) {
      _epubOpenedSuccessfully = false;
      print("ReaderScreen: CRITICAL Error during VocsyEpub configuration or open: $e");
      if (mounted) {
        setState(() { isLoading = false; });
        ScaffoldMessenger.of(context).showSnackBar( SnackBar(content: Text('Error opening EPUB: ${e.toString()}'), backgroundColor: Colors.red), );
        Navigator.pop(context); // Pop on critical error
      }
    }
  }

  void _setupLocatorListener() {
    print("ReaderScreen: Setting up locator stream listener for book ID ${widget.book.id}");
    _locatorSubscription?.cancel();
    _locatorSubscription = VocsyEpub.locatorStream.listen(
          (locatorData) {
        Map<String, dynamic>? locatorMap;
        if (locatorData is String) { try { locatorMap = json.decode(locatorData); } catch (e) { print("ReaderScreen: Error decoding locator string: $e. Data: $locatorData"); return; } }
        else if (locatorData is Map) { try { locatorMap = Map<String, dynamic>.from(locatorData); } catch (e) { print("ReaderScreen: Error converting received map: $e. Data: $locatorData"); return; } }

        if (locatorMap != null) {
          if (locatorMap.containsKey('bookId') && locatorMap.containsKey('href') && locatorMap.containsKey('locations') && locatorMap['locations'] is Map && locatorMap['locations'].containsKey('cfi')) {
            _updateBookProgress(locatorMap);
          } else { print("ReaderScreen: Warning - Received locator map is missing required fields: $locatorMap"); }
        } else { print("ReaderScreen: Received locator data in unrecognized format: ${locatorData?.runtimeType}"); }
      },
      onError: (error) { print("ReaderScreen: Error in locator stream: $error"); if (mounted && _epubOpenedSuccessfully) { _timeTracker.stopAndSaveTracking(); } },
      onDone: () { print("ReaderScreen: Locator stream closed (onDone). Reader likely dismissed."); if (mounted && _epubOpenedSuccessfully) { print("ReaderScreen: Performing safety stop/save of time tracker on locator stream 'onDone'."); _timeTracker.stopAndSaveTracking(); } },
      cancelOnError: false,
    );
    print("ReaderScreen: Locator stream listener is now active.");
  }

  Future<void> _updateBookProgress(Map<String, dynamic> locatorData) async {
    if (widget.book.id == null || !mounted) { return; }
    try {
      final String newLocatorJson = json.encode(locatorData);
      final db = await _databaseHelper.database;
      final currentBookData = await db.query('books', where: 'id = ?', whereArgs: [widget.book.id], limit: 1);
      if (currentBookData.isNotEmpty) {
        final String? currentLocatorJson = currentBookData.first['lastLocatorJson'] as String?;
        if (newLocatorJson != currentLocatorJson) {
          int count = await db.update( 'books', {'lastLocatorJson': newLocatorJson}, where: 'id = ?', whereArgs: [widget.book.id], );
        }
      } else { print("ReaderScreen: Warning - Book ID ${widget.book.id} not found in DB during progress update check."); }
    } catch (e) { print("ReaderScreen: Error encoding or saving book progress: $e"); }
  }

  @override
  Widget build(BuildContext context) {
    print("ReaderScreen: build (isLoading: $isLoading, _epubOpenedSuccessfully: $_epubOpenedSuccessfully)");

    if (widget.book.id == null && !isLoading) { // Fallback UI if initState checks fail unexpectedly
      return Scaffold( appBar: AppBar(title: const Text('Error')), body: Center( child: Padding( padding: const EdgeInsets.all(16.0), child: Text( 'Failed to load book: Invalid data or file missing.', textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).colorScheme.error)), )), );
    }

    return Scaffold(
      // Body content is minimal as the native view takes over.
      body: Center(
        child: isLoading
            ? const Column( mainAxisAlignment: MainAxisAlignment.center, children: [ CircularProgressIndicator(), SizedBox(height: 20), Text('Preparing Book...'), ], ) // Initial loading
            : _epubOpenedSuccessfully
            ? Container(color: Theme.of(context).scaffoldBackgroundColor) // Placeholder while native view is active
            : Padding( // Error state if open failed
          padding: const EdgeInsets.all(20.0),
          child: Text( 'Failed to display the book.\nPlease try again later or check the file.', textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).colorScheme.error), ),
        ),
      ),
    );
  }
}