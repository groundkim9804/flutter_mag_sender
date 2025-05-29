import 'dart:typed_data';

class TimeData {
  final double time;
  final double data;

  TimeData(this.time, this.data);
}

class UltrasonicHandler {
  static void demodulateSound(Uint8List samples) {
    final x = List<double>.filled(samples.length ~/ 2, 0);
    for (int i = 0; i < x.length; i++) {
      int sampleValue =
          (samples[i * 2] & 0xFF) | ((samples[i * 2 + 1] & 0xFF) << 8);
      if (sampleValue >= 32768) sampleValue -= 65536;
      x[i] = sampleValue.toDouble();
    }

    final transformedSound = transformSound(x);

    
  }

  static List<TimeData> transformSound(List<double> x)  {
    final fs = 44100;
    final dt = 1 / fs;
    final numSamples = x.length;

    List<TimeData> timeDataList = [];
    for (int i = 0; i < numSamples; i++) {
      timeDataList.add(TimeData(i * dt, x[i]));
    }

    return timeDataList;
  }
}
