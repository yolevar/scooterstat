import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

// ── Protokoll-Konstanten ─────────────────────────────────────────────────────
const String kUartSvc = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
const String kUartTx  = '6e400002-b5a3-f393-e0a9-e50e24dcca9e';
const String kUartRx  = '6e400003-b5a3-f393-e0a9-e50e24dcca9e';
final List<int> kCmdTelemetry = [0x55, 0xAA, 0x03, 0x20, 0x01, 0x01, 0xDB, 0xFF];

// ── Telemetrie-Datenklasse ────────────────────────────────────────────────────
class ScooterData {
  double speed;
  int    motorTemp;
  int    battery;
  double voltage;
  double current;
  String rawHex;

  ScooterData({
    this.speed     = 0,
    this.motorTemp = 0,
    this.battery   = 0,
    this.voltage   = 0,
    this.current   = 0,
    this.rawHex    = '—',
  });

  ScooterData copyWith(List<int> raw) {
    final d = ScooterData(
      speed:     speed,
      motorTemp: motorTemp,
      battery:   battery,
      voltage:   voltage,
      current:   current,
      rawHex:    raw.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' '),
    );
    if (raw.length > 28) d.motorTemp = raw[28];
    if (raw.length > 26) d.speed     = ((raw[25] << 8) | raw[24]) / 1000.0;
    if (raw.length > 22) d.voltage   = ((raw[21] << 8) | raw[20]) / 100.0;
    if (raw.length > 20) {
      int raw16 = (raw[19] << 8) | raw[18];
      if (raw16 > 32767) raw16 -= 65536;
      d.current = raw16 / 100.0;
    }
    if (raw.length > 15) d.battery = raw[14];
    return d;
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ScooterApp());
}

class ScooterApp extends StatelessWidget {
  const ScooterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Scooter BLE',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF080B12),
        colorScheme: const ColorScheme.dark(
          primary:   Color(0xFF00F5D4),
          secondary: Color(0xFFF72585),
        ),
      ),
      home: const ScooterScreen(),
    );
  }
}

// ── Hauptscreen ───────────────────────────────────────────────────────────────
class ScooterScreen extends StatefulWidget {
  const ScooterScreen({super.key});
  @override
  State<ScooterScreen> createState() => _ScooterScreenState();
}

class _ScooterScreenState extends State<ScooterScreen> {

  // BLE State
  List<ScanResult>       _scanResults = [];
  BluetoothDevice?       _device;
  BluetoothCharacteristic? _txChar;
  BluetoothCharacteristic? _rxChar;
  bool                   _isScanning   = false;
  bool                   _isConnected  = false;
  bool                   _isConnecting = false;
  StreamSubscription?    _scanSub;
  StreamSubscription?    _dataSub;
  Timer?                 _pollTimer;

  // Daten
  ScooterData _data = ScooterData();
  final List<String> _log = [];

  @override
  void dispose() {
    _scanSub?.cancel();
    _dataSub?.cancel();
    _pollTimer?.cancel();
    super.dispose();
  }

  void _addLog(String msg) {
    final ts = TimeOfDay.now().format(context);
    setState(() => _log.insert(0, '[$ts] $msg'));
    if (_log.length > 50) _log.removeLast();
  }

  // ── Berechtigungen ────────────────────────────────────────────────────────
  Future<bool> _requestPermissions() async {
    final statuses = await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    return statuses.values.every((s) => s.isGranted || s.isLimited);
  }

