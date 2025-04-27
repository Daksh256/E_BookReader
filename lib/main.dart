// =========== [ Imports ] ===========
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

// Firebase Auth Imports
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
// import 'firebase_options.dart'; // REMOVED as requested


// =========== [ Enums & Classes (Existing - Unchanged) ] ===========

// Enum to represent library view types
enum LibraryViewType { grid, list }

// Book Class
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

// DatabaseHelper Class
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

// ReadingSettings Class
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

  ReadingSettings() {
    loadSettings();
  }

  Future<void> loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedThemeModeString = prefs.getString(_themeModeKey);
      _themeMode = ThemeMode.values.firstWhere(
              (e) => e.toString() == savedThemeModeString,
          orElse: () => ThemeMode.system
      );
      final savedDirectionName = prefs.getString(_scrollDirectionKey);
      _scrollDirection = EpubScrollDirection.values.firstWhere(
            (e) => e.name == savedDirectionName,
        orElse: () => EpubScrollDirection.HORIZONTAL,
      );
      final savedViewTypeName = prefs.getString(_libraryViewTypeKey);
      _libraryViewType = LibraryViewType.values.firstWhere(
              (e) => e.name == savedViewTypeName,
          orElse: () => LibraryViewType.grid
      );
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
        prefs.setString(_libraryViewTypeKey, _libraryViewType.name),
      ]);
      print("Settings saved successfully.");
    } catch (e) {
      print("Error saving settings: $e");
    }
  }
}

// ReadingTimeTracker Class
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


// =========== [ AuthService - Authentication Logic ] ===========
// =========== [ AuthService - MODIFIED ] ===========
// Service to handle all Firebase Authentication interactions
class AuthService {
  final FirebaseAuth _firebaseAuth = FirebaseAuth.instance;

  Stream<User?> get authStateChanges => _firebaseAuth.authStateChanges();
  User? get currentUser => _firebaseAuth.currentUser;

  Future<User?> signInWithEmailPassword(String email, String password) async {
    try {
      UserCredential result = await _firebaseAuth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password.trim(),
      );
      return result.user;
    } on FirebaseAuthException catch (e) {
      print('Sign In Error: ${e.code} - ${e.message}');
      throw Exception('Sign In Error: ${e.message}');
    } catch (e) {
      print('Unexpected Sign In Error: $e');
      throw Exception('An unexpected error occurred during sign in.');
    }
  }

  Future<User?> signUpWithEmailPassword(String email, String password) async {
    try {
      UserCredential result = await _firebaseAuth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password.trim(),
      );
      return result.user;
    } on FirebaseAuthException catch (e) {
      print('Sign Up Error: ${e.code} - ${e.message}');
      throw Exception('Sign Up Error: ${e.message}');
    } catch (e) {
      print('Unexpected Sign Up Error: $e');
      throw Exception('An unexpected error occurred during sign up.');
    }
  }

  Future<void> signOut() async {
    try {
      await _firebaseAuth.signOut();
      print('User signed out successfully');
    } catch (e) {
      print('Sign Out Error: $e');
    }
  }

  // --- ADDED METHOD for Password Reset ---
  Future<void> sendPasswordResetEmail(String email) async {
    try {
      await _firebaseAuth.sendPasswordResetEmail(email: email.trim());
      print('Password reset email sent successfully to $email');
    } on FirebaseAuthException catch (e) {
      print('Password Reset Error: ${e.code} - ${e.message}');
      // Throw a more specific error message based on the code
      if (e.code == 'user-not-found') {
        throw Exception('No user found for that email.');
      } else if (e.code == 'invalid-email') {
        throw Exception('The email address is not valid.');
      } else {
        throw Exception('Password Reset Error: ${e.message}');
      }
    } catch (e) {
      print('Unexpected Password Reset Error: $e');
      throw Exception('An unexpected error occurred while sending the password reset email.');
    }
  }
// --- END ADDED METHOD ---
}
// ===================================================


