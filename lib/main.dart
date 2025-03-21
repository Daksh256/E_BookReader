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

// Book model class with added reading time
class Book {
  final int? id;
  final String title;
  final String filePath;
  final String lastReadPosition;
  final int totalReadingTime; // In seconds
  final Map<String, List<String>> highlights; // Map of chapter -> list of highlighted text

  Book({
    this.id,
    required this.title,
    required this.filePath,
    this.lastReadPosition = '0',
    this.totalReadingTime = 0,
    this.highlights = const {},
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'filePath': filePath,
      'lastReadPosition': lastReadPosition,
      'totalReadingTime': totalReadingTime,
      'highlights': highlightsToJson(),
    };
  }

  // Convert highlights map to JSON string
  String highlightsToJson() {
    final Map<String, dynamic> jsonMap = {};
    highlights.forEach((chapter, texts) {
      jsonMap[chapter] = texts;
    });
    return jsonMap.toString();
  }

  // Create a copy of book with updated fields
  Book copyWith({
    int? id,
    String? title,
    String? filePath,
    String? lastReadPosition,
    int? totalReadingTime,
    Map<String, List<String>>? highlights,
  }) {
    return Book(
      id: id ?? this.id,
      title: title ?? this.title,
      filePath: filePath ?? this.filePath,
      lastReadPosition: lastReadPosition ?? this.lastReadPosition,
      totalReadingTime: totalReadingTime ?? this.totalReadingTime,
      highlights: highlights ?? this.highlights,
    );
  }

  // Parse highlights from JSON string
  static Map<String, List<String>> parseHighlights(String json) {
    if (json.isEmpty) return {};

    // Basic parsing - in a real app you'd use a proper JSON parser
    final Map<String, List<String>> result = {};
    try {
      // Very simple parsing logic - would need more robust implementation
      final content = json.substring(1, json.length - 1); // Remove outer {}
      final entries = content.split(', ');

      for (var entry in entries) {
        final parts = entry.split(': ');
        if (parts.length == 2) {
          final key = parts[0].replaceAll('"', '');
          final value = parts[1];

          // Parse list
          final listContent = value.substring(1, value.length - 1); // Remove []
          final items = listContent.split(', ');
          final cleanItems = items.map((e) => e.replaceAll('"', '')).toList();

          result[key] = cleanItems;
        }
      }
    } catch (e) {
      print('Error parsing highlights: $e');
    }
    return result;
  }
}

// Database helper with updated methods for reading time and highlights
class DatabaseHelper {
  static Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await initDatabase();
    return _database!;
  }

  Future<Database> initDatabase() async {
    String databasesPath = await getDatabasesPath();
    String dbPath = path.join(databasesPath, 'books_database.db');
    return openDatabase(
      dbPath,
      onCreate: (db, version) {
        return db.execute(
          'CREATE TABLE books(id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT, filePath TEXT, lastReadPosition TEXT, totalReadingTime INTEGER, highlights TEXT)',
        );
      },
      version: 1,
    );
  }

  Future<void> insertBook(Book book) async {
    final Database db = await database;
    await db.insert('books', book.toMap());
  }

  Future<List<Book>> getBooks() async {
    final Database db = await database;
    final List<Map<String, dynamic>> maps = await db.query('books');
    return List.generate(maps.length, (i) {
      return Book(
        id: maps[i]['id'],
        title: maps[i]['title'],
        filePath: maps[i]['filePath'],
        lastReadPosition: maps[i]['lastReadPosition'] ?? '0',
        totalReadingTime: maps[i]['totalReadingTime'] ?? 0,
        highlights: maps[i]['highlights'] != null
            ? Book.parseHighlights(maps[i]['highlights'])
            : {},
      );
    });
  }

  Future<void> updateBook(Book book) async {
    final db = await database;
    await db.update(
      'books',
      book.toMap(),
      where: 'id = ?',
      whereArgs: [book.id],
    );
  }

  Future<void> updateReadingTime(int bookId, int seconds) async {
    final db = await database;
    final books = await db.query(
      'books',
      where: 'id = ?',
      whereArgs: [bookId],
    );

    if (books.isNotEmpty) {
      int currentTime = (books[0]['totalReadingTime'] as int?) ?? 0;
      int newTime = currentTime + seconds;

      final book = Book(
        id: books[0]['id'] as int,
        title: books[0]['title'] as String,
        filePath: books[0]['filePath'] as String,
        lastReadPosition: books[0]['lastReadPosition'] as String,
        totalReadingTime: newTime,
      );

      await updateBook(book);
    }
  }

  Future<void> saveHighlight(int bookId, String chapter, String text) async {
    final db = await database;
    final books = await db.query(
      'books',
      where: 'id = ?',
      whereArgs: [bookId],
    );

    if (books.isNotEmpty) {
      Map<String, List<String>> currentHighlights = {};
      if (books[0]['highlights'] != null) {
        currentHighlights = Book.parseHighlights(books[0]['highlights'] as String);
      }

      // Add highlight
      final updatedHighlights = Map<String, List<String>>.from(currentHighlights);
      if (updatedHighlights.containsKey(chapter)) {
        updatedHighlights[chapter]!.add(text);
      } else {
        updatedHighlights[chapter] = [text];
      }

      final updatedBook = Book(
        id: books[0]['id'] as int,
        title: books[0]['title'] as String,
        filePath: books[0]['filePath'] as String,
        lastReadPosition: books[0]['lastReadPosition'] as String,
        totalReadingTime: books[0]['totalReadingTime'] as int? ?? 0,
        highlights: updatedHighlights,
      );

      await updateBook(updatedBook);
    }
  }
}

