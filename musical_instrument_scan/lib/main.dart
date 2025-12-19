import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'package:fl_chart/fl_chart.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:intl/intl.dart';
import 'package:csv/csv.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;

class ScanRecord {
  final int? id;
  final String instrumentName;
  final String prediction;
  final double accuracy;
  final DateTime scanDate;

  ScanRecord({
    this.id,
    required this.instrumentName,
    required this.prediction,
    required this.accuracy,
    required this.scanDate,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'instrumentName': instrumentName,
      'prediction': prediction,
      'accuracy': accuracy,
      'scanDate': scanDate.toIso8601String(),
    };
  }

  factory ScanRecord.fromMap(Map<String, dynamic> map) {
    return ScanRecord(
      id: map['id'],
      instrumentName: map['instrumentName'],
      prediction: map['prediction'],
      accuracy: map['accuracy'],
      scanDate: DateTime.parse(map['scanDate']),
    );
  }
}

class DatabaseService {
  static final DatabaseService _instance = DatabaseService._internal();
  static Database? _database;

  DatabaseService._internal();

  factory DatabaseService() {
    return _instance;
  }

  Future<Database> get database async {
    _database ??= await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'scan_history.db');
    return openDatabase(
      path,
      version: 1,
      onCreate: _createDb,
    );
  }

  Future<void> _createDb(Database db, int version) async {
    await db.execute(
      'CREATE TABLE scan_records('
      'id INTEGER PRIMARY KEY AUTOINCREMENT,'
      'instrumentName TEXT,'
      'prediction TEXT,'
      'accuracy REAL,'
      'scanDate TEXT'
      ')',
    );
  }

  Future<int> insertScan(ScanRecord record) async {
    final db = await database;
    return db.insert('scan_records', record.toMap());
  }

  Future<List<ScanRecord>> getAllScans() async {
    final db = await database;
    final maps = await db.query('scan_records', orderBy: 'scanDate DESC');
    return maps.map((map) => ScanRecord.fromMap(map)).toList();
  }

  Future<List<ScanRecord>> getScansByDateRange(DateTime start, DateTime end) async {
    final db = await database;
    final maps = await db.query(
      'scan_records',
      where: 'scanDate BETWEEN ? AND ?',
      whereArgs: [start.toIso8601String(), end.toIso8601String()],
      orderBy: 'scanDate DESC',
    );
    return maps.map((map) => ScanRecord.fromMap(map)).toList();
  }

  Future<int> deleteAllScans() async {
    final db = await database;
    return db.delete('scan_records');
  }
}

class TFLiteService {
  static final TFLiteService _instance = TFLiteService._internal();
  late List<String> _labels;
  Interpreter? _interpreter;
  bool _initialized = false;

  TFLiteService._internal();

  factory TFLiteService() {
    return _instance;
  }

  Future<void> initialize() async {
    if (_initialized) return;
    
    try {
      await _loadLabels();
      await _loadModel();
      _initialized = true;
    } catch (e) {
      print('Error initializing model service: $e');
      rethrow;
    }
  }

  Future<void> _loadLabels() async {
    try {
      final labelData = await rootBundle.loadString('assets/model/labels.txt');
      _labels = labelData.split('\n').where((line) => line.isNotEmpty).map((line) {
        final parts = line.split(' ');
        return parts.length > 1 ? parts.sublist(1).join(' ') : line;
      }).toList();
    } catch (e) {
      print('Error loading labels: $e');
      _labels = ['Guitar', 'Piano', 'Cello', 'Violin', 'Drums', 'Trumpet', 'Flute', 'Saxophone', 'Harp', 'Clarinet'];
    }
  }

  Future<void> _loadModel() async {
    try {
      _interpreter = await Interpreter.fromAsset('assets/model/model.tflite');
    } catch (e) {
      print('Error loading TFLite model: $e');
      throw Exception('Failed to load TFLite model: $e');
    }
  }

