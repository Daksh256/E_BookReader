import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:vocsy_epub_viewer/epub_viewer.dart'; // For reader and scroll direction enum
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:provider/provider.dart'; // For state management
import 'package:path/path.dart' as path;
import 'dart:io';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert'; // Needed for json encoding/decoding

// --- Book Model ---
// Book model with robust JSON handling for locator
class Book {
  final int? id;
  final String title;
  final String filePath;
  // Store the full locator JSON string instead of just CFI
  final String lastLocatorJson;
  final int totalReadingTime; // In seconds
  final Map<String, List<String>> highlights;

  const Book({
    this.id,
    required this.title,
    required this.filePath,
    this.lastLocatorJson = '{}', // Default to empty JSON object string
    this.totalReadingTime = 0,
    this.highlights = const {},
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'title': title,
    'filePath': filePath,
    'lastLocatorJson': lastLocatorJson, // Use the new field name
    'totalReadingTime': totalReadingTime,
    'highlights': json.encode(highlights), // Keep highlights encoded
  };

  static Book fromMap(Map<String, dynamic> map) {
    Map<String, List<String>> decodedHighlights = {};
    if (map['highlights'] != null) {
      try {
        // Ensure highlights are decoded correctly, handle potential errors
        var decoded = json.decode(map['highlights']);
        if (decoded is Map) {
          decodedHighlights = Map<String, List<String>>.from(
            decoded.map((key, value) {
              if (value is List) {
                // Ensure inner list contains only strings
                return MapEntry(key.toString(), List<String>.from(value.map((e) => e.toString())));
              }
              // Handle cases where value might not be a List, return empty list
              return MapEntry(key.toString(), <String>[]);
            }),
          );
        }
      } catch (e) {
        print("Error decoding highlights for book ID ${map['id']}: $e");
        // Assign empty map on error
        decodedHighlights = {};
      }
    }

    return Book(
      id: map['id'],
      title: map['title'] ?? 'Untitled', // Provide default title
      filePath: map['filePath'] ?? '', // Provide default path
      lastLocatorJson: map['lastLocatorJson'] ?? '{}', // Load locator JSON, default to empty
      totalReadingTime: map['totalReadingTime'] ?? 0,
      highlights: decodedHighlights,
    );
  }


  Book copyWith({
    int? id,
    String? title,
    String? filePath,
    String? lastLocatorJson, // Use the new field name
    int? totalReadingTime,
    Map<String, List<String>>? highlights,
  }) => Book(
    id: id ?? this.id,
    title: title ?? this.title,
    filePath: filePath ?? this.filePath,
    lastLocatorJson: lastLocatorJson ?? this.lastLocatorJson, // Update copyWith
    totalReadingTime: totalReadingTime ?? this.totalReadingTime,
    highlights: highlights ?? this.highlights,
  );
}

// --- Database Helper ---
// Singleton Database Helper
class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  static Database? _database;

  factory DatabaseHelper() => _instance;
  DatabaseHelper._internal();

  Future<Database> get database async {
    return _database ??= await _initDatabase();
  }

  Future<Database> _initDatabase() async {
    final dbPath = path.join(await getDatabasesPath(), 'books_database.db');
    print("Database path: $dbPath"); // Log database path
    return await openDatabase(
      dbPath,
      version: 1, // Start with version 1
      onCreate: (db, version) {
        print("Creating database table 'books' version $version");
        return db.execute(
          // Updated schema to use lastLocatorJson and store highlights as TEXT (JSON)
          'CREATE TABLE books(id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT, filePath TEXT, lastLocatorJson TEXT, totalReadingTime INTEGER DEFAULT 0, highlights TEXT DEFAULT \'{}\')',
        );
      },
      // Optional: Add onUpgrade for future schema changes
      // onUpgrade: (db, oldVersion, newVersion) async {
      //   print("Upgrading database from version $oldVersion to $newVersion");
      //   if (oldVersion < 2) {
      //     // Example: Add a new column if upgrading from version 1
      //     // await db.execute('ALTER TABLE books ADD COLUMN someNewField TEXT');
      //   }
      // },
    );
  }

  Future<void> insertBook(Book book) async {
    try {
      final db = await database;
      int id = await db.insert(
        'books',
        book.toMap(), // Use the model's toMap method
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      print("Book inserted/replaced: ${book.title} with new ID: $id");
    } catch (e) {
      print("Error inserting book ${book.title}: $e");
      // Re-throw the error if you want calling functions to handle it
      // throw e;
    }
  }

  Future<List<Book>> getBooks() async {
    // No try-catch here, let the caller handle DB errors
    final db = await database;
    // Order by title for consistency
    final maps = await db.query('books', orderBy: 'title ASC');
    if (maps.isEmpty) {
      print("No books found in database.");
      return [];
    }
    // Use List.generate for potentially slightly better performance on large lists
    List<Book> books = List.generate(maps.length, (i) {
      try {
        return Book.fromMap(maps[i]);
      } catch (e) {
        print("Error creating Book object from map: ${maps[i]}, Error: $e");
        // In a production app, you might want to handle corrupted data differently
        // For now, we return null and filter later.
        return null;
      }
    }).where((book) => book != null).cast<Book>().toList(); // Filter out nulls from failed parsing

    print("Loaded ${books.length} books from database.");
    return books;
    // No general catch block here in the helper - let errors propagate
  }

  Future<void> updateBook(Book book) async {
    if (book.id == null) {
      print("Error updating book: ID is null for title '${book.title}'");
      return; // Or throw an error
    }
    try {
      final db = await database;
      int count = await db.update(
        'books',
        book.toMap(), // Use the model's toMap method
        where: 'id = ?',
        whereArgs: [book.id],
      );
      print("Updated book ID ${book.id}. Rows affected: $count");
    } catch (e) {
      print("Error updating book ID ${book.id}: $e");
      // throw e; // Optional: re-throw
    }
  }

  // Specific method to update metadata like reading time and highlights
  Future<void> updateBookMetadata(int bookId, {int? readingTime, String? chapter, String? highlight}) async {
    try {
      final db = await database;
      final books = await db.query('books', where: 'id = ?', whereArgs: [bookId]);

      if (books.isNotEmpty) {
        final book = Book.fromMap(books.first); // Create Book object from DB data

        final updatedBook = book.copyWith(
          // Accumulate reading time safely, ensuring non-null value
          totalReadingTime: (book.totalReadingTime) + (readingTime ?? 0),
          // Add highlight if provided
          highlights: highlight != null && chapter != null
              ? _addHighlight(book.highlights, chapter, highlight)
              : book.highlights, // Keep existing highlights if none added
        );

        // Use the general updateBook method to save changes
        await updateBook(updatedBook); // This already has try-catch
        print("Updated metadata for book ID $bookId. New time: ${updatedBook.totalReadingTime}, Highlight added: ${highlight != null}");
      } else {
        print("Attempted to update metadata, but book ID $bookId not found.");
      }
    } catch(e) {
      print("Error fetching book for metadata update (ID: $bookId): $e");
      // throw e; // Optional: re-throw
    }
  }

  // Helper to add a highlight to the map (returns a new map)
  Map<String, List<String>> _addHighlight(Map<String, List<String>> highlights, String chapter, String text) {
    // Create a deep copy to avoid modifying the original map indirectly
    final updatedHighlights = Map<String, List<String>>.from(highlights.map(
          (key, value) => MapEntry(key, List<String>.from(value)), // Ensure lists are modifiable copies
    ));
    // Add the new highlight
    updatedHighlights.update(
      chapter,
          (list) => list..add(text), // Add to existing list
      ifAbsent: () => [text], // Create new list if chapter doesn't exist
    );
    print("Highlight added for chapter '$chapter'. Total chapters with highlights: ${updatedHighlights.length}");
    return updatedHighlights; // Return the new map
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
      // throw e; // Optional: re-throw
    }
  }
}

