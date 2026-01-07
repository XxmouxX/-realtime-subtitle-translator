import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
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

enum PerfMode { fast, balanced, accurate }

class SubtitleHomePage extends StatefulWidget {
  const SubtitleHomePage({super.key});

  @override
  State<SubtitleHomePage> createState() => _SubtitleHomePageState();
}

class _SubtitleHomePageState extends State<SubtitleHomePage> {
  // ===== UI state =====
  String translated = '（等待翻译…）';
  double level = 0.0; // 0~1
  bool listening = false;

  // 语言：auto / en / ja
  String sttLang = 'auto';

  // 性能档位（默认 Balanced，面向大多数电脑）
  PerfMode perfMode = PerfMode.balanced;

  // ===== rolling subtitles =====
  final List<String> _lines = [];
  final ScrollController _scroll = ScrollController();
  String _lastAppended = '';

  // ===== audio =====
  final AudioRecorder _recorder = AudioRecorder();
  Timer? _meterTimer;

  // 切片
  Timer? _chunkTimer;
  bool _chunkWorking = false;

  String _langLabel(String v) {
    switch (v) {
      case 'en':
        return 'English';
      case 'ja':
        return 'Japanese';
      default:
        return 'Auto';
    }
  }

  String _perfLabel(PerfMode m) {
    switch (m) {
      case PerfMode.fast:
        return 'Fast';
      case PerfMode.accurate:
        return 'Accurate';
      case PerfMode.balanced:
      default:
        return 'Balanced';
    }
  }

  // 面向大多数电脑的参数解释：
  // - 准确率提升优先靠“更长切片”，而不是 bs 拉很高
  Duration get chunkDuration {
    switch (perfMode) {
      case PerfMode.fast:
        return const Duration(seconds: 5);
      case PerfMode.accurate:
        return const Duration(seconds: 8);
      case PerfMode.balanced:
      default:
        return const Duration(seconds: 6);
    }
  }

  String get beamSize {
    switch (perfMode) {
      case PerfMode.fast:
        return '1'; // greedy
      case PerfMode.accurate:
        return '5'; // 仍然不建议 8，给弱机留余地
      case PerfMode.balanced:
      default:
        return '5';
    }
  }

  // 对短片段噪声做一点过滤（不要太激进）
  bool _shouldAppend(String text) {
    final t = text.trim();
    if (t.isEmpty) return false;

    // fast 模式可以更激进过滤；balanced/accurate 稍放宽
    final minLen = (perfMode == PerfMode.fast) ? 8 : 4;
    if (t.length < minLen) return false;

    // 相邻完全重复则忽略
    if (t == _lastAppended) return false;

    return true;
  }

  @override
  void dispose() {
    _meterTimer?.cancel();
    _chunkTimer?.cancel();
    _scroll.dispose();
    _recorder.dispose();
    super.dispose();
  }

  // ===== whisper.cpp runner =====
  Future<String> _runWhisperCpp(String wavPath) async {
    final cwd = Directory.current.path;

    final exePath = p.normalize(p.join(cwd, r'..\..\scripts\whispercpp\bin\whisper-cli.exe'));
    final modelPath = p.normalize(p.join(cwd, r'..\..\scripts\whispercpp\models\ggml-base.bin'));

    if (!File(exePath).existsSync()) return '找不到 whisper-cli.exe：$exePath';
    if (!File(modelPath).existsSync()) return '找不到模型：$modelPath';
    if (!File(wavPath).existsSync()) return '';

    final outBase = p.withoutExtension(wavPath);

    final result = await Process.run(
      exePath,
      [
        '-m',
        modelPath,
        '-f',
        wavPath,
        '-l',
        sttLang,
        '-bs',
        beamSize,
        '-otxt',
        '-of',
        outBase,
      ],
      runInShell: true,
      workingDirectory: cwd,
    );

    if (result.exitCode != 0) {
      // 出错不直接刷屏，返回空让 UI 保持稳定（你也可以改成显示错误）
      return '';
    }

    final txtPath = '$outBase.txt';
    if (!File(txtPath).existsSync()) {
      final out = (result.stdout ?? '').toString().trim();
      return out;
    }

    final text = (await File(txtPath).readAsString()).trim();
    return text;
  }