  Future<Map<String, dynamic>> predict(File imageFile) async {
    if (!_initialized || _interpreter == null) {
      throw Exception('Model service not initialized');
    }

    try {
      final imageBytes = await imageFile.readAsBytes();
      final decodedImage = img.decodeImage(imageBytes);
      
      if (decodedImage == null) {
        throw Exception('Failed to decode image');
      }

      final resized = img.copyResize(decodedImage, width: 224, height: 224);
      
      final input = _preprocessImage(resized);
      final output = List<List<double>>.generate(1, (i) => List<double>.filled(_labels.length, 0.0));
      
      _interpreter!.run(input, output);
      
      final predictions = output[0];
      int predictedIndex = 0;
      double maxConfidence = predictions[0];
      
      for (int i = 1; i < predictions.length; i++) {
        if (predictions[i] > maxConfidence) {
          maxConfidence = predictions[i];
          predictedIndex = i;
        }
      }
      
      final confidence = (maxConfidence * 100).clamp(0.0, 100.0);
      
      return {
        'prediction': _labels[predictedIndex],
        'accuracy': confidence,
        'index': predictedIndex,
      };
    } catch (e) {
      print('Error during prediction: $e');
      rethrow;
    }
  }

  List<List<List<List<double>>>> _preprocessImage(img.Image image) {
    List<List<List<List<double>>>> input = List.generate(
      1,
      (i) => List.generate(
        224,
        (j) => List.generate(
          224,
          (k) => List.generate(3, (l) => 0.0),
        ),
      ),
    );

    for (int y = 0; y < 224; y++) {
      for (int x = 0; x < 224; x++) {
        final pixel = image.getPixelSafe(x, y);
        input[0][y][x][0] = pixel.r.toDouble() / 255.0;
        input[0][y][x][1] = pixel.g.toDouble() / 255.0;
        input[0][y][x][2] = pixel.b.toDouble() / 255.0;
      }
    }

    return input;
  }

  void dispose() {
    _interpreter?.close();
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  bool _isDarkMode = false;

  @override
  void initState() {
    super.initState();
    _initializeTFLite();
  }

  Future<void> _initializeTFLite() async {
    try {
      await TFLiteService().initialize();
    } catch (e) {
      print('Failed to initialize TFLite: $e');
    }
  }

  void _toggleDarkMode() {
    setState(() {
      _isDarkMode = !_isDarkMode;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Musical Instruments Scanner',
      debugShowCheckedModeBanner: false,
      theme: _buildLightTheme(),
      darkTheme: _buildDarkTheme(),
      themeMode: _isDarkMode ? ThemeMode.dark : ThemeMode.light,
      home: SplashScreen(
        toggleDarkMode: _toggleDarkMode,
        isDarkMode: _isDarkMode,
      ),
    );
  }

  ThemeData _buildLightTheme() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF7C3AED),
        brightness: Brightness.light,
      ),
      scaffoldBackgroundColor: const Color(0xFFFAFAFA),
      appBarTheme: const AppBarTheme(
        elevation: 0,
        backgroundColor: Colors.white,
        foregroundColor: Color(0xFF1F2937),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        color: Colors.white,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF7C3AED),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          elevation: 0,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFFF3F4F6),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF7C3AED), width: 2),
        ),
      ),
    );
  }

  ThemeData _buildDarkTheme() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF7C3AED),
        brightness: Brightness.dark,
      ),
      scaffoldBackgroundColor: const Color(0xFF111827),
      appBarTheme: const AppBarTheme(
        elevation: 0,
        backgroundColor: Color(0xFF1F2937),
        foregroundColor: Colors.white,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        color: const Color(0xFF1F2937),
      ),
    );
  }
}

class SplashScreen extends StatefulWidget {
  final VoidCallback toggleDarkMode;
  final bool isDarkMode;

