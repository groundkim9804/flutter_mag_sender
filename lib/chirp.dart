import 'dart:convert';
import 'dart:io';
import 'dart:math';

class ChirpDecoder {
  final double f0 = 17000;
  final double f1 = 19000;
  final double bitDur = 0.010; // 10 ms
  final String preamble = '0101';
  final String sof = '1';
  final int poly = 0x13;
  final int minGapSym = 3;

  List<double> linspace(double start, double stop, int num) {
    var result = <double>[];
    double step = (stop - start) / num;
    for (int i = 0; i < num; i++) {
      result.add(start + step * i);
    }
    return result;
  }

  List<double> chirpSignal(List<double> t, double f0, double f1, double t1) {
    return t.map((ti) {
      return cos(2 * pi * (f0 * ti + (f1 - f0) * pow(ti, 2) / (2 * t1)));
    }).toList();
  }

  String crc4(String bits) {
    int reg = 0;
    for (var b in bits.split('')) {
      reg ^= (int.parse(b) << 3);
      reg = ((reg << 1) & 0x1F) ^ ((reg & 0x10) != 0 ? poly : 0);
    }
    return reg.toRadixString(2).padLeft(4, '0').substring(reg.toRadixString(2).length - 4);
  }

  List<List<double>> buildRefs(double fs) {
    int n = (fs * bitDur).round();
    var t = linspace(0, bitDur, n);
    var up = chirpSignal(t, f0, f1, bitDur);
    var dn = chirpSignal(t, f1, f0, bitDur);
    return [up, dn, List<double>.filled(n, 1)];
  }

  String corrBit(List<double> seg, List<double> up, List<double> dn) {
    if (seg.length != up.length) {
      seg = [...seg, ...List<double>.filled(up.length - seg.length, 0)];
    }
    double sumUp = 0, sumDn = 0;
    for (int i = 0; i < seg.length; i++) {
      sumUp += seg[i] * up[i];
      sumDn += seg[i] * dn[i];
    }
    return sumUp > sumDn ? '0' : '1';
  }

  Map<String, dynamic>? decodeFrame(List<double> rx, int start, List<double> up, List<double> dn, int n) {
    var bits = '';
    for (int i = 0; i < 24; i++) {
      bits += corrBit(rx.sublist(start + i * n, min(start + (i + 1) * n, rx.length)), up, dn);
    }
    if (bits.substring(0, 4) != preamble || bits[4] != sof) return null;
    int length = int.parse(bits.substring(5, 9), radix: 2);
    if (length > 15 || 9 + length + 4 > 24) return null;
    var payload = bits.substring(9, 9 + length);
    var crcOk = crc4(bits.substring(5, 9 + length)) == bits.substring(9 + length, 9 + length + 4);
    return {'payload': payload, 'crc_ok': crcOk};
  }

  Future<void> decodeCsv(String csvIn, {String csvOut = 'decoded_payloads.csv'}) async {
    var lines = await File(csvIn).readAsLines();
    var header = lines.first.split(',');
    var timeIdx = header.indexOf('Time');
    var dataIdx = header.indexOf('Data');

    var time = <double>[];
    var data = <double>[];
    for (var line in lines.skip(1)) {
      var parts = line.split(',');
      time.add(double.parse(parts[timeIdx]));
      data.add(double.parse(parts[dataIdx]));
    }

    double dt = (time[1] - time[0]);
    double fs = 1.0 / dt;
    var refs = buildRefs(fs);
    var up = refs[0];
    var dn = refs[1];
    int n = up.length;
    int gapSamples = (24 + minGapSym) * n;

    int idx = 0, frameNo = 0;
    var out = <Map<String, dynamic>>[];

    while (idx + 24 * n <= data.length) {
      var preBits = '';
      for (int i = 0; i < 4; i++) {
        preBits += corrBit(data.sublist(idx + i * n, min(idx + (i + 1) * n, data.length)), up, dn);
      }
      if (preBits == preamble) {
        var result = decodeFrame(data, idx, up, dn, n);
        if (result != null) {
          frameNo++;
          double tSec = time[idx];
          print('[${frameNo.toString().padLeft(2, '0')}] @$tSec s payload=${result['payload']} CRC=${result['crc_ok']}');
          out.add({'frame_no': frameNo, 'frame_sec': tSec, 'payload': result['payload'], 'crc_ok': result['crc_ok']});
          idx += gapSamples;
          continue;
        }
      }
      idx += (n / 4).floor();
    }

    var sink = File(csvOut).openWrite();
    sink.writeln('frame_no,frame_sec,payload,crc_ok');
    for (var row in out) {
      sink.writeln('${row['frame_no']},${row['frame_sec']},${row['payload']},${row['crc_ok']}');
    }
    await sink.close();
    print('★ 총 ${out.length}개 프레임 저장 → $csvOut');
  }
}

void main() async {
  var decoder = ChirpDecoder();
  await decoder.decodeCsv('tx_multi.csv');
}