// --- Reading Settings Provider ---
// Manages user preferences for reading appearance and behavior
class ReadingSettings extends ChangeNotifier {
  static const _fontSizeKey = 'fontSize';
  static const _fontFamilyKey = 'fontFamily';
  static const _lineHeightKey = 'lineHeight';
  static const _scrollDirectionKey = 'scrollDirection'; // Key for scroll preference

  // Default values
  double _fontSize = 16;
  String _fontFamily = 'Roboto'; // Ensure 'Roboto' is available or change default
  double _lineHeight = 1.4;
  EpubScrollDirection _scrollDirection = EpubScrollDirection.HORIZONTAL; // Default

  // Public getters
  double get fontSize => _fontSize;
  String get fontFamily => _fontFamily;
  double get lineHeight => _lineHeight;
  EpubScrollDirection get scrollDirection => _scrollDirection;

  ReadingSettings() {
    loadSettings(); // Load settings when the provider is initialized
  }

  // Load settings from SharedPreferences
  Future<void> loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _fontSize = prefs.getDouble(_fontSizeKey) ?? _fontSize; // Use default if not found
      _fontFamily = prefs.getString(_fontFamilyKey) ?? _fontFamily;
      _lineHeight = prefs.getDouble(_lineHeightKey) ?? _lineHeight;

      // Load scroll direction by name (string)
      final savedDirectionName = prefs.getString(_scrollDirectionKey);
      _scrollDirection = EpubScrollDirection.values.firstWhere(
            (e) => e.name == savedDirectionName, // Compare enum names
        orElse: () => EpubScrollDirection.HORIZONTAL, // Default if not found/invalid
      );

      print(
          "Loaded settings: Size=$_fontSize, Family=$_fontFamily, LineHeight=$_lineHeight, Scroll=$_scrollDirection");
      notifyListeners(); // Notify listeners after loading
    } catch (e) {
      print("Error loading settings: $e");
      // Ensure defaults are set on error
      _fontSize = 16;
      _fontFamily = 'Roboto';
      _lineHeight = 1.4;
      _scrollDirection = EpubScrollDirection.HORIZONTAL;
    }
  }

  // Update a specific setting
  void updateSetting(String key, dynamic value) {
    bool changed = false;
    switch (key) {
      case _fontSizeKey:
        if (_fontSize != value && value is double) { _fontSize = value; changed = true; }
        break;
      case _fontFamilyKey:
        if (_fontFamily != value && value is String) { _fontFamily = value; changed = true; }
        break;
      case _lineHeightKey:
        if (_lineHeight != value && value is double) { _lineHeight = value; changed = true; }
        break;
      case _scrollDirectionKey: // Handle scroll direction update
        if (_scrollDirection != value && value is EpubScrollDirection) {
          _scrollDirection = value; changed = true;
        }
        break;
    }
    if (changed) {
      _saveSettings(); // Save changes to SharedPreferences
      notifyListeners(); // Notify listeners of the change
      print("Updated setting: $key = $value");
    }
  }

  // Save all current settings to SharedPreferences
  Future<void> _saveSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await Future.wait([
        prefs.setDouble(_fontSizeKey, _fontSize),
        prefs.setString(_fontFamilyKey, _fontFamily),
        prefs.setDouble(_lineHeightKey, _lineHeight),
        // Save scroll direction enum by its name (string)
        prefs.setString(_scrollDirectionKey, _scrollDirection.name),
      ]);
      print("Settings saved.");
    } catch (e) {
      print("Error saving settings: $e");
    }
  }
}

// --- Reading Time Tracker ---
// Utility class to track reading time for a specific book session
class ReadingTimeTracker {
  final int bookId;
  final DatabaseHelper databaseHelper;

  DateTime? _startTime;
  Timer? _timer;
  int _sessionSeconds = 0; // Seconds tracked in the current session

  ReadingTimeTracker({required this.bookId, required this.databaseHelper});

