import 'dart:async';
import 'package:flutter/material.dart';
import 'package:record/record.dart';

void main() => runApp(const SubtitleApp());

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
  final _recorder = AudioRecorder();
  Timer? _timer;

  bool listening = false;
  double level = 0.0; // 0~1

  String original = '（等待识别…）';
  String translated = '（等待翻译…）';

  @override
  void dispose() {
    _timer?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> start() async {
    final ok = await _recorder.hasPermission();
    if (!ok) {
      setState(() => original = '麦克风权限未授予（请到系统设置里允许）');
      return;
    }

    // 为了读取 amplitude，这里先录到临时文件（后面接实时识别会换成 PCM 流方案）
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: 'temp.wav',
    );

    setState(() {
      listening = true;
      original = '正在监听麦克风…（说话看看音量条是否跳动）';
    });

    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) async {
      final amp = await _recorder.getAmplitude();
      final db = amp.current; // dBFS, 常见范围 [-60, 0]
      final mapped = ((db + 60) / 60).clamp(0.0, 1.0);
      if (mounted) setState(() => level = mapped);
    });
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await _recorder.stop();
    setState(() {
      listening = false;
      level = 0.0;
      original = '已停止监听';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Realtime Subtitle Translator')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _SubtitleCard(title: 'Original', text: original),
            const SizedBox(height: 12),
            _SubtitleCard(title: 'Localized Translation', text: translated),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Mic Level'),
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: LinearProgressIndicator(value: level, minHeight: 14),
                      ),
                      const SizedBox(height: 6),
                      Text('level: ${level.toStringAsFixed(2)}'),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: listening ? null : start,
                  child: const Text('Start'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: listening ? stop : null,
                  child: const Text('Stop'),
                ),
              ],
            ),
            const SizedBox(height: 16),
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