  const SplashScreen({
    super.key,
    required this.toggleDarkMode,
    required this.isDarkMode,
  });

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );
    _animationController.forward();
    
    Future.delayed(const Duration(seconds: 10), _navigateToHome);
  }

  void _navigateToHome() {
    if (mounted) {
      Navigator.of(this.context).pushReplacement(
        MaterialPageRoute(
          builder: (ctx) => MyHomePage(
            toggleDarkMode: widget.toggleDarkMode,
            isDarkMode: widget.isDarkMode,
          ),
        ),
      );
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          image: DecorationImage(
            image: AssetImage('assets/images/instruments_bg.jpeg'),
            fit: BoxFit.cover,
          ),
        ),
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.3),
                Colors.black.withValues(alpha: 0.6),
              ],
            ),
          ),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                FadeTransition(
                  opacity: _animationController,
                  child: ScaleTransition(
                    scale: Tween<double>(begin: 0.8, end: 1.0)
                        .animate(_animationController),
                    child: Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: const Color(0xFF7C3AED).withValues(alpha: 0.2),
                        border: Border.all(
                          color: const Color(0xFF7C3AED),
                          width: 2,
                        ),
                      ),
                      child: Image.asset(
                        'assets/images/logo.png',
                        width: 100,
                        height: 100,
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 32),
                SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 0.3),
                    end: Offset.zero,
                  ).animate(
                    CurvedAnimation(
                      parent: _animationController,
                      curve: Curves.easeOut,
                    ),
                  ),
                  child: Column(
                    children: [
                      const Text(
                        'Musical Instruments',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 32,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Text(
                        'Scanner',
                        style: TextStyle(
                          color: Color(0xFF7C3AED),
                          fontSize: 32,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                FadeTransition(
                  opacity: Tween<double>(begin: 0, end: 1).animate(
                    CurvedAnimation(
                      parent: _animationController,
                      curve: const Interval(0.3, 1.0, curve: Curves.easeOut),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFF7C3AED).withValues(alpha: 0.6),
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'Loading...',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 48),
                FadeTransition(
                  opacity: Tween<double>(begin: 0, end: 1).animate(
                    CurvedAnimation(
                      parent: _animationController,
                      curve: const Interval(0.5, 1.0, curve: Curves.easeOut),
                    ),
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: Colors.green.withValues(alpha: 0.5),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.check_circle,
                          color: Colors.green,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'App Ready',
                          style: TextStyle(
                            color: Colors.green,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({
    super.key,
    required this.toggleDarkMode,
    required this.isDarkMode,
  });

  final VoidCallback toggleDarkMode;
  final bool isDarkMode;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> with SingleTickerProviderStateMixin {
  late AnimationController _animationController;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    );
    _animationController.forward();
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        leading: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF7C3AED).withValues(alpha: 0.1),
            ),
            child: const Icon(Icons.music_note, color: Color(0xFF7C3AED)),
          ),
        ),
        title: const Text(
          'Musical Scanner',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: IconButton(
              icon: Icon(
                widget.isDarkMode ? Icons.light_mode : Icons.dark_mode,
                color: const Color(0xFF7C3AED),
              ),
              onPressed: widget.toggleDarkMode,
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              image: DecorationImage(
                image: AssetImage('assets/images/instruments_bg.jpeg'),
                fit: BoxFit.cover,
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.2),
                  Colors.black.withValues(alpha: 0.5),
                ],
              ),
            ),
          ),
          SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const SizedBox(height: 40),
                FadeTransition(
                  opacity: _animationController,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.3),
                      end: Offset.zero,
                    ).animate(_animationController),
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 24),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            const Color(0xFF7C3AED),
                            const Color(0xFF7C3AED).withValues(alpha: 0.7),
                          ],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(24),
                      ),
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          const Text(
                            'Welcome Back!',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 32,
                              fontWeight: FontWeight.bold,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'Discover musical instruments with AI-powered recognition',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 16,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 24),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.green.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: Colors.green.withValues(alpha: 0.5),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.check_circle,
                                  color: Colors.green,
                                  size: 16,
                                ),
                                const SizedBox(width: 6),
                                const Text(
                                  'App Ready',
                                  style: TextStyle(
                                    color: Colors.green,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 24),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) => ExplorePage(
                                      toggleDarkMode: widget.toggleDarkMode,
                                      isDarkMode: widget.isDarkMode,
                                    ),
                                  ),
                                );
                              },
                              icon: const Icon(Icons.arrow_forward),
                              label: const Text('Start Exploring'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.white,
                                foregroundColor: const Color(0xFF7C3AED),
                                padding: const EdgeInsets.symmetric(vertical: 14),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 32),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const Text(
                        'Features',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 16),
                      _featureCard(
                        context,
                        Icons.camera_alt,
                        'Smart Camera',
                        'Capture instruments in real-time',
                      ),
                      const SizedBox(height: 12),
                      _featureCard(
                        context,
                        Icons.analytics,
                        'Analytics',
                        'Track and analyze your scans',
                      ),
                      const SizedBox(height: 12),
                      _featureCard(
                        context,
                        Icons.library_music,
                        '10+ Instruments',
                        'Guitars, pianos, violins and more',
                      ),
                      const SizedBox(height: 32),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _featureCard(
    BuildContext context,
    IconData icon,
    String title,
    String subtitle,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF7C3AED).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: const Color(0xFF7C3AED), size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey[600],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ExplorePage extends StatefulWidget {
  const ExplorePage({
    super.key,
    required this.toggleDarkMode,
    required this.isDarkMode,
  });

  final VoidCallback toggleDarkMode;
  final bool isDarkMode;

  @override
  State<ExplorePage> createState() => _ExplorePageState();
}

