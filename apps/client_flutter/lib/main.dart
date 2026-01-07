import 'package:flutter/material.dart';

void main() {
  runApp(const SubtitleApp());
}

class SubtitleApp extends StatelessWidget {
  const SubtitleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Realtime Subtitle Translator',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true),
      home: const SubtitleHomePage(),
    );
  }
}

class SubtitleHomePage extends StatefulWidget {
  const SubtitleHomePage({super.key});

  @override
  State<SubtitleHomePage> createState() => _SubtitleHomePageState();
}

class _SubtitleHomePageState extends State<SubtitleHomePage> {
  // 先用假数据占位：后面接入语音识别/翻译时替换这里
  String original = 'Hello everyone, welcome to the demo.';
  String translated = '大家好，欢迎来到演示。';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Realtime Subtitle Translator'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _SubtitleCard(title: 'Original', text: original),
            const SizedBox(height: 12),
            _SubtitleCard(title: 'Localized Translation', text: translated),
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 12),
            TextField(
              decoration: const InputDecoration(
                labelText: '模拟原文输入（后面由语音识别填充）',
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => original = v),
            ),
            const SizedBox(height: 12),
            TextField(
              decoration: const InputDecoration(
                labelText: '模拟译文输入（后面由翻译引擎填充）',
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => translated = v),
            ),
          ],
        ),
      ),
    );
  }
}

class _SubtitleCard extends StatelessWidget {
  final String title;
  final String text;

  const _SubtitleCard({required this.title, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.black12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          SelectableText(
            text.isEmpty ? '（等待字幕…）' : text,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ],
      ),
    );
  }
}
// TEST: hot reload should pick this up