  void _appendLine(String text) {
    final t = text.trim();
    if (!_shouldAppend(t)) return;

    setState(() {
      _lines.add(t);
      _lastAppended = t;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  Future<String> _startNewChunkRecording() async {
    final dir = Directory.systemTemp.path;
    final file = p.join(dir, 'rst_chunk_${DateTime.now().millisecondsSinceEpoch}.wav');

    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: file,
    );

    return file;
  }

  Future<void> _captureChunkAndTranscribe() async {
    if (!listening) return;
    if (_chunkWorking) return;
    _chunkWorking = true;

    try {
      // 1) 停止当前切片录音
      final wavPath = await _recorder.stop();

      // 2) 立刻开始下一切片录音（减少间隙）
      if (listening) {
        await _startNewChunkRecording();
      }

      if (wavPath == null || wavPath.isEmpty) return;

      // 3) 离线识别
      final text = await _runWhisperCpp(wavPath);

      // 4) 追加字幕
      _appendLine(text);

      // 5) 清理临时文件（wav + txt）
      try {
        final base = p.withoutExtension(wavPath);
        final txt = '$base.txt';
        if (File(wavPath).existsSync()) File(wavPath).deleteSync();
        if (File(txt).existsSync()) File(txt).deleteSync();
      } catch (_) {}
    } finally {
      _chunkWorking = false;
    }
  }

  Future<void> start() async {
    final ok = await _recorder.hasPermission();
    if (!ok) {
      _appendLine('（麦克风权限未授予）');
      return;
    }

    setState(() {
      listening = true;
      level = 0.0;
      _lines.clear();
      _lastAppended = '';
    });

    _appendLine(
      '（Start：${_langLabel(sttLang)} | ${_perfLabel(perfMode)} '
      '| chunk=${chunkDuration.inSeconds}s bs=$beamSize）',
    );

    await _startNewChunkRecording();

    // 音量条
    _meterTimer?.cancel();
    _meterTimer = Timer.periodic(const Duration(milliseconds: 100), (_) async {
      if (!listening) return;
      final amp = await _recorder.getAmplitude();
      final db = amp.current; // [-60,0]
      final mapped = ((db + 60) / 60).clamp(0.0, 1.0);
      if (mounted) setState(() => level = mapped);
    });

    // 切片识别
    _chunkTimer?.cancel();
    _chunkTimer = Timer.periodic(chunkDuration, (_) async {
      await _captureChunkAndTranscribe();
    });
  }

  Future<void> stop() async {
    _chunkTimer?.cancel();
    _chunkTimer = null;

    _meterTimer?.cancel();
    _meterTimer = null;

    setState(() {
      listening = false;
      level = 0.0;
    });

    // 补最后一段
    final wavPath = await _recorder.stop();
    if (wavPath != null && wavPath.isNotEmpty) {
      _appendLine('（Stop：补最后一段…）');
      final text = await _runWhisperCpp(wavPath);
      _appendLine(text);

      try {
        final base = p.withoutExtension(wavPath);
        final txt = '$base.txt';
        if (File(wavPath).existsSync()) File(wavPath).deleteSync();
        if (File(txt).existsSync()) File(txt).deleteSync();
      } catch (_) {}
    }

    _appendLine('（已停止）');
  }

  @override
  Widget build(BuildContext context) {
    final originalText = _lines.isEmpty ? '（等待字幕…）' : _lines.join('\n');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Realtime Subtitle Translator'),
        actions: [
          // 语言下拉
          Center(
            child: Padding(
              padding: const EdgeInsets.only(right: 10),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: sttLang,
                  items: const [
                    DropdownMenuItem(value: 'auto', child: Text('Auto')),
                    DropdownMenuItem(value: 'en', child: Text('English')),
                    DropdownMenuItem(value: 'ja', child: Text('Japanese')),
                  ],
                  onChanged: listening
                      ? null
                      : (v) {
                          if (v == null) return;
                          setState(() => sttLang = v);
                        },
                ),
              ),
            ),
          ),

          // 性能档位下拉
          Center(
            child: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<PerfMode>(
                  value: perfMode,
                  items: const [
                    DropdownMenuItem(value: PerfMode.fast, child: Text('Fast')),
                    DropdownMenuItem(value: PerfMode.balanced, child: Text('Balanced')),
                    DropdownMenuItem(value: PerfMode.accurate, child: Text('Accurate')),
                  ],
                  onChanged: listening
                      ? null
                      : (v) {
                          if (v == null) return;
                          setState(() => perfMode = v);
                        },
                ),
              ),
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Original（滚动显示）
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.black12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Original (rolling)', style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 240,
                    child: SingleChildScrollView(
                      controller: _scroll,
                      child: SelectableText(
                        originalText,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),

            // Translation（占位）
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.black12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Localized Translation', style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 8),
                  SelectableText(translated, style: Theme.of(context).textTheme.titleMedium),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // 音量条 + 控制
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

            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '当前：${_langLabel(sttLang)} | ${_perfLabel(perfMode)} '
                '(chunk=${chunkDuration.inSeconds}s, bs=$beamSize)',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