  // ── Scan ──────────────────────────────────────────────────────────────────
  Future<void> _startScan() async {
    final ok = await _requestPermissions();
    if (!ok) {
      _addLog('❌ Bluetooth-Berechtigung verweigert');
      return;
    }

    setState(() { _isScanning = true; _scanResults = []; });
    _addLog('Starte BLE-Scan...');

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      setState(() => _scanResults = results);
    });

    await Future.delayed(const Duration(seconds: 8));
    await FlutterBluePlus.stopScan();
    setState(() => _isScanning = false);
    _addLog('Scan abgeschlossen — ${_scanResults.length} Geräte gefunden');
  }

  // ── Verbinden ─────────────────────────────────────────────────────────────
  Future<void> _connect(BluetoothDevice device) async {
    setState(() => _isConnecting = true);
    _addLog('Verbinde mit ${device.platformName.isNotEmpty ? device.platformName : device.remoteId}...');

    try {
      await device.connect(timeout: const Duration(seconds: 15));
      _device = device;

      device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _onDisconnected();
        }
      });

      final services = await device.discoverServices();
      for (final svc in services) {
        if (svc.uuid.toString().toLowerCase() == kUartSvc) {
          for (final c in svc.characteristics) {
            final uuid = c.uuid.toString().toLowerCase();
            if (uuid == kUartTx) _txChar = c;
            if (uuid == kUartRx) _rxChar = c;
          }
        }
      }

      if (_rxChar == null || _txChar == null) {
        _addLog('⚠️  UART-Service nicht gefunden — trotzdem verbunden');
      } else {
        await _rxChar!.setNotifyValue(true);
        _dataSub = _rxChar!.onValueReceived.listen(_onData);
        await _txChar!.write(kCmdTelemetry);

        _pollTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) async {
          if (_isConnected && _txChar != null) {
            try { await _txChar!.write(kCmdTelemetry); } catch (_) {}
          }
        });
      }

      setState(() {
        _isConnected  = true;
        _isConnecting = false;
      });
      _addLog('✓ Verbunden: ${device.platformName.isNotEmpty ? device.platformName : device.remoteId}');

    } catch (e) {
      setState(() => _isConnecting = false);
      _addLog('❌ Verbindungsfehler: $e');
    }
  }

  Future<void> _disconnect() async {
    _pollTimer?.cancel();
    _dataSub?.cancel();
    await _device?.disconnect();
    _onDisconnected();
  }

  void _onDisconnected() {
    _pollTimer?.cancel();
    _dataSub?.cancel();
    setState(() {
      _isConnected  = false;
      _isConnecting = false;
      _txChar = null;
      _rxChar = null;
    });
    _addLog('Verbindung getrennt');
  }

  void _onData(List<int> raw) {
    setState(() => _data = _data.copyWith(raw));
  }

  // ── UI ────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080B12),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D1120),
        title: const Text(
          '⚡ SCOOTER BLE',
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: Color(0xFF00F5D4),
            letterSpacing: 3,
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Row(
              children: [
                Container(
                  width: 8, height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isConnected
                        ? const Color(0xFF39FF14)
                        : _isConnecting
                            ? Colors.orange
                            : const Color(0xFFFF1744),
                    boxShadow: [BoxShadow(
                      color: (_isConnected
                          ? const Color(0xFF39FF14)
                          : const Color(0xFFFF1744)).withOpacity(.6),
                      blurRadius: 8,
                    )],
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  _isConnected ? 'VERBUNDEN'
                      : _isConnecting ? 'VERBINDE...' : 'GETRENNT',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
                    color: _isConnected
                        ? const Color(0xFF39FF14)
                        : Colors.grey,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Scan + Geräteliste ──────────────────────────────────────────
          _sectionTitle('// BLUETOOTH SCAN'),
          const SizedBox(height: 8),
          _outlineButton(
            label: _isScanning ? '⏳  SCANNT...' : '▶  SCAN STARTEN',
            color: const Color(0xFF00F5D4),
            onTap: _isScanning ? null : _startScan,
          ),
          const SizedBox(height: 8),
          if (_scanResults.isNotEmpty) _deviceList(),
          const SizedBox(height: 16),

          // ── Verbinden / Trennen ─────────────────────────────────────────
          _isConnected
              ? _filledButton(label: '✖  TRENNEN',   color: const Color(0xFFFF1744), onTap: _disconnect)
              : _filledButton(label: '🔗  VERBINDEN', color: const Color(0xFF39FF14), textColor: Colors.black,
                              onTap: (_device != null && !_isConnecting) ? () => _connect(_device!) : null),
          const SizedBox(height: 20),

          // ── Telemetrie ──────────────────────────────────────────────────
          _sectionTitle('// LIVE TELEMETRIE'),
          const SizedBox(height: 12),
          _MetricCard(
            label: 'GESCHWINDIGKEIT',
            value: _data.speed.toStringAsFixed(1),
            unit:  'km/h',
            color: const Color(0xFF00F5D4),
            large: true,
            active: _isConnected,
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: _MetricCard(label: 'MOTOR TEMP', value: '${_data.motorTemp}', unit: '°C',   color: const Color(0xFFFF9100), active: _isConnected)),
            const SizedBox(width: 10),
            Expanded(child: _MetricCard(label: 'AKKU',       value: '${_data.battery}',   unit: '%',    color: const Color(0xFF39FF14), active: _isConnected)),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: _MetricCard(label: 'SPANNUNG', value: _data.voltage.toStringAsFixed(2), unit: 'V', color: const Color(0xFFBD93F9), active: _isConnected)),
            const SizedBox(width: 10),
            Expanded(child: _MetricCard(label: 'STROM',    value: _data.current.toStringAsFixed(2), unit: 'A', color: const Color(0xFFF72585), active: _isConnected)),
          ]),
          const SizedBox(height: 10),

          // ── RAW HEX ─────────────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF0D1120),
              border: Border.all(color: const Color(0xFF1C2235)),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('RAW HEX', style: TextStyle(fontSize: 9, color: Colors.grey, letterSpacing: 2)),
                const SizedBox(height: 6),
                Text(_data.rawHex,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 10, color: Color(0xFF546E7A)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // ── Log ─────────────────────────────────────────────────────────
          _sectionTitle('// LOG'),
          const SizedBox(height: 8),
          Container(
            height: 160,
            decoration: BoxDecoration(
              color: const Color(0xFF0D1120),
              border: Border.all(color: const Color(0xFF1C2235)),
              borderRadius: BorderRadius.circular(6),
            ),
            child: ListView.builder(
              padding: const EdgeInsets.all(10),
              reverse: false,
              itemCount: _log.length,
              itemBuilder: (_, i) => Text(
                _log[i],
                style: const TextStyle(fontFamily: 'monospace', fontSize: 10, color: Color(0xFF546E7A), height: 1.8),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Helper Widgets ────────────────────────────────────────────────────────
  Widget _sectionTitle(String t) => Text(t,
    style: const TextStyle(fontFamily: 'monospace', fontSize: 9, color: Color(0xFF4A5568), letterSpacing: 3));

  Widget _outlineButton({required String label, required Color color, VoidCallback? onTap}) =>
    GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          border: Border.all(color: onTap == null ? Colors.grey.shade800 : color),
          borderRadius: BorderRadius.circular(4),
          color: color.withOpacity(.05),
        ),
        child: Center(child: Text(label,
          style: TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold, fontSize: 12,
            color: onTap == null ? Colors.grey : color, letterSpacing: 2))),
      ),
    );

  Widget _filledButton({required String label, required Color color, Color textColor = Colors.white, VoidCallback? onTap}) =>
    GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: onTap == null ? Colors.grey.shade800 : color,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Center(child: Text(label,
          style: TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold,
            fontSize: 12, color: onTap == null ? Colors.grey : textColor, letterSpacing: 2))),
      ),
    );

  Widget _deviceList() {
    final scooterKW = ['mi', 'ninebot', 'nb', 'm365', 'scooter', 'xiaomi'];
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0D1120),
        border: Border.all(color: const Color(0xFF1C2235)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        children: _scanResults.map((r) {
          final name = r.device.platformName.isNotEmpty ? r.device.platformName : 'Unbekannt';
          final isScooter = scooterKW.any((k) => name.toLowerCase().contains(k));
          final isSelected = _device?.remoteId == r.device.remoteId;
          return GestureDetector(
            onTap: () {
              setState(() => _device = r.device);
              _addLog('Ausgewählt: $name [${r.device.remoteId}]');
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: isSelected ? const Color(0xFF00F5D4).withOpacity(.07) : Colors.transparent,
                border: Border(bottom: BorderSide(color: const Color(0xFF1C2235))),
              ),
              child: Row(
                children: [
                  Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Text(name, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                        if (isScooter) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              border: Border.all(color: const Color(0xFFF72585).withOpacity(.5)),
                              color: const Color(0xFFF72585).withOpacity(.1),
                              borderRadius: BorderRadius.circular(2),
                            ),
                            child: const Text('SCOOTER', style: TextStyle(fontSize: 8, color: Color(0xFFF72585), letterSpacing: 1)),
                          ),
                        ],
                      ]),
                      const SizedBox(height: 2),
                      Text('${r.device.remoteId}', style: const TextStyle(fontFamily: 'monospace', fontSize: 10, color: Colors.grey)),
                    ],
                  )),
                  Text('${r.rssi} dBm', style: const TextStyle(fontFamily: 'monospace', fontSize: 10, color: Color(0xFF00F5D4))),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ── Metrik-Karte ──────────────────────────────────────────────────────────────
class _MetricCard extends StatelessWidget {
  final String label, value, unit;
  final Color color;
  final bool large, active;

  const _MetricCard({
    required this.label,
    required this.value,
    required this.unit,
    required this.color,
    this.large  = false,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF0D1120),
        border: Border(
          top: BorderSide(color: active ? color.withOpacity(.6) : const Color(0xFF1C2235), width: 2),
          left: BorderSide(color: const Color(0xFF1C2235)),
          right: BorderSide(color: const Color(0xFF1C2235)),
          bottom: BorderSide(color: const Color(0xFF1C2235)),
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        children: [
          Text(label, style: const TextStyle(fontFamily: 'monospace', fontSize: 8, color: Colors.grey, letterSpacing: 2)),
          const SizedBox(height: 8),
          Text(value,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: large ? 48 : 26,
              fontWeight: FontWeight.bold,
              color: color,
              shadows: [Shadow(color: color.withOpacity(.4), blurRadius: 12)],
            ),
          ),
          const SizedBox(height: 4),
          Text(unit, style: const TextStyle(fontSize: 10, color: Colors.grey)),
        ],
      ),
    );
  }
}
