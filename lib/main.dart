import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:tflite_flutter_helper/tflite_flutter_helper.dart';

void main() {
  runApp(const MyApp());
}

/* =======================
   APP ROOT
======================= */
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Musical Instrument Classifier',
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.teal,
      ),
      home: const MainPage(),
    );
  }
}

/* =======================
   INSTRUMENT MODEL
======================= */
class Instrument {
  final String name;
  final String description;
  final String image;

  const Instrument({
    required this.name,
    required this.description,
    required this.image,
  });
}

const instruments = [
  Instrument(
      name: "Guitar",
      description: "A string instrument played by strumming or plucking.",
      image: "assets/images/guitar.jpeg"),
  Instrument(
      name: "Piano",
      description: "A keyboard instrument producing sound via hammers.",
      image: "assets/images/piano.jpeg"),
  Instrument(
      name: "Violin",
      description: "A high-pitched bowed string instrument.",
      image: "assets/images/violin.jpg"),
  Instrument(
      name: "Cello",
      description: "A bowed string instrument with deep tones.",
      image: "assets/images/cello.jpeg"),
  Instrument(
      name: "Drums",
      description: "Percussion instruments played with sticks or hands.",
      image: "assets/images/drum.jpeg"),
  Instrument(
      name: "Trumpet",
      description: "A brass instrument with a bright sound.",
      image: "assets/images/trumpet.jpeg"),
  Instrument(
      name: "Flute",
      description: "A woodwind instrument played by blowing air.",
      image: "assets/images/flute.png"),
  Instrument(
      name: "Saxophone",
      description: "A woodwind instrument popular in jazz music.",
      image: "assets/images/saxophone.jpeg"),
  Instrument(
      name: "Harp",
      description: "A large string instrument played by plucking.",
      image: "assets/images/harp.jpeg"),
  Instrument(
      name: "Clarinet",
      description: "A single-reed woodwind instrument.",
      image: "assets/images/clarinet.jpeg"),
];

/* =======================
   MAIN PAGE (Bottom Nav)
======================= */
class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  int currentIndex = 0;

  final pages = const [
    HomePage(),
    ScanGridPage(),
    AnalyticsPage(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Musical Instrument Classifier'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              // Settings page later
            },
          ),
        ],
      ),
      body: pages[currentIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: currentIndex,
        onTap: (index) => setState(() => currentIndex = index),
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.home),
            label: 'Home',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.camera_alt),
            label: 'Scan',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.analytics),
            label: 'Analytics',
          ),
        ],
      ),
    );
  }
}

/* =======================
   HOME PAGE
======================= */
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Container(
          decoration: const BoxDecoration(
            image: DecorationImage(
              image: AssetImage('assets/images/instruments_bg.jpeg'),
              fit: BoxFit.cover,
            ),
          ),
        ),
        Container(color: Colors.black.withOpacity(0.45)),
        Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.9),
                borderRadius: BorderRadius.circular(16),
                boxShadow: const [
                  BoxShadow(
                      color: Colors.black26, blurRadius: 8, offset: Offset(0, 4))
                ],
              ),
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Welcome to\nMusical Instrument Classifier',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                  SizedBox(height: 12),
                  Text(
                    'Scan musical instruments and identify them instantly',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 16),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/* =======================
   SCAN GRID PAGE
======================= */
class ScanGridPage extends StatelessWidget {
  const ScanGridPage({super.key});

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: instruments.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 0.85,
      ),
      itemBuilder: (_, i) {
        final inst = instruments[i];
        return GestureDetector(
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ScanDetailPage(instrument: inst),
              ),
            );
          },
          child: Card(
            child: Column(
              children: [
                Expanded(
                  child: Image.asset(inst.image, fit: BoxFit.cover),
                ),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    inst.name,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/* =======================
   SCAN DETAIL PAGE (TFLITE INTEGRATED)
======================= */
class ScanDetailPage extends StatefulWidget {
  final Instrument instrument;
  const ScanDetailPage({super.key, required this.instrument});

  @override
  State<ScanDetailPage> createState() => _ScanDetailPageState();
}

class _ScanDetailPageState extends State<ScanDetailPage> {
  File? selectedImage;
  bool isLoading = false;
  String prediction = '';
  double accuracy = 0.0;

  final ImagePicker picker = ImagePicker();
  Interpreter? interpreter;
  List<String> labels = [];

  @override
  void initState() {
    super.initState();
    loadModel();
  }

  Future<void> loadModel() async {
    try {
      interpreter = await Interpreter.fromAsset('model.tflite'); // your model file
      // Load labels if you have a labels.txt file in assets
      final labelsData = await DefaultAssetBundle.of(context)
          .loadString('assets/labels.txt');
      labels = labelsData.split('\n');
    } catch (e) {
      print('Error loading model: $e');
    }
  }

  Future<void> pickImage(ImageSource source) async {
    final file = await picker.pickImage(source: source);
    if (file == null) return;

    setState(() {
      selectedImage = File(file.path);
      isLoading = true;
      prediction = '';
      accuracy = 0.0;
    });

    await Future.delayed(const Duration(milliseconds: 500)); // small delay

    if (interpreter != null) {
      await runModel(File(file.path));
    }

    setState(() {
      isLoading = false;
    });
  }

  Future<void> runModel(File imageFile) async {
    // Preprocess image
    var inputImage = ImageProcessorBuilder()
        .add(ResizeOp(224, 224, ResizeMethod.BILINEAR))
        .build()
        .process(
          TensorImage.fromFile(imageFile),
        );

    TensorBuffer outputBuffer = TensorBufferFloat([1, labels.length]);

    interpreter!.run(inputImage.buffer, outputBuffer.buffer);

    // Find highest probability
    TensorLabel tensorLabel = TensorLabel.fromList(labels, outputBuffer);
    Map<String, double> labeledProb = tensorLabel.getMapWithFloatValue();
    var sorted = labeledProb.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    setState(() {
      prediction = sorted.first.key;
      accuracy = sorted.first.value * 100;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.instrument.name)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text(
              widget.instrument.description,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 16),
            Container(
              height: 220,
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).colorScheme.primary),
              ),
              child: selectedImage == null
                  ? Image.asset(widget.instrument.image, fit: BoxFit.cover)
                  : Image.file(selectedImage!, fit: BoxFit.cover),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton.icon(
                  icon: const Icon(Icons.camera),
                  label: const Text('Camera'),
                  onPressed: () => pickImage(ImageSource.camera),
                ),
                ElevatedButton.icon(
                  icon: const Icon(Icons.photo),
                  label: const Text('Gallery'),
                  onPressed: () => pickImage(ImageSource.gallery),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (isLoading) ...[
              const CircularProgressIndicator(),
              const SizedBox(height: 12),
              const Text('Predicting...'),
            ] else if (selectedImage != null) ...[
              Text(
                'Prediction: $prediction',
                style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.green),
              ),
              const SizedBox(height: 8),
              Text(
                'Accuracy: ${accuracy.toStringAsFixed(1)}%',
                style: const TextStyle(fontSize: 16),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/* =======================
   ANALYTICS PAGE
======================= */
class AnalyticsPage extends StatelessWidget {
  const AnalyticsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text(
        'Analytics Coming Soon',
        style: TextStyle(fontSize: 18),
      ),
    );
  }
}