class _ExplorePageState extends State<ExplorePage> {
  int _selectedIndex = 0;

  late final List<Widget> _widgetOptions;

  @override
  void initState() {
    super.initState();
    _widgetOptions = <Widget>[
      const CategoryPage(),
      const AnalyticsPage(),
      SettingsPage(
        toggleDarkMode: widget.toggleDarkMode,
        isDarkMode: widget.isDarkMode,
      ),
    ];
  }

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.deepPurple,
        title: const Text('Explore'),
        leading: IconButton(
          icon: const Icon(Icons.home),
          onPressed: () {
            Navigator.pop(context);
          },
        ),
      ),
      body: _widgetOptions.elementAt(_selectedIndex),
      bottomNavigationBar: BottomNavigationBar(
        items: const <BottomNavigationBarItem>[
          BottomNavigationBarItem(
            icon: Icon(Icons.category),
            label: 'Category',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.analytics),
            label: 'Analytics',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
        currentIndex: _selectedIndex,
        selectedItemColor: Colors.deepPurple,
        onTap: _onItemTapped,
      ),
    );
  }
}

class CategoryPage extends StatefulWidget {
  const CategoryPage({super.key});

  @override
  State<CategoryPage> createState() => _CategoryPageState();
}

class _CategoryPageState extends State<CategoryPage> {
  final List<Map<String, String>> instruments = const [
    {'name': 'Guitar', 'image': 'assets/images/guitar.jpeg', 'description': 'A string instrument played by plucking or strumming.'},
    {'name': 'Piano', 'image': 'assets/images/piano.jpeg', 'description': 'A keyboard instrument with 88 keys.'},
    {'name': 'Cello', 'image': 'assets/images/cello.jpeg', 'description': 'A bowed string instrument, larger than a violin.'},
    {'name': 'Violin', 'image': 'assets/images/violin.jpg', 'description': 'A small string instrument played with a bow.'},
    {'name': 'Drum', 'image': 'assets/images/drum.jpeg', 'description': 'A percussion instrument struck with sticks.'},
    {'name': 'Trumpet', 'image': 'assets/images/trumpet.jpeg', 'description': 'A brass instrument played by blowing air.'},
    {'name': 'Flute', 'image': 'assets/images/flute.png', 'description': 'A woodwind instrument played by blowing across a hole.'},
    {'name': 'Saxophone', 'image': 'assets/images/saxophone.jpeg', 'description': 'A woodwind instrument with a reed.'},
    {'name': 'Harp', 'image': 'assets/images/harp.jpeg', 'description': 'A string instrument plucked with fingers.'},
    {'name': 'Clarinet', 'image': 'assets/images/clarinet.jpeg', 'description': 'A woodwind instrument with a single reed.'},
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Instruments', style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: false,
        elevation: 0,
      ),
      body: GridView.builder(
        padding: const EdgeInsets.all(16),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 16,
          mainAxisSpacing: 16,
          childAspectRatio: 0.9,
        ),
        itemCount: instruments.length,
        itemBuilder: (context, index) {
          return _InstrumentCard(
            instrument: instruments[index],
            index: index,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => InstrumentDetailPage(instrument: instruments[index]),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _InstrumentCard extends StatefulWidget {
  final Map<String, String> instrument;
  final int index;
  final VoidCallback onTap;

  const _InstrumentCard({
    required this.instrument,
    required this.index,
    required this.onTap,
  });

  @override
  State<_InstrumentCard> createState() => _InstrumentCardState();
}

class _InstrumentCardState extends State<_InstrumentCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => _controller.forward(),
      onExit: (_) => _controller.reverse(),
      child: GestureDetector(
        onTap: widget.onTap,
        child: ScaleTransition(
          scale: Tween<double>(begin: 1.0, end: 1.05).animate(
            CurvedAnimation(parent: _controller, curve: Curves.easeOut),
          ),
          child: Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(
                color: const Color(0xFF7C3AED).withValues(alpha: 0.1),
              ),
            ),
            child: Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Image.asset(
                    widget.instrument['image']!,
                    fit: BoxFit.cover,
                    width: double.infinity,
                    height: double.infinity,
                  ),
                ),
                ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.7),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.instrument['name']!,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFF7C3AED),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          child: const Text(
                            'Tap to scan',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class InstrumentDetailPage extends StatefulWidget {
  final Map<String, String> instrument;

  const InstrumentDetailPage({super.key, required this.instrument});

  @override
  State<InstrumentDetailPage> createState() => _InstrumentDetailPageState();
}

class _InstrumentDetailPageState extends State<InstrumentDetailPage> {
  File? _selectedImage;
  String? _prediction;
  double? _accuracy;
  bool _isLoading = false;
  final DatabaseService _dbService = DatabaseService();
  final TFLiteService _tfliteService = TFLiteService();

  Future<void> _pickImage(ImageSource source) async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: source);

    if (pickedFile != null) {
      setState(() {
        _selectedImage = File(pickedFile.path);
      });
      await _runPrediction();
    }
  }

