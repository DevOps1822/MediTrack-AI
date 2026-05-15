import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/app_user.dart';
import '../models/appointment.dart';
import '../models/notification_item.dart';
import '../models/patient.dart';

class FirestoreService {
  FirestoreService._();
  static final instance = FirestoreService._();
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _users =>
      _db.collection('users');
  CollectionReference<Map<String, dynamic>> get _patients =>
      _db.collection('patients');
  CollectionReference<Map<String, dynamic>> get _appointments =>
      _db.collection('appointments');
  CollectionReference<Map<String, dynamic>> get _notifications =>
      _db.collection('notifications');

  Future<List<AppUser>> getUsers() async {
    final snapshot = await _users.get();
    return snapshot.docs.map((doc) => AppUser.fromJson(doc.data())).toList();
  }

  Future<List<AppUser>> getDoctorUsers() async {
    final snapshot = await _users.where('role', isEqualTo: 'Doctor').get();
    return snapshot.docs.map((doc) => AppUser.fromJson(doc.data())).toList();
  }

  Future<List<Patient>> getPatients() async {
    final snapshot = await _patients.get();
    return snapshot.docs.map((doc) => Patient.fromJson(doc.data())).toList();
  }

  Stream<List<Patient>> watchPatients() => _patients.snapshots().map(
    (snapshot) =>
        snapshot.docs.map((doc) => Patient.fromJson(doc.data())).toList(),
  );

  Future<List<Patient>> getPatientsForUser(String userId) async {
    final snapshot = await _patients
        .where('linkedPatientUserId', isEqualTo: userId)
        .get();
    return snapshot.docs.map((doc) => Patient.fromJson(doc.data())).toList();
  }

  Stream<List<Patient>> watchPatientsForUser(String userId) => _patients
      .where('linkedPatientUserId', isEqualTo: userId)
      .snapshots()
      .map(
        (snapshot) =>
            snapshot.docs.map((doc) => Patient.fromJson(doc.data())).toList(),
      );

  Future<List<Patient>> getPatientsByEmail(String email) async {
    if (email.trim().isEmpty) return [];
    final snapshot = await _patients
        .where('email', isEqualTo: email.trim())
        .get();
    return snapshot.docs.map((doc) => Patient.fromJson(doc.data())).toList();
  }

  Future<List<Patient>> getPatientsByPhone(String phone) async {
    if (phone.trim().isEmpty) return [];
    final normalized = phone.replaceAll(RegExp(r'\D'), '');
    final snapshot = await _patients
        .where('phoneNormalized', isEqualTo: normalized)
        .get();
    return snapshot.docs.map((doc) => Patient.fromJson(doc.data())).toList();
  }

  Future<List<Appointment>> getAppointments() async {
    final snapshot = await _appointments.get();
    return snapshot.docs
        .map((doc) => Appointment.fromJson(doc.data()))
        .toList();
  }

  Stream<List<Appointment>> watchAppointments() =>
      _appointments.snapshots().map(
        (snapshot) => snapshot.docs
            .map((doc) => Appointment.fromJson(doc.data()))
            .toList(),
      );

  Future<List<Appointment>> getAppointmentsForUser(String userId) async {
    final snapshot = await _appointments
        .where('patientUserId', isEqualTo: userId)
        .get();
    return snapshot.docs
        .map((doc) => Appointment.fromJson(doc.data()))
        .toList();
  }

  Stream<List<Appointment>> watchAppointmentsForUser(String userId) =>
      _appointments
          .where('patientUserId', isEqualTo: userId)
          .snapshots()
          .map(
            (snapshot) => snapshot.docs
                .map((doc) => Appointment.fromJson(doc.data()))
                .toList(),
          );

  Future<List<NotificationItem>> getNotifications() async {
    final snapshot = await _notifications.get();
    return snapshot.docs
        .map((doc) => NotificationItem.fromJson(doc.data()))
        .toList();
  }

  Stream<List<NotificationItem>> watchNotifications() =>
      _notifications.snapshots().map(
        (snapshot) => snapshot.docs
            .map((doc) => NotificationItem.fromJson(doc.data()))
            .toList(),
      );

  Future<List<NotificationItem>> getNotificationsFor({
    required String userId,
    required String role,
  }) async {
    final byUser = await _notifications
        .where('userId', isEqualTo: userId)
        .get();
    final byRole = await _notifications
        .where('userRole', isEqualTo: role)
        .get();
    final items = {
      for (final doc in [...byUser.docs, ...byRole.docs])
        doc.id: NotificationItem.fromJson(doc.data()),
    };
    return items.values.toList();
  }

  Future<AppUser?> getUserById(String id) async {
    final doc = await _users.doc(id).get();
    if (!doc.exists || doc.data() == null) return null;
    return AppUser.fromJson(doc.data()!);
  }

  Future<AppUser?> getUserByEmail(String email) async {
    final snapshot = await _users
        .where('email', isEqualTo: email.trim())
        .limit(1)
        .get();
    if (snapshot.docs.isEmpty) return null;
    return AppUser.fromJson(snapshot.docs.first.data());
  }

  Future<void> saveUser(AppUser user) => _users.doc(user.id).set(user.toJson());

  Future<void> savePatient(Patient patient) =>
      _patients.doc(patient.id).set(patient.toJson());

  Future<void> deletePatient(String id) => _patients.doc(id).delete();

  Future<void> saveAppointment(Appointment appointment) =>
      _appointments.doc(appointment.id).set(appointment.toJson());

  Future<void> deleteAppointment(String id) => _appointments.doc(id).delete();

  Future<void> saveNotification(NotificationItem notification) =>
      _notifications.doc(notification.id).set(notification.toJson());

  Future<void> deleteNotification(String id) => _notifications.doc(id).delete();
}