// Reading settings provider with additional settings
class ReadingSettings with ChangeNotifier {
  double _fontSize = 16;
  double get fontSize => _fontSize;

  String _fontFamily = 'Roboto';
  String get fontFamily => _fontFamily;

  Color _backgroundColor = Colors.white;
  Color get backgroundColor => _backgroundColor;

  Color _textColor = Colors.black;
  Color get textColor => _textColor;

  double _lineHeight = 1.4;
  double get lineHeight => _lineHeight;

  // Update methods
  void updateFontSize(double size) {
    _fontSize = size;
    notifyListeners();
    _saveSettings();
  }

  void updateFontFamily(String family) {
    _fontFamily = family;
    notifyListeners();
    _saveSettings();
  }

  void updateBackgroundColor(Color color) {
    _backgroundColor = color;
    notifyListeners();
    _saveSettings();
  }

  void updateTextColor(Color color) {
    _textColor = color;
    notifyListeners();
    _saveSettings();
  }

  void updateLineHeight(double height) {
    _lineHeight = height;
    notifyListeners();
    _saveSettings();
  }

  // Load settings from SharedPreferences
  Future<void> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _fontSize = prefs.getDouble('fontSize') ?? 16;
    _fontFamily = prefs.getString('fontFamily') ?? 'Roboto';
    _lineHeight = prefs.getDouble('lineHeight') ?? 1.4;
    notifyListeners();
  }

  // Save settings to SharedPreferences
  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('fontSize', _fontSize);
    await prefs.setString('fontFamily', _fontFamily);
    await prefs.setDouble('lineHeight', _lineHeight);
  }
}

// Reading Time Tracker
class ReadingTimeTracker {
  final int bookId;
  final DatabaseHelper databaseHelper;
  DateTime? _startTime;
  Timer? _timer;
  int _sessionSeconds = 0;

  ReadingTimeTracker({required this.bookId, required this.databaseHelper});

  void startTracking() {
    _startTime = DateTime.now();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _sessionSeconds++;
    });
  }

  Future<void> stopTracking() async {
    _timer?.cancel();
    if (_startTime != null) {
      final elapsedSeconds = _sessionSeconds;
      await databaseHelper.updateReadingTime(bookId, elapsedSeconds);
      _sessionSeconds = 0;
      _startTime = null;
    }
  }

  String get formattedSessionTime {
    final hours = _sessionSeconds ~/ 3600;
    final minutes = (_sessionSeconds % 3600) ~/ 60;
    final seconds = _sessionSeconds % 60;

    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    } else {
      return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
  }
}

// Main App
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final readingSettings = ReadingSettings();
  await readingSettings.loadSettings();

  runApp(
    ChangeNotifierProvider.value(
      value: readingSettings,
      child: const EpubReaderApp(),
    ),
  );
}

class EpubReaderApp extends StatelessWidget {
  const EpubReaderApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Enhanced EPUB Reader',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        fontFamily: 'Roboto',
      ),
      home: const LibraryScreen(),
    );
  }
}

