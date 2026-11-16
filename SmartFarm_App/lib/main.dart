import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const SmartFarmApp());
}

class SmartFarmApp extends StatelessWidget {
  const SmartFarmApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Farm Pro',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4F46E5),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF0F4F8),
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tabIndex = 0;
  Timer? _timer;

  String _serverUrl = '';
  String _cookie = '';
  bool _serverOnline = false;
  String _connError = 'Chưa cấu hình địa chỉ máy chủ';

  Map<String, dynamic> _state = {};
  final _urlCtrl = TextEditingController();
  final _userCtrl = TextEditingController(text: 'admin');
  final _passCtrl = TextEditingController();

  // Ngưỡng Ngày / Đêm
  final _dTempCtrl = TextEditingController();
  final _dHumiCtrl = TextEditingController();
  final _dHeatCtrl = TextEditingController();
  final _nTempCtrl = TextEditingController();
  final _nHumiCtrl = TextEditingController();
  final _nHeatCtrl = TextEditingController();
  bool _thresholdsLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadSavedServer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _urlCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    _dTempCtrl.dispose();
    _dHumiCtrl.dispose();
    _dHeatCtrl.dispose();
    _nTempCtrl.dispose();
    _nHumiCtrl.dispose();
    _nHeatCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadSavedServer() async {
    final prefs = await SharedPreferences.getInstance();
    final savedUrl = prefs.getString('server_url') ?? '';
    final savedCookie = prefs.getString('session_cookie') ?? '';
    setState(() {
      _serverUrl = savedUrl;
      _cookie = savedCookie;
      _urlCtrl.text = savedUrl;
      if (savedUrl.isEmpty) {
        _tabIndex = 2; // Mở tab Kết nối nếu chưa nhập link
      }
    });
    _startPolling();
  }

