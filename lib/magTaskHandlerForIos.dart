import 'dart:convert';
import 'dart:ffi';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:uuid/uuid.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:flutter_mag_sender/constant.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:fftea/fftea.dart';
import 'dart:math';
import 'dart:math' as math;
import 'dart:async';
import 'dart:typed_data';
import 'package:statistics/statistics.dart';
import 'package:mic_stream/mic_stream.dart';

class MagTaskHandlerForIos {
  int identifier = -1;

  MagTaskHandlerForIos(this.identifier);

  MqttServerClient mqttServerClient = MqttServerClient.withPort(
      MQTT_SERVER, 'HD_HYUNDAI_PASS_${Uuid().v4()}', MQTT_PORT);

  StreamController<String> channelMessageController =
      StreamController<String>();

  StreamController<List<Map<double, double>>>
      frequencyMagnitudeStreamController =
      StreamController<List<Map<double, double>>>();

  int intervalMilliseconds = 10;
  int MAG_SAMPLE_RATE = 125;
  int MAG_WINDOW_SUBLIST_SIZE = 1;

  int DOM_MAG_THRESHOLD = 30;

  int SOUND_SAMPLE_RATE = 44100;

  int OVER_10_MEAN_THRESHOLD = 100;

  int MIC_DURATION = 3;

  double magDominantFrequency = 0;
  double soundDominantFrequency = 0;

  int micStartedTime = -1;

  List<int> intervalMillisecondsList = [];
  Future<void> setIntervalMilliseconds() async {
    int startTime = DateTime.now().millisecondsSinceEpoch;
    var eventStream = magnetometerEventStream(
      samplingPeriod: Duration(milliseconds: 0),
    );
    var subscription = eventStream.listen((event) {
      int time = event.timestamp.millisecondsSinceEpoch;
      intervalMilliseconds = time - startTime;
      startTime = time;
      intervalMillisecondsList.add(intervalMilliseconds);
    });

    await Future.delayed(Duration(seconds: 2), () async {
      intervalMilliseconds = intervalMillisecondsList.mean.round();

      if (intervalMilliseconds < 10) {
        DOM_MAG_THRESHOLD = 15;
      }

      await subscription.cancel();
    });
  }