// Library Screen with reading statistics
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
    _loadBooks();
  }

  Future<void> _loadBooks() async {
    setState(() {
      isLoading = true;
    });

    final loadedBooks = await _databaseHelper.getBooks();
    setState(() {
      books = loadedBooks;
      isLoading = false;
    });
  }

  Future<void> _pickAndImportBook() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['epub'],
    );

    if (result != null && result.files.single.path != null) {
      File file = File(result.files.single.path!);
      String fileName = result.files.single.name;

      // Save book to app directory
      Directory appDocDir = await getApplicationDocumentsDirectory();
      String newPath = path.join(appDocDir.path, fileName);
      await file.copy(newPath);

      // Save to database
      Book newBook = Book(
        title: fileName.replaceAll('.epub', ''),
        filePath: newPath,
      );
      await _databaseHelper.insertBook(newBook);
      _loadBooks();
    }
  }

  String _formatReadingTime(int seconds) {
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;

    if (hours > 0) {
      return '$hours hours ${minutes > 0 ? '$minutes mins' : ''}';
    } else {
      return '$minutes minutes';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
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
            const Text('No books in library'),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _pickAndImportBook,
              child: const Text('Add Book'),
            ),
          ],
        ),
      )
          : ListView.builder(
        itemCount: books.length,
        itemBuilder: (context, index) {
          return Card(
            margin: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 8,
            ),
            child: ListTile(
              title: Text(
                books[index].title,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Icon(Icons.timer, size: 16),
                      const SizedBox(width: 4),
                      Text('Reading time: ${_formatReadingTime(books[index].totalReadingTime)}'),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Icon(Icons.highlight, size: 16),
                      const SizedBox(width: 4),
                      Text(
                        'Highlights: ${books[index].highlights.values.expand((e) => e).length}',
                      ),
                    ],
                  ),
                ],
              ),
              trailing: IconButton(
                icon: const Icon(Icons.menu),
                onPressed: () {
                  showModalBottomSheet(
                    context: context,
                    builder: (context) {
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ListTile(
                            leading: const Icon(Icons.play_arrow),
                            title: const Text('Continue Reading'),
                            onTap: () {
                              Navigator.pop(context);
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => ReaderScreen(book: books[index]),
                                ),
                              ).then((_) => _loadBooks());
                            },
                          ),
                          if (books[index].id != null)
                            ListTile(
                              leading: const Icon(Icons.highlight),
                              title: const Text('View Highlights'),
                              onTap: () {
                                Navigator.pop(context);
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) => HighlightsScreen(book: books[index]),
                                  ),
                                );
                              },
                            ),
                        ],
                      );
                    },
                  );
                },
              ),
              onTap: () {
                if (books[index].id != null) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => ReaderScreen(book: books[index]),
                    ),
                  ).then((_) => _loadBooks()); // Refresh when returning
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Book ID is null')),
                  );
                }
              },
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _pickAndImportBook,
        child: const Icon(Icons.add),
      ),
    );
  }
}

// Settings Screen
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final readingSettings = Provider.of<ReadingSettings>(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Reading Settings')),
      body: ListView(
        children: [
          ListTile(
            title: const Text('Font Size'),
            subtitle: Slider(
              value: readingSettings.fontSize,
              min: 12,
              max: 32,
              divisions: 10,
              label: '${readingSettings.fontSize.toInt()}',
              onChanged: (value) {
                readingSettings.updateFontSize(value);
              },
            ),
          ),
          ListTile(
            title: const Text('Line Height'),
            subtitle: Slider(
              value: readingSettings.lineHeight,
              min: 1.0,
              max: 2.0,
              divisions: 10,
              label: readingSettings.lineHeight.toStringAsFixed(1),
              onChanged: (value) {
                readingSettings.updateLineHeight(value);
              },
            ),
          ),
          ListTile(
            title: const Text('Font'),
            trailing: DropdownButton<String>(
              value: readingSettings.fontFamily,
              items: const [
                DropdownMenuItem(value: 'Roboto', child: Text('Roboto')),
                DropdownMenuItem(value: 'Merriweather', child: Text('Merriweather')),
                DropdownMenuItem(value: 'OpenSans', child: Text('Open Sans')),
                DropdownMenuItem(value: 'Lora', child: Text('Lora')),
              ],
              onChanged: (value) {
                if (value != null) {
                  readingSettings.updateFontFamily(value);
                }
              },
            ),
          ),
        ],
      ),
    );
  }
}

// Highlights Screen
class HighlightsScreen extends StatelessWidget {
  final Book book;

