// lib/main.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:typed_data';
import 'package:shared_preferences/shared_preferences.dart';


/// BT24 (BLE UART) UUID —— 16-bit 擴展成 128-bit
final bt24ServiceUuid = Guid("0000FFE0-0000-1000-8000-00805F9B34FB");
final bt24NotifyUuid = Guid(
  "0000FFE1-0000-1000-8000-00805F9B34FB",
); // notify / write
final bt24WriteUuid = Guid(
  "0000FFE2-0000-1000-8000-00805F9B34FB",
); // write (優先)

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 鎖定橫向
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BLDC 虛擬手把 (BLE BT24)',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  BluetoothDevice? device;
  BluetoothCharacteristic? txChar; // write / writeWithoutResponse
  BluetoothCharacteristic? rxChar; // notify（目前不用顯示）
  StreamSubscription<List<int>>? rxSub;

  bool connecting = false;
  bool connected = false;
  // ====== [Config] 手感與上下限（方案 B）======
  static const int kMinThrottle = 0; // 最小油門保護
  static const int kMaxThrottle = 2047; // 最大油門
  static const int kTickMs = 20; // 計時器節拍 (ms)
  static const double kUnitsPerSecAtFull = 800; // 搖桿滿行程時每秒增減量

  // ====== [State] 變化率控制 ======
  double _leftX = 0, _leftY = 0.0; // 左搖桿的 Y（-1..+1；上為負、下為正）
  Timer? _stickTimer; // 方案 B 連續更新的計時器
  int _thrBase = 0;                // 集體油門基準（由上/下調）
  static const int _yawMax = 500;  // 左右最大差速
  double _rightX = 0, _rightY = 0;   // 右搖桿 [-1..1]，上推為負
  static const int _rollMax  = 500;  // 右搖桿左右(roll)最大差
  static const int _pitchMax = 500;  // 右搖桿前後(pitch)最大差

  // ====== Throttle ======
  int throttle = kMinThrottle; // 0..2047
  int _pending = 0; // 節流佇列
  Timer? _sendTimer; // 20ms 節流送出

// === 四路 throttle 狀態（0~2047；遵守 MCU 限幅規則）===
  int _m1 = 0, _m2 = 0, _m3 = 0, _m4 = 0;

// 限幅規則要跟 MCU 端一致
  int clamp(int v) {
    if (v <= 0) return 0;
    if (v == 1) return 1;
    if (v > 1 && v <= 48) return 48;
    if (v > 2047) return 2047;
    return v;
  }

  // 一次把四路設成同值
  void _setAllThrottle(int v) {
    final nv = clamp(v);
    setState(() {
      _m1 = nv; _m2 = nv; _m3 = nv; _m4 = nv;
    });
  }