  // Start the timer
  void startTracking() {
    if (_timer?.isActive ?? false) {
      print("Time tracking already active for book ID $bookId.");
      return; // Avoid multiple timers
    }

    _startTime = DateTime.now();
    _sessionSeconds = 0; // Reset session counter
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _sessionSeconds++;
      // Optional: print("Book $bookId - Session time: $_sessionSeconds s");
    });
    print("Started time tracking for book ID $bookId.");
  }

  // Stop the timer and save the accumulated session time to the database
  Future<void> stopAndSaveTracking() async {
    if (!(_timer?.isActive ?? false) && _sessionSeconds == 0) {
      // No active timer or no time tracked, nothing to save
      print("Time tracking stop called for book ID $bookId, but no active session or time recorded.");
      _timer?.cancel();
      _timer = null;
      _resetTrackingState();
      return;
    }

    _timer?.cancel(); // Stop the timer
    _timer = null;

    if (_startTime != null && _sessionSeconds > 0) {
      print("Stopping time tracking for book ID $bookId. Session duration: $_sessionSeconds seconds.");
      try {
        // Use the specific metadata update method
        await databaseHelper.updateBookMetadata(
          bookId,
          readingTime: _sessionSeconds, // Pass only the session time
        );
        print("Saved session time ($_sessionSeconds s) for book ID $bookId.");
      } catch (e) {
        print("Error saving reading time for book ID $bookId: $e");
      }
      _resetTrackingState(); // Reset state after saving
    } else {
      print("Time tracking stopped for book ID $bookId, but no time was recorded in this session.");
      _resetTrackingState(); // Still reset state
    }
  }

  // Reset internal tracking state
  void _resetTrackingState() {
    _sessionSeconds = 0;
    _startTime = null;
    // print("Resetting tracking state for book ID $bookId.");
  }

  // Static method to format total reading time (in seconds) into a user-friendly string
  static String formatTotalReadingTime(int totalSeconds) {
    if (totalSeconds <= 0) return '0 minutes';
    final duration = Duration(seconds: totalSeconds);
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);

    String result = '';
    if (hours > 0) {
      result += '$hours hour${hours == 1 ? '' : 's'} ';
    }
    if (minutes > 0 || hours == 0) { // Show minutes if > 0 or if hours is 0 and totalSeconds > 0
      result += '$minutes minute${minutes == 1 ? '' : 's'}';
    }
    // Handle cases very close to zero but not exactly zero
    if (result.trim().isEmpty && totalSeconds > 0) {
      return '< 1 minute';
    }
    return result.trim();
  }
}

// --- Main Application Entry Point ---
void main() async {
  // Ensure Flutter bindings are initialized for plugins
  WidgetsFlutterBinding.ensureInitialized();
  // Optional: Pre-initialize database if needed, though it's lazy-loaded
  // await DatabaseHelper().database;

  runApp(
    // Provide the ReadingSettings to the widget tree
    ChangeNotifierProvider(
      create: (context) => ReadingSettings(), // Create instance of the provider
      child: const EpubReaderApp(), // Your main application widget
    ),
  );
}

// --- Main App Widget (MaterialApp) ---
class EpubReaderApp extends StatelessWidget {
  const EpubReaderApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    // Access ReadingSettings provided by ChangeNotifierProvider
    // We use watch here so the theme updates if the font family changes
    final readingSettings = context.watch<ReadingSettings>();

    return MaterialApp(
      debugShowCheckedModeBanner: false, // Disable debug banner
      title: 'Flutter EPUB Reader',
      theme: ThemeData(
        // Use Material 3 styling
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo, brightness: Brightness.light),
        fontFamily: readingSettings.fontFamily, // Apply selected font family
        // Light theme customizations (can use colorScheme properties)
        cardTheme: CardTheme(
          elevation: 1.0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 5), // Default card margin
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo, brightness: Brightness.dark),
        fontFamily: readingSettings.fontFamily, // Apply selected font family
        // Dark theme customizations
        cardTheme: CardTheme(
          elevation: 1.0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        ),
      ),
      themeMode: ThemeMode.system, // Follow system preference for light/dark mode
      home: const LibraryScreen(), // Start with the library screen
    );
  }
}


