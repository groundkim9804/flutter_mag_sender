import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_mag_sender/magTaskHandlerForIos.dart';
import 'package:flutter_mag_sender/magTaskHandler.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  WakelockPlus.enable();
  runApp(const MyApp());
}

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(MagTaskHandler());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HD 현대 PASS',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const MyHomePage(title: 'HD 현대 PASS'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  double currentEMF = 0;
  double magDominantFrequency = 0;
  double magDominantMagnitude = 0;
  double soundDominantFrequency = 0;
  int intervalMilliseconds = 0;
  List<double> emfList = [];
  List<FlSpot> spots = [];
  List<double> over50Mag = [];

  bool isMagOn = false;
  bool isMicOn = false;

  int identifier = -1;

  @override
  void initState() {
    super.initState();

    Permission.microphone.request().then((value) {
      _requestBatteryPermission();
    });

    // if (Platform.isAndroid) {
    //   FlutterForegroundTask.addTaskDataCallback(_onReceiveTaskData);
    // }
  }

  @override
  void dispose() {
    FlutterForegroundTask.removeTaskDataCallback(_onReceiveTaskData);

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          children: <Widget>[
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 100,
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: 'ID',
                    ),
                    keyboardType: TextInputType.number,
                    onChanged: (value) {
                      if (value.isEmpty) {
                        return;
                      }

                      identifier = int.parse(value);
                    },
                  ),
                ),
                ElevatedButton(
                  onPressed: () async {
                    if (identifier == -1) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('ID를 입력해주세요'),
                        ),
                      );
                      return;
                    }

                    if (Platform.isAndroid) {
                      _startMagForIos(identifier);

                      // _initService();
                      // await _startService();
                      // _startMag();
                    }

                    if (Platform.isIOS) {
                      _startMagForIos(identifier);
                    }

                    FocusManager.instance.primaryFocus?.unfocus();
                  },
                  child: Text('Start'),
                )
              ],
            ),
            Text(isMagOn ? 'Magnetometer On' : 'Magnetometer Off'),
            Text(isMicOn ? 'Mic On' : 'Mic Off'),
            Text(
                'Mag Dominant Frequency: ${magDominantFrequency.toStringAsFixed(2)}'),
            Text(
                'Mag Dominant Magnitude: ${magDominantMagnitude.toStringAsFixed(2)}'),
            Text(
                'Sound Dominant Frequency: ${soundDominantFrequency.toStringAsFixed(2)}'),
            Text('Interval Milliseconds: $intervalMilliseconds'),
            SizedBox(
              height: 500,
              child: LineChart(
                LineChartData(
                  minX: 5,
                  maxX: 80,
                  minY: 0,
                  maxY: spots.isNotEmpty &&
                          spots.map((e) => e.y).reduce((a, b) => max(a, b)) >
                              100
                      ? 1000
                      : 100,
                  lineBarsData: [
                    LineChartBarData(
                      spots: spots,
                    ),
                  ],
                ),
              ),
            )
          ],
        ),
      ),
    );
  }

  void _onReceiveTaskData(data) {
    final response = jsonDecode(data as String);
    if (response['data']['mag_status'] == 'on') {
      isMagOn = true;
    } else {
      isMagOn = false;
    }
    if (response['data']['mic_status'] == 'on') {
      isMicOn = true;
    } else {
      isMicOn = false;
    }
    magDominantFrequency = response['data']['mag_dominant_frequency'];
    soundDominantFrequency = response['data']['sound_dominant_frequency'];
    setState(() {});
  }

  // foreground task
  void _initService() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'HD_HYUNDAI_PASS_FOR_$identifier',
        channelName: 'HD_HYUNDAI_PASS_FOR_$identifier',
        channelDescription:
            'This notification appears when the HD HYUNDAI PASS service is running.',
        onlyAlertOnce: false,
        channelImportance: NotificationChannelImportance.HIGH,
        priority: NotificationPriority.HIGH,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(1000),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  Future<ServiceRequestResult> _startService() async {
    if (await FlutterForegroundTask.isRunningService) {
      return FlutterForegroundTask.restartService();
    } else {
      return FlutterForegroundTask.startService(
        serviceId: 256,
        notificationTitle: 'HD 현대 PASS',
        notificationText: '데이터가 전송되고 있습니다',
        notificationIcon:
            const NotificationIcon(metaDataName: 'ic_launcher_hd_hd'),
        callback: startCallback,
      );
    }
  }

  Future<ServiceRequestResult> _stopService() {
    return FlutterForegroundTask.stopService();
  }

  void _startMag() {
    final message = {
      'operation': 'start',
      'data': {
        'identifier': identifier,
      },
    };

    FlutterForegroundTask.sendDataToTask(jsonEncode(message));
  }

  Future<void> _requestBatteryPermission() async {
    final NotificationPermission notificationPermission =
        await FlutterForegroundTask.checkNotificationPermission();
    if (notificationPermission != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }

    if (Platform.isAndroid) {
      bool isIgnoringBatteryOptimizations =
          await FlutterForegroundTask.isIgnoringBatteryOptimizations;

      bool canScheduleExactAlarms =
          await FlutterForegroundTask.canScheduleExactAlarms;

      while (!isIgnoringBatteryOptimizations) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
        isIgnoringBatteryOptimizations =
            await FlutterForegroundTask.isIgnoringBatteryOptimizations;
      }

      while (!canScheduleExactAlarms) {
        await FlutterForegroundTask.requestNotificationPermission();
        canScheduleExactAlarms =
            await FlutterForegroundTask.canScheduleExactAlarms;
      }
    }
  }

  void _startMagForIos(int identifier) {
    var magTaskHandlerForIos = MagTaskHandlerForIos(identifier);
    magTaskHandlerForIos.startMagnetometer().then((value) {
      magTaskHandlerForIos.channelMessageController.stream.listen((data) {
        final response = jsonDecode(data);
        if (response['data']['mag_status'] == 'on') {
          isMagOn = true;
        } else {
          isMagOn = false;
        }
        if (response['data']['mic_status'] == 'on') {
          isMicOn = true;
        } else {
          isMicOn = false;
        }
        magDominantFrequency = response['data']['mag_dominant_frequency'];
        magDominantMagnitude = response['data']['mag_dominant_magnitude'];
        soundDominantFrequency = response['data']['sound_dominant_frequency'];
        intervalMilliseconds = response['data']['interval_milliseconds'];
        setState(() {});
      });

      magTaskHandlerForIos.frequencyMagnitudeStreamController.stream
          .listen((data) {
        setState(() {
          // only 5 ~ 80
          spots = data
              .map((e) => FlSpot(e.keys.first, e.values.first))
              .where((e) => e.x >= 5 && e.x <= 80)
              .toList();
        });
      });
    });
  }
}