  void _startPolling() {
    _timer?.cancel();
    _fetchStatus();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _fetchStatus());
  }

  String _normalizeUrl(String raw) {
    var u = raw.trim();
    if (u.endsWith('/')) u = u.substring(0, u.length - 1);
    if (u.isNotEmpty && !u.startsWith('http://') && !u.startsWith('https://')) {
      u = 'https://$u';
    }
    return u;
  }

  Map<String, String> _headers({bool jsonBody = false}) {
    final h = <String, String>{};
    if (_cookie.isNotEmpty) h['Cookie'] = _cookie;
    if (jsonBody) h['Content-Type'] = 'application/json';
    return h;
  }

  Future<void> _saveCookieFromResponse(http.Response res) async {
    final raw = res.headers['set-cookie'];
    if (raw != null && raw.isNotEmpty) {
      final sessionPart = raw.split(';').first.trim();
      if (sessionPart.isNotEmpty && sessionPart != _cookie) {
        _cookie = sessionPart;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('session_cookie', _cookie);
      }
    }
  }

  Future<void> _fetchStatus() async {
    if (_serverUrl.isEmpty) return;
    try {
      final res = await http
          .get(Uri.parse('$_serverUrl/status'), headers: _headers())
          .timeout(const Duration(seconds: 3));
      await _saveCookieFromResponse(res);

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        if (!mounted) return;
        setState(() {
          _state = data;
          _serverOnline = true;
          _connError = '';
          if (!_thresholdsLoaded) {
            _dTempCtrl.text = '${data['day_temp'] ?? 32}';
            _dHumiCtrl.text = '${data['day_humi'] ?? 70}';
            _dHeatCtrl.text = '${data['day_heater'] ?? 18}';
            _nTempCtrl.text = '${data['night_temp'] ?? 28}';
            _nHumiCtrl.text = '${data['night_humi'] ?? 80}';
            _nHeatCtrl.text = '${data['night_heater'] ?? 22}';
            _thresholdsLoaded = true;
          }
        });
      } else if (res.statusCode == 401) {
        if (!mounted) return;
        setState(() {
          _serverOnline = false;
          _connError = 'Cần đăng nhập hoặc link QR có mã (?t=...)';
        });
      } else {
        if (!mounted) return;
        setState(() {
          _serverOnline = false;
          _connError = 'Máy chủ trả về lỗi HTTP ${res.statusCode}';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _serverOnline = false;
        _connError = 'Mất kết nối tới máy chủ (Kiểm tra Wi-Fi/4G hoặc PC)';
      });
    }
  }

  Future<void> _sendControl(String action) async {
    if (_serverUrl.isEmpty) return;
    try {
      final res = await http
          .post(
            Uri.parse('$_serverUrl/control'),
            headers: _headers(jsonBody: true),
            body: jsonEncode({'action': action}),
          )
          .timeout(const Duration(seconds: 4));
      await _saveCookieFromResponse(res);
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (res.statusCode == 200 && body['success'] == true) {
        _showSnack('Đã gửi lệnh: $action', isError: false);
        _fetchStatus();
      } else {
        _showSnack(body['error']?.toString() ?? 'Không có quyền thực hiện!', isError: true);
      }
    } catch (e) {
      _showSnack('Không kết nối được máy chủ!', isError: true);
    }
  }

  Future<void> _saveThresholds() async {
    if (_serverUrl.isEmpty) return;
    try {
      final payload = {
        'day_temp': double.tryParse(_dTempCtrl.text) ?? 32.0,
        'day_humi': double.tryParse(_dHumiCtrl.text) ?? 70.0,
        'day_heater': double.tryParse(_dHeatCtrl.text) ?? 18.0,
        'night_temp': double.tryParse(_nTempCtrl.text) ?? 28.0,
        'night_humi': double.tryParse(_nHumiCtrl.text) ?? 80.0,
        'night_heater': double.tryParse(_nHeatCtrl.text) ?? 22.0,
      };
      final res = await http
          .post(
            Uri.parse('$_serverUrl/update_settings'),
            headers: _headers(jsonBody: true),
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 4));
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (res.statusCode == 200 && body['success'] == true) {
        _showSnack('Đã lưu ngưỡng Ngày / Đêm!', isError: false);
        _fetchStatus();
      } else {
        _showSnack(body['error']?.toString() ?? 'Lỗi lưu ngưỡng!', isError: true);
      }
    } catch (e) {
      _showSnack('Không kết nối được máy chủ!', isError: true);
    }
  }

  Future<void> _connectServer() async {
    final url = _normalizeUrl(_urlCtrl.text);
    if (url.isEmpty) {
      _showSnack('Vui lòng nhập link máy chủ!', isError: true);
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('server_url', url);
    setState(() {
      _serverUrl = url;
      _thresholdsLoaded = false;
    });

    // Nếu link có /join?t=... thì gọi để nhận session cookie khách
    if (url.contains('/join')) {
      try {
        final uri = Uri.parse(url);
        final res = await http.get(uri).timeout(const Duration(seconds: 4));
        await _saveCookieFromResponse(res);
        final base = '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
        await prefs.setString('server_url', base);
        setState(() {
          _serverUrl = base;
          _urlCtrl.text = base;
        });
      } catch (_) {}
    }

    await _fetchStatus();
    if (_serverOnline && mounted) {
      setState(() => _tabIndex = 0);
      _showSnack('Đã kết nối thành công!', isError: false);
    }
  }

  Future<void> _loginAdmin() async {
    if (_serverUrl.isEmpty) {
      _showSnack('Hãy nhập link máy chủ trước!', isError: true);
      return;
    }
    try {
      final res = await http.post(
        Uri.parse('$_serverUrl/login'),
        headers: _headers(),
        body: {
          'username': _userCtrl.text.trim(),
          'password': _passCtrl.text,
        },
      ).timeout(const Duration(seconds: 4));
      await _saveCookieFromResponse(res);
      if (res.statusCode == 302 || res.statusCode == 200) {
        _passCtrl.clear();
        await _fetchStatus();
        _showSnack('Đăng nhập thành công (${_state['current_role'] ?? ''})', isError: false);
      } else {
        _showSnack('Sai tên đăng nhập hoặc mật khẩu!', isError: true);
      }
    } catch (e) {
      _showSnack('Không kết nối được máy chủ!', isError: true);
    }
  }

  void _showSnack(String msg, {required bool isError}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? Colors.red.shade700 : Colors.green.shade700,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Smart Farm Pro', style: TextStyle(fontWeight: FontWeight.w800)),
        backgroundColor: const Color(0xFF0F172A),
        foregroundColor: Colors.white,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Chip(
              backgroundColor: _serverOnline ? Colors.green.shade700 : Colors.red.shade700,
              label: Text(
                _serverOnline ? 'ONLINE' : 'OFFLINE',
                style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
      body: IndexedStack(
        index: _tabIndex,
        children: [
          _buildDashboardTab(),
          _buildThresholdsTab(),
          _buildConnectionTab(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (i) => setState(() => _tabIndex = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.dashboard), label: 'Điều Khiển'),
          NavigationDestination(icon: Icon(Icons.tune), label: 'Ngưỡng'),
          NavigationDestination(icon: Icon(Icons.link), label: 'Kết Nối'),
        ],
      ),
    );
  }

  Widget _buildDashboardTab() {
    final temp = (_state['temp'] ?? 0.0).toString();
    final humi = (_state['humi'] ?? 0.0).toString();
    final vpd = (_state['vpd'] ?? 0.0).toString();
    final pidOut = (_state['pid_out'] ?? 0.0).toString();
    final mode = (_state['mode'] ?? 'AUTO').toString();
    final pumpOn = _state['pump'] == true;
    final heaterOn = _state['heater'] == true;
    final period = _state['current_period'] == 'DAY' ? 'BAN NGÀY' : 'BAN ĐÊM';
    final hwStatus = _state['conn_status'] == 'OK';

    return RefreshIndicator(
      onRefresh: _fetchStatus,
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          if (!_serverOnline)
            Container(
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.red.shade200),
              ),
              child: Row(
                children: [
                  const Icon(Icons.wifi_off, color: Colors.red),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _connError,
                      style: TextStyle(color: Colors.red.shade900, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          Row(
            children: [
              _kpiCard('NHIỆT ĐỘ', '$temp °C', Icons.thermostat, Colors.red),
              const SizedBox(width: 10),
              _kpiCard('ĐỘ ẨM', '$humi %', Icons.water_drop, Colors.blue),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _kpiCard('CHỈ SỐ VPD', '$vpd kPa', Icons.air, Colors.green),
              const SizedBox(width: 10),
              _kpiCard('PID SƯỞI', '$pidOut %', Icons.bolt, Colors.orange),
            ],
          ),
          const SizedBox(height: 12),
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('CHẾ ĐỘ ĐIỀU KHIỂN', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                      Text(
                        '$period • ${hwStatus ? "Cảm biến OK" : "Lỗi RS-485"}',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: hwStatus ? Colors.green : Colors.red),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () => _sendControl('AUTO'),
                          icon: const Icon(Icons.auto_awesome),
                          label: const Text('AUTO'),
                          style: FilledButton.styleFrom(
                            backgroundColor: mode == 'AUTO' ? const Color(0xFF0EA5E9) : Colors.grey.shade400,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () => _sendControl('MANUAL'),
                          icon: const Icon(Icons.touch_app),
                          label: const Text('MANUAL'),
                          style: FilledButton.styleFrom(
                            backgroundColor: mode == 'MANUAL' ? const Color(0xFFF59E0B) : Colors.grey.shade400,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _actuatorTile('Bơm Phun Sương', pumpOn, 'PUMP_ON', 'PUMP_OFF', Icons.water),
                  const Divider(height: 20),
                  _actuatorTile('Máy Sưởi (NO3)', heaterOn, 'HEATER_ON', 'HEATER_OFF', Icons.local_fire_department),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _kpiCard(String title, String value, IconData icon, Color color) {
    return Expanded(
      child: Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(title, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.black54)),
                  Icon(icon, color: color, size: 18),
                ],
              ),
              const SizedBox(height: 8),
              Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _actuatorTile(String name, bool isOn, String onAct, String offAct, IconData icon) {
    return Row(
      children: [
        CircleAvatar(
          backgroundColor: isOn ? Colors.green.shade100 : Colors.grey.shade200,
          child: Icon(icon, color: isOn ? Colors.green.shade700 : Colors.grey.shade600),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
              Text(
                isOn ? 'ĐANG BẬT' : 'ĐANG TẮT',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12, color: isOn ? Colors.green : Colors.red),
              ),
            ],
          ),
        ),
        FilledButton(
          onPressed: () => _sendControl(onAct),
          style: FilledButton.styleFrom(backgroundColor: Colors.green, minimumSize: const Size(64, 40)),
          child: const Text('BẬT'),
        ),
        const SizedBox(width: 6),
        FilledButton(
          onPressed: () => _sendControl(offAct),
          style: FilledButton.styleFrom(backgroundColor: Colors.red, minimumSize: const Size(64, 40)),
          child: const Text('TẮT'),
        ),
      ],
    );
  }

  Widget _buildThresholdsTab() {
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        Card(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('☀️ BAN NGÀY (06:00 - 18:00)', style: TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 10),
                _numField('Nhiệt độ bật bơm (°C)', _dTempCtrl),
                _numField('Độ ẩm bật bơm (%)', _dHumiCtrl),
                _numField('Nhiệt độ sưởi PID (°C)', _dHeatCtrl),
                const SizedBox(height: 14),
                const Text('🌙 BAN ĐÊM (18:00 - 06:00)', style: TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 10),
                _numField('Nhiệt độ bật bơm (°C)', _nTempCtrl),
                _numField('Độ ẩm bật bơm (%)', _nHumiCtrl),
                _numField('Nhiệt độ sưởi PID (°C)', _nHeatCtrl),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _saveThresholds,
                    icon: const Icon(Icons.save),
                    label: const Text('LƯU NGƯỠNG TỰ ĐỘNG'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _numField(String label, TextEditingController ctrl) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: ctrl,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }

  Widget _buildConnectionTab() {
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        Card(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Địa chỉ Máy Chủ Smart Farm', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                const SizedBox(height: 6),
                const Text(
                  'Dán link https://...trycloudflare.com (hoặc http://IP:8000 khi cùng Wi-Fi)',
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _urlCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Server URL',
                    hintText: 'https://xxxx.trycloudflare.com',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _connectServer,
                    icon: const Icon(Icons.wifi),
                    label: const Text('KẾT NỐI MÁY CHỦ'),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Tài khoản hiện tại: ${_state['current_user'] ?? 'Chưa kết nối'} (${_state['current_role'] ?? '-'})',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _userCtrl,
                  decoration: const InputDecoration(labelText: 'Tên đăng nhập', border: OutlineInputBorder(), isDense: true),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _passCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Mật khẩu', border: OutlineInputBorder(), isDense: true),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _loginAdmin,
                    icon: const Icon(Icons.login),
                    label: const Text('ĐĂNG NHẬP TÀI KHOẢN'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