// --- Library Screen ---
// Displays the list of imported books as a grid of covers (UPDATED UI)
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
    _loadBooks(); // Load books when the screen initializes
  }

  // Load books from the database (with error handling)
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
        setState(() {
          books = loadedBooks;
          isLoading = false;
          print("LibraryScreen: _loadBooks - Inside setState. isLoading=false, books=${books.length}");
        });
      } else {
        print("LibraryScreen: _loadBooks - Load books completed but widget was disposed.");
      }
    } catch (e, stackTrace) {
      print("LibraryScreen: _loadBooks - Error loading books: $e");
      print(stackTrace);
      if (mounted) {
        setState(() {
          isLoading = false; // Stop loading indicator even on error
          books = []; // Ensure books list is empty on error
        });
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Error loading library. Please try again.'), backgroundColor: Colors.red)
        );
      }
    }
  }

  // Pick an EPUB file and import it (with duplicate check and loading indicator)
  Future<void> _pickAndImportBook() async {
    print("LibraryScreen: Picking file...");
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['epub'],
      );
    } catch (e) {
      print("LibraryScreen: File picking error: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error picking file: ${e.toString()}'))
        );
      }
      return;
    }

    if (result != null && result.files.single.path != null) {
      File sourceFile = File(result.files.single.path!);
      String originalFileName = result.files.single.name;
      print("LibraryScreen: File picked: $originalFileName at ${sourceFile.path}");

      // Show loading indicator during import
      if (mounted) setState(() => isLoading = true);


      try {
        Directory appDocDir = await getApplicationDocumentsDirectory();
        String booksDir = path.join(appDocDir.path, 'epubs');
        Directory dir = Directory(booksDir);
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        String newPath = path.join(booksDir, originalFileName);

        // Check for duplicates based on target path before copying
        final currentBooksInDb = await _databaseHelper.getBooks(); // Check DB *before* copy
        bool bookExists = currentBooksInDb.any((book) => book.filePath == newPath);

        if (bookExists) {
          print("LibraryScreen: Book file path already exists in library: $newPath. Skipping import.");
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('This book is already in your library.')),
            );
            // Stop loading indicator if skipping
            setState(() => isLoading = false);
          }
          return; // Don't add the book again
        }

        // --- Proceed with copy and DB insert only if book is not duplicate ---
        print("LibraryScreen: Copying from ${sourceFile.path} to $newPath");
        await sourceFile.copy(newPath);
        print("LibraryScreen: File copied successfully.");

        Book newBook = Book(
          title: originalFileName.replaceAll(RegExp(r'\.epub$', caseSensitive: false), ''),
          filePath: newPath,
          lastLocatorJson: '{}',
          totalReadingTime: 0,
          highlights: {},
        );
        await _databaseHelper.insertBook(newBook);
        print("LibraryScreen: Book saved to database.");
        await _loadBooks(); // Reload the list (this will set isLoading = false)

      } catch (e) {
        print("LibraryScreen: Error copying or saving book: $e");
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Error importing book: ${e.toString()}'))
          );
          // Ensure loading indicator stops on error
          setState(() => isLoading = false);
        }
      }
    } else {
      print("LibraryScreen: File picking cancelled.");
      // No need for snackbar here, it's a normal user action
    }
  }

  // Show confirmation dialog before deleting a book
  void _confirmAndDeleteBook(Book book) {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext ctx) {
        return AlertDialog(
          title: const Text('Delete Book?'),
          content: Text('Are you sure you want to permanently delete "${book.title}"?\n\nThis will remove the book file, reading progress, and all associated highlights.'),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () => Navigator.of(ctx).pop(),
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.red.shade700),
              child: const Text('Delete Permanently'),
              onPressed: () async {
                Navigator.of(ctx).pop();
                await _deleteBook(book);
              },
            ),
          ],
        );
      },
    );
  }

  // Delete the book file and database record (with loading indicator)
  Future<void> _deleteBook(Book book) async {
    print("LibraryScreen: Deleting book ID ${book.id} - ${book.title}");
    if (book.id == null) {
      print("Error: Cannot delete book with null ID.");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Error: Cannot delete book without an ID.')),
        );
      }
      return;
    }

    if (mounted) setState(() { isLoading = true; }); // Show loading during delete

    try {
      final file = File(book.filePath);
      if (await file.exists()) {
        await file.delete();
        print("LibraryScreen: Deleted file ${book.filePath}");
      } else {
        print("LibraryScreen: File not found for deletion, proceeding to delete DB record: ${book.filePath}");
      }
      await _databaseHelper.deleteBook(book.id!);
      print("LibraryScreen: Deleted book record from database (ID: ${book.id}).");
      await _loadBooks(); // Refresh the list (also sets isLoading=false)

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('"${book.title}" deleted successfully.')),
        );
      }
    } catch (e) {
      print("LibraryScreen: Error deleting book ID ${book.id}: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error deleting "${book.title}".')),
        );
        setState(() { isLoading = false; }); // Ensure loading stops on error
      }
    }
  }

  // Navigate to the ReaderScreen for the selected book
  void _openReader(Book book) {
    if (book.id == null) {
      print("LibraryScreen: Cannot open book, ID is null for title '${book.title}'");
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Error: Book data is incomplete. Cannot open.')),
      );
      return;
    }
    final file = File(book.filePath);
    if (!file.existsSync()) {
      print("LibraryScreen: Error - Book file not found at ${book.filePath} before opening reader.");
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Error: Book file is missing or moved. Cannot open.')),
      );
      return;
    }

    print("LibraryScreen: Opening reader for book ID ${book.id} - ${book.title}");
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ReaderScreen(book: book),
      ),
    ).then((_) {
      print("LibraryScreen: Returned from ReaderScreen. Reloading books.");
      _loadBooks();
    });
  }

  // --- Build Method ---
  @override
  Widget build(BuildContext context) {
    print("LibraryScreen: build - isLoading: $isLoading, books.length: ${books.length}");
    return Scaffold(
      appBar: AppBar(
        title: const Text('My EPUB Library'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const SettingsScreen()),
              );
            },
          ),
        ],
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : books.isEmpty
          ? _buildEmptyLibraryView()
          : RefreshIndicator(
        onRefresh: _loadBooks,
        child: _buildBookGridView(), // Use the Grid view
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _pickAndImportBook,
        tooltip: 'Import EPUB Book',
        child: const Icon(Icons.add),
      ),
    );
  }

  // Widget for the Empty Library View
  Widget _buildEmptyLibraryView() {
    return Center(
      child: Padding( // Add padding for better spacing on small screens
        padding: const EdgeInsets.all(20.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.library_books_outlined, size: 70, color: Colors.grey),
            const SizedBox(height: 20),
            Text(
              'Your library is empty.',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(color: Colors.grey),
            ),
            const SizedBox(height: 10),
            Text(
              'Tap the "+" button below to import an EPUB file from your device.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey),
            ),
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

  // Widget to display the grid of books (Corrected Implementation)
  Widget _buildBookGridView() {
    final screenWidth = MediaQuery.of(context).size.width;
    final crossAxisCount = (screenWidth / 140).floor().clamp(2, 5);
    final double gridPadding = 12.0; // Padding around the grid
    final double crossAxisSpacing = 12.0; // Horizontal space between items
    final double mainAxisSpacing = 16.0; // Vertical space between items

    // Calculate item width considering spacing
    final double itemWidth = (screenWidth - (gridPadding * 2) - (crossAxisSpacing * (crossAxisCount - 1))) / crossAxisCount;

    final double coverHeight = itemWidth * 1.4; // Height relative to width (adjust ratio as needed)
    // --- Overflow Fix: Increased estimated text height ---
    final double textHeight = 50; // Increased from 45 to give more space for 2 lines + padding

    // Calculate aspect ratio for the whole item (Width / Total Height)
    final double childAspectRatio = itemWidth / (coverHeight + textHeight);

    print("LibraryScreen: Grid - ScreenWidth: $screenWidth, Cols: $crossAxisCount, ItemWidth: $itemWidth, CoverHeight: $coverHeight, TextHeightEst: $textHeight, ChildAspect: $childAspectRatio");

    return GridView.builder(
      key: const PageStorageKey('libraryGrid'), // Preserve scroll position
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
          return Material( // Use Material for InkWell splash effects
            color: Colors.transparent,
            child: InkWell(
              onTap: () => _openReader(book),
              onLongPress: () => _confirmAndDeleteBook(book),
              borderRadius: BorderRadius.circular(8.0), // Match Ink clipping
              child: Column(
                mainAxisAlignment: MainAxisAlignment.start, // Align children to top
                children: [
                  // --- Cover Placeholder ---
                  Ink( // Use Ink for decoration inside InkWell
                    height: coverHeight, // Fixed height for the cover area
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceVariant,
                      borderRadius: BorderRadius.circular(8.0),
                    ),
                    child: Center(
                      child: Icon(
                        Icons.menu_book,
                        size: 40.0,
                        color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.8),
                      ),
                    ),
                  ),
                  // --- Title ---
                  Padding(
                    // Reduced top padding slightly
                    padding: const EdgeInsets.only(top: 6.0, left: 4.0, right: 4.0),
                    child: Text(
                      book.title,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                        height: 1.25, // Slightly increased line height might also help
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        } catch (e, stackTrace) {
          print("LibraryScreen: Error in Grid itemBuilder at index $index: $e");
          print(stackTrace);
          // Error placeholder for specific item
          return Container(
            decoration: BoxDecoration(
              color: Colors.red.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8.0),
              border: Border.all(color: Colors.red),
            ),
            child: const Center(child: Icon(Icons.error_outline, color: Colors.red, size: 30)),
          );
        }
      },
    );
  }
}


// --- Settings Screen ---
// Allows adjusting reading preferences (Font, Size, Line Height, Scroll Direction)
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    // Use Consumer for reacting to changes in settings
    return Consumer<ReadingSettings>(
      builder: (context, readingSettings, child) {
        return Scaffold(
          appBar: AppBar(title: const Text('Settings')),
          body: ListView(
            padding: const EdgeInsets.all(8.0),
            children: [
              // --- Appearance Section ---
              _buildSectionHeader(context, 'Appearance'),
              _buildFontSizeSetting(context, readingSettings),
              _buildLineHeightSetting(context, readingSettings),
              _buildFontFamilySetting(context, readingSettings),
              _buildScrollDirectionSetting(context, readingSettings), // Add Scroll Direction
              const Divider(height: 20, thickness: 1),

              // --- About Section ---
              _buildSectionHeader(context, 'About'),
              _buildAboutTile(context),
            ],
          ),
        );
      },
    );
  }

  // Helper for Section Headers
  Widget _buildSectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 16.0),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  // Font Size Slider Setting
  Widget _buildFontSizeSetting(BuildContext context, ReadingSettings settings) {
    return ListTile(
      title: const Text('Font Size'),
      subtitle: Text('${settings.fontSize.toInt()} pt'),
      trailing: SizedBox(
        width: MediaQuery.of(context).size.width * 0.5, // Limit slider width
        child: Slider(
          value: settings.fontSize,
          min: 12,
          max: 32,
          divisions: 20, // Granularity
          label: '${settings.fontSize.toInt()}',
          onChanged: (value) {
            settings.updateSetting(ReadingSettings._fontSizeKey, value);
          },
        ),
      ),
    );
  }

  // Line Height Slider Setting
  Widget _buildLineHeightSetting(BuildContext context, ReadingSettings settings) {
    return ListTile(
      title: const Text('Line Height'),
      subtitle: Text(settings.lineHeight.toStringAsFixed(1)),
      trailing: SizedBox(
        width: MediaQuery.of(context).size.width * 0.5,
        child: Slider(
          value: settings.lineHeight,
          min: 1.0,
          max: 2.0,
          divisions: 10,
          label: settings.lineHeight.toStringAsFixed(1),
          onChanged: (value) {
            settings.updateSetting(ReadingSettings._lineHeightKey, value);
          },
        ),
      ),
    );
  }

  // Font Family Dropdown Setting
  Widget _buildFontFamilySetting(BuildContext context, ReadingSettings settings) {
    // List of available fonts (ensure they are added to pubspec.yaml and assets if custom)
    const List<String> availableFonts = [
      'Roboto', 'Merriweather', 'OpenSans', 'Lato', 'Lora', 'SourceSerifPro'
    ];

    return ListTile(
      title: const Text('Font Family'),
      trailing: DropdownButton<String>(
        value: settings.fontFamily, // Current value
        items: availableFonts.map((String fontName) {
          return DropdownMenuItem<String>(
            value: fontName,
            child: Text(fontName),
          );
        }).toList(),
        onChanged: (value) {
          if (value != null) {
            settings.updateSetting(ReadingSettings._fontFamilyKey, value);
          }
        },
      ),
    );
  }

  // Scroll Direction Dropdown Setting
  Widget _buildScrollDirectionSetting(BuildContext context, ReadingSettings settings) {
    return ListTile(
      title: const Text('Scroll Direction'),
      trailing: DropdownButton<EpubScrollDirection>(
        value: settings.scrollDirection, // Current value
        items: const [
          // Create items for the supported enum values
          DropdownMenuItem(
            value: EpubScrollDirection.HORIZONTAL,
            child: Text('Horizontal (Pages)'),
          ),
          DropdownMenuItem(
            value: EpubScrollDirection.VERTICAL,
            child: Text('Vertical (Scroll)'),
          ),
          // You could add ALLDIRECTIONS if needed, but usually it's H or V
        ],
        onChanged: (value) {
          if (value != null) {
            // Update setting using the specific key and value
            settings.updateSetting(ReadingSettings._scrollDirectionKey, value);
          }
        },
      ),
    );
  }

  // About App Tile
  Widget _buildAboutTile(BuildContext context) {
    return ListTile(
      title: const Text('App Version'),
      subtitle: const Text('1.2.0 (Grid UI)'), // Example version
      leading: const Icon(Icons.info_outline),
      onTap: () {
        // Optional: Show licenses or more info dialog
        showAboutDialog(
          context: context,
          applicationName: 'Flutter EPUB Reader',
          applicationVersion: '1.2.0',
          applicationLegalese: '© 2025 Your Name/Company', // Replace as needed
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 15),
              child: Text('A simple EPUB reader built with Flutter and Vocsy EPUB Viewer.'),
            )
          ],
        );
      },
    );
  }
}