  Future<void> _runPrediction() async {
    if (_selectedImage == null) return;
    
    setState(() {
      _isLoading = true;
    });

    try {
      final result = await _tfliteService.predict(_selectedImage!);
      setState(() {
        _prediction = result['prediction'];
        _accuracy = result['accuracy'];
        _isLoading = false;
      });
      await _saveScanToDB();
    } catch (e) {
      setState(() {
        _isLoading = false;
        _prediction = 'Error: ${e.toString()}';
        _accuracy = 0;
      });
    }
  }

  Future<void> _saveScanToDB() async {
    if (_prediction != null && _accuracy != null) {
      final record = ScanRecord(
        instrumentName: widget.instrument['name']!,
        prediction: _prediction!,
        accuracy: _accuracy!,
        scanDate: DateTime.now(),
      );
      await _dbService.insertScan(record);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.instrument['name']!, style: const TextStyle(fontWeight: FontWeight.bold)),
        elevation: 0,
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: const BorderRadius.vertical(bottom: Radius.circular(24)),
              child: Image.asset(
                widget.instrument['image']!,
                height: 280,
                width: double.infinity,
                fit: BoxFit.cover,
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.instrument['name']!,
                    style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    widget.instrument['description']!,
                    style: TextStyle(fontSize: 16, color: Colors.grey[600], height: 1.6),
                  ),
                  const SizedBox(height: 32),
                  const Text(
                    'Scan to Identify',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: _ScanButton(
                          icon: Icons.camera_alt,
                          label: 'Camera',
                          onPressed: () => _pickImage(ImageSource.camera),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _ScanButton(
                          icon: Icons.image,
                          label: 'Gallery',
                          onPressed: () => _pickImage(ImageSource.gallery),
                        ),
                      ),
                    ],
                  ),
                  if (_selectedImage != null) ...[
                    const SizedBox(height: 32),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: Image.file(
                        _selectedImage!,
                        height: 240,
                        width: double.infinity,
                        fit: BoxFit.cover,
                      ),
                    ),
                    const SizedBox(height: 24),
                    if (_isLoading)
                      Center(
                        child: Column(
                          children: [
                            const SizedBox(height: 24),
                            const SizedBox(
                              width: 48,
                              height: 48,
                              child: CircularProgressIndicator(strokeWidth: 3),
                            ),
                            const SizedBox(height: 16),
                            const Text(
                              'Analyzing image...',
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                            ),
                          ],
                        ),
                      )
                    else if (_prediction != null)
                      _PredictionResult(
                        prediction: _prediction!,
                        accuracy: _accuracy!,
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScanButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  const _ScanButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon),
      label: Text(label),
      style: ElevatedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 16),
        backgroundColor: const Color(0xFF7C3AED),
        foregroundColor: Colors.white,
      ),
    );
  }
}