// === Offsets（±500 可調）===
  int _off1 = 0, _off2 = 0, _off3 = 0, _off4 = 0;
  static const int _offMin = -500, _offMax = 500;

  int _clampOffset(int v) => v.clamp(_offMin, _offMax);

  Future<void> _loadOffsets() async {
    final p = await SharedPreferences.getInstance();
    setState(() {
      _off1 = p.getInt('off_m1') ?? 0;
      _off2 = p.getInt('off_m2') ?? 0;
      _off3 = p.getInt('off_m3') ?? 0;
      _off4 = p.getInt('off_m4') ?? 0;
    });
  }
  Future<void> _saveOffsets() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt('off_m1', _off1);
    await p.setInt('off_m2', _off2);
    await p.setInt('off_m3', _off3);
    await p.setInt('off_m4', _off4);
  }



  // 發送 20 bytes 封包 (協議: #C1C2C3C4FCRC)
  Future<void> _send20BytePacket(
    int m1,
    int m2,
    int m3,
    int m4,
    String flag,
  ) async {
    if (device == null || txChar == null) return;

    m1 = clamp(m1);
    m2 = clamp(m2);
    m3 = clamp(m3);
    m4 = clamp(m4);

    // 四個馬達轉 4 位數字 ASCII
    String s1 = m1.toString().padLeft(4, '0');
    String s2 = m2.toString().padLeft(4, '0');
    String s3 = m3.toString().padLeft(4, '0');
    String s4 = m4.toString().padLeft(4, '0');

    String payload = "$s1$s2$s3$s4$flag";

    // XOR 校驗
    int crc = 0;
    for (int i = 0; i < payload.length; i++) {
      crc ^= payload.codeUnitAt(i);
    }
    String crcHex = crc.toRadixString(16).toUpperCase().padLeft(2, '0');

    // 完整封包
    String packet = "#$payload$crcHex";

    // 轉成 bytes (ASCII)
    Uint8List data = ascii.encode(packet);

    // 寫入 BLE 特徵值
    await txChar!.write(data, withoutResponse: true);
  }

  @override
  void initState() {
    super.initState();
    _loadOffsets();
    _ensurePermissions();
  }

  void _ensureStickTimer() {
    if (_stickTimer != null) return;

    const tick = Duration(milliseconds: 30); // 送包節拍 ~33Hz
    const dead = 0.03;                  // 小幅抖動時不動作
    const minStep = 2;                      // 最小步進
    const maxStep = 40;                     // 由搖桿位移放大到的額外步進上限

    _stickTimer = Timer.periodic(tick, (_) async {
      final lx = _leftX;   // 左搖桿 x：原地轉向（m1&m3 vs m2&m4）
      final ly = _leftY;   // 左搖桿 y：集體油門
      final rx = _rightX;  // 右搖桿 x：左右差速（m1&m2 vs m3&m4）
      final ry = _rightY;  // 右搖桿 y：前後差速（m1&m4 vs m2&m3）

      // 四軸都在死區 → 停止
      if (lx.abs() < dead && ly.abs() < dead && rx.abs() < dead && ry.abs() < dead) {
        _cancelStickTimer();
        return;
      }

      // 1) 左搖桿 Y：調整集體油門基準 _thrBase（上推=負→增加）
      var base = _thrBase;
      if (ly.abs() >= dead) {
        final dirY = (ly < 0) ? 1 : -1;
        final step = (minStep + (ly.abs() * maxStep)).round();
        base = clamp(base + dirY * step);
        _thrBase = base;
      }

      // 2) 左搖桿 X：原地轉向（m1&m3 vs m2&m4），滿推差 _yawMax
      int yaw = 0;
      if (lx.abs() >= dead) yaw = (lx.abs() * _yawMax).round();

      // yaw 符號分配：
      //  lx < 0（向左）：m2,m4 > m1,m3  → m1:-yaw, m2:+yaw, m3:-yaw, m4:+yaw
      int yaw_m1 = 0, yaw_m2 = 0, yaw_m3 = 0, yaw_m4 = 0;
      if (lx <= -dead) {
        yaw_m1 = -yaw; yaw_m2 = yaw; yaw_m3 = -yaw; yaw_m4 = yaw;
      } else if (lx >= dead) {
        yaw_m1 = yaw; yaw_m2 = -yaw; yaw_m3 = yaw; yaw_m4 = -yaw;
      }

      // 3) 右搖桿 X：左右差速（m1&m2 vs m3&m4），滿推差 _rollMax
      int roll = 0;
      if (rx.abs() >= dead) roll = (rx.abs() * _rollMax).round();

      // rx < 0（向左）：m1,m2 > m3,m4 → m1:+roll, m2:+roll, m3:-roll, m4:-roll
      int roll_m1 = 0, roll_m2 = 0, roll_m3 = 0, roll_m4 = 0;
      if (rx <= -dead) {
        roll_m1 = roll; roll_m2 = roll; roll_m3 = -roll; roll_m4 = -roll;
      } else if (rx >= dead) {
        roll_m1 = -roll; roll_m2 = -roll; roll_m3 = roll; roll_m4 = roll;
      }

      // 4) 右搖桿 Y：前後差速（m1&m4 vs m2&m3），滿推差 _pitchMax
      int pitch = 0;
      if (ry.abs() >= dead) pitch = (ry.abs() * _pitchMax).round();

      // ry < 0（向上）：m1,m4 > m2,m3 → m1:+pitch, m4:+pitch, m2:-pitch, m3:-pitch
      int pitch_m1 = 0, pitch_m2 = 0, pitch_m3 = 0, pitch_m4 = 0;
      if (ry <= -dead) {
        pitch_m1 = pitch; pitch_m4 = pitch; pitch_m2 = -pitch; pitch_m3 = -pitch;
      } else if (ry >= dead) {
        pitch_m1 = -pitch; pitch_m4 = -pitch; pitch_m2 = pitch; pitch_m3 = pitch;
      }

      // 5) 合成四路
      final a = clamp(base + yaw_m1 + roll_m1 + pitch_m1 + _off1); // m1
      final b = clamp(base + yaw_m2 + roll_m2 + pitch_m2 + _off2); // m2
      final c = clamp(base + yaw_m3 + roll_m3 + pitch_m3 + _off3); // m3
      final d = clamp(base + yaw_m4 + roll_m4 + pitch_m4 + _off4); // m4

      setState(() { _m1 = a; _m2 = b; _m3 = c; _m4 = d; });
      if (txChar != null) {
        await _send20BytePacket(_m1, _m2, _m3, _m4, 'A');
      }
    });
  }

  void _cancelStickTimer() {
    _stickTimer?.cancel();
    _stickTimer = null;
  }

  /// 每個 tick 根據左搖桿 Y 來累加/遞減 throttle
  void _tickUpdate() {
    // 若已回中就停止
    if (_leftY.abs() < 1e-3) {
      _cancelStickTimer();
      return;
    }

    // 上推（負）= 增加；下推（正）= 減少
    final perSec = kUnitsPerSecAtFull * (-_leftY);
    final perTick = perSec * (kTickMs / 1000.0);
    int delta = perTick.round();

    // 讓極小位移也能動
    if (delta == 0) {
      delta = perTick > 0 ? 1 : -1;
    }

    final next = (throttle + delta).clamp(kMinThrottle, kMaxThrottle);
    if (next != throttle) {
      setState(() => throttle = next as int);
      _scheduleSend(throttle); // 沿用你原本的 20ms 節流送出（只送 4 位數字）
    }
  }

  Future<void> _ensurePermissions() async {
    final reqs = <Permission>[
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse, // Android 11- 需要
    ];
    for (final p in reqs) {
      if (await p.isDenied) await p.request();
    }
    final state = await FlutterBluePlus.adapterState.first;
    if (!mounted) return;
    if (state != BluetoothAdapterState.on) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('請先開啟手機藍牙')));
    }
  }

  // ====== 掃描 + 連線 ======
  Future<void> _scanAndConnect() async {
    setState(() => connecting = true);
    final found = <ScanResult>[];

    await FlutterBluePlus.startScan(
      timeout: const Duration(seconds: 6),
      withServices: [bt24ServiceUuid],
    );

    final sub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        if (!found.any((x) => x.device.remoteId == r.device.remoteId)) {
          found.add(r);
        }
      }
    });

    await Future.delayed(const Duration(seconds: 6));
    await FlutterBluePlus.stopScan();
    await sub.cancel();
    if (!mounted) return;

    final picked = await showDialog<ScanResult>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('選擇 BT24 (BLE UART)'),
        children: found.isEmpty
            ? [
                const Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Text('掃不到裝置，請確認 BT24 上電且可被掃描。'),
                ),
              ]
            : found
                  .map(
                    (r) => SimpleDialogOption(
                      onPressed: () => Navigator.pop(ctx, r),
                      child: Text(
                        '${r.device.platformName.isEmpty ? "(no name)" : r.device.platformName} (${r.device.remoteId.str})',
                      ),
                    ),
                  )
                  .toList(),
      ),
    );

    if (picked == null) {
      setState(() => connecting = false);
      return;
    }
    await _connect(picked.device);
  }

  Future<void> _connect(BluetoothDevice d) async {
    try {
      device = d;
      await d.connect(timeout: const Duration(seconds: 10));
      connected = true;

      final services = await d.discoverServices();
      for (final s in services) {
        if (s.uuid == bt24ServiceUuid) {
          for (final c in s.characteristics) {
            if (c.uuid == bt24WriteUuid &&
                (c.properties.write || c.properties.writeWithoutResponse)) {
              txChar = c; // FFE2 優先當寫入
            }
            if (c.uuid == bt24NotifyUuid) {
              if (c.properties.notify) rxChar = c; // 目前不顯示
              if (txChar == null &&
                  (c.properties.write || c.properties.writeWithoutResponse)) {
                txChar = c; // 若沒 FFE2，就用 FFE1 寫
              }
            }
          }
        }
      }
      if (txChar == null) throw '找不到可寫入的 TX characteristic (FFE2/FFE1)';

      // 若你日後需要顯示回傳，可開啟 notify，但現在不顯示
      if (rxChar != null && rxChar!.properties.notify) {
        await rxChar!.setNotifyValue(true);
        rxSub = rxChar!.lastValueStream.listen((data) {
          // 靜音，不輸出
          // final line = utf8.decode(data, allowMalformed: true).trim();
        });
      }

      setState(() {
        connecting = false;
        connected = true;
      });
    } catch (e) {
      await _disconnect();
      if (mounted) {
        setState(() => connecting = false);
        _snack('連線失敗：$e');
      }
    }
  }

  Future<void> _disconnect() async {
    try {
      await rxSub?.cancel();
      rxSub = null;
      txChar = null;
      rxChar = null;
      connected = false;
      if (device != null) {
        await device!.disconnect();
      }
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> _writeAscii(String s) async {
    final c = txChar;
    if (c == null || !connected) return;
    final noResp = c.properties.writeWithoutResponse;
    await c.write(utf8.encode(s), withoutResponse: noResp);
  }

  void _scheduleSend(int val) {
    _pending = val.clamp(0, 2047);
    _sendTimer ??= Timer.periodic(const Duration(milliseconds: 20), (_) {
      final s = _pending.toString().padLeft(4, '0'); // 只送 4 位數字，無 T、無 \n
      _writeAscii(s);
    });
  }

  void _snack(String s) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }
  Future<void> _openOffsetPage() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => OffsetPage(
        m1: _off1, m2: _off2, m3: _off3, m4: _off4,
        minV: _offMin, maxV: _offMax,
        onSave: (a, b, c, d) async {
          setState(() { _off1 = a; _off2 = b; _off3 = c; _off4 = d; });
          await _saveOffsets();
        },
      ),
    ));
  }


  @override
  void dispose() {
    _stickTimer?.cancel(); // ← 新增
    _sendTimer?.cancel();
    rxSub?.cancel();
    device?.disconnect();
    super.dispose();
  }

  // ====== UI ======
  @override
  Widget build(BuildContext context) {
    final status = connected
        ? 'Connected: ${device?.platformName}'
        : connecting
        ? 'Connecting...'
        : 'Disconnected';

    return Scaffold(
      backgroundColor: const Color(0xFF0E1116),
      body: SafeArea(
        child: Column(
          children: [
            // Top bar：僅連線控制，盡量簡潔
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Text(status, style: const TextStyle(color: Colors.white70)),
                  const Spacer(),
                  if (connected)
                    FilledButton.tonal(
                      onPressed: _disconnect,
                      child: const Text('Disconnect'),
                    )
                  else
                    FilledButton(
                      onPressed: connecting ? null : _scanAndConnect,
                      child: const Text('Scan & Connect'),
                    ),
                ],
              ),
            ),

            // 主要區塊：兩顆虛擬手把（左/右）
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: Center(
                      child:Joystick(
                        size: 220,
                        // verticalOnly: true, // NEW：只吃上下
                        onChanged: (dx, dy) {
                          setState(() { _leftX = dx;_leftY = -dy; });
                          const dead = 0.03;
                          if (_leftX.abs() < dead && _leftY.abs() < dead) {
                            _cancelStickTimer();
                          } else {
                            _ensureStickTimer(); // 仍沿用你現在的變化率→四路同值邏輯
                          }
                        },
                        label: 'Left Stick',
                      ),
                    ),
                  ),
                  Expanded(
                    child: Center(
                      child: Joystick(
                        size: 220,
                        onChanged: (dx, dy) {
                          setState(() {
                            _rightX = dx;  // 左(負)／右(正)
                            _rightY = -dy;  // 上(負)／下(正)
                          });
                          const dead = 0.03;
                          if (_rightX.abs() < dead && _rightY.abs() < dead && _leftX.abs() < dead && _leftY.abs() < dead) {
                            _cancelStickTimer();
                          } else {
                            _ensureStickTimer();
                          }
                        },
                        label: 'Right Stick',
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // 底部：小顯示（僅數值，無 RX 輸出）
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // 四路油門顯示
                  Text(
                    'm1=$_m1  m2=$_m2  m3=$_m3  m4=$_m4',
                    style: const TextStyle(color: Colors.white70),
                  ),

                  const SizedBox(width: 12),
                  OutlinedButton(
                    onPressed: () {
                      setState(() {
                        _thrBase = 0;
                        _m1 = 0;
                        _m2 = 0;
                        _m3 = 0;
                        _m4 = 0;
                      });
                      _send20BytePacket(_m1, _m2, _m3, _m4, 'S'); // STOP flag
                    },
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white70,
                      side: const BorderSide(color: Colors.white24),
                    ),
                    child: const Text('STOP'),
                  ),

                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: () {
                      setState(() {
                        _thrBase = 2047;
                        _m1 = 2047;
                        _m2 = 2047;
                        _m3 = 2047;
                        _m4 = 2047;
                      });
                      _send20BytePacket(_m1, _m2, _m3, _m4, 'A'); // ARM flag
                    },
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white70,
                      side: const BorderSide(color: Colors.white24),
                    ),
                    child: const Text('MAX'),
                  ),
                  const Spacer(),

                  OutlinedButton.icon(
                    onPressed: _openOffsetPage,
                    icon: const Icon(Icons.tune, size: 16, color: Colors.white70),
                    label: const Text('Offsets', style: TextStyle(color: Colors.white70)),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.white24),
                      foregroundColor: Colors.white70,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 簡易虛擬手把（不依賴外部套件）
/// - 回傳 (dx, dy) ∈ [-1, 1]
class Joystick extends StatefulWidget {
  const Joystick({
    super.key,
    required this.onChanged,
    this.size = 160,
    this.verticalOnly = false, // NEW
    this.label,                    // NEW
  });

  final void Function(double dx, double dy) onChanged;
  final double size;
  final bool verticalOnly; // NEW
  final String? label;             // NEW

  @override
  State<Joystick> createState() => _JoystickState();
}

class _JoystickState extends State<Joystick> {
  Offset _knob = Offset.zero; // -1..1 範圍內的位移（x,y）

  void _emit(Offset o) {
    // 轉成 [-1,1]，上推 dy 應為負
    double nx = o.dx;
    double ny = o.dy;

    if (widget.verticalOnly) nx = 0; // NEW: 鎖水平
    widget.onChanged(nx, ny);
  }

  @override
  Widget build(BuildContext context) {
    final sz = widget.size;
    final r = sz / 2;

    return GestureDetector(
      onPanStart: (d) {
        final local = (context.findRenderObject() as RenderBox)
            .globalToLocal(d.globalPosition);
        final center = Offset(sz / 2, sz / 2);
        var v = (local - center) / r;         // 正規化到 [-1,1]
        if (widget.verticalOnly) v = Offset(0, v.dy); // NEW
        v = Offset(v.dx.clamp(-1, 1), v.dy.clamp(-1, 1));
        setState(() => _knob = Offset(v.dx, v.dy));
        _emit(Offset(v.dx, -v.dy)); // 讓上推為負 dy
      },
      onPanUpdate: (d) {
        final local = (context.findRenderObject() as RenderBox)
            .globalToLocal(d.globalPosition);
        final center = Offset(sz / 2, sz / 2);
        var v = (local - center) / r;
        if (widget.verticalOnly) v = Offset(0, v.dy); // NEW
        v = Offset(v.dx.clamp(-1, 1), v.dy.clamp(-1, 1));
        setState(() => _knob = Offset(v.dx, v.dy));
        _emit(Offset(v.dx, -v.dy));
      },
      onPanEnd: (_) {
        setState(() => _knob = Offset.zero);
        _emit(Offset.zero);
      },
      child: SizedBox(
        width: sz,
        height: sz,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // 背板
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFF161A22),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0x22FFFFFF)),
              ),
            ),
            // 十字盤（水平/垂直條）
            // 即使 verticalOnly，也保留十字盤外觀（左右功能先不做）
            Container(width: sz * 0.7, height: 4, color: const Color(0x33FFFFFF)),
            Container(width: 4, height: sz * 0.7, color: const Color(0x33FFFFFF)),

            // 位置刻度（中點）
            Container(width: 6, height: 6, decoration: const BoxDecoration(
                color: Color(0x55FFFFFF), shape: BoxShape.circle)),

            // 搖桿頭
            Transform.translate(
              offset: Offset(_knob.dx * (r - 18), _knob.dy * (r - 18)),
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: const Color(0xFF2A2F3A),
                  shape: BoxShape.circle,
                  boxShadow: const [BoxShadow(blurRadius: 8, color: Colors.black54)],
                  border: Border.all(color: const Color(0x44FFFFFF)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class OffsetPage extends StatefulWidget {
  const OffsetPage({
    super.key,
    required this.m1, required this.m2, required this.m3, required this.m4,
    required this.minV, required this.maxV,
    required this.onSave,
  });

  final int m1, m2, m3, m4;
  final int minV, maxV;
  final void Function(int m1, int m2, int m3, int m4) onSave;

  @override
  State<OffsetPage> createState() => _OffsetPageState();
}

class _OffsetPageState extends State<OffsetPage> {
  late int o1 = widget.m1,
      o2 = widget.m2,
      o3 = widget.m3,
      o4 = widget.m4;

  late final TextEditingController _c1;
  late final TextEditingController _c2;
  late final TextEditingController _c3;
  late final TextEditingController _c4;

  int _clp(int v) => v.clamp(widget.minV, widget.maxV);


  @override
  void initState() {
    super.initState();
    _c1 = TextEditingController(text: o1.toString());
    _c2 = TextEditingController(text: o2.toString());
    _c3 = TextEditingController(text: o3.toString());
    _c4 = TextEditingController(text: o4.toString());
  }

  @override
  void dispose() {
    _c1.dispose(); _c2.dispose(); _c3.dispose(); _c4.dispose();
    super.dispose();
  }

  // name: 'M1' ... 'M4'
  // val : 目前值
  // setV: 更新狀態 setState(() => o1 = v)
  // ctrl: 對應文字框 controller（_c1.._c4）
  Widget _row(String name, int val, void Function(int) setV, TextEditingController ctrl) {
    void applyInt(int v) {
      final nv = _clp(v);
      setState(() {
        setV(nv);
        ctrl.text = nv.toString();
      });
      HapticFeedback.selectionClick();
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
      child: Row(
        children: [
          SizedBox(width: 44, child: Text(name, style: const TextStyle(color: Colors.white))),

          // 滑桿（連續，-500~500）
          Expanded(
            child: Slider(
              value: val.toDouble(),
              min: widget.minV.toDouble(),
              max: widget.maxV.toDouble(),
              divisions: 200, // 可調；200 ≈ 每格 5
              label: '$val',
              onChanged: (d) => applyInt(d.round()),
            ),
          ),

          const SizedBox(width: 8),

          // 直接輸入數字（±500），Enter 提交
          SizedBox(
            width: 76,
            child: TextField(
              controller: ctrl,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
              keyboardType: const TextInputType.numberWithOptions(signed: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'^-?\d{0,4}$')),
              ],
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                enabledBorder: OutlineInputBorder(
                  borderSide: const BorderSide(color: Color(0x22FFFFFF)),
                  borderRadius: BorderRadius.circular(8),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: const BorderSide(color: Color(0x66FFFFFF)),
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onSubmitted: (s) {
                final v = int.tryParse(s);
                if (v != null) applyInt(v);
                else ctrl.text = val.toString();
              },
            ),
          ),

          // 一鍵歸零
          IconButton(
            tooltip: 'Reset to 0',
            onPressed: () => applyInt(0),
            icon: const Icon(Icons.restart_alt, color: Colors.white70, size: 20),
            style: IconButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 6),
            ),
          ),
        ],
      ),
    );
  }

  Widget _stepBtn(String label, VoidCallback onTap) {
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white70,
        side: const BorderSide(color: Colors.white24),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        minimumSize: const Size(0, 0),
      ),
      child: Text(label),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0E1116),
      resizeToAvoidBottomInset: true,
      // 鍵盤彈出時自動推開內容
      appBar: AppBar(
        backgroundColor: const Color(0xFF0E1116),
        elevation: 0,
        title: const Text(
            'Motor Offsets', style: TextStyle(color: Colors.white)),
        actions: [
          TextButton(
            onPressed: () {
              setState(() {
                o1 = 0;
                o2 = 0;
                o3 = 0;
                o4 = 0;
              });
            },
            child: const Text('Reset', style: TextStyle(color: Colors.white70)),
          ),
          const SizedBox(width: 8),
        ],
      ),