// =========== [ Main Function - MODIFIED for Manual Init & Debugging ] ===========
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // --- Firebase Initialization with Debugging ---
  try {
    print("Attempting Firebase initialization..."); // Debug log
    // ** IMPORTANT: Replace placeholders with your actual Firebase project credentials! **
    // Find these in your Firebase project settings (Project settings > General > Your apps > Flutter app)
    await Firebase.initializeApp(
      options: const FirebaseOptions(
        apiKey: "YOUR_API_KEY", // Replace with your key
        appId: "YOUR_APP_ID", // Replace with your ID
        messagingSenderId: "YOUR_MESSAGING_SENDER_ID", // Replace with your Sender ID
        projectId: "YOUR_PROJECT_ID", // Replace with your Project ID
        // storageBucket: "YOUR_PROJECT_ID.appspot.com", // Optional: Add if you use Firebase Storage
      ),
    );
    print("Firebase initialized successfully."); // Debug log
  } catch (e) {
    // ---- !!! Crucial Debugging Output !!! ----
    print("!!!!!!!!!!!! Firebase initialization FAILED !!!!!!!!!!!!");
    print(e.toString());
    // Consider showing an error screen here if Firebase is essential
    // runApp(ErrorScreen(error: e.toString())); // Example error screen
    // return; // Stop the app if needed
    // ---- !!! ----------------------------- !!! ----
  }
  // --- End Firebase Initialization ---


  // Load settings (existing)
  final readingSettings = ReadingSettings();
  await readingSettings.loadSettings();

  // Run App with Providers (existing)
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: readingSettings),
        Provider<AuthService>(create: (_) => AuthService()),
      ],
      child: const EpubReaderApp(),
    ),
  );
}


// =========== [ EpubReaderApp Widget - Root ] ===========
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
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          focusedBorder: OutlineInputBorder(
            borderSide: BorderSide(color: Colors.indigo, width: 2.0),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 20),
            textStyle: const TextStyle(fontSize: 16),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
            style: TextButton.styleFrom(
              textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            )
        ),
        cardTheme: CardTheme(
            elevation: 1.0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 5)
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo, brightness: Brightness.dark),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          focusedBorder: OutlineInputBorder(
            borderSide: BorderSide(color: Colors.indigoAccent, width: 2.0),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 20),
            textStyle: const TextStyle(fontSize: 16),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
            style: TextButton.styleFrom(
              textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            )
        ),
        cardTheme: CardTheme(
            elevation: 1.0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 5)
        ),
      ),
      themeMode: readingSettings.themeMode,
      home: const AuthGate(), // Start with AuthGate
      // Use this for testing if stuck on splash:
      // home: const Scaffold(body: Center(child: Text("App Started Successfully!"))),
    );
  }
}


// =========== [ AuthGate Widget - Decides Login vs. Main App ] ===========
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    final authService = Provider.of<AuthService>(context, listen: false);

    return StreamBuilder<User?>(
      stream: authService.authStateChanges,
      builder: (context, snapshot) {
        // --- Debug Logs for AuthGate ---
        print("AuthGate StreamBuilder state: ${snapshot.connectionState}");
        if (snapshot.hasError) {
          print("!!!!!!!!!!!! AuthGate Stream Error !!!!!!!!!!!!");
          print(snapshot.error.toString());
          // Consider showing an error message UI here
          return Scaffold(body: Center(child: Text('Auth Error: ${snapshot.error}')));
        }
        // --- End Debug Logs ---

        if (snapshot.connectionState == ConnectionState.waiting) {
          print("AuthGate: Waiting for auth state..."); // Debug log
          // Show loading indicator OR your native splash might still be visible
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }

        if (snapshot.hasData) {
          // User is logged in
          print("AuthGate: User is logged in (${snapshot.data?.uid}). Showing LibraryScreen."); // Debug log
          return const LibraryScreen(); // Show your main library screen
        } else {
          // User is logged out
          print("AuthGate: User is logged out. Showing LoginSignupFlow."); // Debug log
          return const LoginSignupFlow(); // Show the login/signup switcher
        }
      },
    );
  }
}


// =========== [ LoginSignupFlow Widget - Switches Login/Signup ] ===========
class LoginSignupFlow extends StatefulWidget {
  const LoginSignupFlow({super.key});
  @override
  State<LoginSignupFlow> createState() => _LoginSignupFlowState();
}

