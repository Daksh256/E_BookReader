import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:vocsy_epub_viewer/epub_viewer.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:provider/provider.dart'; // Make sure to include this in pubspec.yaml
import 'package:path/path.dart' as path;
import 'dart:io';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert'; // Needed for json encoding/decoding

// Book model with robust JSON handling for locator
class Book {
  final int? id;
  final String title;
  final String filePath;
  // Store the full locator JSON string instead of just CFI
  final String lastLocatorJson;
  final int totalReadingTime;
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
                return MapEntry(key, List<String>.from(value.map((e) => e.toString())));
              }
              // Handle cases where value might not be a List, return empty list
              return MapEntry(key, <String>[]);
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
      version: 1, // Increment version if schema changes
      onCreate: (db, version) {
        print("Creating database table 'books' version $version");
        return db.execute(
          // Updated schema to use lastLocatorJson
          'CREATE TABLE books(id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT, filePath TEXT, lastLocatorJson TEXT, totalReadingTime INTEGER, highlights TEXT)',
        );
      },
      // Optional: Add onUpgrade for future schema changes
      // onUpgrade: (db, oldVersion, newVersion) {
      //   print("Upgrading database from version $oldVersion to $newVersion");
      //   if (oldVersion < 2) {
      //     // Example: db.execute('ALTER TABLE books ADD COLUMN newField TEXT');
      //   }
      // },
    );
  }

  Future<void> insertBook(Book book) async {
    try {
      final db = await database;
      int id = await db.insert('books', book.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace
      );
      print("Book inserted/replaced: ${book.title} with new ID: $id"); // Log insertion with ID
    } catch (e) {
      print("Error inserting book ${book.title}: $e");
    }
  }


  Future<List<Book>> getBooks() async {
    try {
      final db = await database;
      final maps = await db.query('books');
      if (maps.isEmpty) {
        print("No books found in database.");
        return [];
      }
      List<Book> books = maps.map((map) {
        try {
          return Book.fromMap(map);
        } catch (e) {
          print("Error creating Book object from map: $map, Error: $e");
          return null; // Return null for maps that cause errors
        }
      }).where((book) => book != null).cast<Book>().toList(); // Filter out nulls
      print("Loaded ${books.length} books from database.");
      return books;
    } catch (e) {
      print("Error getting books from database: $e");
      return []; // Return empty list on error
    }
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
        book.toMap(),
        where: 'id = ?',
        whereArgs: [book.id],
      );
      print("Updated book ID ${book.id}. Rows affected: $count"); // Log update
    } catch (e) {
      print("Error updating book ID ${book.id}: $e");
    }
  }

  // updateBookMetadata can remain largely the same, as highlight logic is separate
  Future<void> updateBookMetadata(int bookId, {int? readingTime, String? chapter, String? highlight}) async {
    final db = await database;
    final books = await db.query('books', where: 'id = ?', whereArgs: [bookId]);

    if (books.isNotEmpty) {
      final book = Book.fromMap(books.first);

      final updatedBook = book.copyWith(
        totalReadingTime: (book.totalReadingTime) + (readingTime ?? 0), // Accumulate reading time
        highlights: highlight != null && chapter != null
            ? _addHighlight(book.highlights, chapter, highlight)
            : book.highlights,
      );

      await updateBook(updatedBook); // This uses the general updateBook method
      print("Updated metadata for book ID $bookId. New time: ${updatedBook.totalReadingTime}");
    } else {
      print("Attempted to update metadata, but book ID $bookId not found.");
    }
  }

  Map<String, List<String>> _addHighlight(Map<String, List<String>> highlights, String chapter, String text) {
    // Create a new map to avoid modifying the original directly during the operation
    final updatedHighlights = Map<String, List<String>>.from(highlights.map(
            (key, value) => MapEntry(key, List<String>.from(value)) // Ensure lists are modifiable copies
    ));
    // Add the new highlight
    updatedHighlights.update(
      chapter,
          (list) => list..add(text), // Add to existing list
      ifAbsent: () => [text],    // Create new list if chapter doesn't exist
    );
    print("Highlight added for chapter '$chapter'. Total chapters with highlights: ${updatedHighlights.length}");
    return updatedHighlights;
  }

  // Optional: Add a delete method
  Future<void> deleteBook(int id) async {
    try {
      final db = await database;
      int count = await db.delete(
        'books',
        where: 'id = ?',
        whereArgs: [id],
      );
      print("Deleted book ID $id. Rows affected: $count");
    } catch (e) {
      print("Error deleting book ID $id: $e");
    }
  }
}

// Reading Settings Provider (using Provider package)
class ReadingSettings extends ChangeNotifier {
  static const _fontSizeKey = 'fontSize';
  static const _fontFamilyKey = 'fontFamily';
  static const _lineHeightKey = 'lineHeight';