  List<double> emfList = [];
  Future<void> startMagnetometer() async {
    mqttServerClient.autoReconnect = true;
    await mqttServerClient.connect();

    mqttServerClient.subscribe('hhi/settings/#', MqttQos.atMostOnce);
    // on message
    mqttServerClient.updates!
        .listen((List<MqttReceivedMessage<MqttMessage>> c) {
      final recMess = c[0].payload as MqttPublishMessage;

      Uint8List messageBytes = Uint8List.fromList(recMess.payload.message);
      String message = utf8.decode(messageBytes);

      final jMessage = jsonDecode(message);

      String topicName = recMess.variableHeader!.topicName;

      if (topicName == 'hhi/settings/dom_mag_threshold') {
        var target = jMessage['target'];

        if (target == null) {
          DOM_MAG_THRESHOLD = jMessage['DOM_MAG_THRESHOLD'];
        } else {
          if (intervalMilliseconds == target) {
            DOM_MAG_THRESHOLD = jMessage['DOM_MAG_THRESHOLD'];
          }
        }
      }

      if (topicName == 'hhi/settings/mic_duration') {
        MIC_DURATION = jMessage['MIC_DURATION'];
      }

      if (topicName == 'hhi/settings/db_threshold') {
        DB_THRESHOLD = jMessage['DB_THRESHOLD'];
      }

      if (topicName == 'hhi/settings/mic_duration') {
        MIC_DURATION = jMessage['MIC_DURATION'];
      }

      if (topicName == 'hhi/settings/mag_window_sublist_size') {
        MAG_WINDOW_SUBLIST_SIZE = jMessage['MAG_WINDOW_SUBLIST_SIZE'];
      }

      if (topicName == 'hhi/settings/over_10_mean_threshold') {
        OVER_10_MEAN_THRESHOLD = jMessage['OVER_10_MEAN_THRESHOLD'];
      }
    });

    List<double> mags = [];
    double dominantMagnitude = 0;
    magDominantFrequency = 0;

    await setIntervalMilliseconds();
    MAG_SAMPLE_RATE = 1000 ~/ intervalMilliseconds;

    magnetometerEventStream(
      samplingPeriod: Duration(milliseconds: intervalMilliseconds),
    ).listen((event) {
      var magnetometerEvent = event;
      var mX = magnetometerEvent.x;
      var mY = magnetometerEvent.y;
      var mZ = magnetometerEvent.z;
      var emf = sqrt(mX * mX + mY * mY + mZ * mZ);
      emfList.add(emf);

      if (emfList.length >= MAG_SAMPLE_RATE) {
        final fft = FFT(emfList.length);
        final freq = fft.realFft(emfList);

        final deltaFrequency = MAG_SAMPLE_RATE / emfList.length;
        final magnitudes = freq.magnitudes();

        List<Map<double, double>> frequencyMagnitudeList = [];
        for (int i = 0; i < emfList.length ~/ 2; i++) {
          double frequency = i * deltaFrequency;
          double magnitude = magnitudes[i];

          frequencyMagnitudeList.add({frequency: magnitude});
          if (frequency > 10) {
            mags.add(magnitude);
          }

          if ((frequency > 10) && (magnitude > dominantMagnitude)) {
            dominantMagnitude = magnitude;
            magDominantFrequency = frequency;
          }
        }

        frequencyMagnitudeStreamController.add(frequencyMagnitudeList);

        // validate
        var over10Mean = mags.mean;

        if (over10Mean < OVER_10_MEAN_THRESHOLD) {
          if ((dominantMagnitude - over10Mean) > DOM_MAG_THRESHOLD) {
            if ((19 < magDominantFrequency && magDominantFrequency < 21) ||
                (39 < magDominantFrequency && magDominantFrequency < 41) ||
                (59 < magDominantFrequency && magDominantFrequency < 61)) {
              final builderMicStart = MqttClientPayloadBuilder();
              builderMicStart.addString(jsonEncode({
                "USER_ID": identifier,
                "MAG_DOMINANT_FREQUENCY": magDominantFrequency,
                "MAG_DOMINANT_MAGNITUDE": dominantMagnitude,
                "OVER_10_MEAN": over10Mean,
                "DOM_MAG-MEAN": dominantMagnitude - over10Mean,
                "DOM_MAG_THRESHOLD": DOM_MAG_THRESHOLD,
                "DATETIME": DateTime.now().toIso8601String()
              }));
              mqttServerClient.publishMessage('hhi/$identifier/data/mic_start',
                  MqttQos.atMostOnce, builderMicStart.payload!);

              _startMic();
            }
          }
        }

        final builder = MqttClientPayloadBuilder();
        builder.addString(jsonEncode({
          "USER_ID": identifier,
          "MAG_DOMINANT_FREQUENCY": magDominantFrequency,
          "MAG_DOMINANT_MAGNITUDE": dominantMagnitude,
          "OVER_10_MEAN": over10Mean,
          "DOM_MAG-MEAN": dominantMagnitude - over10Mean,
          "DOM_MAG_THRESHOLD": DOM_MAG_THRESHOLD,
          "DB_THRESHOLD": DB_THRESHOLD,
          "MIC_DURATION": MIC_DURATION,
          "MAG_WINDOW_SUBLIST_SIZE": MAG_WINDOW_SUBLIST_SIZE,
          "OVER_10_MEAN_THRESHOLD": OVER_10_MEAN_THRESHOLD,
          "DATETIME": DateTime.now().toIso8601String()
        }));
        mqttServerClient.publishMessage('hhi/$identifier/data/dominant_emf',
            MqttQos.atMostOnce, builder.payload!);

        channelMessageController.add(jsonEncode({
          'data': {
            'mag_status': 'on',
            'mag_dominant_frequency': magDominantFrequency,
            "mag_dominant_magnitude": dominantMagnitude,
            'mic_status': soundSubscription != null ? 'on' : 'off',
            'sound_dominant_frequency': soundDominantFrequency,
            'interval_milliseconds': intervalMilliseconds,
          }
        }));

        mags.clear();
        dominantMagnitude = 0;
        emfList = emfList.sublist(MAG_WINDOW_SUBLIST_SIZE);
      }

      final builder2 = MqttClientPayloadBuilder();
      builder2.addString(jsonEncode({
        "USER_ID": identifier,
        "EMF_DATA": emf.toString(),
        "INTERVAL": intervalMilliseconds,
        "DATETIME": event.timestamp.toIso8601String(),
      }));
      mqttServerClient.publishMessage(
          'hhi/$identifier/data/emf', MqttQos.atMostOnce, builder2.payload!);

      final mic_builder = MqttClientPayloadBuilder();
      var micStatus = {
        "MIC": soundSubscription != null ? true : false,
        "DATETIME": DateTime.now().toIso8601String()
      };
      mic_builder.addString(jsonEncode(micStatus));
      mqttServerClient.publishMessage('hhi/$identifier/data/mic_status',
          MqttQos.atMostOnce, mic_builder.payload!);
    });
  }

  Stream<Uint8List>? soundStream;
  StreamSubscription<Uint8List>? soundSubscription;

  int DB_THRESHOLD = 100;
  int FREQUENCY_THRESHOLD = 17000;
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
    micStartedTime = -1;
  }

  void _micListener(Uint8List samples) {
    if (micStartedTime == -1) {
      micStartedTime = DateTime.now().millisecondsSinceEpoch;
      final builder = MqttClientPayloadBuilder();
      builder.addString(jsonEncode({
        "USER_ID": identifier,
        "MIC_STARTED_TIME": micStartedTime,
        "DATETIME": DateTime.now().toIso8601String()
      }));
      mqttServerClient.publishMessage('hhi/$identifier/data/mic_started',
          MqttQos.atMostOnce, builder.payload!);
    }
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
    double soundDominantFrequencyMag = -1;

    for (int i = 0; i < x.length ~/ 2; i++) {
      double frequency = (i * deltaFrequency);
      double magnitude = magnitudes[i].abs();
      double db = 20 * math.log(magnitude) / math.ln10;

      if (db > DB_THRESHOLD && frequency > FREQUENCY_THRESHOLD) {
        ultrasonicData
            .add({"FREQUENCY": frequency, "MAGNITUDE": magnitude, "DB": db});

        if (magnitude > soundDominantFrequencyMag) {
          soundDominantFrequencyMag = magnitude;
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

  Future<void> _startMic() async {
    bool hasMicTurned = await _turnOnMic();
    if (hasMicTurned) {
      Timer(Duration(seconds: MIC_DURATION), () async {
        await _turnOffMic();
      });
    }
  }
}