class _LoginSignupFlowState extends State<LoginSignupFlow> {
  bool _showLoginScreen = true;
  void toggleScreens() {
    setState(() => _showLoginScreen = !_showLoginScreen);
  }
  @override
  Widget build(BuildContext context) {
    if (_showLoginScreen) {
      return LoginScreen(onTapSwitch: toggleScreens);
    } else {
      return SignupScreen(onTapSwitch: toggleScreens);
    }
  }
}


// =========== [ LoginScreen Widget - UI ] ===========
// =========== [ LoginScreen Widget - MODIFIED ] ===========
// UI for the Login page
class LoginScreen extends StatefulWidget {
  final VoidCallback onTapSwitch;
  const LoginScreen({super.key, required this.onTapSwitch});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _isLoading = false;
  String? _errorMessage;

  // Login logic (unchanged)
  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) { return; }
    if (_isLoading) return;
    setState(() { _isLoading = true; _errorMessage = null; });
    final authService = Provider.of<AuthService>(context, listen: false);
    try {
      await authService.signInWithEmailPassword(_emailController.text, _passwordController.text,);
    } catch (e) {
      if (mounted) {
        setState(() { _errorMessage = e.toString().replaceFirst('Exception: ', ''); _isLoading = false; });
        ScaffoldMessenger.of(context).showSnackBar( SnackBar(content: Text(_errorMessage!), backgroundColor: Theme.of(context).colorScheme.error) );
      }
    } finally {
      if (mounted && _isLoading) { setState(() => _isLoading = false); }
    }
  }

  // --- ADDED: Forgot Password Logic ---
  Future<void> _forgotPassword() async {
    final email = _emailController.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: const Text('Please enter a valid email address first.'), backgroundColor: Colors.orangeAccent[700])
      );
      return;
    }

    // Show a loading indicator temporarily or disable button
    setState(() { _isLoading = true; _errorMessage = null; });
    final authService = Provider.of<AuthService>(context, listen: false);

    try {
      await authService.sendPasswordResetEmail(email);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Password reset email sent to $email. Please check your inbox (and spam folder).'), backgroundColor: Colors.green)
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() { _errorMessage = e.toString().replaceFirst('Exception: ', ''); });
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_errorMessage!), backgroundColor: Theme.of(context).colorScheme.error)
        );
      }
    } finally {
      if (mounted) { setState(() => _isLoading = false); } // Ensure loading stops
    }
  }
  // --- END ADDED: Forgot Password Logic ---

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(30.0),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text( "Welcome Back", style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold), textAlign: TextAlign.center ),
                  Text( "Login to your E-Book Reader", style: Theme.of(context).textTheme.titleSmall, textAlign: TextAlign.center ),
                  const SizedBox(height: 40),
                  TextFormField(
                    controller: _emailController,
                    decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.email_outlined)),
                    keyboardType: TextInputType.emailAddress,
                    validator: (value) { if (value == null || value.isEmpty || !value.contains('@')) { return 'Please enter a valid email'; } return null; },
                  ),
                  const SizedBox(height: 15),
                  TextFormField(
                    controller: _passwordController,
                    decoration: const InputDecoration(labelText: 'Password', prefixIcon: Icon(Icons.lock_outline)),
                    obscureText: true,
                    validator: (value) { if (value == null || value.isEmpty || value.length < 6) { return 'Password must be at least 6 characters'; } return null; },
                  ),
                  const SizedBox(height: 5), // Reduced spacing

                  // --- ADDED: Forgot Password Button ---
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                        onPressed: _isLoading ? null : _forgotPassword, // Call the new method
                        child: const Text('Forgot Password?'),
                        style: TextButton.styleFrom(
                            padding: EdgeInsets.zero, // Reduce default padding
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap, // Reduce tap area
                            alignment: Alignment.centerRight // Align text right
                        )
                    ),
                  ),
                  // --- END ADDED ---

                  const SizedBox(height: 5), // Adjusted spacing
                  if (_errorMessage != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8.0),
                      child: Text( _errorMessage!, style: TextStyle(color: Theme.of(context).colorScheme.error), textAlign: TextAlign.center, ),
                    ),
                  const SizedBox(height: 10),
                  _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : ElevatedButton.icon( icon: const Icon(Icons.login), label: const Text('Login'), onPressed: _login, ),
                  const SizedBox(height: 20),
                  TextButton( onPressed: _isLoading ? null : widget.onTapSwitch, child: const Text("Don't have an account? Sign Up"), ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
// ===================================================


// =========== [ SignupScreen Widget - UI ] ===========
class SignupScreen extends StatefulWidget {
  final VoidCallback onTapSwitch;
  const SignupScreen({super.key, required this.onTapSwitch});
  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPasswordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _isLoading = false;
  String? _errorMessage;

  Future<void> _signup() async {
    if (!_formKey.currentState!.validate()) return;
    if (_isLoading) return;
    setState(() { _isLoading = true; _errorMessage = null; });
    final authService = Provider.of<AuthService>(context, listen: false);
    try {
      await authService.signUpWithEmailPassword(_emailController.text, _passwordController.text);
      // AuthGate handles navigation
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString().replaceFirst('Exception: ', '');
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_errorMessage!), backgroundColor: Theme.of(context).colorScheme.error)
        );
      }
    } finally {
      if (mounted && _isLoading) { setState(() => _isLoading = false); }
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Create Account"),
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(30.0),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                      "Create your Account",
                      style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center
                  ),
                  Text(
                      "Join the E-Book Reader community",
                      style: Theme.of(context).textTheme.titleSmall,
                      textAlign: TextAlign.center
                  ),
                  const SizedBox(height: 40),
                  TextFormField(
                    controller: _emailController,
                    decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.email_outlined)),
                    keyboardType: TextInputType.emailAddress,
                    validator: (value) {
                      if (value == null || value.isEmpty || !value.contains('@')) {
                        return 'Please enter a valid email';
                      } return null;
                    },
                  ),
                  const SizedBox(height: 15),
                  TextFormField(
                    controller: _passwordController,
                    decoration: const InputDecoration(labelText: 'Password', prefixIcon: Icon(Icons.lock_outline)),
                    obscureText: true,
                    validator: (value) {
                      if (value == null || value.isEmpty || value.length < 6) {
                        return 'Password must be at least 6 characters';
                      } return null;
                    },
                  ),
                  const SizedBox(height: 15),
                  TextFormField(
                    controller: _confirmPasswordController,
                    decoration: const InputDecoration(labelText: 'Confirm Password', prefixIcon: Icon(Icons.lock_reset_outlined)),
                    obscureText: true,
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'Please confirm your password';
                      }
                      if (value != _passwordController.text) {
                        return 'Passwords do not match';
                      } return null;
                    },
                  ),
                  const SizedBox(height: 10),
                  if (_errorMessage != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8.0),
                      child: Text(
                        _errorMessage!,
                        style: TextStyle(color: Theme.of(context).colorScheme.error),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  const SizedBox(height: 10),
                  _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : ElevatedButton.icon(
                    icon: const Icon(Icons.person_add_alt_1),
                    label: const Text('Sign Up'),
                    onPressed: _signup,
                  ),
                  const SizedBox(height: 20),
                  TextButton(
                    onPressed: _isLoading ? null : widget.onTapSwitch,
                    child: const Text('Already have an account? Login'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}


// =========== [ LibraryScreen Widget - Main App Screen ] ===========
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
        if (locatorData is String) { locatorJsonString = locatorData; }
        else if (locatorData is Map) {
          try { locatorJsonString = json.encode(locatorData); }
          catch (e) { print("Listener Error encoding map for $bookId: $e"); }
        }
        if (locatorJsonString != null) {
          if (locatorJsonString != '{}') { await _updateBookProgress(bookId, locatorJsonString); }
          else { print("Listener Info: Received empty locator '{}' for $bookId, skipping update."); }
        } else { print("Listener Error: Unrecognized locator format for $bookId: $locatorData"); }
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
      if (bookIndex != -1 && books[bookIndex].lastLocatorJson == newLocatorJson) return;
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
        if (maps.isNotEmpty) { freshBook = Book.fromMap(maps.first); print("Fetched fresh data for book ID ${book.id} before StatsScreen."); }
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
            TextButton( child: const Text('Cancel'), onPressed: () => Navigator.of(ctx).pop()),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
              child: const Text('Delete'),
              onPressed: () async {
                Navigator.of(ctx).pop(); // Close dialog first
                if (!mounted) return;
                await _deleteBook(book);
                if (mounted && Navigator.canPop(context)) {
                  // Pop the StatsScreen if delete came from there
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
    if (book.id == null) { print("Error: Cannot delete book with null ID."); return; }
    if (mounted && !isLoading) setState(() => isLoading = true);
    try {
      if (_timeTracker?.bookId == book.id) { await _timeTracker?.stopAndSaveTracking(); _timeTracker = null; print("Stopped tracker for book ID ${book.id} during deletion."); }
      if (_locatorSubscription != null && _timeTracker?.bookId == book.id ) { _locatorSubscription?.cancel(); _locatorSubscription = null; print("Cancelled locator listener for book ID ${book.id} during deletion."); }
      final file = File(book.filePath);
      if (await file.exists()) { await file.delete(); print("Deleted file: ${book.filePath}"); }
      else { print("File not found for deletion: ${book.filePath}"); }
      await _databaseHelper.deleteBook(book.id!);
      await _loadBooks(); // Refreshes list and sets isLoading=false
      if (mounted && showSnackbar) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('"${book.title}" deleted.'))); }
    } catch (e, stackTrace) {
      print("Error deleting book ID ${book.id}: $e\n$stackTrace");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error deleting "${book.title}".')));
        if (isLoading) setState(() { isLoading = false; });
      }
    }
  }

  void _toggleViewType() {
    final settings = Provider.of<ReadingSettings>(context, listen: false);
    final currentType = settings.libraryViewType;
    final nextType = currentType == LibraryViewType.grid ? LibraryViewType.list : LibraryViewType.grid;
    settings.updateSetting(ReadingSettings._libraryViewTypeKey, nextType);
  }

  @override
  Widget build(BuildContext context) {
    final readingSettings = context.watch<ReadingSettings>();
    final currentViewType = readingSettings.libraryViewType;
    // final authService = Provider.of<AuthService>(context, listen: false); // Access if needed
    // final userEmail = authService.currentUser?.email; // Optional: Get user email

    return Scaffold(
      appBar: AppBar(
        title: const Text('My EPUB Library'),
        // subtitle: userEmail != null ? Text(userEmail) : null, // Optional
        actions: [
          IconButton(
            icon: Icon(currentViewType == LibraryViewType.grid ? Icons.view_list_outlined : Icons.grid_view_outlined),
            tooltip: currentViewType == LibraryViewType.grid ? 'Switch to List View' : 'Switch to Grid View',
            onPressed: _toggleViewType,
          ),
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
          : RefreshIndicator(
        onRefresh: _loadBooks,
        child: currentViewType == LibraryViewType.grid ? _buildBookGridView() : _buildBookListView(),
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
    const double gridPadding = 12.0;
    const double crossAxisSpacing = 12.0;
    const double mainAxisSpacing = 16.0;
    final double itemWidth = (screenWidth - (gridPadding * 2) - (crossAxisSpacing * (crossAxisCount - 1))) / crossAxisCount;
    final double coverHeight = itemWidth * 1.5;
    const double textHeight = 60;
    const double progressBarHeight = 8;
    final double itemHeight = coverHeight + textHeight + progressBarHeight;
    final double childAspectRatio = itemWidth / itemHeight;

    return GridView.builder(
      key: const PageStorageKey('libraryGrid'),
      padding: const EdgeInsets.all(gridPadding),
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
                  boxShadow: [ BoxShadow( color: Colors.black.withOpacity(0.05), blurRadius: 4, offset: const Offset(0, 2),),],
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.start,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ClipRRect(
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(8.0)),
                      child: Container(
                        height: coverHeight, width: double.infinity, color: Theme.of(context).colorScheme.surfaceVariant,
                        child: (book.coverImagePath != null && book.coverImagePath!.isNotEmpty)
                            ? Image.asset( book.coverImagePath!, fit: BoxFit.cover, errorBuilder: (ctx, err, st) => const Center(child: Icon(Icons.broken_image_outlined, color: Colors.grey, size: 40)))
                            : Center(child: Icon(Icons.menu_book, size: 50.0, color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.6))),
                      ),
                    ),
                    const SizedBox(height: 6.0),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8.0),
                      child: Text( book.title, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500, height: 1.3),),
                    ),
                    const Spacer(),
                    if (progress > 0.0)
                      Padding(
                        padding: const EdgeInsets.only(left: 8.0, right: 8.0, bottom: 8.0, top: 4.0),
                        child: SizedBox( height: progressBarHeight, child: LinearProgressIndicator( value: progress, backgroundColor: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.5), valueColor: AlwaysStoppedAnimation<Color>(Theme.of(context).colorScheme.primary), borderRadius: BorderRadius.circular(progressBarHeight / 2), ),),
                      )
                    else const SizedBox(height: progressBarHeight + 12.0), // Keep spacing consistent
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
    const double listPadding = 8.0;
    const double coverSize = 60.0;

    return ListView.builder(
      key: const PageStorageKey('libraryList'),
      padding: const EdgeInsets.all(listPadding),
      itemCount: books.length,
      itemBuilder: (context, index) {
        try {
          final book = books[index];
          final double progress = book.progression;
          return Card(
            margin: const EdgeInsets.symmetric(vertical: 5.0), elevation: 1.5, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
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
                        width: coverSize, height: coverSize * 1.4, color: Theme.of(context).colorScheme.surfaceVariant,
                        child: (book.coverImagePath != null && book.coverImagePath!.isNotEmpty)
                            ? Image.asset( book.coverImagePath!, fit: BoxFit.cover, errorBuilder: (ctx, err, st) => const Center(child: Icon(Icons.broken_image_outlined, size: 24, color: Colors.grey)))
                            : Center(child: Icon(Icons.menu_book, size: 30.0, color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.6))),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text( book.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w500), ),
                          const SizedBox(height: 8),
                          if (progress > 0.0) ...[
                            const SizedBox(height: 8),
                            LinearProgressIndicator( value: progress, backgroundColor: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.5), valueColor: AlwaysStoppedAnimation<Color>(Theme.of(context).colorScheme.primary), minHeight: 5, borderRadius: BorderRadius.circular(2.5),),
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
          return ListTile( leading: const Icon(Icons.error, color: Colors.red), title: const Text('Error loading item'), subtitle: Text(e.toString()), );
        }
      },
    );
  }
}