  double _fontSize = 16;
  String _fontFamily = 'Roboto';
  double _lineHeight = 1.4;

  double get fontSize => _fontSize;
  String get fontFamily => _fontFamily;
  double get lineHeight => _lineHeight;

  ReadingSettings() {
    loadSettings(); // Load settings when the provider is created
  }

  Future<void> loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _fontSize = prefs.getDouble(_fontSizeKey) ?? 16;
      _fontFamily = prefs.getString(_fontFamilyKey) ?? 'Roboto';
      _lineHeight = prefs.getDouble(_lineHeightKey) ?? 1.4;
      print("Loaded settings: Font Size=$_fontSize, Family=$_fontFamily, Line Height=$_lineHeight");
      notifyListeners();
    } catch (e) {
      print("Error loading settings: $e");
    }
  }

  void updateSetting(String key, dynamic value) {
    bool changed = false;
    switch (key) {
      case _fontSizeKey:
        if (_fontSize != value) { _fontSize = value; changed = true; }
        break;
      case _fontFamilyKey:
        if (_fontFamily != value) { _fontFamily = value; changed = true; }
        break;
      case _lineHeightKey:
        if (_lineHeight != value) { _lineHeight = value; changed = true; }
        break;
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
      ]);
      print("Settings saved.");
    } catch (e) {
      print("Error saving settings: $e");
    }
  }
}

// Reading Time Tracker
class ReadingTimeTracker {
  final int bookId;
  final DatabaseHelper databaseHelper;

  DateTime? _startTime;
  Timer? _timer;
  int _sessionSeconds = 0; // Seconds tracked in the current session

  ReadingTimeTracker({required this.bookId, required this.databaseHelper});

  void startTracking() {
    if (_timer?.isActive ?? false) {
      print("Time tracking already active for book ID $bookId.");
      return; // Already tracking
    }

    _startTime = DateTime.now();
    // Reset session seconds when starting a new tracking period
    _sessionSeconds = 0;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _sessionSeconds++;
      // Optional: print("Book $bookId - Session time: $_sessionSeconds s");
    });
    print("Started time tracking for book ID $bookId.");
  }

  // Call this when the reader screen is closed or paused
  Future<void> stopAndSaveTracking() async {
    if (!(_timer?.isActive ?? false) && _sessionSeconds == 0) {
      // Avoid saving if timer wasn't active or no time was tracked
      print("Time tracking stop called for book ID $bookId, but no active session or time recorded.");
      _timer?.cancel(); // Ensure timer is cancelled even if nothing to save
      _timer = null;
      _resetTrackingState();
      return;
    }

    _timer?.cancel();
    _timer = null; // Ensure timer is reset

    if (_startTime != null && _sessionSeconds > 0) {
      print("Stopping time tracking for book ID $bookId. Session duration: $_sessionSeconds seconds.");
      try {
        // Update the database with the time spent in this session
        await databaseHelper.updateBookMetadata(
            bookId,
            readingTime: _sessionSeconds
        );
        print("Saved session time ($_sessionSeconds s) for book ID $bookId.");
      } catch (e) {
        print("Error saving reading time for book ID $bookId: $e");
      }
      _resetTrackingState();
    } else {
      print("Time tracking stopped for book ID $bookId, but no time was recorded in this session.");
      _resetTrackingState(); // Still reset state
    }
  }

  void _resetTrackingState() {
    _sessionSeconds = 0;
    _startTime = null;
    // print("Resetting tracking state for book ID $bookId."); // Reduced verbosity
  }

  // Format total accumulated time (from Book object) for display
  static String formatTotalReadingTime(int totalSeconds) {
    if (totalSeconds <= 0) return '0 minutes';
    final duration = Duration(seconds: totalSeconds);
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);

    String result = '';
    if (hours > 0) {
      result += '$hours hour${hours == 1 ? '' : 's'} ';
    }
    if (minutes > 0 || hours == 0) { // Show minutes if > 0 or if hours is 0
      result += '$minutes minute${minutes == 1 ? '' : 's'}';
    }
    return result.trim();
  }
}

// Main Application Entry Point
void main() async {
  // Ensure Flutter bindings are initialized
  WidgetsFlutterBinding.ensureInitialized();
  // Initialize Database (optional, but good practice to ensure it's ready)
  // await DatabaseHelper().database; // You can pre-warm the database if needed

  runApp(
    // Use Provider for state management (ReadingSettings)
    ChangeNotifierProvider(
      create: (context) => ReadingSettings(),
      child: const EpubReaderApp(), // Use EpubReaderApp which includes MaterialApp
    ),
  );
}