// ===== OffsetPage.build 的 body 取代這段 =====
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= 520; // 寬螢幕並排、窄螢幕直排

            Widget infoPanel() => Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0x181C1C1C),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0x22FFFFFF)),
              ),
              child: const Text(
                '可對各馬達施加常數偏移 ±500\n'
                    '最終輸出仍會被限制在 0–2047 。',
                style: TextStyle(color: Colors.white54, height: 1.3),
              ),
            );

            final leftColumn = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _row('M1', o1, (v) => o1 = v, _c1),
                _row('M2', o2, (v) => o2 = v, _c2),
                _row('M3', o3, (v) => o3 = v, _c3),
                _row('M4', o4, (v) => o4 = v, _c4),
              ],
            );

            final content = isWide
                ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: leftColumn),
                const SizedBox(width: 16),
                SizedBox(width: 260, child: infoPanel()), // 右側說明
              ],
            )
                : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                infoPanel(),
                const SizedBox(height: 12),
                leftColumn,
              ],
            );

            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: content,
              ),
            );
          },
        ),
      ),

      // Save 固定在底部，不佔用可滾動區域的高度
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () {
                widget.onSave(o1, o2, o3, o4);
                Navigator.pop(context);
              },
              child: const Text('Save'),
            ),
          ),
        ),
      ),
    );
  }
}
