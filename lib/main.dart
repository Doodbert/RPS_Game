import 'dart:io';
import 'dart:math';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_arc_text/flutter_arc_text.dart';
import 'package:camera/camera.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tflite/tflite.dart';
import 'package:image/image.dart' as img;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RPS Game',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: const StartScreen(),
    );
  }
}

class StartScreen extends StatefulWidget {
  const StartScreen({super.key});
  @override
  _StartScreenState createState() => _StartScreenState();
}

class _StartScreenState extends State<StartScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    )..repeat(reverse: true);

    _animation = Tween<double>(begin: -0.05, end: 0.05).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.elasticIn,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.blueGrey,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedBuilder(
              animation: _animation,
              builder: (context, child) {
                return Transform(
                  transform: Matrix4.rotationZ(_animation.value * pi),
                  child: const ArcText(
                    radius: 140,
                    text: 'Rock Paper Scissors',
                    textStyle: TextStyle(
                      fontSize: 40.0,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      fontFamily: 'ComicSans',
                      shadows: [
                        Shadow(
                          offset: Offset(1.5, 1.5),
                          color: Colors.black,
                          blurRadius: 1.0,
                        ),
                        Shadow(
                          offset: Offset(1.5, -1.5),
                          color: Colors.black,
                          blurRadius: 1.0,
                        ),
                        Shadow(
                          offset: Offset(-1.5, 1.5),
                          color: Colors.black,
                          blurRadius: 1.0,
                        ),
                        Shadow(
                          offset: Offset(-1.5, -1.5),
                          color: Colors.black,
                          blurRadius: 1.0,
                        ),
                      ],
                    ),
                    startAngle: -pi / 2.5,
                    startAngleAlignment: StartAngleAlignment.start,
                    direction: Direction.clockwise,
                    placement: Placement.outside,
                  ),
                );
              },
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                shape: const CircleBorder(),
                padding: const EdgeInsets.all(40),
                textStyle: const TextStyle(fontSize: 20),
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
                elevation: 10,
                shadowColor: Colors.black.withOpacity(0.8),
              ),
              onPressed: () {
                Navigator.push(
                    context, MaterialPageRoute(builder: (_) => GameScreen()));
              },
              child: const Text('Start'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

class GameScreen extends StatefulWidget {
  @override
  _GameScreenState createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  late CameraController _cameraController;
  List<CameraDescription>? cameras;
  bool isCameraInitialized = false;
  bool isCameraRecording = false;
  bool isCountdown = false;
  bool isCalculating = false;
  int countdownValue = 3;
  String resultText = "";
  List<List<dynamic>> predictions = [];
  List<XFile> tempImagesList = [];
  String computerChoice = "";
  String userChoice = "";
  String gameResultText = "";

  @override
  void initState() {
    super.initState();
    _initializeCamera();
    _loadModel();
  }

  _loadModel() async {
    await Tflite.loadModel(
      model: "assets/rps_model2.tflite",
      labels: "assets/labels.txt",
    );
  }

  _initializeCamera() async {
    cameras = await availableCameras();
    _cameraController = CameraController(cameras![0], ResolutionPreset.medium);
    _cameraController.initialize().then((_) {
      if (!mounted) {
        return;
      }
      setState(() {
        isCameraInitialized = true;
      });
    });
  }

  _startGame() async {
    setState(() {
      isCountdown = true;
    });

    Timer.periodic(Duration(seconds: 1), (timer) {
      if (countdownValue == 0) {
        timer.cancel();
        _startCameraCapture();
      } else {
        setState(() {
          countdownValue--;
        });
      }
    });
  }

  _startCameraCapture() {
    int captureCount = 0;

    setState(() {
      isCameraRecording = true;
    });

    Timer.periodic(Duration(seconds: 2), (timer) async {
      if (!_cameraController.value.isInitialized) {
        print("Camera is not initialized yet");
        return;
      }

      if (captureCount >= 5) {
        timer.cancel();
        setState(() {
          isCameraRecording = false;
        });
        _evaluateAllTempImages();
      } else {
        captureCount++;
        XFile photo = await _cameraController.takePicture();
        tempImagesList.add(photo);
      }
    });
  }

  Future<void> _evaluatePhoto(XFile photo) async {
    // Bild laden
    img.Image? image = img.decodeImage(await photo.readAsBytes());
    if (image == null) {
      print('Failed to decode image.');
      return;
    }

    // Bild auf 180x180 skalieren
    img.Image resizedImage = img.copyResize(image, width: 180, height: 180);

    final tempDir = await getTemporaryDirectory();
    final tempFile = await File('${tempDir.path}/temp.jpg').create();
    await tempFile.writeAsBytes(img.encodeJpg(resizedImage));

    var output = await Tflite.runModelOnImage(
      path: tempFile.path,
      numResults: 3, // 3 Klassen Rock; Paper; Scissors
      threshold: 0.1,
      imageMean: 0.0,
      imageStd: 1.0,
    );

    await tempFile.delete();

    print("TFLite Output: $output");
    if (output != null) {
      predictions.add(output);
    }
  }

  _evaluateAllTempImages() async {
    for (var image in tempImagesList) {
      await _evaluatePhoto(image);
    }
    _calculateResult();
    tempImagesList.clear();
  }

  _calculateResult() {
    Map<String, double> summedPredictions = {
      'rock': 0,
      'paper': 0,
      'scissors': 0
    };

    //print(
    //    "-------------------------------------------------------------------");
    //print("predictions:");
    //print(predictions);
    //print(
    //    "-------------------------------------------------------------------");

    for (var predictionList in predictions) {
      for (var item in predictionList) {
        String fullLabel = item['label'];
        String labelName = fullLabel.split(' ')[1];

        if (labelName == "rock") {
          summedPredictions['rock'] =
              (summedPredictions['rock'] ?? 0) + item['confidence'];
        } else if (labelName == "paper") {
          summedPredictions['paper'] =
              (summedPredictions['paper'] ?? 0) + item['confidence'];
        } else if (labelName == "scissors") {
          summedPredictions['scissors'] =
              (summedPredictions['scissors'] ?? 0) + item['confidence'];
        }
      }
    }

    // Finde das Label mit der höchsten Summe
    var topPrediction =
        summedPredictions.entries.reduce((a, b) => a.value > b.value ? a : b);

    //print(summedPredictions);
    //print(topPrediction.key);

    setState(() {
      userChoice = topPrediction.key;
    });
    predictions.clear();
    _displayComputerChoiceAndResult();
  }

  _displayComputerChoiceAndResult() async {
    List<String> choices = ['rock', 'paper', 'scissors'];
    computerChoice = choices[Random().nextInt(3)];

    setState(() {
      gameResultText = "Warte...";
      isCalculating = true;
    });

    await Future.delayed(Duration(seconds: 6));

    if (computerChoice == userChoice) {
      gameResultText = "Unentschieden";
    } else if ((computerChoice == 'rock' && userChoice == 'scissors') ||
        (computerChoice == 'scissors' && userChoice == 'paper') ||
        (computerChoice == 'paper' && userChoice == 'rock')) {
      gameResultText = "Verloren";
    } else {
      gameResultText = "Gewonnen";
    }

    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: <Widget>[
          // Kamera Vorschau
          if (isCameraRecording)
            isCameraInitialized
                ? CameraPreview(_cameraController)
                : Center(child: CircularProgressIndicator()),

          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                if (isCountdown && !isCalculating && !isCameraRecording)
                  Text(countdownValue.toString(),
                      style: TextStyle(fontSize: 40)),
                if (!isCountdown && !isCalculating && gameResultText.isEmpty)
                  ElevatedButton(
                    onPressed: _startGame,
                    child: Text('Start Game'),
                  ),
                if (isCalculating && gameResultText == "Warte...")
                  Column(
                    children: [
                      Text('Der Computer hat $computerChoice gewählt.',
                          style: TextStyle(fontSize: 20)),
                      Text('Sie haben $userChoice gewählt.',
                          style: TextStyle(fontSize: 20))
                    ],
                  ),
                if (gameResultText != "Warte..." && gameResultText.isNotEmpty)
                  Text(gameResultText, style: TextStyle(fontSize: 40)),
                if (gameResultText == "Gewonnen" ||
                    gameResultText == "Verloren" ||
                    gameResultText == "Unentschieden")
                  ElevatedButton(
                    onPressed: () {
                      setState(() {
                        isCalculating = false;
                      });
                      Navigator.pop(context);
                    },
                    child: Text('Play Again'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _cameraController.dispose();
    Tflite.close();
    super.dispose();
  }
}
