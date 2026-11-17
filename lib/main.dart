import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:html_unescape/html_unescape.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_options.dart';

const triviaUrl =
    'https://opentdb.com/api.php?amount=10&category=9&difficulty=easy&type=multiple';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const QuizApp());
}

class QuizApp extends StatelessWidget {
  const QuizApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ICA16 Cloud Quiz',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }

          if (snapshot.hasError) {
            return Scaffold(
              body: Center(
                child: Text('Authentication error: ${snapshot.error}'),
              ),
            );
          }

          final user = snapshot.data;
          if (user == null) return const LoginScreen();

          return QuizScreen(key: ValueKey(user.uid), user: user);
        },
      ),
    );
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();

  bool busy = false;
  String error = '';

  Future<void> signIn() async {
    if (busy) return;

    setState(() {
      busy = true;
      error = '';
    });

    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: emailController.text.trim(),
        password: passwordController.text,
      );
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        setState(() {
          error = 'Sign-in failed: ${e.code}';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = 'Sign-in failed: $e';
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ICA16 Cloud Quiz')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 450),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cloud_done, size: 70, color: Colors.indigo),
                const SizedBox(height: 16),
                const Text(
                  'General Knowledge Quiz',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                const Text('Sign in using your Firebase test account.'),
                const SizedBox(height: 24),
                TextField(
                  controller: emailController,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Password',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (error.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(error, style: const TextStyle(color: Colors.red)),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: busy ? null : signIn,
                  child: Text(busy ? 'Signing in...' : 'Sign In'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class QuizQuestion {
  final String question;
  final String correct;
  final List<String> choices;

  const QuizQuestion({
    required this.question,
    required this.correct,
    required this.choices,
  });
}

class QuizScreen extends StatefulWidget {
  final User user;

  const QuizScreen({super.key, required this.user});

  @override
  State<QuizScreen> createState() => _QuizScreenState();
}

class _QuizScreenState extends State<QuizScreen> {
  final firestore = FirebaseFirestore.instance;
  final decoder = HtmlUnescape();

  List<QuizQuestion> questions = [];
  List<String?> answers = [];

  String state = 'loading';
  String message = '';
  String? roundId;

  int questionIndex = 0;
  int score = 0;

  bool busy = false;
  DateTime? lastFetch;

  // Development test: simulate losing the acknowledgement
  // after a real transaction succeeds.
  bool simulateLostAcknowledgement = false;

  @override
  void initState() {
    super.initState();
    restoreOrLoad();
  }

  String get recoveryKey => 'ica16_pending_${widget.user.uid}';

  Future<void> saveRecovery() async {
    if (roundId == null ||
        questions.length != 10 ||
        answers.length != 10 ||
        answers.any((a) => a == null)) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      recoveryKey,
      jsonEncode({
        'roundId': roundId,
        'score': score,
        'questions': questions
            .map(
              (q) => {
                'question': q.question,
                'correct': q.correct,
                'choices': q.choices,
              },
            )
            .toList(),
        'answers': answers,
      }),
    );
  }

  Future<void> clearRecovery() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(recoveryKey);
  }

  Future<void> restoreOrLoad() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(recoveryKey);

      if (saved != null) {
        final data = jsonDecode(saved) as Map<String, dynamic>;
        final savedQuestions = (data['questions'] as List).map((item) {
          final q = item as Map<String, dynamic>;
          return QuizQuestion(
            question: q['question'] as String,
            correct: q['correct'] as String,
            choices: List<String>.from(q['choices'] as List),
          );
        }).toList();
        final savedAnswers = List<String?>.from(data['answers'] as List);
        final savedScore = data['score'] as int;
        final savedRoundId = data['roundId'] as String;

        if (savedQuestions.length == 10 &&
            savedAnswers.length == 10 &&
            savedAnswers.every((answer) => answer != null) &&
            savedScore >= 0 &&
            savedScore <= 10 &&
            savedRoundId.isNotEmpty) {
          if (!mounted) return;
          setState(() {
            questions = savedQuestions;
            answers = savedAnswers;
            score = savedScore;
            roundId = savedRoundId;
            questionIndex = 9;
            state = 'verificationUnavailable';
            message =
                'Previous completed round recovered. '
                'Check the server before retrying submission.';
          });
          return;
        }
      }
    } catch (e) {
      if (!mounted) return;
      changeState('requestError', 'Could not restore saved round: $e');
      return;
    }

    if (mounted) await loadQuestions();
  }

  DocumentReference<Map<String, dynamic>> get attemptRef {
    return firestore
        .collection('users')
        .doc(widget.user.uid)
        .collection('attempts')
        .doc(roundId!);
  }

  void changeState(String next, [String info = '']) {
    if (!mounted) return;
    setState(() {
      state = next;
      message = info;
    });
  }

  Future<void> loadQuestions() async {
    if (busy ||
        state == 'submitting' ||
        state == 'verifying' ||
        state == 'saveUnknown' ||
        state == 'verificationUnavailable') {
      return;
    }

    if (lastFetch != null &&
        DateTime.now().difference(lastFetch!) < const Duration(seconds: 5)) {
      changeState(
        'requestError',
        'Wait at least 5 seconds before fetching again.',
      );
      return;
    }

    busy = true;
    lastFetch = DateTime.now();
    changeState('loading');

    try {
      final response = await http
          .get(Uri.parse(triviaUrl))
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      final decoded = jsonDecode(response.body);

      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Invalid JSON object');
      }

      if (decoded['response_code'] != 0) {
        throw FormatException(
          'Trivia API response code: ${decoded['response_code']}',
        );
      }

      final results = decoded['results'];

      if (results is! List || results.length != 10) {
        throw const FormatException(
          'The API must return exactly 10 questions.',
        );
      }

      final loaded = <QuizQuestion>[];

      for (final item in results) {
        if (item is! Map<String, dynamic>) {
          throw const FormatException('Invalid question data.');
        }

        if (item['category'] != 'General Knowledge' ||
            item['difficulty'] != 'easy' ||
            item['type'] != 'multiple') {
          throw const FormatException(
            'Question category, difficulty, or type is incorrect.',
          );
        }

        final rawQuestion = item['question'];
        final rawCorrect = item['correct_answer'];
        final rawWrong = item['incorrect_answers'];

        if (rawQuestion is! String ||
            rawCorrect is! String ||
            rawWrong is! List ||
            rawWrong.length != 3 ||
            rawWrong.any((value) => value is! String)) {
          throw const FormatException('Invalid question fields.');
        }

        final question = decoder.convert(rawQuestion).trim();
        final correct = decoder.convert(rawCorrect).trim();

        final incorrect = rawWrong
            .map((value) => decoder.convert(value as String).trim())
            .toList();

        final choices = <String>[correct, ...incorrect];

        if (question.isEmpty ||
            choices.any((choice) => choice.isEmpty) ||
            choices.toSet().length != 4) {
          throw const FormatException(
            'Question contains empty or duplicate choices.',
          );
        }

        choices.shuffle();

        loaded.add(
          QuizQuestion(question: question, correct: correct, choices: choices),
        );
      }

      if (!mounted) return;

      setState(() {
        questions = loaded;
        answers = List<String?>.filled(10, null);
        questionIndex = 0;
        score = 0;
        roundId = firestore
            .collection('users')
            .doc(widget.user.uid)
            .collection('attempts')
            .doc()
            .id;
        state = 'playing';
        message = '';
      });
    } catch (e) {
      changeState('requestError', 'Could not load quiz: $e');
    } finally {
      busy = false;
    }
  }

  void chooseAnswer(String choice) {
    if (state != 'playing' || answers[questionIndex] != null) {
      return;
    }

    setState(() {
      answers[questionIndex] = choice;

      if (choice == questions[questionIndex].correct) {
        score++;
      }
    });
  }

  void nextQuestion() {
    if (state != 'playing' || answers[questionIndex] == null) {
      return;
    }

    setState(() {
      if (questionIndex < 9) {
        questionIndex++;
      } else {
        state = 'readyToSubmit';
      }
    });
  }

  bool matchesSavedData(Map<String, dynamic>? data) {
    if (data == null) return false;

    return data.length == 6 &&
        data['schemaVersion'] == 1 &&
        data['variant'] == 'A' &&
        data['categoryId'] == 9 &&
        data['questionCount'] == 10 &&
        data['correctCount'] == score;
  }

  Future<bool> verifyServerRecord() async {
    final snapshot = await attemptRef.get(
      const GetOptions(source: Source.server),
    );

    if (!snapshot.exists || snapshot.metadata.hasPendingWrites) {
      return false;
    }

    final data = snapshot.data();

    return matchesSavedData(data) && data!['submittedAt'] is Timestamp;
  }

  Future<void> submitScore() async {
    if (busy || roundId == null || state != 'readyToSubmit') {
      return;
    }

    busy = true;

    try {
      await saveRecovery();
    } catch (e) {
      busy = false;
      changeState('saveUnknown', 'Could not preserve the round: $e');
      return;
    }

    final expectedUid = widget.user.uid;
    final expectedRoundId = roundId;

    changeState('submitting');

    final payload = <String, dynamic>{
      'schemaVersion': 1,
      'variant': 'A',
      'categoryId': 9,
      'questionCount': 10,
      'correctCount': score,
      'submittedAt': FieldValue.serverTimestamp(),
    };

    try {
      await firestore.runTransaction((transaction) async {
        final existing = await transaction.get(attemptRef);

        if (existing.exists) {
          if (!matchesSavedData(existing.data())) {
            throw StateError('Round ID collision.');
          }
        } else {
          transaction.set(attemptRef, payload);
        }
      });

      if (!mounted ||
          FirebaseAuth.instance.currentUser?.uid != expectedUid ||
          roundId != expectedRoundId) {
        return;
      }

      if (simulateLostAcknowledgement) {
        changeState(
          'saveUnknown',
          'Test: acknowledgement lost after the transaction. '
              'Use Check Server to recover.',
        );
        return;
      }

      changeState('verifying');

      final verified = await verifyServerRecord();

      if (verified) {
        await clearRecovery();
      }

      changeState(
        verified ? 'cloudVerified' : 'verificationUnavailable',
        verified
            ? 'Saved and verified directly from Firestore.'
            : 'The server record could not be verified.',
      );
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') {
        changeState('permissionDenied', 'Permission denied.');
      } else if (e.code == 'unauthenticated') {
        changeState('authError', 'Authentication is required.');
      } else {
        changeState(
          'saveUnknown',
          'Save outcome is unknown (${e.code}). Check the server.',
        );
      }
    } catch (e) {
      changeState('saveUnknown', 'Save outcome is unknown: $e');
    } finally {
      busy = false;
    }
  }

  Future<void> checkServer() async {
    if (busy || roundId == null) return;

    busy = true;
    changeState('verifying');

    try {
      final verified = await verifyServerRecord();

      if (verified) {
        await clearRecovery();
      }

      changeState(
        verified ? 'cloudVerified' : 'saveUnknown',
        verified
            ? 'The original round was found and verified on the server.'
            : 'No matching saved record was found. '
                  'You may retry submission using the same round ID.',
      );
    } catch (e) {
      changeState(
        'verificationUnavailable',
        'Server verification is unavailable: $e',
      );
    } finally {
      busy = false;
    }
  }

  Future<void> retrySubmission() async {
    if (busy || roundId == null || state != 'saveUnknown') return;

    // Recheck the original ID before attempting another transaction.
    await checkServer();

    if (!mounted || state != 'saveUnknown') return;

    setState(() => state = 'readyToSubmit');
    await submitScore();
  }

  Future<void> signOut() async {
    if (busy ||
        state == 'submitting' ||
        state == 'verifying' ||
        state == 'saveUnknown' ||
        state == 'verificationUnavailable') {
      return;
    }

    await FirebaseAuth.instance.signOut();
  }

  Widget buildQuestion() {
    final question = questions[questionIndex];
    final selected = answers[questionIndex];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LinearProgressIndicator(value: (questionIndex + 1) / 10),
        const SizedBox(height: 20),
        Text(
          'Question ${questionIndex + 1} of 10',
          style: const TextStyle(fontSize: 17),
        ),
        const SizedBox(height: 16),
        Text(
          question.question,
          style: const TextStyle(fontSize: 23, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 20),
        for (final choice in question.choices)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: OutlinedButton(
              onPressed: selected == null ? () => chooseAnswer(choice) : null,
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.all(16),
                backgroundColor: selected == null
                    ? Colors.white
                    : choice == question.correct
                    ? Colors.green.shade100
                    : choice == selected
                    ? Colors.red.shade100
                    : Colors.white,
              ),
              child: Text(choice),
            ),
          ),
        if (selected != null) ...[
          const SizedBox(height: 10),
          Text(
            selected == question.correct
                ? 'Correct!'
                : 'Incorrect. Correct answer: ${question.correct}',
            style: TextStyle(
              color: selected == question.correct
                  ? Colors.green.shade800
                  : Colors.red.shade800,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: nextQuestion,
            child: Text(
              questionIndex == 9 ? 'Review Results' : 'Next Question',
            ),
          ),
        ],
      ],
    );
  }

  Widget buildResults() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Final Score: $score / 10',
          style: const TextStyle(fontSize: 27, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 10),
        Text('Round ID: ${roundId ?? 'Not available'}'),
        const SizedBox(height: 12),
        for (int i = 0; i < questions.length; i++)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${i + 1}. ${questions[i].question}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  Text('Your answer: ${answers[i]}'),
                  Text('Correct answer: ${questions[i].correct}'),
                ],
              ),
            ),
          ),
        const SizedBox(height: 15),
        Text('Cloud status: $state'),
        if (message.isNotEmpty) ...[const SizedBox(height: 8), Text(message)],
        const SizedBox(height: 15),
        if (state == 'readyToSubmit')
          FilledButton(
            onPressed: busy ? null : submitScore,
            child: const Text('Submit Score to Cloud'),
          ),
        if (state == 'saveUnknown' || state == 'verificationUnavailable')
          FilledButton(
            onPressed: busy ? null : checkServer,
            child: const Text('Check Server'),
          ),
        if (state == 'saveUnknown')
          OutlinedButton(
            onPressed: busy ? null : retrySubmission,
            child: const Text('Retry Original Submission'),
          ),
        if (state == 'cloudVerified') ...[
          const Text(
            'Cloud Verified!',
            style: TextStyle(
              color: Colors.green,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: busy ? null : loadQuestions,
            child: const Text('Replay Quiz'),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ICA16 Cloud Quiz'),
        actions: [
          IconButton(
            tooltip: 'Sign Out',
            onPressed:
                busy ||
                    state == 'saveUnknown' ||
                    state == 'verificationUnavailable'
                ? null
                : signOut,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 650),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Builder(
              builder: (context) {
                if (state == 'loading') {
                  return const Center(
                    child: Column(
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 15),
                        Text('Loading questions...'),
                      ],
                    ),
                  );
                }

                if (state == 'requestError') {
                  return Column(
                    children: [
                      Text(message),
                      const SizedBox(height: 15),
                      FilledButton(
                        onPressed: busy ? null : loadQuestions,
                        child: const Text('Retry'),
                      ),
                    ],
                  );
                }

                if (state == 'playing') {
                  return buildQuestion();
                }

                return buildResults();
              },
            ),
          ),
        ),
      ),
    );
  }
}