// Main App Widget using MaterialApp
class EpubReaderApp extends StatelessWidget {
  const EpubReaderApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    // Access ReadingSettings provided by ChangeNotifierProvider
    final readingSettings = Provider.of<ReadingSettings>(context);

    return MaterialApp(
      debugShowCheckedModeBanner: false, // Disable debug banner
      title: 'Enhanced EPUB Reader',
      theme: ThemeData(
        primarySwatch: Colors.indigo, // Example theme color
        fontFamily: readingSettings.fontFamily, // Use font from settings
        brightness: Brightness.light,
        // Add other theme properties as needed
        scaffoldBackgroundColor: Colors.grey[100], // Light background
        cardTheme: CardTheme(elevation: 2.0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
      ),
      darkTheme: ThemeData(
        primarySwatch: Colors.indigo,
        fontFamily: readingSettings.fontFamily,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.grey[900], // Dark background
        cardTheme: CardTheme(elevation: 2.0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
        // Add dark theme specific properties
      ),
      themeMode: ThemeMode.system, // Or ThemeMode.light / ThemeMode.dark
      home: const LibraryScreen(),
    );
  }
}

// Library Screen - Displays the list of books
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
    print("LibraryScreen: initState");
    _loadBooks();
  }

  Future<void> _loadBooks() async {
    print("LibraryScreen: Loading books...");
    if (!mounted) return; // Check if the widget is still in the tree
    setState(() { isLoading = true; });

    final loadedBooks = await _databaseHelper.getBooks();

    if (mounted) { // Check again before calling setState
      setState(() {
        books = loadedBooks;
        isLoading = false;
        print("LibraryScreen: Books loaded (${books.length}).");
      });
    } else {
      print("LibraryScreen: Load books completed but widget was disposed.");
    }
  }

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
      print("LibraryScreen: File picked: $originalFileName");

      try {
        // Get the app's documents directory
        Directory appDocDir = await getApplicationDocumentsDirectory();
        String booksDir = path.join(appDocDir.path, 'epubs'); // Subdirectory for books
        Directory dir = Directory(booksDir);

        // Create the directory if it doesn't exist
        if (!await dir.exists()) {
          await dir.create(recursive: true);
          print("LibraryScreen: Created directory $booksDir");
        }

        // Create the destination path
        String newPath = path.join(booksDir, originalFileName);

        // Copy the file
        print("LibraryScreen: Copying from ${sourceFile.path} to $newPath");
        await sourceFile.copy(newPath);
        print("LibraryScreen: File copied successfully.");

        // --- Check if book with this file path already exists ---
        // Load current books again to ensure we have the latest list before checking
        final currentBooksInDb = await _databaseHelper.getBooks();
        bool bookExists = currentBooksInDb.any((book) => book.filePath == newPath);

        if (bookExists) {
          print("LibraryScreen: Book already exists at path $newPath. Skipping import.");
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('This book is already in your library.')),
            );
          }
          return; // Don't add the book again
        }
        // --- End check ---


        // Create Book object and insert into database
        Book newBook = Book(
          // Extract title from filename, remove .epub extension
          title: originalFileName.replaceAll(RegExp(r'\.epub$', caseSensitive: false), ''),
          filePath: newPath, // Store the path within the app's documents directory
          // Initialize other fields as needed
        );
        await _databaseHelper.insertBook(newBook);
        print("LibraryScreen: Book saved to database.");

        // Reload books to update the UI
        _loadBooks();

      } catch (e) {
        print("LibraryScreen: Error copying or saving book: $e");
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Error saving book: ${e.toString()}'))
          );
        }
      }
    } else {
      print("LibraryScreen: File picking cancelled.");
    }
  }

  void _showBookOptions(BuildContext context, Book book) {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return SafeArea( // Ensure content is within safe area
          child: Wrap( // Use Wrap for better layout flexibility
            children: [
              ListTile(
                leading: const Icon(Icons.menu_book), // Changed icon
                title: const Text('Continue Reading'),
                onTap: () {
                  Navigator.pop(context); // Close the bottom sheet
                  _openReader(book);
                },
              ),
              if (book.highlights.isNotEmpty) // Only show if highlights exist
                ListTile(
                  leading: const Icon(Icons.highlight),
                  title: const Text('View Highlights'),
                  onTap: () {
                    Navigator.pop(context); // Close the bottom sheet
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => HighlightsScreen(book: book),
                      ),
                    );
                  },
                ),
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('Book Info'), // Example action
                onTap: () {
                  Navigator.pop(context);
                  _showBookInfoDialog(book);
                },
              ),
              ListTile(
                leading: Icon(Icons.delete_outline, color: Colors.red.shade700),
                title: Text('Delete Book', style: TextStyle(color: Colors.red.shade700)),
                onTap: () {
                  Navigator.pop(context); // Close the bottom sheet
                  _confirmAndDeleteBook(book);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _showBookInfoDialog(Book book) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(book.title),
        content: SingleChildScrollView( // In case content gets long
          child: ListBody(
            children: <Widget>[
              Text('Total Reading Time: ${ReadingTimeTracker.formatTotalReadingTime(book.totalReadingTime)}'),
              const SizedBox(height: 8),
              Text('Highlights Count: ${book.highlights.values.expand((list) => list).length}'),
              const SizedBox(height: 8),
              Text('File Path: ${book.filePath}', style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
              const SizedBox(height: 8),
              Text('Database ID: ${book.id ?? 'N/A'}', style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            child: const Text('Close'),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }


  void _confirmAndDeleteBook(Book book) {
    showDialog(
      context: context,
      builder: (BuildContext ctx) {
        return AlertDialog(
          title: const Text('Delete Book?'),
          content: Text('Are you sure you want to remove "${book.title}"? This will delete its reading progress, highlights, and the stored EPUB file.'),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () => Navigator.of(ctx).pop(), // Close the dialog
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.red.shade700),
              child: const Text('Delete'),
              onPressed: () async {
                Navigator.of(ctx).pop(); // Close the dialog first
                await _deleteBook(book); // Then perform deletion
              },
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Error: Cannot delete book without an ID.')),
        );
      }
      return;
    }

    try {
      // 1. Delete the actual file
      final file = File(book.filePath);
      if (await file.exists()) {
        await file.delete();
        print("LibraryScreen: Deleted file ${book.filePath}");
      } else {
        print("LibraryScreen: File not found for deletion: ${book.filePath}");
      }

      // 2. Delete the book record from the database
      await _databaseHelper.deleteBook(book.id!);
      print("LibraryScreen: Deleted book record from database (ID: ${book.id}).");

      // 3. Refresh the book list in the UI
      _loadBooks();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('"${book.title}" deleted.')),
        );
      }
    } catch (e) {
      print("LibraryScreen: Error deleting book ID ${book.id}: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error deleting "${book.title}".')),
        );
      }
    }
  }


  void _openReader(Book book) {
    if (book.id == null) {
      print("LibraryScreen: Cannot open book, ID is null for title '${book.title}'");
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Error: Book data is incomplete.')),
      );
      return;
    }
    print("LibraryScreen: Opening reader for book ID ${book.id} - ${book.title}");
    Navigator.push(
      context,
      MaterialPageRoute(
        // Pass the book object to the ReaderScreen
        builder: (context) => ReaderScreen(book: book),
      ),
    ).then((_) {
      print("LibraryScreen: Returned from ReaderScreen. Reloading books.");
      // Reload books when returning from the reader to reflect changes
      // (like updated reading time or last position - though position is handled internally now)
      _loadBooks();
    });
  }


  @override
  Widget build(BuildContext context) {
    print("LibraryScreen: build");
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Library'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined), // Changed icon
            tooltip: 'Settings', // Added tooltip
            onPressed: () {
              print("LibraryScreen: Navigating to SettingsScreen.");
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const SettingsScreen(),
                ),
              );
            },
          ),
        ],
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : books.isEmpty
          ? Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.library_books_outlined, size: 60, color: Colors.grey),
            const SizedBox(height: 20),
            const Text('Your library is empty.', style: TextStyle(fontSize: 16)),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              icon: const Icon(Icons.add_circle_outline),
              label: const Text('Add First Book'),
              onPressed: _pickAndImportBook,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              ),
            )
          ],
        ),
      )
          : RefreshIndicator( // Add pull-to-refresh
        onRefresh: _loadBooks,
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 8.0), // Add padding to list
          itemCount: books.length,
          itemBuilder: (context, index) {
            final book = books[index];
            // Calculate highlight count safely
            int highlightCount = 0;
            try {
              highlightCount = book.highlights.values.expand((list) => list).length;
            } catch (e) {
              print("Error calculating highlights for book ${book.id}: $e");
            }

            return Card(
              margin: const EdgeInsets.symmetric(
                horizontal: 10, // Reduced horizontal margin
                vertical: 5,   // Reduced vertical margin
              ),
              // elevation: 2.0, // Provided by CardTheme
              child: ListTile(
                leading: const Icon(Icons.book_outlined, size: 36, color: Colors.indigo), // Example leading icon
                title: Text(
                  book.title,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                  maxLines: 2, // Allow title to wrap
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(Icons.timer_outlined, size: 14, color: Colors.grey.shade600),
                        const SizedBox(width: 4),
                        Text(
                          // Use the static formatter from ReadingTimeTracker
                          'Read: ${ReadingTimeTracker.formatTotalReadingTime(book.totalReadingTime)}',
                          style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(Icons.highlight_outlined, size: 14, color: Colors.grey.shade600),
                        const SizedBox(width: 4),
                        Text(
                          'Highlights: $highlightCount',
                          style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                        ),
                      ],
                    ),
                  ],
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.more_vert), // Options icon
                  tooltip: 'Book options',
                  onPressed: () => _showBookOptions(context, book),
                ),
                onTap: () => _openReader(book), // Open reader on tap
              ),
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _pickAndImportBook,
        tooltip: 'Import EPUB', // Added tooltip
        child: const Icon(Icons.add),
      ),
    );
  }
}

