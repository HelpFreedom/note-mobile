import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Превью видео в ленте: автоплей без звука в цикле. Тап → полный экран со звуком.
class VideoView extends StatefulWidget {
  final File file;
  const VideoView(this.file, {super.key});

  @override
  State<VideoView> createState() => _VideoViewState();
}

class _VideoViewState extends State<VideoView> {
  VideoPlayerController? _c;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    if (!await widget.file.exists()) return;
    final c = VideoPlayerController.file(widget.file);
    try {
      await c.initialize();
      await c.setVolume(0);
      await c.setLooping(true);
      await c.play();
      if (mounted) {
        setState(() => _c = c);
      } else {
        await c.dispose();
      }
    } catch (_) {
      await c.dispose();
    }
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (c == null || !c.value.isInitialized) {
      return Container(
        height: 180,
        decoration: BoxDecoration(
          color: Colors.black26,
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Center(child: Icon(Icons.movie, color: Colors.white54, size: 40)),
      );
    }
    // фикс-высота 180 (как у плейсхолдера) + cover: высота НЕ меняется при инициализации
    // контроллера → нет рывков прокрутки. Полный кадр (с пропорциями) — по тапу.
    return GestureDetector(
      onTap: () => Navigator.push(context,
          MaterialPageRoute(builder: (_) => _FullscreenVideo(widget.file))),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          height: 180,
          width: double.infinity,
          child: Stack(
            alignment: Alignment.center,
            fit: StackFit.expand,
            children: [
              FittedBox(
                fit: BoxFit.cover,
                clipBehavior: Clip.hardEdge,
                child: SizedBox(
                  width: c.value.size.width,
                  height: c.value.size.height,
                  child: VideoPlayer(c),
                ),
              ),
              const Icon(Icons.play_circle_outline, color: Colors.white70, size: 48),
            ],
          ),
        ),
      ),
    );
  }
}

class _FullscreenVideo extends StatefulWidget {
  final File file;
  const _FullscreenVideo(this.file);

  @override
  State<_FullscreenVideo> createState() => _FullscreenVideoState();
}

class _FullscreenVideoState extends State<_FullscreenVideo> {
  VideoPlayerController? _c;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final c = VideoPlayerController.file(widget.file);
    try {
      await c.initialize();
      await c.setLooping(true);
      await c.play();
      if (mounted) {
        setState(() => _c = c);
      } else {
        await c.dispose();
      }
    } catch (_) {
      await c.dispose();
    }
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
      body: Center(
        child: c == null || !c.value.isInitialized
            ? const CircularProgressIndicator()
            : GestureDetector(
                onTap: () => setState(
                    () => c.value.isPlaying ? c.pause() : c.play()),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    AspectRatio(aspectRatio: c.value.aspectRatio, child: VideoPlayer(c)),
                    VideoProgressIndicator(c, allowScrubbing: true),
                  ],
                ),
              ),
      ),
    );
  }
}