class _PredictionResult extends StatelessWidget {
  final String prediction;
  final double accuracy;

  const _PredictionResult({
    required this.prediction,
    required this.accuracy,
  });

  @override
  Widget build(BuildContext context) {
    final isHighAccuracy = accuracy > 80;
    
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
          color: const Color(0xFF7C3AED).withValues(alpha: 0.2),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: (isHighAccuracy ? Colors.green : Colors.orange).withValues(alpha: 0.1),
              ),
              child: Icon(
                isHighAccuracy ? Icons.check_circle : Icons.info,
                color: isHighAccuracy ? Colors.green : Colors.orange,
                size: 32,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Detection Result',
              style: TextStyle(fontSize: 16, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            Text(
              prediction,
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: Color(0xFF7C3AED),
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            _ConfidenceBar(accuracy: accuracy),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _StatItem(
                  label: 'Confidence',
                  value: '${accuracy.toStringAsFixed(1)}%',
                  color: isHighAccuracy ? Colors.green : Colors.orange,
                ),
                Container(height: 40, width: 1, color: Colors.grey[300]),
                _StatItem(
                  label: 'Status',
                  value: isHighAccuracy ? 'High' : 'Medium',
                  color: isHighAccuracy ? Colors.green : Colors.orange,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ConfidenceBar extends StatelessWidget {
  final double accuracy;

  const _ConfidenceBar({required this.accuracy});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Confidence Level', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Colors.grey)),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: accuracy / 100,
            minHeight: 12,
            backgroundColor: Colors.grey[200],
            valueColor: AlwaysStoppedAnimation<Color>(
              accuracy > 80 ? Colors.green : (accuracy > 60 ? Colors.orange : Colors.red),
            ),
          ),
        ),
      ],
    );
  }
}

class _StatItem extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _StatItem({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ],
    );
  }
}

class AnalyticsPage extends StatefulWidget {
  const AnalyticsPage({super.key});

  @override
  State<AnalyticsPage> createState() => _AnalyticsPageState();
}

class _AnalyticsPageState extends State<AnalyticsPage> {
  final DatabaseService _dbService = DatabaseService();
  late Future<List<ScanRecord>> _scans;
  DateTime _startDate = DateTime.now().subtract(const Duration(days: 30));
  DateTime _endDate = DateTime.now();
  String _searchQuery = '';
  int _selectedTab = 0;

  @override
  void initState() {
    super.initState();
    _refreshScans();
  }

  void _refreshScans() {
    setState(() {
      _scans = _dbService.getScansByDateRange(_startDate, _endDate);
    });
  }