// Settings Screen - Allows adjusting reading preferences
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    // Use Consumer for fine-grained rebuilding if needed, or Provider.of
    final readingSettings = Provider.of<ReadingSettings>(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Reading Settings')),
      body: ListView(
        padding: const EdgeInsets.all(8.0), // Add padding
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: Text('Appearance', style: Theme.of(context).textTheme.titleMedium),
          ),
          ListTile(
            title: const Text('Font Size'),
            subtitle: Text('${readingSettings.fontSize.toInt()} pt'), // Display current value
            trailing: SizedBox( // Constrain slider width
              width: MediaQuery.of(context).size.width * 0.5,
              child: Slider(
                value: readingSettings.fontSize,
                min: 12,
                max: 32,
                divisions: 20, // More granular control
                label: '${readingSettings.fontSize.toInt()}',
                onChanged: (value) {
                  readingSettings.updateSetting(ReadingSettings._fontSizeKey, value);
                },
              ),
            ),
          ),
          ListTile(
            title: const Text('Line Height'),
            subtitle: Text(readingSettings.lineHeight.toStringAsFixed(1)), // Display current value
            trailing: SizedBox(
              width: MediaQuery.of(context).size.width * 0.5,
              child: Slider(
                value: readingSettings.lineHeight,
                min: 1.0,
                max: 2.0,
                divisions: 10,
                label: readingSettings.lineHeight.toStringAsFixed(1),
                onChanged: (value) {
                  readingSettings.updateSetting(ReadingSettings._lineHeightKey, value);
                },
              ),
            ),
          ),
          ListTile(
            title: const Text('Font Family'),
            trailing: DropdownButton<String>(
              value: readingSettings.fontFamily,
              // Add more fonts as desired (ensure they are included in pubspec.yaml)
              items: const [
                DropdownMenuItem(value: 'Roboto', child: Text('Roboto')),
                DropdownMenuItem(value: 'Merriweather', child: Text('Merriweather')),
                DropdownMenuItem(value: 'OpenSans', child: Text('Open Sans')),
                DropdownMenuItem(value: 'Lato', child: Text('Lato')),
                DropdownMenuItem(value: 'Lora', child: Text('Lora')),
                DropdownMenuItem(value: 'SourceSerifPro', child: Text('Source Serif Pro')),
              ],
              onChanged: (value) {
                if (value != null) {
                  readingSettings.updateSetting(ReadingSettings._fontFamilyKey, value);
                }
              },
            ),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: Text('About', style: Theme.of(context).textTheme.titleMedium),
          ),
          ListTile(
            title: const Text('App Version'),
            subtitle: const Text('1.0.1 (Fixed)'), // Replace with dynamic version later if needed
            leading: const Icon(Icons.info_outline),
            onTap: () {
              // Optional: Show more detailed info or licenses
            },
          ),
        ],
      ),
    );
  }
}


