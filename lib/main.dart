// lib/main.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:typed_data';

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
  static const int kMinThrottle = 48; // 最小油門保護
  static const int kMaxThrottle = 2047; // 最大油門
  static const int kTickMs = 20; // 計時器節拍 (ms)
  static const double kUnitsPerSecAtFull = 800; // 搖桿滿行程時每秒增減量

  // ====== [State] 變化率控制 ======
  double _leftY = 0.0; // 左搖桿的 Y（-1..+1；上為負、下為正）
  Timer? _stickTimer; // 方案 B 連續更新的計時器
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
    _ensurePermissions();
  }

  void _ensureStickTimer() {
    if (_stickTimer != null) return;

    const tick = Duration(milliseconds: 30); // 送包節拍 ~33Hz
    const deadzone = 0.03;                  // 小幅抖動時不動作
    const minStep = 2;                      // 最小步進
    const maxStep = 40;                     // 由搖桿位移放大到的額外步進上限

    _stickTimer = Timer.periodic(tick, (_) async {
      final y = _leftY;                     // dy ∈ [-1, 1]；上推為負、下推為正

      // 死區：太小就停止計時器
      if (y.abs() < deadzone) {
        _cancelStickTimer();
        return;
      }

      // 上推(負) → 增加；下推(正) → 減少
      final dir = (y < 0) ? 1 : -1;

      // 依位移量調整步進（更用力推，變化更快）
      final step = (minStep + (y.abs() * maxStep)).round();

      // 計算新油門並一次套用四路（_setAllThrottle 內含 clamp 規則）
      final next = _m1 + dir * step;
      _setAllThrottle(next);

      // 送 20-byte 封包（此處預設 ARM，可依需求改 'D' 或 'S'）
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
                      child: Joystick(
                        size: 220,
                        onChanged: (dx, dy) {
                          // 方案 B：改用變化率，不直接設定絕對油門
                          setState(() { _leftY = dy; });
                          if (_leftY.abs() < 1e-3) {
                            _cancelStickTimer();
                          } else {
                            _ensureStickTimer();
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
                          // 右手把：目前空著（保留未來功能）
                          // 你要指派功能時，處理 dx/dy 即可
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
  final double size;
  final void Function(double dx, double dy) onChanged;
  final String? label;

  const Joystick({
    super.key,
    required this.size,
    required this.onChanged,
    this.label,
  });

  @override
  State<Joystick> createState() => _JoystickState();
}

class _JoystickState extends State<Joystick> {
  Offset _pos = Offset.zero; // -1..1 範圍內的相對位置

  @override
  Widget build(BuildContext context) {
    final outer = widget.size;
    final knob = widget.size * 0.35;
    final radius = (outer - knob) / 2;

    Offset toUnit(Offset p) {
      // 轉成 -1..1
      final x = (p.dx / radius).clamp(-1.0, 1.0);
      final y = (p.dy / radius).clamp(-1.0, 1.0);
      return Offset(x, y);
    }

    Offset fromLocal(Offset local, Size size) {
      final center = Offset(size.width / 2, size.height / 2);
      return local - center;
    }

    Offset clampToCircle(Offset v, double r) {
      final len = v.distance;
      if (len <= r) return v;
      final k = r / len;
      return Offset(v.dx * k, v.dy * k);
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.label != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8.0),
            child: Text(
              widget.label!,
              style: const TextStyle(color: Colors.white70),
            ),
          ),
        GestureDetector(
          onPanStart: (d) {
            final box = context.findRenderObject() as RenderBox;
            final local = box.globalToLocal(d.globalPosition);
            final p = fromLocal(local, box.size);
            setState(() => _pos = clampToCircle(p, radius));
            final u = toUnit(_pos);
            widget.onChanged(u.dx, u.dy);
          },
          onPanUpdate: (d) {
            final box = context.findRenderObject() as RenderBox;
            final local = box.globalToLocal(d.globalPosition);
            final p = fromLocal(local, box.size);
            setState(() => _pos = clampToCircle(p, radius));
            final u = toUnit(_pos);
            widget.onChanged(u.dx, u.dy);
          },
          onPanEnd: (_) {
            setState(() => _pos = Offset.zero);
            widget.onChanged(0, 0);
          },
          child: Container(
            width: outer,
            height: outer,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const RadialGradient(
                colors: [Color(0xFF1B2330), Color(0xFF151A22)],
              ),
              border: Border.all(color: Colors.white12),
              boxShadow: const [
                BoxShadow(color: Colors.black54, blurRadius: 12),
              ],
            ),
            child: Center(
              child: Transform.translate(
                offset: _pos,
                child: Container(
                  width: knob,
                  height: knob,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF2C3545),
                    border: Border.all(color: Colors.white24),
                    boxShadow: const [
                      BoxShadow(color: Colors.black87, blurRadius: 10),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