// =========== [ StatsScreen Widget - Book Details/Actions ] ===========
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
            if (book.coverImagePath != null && book.coverImagePath!.isNotEmpty)
              Center( child: ConstrainedBox( constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.3), child: ClipRRect( borderRadius: BorderRadius.circular(12.0), child: Image.asset( book.coverImagePath!, fit: BoxFit.contain, errorBuilder: (ctx, err, st) => const Icon(Icons.error, size: 60) ) ) ), ),
            if (book.coverImagePath != null) const SizedBox(height: 24),
            Card(
              elevation: 2, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding( padding: const EdgeInsets.symmetric(vertical: 12.0, horizontal: 16.0), child: _buildStatRow(context, Icons.timer_outlined, 'Total Time Read', _formatDurationLocal(Duration(seconds: book.totalReadingTime))), ),
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
          Expanded( child: Text( value, style: Theme.of(context).textTheme.bodyMedium, textAlign: TextAlign.end, softWrap: true, overflow: TextOverflow.fade, ) ),
        ],
      ),
    );
  }
}


// =========== [ SettingsScreen Widget - App/Account Settings ] ===========
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final readingSettings = context.watch<ReadingSettings>();
    final authService = Provider.of<AuthService>(context, listen: false);
    final userEmail = authService.currentUser?.email;

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
          _buildSectionHeader(context, 'Account'),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Logout'),
            subtitle: userEmail != null ? Text('Logged in as: $userEmail') : null,
            onTap: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Confirm Logout'),
                  content: const Text('Are you sure you want to log out?'),
                  actions: [
                    TextButton( onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel'), ),
                    TextButton( style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error), onPressed: () => Navigator.of(context).pop(true), child: const Text('Logout'), ),
                  ],
                ),
              );
              if (confirm == true && context.mounted) {
                await authService.signOut();
                Navigator.of(context).popUntil((route) => route.isFirst);
              }
            },
          ),
          const Divider(height: 20, thickness: 1),
          _buildSectionHeader(context, 'About'),
          _buildAboutTile(context),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 16.0, right: 16.0, top: 20.0, bottom: 8.0),
      child: Text( title, style: Theme.of(context).textTheme.titleMedium?.copyWith( color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600, ), ),
    );
  }

  Widget _buildThemeSetting(BuildContext context, ReadingSettings settings) {
    return ListTile(
      leading: Icon( settings.themeMode == ThemeMode.light ? Icons.wb_sunny_outlined : settings.themeMode == ThemeMode.dark ? Icons.nightlight_outlined : Icons.brightness_auto_outlined ),
      title: const Text('App Theme'),
      trailing: DropdownButton<ThemeMode>(
        value: settings.themeMode, underline: Container(), borderRadius: BorderRadius.circular(8),
        items: const [ DropdownMenuItem(value: ThemeMode.system, child: Text('System Default')), DropdownMenuItem(value: ThemeMode.light, child: Text('Light')), DropdownMenuItem(value: ThemeMode.dark, child: Text('Dark')), ],
        onChanged: (value) { if (value != null) { settings.updateSetting(ReadingSettings._themeModeKey, value); } },
      ),
    );
  }

  Widget _buildScrollDirectionSetting(BuildContext context, ReadingSettings settings) {
    return ListTile(
      leading: const Icon(Icons.swap_horiz_outlined),
      title: const Text('Reader Scroll Direction'),
      trailing: DropdownButton<EpubScrollDirection>(
        value: settings.scrollDirection, underline: Container(), borderRadius: BorderRadius.circular(8),
        items: const [ DropdownMenuItem(value: EpubScrollDirection.HORIZONTAL, child: Text('Horizontal')), DropdownMenuItem(value: EpubScrollDirection.VERTICAL, child: Text('Vertical')), ],
        onChanged: (value) { if (value != null) { settings.updateSetting(ReadingSettings._scrollDirectionKey, value); } },
      ),
    );
  }

  Widget _buildAboutTile(BuildContext context) {
    String appVersion = '1.7.0'; // Consider using package_info_plus
    return ListTile(
      leading: const Icon(Icons.info_outline), title: const Text('App Version'), subtitle: Text(appVersion),
      onTap: () {
        showAboutDialog( context: context, applicationName: 'Flutter EPUB Reader', applicationVersion: appVersion, applicationLegalese: '© 2024 Your Name/Company',
          children: [ const Padding( padding: EdgeInsets.only(top: 15), child: Text('A simple EPUB reader application built using Flutter.') ) ],
        );
      },
    );
  }
}


// =========== [ HighlightsScreen Widget - View Highlights ] ===========
class HighlightsScreen extends StatelessWidget {
  final Book book;
  const HighlightsScreen({Key? key, required this.book}) : super(key: key);

  Map<String, List<String>> _getValidHighlights() {
    try {
      if (book.highlights is Map) {
        final potentialMap = book.highlights;
        if (potentialMap.keys.every((k) => k is String) && potentialMap.values.every((v) => v is List && v.every((item) => item is String))) {
          return Map<String, List<String>>.from(potentialMap);
        }
      }
    } catch (e) { print("Error accessing or casting highlights map: $e");}
    return {};
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, List<String>> highlights = _getValidHighlights();
    final List<MapEntry<String, List<String>>> chapterEntries = highlights.entries.where((entry) => entry.value.isNotEmpty).toList();

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
              children: chapterHighlights.map((text) {
                return Padding(
                  padding: const EdgeInsets.only(top: 10.0),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration( color: Theme.of(context).colorScheme.secondaryContainer.withOpacity(0.7), borderRadius: BorderRadius.circular(8), ),
                    child: SelectableText( text.trim(), style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.4) ),
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