// Highlights Screen - Displays saved highlights for a book
class HighlightsScreen extends StatelessWidget {
  final Book book;

  const HighlightsScreen({Key? key, required this.book}) : super(key: key);

  // Function to safely get highlights map
  Map<String, List<String>> _getValidHighlights() {
    if (book.highlights is Map<String, List<String>>) {
      return book.highlights;
    } else {
      print("Warning: Highlights data is not in the expected format for book ${book.id}. Returning empty map.");
      return {}; // Return an empty map if the format is wrong
    }
  }


  @override
  Widget build(BuildContext context) {
    final highlights = _getValidHighlights(); // Use the safe getter
    final chapters = highlights.keys.toList();
    print("HighlightsScreen: Displaying highlights for book ${book.id}. Chapters: ${chapters.length}");

    return Scaffold(
      appBar: AppBar(title: Text('Highlights: ${book.title}')),
      body: highlights.isEmpty
          ? const Center(child: Text('No highlights found for this book.')) // Improved message
          : ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8.0), // Add padding
        itemCount: chapters.length,
        itemBuilder: (context, chapterIndex) {
          final chapter = chapters[chapterIndex];
          // Ensure chapterHighlights is always a list, even if key is somehow null (though keys.toList shouldn't allow nulls)
          final chapterHighlights = highlights[chapter] ?? [];

          // Skip empty chapters in the UI
          if (chapterHighlights.isEmpty) {
            return const SizedBox.shrink(); // Render nothing for empty chapters
          }

          return Card( // Use Card for better visual separation of chapters
            margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            elevation: 1.5,
            child: ExpansionTile(
              title: Text(chapter.isNotEmpty ? 'Chapter: $chapter' : 'Unknown Chapter', // Handle potentially empty chapter names stored
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              initiallyExpanded: true, // Keep chapters expanded by default
              childrenPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              children: chapterHighlights.map((text) {
                return Padding( // Add padding around each highlight text
                  padding: const EdgeInsets.symmetric(vertical: 8.0),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.secondary.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SelectableText( // Allow users to select text
                          text,
                          style: const TextStyle(
                            fontStyle: FontStyle.italic,
                            height: 1.4, // Improve readability
                          ),
                        ),
                        // Add actions like copy/share if needed here later
                      ],
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


// Reader Screen - Handles displaying the EPUB and tracking progress
class ReaderScreen extends StatefulWidget {
  final Book book;

  const ReaderScreen({Key? key, required this.book}) : super(key: key);

  @override
  _ReaderScreenState createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> with WidgetsBindingObserver {
  bool isLoading = true;
  late ReadingTimeTracker _timeTracker;
  late DatabaseHelper _databaseHelper; // Use instance for updates
  bool _epubOpened = false; // Track if VocsyEpub.open has been called
  StreamSubscription? _locatorSubscription; // To manage the listener

  @override
  void initState() {
    super.initState();
    print("ReaderScreen: initState for book ID ${widget.book.id}");
    WidgetsBinding.instance.addObserver(this);
    _databaseHelper = DatabaseHelper(); // Initialize database helper instance

    // Ensure book has a valid ID before proceeding
    if (widget.book.id == null) {
      print("ReaderScreen: Error - Book ID is null. Cannot initialize.");
      // Show error and pop in the next frame to avoid build errors
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Error: Cannot open book without a valid ID.')),
          );
          Navigator.pop(context);
        }
      });
      // Set loading to false so it doesn't hang indefinitely
      setState(() { isLoading = false; });
      return; // Stop initialization
    }

    // Initialize time tracker only if ID is valid
    _timeTracker = ReadingTimeTracker(
      bookId: widget.book.id!,
      databaseHelper: _databaseHelper,
    );

    // Start opening the EPUB
    _openEpub();
  }

  @override
  void dispose() {
    print("ReaderScreen: dispose for book ID ${widget.book.id}");
    WidgetsBinding.instance.removeObserver(this);
    // Cancel the stream subscription to prevent memory leaks
    _locatorSubscription?.cancel();
    print("ReaderScreen: Locator stream listener cancelled.");

    // Stop and save time only if the book ID was valid and tracker was initialized
    // Ensure this runs before potential native cleanup
    if (widget.book.id != null) {
      _timeTracker.stopAndSaveTracking();
    }

    // Optional: Call VocsyEpub.close() if available to explicitly release native resources
    // try {
    //   VocsyEpub.close();
    //   print("ReaderScreen: Called VocsyEpub.close()");
    // } catch (e) {
    //   print("ReaderScreen: Error calling VocsyEpub.close(): $e");
    // }

    print("ReaderScreen: Disposed.");
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    print("ReaderScreen: AppLifecycleState changed to $state for book ID ${widget.book.id}");
    // Only track time if the book ID is valid and EPUB has been successfully opened
    if (widget.book.id == null || !_epubOpened) return;

    switch (state) {
      case AppLifecycleState.resumed:
        print("ReaderScreen: App resumed, starting time tracking.");
        _timeTracker.startTracking();
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden: // Handle hidden state
        print("ReaderScreen: App paused/inactive/detached/hidden, stopping time tracking.");
        // Stop and save time when app goes to background, is hidden, or is terminated
        _timeTracker.stopAndSaveTracking();
        break;
    // No default case needed because all enum values are handled.
    }
  }

  Future<void> _openEpub() async {
    print("ReaderScreen: _openEpub called.");
    // Redundant check, but safe
    if (widget.book.id == null) {
      print("ReaderScreen: _openEpub - Cannot proceed, book ID is null.");
      setState(() { isLoading = false; });
      return;
    }

    // Ensure the file exists before trying to open
    final file = File(widget.book.filePath);
    if (!await file.exists()) {
      print("ReaderScreen: Error - Book file not found at ${widget.book.filePath}");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Error: Book file is missing or moved.')),
        );
        Navigator.pop(context); // Go back if file is missing
      }
      setState(() { isLoading = false; });
      return;
    }

    // Access settings via Provider
    final readingSettings = Provider.of<ReadingSettings>(context, listen: false);
    final bool isDarkMode = Theme.of(context).brightness == Brightness.dark;

    print("ReaderScreen: Configuring VocsyEpub...");
    print("  - Theme: ${Theme.of(context).primaryColor}");
    print("  - Identifier: book_${widget.book.id}"); // Use unique identifier
    print("  - Direction: HORIZONTAL");
    print("  - Sharing: true, TTS: false"); // TTS disabled for simplicity/performance
    print("  - Night Mode: $isDarkMode");
    print("  - Font Size: ${readingSettings.fontSize}"); // Apply settings if Vocsy supports them
    print("  - Font Family: ${readingSettings.fontFamily}");
    print("  - Line Height: ${readingSettings.lineHeight}");


    try {
      // Configure VocsyEpub before opening
      // Note: VocsyEpub might not support all Flutter theme features directly.
      // Font size/family/line height might need specific API calls if supported by Vocsy.
      VocsyEpub.setConfig(
        themeColor: Theme.of(context).primaryColor,
        identifier: "book_${widget.book.id}", // More specific identifier
        scrollDirection: EpubScrollDirection.HORIZONTAL,
        allowSharing: true,
        enableTts: false, // Disabled TTS for this example
        nightMode: isDarkMode,
        // Font/Line height settings might require different methods if available
        // Check VocsyEpub documentation for applying custom styles
      );

      print("ReaderScreen: Configuration set. Loading last location...");
      // Load and Decode the Last Location JSON
      EpubLocator? locator;
      if (widget.book.lastLocatorJson.isNotEmpty && widget.book.lastLocatorJson != '{}') {
        print("ReaderScreen: Found saved locator JSON: ${widget.book.lastLocatorJson}");
        try {
          Map<String, dynamic> decodedLocator = json.decode(widget.book.lastLocatorJson);
          // Basic validation of the decoded map structure
          if (decodedLocator.containsKey('bookId') &&
              decodedLocator.containsKey('href') &&
              decodedLocator.containsKey('created') &&
              decodedLocator.containsKey('locations') &&
              decodedLocator['locations'] is Map &&
              decodedLocator['locations'].containsKey('cfi'))
          {
            locator = EpubLocator.fromJson(decodedLocator);
            print("ReaderScreen: Successfully decoded and created EpubLocator.");
          } else {
            print("ReaderScreen: Warning - Decoded locator JSON has missing fields. Opening from beginning.");
          }
        } catch (e) {
          print("ReaderScreen: Error decoding locator JSON '${widget.book.lastLocatorJson}': $e. Opening from beginning.");
          locator = null; // Ensure locator is null on error
        }
      } else {
        print("ReaderScreen: No valid saved location found. Opening from beginning.");
      }


      print("ReaderScreen: Calling VocsyEpub.open with path: ${widget.book.filePath}");
      // Open the EPUB file
      VocsyEpub.open(
        widget.book.filePath,
        lastLocation: locator,
      );
      _epubOpened = true; // Mark EPUB as successfully opened
      print("ReaderScreen: VocsyEpub.open called successfully.");


      // Start tracking reading time after successfully calling open
      _timeTracker.startTracking();

      // Setup listener after calling open
      _setupLocatorListener();


      // Update state to indicate loading is finished (the native view will appear)
      if (mounted) {
        setState(() { isLoading = false; });
      }
      print("ReaderScreen: Loading finished, native view should appear.");

    } catch (e) {
      print("ReaderScreen: Error during VocsyEpub configuration or open: $e");
      _epubOpened = false; // Ensure this is false on error
      if (mounted) {
        setState(() { isLoading = false; });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error opening book: ${e.toString()}')),
        );
        // Maybe pop back if opening fails critically
        // Navigator.pop(context);
      }
    }
  }


  void _setupLocatorListener() {
    print("ReaderScreen: Setting up locator stream listener for book ID ${widget.book.id}");
    // Cancel any previous subscription
    _locatorSubscription?.cancel();
    // Assign the new subscription
    _locatorSubscription = VocsyEpub.locatorStream.listen((locatorData) {
      // print("ReaderScreen: Received locator data: $locatorData"); // Can be verbose

      Map<String, dynamic>? locatorMap;

      // Handle received data (might be String or Map)
      if (locatorData is String) {
        try {
          locatorMap = json.decode(locatorData);
        } catch (e) {
          print("ReaderScreen: Error decoding locator string: $e");
          return; // Skip update if decoding fails
        }
      } else if (locatorData is Map) {
        // Ensure keys are strings if necessary, though default jsonDecode usually handles this.
        // If keys might be non-strings, manual conversion is needed.
        try {
          locatorMap = Map<String, dynamic>.from(locatorData);
        } catch (e) {
          print("ReaderScreen: Error converting received map: $e");
          return; // Skip update if conversion fails
        }
      }

      if (locatorMap != null) {
        // Basic validation: Check if essential fields exist
        if (locatorMap.containsKey('bookId') &&
            locatorMap.containsKey('href') &&
            locatorMap.containsKey('locations') &&
            locatorMap['locations'] is Map &&
            locatorMap['locations'].containsKey('cfi'))
        {
          _updateBookProgress(locatorMap); // Pass the validated map
        } else {
          print("ReaderScreen: Warning - Received locator map is missing required fields: $locatorMap");
        }
      } else {
        print("ReaderScreen: Received locator data in unrecognized format: ${locatorData?.runtimeType}");
      }
    }, onError: (error) {
      print("ReaderScreen: Error in locator stream: $error");
      // Handle stream errors if necessary (e.g., show a message, stop timer)
      if(mounted) {
        _timeTracker.stopAndSaveTracking(); // Stop timer on stream error
      }
    }, onDone: () {
      print("ReaderScreen: Locator stream closed (onDone). Reader likely closed.");
      // This might be a place to trigger Navigator.pop, but test reliability.
      // If the native view closing reliably triggers pop, this might not be needed.
      // if (mounted) {
      //   print("ReaderScreen: Popping view controller due to locator stream onDone.");
      //   Navigator.pop(context);
      // }
    });
    print("ReaderScreen: Locator stream listener is active.");
  }

  // Updated to accept the full locator map
  Future<void> _updateBookProgress(Map<String, dynamic> locatorData) async {
    // Guard against null ID (shouldn't happen if initial checks pass, but safe)
    // Also check if mounted before proceeding with async database operations
    if (widget.book.id == null || !mounted) return;

    // print("ReaderScreen: _updateBookProgress called with locator for href: ${locatorData['href']}"); // Can be verbose
    try {
      // Encode the entire map to a JSON string
      final String locatorJson = json.encode(locatorData);

      // Only update if the new locator is different from the currently stored one
      // This check prevents unnecessary database writes if the position hasn't changed meaningfully
      // Note: We read the current value from widget.book, which might be slightly stale
      // if multiple updates happen very quickly before state is rebuilt. Usually not an issue.
      if (locatorJson != widget.book.lastLocatorJson) {
        print("ReaderScreen: New locator detected. Updating database.");
        // Create a copy of the book with the new locator JSON
        final updatedBook = widget.book.copyWith(
          lastLocatorJson: locatorJson,
        );
        // Update the database using the instance
        await _databaseHelper.updateBook(updatedBook);
        // print("ReaderScreen: Book progress updated in database."); // Can be verbose

        // VERY IMPORTANT: Update the local widget's book state IF NEEDED.
        // Since the locator stream keeps firing based on the native view,
        // this widget's widget.book instance DOES NOT automatically update
        // after _databaseHelper.updateBook.
        // If subsequent calls to _updateBookProgress rely on the absolutely latest
        // saved lastLocatorJson for the comparison check, you would need
        // to somehow refresh widget.book here. This often involves more complex state management.
        // For now, the check locatorJson != widget.book.lastLocatorJson compares against
        // the lastLocatorJson that was present when this ReaderScreen widget was built or last rebuilt.
      } else {
        // print("ReaderScreen: Locator unchanged, skipping database update.");
      }
    } catch (e) {
      print("ReaderScreen: Error encoding or saving book progress: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    print("ReaderScreen: build (isLoading: $isLoading, _epubOpened: $_epubOpened)");

    // Handle the case where initialization failed due to null ID
    if (widget.book.id == null && !isLoading) {
      // This case should ideally be prevented by the early return in initState,
      // but it's a safe fallback.
      return Scaffold(
        appBar: AppBar(title: const Text('Error')),
        body: const Center(child: Text('Failed to load book: Invalid book data.')),
      );
    }

    // --- BUILD METHOD MODIFIED TO PREVENT BLACK SCREEN ---
    // Always return a Scaffold. The content depends on the state.
    return Scaffold(
      // Optional: Keep AppBar for context, or remove if the native view provides its own
      // appBar: AppBar(
      //   title: Text(widget.book.title),
      //   // Optionally add actions like settings, bookmarks specific to the reader view
      // ),
      body: Center(
        child: isLoading
            ? const Column( // State 1: Initial Loading
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 20),
            Text('Preparing book...'),
          ],
        )
            : _epubOpened
            ? const Column( // State 2: EPUB Opened (Native view active OR closing transition)
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Using an indicator during closing might look like it's reloading.
            // Text might be better. Or just an empty colored container.
            // CircularProgressIndicator(),
            // SizedBox(height: 16),
            Text('Loading Reader...'), // Or "Closing..." or keep it visually empty
          ],
        )
            : const Text('Failed to display book.\nPlease try again.'), // State 3: Error after trying to load/open
      ),
    );
    // --- END OF BUILD METHOD MODIFICATION ---
  }
}