  const HighlightsScreen({Key? key, required this.book}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final highlights = book.highlights;
    final chapters = highlights.keys.toList();

    return Scaffold(
      appBar: AppBar(title: Text('Highlights: ${book.title}')),
      body: highlights.isEmpty
          ? const Center(child: Text('No highlights yet'))
          : ListView.builder(
        itemCount: chapters.length,
        itemBuilder: (context, chapterIndex) {
          final chapter = chapters[chapterIndex];
          final chapterHighlights = highlights[chapter] ?? [];

          return ExpansionTile(
            title: Text('Chapter: $chapter'),
            initiallyExpanded: true,
            children: chapterHighlights.map((text) {
              return Card(
                margin: const EdgeInsets.all(8),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        text,
                        style: const TextStyle(
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.copy),
                            onPressed: () {
                              // Copy to clipboard functionality would go here
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Copied to clipboard')),
                              );
                            },
                          ),
                          IconButton(
                            icon: const Icon(Icons.share),
                            onPressed: () {
                              // Share functionality would go here
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Share functionality')),
                              );
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          );
        },
      ),
    );
  }
}

// Reader Screen with vocsy_epub_viewer
class ReaderScreen extends StatefulWidget {
  final Book book;

  const ReaderScreen({Key? key, required this.book}) : super(key: key);

  @override
  _ReaderScreenState createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> with WidgetsBindingObserver {
  bool isLoading = true;
  late ReadingTimeTracker timeTracker;
  bool hasInitialized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Ensure book has a valid ID
    if (widget.book.id == null) {
      setState(() {
        isLoading = false;
      });

      // Show error in the next frame
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Error: Book ID is null')),
          );
          Navigator.pop(context);
        }
      });
      return;
    }

    timeTracker = ReadingTimeTracker(
      bookId: widget.book.id!,
      databaseHelper: DatabaseHelper(),
    );

    _openEpub();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.book.id != null) {
      timeTracker.stopTracking();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // App came to foreground
      if (widget.book.id != null && hasInitialized) {
        timeTracker.startTracking();
      }
    } else if (state == AppLifecycleState.paused) {
      // App went to background
      if (widget.book.id != null && hasInitialized) {
        timeTracker.stopTracking();
      }
    }
  }

  Future<void> _openEpub() async {
    if (widget.book.id == null) {
      setState(() {
        isLoading = false;
      });
      return;
    }

    try {
      // Configure reader settings
      VocsyEpub.setConfig(
        themeColor: Colors.blue,
        identifier: "bookId",
        scrollDirection: EpubScrollDirection.HORIZONTAL,
        allowSharing: true,
        enableTts: true,
        nightMode: false,
      );

      // Check if file exists
      if (!File(widget.book.filePath).existsSync()) {
        setState(() {
          isLoading = false;
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Error: Book file not found')),
          );
        }
        return;
      }

      // Open the book
      EpubLocator? locator;
      if (widget.book.lastReadPosition != '0') {
        locator = EpubLocator.fromJson({
          'bookId': 'bookId',
          'href': widget.book.lastReadPosition,
          'created': DateTime.now().millisecondsSinceEpoch,
          'locations': {
            'cfi': widget.book.lastReadPosition
          }
        });
      }

      // Open the book
      VocsyEpub.open(
        widget.book.filePath,
        lastLocation: locator,
      );

      // Start tracking reading time
      timeTracker.startTracking();
      hasInitialized = true;

      // Listen for locator changes
      VocsyEpub.locatorStream.listen((locator) {
        if (locator != null && locator['locations'] != null) {
          final cfi = locator['locations']['cfi'];
          if (cfi != null && cfi is String) {
            _updateBookProgress(cfi);
          }
        }
      });

      setState(() {
        isLoading = false;
      });
    } catch (e) {
      print('Error opening book: $e');
      setState(() {
        isLoading = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading book: $e')),
        );
      }
    }
  }

  Future<void> _updateBookProgress(String cfi) async {
    if (widget.book.id == null) return;

    try {
      final db = DatabaseHelper();
      final updatedBook = widget.book.copyWith(
        lastReadPosition: cfi,
      );
      await db.updateBook(updatedBook);
    } catch (e) {
      print('Error updating book progress: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.book.id == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Error')),
        body: const Center(child: Text('Invalid book: missing ID')),
      );
    }

    return isLoading
        ? const Scaffold(
      body: Center(
        child: CircularProgressIndicator(),
      ),
    )
        : Scaffold(
      // This is just a placeholder since the actual EPUB viewer
      // is opened by the VocsyEpub.open method
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            Text('Opening book...'),
            SizedBox(height: 20),
            CircularProgressIndicator(),
          ],
        ),
      ),
    );
  }
}