  Future<void> _exportCSV(List<ScanRecord> records) async {
    List<List<dynamic>> rows = [];
    rows.add(['Instrument', 'Prediction', 'Accuracy (%)', 'Date']);
    for (var record in records) {
      rows.add([
        record.instrumentName,
        record.prediction,
        record.accuracy.toStringAsFixed(2),
        DateFormat('yyyy-MM-dd HH:mm').format(record.scanDate),
      ]);
    }
    
    String csv = const ListToCsvConverter().convert(rows);
    final directory = Directory.systemTemp;
    final file = File('${directory.path}/scan_analytics.csv');
    await file.writeAsString(csv);
    await Share.shareXFiles([XFile(file.path)], text: 'Scan Analytics');
  }

  Future<void> _exportPDF(List<ScanRecord> records) async {
    final pdf = pw.Document();
    
    pdf.addPage(
      pw.Page(
        build: (pw.Context context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text('Musical Instrument Scanner - Analytics Report',
                  style: pw.TextStyle(fontSize: 24, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 20),
              pw.Text('Date Range: ${DateFormat('yyyy-MM-dd').format(_startDate)} to ${DateFormat('yyyy-MM-dd').format(_endDate)}'),
              pw.SizedBox(height: 20),
              pw.Text('Total Scans: ${records.length}'),
              pw.SizedBox(height: 20),
              pw.TableHelper.fromTextArray(
                headers: ['Instrument', 'Prediction', 'Accuracy (%)', 'Date'],
                data: records.map((r) => [
                  r.instrumentName,
                  r.prediction,
                  r.accuracy.toStringAsFixed(2),
                  DateFormat('yyyy-MM-dd HH:mm').format(r.scanDate),
                ]).toList(),
              ),
            ],
          );
        },
      ),
    );

