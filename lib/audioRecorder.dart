import 'dart:io';

import 'package:dio/dio.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
class AudioRecorder {
  static final recorder = Record();
  static String filePath = '';

  static Future<void> recordAudio(String fileName) async {
    final directory = await getApplicationDocumentsDirectory();
    final path = '${directory.path}/$fileName.wav';
    filePath = path;
      await recorder.start(
      path: path,
      encoder: AudioEncoder.wav,      // WAV 포맷 지정
      bitRate: 128000,                // 선택 비트레이트
      samplingRate: 44100,
    );
  }

  static Future<void> stopAudio() async {
    await recorder.stop();

    final dio = Dio();
    await dio.post(
      'http://legend.flexing.ai:8080/audio/wav',
      data: FormData.fromMap({
        'file': await MultipartFile.fromFile(filePath),
      }),
    );

    await File(filePath).delete();
    filePath = '';
  }
}
