import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_user.dart';
import '../models/appointment.dart';
import '../models/notification_item.dart';
import '../models/patient.dart';

class StorageService {
  StorageService._();
  static final instance = StorageService._();
  late final SharedPreferences _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    if (!(_prefs.getBool('seeded') ?? false)) {
      await _seed();
    }
    if (!(_prefs.getBool('legacyDemoDataRemoved') ?? false)) {
      await _removeLegacyDemoData();
    }
  }

  bool get onboardingCompleted =>
      _prefs.getBool('onboardingCompleted') ?? false;
  Future<void> setOnboardingCompleted() =>
      _prefs.setBool('onboardingCompleted', true);
  String? get loggedInUserId => _prefs.getString('loggedInUserId');
  Future<void> setLoggedInUserId(String? id) async => id == null
      ? _prefs.remove('loggedInUserId')
      : _prefs.setString('loggedInUserId', id);
  String get rememberedEmail => _prefs.getString('rememberedEmail') ?? '';
  String get rememberedPassword => _prefs.getString('rememberedPassword') ?? '';
  String get geminiApiKey => _prefs.getString('geminiApiKey') ?? '';
  Future<void> setGeminiApiKey(String value) =>
      _prefs.setString('geminiApiKey', value.trim());
  Future<void> clearGeminiApiKey() => _prefs.remove('geminiApiKey');

  Future<void> remember(String email, String password) async {
    await _prefs.setString('rememberedEmail', email);
    await _prefs.setString('rememberedPassword', password);
  }

  List<AppUser> getUsers() => _readList('users').map(AppUser.fromJson).toList();
  List<Patient> getPatients() =>
      _readList('patients').map(Patient.fromJson).toList();
  List<Appointment> getAppointments() =>
      _readList('appointments').map(Appointment.fromJson).toList();
  List<NotificationItem> getNotifications() =>
      _readList('notifications').map(NotificationItem.fromJson).toList();
  Future<void> saveUsers(List<AppUser> value) =>
      _writeList('users', value.map((e) => e.toJson()).toList());
  Future<void> savePatients(List<Patient> value) =>
      _writeList('patients', value.map((e) => e.toJson()).toList());
  Future<void> saveAppointments(List<Appointment> value) =>
      _writeList('appointments', value.map((e) => e.toJson()).toList());
  Future<void> saveNotifications(List<NotificationItem> value) =>
      _writeList('notifications', value.map((e) => e.toJson()).toList());

  List<Map<String, dynamic>> _readList(String key) {
    final raw = _prefs.getString(key);
    if (raw == null || raw.isEmpty) return [];
    return List<Map<String, dynamic>>.from(
      jsonDecode(raw).map((e) => Map<String, dynamic>.from(e)),
    );
  }

  Future<void> _writeList(String key, List<Map<String, dynamic>> value) =>
      _prefs.setString(key, jsonEncode(value));

  Future<void> _seed() async {
    await saveUsers([]);
    await savePatients([]);
    await saveAppointments([]);
    await saveNotifications([]);
    await _prefs.setBool('seeded', true);
  }

  Future<void> _removeLegacyDemoData() async {
    final users = getUsers()
        .where((u) => !{'doctor-demo', 'patient-demo'}.contains(u.id))
        .toList();
    final patients = getPatients()
        .where((p) => !{'p1', 'p2', 'p3'}.contains(p.id))
        .toList();
    final appointments = getAppointments()
        .where((a) => !{'a1', 'a2', 'a3'}.contains(a.id))
        .toList();
    final notifications = getNotifications()
        .where((n) => !{'n1', 'n2', 'n3'}.contains(n.id))
        .toList();
    await saveUsers(users);
    await savePatients(patients);
    await saveAppointments(appointments);
    await saveNotifications(notifications);
    if ({'doctor-demo', 'patient-demo'}.contains(loggedInUserId)) {
      await setLoggedInUserId(null);
    }
    if (rememberedEmail.endsWith('@meditrack.local')) {
      await _prefs.remove('rememberedEmail');
      await _prefs.remove('rememberedPassword');
    }
    await _prefs.setBool('legacyDemoDataRemoved', true);
  }
}