    final directory = Directory.systemTemp;
    final file = File('${directory.path}/scan_analytics.pdf');
    await file.writeAsBytes(await pdf.save());
    await Share.shareXFiles([XFile(file.path)], text: 'Scan Analytics');
  }

  Map<String, int> _getInstrumentCount(List<ScanRecord> records) {
    final Map<String, int> count = {};
    for (var record in records) {
      count[record.prediction] = (count[record.prediction] ?? 0) + 1;
    }
    return count;
  }

  List<FlSpot> _getAccuracyTrend(List<ScanRecord> records) {
    if (records.isEmpty) return [];
    records.sort((a, b) => a.scanDate.compareTo(b.scanDate));
    return List.generate(
      records.length,
      (i) => FlSpot(i.toDouble(), records[i].accuracy),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<ScanRecord>>(
      future: _scans,
      builder: (context, snapshot) {
        final records = snapshot.data ?? [];
        final filteredRecords = records
            .where((r) => r.prediction.toLowerCase().contains(_searchQuery.toLowerCase()))
            .toList();

        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Analytics', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton(
                            onPressed: () async {
                              final date = await showDatePicker(
                                context: context,
                                initialDate: _startDate,
                                firstDate: DateTime(2020),
                                lastDate: DateTime.now(),
                              );
                              if (date != null) {
                                setState(() => _startDate = date);
                                _refreshScans();
                              }
                            },
                            child: Text('From: ${DateFormat('MMM dd').format(_startDate)}'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: () async {
                              final date = await showDatePicker(
                                context: context,
                                initialDate: _endDate,
                                firstDate: DateTime(2020),
                                lastDate: DateTime.now(),
                              );
                              if (date != null) {
                                setState(() => _endDate = date);
                                _refreshScans();
                              }
                            },
                            child: Text('To: ${DateFormat('MMM dd').format(_endDate)}'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      onChanged: (value) => setState(() => _searchQuery = value),
                      decoration: InputDecoration(
                        hintText: 'Search instruments...',
                        prefixIcon: const Icon(Icons.search),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: () => _exportCSV(filteredRecords),
                            icon: const Icon(Icons.download),
                            label: const Text('CSV'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: () => _exportPDF(filteredRecords),
                            icon: const Icon(Icons.picture_as_pdf),
                            label: const Text('PDF'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Row(
                  children: [
                    Expanded(
                      child: SegmentedButton<int>(
                        segments: const [
                          ButtonSegment(label: Text('Overview'), value: 0),
                          ButtonSegment(label: Text('History'), value: 1),
                        ],
                        selected: {_selectedTab},
                        onSelectionChanged: (Set<int> newSelection) {
                          setState(() => _selectedTab = newSelection.first);
                        },
                      ),
                    ),
                  ],
                ),
              ),
              if (_selectedTab == 0) ...[
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Total Scans: ${filteredRecords.length}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      Text('Avg Accuracy: ${filteredRecords.isEmpty ? 0 : (filteredRecords.fold<double>(0, (sum, r) => sum + r.accuracy) / filteredRecords.length).toStringAsFixed(2)}%', style: const TextStyle(fontSize: 16)),
                      const SizedBox(height: 20),
                      const Text('Accuracy Trend', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      if (filteredRecords.isNotEmpty)
                        SizedBox(
                          height: 200,
                          child: LineChart(
                            LineChartData(
                              gridData: FlGridData(show: true),
                              titlesData: FlTitlesData(show: true),
                              borderData: FlBorderData(show: true),
                              lineBarsData: [
                                LineChartBarData(
                                  spots: _getAccuracyTrend(filteredRecords),
                                  isCurved: true,
                                  color: Colors.deepPurple,
                                  barWidth: 3,
                                  belowBarData: BarAreaData(show: true, color: Colors.deepPurple.withValues(alpha: 0.2)),
                                ),
                              ],
                            ),
                          ),
                        )
                      else
                        const Center(child: Text('No data available')),
                      const SizedBox(height: 20),
                      const Text('Instrument Distribution', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      if (_getInstrumentCount(filteredRecords).isNotEmpty)
                        SizedBox(
                          height: 250,
                          child: PieChart(
                            PieChartData(
                              sections: _getInstrumentCount(filteredRecords)
                                  .entries
                                  .toList()
                                  .asMap()
                                  .entries
                                  .map((entry) {
                                    final colors = [Colors.blue, Colors.red, Colors.green, Colors.orange, Colors.purple, Colors.teal, Colors.pink, Colors.yellow];
                                    return PieChartSectionData(
                                      value: entry.value.value.toDouble(),
                                      title: '${entry.value.key}\n${entry.value.value}',
                                      color: colors[entry.key % colors.length],
                                      radius: 80,
                                    );
                                  })
                                  .toList(),
                            ),
                          ),
                        )
                      else
                        const Center(child: Text('No data available')),
                    ],
                  ),
                ),
              ] else ...[
                ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: filteredRecords.length,
                  itemBuilder: (context, index) {
                    final record = filteredRecords[index];
                    return ListTile(
                      title: Text(record.prediction),
                      subtitle: Text('Accuracy: ${record.accuracy.toStringAsFixed(2)}%'),
                      trailing: Text(DateFormat('MMM dd, HH:mm').format(record.scanDate)),
                    );
                  },
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.toggleDarkMode,
    required this.isDarkMode,
  });

  final VoidCallback toggleDarkMode;
  final bool isDarkMode;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _notificationsEnabled = true;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16.0),
      children: [
        const Text(
          'Settings',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 20),
        SwitchListTile(
          title: const Text('Enable Notifications'),
          value: _notificationsEnabled,
          onChanged: (bool value) {
            setState(() {
              _notificationsEnabled = value;
            });
          },
        ),
        SwitchListTile(
          title: const Text('Dark Mode'),
          value: widget.isDarkMode,
          onChanged: (bool value) {
            widget.toggleDarkMode();
          },
        ),
        ListTile(
          title: const Text('About'),
          trailing: const Icon(Icons.arrow_forward),
          onTap: () {
            showDialog(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('About'),
                content: const Text('Musical Instruments Scanner v1.0\nDeveloped with Flutter.'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('OK'),
                  ),
                ],
              ),
            );
          },
        ),
        ListTile(
          title: const Text('Privacy Policy'),
          trailing: const Icon(Icons.arrow_forward),
          onTap: () {
            // Navigate to privacy policy page or show dialog
          },
        ),
      ],
    );
  }
}