// --- Highlights Screen ---
// Displays saved highlights for a specific book, grouped by chapter
class HighlightsScreen extends StatelessWidget {
  final Book book;

  const HighlightsScreen({Key? key, required this.book}) : super(key: key);

  // Safely get the highlights map, ensuring correct type
  Map<String, List<String>> _getValidHighlights() {
    if (book.highlights is Map<String, List<String>>) {
      return book.highlights;
    } else {
      print("Warning: Highlights data is not Map<String, List<String>> for book ${book.id}. Returning empty.");
      return {}; // Return an empty map if type is incorrect
    }
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, List<String>> highlights = _getValidHighlights();
    final List<String> chapters = highlights.keys.toList(); // Get list of chapters with highlights
    print("HighlightsScreen: Displaying highlights for book ${book.id}. Chapters: ${chapters.length}");

    return Scaffold(
      appBar: AppBar(
          title: Text('Highlights: ${book.title}', overflow: TextOverflow.ellipsis)
      ),
      body: highlights.isEmpty
          ? Center( // Message when no highlights exist
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Text(
            'No highlights saved for this book yet.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.grey),
          ),
        ),
      )
          : ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 10.0, horizontal: 8.0),
        itemCount: chapters.length, // Number of chapters with highlights
        itemBuilder: (context, chapterIndex) {
          final String chapter = chapters[chapterIndex];
          // Ensure chapterHighlights is always a list (should be due to Map structure)
          final List<String> chapterHighlights = highlights[chapter] ?? [];

          // Skip rendering if a chapter somehow has an empty list (unlikely but safe)
          if (chapterHighlights.isEmpty) {
            return const SizedBox.shrink();
          }

          // Use Card and ExpansionTile for better UI
          return Card(
            // Use Card defaults from theme
            // margin: const EdgeInsets.symmetric(vertical: 6),
            // elevation: 1.5,
            child: ExpansionTile(
              // Display chapter name or fallback
              title: Text(chapter.isNotEmpty ? chapter : 'Unknown Chapter',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              initiallyExpanded: true, // Keep chapters expanded by default
              childrenPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              children: chapterHighlights.map((text) {
                // Build widget for each highlight text
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8.0),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      // Use theme colors for background/border
                        color: Theme.of(context).colorScheme.secondaryContainer.withOpacity(0.5),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Theme.of(context).colorScheme.outline.withOpacity(0.3))
                    ),
                    child: SelectableText( // Allow text selection
                      text,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontStyle: FontStyle.italic,
                        height: 1.4, // Improve readability
                      ),
                    ),
                    // Add copy/share actions here if needed later
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
// Handles displaying the EPUB content using VocsyEpubViewer
class ReaderScreen extends StatefulWidget {
  final Book book; // Receive the full Book object

  const ReaderScreen({Key? key, required this.book}) : super(key: key);

  @override
  _ReaderScreenState createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> with WidgetsBindingObserver {
  bool isLoading = true; // Indicates if the EPUB is being prepared
  late ReadingTimeTracker _timeTracker;
  late DatabaseHelper _databaseHelper; // Use instance for updates
  bool _epubOpenedSuccessfully = false; // Track if VocsyEpub.open was called without error
  StreamSubscription? _locatorSubscription; // To manage the page/location listener

  @override
  void initState() {
    super.initState();
    print("ReaderScreen: initState for book ID ${widget.book.id} - ${widget.book.title}");
    WidgetsBinding.instance.addObserver(this); // Observe app lifecycle changes
    _databaseHelper = DatabaseHelper(); // Initialize database helper instance

    // --- Crucial Check: Ensure book ID is valid ---
    if (widget.book.id == null) {
      print("ReaderScreen: FATAL ERROR - Book ID is null. Cannot initialize reader.");
      // Use addPostFrameCallback to show SnackBar and pop after the build phase
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Error: Cannot open book due to missing data.'),
                backgroundColor: Colors.red),
          );
          Navigator.pop(context); // Go back immediately
        }
      });
      setState(() { isLoading = false; }); // Stop loading indicator
      return; // Halt initialization
    }

