import 'dart:convert';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_mag_sender/constant.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:uuid/uuid.dart';
import 'dart:math';
import 'package:fftea/fftea.dart';
import 'package:mic_stream/mic_stream.dart';
import 'dart:typed_data';
import 'dart:async';
import 'dart:math' as math;
import 'package:mqtt_client/mqtt_client.dart';
import 'package:statistics/statistics.dart';

class MagTaskHandler extends TaskHandler {
  MqttServerClient mqttServerClient = MqttServerClient.withPort(
      MQTT_SERVER, 'HD_HYUNDAI_PASS_${Uuid().v4()}', MQTT_PORT);

  int MAG_SAMPLE_RATE = 100;
  int MAG_WINDOW_SIZE = 100;

  int SOUND_SAMPLE_RATE = 44100;

  double MAINTENANCE_TIME = 5;

  int identifier = -1;

  double magDominantFrequency = 0;
  double soundDominantFrequency = 0;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onReceiveData(Object data) {
    final response = jsonDecode(data as String);

    if (response['operation'] == 'start') {
      identifier = response['data']['identifier'];

      _startMagnetometer();
    }

    if (response['operation'] == 'stop') {}
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) {
    throw UnimplementedError();
  }

  List<double> emfList = [];
  void _startMagnetometer() async {
    mqttServerClient.autoReconnect = true;
    await mqttServerClient.connect();

    List<double> over50Mag = [];
    double dominantMagnitude = 0;
    magDominantFrequency = 0;

    magnetometerEventStream(
      samplingPeriod: Duration(milliseconds: 8),
    ).listen((event) async {
      var magnetometerEvent = event;
      var mX = magnetometerEvent.x;
      var mY = magnetometerEvent.y;
      var mZ = magnetometerEvent.z;
      var emf = sqrt(mX * mX + mY * mY + mZ * mZ);
      emfList.add(emf);

      if (emfList.length >= 100) {
        final fft = FFT(emfList.length);
        final freq = fft.realFft(emfList);

        final deltaFrequency = MAG_SAMPLE_RATE / emfList.length;
        final magnitudes = freq.magnitudes();

        for (int i = 0; i < emfList.length ~/ 2; i++) {
          double frequency = i * deltaFrequency;
          double magnitude = magnitudes[i];

          if (frequency > 50) {
            over50Mag.add(magnitude);
          }

          if ((frequency > 50) && (magnitude > dominantMagnitude)) {
            dominantMagnitude = magnitude;
            magDominantFrequency = frequency;
          }
        }

        if (10 < over50Mag.standardDeviation &&
            over50Mag.standardDeviation < 50) {
          if (magDominantFrequency == 60) {
            bool hasMicTurned = await _turnOnMic();
            if (hasMicTurned) {
              Timer(Duration(seconds: 3), () async {
                await _turnOffMic();
              });
            }
          }
        }

        final builder = MqttClientPayloadBuilder();
        builder.addString(jsonEncode({
          "USER_ID": identifier,
          "EMF_DATA": emf.toString(),
          "DATETIME": event.timestamp.toIso8601String(),
          "MAG_DOMINANT_FREQUENCY": magDominantFrequency,
          "MAG_DOMINANT_MAGNITUDE": dominantMagnitude,
        }));
        mqttServerClient.publishMessage(
            'hhi/$identifier/data/emf', MqttQos.atMostOnce, builder.payload!);

        dominantMagnitude = 0;
        emfList = emfList.sublist(25);
      }

      FlutterForegroundTask.sendDataToMain(jsonEncode({
        'data': {
          'mag_status': 'on',
          'mag_dominant_frequency': magDominantFrequency,
          'mag_dominant_magnitude': dominantMagnitude,
          'mic_status': soundSubscription != null ? 'on' : 'off',
          'sound_dominant_frequency': soundDominantFrequency,
        }
      }));
    });
  }

  Stream<Uint8List>? soundStream;
  StreamSubscription<Uint8List>? soundSubscription;

  final DB_THRESHOLD = 100;
  final FREQUENCY_THRESHOLD = 17000;
  Future<bool> _turnOnMic() async {
    if (soundSubscription != null) {
      return false;
    }

    soundStream = MicStream.microphone(
      audioSource: AudioSource.DEFAULT,
      sampleRate: SOUND_SAMPLE_RATE,
      channelConfig: ChannelConfig.CHANNEL_IN_MONO,
      audioFormat: AudioFormat.ENCODING_PCM_16BIT,
    );

    soundSubscription = soundStream!.listen(_micListener);
    SOUND_SAMPLE_RATE = await MicStream.sampleRate;
    return true;
  }

  Future<void> _turnOffMic() async {
    await soundSubscription!.cancel();
    soundSubscription = null;
    soundStream = null;

    soundDominantFrequency = -1;
  }

  void _micListener(Uint8List samples) {
    final x = List<double>.filled(samples.length ~/ 2, 0);
    for (int i = 0; i < x.length; i++) {
      int sampleValue =
          (samples[i * 2] & 0xFF) | ((samples[i * 2 + 1] & 0xFF) << 8);
      if (sampleValue >= 32768) sampleValue -= 65536;
      x[i] = sampleValue.toDouble();
    }

    final fft = FFT(x.length);
    final freq = fft.realFft(x);

    final deltaFrequency = SOUND_SAMPLE_RATE / x.length;
    final magnitudes = freq.magnitudes();

    List<Map<String, double>> ultrasonicData = [];
    soundDominantFrequency = -1;
    double dominantFrequencyMag = -1;

    for (int i = 0; i < x.length ~/ 2; i++) {
      double frequency = (i * deltaFrequency);
      double magnitude = magnitudes[i].abs();
      double db = 20 * math.log(magnitude) / math.ln10;

      if (db > DB_THRESHOLD && frequency > FREQUENCY_THRESHOLD) {
        ultrasonicData
            .add({"FREQUENCY": frequency, "MAGNITUDE": magnitude, "DB": db});

        if (magnitude > dominantFrequencyMag) {
          dominantFrequencyMag = magnitude;
          soundDominantFrequency = frequency;
        }
      }
    }

    ultrasonicData.sort((a, b) => a["FREQUENCY"]!.compareTo(b["FREQUENCY"]!));
    var builder = MqttClientPayloadBuilder();
    builder.addString(jsonEncode({
      "FREQUENCY": ultrasonicData,
      "DOMINANT": soundDominantFrequency,
      "USER_ID": identifier,
      "DATETIME": DateTime.now().toIso8601String()
    }));
    if (ultrasonicData.isNotEmpty) {
      mqttServerClient.publishMessage('hhi/$identifier/data/ultrasonic',
          MqttQos.atMostOnce, builder.payload!);
    }
    ultrasonicData.clear();
  }
}