    // --- Check if file exists before proceeding ---
    final file = File(widget.book.filePath);
    if (!file.existsSync()) {
      print("ReaderScreen: FATAL ERROR - Book file not found at ${widget.book.filePath}.");
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Error: Book file is missing or moved.'),
                backgroundColor: Colors.red),
          );
          Navigator.pop(context);
        }
      });
      setState(() { isLoading = false; });
      return; // Halt initialization
    }


    // Initialize time tracker only if ID is valid
    _timeTracker = ReadingTimeTracker(
      bookId: widget.book.id!,
      databaseHelper: _databaseHelper,
    );

    // Start opening the EPUB asynchronously
    _openEpub();
  }

  @override
  void dispose() {
    print("ReaderScreen: dispose for book ID ${widget.book.id}");
    WidgetsBinding.instance.removeObserver(this); // Stop observing lifecycle

    // Cancel the stream subscription to prevent memory leaks and errors
    _locatorSubscription?.cancel();
    print("ReaderScreen: Locator stream listener cancelled.");

    // Stop and save time tracking *only if* initialized (i.e., book ID was valid)
    // Ensure this runs reliably before the widget is fully gone.
    // Check for `_epubOpenedSuccessfully` ensures we only save if the book was opened.
    if (widget.book.id != null && _epubOpenedSuccessfully) {
      print("ReaderScreen: Stopping and saving time tracking before dispose.");
      // Don't await here in dispose, fire and forget is safer
      _timeTracker.stopAndSaveTracking();
    } else {
      print("ReaderScreen: Skipping time save on dispose (book ID null or EPUB not opened).");
    }

    // Optional: Attempt to close the native EPUB view if the library supports it explicitly.
    // try {
    //   VocsyEpub.close(); // If such a method exists
    //   print("ReaderScreen: Called VocsyEpub.close()");
    // } catch (e) {
    //   print("ReaderScreen: Error calling VocsyEpub.close(): $e");
    // }

    print("ReaderScreen: Disposed.");
    super.dispose();
  }

  // Handle app lifecycle changes (pause, resume) for time tracking
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    print("ReaderScreen: AppLifecycleState changed to $state for book ID ${widget.book.id}");

    // Only manage time tracking if the book ID is valid and EPUB was opened
    if (widget.book.id == null || !_epubOpenedSuccessfully) {
      print("ReaderScreen: Ignoring lifecycle change (book ID null or EPUB not opened).");
      return;
    }

    switch (state) {
      case AppLifecycleState.resumed:
        print("ReaderScreen: App resumed, starting time tracking.");
        _timeTracker.startTracking();
        break;
      case AppLifecycleState.inactive: // App is inactive (e.g., phone call)
      case AppLifecycleState.paused:   // App is in background
      case AppLifecycleState.detached: // App is terminating
      case AppLifecycleState.hidden:   // App is hidden (new state)
        print("ReaderScreen: App inactive/paused/detached/hidden, stopping and saving time tracking.");
        // Stop and save time when app loses focus or closes
        _timeTracker.stopAndSaveTracking(); // Use await if critical, but might delay pausing
        break;
    }
  }

  // Asynchronously configure and open the EPUB using VocsyEpubViewer
  Future<void> _openEpub() async {
    print("ReaderScreen: _openEpub called.");
    // Redundant checks, but safe
    if (widget.book.id == null) {
      print("ReaderScreen: _openEpub - Cannot proceed, book ID is null.");
      if (mounted) setState(() { isLoading = false; });
      return;
    }
    final file = File(widget.book.filePath);
    if (!await file.exists()) {
      print("ReaderScreen: Error - Book file disappeared before opening: ${widget.book.filePath}");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error: Book file is missing.'), backgroundColor: Colors.red));
        Navigator.pop(context);
        setState(() { isLoading = false; });
      }
      return;
    }

    // Access reading settings via Provider (listen: false as we need it only once here)
    final readingSettings = Provider.of<ReadingSettings>(context, listen: false);
    final bool isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final EpubScrollDirection scrollDirection = readingSettings.scrollDirection;

    print("ReaderScreen: Configuring VocsyEpub...");
    print("  - Identifier: book_${widget.book.id}"); // Use unique identifier per book
    print("  - Scroll Direction: $scrollDirection"); // Use selected direction
    print("  - Night Mode: $isDarkMode");

    try {
      // Configure the EPUB viewer settings
      VocsyEpub.setConfig(
        themeColor: Theme.of(context).colorScheme.primary, // Use theme color
        identifier: "book_${widget.book.id}",      // Unique ID for the reader instance
        scrollDirection: scrollDirection,            // Apply user preference
        allowSharing: true,                        // Allow sharing text
        enableTts: false,                          // Text-to-speech disabled for simplicity
        nightMode: isDarkMode,                     // Sync with app's theme
      );

      print("ReaderScreen: Configuration set. Attempting to load last location...");
      // Decode the stored locator JSON string into an EpubLocator object
      EpubLocator? lastKnownLocator;
      if (widget.book.lastLocatorJson.isNotEmpty && widget.book.lastLocatorJson != '{}') {
        print("ReaderScreen: Found saved locator JSON: ${widget.book.lastLocatorJson}");
        try {
          Map<String, dynamic> decodedLocatorMap = json.decode(widget.book.lastLocatorJson);
          // Basic validation of the map structure (ensure required fields exist)
          if (decodedLocatorMap.containsKey('bookId') &&
              decodedLocatorMap.containsKey('href') &&
              decodedLocatorMap.containsKey('created') &&
              decodedLocatorMap.containsKey('locations') &&
              decodedLocatorMap['locations'] is Map &&
              decodedLocatorMap['locations'].containsKey('cfi'))
          {
            lastKnownLocator = EpubLocator.fromJson(decodedLocatorMap);
            print("ReaderScreen: Successfully decoded last location.");
          } else {
            print("ReaderScreen: Warning - Saved locator JSON has missing/invalid fields. Opening from start.");
          }
        } catch (e) {
          print("ReaderScreen: Error decoding locator JSON '${widget.book.lastLocatorJson}': $e. Opening from start.");
          lastKnownLocator = null; // Ensure locator is null on error
        }
      } else {
        print("ReaderScreen: No valid saved location found. Opening from start.");
      }

      print("ReaderScreen: Calling VocsyEpub.open with path: ${widget.book.filePath} and locator: ${lastKnownLocator != null}");
      // Open the EPUB file, providing the last known location if available
      VocsyEpub.open(
        widget.book.filePath,
        lastLocation: lastKnownLocator,
      );

      // --- Setup Listeners and Tracking *after* calling open ---
      _epubOpenedSuccessfully = true; // Mark as successfully opened
      print("ReaderScreen: VocsyEpub.open called. Setting up listeners and starting timer.");

      _setupLocatorListener(); // Start listening for location changes from the reader
      _timeTracker.startTracking(); // Start tracking reading time

      // Update UI state to indicate loading is finished (native view takes over)
      if (mounted) {
        setState(() { isLoading = false; });
      }
      print("ReaderScreen: EPUB should now be visible.");

    } catch (e) {
      _epubOpenedSuccessfully = false; // Mark as failed on error
      print("ReaderScreen: CRITICAL Error during VocsyEpub configuration or open: $e");
      if (mounted) {
        setState(() { isLoading = false; });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error opening EPUB: ${e.toString()}'), backgroundColor: Colors.red),
        );
        // Pop back if opening fails critically to avoid blank screen
        Navigator.pop(context);
      }
    }
  }

  // Set up the listener for location changes emitted by VocsyEpubViewer
  void _setupLocatorListener() {
    print("ReaderScreen: Setting up locator stream listener for book ID ${widget.book.id}");
    // Cancel any existing subscription first
    _locatorSubscription?.cancel();

    // Listen to the stream
    _locatorSubscription = VocsyEpub.locatorStream.listen(
          (locatorData) {
        // This callback receives data whenever the location changes in the native view
        // print("ReaderScreen: Received locator data: $locatorData"); // Can be verbose

        Map<String, dynamic>? locatorMap;

        // Handle different possible data types (String JSON or Map)
        if (locatorData is String) {
          try {
            locatorMap = json.decode(locatorData);
          } catch (e) {
            print("ReaderScreen: Error decoding locator string: $e. Data: $locatorData");
            return; // Skip update if decoding fails
          }
        } else if (locatorData is Map) {
          // Ensure keys are strings if necessary, though jsonDecode usually handles this.
          try {
            locatorMap = Map<String, dynamic>.from(locatorData);
          } catch (e) {
            print("ReaderScreen: Error converting received map: $e. Data: $locatorData");
            return; // Skip update if conversion fails
          }
        }

        if (locatorMap != null) {
          // Basic validation: Check if essential fields exist before saving
          if (locatorMap.containsKey('bookId') &&
              locatorMap.containsKey('href') &&
              locatorMap.containsKey('locations') &&
              locatorMap['locations'] is Map &&
              locatorMap['locations'].containsKey('cfi'))
          {
            // Debounce or throttle updates here if they become too frequent
            // For now, update on every valid received locator
            _updateBookProgress(locatorMap); // Pass the validated map
          } else {
            print("ReaderScreen: Warning - Received locator map is missing required fields: $locatorMap");
          }
        } else {
          print("ReaderScreen: Received locator data in unrecognized format: ${locatorData?.runtimeType}");
        }
      },
      onError: (error) {
        // Handle errors from the stream itself
        print("ReaderScreen: Error in locator stream: $error");
        // Consider stopping time tracking or showing an error if the stream fails
        if(mounted && _epubOpenedSuccessfully) {
          _timeTracker.stopAndSaveTracking();
        }
      },
      onDone: () {
        // This is called when the stream is closed, often when the native view is dismissed
        print("ReaderScreen: Locator stream closed (onDone). Reader likely dismissed.");
        // Time tracking should ideally be stopped by lifecycle events (paused/detached) or dispose,
        // but we can add a safety stop here too.
        if (mounted && _epubOpenedSuccessfully) {
          print("ReaderScreen: Performing safety stop/save of time tracker on locator stream 'onDone'.");
          _timeTracker.stopAndSaveTracking();
        }
        // IMPORTANT: Do NOT pop here directly as it can cause issues if the user
        // is navigating back normally. Rely on dispose or lifecycle for cleanup.
      },
      cancelOnError: false, // Keep listening even if one event causes an error
    );
    print("ReaderScreen: Locator stream listener is now active.");
  }

  // Update the book's progress (last location) in the database
  Future<void> _updateBookProgress(Map<String, dynamic> locatorData) async {
    // Guard against null ID and ensure widget is still mounted
    if (widget.book.id == null || !mounted) {
      // print("ReaderScreen: Skipping progress update (ID null or unmounted)."); // Reduce log noise
      return;
    }

    try {
      // Encode the entire locator map to a JSON string for storage
      final String newLocatorJson = json.encode(locatorData);

      // --- Optimization: Only update if the locator JSON has actually changed ---
      // Read the *current* book data from the database for the comparison.
      final db = await _databaseHelper.database;
      // Use limit 1 for efficiency
      final currentBookData = await db.query('books', where: 'id = ?', whereArgs: [widget.book.id], limit: 1);

      if (currentBookData.isNotEmpty) {
        final String? currentLocatorJson = currentBookData.first['lastLocatorJson'] as String?;
        if (newLocatorJson != currentLocatorJson) {
          // print("ReaderScreen: New locator detected. Updating database."); // Reduce log noise
          // Update only the lastLocatorJson field in the database
          int count = await db.update(
            'books',
            {'lastLocatorJson': newLocatorJson}, // Map with only the field to update
            where: 'id = ?',
            whereArgs: [widget.book.id],
          );
          // print("ReaderScreen: Book progress updated in database. Rows affected: $count"); // Reduce log noise
        } // else { // print("ReaderScreen: Locator unchanged, skipping database update."); } // Reduce log noise
      } else {
        print("ReaderScreen: Warning - Book ID ${widget.book.id} not found in DB during progress update check.");
      }

    } catch (e) {
      print("ReaderScreen: Error encoding or saving book progress: $e");
      // Consider adding more robust error handling here if needed
    }
  }

  @override
  Widget build(BuildContext context) {
    print("ReaderScreen: build (isLoading: $isLoading, _epubOpenedSuccessfully: $_epubOpenedSuccessfully)");

    // Handle cases where initialization failed (null ID, file not found) - caught in initState
    if (widget.book.id == null && !isLoading) {
      // This state should ideally be handled by the immediate pop in initState,
      // but serves as a fallback UI if that fails.
      return Scaffold(
        appBar: AppBar(title: const Text('Error')),
        body: Center(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text('Failed to load book: Invalid data or file missing.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            )),
      );
    }

    // Return a basic Scaffold. The VocsyEpub viewer displays as an overlay/native view.
    // The body content here is mostly a placeholder shown during loading or if errors occur *after* initState.
    return Scaffold(
      // AppBar is usually not needed as the native reader provides controls
      body: Center(
        child: isLoading
            ? const Column( // State 1: Initial Loading
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 20),
            Text('Preparing Book...'),
          ],
        )
            : _epubOpenedSuccessfully
        // State 2: EPUB Opened - Native view is likely active.
        // Show minimal content, maybe just a background color or a subtle indicator.
            ? Container(color: Theme.of(context).scaffoldBackgroundColor) // Or SizedBox.shrink()
        // State 3: Error *after* trying to load/open (e.g., VocsyEpub.open failed)
            : Padding(
          padding: const EdgeInsets.all(20.0),
          child: Text(
            'Failed to display the book.\nPlease try again later or check the file.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      ),
    );
  }
}