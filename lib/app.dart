import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import 'models/ai_models.dart';
import 'models/app_user.dart';
import 'models/appointment.dart';
import 'models/notification_item.dart';
import 'models/patient.dart';
import 'services/auth_service.dart';
import 'services/firestore_service.dart';
import 'services/gemini_service.dart';
import 'services/notification_service.dart';
import 'services/storage_service.dart';
import 'theme/app_colors.dart';
import 'theme/app_theme.dart';
import 'widgets/app_button.dart';
import 'widgets/app_card.dart';
import 'widgets/app_text_field.dart';
import 'widgets/confirmation_dialog.dart';
import 'widgets/empty_state.dart';
import 'widgets/priority_chip.dart';

final appState = AppState();

class MediTrackApp extends StatelessWidget {
  const MediTrackApp({super.key});

  @override
  Widget build(BuildContext context) {
    appState.load();
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'MediTrack',
      theme: AppTheme.light(),
      home: const SplashScreen(),
    );
  }
}

class AppState extends ChangeNotifier {
  final storage = StorageService.instance;
  final cloud = FirestoreService.instance;
  final auth = AuthService();
  final gemini = GeminiService();
  AppUser? user;
  List<AppUser> users = [];
  List<Patient> patients = [];
  List<Appointment> appointments = [];
  List<NotificationItem> notifications = [];
  final List<StreamSubscription<dynamic>> _cloudSubscriptions = [];
  final Set<String> _knownNotificationIds = {};

  void load() {
    users = storage.getUsers();
    patients = storage.getPatients();
    appointments = storage.getAppointments();
    notifications = storage.getNotifications();
    user = auth.currentUser();
  }

  void refresh() {
    load();
    notifyListeners();
  }

  Future<void> loadSharedData() async {
    final currentUser = await auth.currentUserAsync();
    if (currentUser == null) {
      user = null;
      notifyListeners();
      return;
    }
    if (currentUser.isDoctor) {
      users = await cloud.getUsers();
      patients = await cloud.getPatients();
      appointments = await cloud.getAppointments();
      notifications = await cloud.getNotifications();
    } else {
      final doctors = await cloud.getDoctorUsers();
      users = [currentUser, ...doctors];
      patients = await cloud.getPatientsForUser(currentUser.id);
      appointments = await cloud.getAppointmentsForUser(currentUser.id);
      notifications = await cloud.getNotificationsFor(
        userId: currentUser.id,
        role: currentUser.role,
      );
    }
    await storage.saveUsers(users);
    await storage.savePatients(patients);
    await storage.saveAppointments(appointments);
    await storage.saveNotifications(notifications);
    user =
        users.where((u) => u.id == currentUser.id).firstOrNull ?? currentUser;
    _knownNotificationIds
      ..clear()
      ..addAll(notifications.map((n) => n.id));
    await _startCloudSubscriptions(user!);
    notifyListeners();
  }

  List<NotificationItem> get myNotifications =>
      notifications.where((n) => _notificationTargetsUser(n, user)).toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  int get unreadCount => myNotifications.where((n) => !n.isRead).length;
  List<Appointment> get patientAppointments =>
      appointments
          .where((a) => user != null && a.patientUserId == user!.id)
          .toList()
        ..sort(sortAppointmentsNewestFirst);

  Future<void> persist() async {
    await storage.savePatients(patients);
    await storage.saveAppointments(appointments);
    await storage.saveNotifications(notifications);
    await storage.saveUsers(users);
    for (final value in users) {
      await cloud.saveUser(value);
    }
    for (final value in patients) {
      await cloud.savePatient(value);
    }
    for (final value in appointments) {
      await cloud.saveAppointment(value);
    }
    for (final value in notifications) {
      await cloud.saveNotification(value);
    }
    notifyListeners();
  }

  Future<void> setUser(AppUser value) async {
    user = value;
    await loadSharedData();
    notifyListeners();
  }

  Future<void> logout() async {
    await _cancelCloudSubscriptions();
    await auth.logout();
    user = null;
    _knownNotificationIds.clear();
    notifyListeners();
  }

  Future<void> _cancelCloudSubscriptions() async {
    for (final subscription in _cloudSubscriptions) {
      await subscription.cancel();
    }
    _cloudSubscriptions.clear();
  }

  Future<void> _startCloudSubscriptions(AppUser currentUser) async {
    await _cancelCloudSubscriptions();
    final patientStream = currentUser.isDoctor
        ? cloud.watchPatients()
        : cloud.watchPatientsForUser(currentUser.id);
    final appointmentStream = currentUser.isDoctor
        ? cloud.watchAppointments()
        : cloud.watchAppointmentsForUser(currentUser.id);

    _cloudSubscriptions.addAll([
      patientStream.listen((value) async {
        patients = value;
        await storage.savePatients(patients);
        notifyListeners();
      }),
      appointmentStream.listen((value) async {
        appointments = value;
        await storage.saveAppointments(appointments);
        notifyListeners();
      }),
      cloud.watchNotifications().listen((value) async {
        final filtered = value
            .where((n) => _notificationTargetsUser(n, currentUser))
            .toList();
        final newNotifications = filtered
            .where((n) => !_knownNotificationIds.contains(n.id))
            .toList();
        notifications = filtered;
        _knownNotificationIds
          ..clear()
          ..addAll(filtered.map((n) => n.id));
        await storage.saveNotifications(notifications);
        for (final notification in newNotifications) {
          await NotificationService.instance.show(
            notification.title,
            notification.message,
          );
        }
        notifyListeners();
      }),
    ]);
  }

  bool _shouldShowLocalNotification(NotificationItem item) =>
      _notificationTargetsUser(item, user);

  bool _notificationTargetsUser(NotificationItem item, AppUser? target) {
    if (target == null) return false;
    if (item.userId == target.id) return true;
    final broadcastId = item.userRole.toLowerCase();
    final isRoleBroadcast =
        item.userId.trim().isEmpty || item.userId.toLowerCase() == broadcastId;
    return isRoleBroadcast && item.userRole == target.role;
  }

  Future<void> addNotification(
    NotificationItem item, {
    bool push = true,
  }) async {
    notifications.add(item);
    _knownNotificationIds.add(item.id);
    notifyListeners();
    await storage.saveNotifications(notifications);
    await cloud.saveNotification(item);
    if (push && _shouldShowLocalNotification(item)) {
      await NotificationService.instance.show(item.title, item.message);
    }
    notifyListeners();
  }

  Future<void> notifyAllDoctors({
    required String title,
    required String message,
    required String type,
    bool push = true,
  }) async {
    final doctors = users.where((u) => u.isDoctor).toList();
    final created = <NotificationItem>[];
    if (doctors.isEmpty) {
      created.add(
        NotificationItem(
          id: id(),
          userRole: 'Doctor',
          userId: 'doctor',
          title: title,
          message: message,
          type: type,
        ),
      );
    } else {
      for (final doctor in doctors) {
        created.add(
          NotificationItem(
            id: id(),
            userRole: 'Doctor',
            userId: doctor.id,
            title: title,
            message: message,
            type: type,
          ),
        );
      }
    }
    notifications.addAll(created);
    _knownNotificationIds.addAll(created.map((n) => n.id));
    notifyListeners();
    await storage.saveNotifications(notifications);
    for (final notification in created) {
      await cloud.saveNotification(notification);
    }
    if (push && created.any(_shouldShowLocalNotification)) {
      await NotificationService.instance.show(title, message);
    }
    notifyListeners();
  }

  Future<void> savePatient(Patient patient) async {
    final index = patients.indexWhere((p) => p.id == patient.id);
    patient.updatedAt = DateTime.now();
    if (index >= 0) {
      patients[index] = patient;
    } else {
      patients.add(patient);
    }
    await storage.savePatients(patients);
    await cloud.savePatient(patient);
    notifyListeners();
  }

  Future<int> syncPatientAccountRecord(AppUser patientUser) async {
    if (patientUser.isDoctor) return 0;
    var linked = 0;
    final cloudCandidates = [
      ...await cloud.getPatientsByEmail(patientUser.email),
      ...await cloud.getPatientsByPhone(patientUser.phone),
    ];
    for (final candidate in cloudCandidates) {
      if (!patients.any((p) => p.id == candidate.id)) {
        patients.add(candidate);
      }
    }
    final existingLinked = patients.any(
      (patient) => patient.linkedPatientUserId == patientUser.id,
    );
    for (final patient in patients.where(
      (patient) => patient.linkedPatientUserId == patientUser.id,
    )) {
      patient.name = patientUser.name;
      patient.age = patientUser.age ?? patient.age;
      patient.gender = patientUser.gender ?? patient.gender;
      patient.phone = patientUser.phone;
      patient.email = patientUser.email;
      patient.medicalHistory =
          patientUser.medicalHistory ?? patient.medicalHistory;
      patient.updatedAt = DateTime.now();
      linked++;
    }
    for (final patient in patients) {
      final phoneMatches =
          normalizedPhone(patient.phone).isNotEmpty &&
          normalizedPhone(patient.phone) == normalizedPhone(patientUser.phone);
      final emailMatches =
          (patient.email ?? '').trim().isNotEmpty &&
          patient.email!.trim().toLowerCase() ==
              patientUser.email.toLowerCase();
      if (patient.linkedPatientUserId == null &&
          (phoneMatches || emailMatches)) {
        patient.linkedPatientUserId = patientUser.id;
        linked++;
      }
    }
    if (linked == 0 && !existingLinked) {
      patients.add(
        Patient(
          id: id(),
          name: patientUser.name,
          age: patientUser.age ?? 1,
          gender: patientUser.gender ?? 'Other',
          phone: patientUser.phone,
          email: patientUser.email,
          disease: 'Not specified',
          symptoms: 'No symptoms recorded yet.',
          medicalHistory: patientUser.medicalHistory ?? '',
          doctorNotes:
              'Patient registered from the mobile app. Doctor can complete this medical record after review.',
          priorityLevel: 'Low',
          linkedPatientUserId: patientUser.id,
        ),
      );
      linked++;
    }
    if (linked > 0) {
      await storage.savePatients(patients);
      for (final patient in patients.where(
        (patient) => patient.linkedPatientUserId == patientUser.id,
      )) {
        await cloud.savePatient(patient);
      }
      notifyListeners();
    }
    return linked;
  }

  Future<void> deletePatient(Patient patient) async {
    patients.removeWhere((p) => p.id == patient.id);
    await storage.savePatients(patients);
    await cloud.deletePatient(patient.id);
    notifyListeners();
  }

  Future<void> requestAppointment(Appointment appointment) async {
    appointments.add(appointment);
    notifyListeners();
    await syncPatientRecordFromAppointment(appointment);
    await storage.saveAppointments(appointments);
    await cloud.saveAppointment(appointment);
    await notifyAllDoctors(
      title: 'New appointment request',
      message: 'New appointment request from ${appointment.patientName}.',
      type: 'appointment',
    );
  }

  Future<void> editAppointmentRequest(Appointment updated) async {
    final index = appointments.indexWhere((a) => a.id == updated.id);
    if (index >= 0) {
      appointments[index] = updated;
      notifyListeners();
      await syncPatientRecordFromAppointment(updated);
      await storage.saveAppointments(appointments);
      await cloud.saveAppointment(updated);
      await notifyAllDoctors(
        title: 'Appointment request updated',
        message: '${updated.patientName} updated an appointment request.',
        type: 'appointment',
      );
      notifyListeners();
    }
  }

  Future<void> deleteAppointmentRequest(Appointment appointment) async {
    appointments.removeWhere((a) => a.id == appointment.id);
    notifyListeners();
    await storage.saveAppointments(appointments);
    await cloud.deleteAppointment(appointment.id);
    await notifyAllDoctors(
      title: 'Appointment request deleted',
      message: '${appointment.patientName} deleted an appointment request.',
      type: 'appointment',
    );
    notifyListeners();
  }

  Future<void> syncPatientRecordFromAppointment(Appointment appointment) async {
    final patientUser = users
        .where((u) => u.id == appointment.patientUserId && !u.isDoctor)
        .firstOrNull;
    if (patientUser != null) await syncPatientAccountRecord(patientUser);

    final index = patients.indexWhere(
      (p) => p.linkedPatientUserId == appointment.patientUserId,
    );
    if (index < 0) return;

    final patient = patients[index];
    patient.name = appointment.patientName;
    patient.symptoms = appointment.symptoms;
    if ((appointment.disease ?? '').trim().isNotEmpty) {
      patient.disease = appointment.disease!.trim();
    }
    if (appointment.priorityLevel != null) {
      patient.priorityLevel = appointment.priorityLevel!;
      patient.priorityReason = appointment.priorityReason;
    }
    patient.nextAppointmentDate = appointment.date;
    patient.updatedAt = DateTime.now();
    await storage.savePatients(patients);
    await cloud.savePatient(patient);
  }

  Future<void> updateAppointment(Appointment appointment, String status) async {
    final index = appointments.indexWhere((a) => a.id == appointment.id);
    if (index >= 0) {
      appointments[index].status = status;
    } else {
      appointment.status = status;
      appointments.add(appointment);
    }
    notifyListeners();
    await storage.saveAppointments(appointments);
    await cloud.saveAppointment(index >= 0 ? appointments[index] : appointment);
    await addNotification(
      NotificationItem(
        id: id(),
        userRole: 'Patient',
        userId: appointment.patientUserId,
        title: 'Appointment ${status == 'accepted' ? 'accepted' : 'rejected'}',
        message: 'Your appointment has been $status.',
        type: 'appointment',
      ),
    );
  }

  Future<void> rescheduleAppointment(
    Appointment appointment,
    DateTime newDate,
    String newTime,
  ) async {
    final index = appointments.indexWhere((a) => a.id == appointment.id);
    final target = index >= 0 ? appointments[index] : appointment;
    target.date = newDate;
    target.time = newTime;
    target.status = 'rescheduled';
    if (index < 0) appointments.add(target);
    notifyListeners();
    await storage.saveAppointments(appointments);
    await cloud.saveAppointment(target);
    await addNotification(
      NotificationItem(
        id: id(),
        userRole: 'Patient',
        userId: target.patientUserId,
        title: 'Appointment rescheduled',
        message:
            'Your appointment has been rescheduled to ${fmt(newDate)} at $newTime.',
        type: 'appointment',
      ),
    );
  }
}

String id() => DateTime.now().microsecondsSinceEpoch.toString();
String normalizedPhone(String value) => value.replaceAll(RegExp(r'\D'), '');
String fmt(DateTime? date) =>
    date == null ? 'Not set' : DateFormat('MMM d, yyyy').format(date);
String visitDateLabel(DateTime? date) =>
    date == null ? 'Not recorded' : fmt(date);
String statusLabel(String status) =>
    status.isEmpty ? 'Pending' : status[0].toUpperCase() + status.substring(1);
int sortAppointmentsNewestFirst(Appointment a, Appointment b) =>
    b.createdAt.compareTo(a.createdAt);

String greeting() {
  final h = DateTime.now().hour;
  if (h < 5) return 'Good Night';
  if (h < 12) return 'Good Morning';
  if (h < 17) return 'Good Afternoon';
  if (h < 21) return 'Good Evening';
  return 'Good Night';
}

void go(
  BuildContext context,
  Widget page, {
  bool replace = false,
  bool clear = false,
}) {
  final route = MaterialPageRoute(builder: (_) => page);
  if (clear) {
    Navigator.pushAndRemoveUntil(context, route, (_) => false);
  } else if (replace) {
    Navigator.pushReplacement(context, route);
  } else {
    Navigator.push(context, route);
  }
}

void toast(BuildContext context, String message) => ScaffoldMessenger.of(
  context,
).showSnackBar(SnackBar(content: Text(message)));

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..forward();
  late final Animation<double> scale = CurvedAnimation(
    parent: c,
    curve: Curves.easeOutBack,
  );

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 1600), () {
      if (!mounted) return;
      () async {
        await appState.loadSharedData();
        if (!mounted) return;
        if (!StorageService.instance.onboardingCompleted) {
          go(context, const OnboardingScreen(), clear: true);
        } else if (appState.user != null) {
          go(
            context,
            appState.user!.isDoctor
                ? const DoctorShell()
                : const PatientShell(),
            clear: true,
          );
        } else {
          go(context, const RoleSelectionScreen(), clear: true);
        }
      }();
    });
  }

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [AppColors.primaryDark, AppColors.primary, AppColors.accent],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: ScaleTransition(
          scale: scale,
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Logo(size: 92, light: true),
              SizedBox(height: 18),
              Text(
                'MediTrack',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 34,
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(height: 8),
              Text(
                'Smart Patient Management',
                style: TextStyle(color: Colors.white70, fontSize: 16),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _Logo extends StatelessWidget {
  const _Logo({this.size = 54, this.light = false});
  final double size;
  final bool light;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: light
          ? Colors.white.withValues(alpha: .18)
          : AppColors.primary.withValues(alpha: .1),
      borderRadius: BorderRadius.circular(size / 3),
      border: Border.all(color: light ? Colors.white30 : AppColors.border),
    ),
    child: Icon(
      Icons.health_and_safety_rounded,
      color: light ? Colors.white : AppColors.primary,
      size: size * .55,
    ),
  );
}

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final controller = PageController();
  int page = 0;
  final data = const [
    (
      Icons.folder_shared_rounded,
      'Manage patient records digitally.',
      'Keep histories, visits, notes, and priority levels organized in one clean workspace.',
    ),
    (
      Icons.auto_awesome_rounded,
      'AI summaries and follow-up support.',
      'Generate patient summaries, appointment priority suggestions, and follow-up reminders.',
    ),
    (
      Icons.notifications_active_rounded,
      'Appointment notifications for everyone.',
      'Patients can request appointments while doctors accept, reject, and track requests.',
    ),
  ];

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Expanded(
              child: PageView.builder(
                controller: controller,
                onPageChanged: (v) => setState(() => page = v),
                itemCount: data.length,
                itemBuilder: (_, i) => Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 150,
                      height: 150,
                      decoration: BoxDecoration(
                        color: (i == 1 ? AppColors.accent : AppColors.primary)
                            .withValues(alpha: .1),
                        borderRadius: BorderRadius.circular(40),
                      ),
                      child: Icon(
                        data[i].$1,
                        size: 76,
                        color: i == 1 ? AppColors.accent : AppColors.primary,
                      ),
                    ),
                    const SizedBox(height: 36),
                    Text(
                      data[i].$2,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 27,
                        height: 1.15,
                        fontWeight: FontWeight.w700,
                        color: AppColors.text,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      data[i].$3,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 15,
                        height: 1.5,
                        color: AppColors.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(
                data.length,
                (i) => AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  margin: const EdgeInsets.all(4),
                  width: i == page ? 24 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: i == page ? AppColors.primary : AppColors.border,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            AppButton(
              label: page == 2 ? 'Get Started' : 'Next',
              onPressed: () async {
                if (page < 2) {
                  controller.nextPage(
                    duration: const Duration(milliseconds: 320),
                    curve: Curves.easeOut,
                  );
                } else {
                  await StorageService.instance.setOnboardingCompleted();
                  if (context.mounted) {
                    go(context, const RoleSelectionScreen(), clear: true);
                  }
                }
              },
            ),
          ],
        ),
      ),
    ),
  );
}

class RoleSelectionScreen extends StatefulWidget {
  const RoleSelectionScreen({super.key});
  @override
  State<RoleSelectionScreen> createState() => _RoleSelectionScreenState();
}

class _RoleSelectionScreenState extends State<RoleSelectionScreen> {
  String role = 'Patient';
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Choose Role')),
    body: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Continue as',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          const Text(
            'Select the workspace that matches your account.',
            style: TextStyle(color: AppColors.muted),
          ),
          const SizedBox(height: 28),
          _RoleCard(
            label: 'Doctor',
            subtitle: 'Manage patients, AI summaries, and requests',
            icon: Icons.medical_services_rounded,
            selected: role == 'Doctor',
            onTap: () => setState(() => role = 'Doctor'),
          ),
          const SizedBox(height: 14),
          _RoleCard(
            label: 'Patient',
            subtitle: 'Book appointments and view status updates',
            icon: Icons.person_rounded,
            selected: role == 'Patient',
            onTap: () => setState(() => role = 'Patient'),
          ),
          const Spacer(),
          AppButton(
            label: 'Continue',
            onPressed: () => go(context, LoginScreen(initialRole: role)),
          ),
        ],
      ),
    ),
  );
}

class _RoleCard extends StatelessWidget {
  const _RoleCard({
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final String subtitle;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => AppCard(
    onTap: onTap,
    child: Row(
      children: [
        CircleAvatar(
          radius: 28,
          backgroundColor: (selected ? AppColors.primary : AppColors.border)
              .withValues(alpha: .14),
          child: Icon(
            icon,
            color: selected ? AppColors.primary : AppColors.muted,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(subtitle, style: const TextStyle(color: AppColors.muted)),
            ],
          ),
        ),
        Icon(
          selected ? Icons.check_circle_rounded : Icons.circle_outlined,
          color: selected ? AppColors.primary : AppColors.border,
        ),
      ],
    ),
  );
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.initialRole});
  final String initialRole;
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final form = GlobalKey<FormState>();
  late String role = widget.initialRole;
  late final email = TextEditingController(
    text: StorageService.instance.rememberedEmail,
  );
  late final password = TextEditingController(
    text: StorageService.instance.rememberedPassword,
  );
  final code = TextEditingController();
  bool obscure = true;
  bool loading = false;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Login')),
    body: Form(
      key: form,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const _Logo(size: 64),
          const SizedBox(height: 18),
          const Text(
            'Welcome back',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 24),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'Patient', label: Text('Patient')),
              ButtonSegment(value: 'Doctor', label: Text('Doctor')),
            ],
            selected: {role},
            onSelectionChanged: (v) => setState(() => role = v.first),
          ),
          const SizedBox(height: 14),
          AppTextField(
            controller: email,
            label: 'Email',
            keyboardType: TextInputType.emailAddress,
            validator: emailValidator,
          ),
          const SizedBox(height: 14),
          AppTextField(
            controller: password,
            label: 'Password',
            obscureText: obscure,
            validator: passwordValidator,
            suffixIcon: IconButton(
              icon: Icon(
                obscure
                    ? Icons.visibility_rounded
                    : Icons.visibility_off_rounded,
              ),
              onPressed: () => setState(() => obscure = !obscure),
            ),
          ),
          if (role == 'Doctor') ...[
            const SizedBox(height: 14),
            AppTextField(
              controller: code,
              label: 'Doctor Code',
              validator: (v) => v == AuthService.doctorCode
                  ? null
                  : 'Invalid doctor access code.',
            ),
          ],
          const SizedBox(height: 24),
          AppButton(
            label: loading ? 'Logging in...' : 'Login',
            icon: loading ? Icons.hourglass_empty_rounded : null,
            onPressed: loading
                ? null
                : () async {
                    if (!form.currentState!.validate()) return;
                    setState(() => loading = true);
                    try {
                      final user = await appState.auth.login(
                        email: email.text.trim(),
                        password: password.text,
                        role: role,
                        code: code.text.trim(),
                      );
                      await appState.setUser(user);
                      if (context.mounted) {
                        go(
                          context,
                          user.isDoctor
                              ? const DoctorShell()
                              : const PatientShell(),
                          clear: true,
                        );
                      }
                    } catch (e) {
                      if (context.mounted) toast(context, e.toString());
                    } finally {
                      if (mounted) setState(() => loading = false);
                    }
                  },
          ),
          TextButton(
            onPressed: loading
                ? null
                : () => go(context, SignupScreen(initialRole: role)),
            child: const Text('Create Account'),
          ),
          if (role == 'Doctor')
            TextButton.icon(
              onPressed: loading
                  ? null
                  : () => go(context, const ApiKeySettingsScreen()),
              icon: const Icon(Icons.key_rounded),
              label: const Text('API Key Settings'),
            ),
        ],
      ),
    ),
  );
}

class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key, required this.initialRole});
  final String initialRole;
  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final form = GlobalKey<FormState>();
  late String role = widget.initialRole;
  String gender = 'Male';
  final name = TextEditingController(),
      email = TextEditingController(),
      password = TextEditingController(),
      confirmPassword = TextEditingController(),
      phone = TextEditingController(),
      medicalHistory = TextEditingController(),
      code = TextEditingController(),
      specialization = TextEditingController(),
      age = TextEditingController();
  bool loading = false;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Create Account')),
    body: Form(
      key: form,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'Patient', label: Text('Patient')),
              ButtonSegment(value: 'Doctor', label: Text('Doctor')),
            ],
            selected: {role},
            onSelectionChanged: (v) => setState(() => role = v.first),
          ),
          const SizedBox(height: 14),
          AppTextField(
            controller: name,
            label: 'Full Name',
            textCapitalization: TextCapitalization.words,
            validator: requiredValidator,
          ),
          const SizedBox(height: 14),
          AppTextField(
            controller: email,
            label: 'Email',
            keyboardType: TextInputType.emailAddress,
            validator: emailValidator,
          ),
          const SizedBox(height: 14),
          AppTextField(
            controller: password,
            label: 'Password',
            obscureText: true,
            validator: passwordValidator,
          ),
          const SizedBox(height: 14),
          AppTextField(
            controller: confirmPassword,
            label: 'Confirm Password',
            obscureText: true,
            validator: (v) =>
                v == password.text ? null : 'Passwords must match.',
          ),
          const SizedBox(height: 14),
          AppTextField(
            controller: phone,
            label: 'Phone Number',
            keyboardType: TextInputType.phone,
            validator: phoneValidator,
          ),
          if (role == 'Doctor') ...[
            const SizedBox(height: 14),
            AppTextField(
              controller: code,
              label: 'Doctor Code',
              validator: (v) => v == AuthService.doctorCode
                  ? null
                  : 'Invalid doctor access code.',
            ),
            const SizedBox(height: 14),
            AppTextField(
              controller: specialization,
              label: 'Specialization',
              textCapitalization: TextCapitalization.words,
              validator: requiredValidator,
            ),
          ] else ...[
            const SizedBox(height: 14),
            AppTextField(
              controller: age,
              label: 'Age',
              keyboardType: TextInputType.number,
              validator: ageValidator,
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField(
              initialValue: gender,
              decoration: const InputDecoration(labelText: 'Gender'),
              items: const [
                'Male',
                'Female',
                'Other',
              ].map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
              onChanged: (v) => gender = v!,
            ),
            const SizedBox(height: 14),
            AppTextField(
              controller: medicalHistory,
              label: 'Medical History optional',
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
            ),
          ],
          const SizedBox(height: 24),
          AppButton(
            label: loading ? 'Creating account...' : 'Create Account',
            icon: loading ? Icons.hourglass_empty_rounded : null,
            onPressed: loading
                ? null
                : () async {
                    if (!form.currentState!.validate()) return;
                    setState(() => loading = true);
                    final user = AppUser(
                      id: id(),
                      name: name.text.trim(),
                      email: email.text.trim(),
                      password: password.text,
                      phone: phone.text.trim(),
                      role: role,
                      doctorCodeVerified: role == 'Doctor',
                      specialization: specialization.text.trim().isEmpty
                          ? null
                          : specialization.text.trim(),
                      age: int.tryParse(age.text),
                      gender: role == 'Patient' ? gender : null,
                      medicalHistory: role == 'Patient'
                          ? (medicalHistory.text.trim().isEmpty
                                ? null
                                : medicalHistory.text.trim())
                          : null,
                    );
                    try {
                      final created = await appState.auth.signup(user);
                      await appState.setUser(created);
                      await appState.syncPatientAccountRecord(created);
                      if (context.mounted) {
                        go(
                          context,
                          created.isDoctor
                              ? const DoctorShell()
                              : const PatientShell(),
                          clear: true,
                        );
                      }
                    } catch (e) {
                      if (context.mounted) toast(context, e.toString());
                    } finally {
                      if (mounted) setState(() => loading = false);
                    }
                  },
          ),
          if (role == 'Doctor') ...[
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: loading
                  ? null
                  : () => go(context, const ApiKeySettingsScreen()),
              icon: const Icon(Icons.key_rounded),
              label: const Text('API Key Settings'),
            ),
          ],
        ],
      ),
    ),
  );
}

String? requiredValidator(String? v) =>
    v == null || v.trim().isEmpty ? 'This field is required.' : null;
String? emailValidator(String? v) =>
    requiredValidator(v) ??
    (RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v!.trim())
        ? null
        : 'Enter a valid email address.');
String? optionalEmailValidator(String? v) {
  if (v == null || v.trim().isEmpty) return null;
  return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v.trim())
      ? null
      : 'Enter a valid email address.';
}

String? passwordValidator(String? v) =>
    requiredValidator(v) ??
    (v!.length >= 6 ? null : 'Password must be at least 6 characters.');
String? phoneValidator(String? v) =>
    requiredValidator(v) ??
    (v!.trim().length >= 8 ? null : 'Enter a valid phone number.');
String? ageValidator(String? v) {
  final n = int.tryParse(v ?? '');
  return n == null || n < 1 || n > 120
      ? 'Enter an age between 1 and 120.'
      : null;
}

class DoctorShell extends StatefulWidget {
  const DoctorShell({super.key});
  @override
  State<DoctorShell> createState() => _DoctorShellState();
}

class _DoctorShellState extends State<DoctorShell> {
  int index = 0;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: appState,
    builder: (context, child) => Scaffold(
      body: [
        const DoctorDashboard(),
        const PatientListScreen(),
        const AppointmentRequestsScreen(),
        const NotificationsScreen(),
        const ProfileScreen(),
      ][index],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: index,
        onTap: (v) => setState(() => index = v),
        selectedFontSize: 11,
        unselectedFontSize: 10,
        items: [
          const BottomNavigationBarItem(
            icon: Icon(Icons.dashboard_rounded),
            label: 'Dashboard',
          ),
          const BottomNavigationBarItem(
            icon: Icon(Icons.group_rounded),
            label: 'Patients',
          ),
          const BottomNavigationBarItem(
            icon: Icon(Icons.event_note_rounded),
            label: 'Appts',
          ),
          BottomNavigationBarItem(
            icon: NavBadgeIcon(
              icon: Icons.notifications_rounded,
              count: appState.unreadCount,
            ),
            label: 'Alerts',
          ),
          const BottomNavigationBarItem(
            icon: Icon(Icons.person_rounded),
            label: 'Profile',
          ),
        ],
      ),
    ),
  );
}

class PatientShell extends StatefulWidget {
  const PatientShell({super.key});
  @override
  State<PatientShell> createState() => _PatientShellState();
}

class _PatientShellState extends State<PatientShell> {
  int index = 0;
  void openAppointmentsTab() => setState(() => index = 2);

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: appState,
    builder: (context, child) => Scaffold(
      body: [
        const PatientDashboard(),
        const AppointmentBookingScreen(),
        const MyAppointmentsScreen(),
        const NotificationsScreen(),
        const ProfileScreen(),
      ][index],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: index,
        onTap: (v) => setState(() => index = v),
        selectedFontSize: 11,
        unselectedFontSize: 10,
        items: [
          const BottomNavigationBarItem(
            icon: Icon(Icons.home_rounded),
            label: 'Home',
          ),
          const BottomNavigationBarItem(
            icon: Icon(Icons.add_circle_rounded),
            label: 'Book',
          ),
          const BottomNavigationBarItem(
            icon: Icon(Icons.calendar_month_rounded),
            label: 'Appts',
          ),
          BottomNavigationBarItem(
            icon: NavBadgeIcon(
              icon: Icons.notifications_rounded,
              count: appState.unreadCount,
            ),
            label: 'Alerts',
          ),
          const BottomNavigationBarItem(
            icon: Icon(Icons.person_rounded),
            label: 'Profile',
          ),
        ],
      ),
    ),
  );
}

void openPatientAppointmentsTab(BuildContext context) {
  final shell = context.findAncestorStateOfType<_PatientShellState>();
  if (shell != null) {
    shell.openAppointmentsTab();
  } else {
    go(context, const MyAppointmentsScreen(), replace: true);
  }
}

class NavBadgeIcon extends StatelessWidget {
  const NavBadgeIcon({super.key, required this.icon, required this.count});
  final IconData icon;
  final int count;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 30,
    height: 26,
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        Align(alignment: Alignment.center, child: Icon(icon)),
        if (count > 0)
          Positioned(
            right: 0,
            top: 0,
            child: Container(
              constraints: const BoxConstraints(minWidth: 8, minHeight: 8),
              padding: count > 9
                  ? const EdgeInsets.symmetric(horizontal: 4, vertical: 1)
                  : EdgeInsets.zero,
              decoration: BoxDecoration(
                color: AppColors.error,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: Colors.white, width: 1.5),
              ),
              child: count > 9
                  ? Text(
                      count > 99 ? '99+' : '$count',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 8,
                        fontWeight: FontWeight.w800,
                        height: 1,
                      ),
                    )
                  : const SizedBox(width: 8, height: 8),
            ),
          ),
      ],
    ),
  );
}

class DoctorDashboard extends StatelessWidget {
  const DoctorDashboard({super.key});
  @override
  Widget build(BuildContext context) {
    final u = appState.user!;
    final today = appState.appointments
        .where(
          (a) =>
              a.status == 'accepted' &&
              DateUtils.isSameDay(a.date, DateTime.now()),
        )
        .length;
    final pending = appState.appointments
        .where((a) => a.status == 'pending')
        .length;
    final urgent = appState.appointments
        .where((a) => a.priorityLevel == 'Urgent')
        .length;
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _TopBar(
            greetingText: greeting(),
            nameText: doctorDisplayName(u.name),
            subtitle: 'Here is your clinical overview',
          ),
          const SizedBox(height: 18),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 1.25,
            children: [
              _Metric(
                'Total Patients',
                '${appState.patients.length}',
                Icons.group_rounded,
                onTap: () => go(context, const PatientListScreen()),
              ),
              _Metric(
                "Today's Appointments",
                '$today',
                Icons.today_rounded,
                onTap: () => go(
                  context,
                  const AppointmentRequestsScreen(initialTab: 'accepted'),
                ),
              ),
              _Metric(
                'Pending Requests',
                '$pending',
                Icons.pending_actions_rounded,
                onTap: () => go(
                  context,
                  const AppointmentRequestsScreen(initialTab: 'pending'),
                ),
              ),
              _Metric(
                'Urgent Requests',
                '$urgent',
                Icons.warning_rounded,
                onTap: () => go(
                  context,
                  const AppointmentRequestsScreen(initialTab: 'urgent'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          const _AiInsight(),
          const SizedBox(height: 18),
          _SectionHeader(
            'Recent appointment requests',
            action: () => go(context, const AppointmentRequestsScreen()),
          ),
          ...([...appState.appointments]..sort(sortAppointmentsNewestFirst))
              .take(2)
              .map((a) => _AppointmentCard(a, doctorView: true)),
          const SizedBox(height: 18),
          _SectionHeader(
            'Recent patients',
            action: () => go(context, const PatientListScreen()),
          ),
          ...appState.patients.take(3).map((p) => _PatientCard(p)),
        ],
      ),
    );
  }
}

class PatientDashboard extends StatelessWidget {
  const PatientDashboard({super.key});
  @override
  Widget build(BuildContext context) {
    final upcomingAppointments =
        appState.patientAppointments
            .where((a) => a.status != 'rejected')
            .toList()
          ..sort((a, b) => a.date.compareTo(b.date));
    final upcoming = upcomingAppointments.firstOrNull;
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _TopBar(
            greetingText: 'Hello',
            nameText: appState.user!.name,
            subtitle: 'Care updates',
          ),
          const SizedBox(height: 18),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Upcoming Appointment',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                Text(
                  upcoming == null
                      ? 'No upcoming appointment yet.'
                      : '${fmt(upcoming.date)} - ${upcoming.time} - ${statusLabel(upcoming.status)}',
                  style: const TextStyle(color: AppColors.muted),
                ),
                const SizedBox(height: 14),
                AppButton(
                  label: 'Book Appointment',
                  icon: Icons.add_rounded,
                  onPressed: () =>
                      go(context, const AppointmentBookingScreen()),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Appointment Status',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          if (appState.patientAppointments.isEmpty)
            const EmptyState(
              icon: Icons.event_busy_rounded,
              title: 'No appointments',
              message: 'Book your first appointment request.',
            )
          else
            ...appState.patientAppointments.map((a) => _AppointmentCard(a)),
          const SizedBox(height: 16),
          AppCard(
            child: Row(
              children: [
                const Icon(Icons.favorite_rounded, color: AppColors.error),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Profile: ${appState.user!.age ?? '-'} years - ${appState.user!.gender ?? '-'}\nKeep your health info updated from Profile.',
                    style: const TextStyle(color: AppColors.muted),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.greetingText,
    required this.nameText,
    required this.subtitle,
  });
  final String greetingText;
  final String nameText;
  final String subtitle;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      GestureDetector(
        onTap: () => go(context, const ProfileScreen()),
        child: UserAvatar(user: appState.user!, radius: 24),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              greetingText,
              style: const TextStyle(
                color: AppColors.muted,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            FlexibleNameText(
              nameText,
              maxFontSize: 24,
              minFontSize: 15,
              maxLines: 2,
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: const TextStyle(color: AppColors.muted),
            ),
          ],
        ),
      ),
      Stack(
        children: [
          IconButton(
            onPressed: () => go(context, const NotificationsScreen()),
            icon: const Icon(Icons.notifications_rounded),
          ),
          if (appState.unreadCount > 0)
            Positioned(
              right: 8,
              top: 8,
              child: CircleAvatar(
                radius: 8,
                backgroundColor: AppColors.error,
                child: Text(
                  '${appState.unreadCount}',
                  style: const TextStyle(color: Colors.white, fontSize: 9),
                ),
              ),
            ),
        ],
      ),
    ],
  );
}

class UserAvatar extends StatelessWidget {
  const UserAvatar({
    super.key,
    required this.user,
    this.radius = 28,
    this.showCamera = false,
  });
  final AppUser user;
  final double radius;
  final bool showCamera;
  @override
  Widget build(BuildContext context) {
    final path = user.profileImagePath;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        CircleAvatar(
          radius: radius,
          backgroundColor: AppColors.primary.withValues(alpha: .12),
          backgroundImage: path == null || path.isEmpty
              ? null
              : FileImage(File(path)),
          child: path == null || path.isEmpty
              ? Text(
                  initials(user.name),
                  style: TextStyle(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w800,
                    fontSize: radius * .62,
                    letterSpacing: 0,
                  ),
                )
              : null,
        ),
        if (showCamera)
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              width: radius * .72,
              height: radius * .72,
              decoration: BoxDecoration(
                color: AppColors.primary,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
              child: Icon(
                Icons.photo_camera_rounded,
                size: radius * .38,
                color: Colors.white,
              ),
            ),
          ),
      ],
    );
  }
}

class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {super.key});
  final String status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status.toLowerCase()) {
      'accepted' => AppColors.success,
      'rejected' => AppColors.error,
      'rescheduled' => AppColors.accent,
      _ => AppColors.medium,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        statusLabel(status),
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w800,
          fontSize: 12,
        ),
      ),
    );
  }
}

String initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
  final value = parts.take(2).map((p) => p[0]).join();
  return value.isEmpty ? 'U' : value.toUpperCase();
}

String doctorDisplayName(String name) {
  final trimmed = name.trim();
  if (trimmed.toLowerCase().startsWith('dr.')) return trimmed;
  if (trimmed.toLowerCase().startsWith('dr ')) return trimmed;
  return 'Dr. $trimmed';
}

class FlexibleNameText extends StatelessWidget {
  const FlexibleNameText(
    this.text, {
    super.key,
    this.maxFontSize = 24,
    this.minFontSize = 14,
    this.maxLines = 1,
    this.textAlign = TextAlign.start,
  });
  final String text;
  final double maxFontSize;
  final double minFontSize;
  final int maxLines;
  final TextAlign textAlign;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scale = (constraints.maxWidth / (text.length * maxFontSize * .56))
          .clamp(minFontSize / maxFontSize, 1.0);
      return Text(
        text,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        textAlign: textAlign,
        style: TextStyle(
          fontSize: maxFontSize * scale,
          height: 1.12,
          fontWeight: FontWeight.w800,
          color: AppColors.text,
        ),
      );
    },
  );
}

class _Metric extends StatelessWidget {
  const _Metric(this.label, this.value, this.icon, {this.onTap});
  final String label;
  final String value;
  final IconData icon;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => AppCard(
    onTap: onTap,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: AppColors.primary),
        const Spacer(),
        Text(
          value,
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
        ),
        Text(
          label,
          style: const TextStyle(color: AppColors.muted, fontSize: 12),
        ),
      ],
    ),
  );
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: AppColors.background,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: AppColors.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(color: AppColors.muted, fontSize: 12),
        ),
      ],
    ),
  );
}

class _AiInsight extends StatelessWidget {
  const _AiInsight();
  @override
  Widget build(BuildContext context) {
    if (appState.patients.isEmpty) return const SizedBox.shrink();
    final count = appState.patients
        .where((p) => p.followUpSuggestion == null)
        .length;
    final allCovered = count == 0;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: (allCovered ? AppColors.success : AppColors.accent).withValues(
            alpha: .25,
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: (allCovered ? AppColors.success : AppColors.accent)
                .withValues(alpha: .08),
            blurRadius: 20,
          ),
        ],
      ),
      child: Row(
        children: [
          Icon(
            allCovered
                ? Icons.check_circle_rounded
                : Icons.auto_awesome_rounded,
            color: allCovered ? AppColors.success : AppColors.accent,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              allCovered
                  ? appState.patients.length == 1
                        ? 'Your patient has an AI follow-up suggestion.'
                        : 'All patients have AI follow-up suggestions.'
                  : 'AI follow-up suggestions available for $count patient${count == 1 ? '' : 's'}.',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title, {this.action});
  final String title;
  final VoidCallback? action;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(
          title,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
      ),
      if (action != null)
        TextButton(onPressed: action, child: const Text('View all')),
    ],
  );
}

class PatientListScreen extends StatefulWidget {
  const PatientListScreen({super.key});
  @override
  State<PatientListScreen> createState() => _PatientListScreenState();
}

class _PatientListScreenState extends State<PatientListScreen> {
  final search = TextEditingController();
  String filter = 'All';
  @override
  Widget build(BuildContext context) {
    final list = appState.patients.where((p) {
      final q = search.text.toLowerCase();
      final matches =
          p.name.toLowerCase().contains(q) ||
          p.disease.toLowerCase().contains(q);
      final byFilter =
          filter == 'All' ||
          p.priorityLevel == filter ||
          (filter == 'Recent' &&
              p.createdAt.isAfter(
                DateTime.now().subtract(const Duration(days: 7)),
              )) ||
          (filter == 'Follow-up Due' &&
              (p.followUpDate?.isBefore(
                    DateTime.now().add(const Duration(days: 3)),
                  ) ??
                  false));
      return matches && byFilter;
    }).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Patients')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => go(context, const PatientFormScreen()),
        child: const Icon(Icons.add_rounded),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
            child: TextField(
              controller: search,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search_rounded),
                hintText: 'Search by name or disease',
              ),
            ),
          ),
          SizedBox(
            height: 42,
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              scrollDirection: Axis.horizontal,
              children:
                  [
                        'All',
                        'Recent',
                        'Low',
                        'Medium',
                        'High',
                        'Urgent',
                        'Follow-up Due',
                      ]
                      .map(
                        (f) => Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(f),
                            selected: filter == f,
                            onSelected: (_) => setState(() => filter = f),
                          ),
                        ),
                      )
                      .toList(),
            ),
          ),
          Expanded(
            child: list.isEmpty
                ? const EmptyState(
                    icon: Icons.group_off_rounded,
                    title: 'No patients found',
                    message: 'Add a patient or adjust the search filters.',
                  )
                : ListView(
                    padding: const EdgeInsets.all(20),
                    children: list.map((p) => _PatientCard(p)).toList(),
                  ),
          ),
        ],
      ),
    );
  }
}

class _PatientCard extends StatelessWidget {
  const _PatientCard(this.p);
  final Patient p;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: AppCard(
      onTap: () => go(context, PatientProfileScreen(patient: p)),
      child: Row(
        children: [
          CircleAvatar(
            radius: 25,
            backgroundColor: AppColors.primary.withValues(alpha: .1),
            child: Text(
              initials(p.name),
              style: const TextStyle(
                color: AppColors.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p.name,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  '${p.age}/${p.gender} - ${p.disease}',
                  style: const TextStyle(color: AppColors.muted),
                ),
                Text(
                  'Last visit ${visitDateLabel(p.lastVisitDate)}',
                  style: const TextStyle(color: AppColors.muted, fontSize: 12),
                ),
              ],
            ),
          ),
          PriorityChip(p.priorityLevel),
        ],
      ),
    ),
  );
}

class PatientFormScreen extends StatefulWidget {
  const PatientFormScreen({super.key, this.patient});
  final Patient? patient;
  @override
  State<PatientFormScreen> createState() => _PatientFormScreenState();
}

class _PatientFormScreenState extends State<PatientFormScreen> {
  final form = GlobalKey<FormState>();
  late final name = TextEditingController(text: widget.patient?.name),
      age = TextEditingController(text: widget.patient?.age.toString()),
      phone = TextEditingController(text: widget.patient?.phone),
      email = TextEditingController(text: widget.patient?.email),
      disease = TextEditingController(text: widget.patient?.disease),
      symptoms = TextEditingController(text: widget.patient?.symptoms),
      history = TextEditingController(text: widget.patient?.medicalHistory),
      notes = TextEditingController(text: widget.patient?.doctorNotes);
  late String gender = widget.patient?.gender ?? 'Male';
  DateTime? lastVisit, nextAppt;
  bool get isEditing => widget.patient != null;

  @override
  void initState() {
    super.initState();
    lastVisit = widget.patient?.lastVisitDate;
    nextAppt = widget.patient?.nextAppointmentDate;
  }

  Future<void> pickDate(bool last) async {
    final date = await showDatePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
      initialDate: DateTime.now(),
    );
    if (date != null) setState(() => last ? lastVisit = date : nextAppt = date);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.patient == null ? 'Add Patient' : 'Edit Patient'),
    ),
    body: Form(
      key: form,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const _FormSection('Basic Information'),
          AppTextField(
            controller: name,
            label: 'Full Name',
            textCapitalization: TextCapitalization.words,
            validator: requiredValidator,
            readOnly: isEditing,
            enabled: !isEditing,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: AppTextField(
                  controller: age,
                  label: 'Age',
                  keyboardType: TextInputType.number,
                  validator: ageValidator,
                  readOnly: isEditing,
                  enabled: !isEditing,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: gender,
                  decoration: const InputDecoration(labelText: 'Gender'),
                  disabledHint: Text(gender),
                  items: const ['Male', 'Female', 'Other']
                      .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                      .toList(),
                  onChanged: isEditing ? null : (v) => gender = v!,
                ),
              ),
            ],
          ),
          if (!isEditing) ...[
            const SizedBox(height: 12),
            AppTextField(
              controller: phone,
              label: 'Phone Number',
              keyboardType: TextInputType.phone,
              validator: phoneValidator,
            ),
            const SizedBox(height: 12),
            AppTextField(
              controller: email,
              label: 'Email optional',
              keyboardType: TextInputType.emailAddress,
              validator: optionalEmailValidator,
            ),
          ],
          const _FormSection('Medical Details'),
          AppTextField(
            controller: disease,
            label: 'Disease/Condition',
            textCapitalization: TextCapitalization.words,
            validator: requiredValidator,
          ),
          const SizedBox(height: 12),
          AppTextField(
            controller: symptoms,
            label: 'Symptoms',
            maxLines: 3,
            textCapitalization: TextCapitalization.sentences,
            validator: requiredValidator,
          ),
          const SizedBox(height: 12),
          AppTextField(
            controller: history,
            label: 'Medical History',
            maxLines: 3,
            textCapitalization: TextCapitalization.sentences,
          ),
          const SizedBox(height: 12),
          AppTextField(
            controller: notes,
            label: 'Doctor Notes',
            maxLines: 3,
            textCapitalization: TextCapitalization.sentences,
          ),
          const _FormSection('Appointment Details'),
          _DateTile(
            label: 'Last Visit Date',
            date: lastVisit,
            onTap: () => pickDate(true),
          ),
          const SizedBox(height: 12),
          _DateTile(
            label: 'Next Appointment Date',
            date: nextAppt,
            onTap: () => pickDate(false),
          ),
          const SizedBox(height: 22),
          AppButton(
            label: widget.patient == null ? 'Save Patient' : 'Update Patient',
            onPressed: save,
          ),
          const SizedBox(height: 10),
          if (widget.patient == null)
            AppButton(
              label: 'Save & Generate AI Summary',
              icon: Icons.auto_awesome_rounded,
              outlined: true,
              onPressed: () async {
                await save(openAi: true);
              },
            ),
          if (widget.patient != null) ...[
            const SizedBox(height: 10),
            AppButton(
              label: 'Delete Patient',
              outlined: true,
              onPressed: () async {
                if (await confirm(
                  context,
                  'Are you sure you want to delete this patient record?',
                )) {
                  await appState.deletePatient(widget.patient!);
                  if (context.mounted) Navigator.pop(context);
                }
              },
            ),
          ],
        ],
      ),
    ),
  );

  Future<void> save({bool openAi = false}) async {
    if (!form.currentState!.validate()) return;
    final p =
        widget.patient ??
        Patient(
          id: id(),
          name: '',
          age: 1,
          gender: 'Male',
          phone: '',
          disease: '',
          symptoms: '',
          medicalHistory: '',
          doctorNotes: '',
        );
    if (!isEditing) {
      p.name = name.text.trim();
      p.age = int.parse(age.text);
      p.gender = gender;
      p.phone = phone.text.trim();
      p.email = email.text.trim().isEmpty ? null : email.text.trim();
    }
    p.disease = disease.text.trim();
    p.symptoms = symptoms.text.trim();
    p.medicalHistory = history.text.trim();
    p.doctorNotes = notes.text.trim();
    p.lastVisitDate = lastVisit;
    p.nextAppointmentDate = nextAppt;
    await appState.savePatient(p);
    if (!mounted) return;
    toast(context, 'Patient saved.');
    if (openAi) {
      go(context, AiResultScreen(patient: p, type: AiType.summary));
    } else {
      Navigator.pop(context);
    }
  }
}

class _FormSection extends StatelessWidget {
  const _FormSection(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 22, bottom: 10),
    child: Text(
      text,
      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
    ),
  );
}

class _DateTile extends StatelessWidget {
  const _DateTile({
    required this.label,
    required this.date,
    required this.onTap,
  });
  final String label;
  final DateTime? date;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(18),
    child: InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: const Icon(Icons.calendar_month_rounded),
      ),
      child: Text(fmt(date)),
    ),
  );
}

class PatientProfileScreen extends StatelessWidget {
  const PatientProfileScreen({super.key, required this.patient});
  final Patient patient;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: appState,
    builder: (context, child) {
      final latest = appState.patients
          .where((p) => p.id == patient.id)
          .firstOrNull;
      if (latest == null) {
        return Scaffold(
          appBar: AppBar(title: const Text('Patient Profile')),
          body: const EmptyState(
            icon: Icons.person_off_rounded,
            title: 'Patient removed',
            message: 'This patient record is no longer available.',
          ),
        );
      }
      return _PatientProfileBody(patient: latest);
    },
  );
}

class _PatientProfileBody extends StatelessWidget {
  const _PatientProfileBody({required this.patient});
  final Patient patient;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Patient Profile')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        AppCard(
          child: Row(
            children: [
              CircleAvatar(
                radius: 34,
                backgroundColor: AppColors.primary.withValues(alpha: .12),
                child: Text(
                  initials(patient.name),
                  style: const TextStyle(
                    fontSize: 18,
                    color: AppColors.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FlexibleNameText(
                      patient.name,
                      maxFontSize: 22,
                      minFontSize: 14,
                      maxLines: 2,
                    ),
                    Text(
                      '${patient.age} years - ${patient.gender}',
                      style: const TextStyle(color: AppColors.muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _Info('Disease/Condition', patient.disease),
        _Info('Symptoms', patient.symptoms),
        _Info('Medical History', patient.medicalHistory),
        _Info('Doctor Notes', patient.doctorNotes),
        _Info('Last Visit', visitDateLabel(patient.lastVisitDate)),
        _Info('Next Appointment', fmt(patient.nextAppointmentDate)),
        const SizedBox(height: 12),
        const Text(
          'AI Assistance',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        AppButton(
          label: 'Generate AI Summary',
          icon: Icons.summarize_rounded,
          onPressed: () => go(
            context,
            AiResultScreen(patient: patient, type: AiType.summary),
          ),
        ),
        const SizedBox(height: 10),
        AppButton(
          label: 'Check Appointment Priority',
          icon: Icons.priority_high_rounded,
          outlined: true,
          onPressed: () => go(
            context,
            AiResultScreen(patient: patient, type: AiType.priority),
          ),
        ),
        const SizedBox(height: 10),
        AppButton(
          label: 'Suggest Follow-Up',
          icon: Icons.event_repeat_rounded,
          outlined: true,
          onPressed: () => go(
            context,
            AiResultScreen(patient: patient, type: AiType.followUp),
          ),
        ),
        if (patient.aiSummary != null) ...[
          _DismissibleInfo(
            label: 'AI Summary',
            value: patient.aiSummary!.summary,
            onDelete: () async {
              patient.aiSummary = null;
              await appState.savePatient(patient);
            },
          ),
        ],
        if (patient.priorityReason != null) ...[
          _DismissibleInfo(
            label: 'Priority Level',
            value: '${patient.priorityLevel}\n${patient.priorityReason}',
            onDelete: () async {
              patient.priorityLevel = 'Low';
              patient.priorityReason = null;
              await appState.savePatient(patient);
            },
          ),
        ],
        if (patient.followUpSuggestion != null) ...[
          _DismissibleInfo(
            label: 'Follow-Up Suggestion',
            value:
                '${patient.followUpSuggestion!.suggestedPeriod}\n${patient.followUpSuggestion!.reason}',
            onDelete: () async {
              patient.followUpSuggestion = null;
              patient.followUpDate = null;
              await appState.savePatient(patient);
            },
          ),
        ],
        const SizedBox(height: 16),
        AppButton(
          label: 'Edit Patient',
          icon: Icons.edit_rounded,
          onPressed: () => go(context, PatientFormScreen(patient: patient)),
        ),
        const SizedBox(height: 10),
        AppButton(
          label: 'Delete Patient',
          outlined: true,
          onPressed: () async {
            if (await confirm(
              context,
              'Are you sure you want to delete this patient record?',
            )) {
              await appState.deletePatient(patient);
              if (context.mounted) Navigator.pop(context);
            }
          },
        ),
      ],
    ),
  );
}

class _Info extends StatelessWidget {
  const _Info(this.label, this.value);
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(
            value.isEmpty ? 'Not provided' : value,
            style: const TextStyle(color: AppColors.muted, height: 1.35),
          ),
        ],
      ),
    ),
  );
}

class _DismissibleInfo extends StatelessWidget {
  const _DismissibleInfo({
    required this.label,
    required this.value,
    required this.onDelete,
  });
  final String label;
  final String value;
  final Future<void> Function() onDelete;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              SizedBox(
                height: 28,
                width: 28,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  iconSize: 18,
                  icon: const Icon(
                    Icons.delete_outline_rounded,
                    color: AppColors.error,
                  ),
                  onPressed: () async {
                    if (await confirm(context, 'Clear $label?')) {
                      await onDelete();
                    }
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value.isEmpty ? 'Not provided' : value,
            style: const TextStyle(color: AppColors.muted, height: 1.35),
          ),
        ],
      ),
    ),
  );
}

enum AiType { summary, priority, followUp }

class AiResultScreen extends StatefulWidget {
  const AiResultScreen({super.key, required this.patient, required this.type});
  final Patient patient;
  final AiType type;
  @override
  State<AiResultScreen> createState() => _AiResultScreenState();
}

class _AiResultScreenState extends State<AiResultScreen> {
  Object? result;
  String? error;
  bool loading = true;
  @override
  void initState() {
    super.initState();
    run();
  }

  Future<void> run() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      result = switch (widget.type) {
        AiType.summary => await appState.gemini.generatePatientSummary(
          widget.patient,
        ),
        AiType.priority => await appState.gemini.classifyAppointmentPriority(
          patient: widget.patient,
        ),
        AiType.followUp => await appState.gemini.suggestFollowUp(
          widget.patient,
        ),
      };
    } catch (e) {
      error = e is MissingApiKeyException
          ? e.toString()
          : e.toString().replaceFirst('Exception: ', '');
    }
    if (mounted) setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final title = switch (widget.type) {
      AiType.summary => 'AI Summary',
      AiType.priority => 'AI Priority',
      AiType.followUp => 'AI Follow-Up',
    };
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: loading
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 14),
                    const Text('Generating AI response...'),
                    if (widget.type == AiType.priority ||
                        widget.type == AiType.followUp) ...[
                      const SizedBox(height: 16),
                      _AiGuideCard(type: widget.type),
                    ],
                  ],
                ),
              )
            : error != null
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.key_rounded,
                      color: AppColors.primary,
                      size: 42,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: AppColors.muted),
                    ),
                    const SizedBox(height: 12),
                    AppButton(
                      label: 'Set Up API Key',
                      icon: Icons.key_rounded,
                      onPressed: () =>
                          go(context, const ApiKeySettingsScreen()),
                    ),
                    const SizedBox(height: 10),
                    AppButton(label: 'Retry', outlined: true, onPressed: run),
                  ],
                ),
              )
            : ListView(
                children: [
                  if (widget.type == AiType.priority ||
                      widget.type == AiType.followUp) ...[
                    _AiGuideCard(type: widget.type),
                    const SizedBox(height: 14),
                  ],
                  AppCard(child: _AiResultBody(result: result!)),
                  const SizedBox(height: 14),
                  AppButton(label: saveLabel, onPressed: save),
                  const SizedBox(height: 10),
                  AppButton(
                    label: 'Regenerate',
                    outlined: true,
                    onPressed: run,
                  ),
                  const SizedBox(height: 10),
                  AppButton(
                    label: widget.type == AiType.priority
                        ? 'Edit Manually'
                        : widget.type == AiType.followUp
                        ? 'Edit Date'
                        : 'Close',
                    outlined: true,
                    onPressed: () async {
                      if (widget.type == AiType.followUp) {
                        final date = await showDatePicker(
                          context: context,
                          firstDate: DateTime.now(),
                          lastDate: DateTime(2035),
                          initialDate: DateTime.now().add(
                            const Duration(days: 14),
                          ),
                        );
                        if (date != null) {
                          widget.patient.followUpDate = date;
                          await appState.savePatient(widget.patient);
                          if (context.mounted) {
                            toast(context, 'Follow-up date updated.');
                          }
                        }
                      } else if (widget.type == AiType.priority) {
                        await showDialog(
                          context: context,
                          builder: (_) =>
                              _ManualPriorityDialog(patient: widget.patient),
                        );
                      } else if (context.mounted) {
                        Navigator.pop(context);
                      }
                    },
                  ),
                ],
              ),
      ),
    );
  }

  String get saveLabel => switch (widget.type) {
    AiType.summary => 'Save Summary',
    AiType.priority => 'Save Priority',
    AiType.followUp => 'Save Reminder',
  };
  Future<void> save() async {
    if (result case AiSummary r) widget.patient.aiSummary = r;
    if (result case PrioritySuggestion r) {
      widget.patient.priorityLevel = r.priorityLevel;
      widget.patient.priorityReason = r.reason;
      for (final a in appState.appointments.where(
        (a) => a.patientUserId == widget.patient.linkedPatientUserId,
      )) {
        a.priorityLevel = r.priorityLevel;
        a.priorityReason = r.reason;
      }
      if (r.priorityLevel == 'Urgent') {
        await appState.notifyAllDoctors(
          title: 'Urgent priority detected',
          message: '${widget.patient.name} has urgent priority.',
          type: 'urgent',
        );
      }
    }
    if (result case FollowUpSuggestion r) {
      widget.patient.followUpSuggestion = r;
      widget.patient.followUpDate = r.suggestedDate == null
          ? DateTime.now().add(const Duration(days: 14))
          : DateTime.tryParse(r.suggestedDate!) ??
                DateTime.now().add(const Duration(days: 14));
      final reminderDate =
          widget.patient.followUpDate ??
          DateTime.now().add(const Duration(days: 14));
      await NotificationService.instance.scheduleFollowUp(
        id: widget.patient.id.hashCode.abs(),
        title: 'Follow-up reminder for ${widget.patient.name}',
        body: 'Follow-up reminder is due today.',
        date: reminderDate,
      );
    }
    await appState.savePatient(widget.patient);
    await appState.persist();
    if (mounted) toast(context, 'Saved.');
  }
}

class _AiGuideCard extends StatelessWidget {
  const _AiGuideCard({required this.type});
  final AiType type;

  @override
  Widget build(BuildContext context) {
    final isPriority = type == AiType.priority;
    return AppCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isPriority ? Icons.fact_check_rounded : Icons.event_repeat_rounded,
            color: AppColors.primary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              isPriority
                  ? 'Priority is estimated from recorded symptoms, condition, visit reason, history, and clinical red-flag wording. It supports scheduling urgency only.'
                  : 'Follow-up timing is estimated from the condition, symptoms, last visit, planned appointment, and doctor notes. The doctor can adjust the date before relying on it.',
              style: const TextStyle(color: AppColors.muted, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

class _AiResultBody extends StatelessWidget {
  const _AiResultBody({required this.result});
  final Object result;
  @override
  Widget build(BuildContext context) {
    if (result case AiSummary r) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(r.summary),
          const SizedBox(height: 12),
          ...r.importantPoints.map((p) => Text('- $p')),
          const Divider(),
          Text(r.disclaimer, style: const TextStyle(color: AppColors.muted)),
        ],
      );
    }
    if (result case PrioritySuggestion r) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PriorityChip(r.priorityLevel),
          const SizedBox(height: 12),
          Text(r.reason),
          const Divider(),
          Text(r.safetyNote, style: const TextStyle(color: AppColors.muted)),
        ],
      );
    }
    final r = result as FollowUpSuggestion;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          r.suggestedPeriod,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        Text(r.suggestedDate ?? 'Date not specified'),
        const SizedBox(height: 12),
        Text(r.reason),
        const Divider(),
        Text(r.disclaimer, style: const TextStyle(color: AppColors.muted)),
      ],
    );
  }
}

class _ManualPriorityDialog extends StatefulWidget {
  const _ManualPriorityDialog({required this.patient});
  final Patient patient;
  @override
  State<_ManualPriorityDialog> createState() => _ManualPriorityDialogState();
}

class _ManualPriorityDialogState extends State<_ManualPriorityDialog> {
  late String value = widget.patient.priorityLevel;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Edit Priority'),
    content: DropdownButtonFormField(
      initialValue: value,
      items: const [
        'Low',
        'Medium',
        'High',
        'Urgent',
      ].map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
      onChanged: (v) => value = v!,
    ),
    actions: [
      FilledButton(
        onPressed: () {
          widget.patient.priorityLevel = value;
          Navigator.pop(context);
        },
        child: const Text('Save'),
      ),
    ],
  );
}

class AppointmentBookingScreen extends StatefulWidget {
  const AppointmentBookingScreen({super.key, this.appointment});
  final Appointment? appointment;
  @override
  State<AppointmentBookingScreen> createState() =>
      _AppointmentBookingScreenState();
}

class _AppointmentBookingScreenState extends State<AppointmentBookingScreen> {
  final form = GlobalKey<FormState>();
  final symptoms = TextEditingController(),
      reason = TextEditingController(),
      disease = TextEditingController();
  DateTime? date;
  TimeOfDay? time;
  bool loading = false;

  bool get isEditing => widget.appointment != null;

  @override
  void initState() {
    super.initState();
    final appointment = widget.appointment;
    if (appointment != null) {
      date = appointment.date;
      time = _parseAppointmentTime(context, appointment.time);
      symptoms.text = appointment.symptoms;
      reason.text = appointment.reason;
      disease.text = appointment.disease ?? '';
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(isEditing ? 'Edit Appointment' : 'Book Appointment'),
    ),
    body: Form(
      key: form,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          AppCard(
            child: Row(
              children: [
                const Icon(
                  Icons.local_hospital_rounded,
                  color: AppColors.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Request an appointment with the MediTrack care team. A doctor will review and respond.',
                    style: const TextStyle(color: AppColors.muted),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _DateTile(
            label: 'Preferred Date',
            date: date,
            onTap: () async {
              final v = await showDatePicker(
                context: context,
                firstDate: DateTime.now(),
                lastDate: DateTime(2035),
                initialDate: DateTime.now(),
              );
              if (v != null) setState(() => date = v);
            },
          ),
          const SizedBox(height: 12),
          InkWell(
            onTap: () async {
              final v = await showTimePicker(
                context: context,
                initialTime: TimeOfDay.now(),
              );
              if (v != null) setState(() => time = v);
            },
            child: InputDecorator(
              decoration: const InputDecoration(
                labelText: 'Preferred Time',
                suffixIcon: Icon(Icons.schedule_rounded),
              ),
              child: Text(time?.format(context) ?? 'Not set'),
            ),
          ),
          const SizedBox(height: 12),
          AppTextField(
            controller: symptoms,
            label: 'Symptoms',
            maxLines: 3,
            textCapitalization: TextCapitalization.sentences,
            validator: requiredValidator,
          ),
          const SizedBox(height: 12),
          AppTextField(
            controller: reason,
            label: 'Reason for Visit',
            maxLines: 3,
            textCapitalization: TextCapitalization.sentences,
            validator: requiredValidator,
          ),
          const SizedBox(height: 12),
          AppTextField(
            controller: disease,
            label: 'Known Disease/Condition optional',
            textCapitalization: TextCapitalization.words,
          ),
          const SizedBox(height: 24),
          AppButton(
            label: loading ? 'Sending request...' : 'Request Appointment',
            icon: loading ? Icons.hourglass_empty_rounded : Icons.send_rounded,
            onPressed: loading
                ? null
                : () async {
                    if (!form.currentState!.validate()) return;
                    if (date == null || time == null) {
                      toast(context, 'Date and time are required.');
                      return;
                    }
                    setState(() => loading = true);
                    final appt = Appointment(
                      id: widget.appointment?.id ?? id(),
                      patientUserId: appState.user!.id,
                      patientName: appState.user!.name,
                      doctorNameOrSpecialty: 'MediTrack Care Team',
                      date: date!,
                      time: time!.format(context),
                      symptoms: symptoms.text.trim(),
                      reason: reason.text.trim(),
                      disease: disease.text.trim().isEmpty
                          ? null
                          : disease.text.trim(),
                      status: widget.appointment?.status ?? 'pending',
                      priorityLevel: widget.appointment?.priorityLevel,
                      priorityReason: widget.appointment?.priorityReason,
                      createdAt: widget.appointment?.createdAt,
                    );
                    try {
                      final priority = await appState.gemini
                          .classifyAppointmentPriority(appointment: appt);
                      appt.priorityLevel = priority.priorityLevel;
                      appt.priorityReason = priority.reason;
                    } on MissingApiKeyException {
                      appt.priorityLevel = null;
                      appt.priorityReason = null;
                    }
                    if (isEditing) {
                      await appState.editAppointmentRequest(appt);
                    } else {
                      await appState.requestAppointment(appt);
                    }
                    if (context.mounted) {
                      toast(
                        context,
                        isEditing
                            ? 'Appointment request updated.'
                            : 'Your appointment request has been sent.',
                      );
                      if (isEditing) {
                        Navigator.pop(context);
                      } else {
                        setState(() {
                          loading = false;
                          date = null;
                          time = null;
                          symptoms.clear();
                          reason.clear();
                          disease.clear();
                        });
                        openPatientAppointmentsTab(context);
                      }
                    }
                    if (mounted) setState(() => loading = false);
                  },
          ),
        ],
      ),
    ),
  );
}

class AppointmentRequestsScreen extends StatefulWidget {
  const AppointmentRequestsScreen({super.key, this.initialTab = 'pending'});
  final String initialTab;
  @override
  State<AppointmentRequestsScreen> createState() =>
      _AppointmentRequestsScreenState();
}

class _AppointmentRequestsScreenState extends State<AppointmentRequestsScreen> {
  late String tab = widget.initialTab;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: appState,
    builder: (context, child) {
      final list =
          appState.appointments
              .where(
                (a) => tab == 'urgent'
                    ? a.priorityLevel == 'Urgent'
                    : a.status == tab,
              )
              .toList()
            ..sort(sortAppointmentsNewestFirst);
      return Scaffold(
        appBar: AppBar(title: const Text('Appointment Requests')),
        body: Column(
          children: [
            SizedBox(
              height: 42,
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                scrollDirection: Axis.horizontal,
                children:
                    ['pending', 'rescheduled', 'accepted', 'rejected', 'urgent']
                        .map(
                          (f) => Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text(f[0].toUpperCase() + f.substring(1)),
                              selected: tab == f,
                              onSelected: (_) => setState(() => tab = f),
                            ),
                          ),
                        )
                        .toList(),
              ),
            ),
            Expanded(
              child: list.isEmpty
                  ? const EmptyState(
                      icon: Icons.event_busy_rounded,
                      title: 'No requests',
                      message: 'Appointment requests will appear here.',
                    )
                  : ListView(
                      padding: const EdgeInsets.all(20),
                      children: list
                          .map((a) => _AppointmentCard(a, doctorView: true))
                          .toList(),
                    ),
            ),
          ],
        ),
      );
    },
  );
}

class MyAppointmentsScreen extends StatelessWidget {
  const MyAppointmentsScreen({super.key});
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: appState,
    builder: (context, child) => Scaffold(
      appBar: AppBar(title: const Text('My Appointments')),
      body: appState.patientAppointments.isEmpty
          ? const EmptyState(
              icon: Icons.event_busy_rounded,
              title: 'No appointments',
              message: 'Book an appointment to track its status.',
            )
          : ListView(
              padding: const EdgeInsets.all(20),
              children: appState.patientAppointments
                  .map((a) => _AppointmentCard(a))
                  .toList(),
            ),
    ),
  );
}

class _AppointmentCard extends StatelessWidget {
  const _AppointmentCard(this.a, {this.doctorView = false});
  final Appointment a;
  final bool doctorView;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: AppCard(
      onTap: () => go(context, AppointmentDetailScreen(appointment: a)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  a.patientName,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
              ),
              if (doctorView && a.priorityLevel != null)
                PriorityChip(a.priorityLevel!)
              else
                StatusChip(a.status),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${fmt(a.date)} - ${a.time}',
            style: const TextStyle(color: AppColors.muted),
          ),
          if (doctorView) ...[const SizedBox(height: 6), StatusChip(a.status)],
          const SizedBox(height: 6),
          Text(a.reason, maxLines: 2, overflow: TextOverflow.ellipsis),
          if (doctorView && canDoctorActOnAppointment(a))
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _CardActionButton(
                    label: 'Accept',
                    icon: Icons.check_rounded,
                    filled: true,
                    onPressed: () async {
                      if (await confirm(context, 'Accept this appointment?')) {
                        await appState.updateAppointment(a, 'accepted');
                      }
                    },
                  ),
                  if (a.status == 'pending')
                    _CardActionButton(
                      label: 'Reject',
                      icon: Icons.close_rounded,
                      onPressed: () async {
                        if (await confirm(
                          context,
                          'Reject this appointment?',
                        )) {
                          await appState.updateAppointment(a, 'rejected');
                        }
                      },
                    ),
                  _CardActionButton(
                    label: a.status == 'rescheduled'
                        ? 'Reschedule Again'
                        : 'Reschedule',
                    icon: Icons.update_rounded,
                    onPressed: () async {
                      await showRescheduleDialog(context, a);
                    },
                  ),
                ],
              ),
            ),
          if (!doctorView && canEditAppointment(a))
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _CardActionButton(
                    label: 'Edit',
                    icon: Icons.edit_rounded,
                    filled: true,
                    onPressed: () =>
                        go(context, AppointmentBookingScreen(appointment: a)),
                  ),
                  _CardActionButton(
                    label: 'Delete',
                    icon: Icons.delete_outline_rounded,
                    danger: true,
                    onPressed: () async {
                      if (await confirm(
                        context,
                        'Are you sure you want to delete this appointment request?',
                      )) {
                        await appState.deleteAppointmentRequest(a);
                        if (context.mounted) {
                          toast(context, 'Appointment request deleted.');
                        }
                      }
                    },
                  ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}

bool canEditAppointment(Appointment appointment) {
  final status = appointment.status.toLowerCase();
  return status == 'pending' || status == 'rescheduled';
}

bool canDoctorActOnAppointment(Appointment appointment) {
  final status = appointment.status.toLowerCase();
  return status == 'pending' || status == 'rescheduled';
}

class _CardActionButton extends StatelessWidget {
  const _CardActionButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.filled = false,
    this.danger = false,
  });
  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final bool filled;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? AppColors.error : AppColors.primary;
    final foreground = filled ? Colors.white : color;
    final background = filled ? color : color.withValues(alpha: .08);
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onPressed,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: filled ? color : color.withValues(alpha: .25),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 17, color: foreground),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: foreground,
                fontWeight: FontWeight.w800,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AppointmentDetailScreen extends StatelessWidget {
  const AppointmentDetailScreen({super.key, required this.appointment});
  final Appointment appointment;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: appState,
    builder: (context, child) {
      final current =
          appState.appointments
              .where((a) => a.id == appointment.id)
              .firstOrNull ??
          appointment;
      return Scaffold(
        appBar: AppBar(title: const Text('Appointment Detail')),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            _Info('Patient', current.patientName),
            _Info('Date/Time', '${fmt(current.date)} - ${current.time}'),
            _Info('Symptoms', current.symptoms),
            _Info('Reason', current.reason),
            _Info('Disease', current.disease ?? 'Not provided'),
            _Info('Status', current.status),
            if (appState.user?.isDoctor ?? false) ...[
              _Info(
                'AI Priority',
                '${current.priorityLevel ?? 'Not checked'}\n${current.priorityReason ?? ''}',
              ),
              if (current.status == 'pending') ...[
                const SizedBox(height: 14),
                AppButton(
                  label: 'Accept Appointment',
                  onPressed: () async {
                    if (await confirm(context, 'Accept this appointment?')) {
                      await appState.updateAppointment(current, 'accepted');
                    }
                  },
                ),
                const SizedBox(height: 10),
                AppButton(
                  label: 'Reject Appointment',
                  outlined: true,
                  onPressed: () async {
                    if (await confirm(context, 'Reject this appointment?')) {
                      await appState.updateAppointment(current, 'rejected');
                    }
                  },
                ),
                const SizedBox(height: 10),
                AppButton(
                  label: 'Reschedule Appointment',
                  icon: Icons.update_rounded,
                  outlined: true,
                  onPressed: () => showRescheduleDialog(context, current),
                ),
              ] else if (current.status == 'rescheduled') ...[
                const SizedBox(height: 14),
                AppButton(
                  label: 'Accept Appointment',
                  onPressed: () async {
                    if (await confirm(context, 'Accept this appointment?')) {
                      await appState.updateAppointment(current, 'accepted');
                    }
                  },
                ),
                const SizedBox(height: 10),
                AppButton(
                  label: 'Reschedule Again',
                  icon: Icons.update_rounded,
                  outlined: true,
                  onPressed: () => showRescheduleDialog(context, current),
                ),
              ],
              const SizedBox(height: 10),
              AppButton(
                label: 'Open Patient Profile',
                outlined: true,
                onPressed: () {
                  final p =
                      appState.patients
                          .where(
                            (p) =>
                                p.linkedPatientUserId == current.patientUserId,
                          )
                          .firstOrNull ??
                      appState.patients
                          .where((p) => p.name == current.patientName)
                          .firstOrNull;
                  if (p == null) {
                    toast(context, 'No linked patient record found.');
                  } else {
                    go(context, PatientProfileScreen(patient: p));
                  }
                },
              ),
            ],
            if (!(appState.user?.isDoctor ?? false) &&
                canEditAppointment(current)) ...[
              const SizedBox(height: 14),
              AppButton(
                label: 'Edit Appointment',
                icon: Icons.edit_rounded,
                onPressed: () =>
                    go(context, AppointmentBookingScreen(appointment: current)),
              ),
              const SizedBox(height: 10),
              AppButton(
                label: 'Delete Appointment',
                outlined: true,
                onPressed: () async {
                  if (await confirm(
                    context,
                    'Are you sure you want to delete this appointment request?',
                  )) {
                    await appState.deleteAppointmentRequest(current);
                    if (context.mounted) {
                      toast(context, 'Appointment request deleted.');
                      Navigator.pop(context);
                    }
                  }
                },
              ),
            ],
          ],
        ),
      );
    },
  );
}

Future<void> showRescheduleDialog(
  BuildContext context,
  Appointment appointment,
) async {
  DateTime selectedDate = appointment.date.isBefore(DateTime.now())
      ? DateTime.now()
      : appointment.date;
  TimeOfDay selectedTime = _parseAppointmentTime(context, appointment.time);

  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: const Text('Reschedule Appointment'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Choose a new date and time for this appointment.',
              style: TextStyle(color: AppColors.muted),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () async {
                final picked = await showDatePicker(
                  context: context,
                  firstDate: DateTime.now(),
                  lastDate: DateTime(2035),
                  initialDate: selectedDate,
                );
                if (picked != null) {
                  setDialogState(() => selectedDate = picked);
                }
              },
              icon: const Icon(Icons.calendar_month_rounded),
              label: Text(fmt(selectedDate)),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () async {
                final picked = await showTimePicker(
                  context: context,
                  initialTime: selectedTime,
                );
                if (picked != null) {
                  setDialogState(() => selectedTime = picked);
                }
              },
              icon: const Icon(Icons.schedule_rounded),
              label: Text(selectedTime.format(context)),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              await appState.rescheduleAppointment(
                appointment,
                selectedDate,
                selectedTime.format(context),
              );
              if (context.mounted) {
                Navigator.pop(dialogContext);
                toast(context, 'Appointment rescheduled.');
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}

TimeOfDay _parseAppointmentTime(BuildContext context, String value) {
  final cleaned = value.trim().toUpperCase();
  final match = RegExp(r'^(\d{1,2}):(\d{2})\s*(AM|PM)?$').firstMatch(cleaned);
  if (match == null) return TimeOfDay.now();
  var hour = int.tryParse(match.group(1) ?? '') ?? TimeOfDay.now().hour;
  final minute = int.tryParse(match.group(2) ?? '') ?? TimeOfDay.now().minute;
  final period = match.group(3);
  if (period == 'PM' && hour < 12) hour += 12;
  if (period == 'AM' && hour == 12) hour = 0;
  return TimeOfDay(hour: hour.clamp(0, 23), minute: minute.clamp(0, 59));
}

class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: appState,
    builder: (context, child) {
      final notifications = appState.myNotifications;
      return Scaffold(
        appBar: AppBar(
          title: const Text('Notifications'),
          actions: [
            TextButton(
              onPressed: notifications.isEmpty
                  ? null
                  : () async {
                      if (await confirm(context, 'Clear all notifications?')) {
                        final visibleIds = notifications
                            .map((n) => n.id)
                            .toSet();
                        appState.notifications.removeWhere(
                          (n) => visibleIds.contains(n.id),
                        );
                        for (final id in visibleIds) {
                          await appState.cloud.deleteNotification(id);
                        }
                        await appState.persist();
                      }
                    },
              child: const Text('Clear All'),
            ),
          ],
        ),
        body: notifications.isEmpty
            ? const EmptyState(
                icon: Icons.notifications_off_rounded,
                title: 'No notifications',
                message: 'Status updates and reminders will appear here.',
              )
            : ListView(
                padding: const EdgeInsets.all(20),
                children: notifications
                    .map(
                      (n) => Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: AppCard(
                          onTap: () async {
                            if (!n.isRead) {
                              n.isRead = true;
                              await appState.persist();
                            }
                          },
                          child: Row(
                            children: [
                              Icon(
                                n.type == 'urgent'
                                    ? Icons.warning_rounded
                                    : Icons.notifications_rounded,
                                color: n.isRead
                                    ? AppColors.muted
                                    : AppColors.primary,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      n.title,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    Text(
                                      n.message,
                                      style: const TextStyle(
                                        color: AppColors.muted,
                                      ),
                                    ),
                                    Text(
                                      DateFormat(
                                        'MMM d, h:mm a',
                                      ).format(n.createdAt),
                                      style: const TextStyle(
                                        color: AppColors.muted,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (!n.isRead)
                                const CircleAvatar(
                                  radius: 5,
                                  backgroundColor: AppColors.accent,
                                ),
                            ],
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
      );
    },
  );
}

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: appState,
    builder: (context, child) {
      final u = appState.user!;
      return Scaffold(
        appBar: AppBar(
          title: Text(u.isDoctor ? 'Doctor Profile' : 'Patient Profile'),
        ),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Center(
              child: GestureDetector(
                onTap: () async {
                  final img = await ImagePicker().pickImage(
                    source: ImageSource.gallery,
                  );
                  if (img != null) {
                    u.profileImagePath = img.path;
                    await appState.auth.update(u);
                    await appState.persist();
                  }
                },
                child: UserAvatar(user: u, radius: 54, showCamera: true),
              ),
            ),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: FlexibleNameText(
                u.name,
                maxFontSize: 24,
                minFontSize: 14,
                maxLines: 2,
                textAlign: TextAlign.center,
              ),
            ),
            Center(
              child: Text(
                u.email,
                style: const TextStyle(color: AppColors.muted),
              ),
            ),
            const SizedBox(height: 20),
            _Info('Phone', u.phone),
            if (u.isDoctor)
              _Info('Specialization', u.specialization ?? 'Not set')
            else
              _Info(
                'Health Info',
                '${u.age ?? '-'} years - ${u.gender ?? '-'}',
              ),
            if (!u.isDoctor)
              _Info(
                'Medical History',
                (u.medicalHistory ?? '').trim().isEmpty
                    ? 'Not provided'
                    : u.medicalHistory!,
              ),
            if (!u.isDoctor) ...[
              const SizedBox(height: 10),
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Appointment Overview',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: _MiniStat(
                            label: 'Total',
                            value: '${appState.patientAppointments.length}',
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _MiniStat(
                            label: 'Pending',
                            value:
                                '${appState.patientAppointments.where((a) => a.status == 'pending').length}',
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    AppButton(
                      label: 'Book Appointment',
                      icon: Icons.add_rounded,
                      onPressed: () =>
                          go(context, const AppointmentBookingScreen()),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 10),
            AppButton(
              label: 'Edit Profile',
              icon: Icons.edit_rounded,
              onPressed: () => go(context, const EditProfileScreen()),
            ),
            if (u.isDoctor) ...[
              const SizedBox(height: 10),
              AppButton(
                label: 'API Key Settings',
                icon: Icons.key_rounded,
                outlined: true,
                onPressed: () => go(context, const ApiKeySettingsScreen()),
              ),
            ],
            const SizedBox(height: 10),
            AppButton(
              label: 'Logout',
              outlined: true,
              onPressed: () async {
                if (await confirm(
                  context,
                  'Are you sure you want to logout?',
                )) {
                  await appState.logout();
                  if (context.mounted) {
                    go(context, const RoleSelectionScreen(), clear: true);
                  }
                }
              },
            ),
          ],
        ),
      );
    },
  );
}

class ApiKeySettingsScreen extends StatefulWidget {
  const ApiKeySettingsScreen({super.key});
  @override
  State<ApiKeySettingsScreen> createState() => _ApiKeySettingsScreenState();
}

class _ApiKeySettingsScreenState extends State<ApiKeySettingsScreen> {
  late final apiKey = TextEditingController(
    text: StorageService.instance.geminiApiKey,
  );
  bool obscure = true;

  @override
  Widget build(BuildContext context) {
    final hasKey =
        StorageService.instance.geminiApiKey.isNotEmpty ||
        const String.fromEnvironment('GEMINI_API_KEY').isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('API Key Settings')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          AppCard(
            child: Row(
              children: [
                Icon(
                  hasKey ? Icons.check_circle_rounded : Icons.info_rounded,
                  color: hasKey ? AppColors.success : AppColors.accent,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    hasKey
                        ? 'API key is configured. AI features will use live responses.'
                        : 'No API key is configured. AI features are disabled until you add one.',
                    style: const TextStyle(color: AppColors.muted),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          AppTextField(
            controller: apiKey,
            label: 'API Key',
            obscureText: obscure,
            suffixIcon: IconButton(
              icon: Icon(
                obscure
                    ? Icons.visibility_rounded
                    : Icons.visibility_off_rounded,
              ),
              onPressed: () => setState(() => obscure = !obscure),
            ),
            helperText: 'Saved on this device for doctor AI features.',
          ),
          const SizedBox(height: 18),
          AppButton(
            label: 'Save API Key',
            icon: Icons.save_rounded,
            onPressed: () async {
              await StorageService.instance.setGeminiApiKey(apiKey.text);
              if (context.mounted) {
                toast(context, 'API key saved.');
                setState(() {});
              }
            },
          ),
          const SizedBox(height: 10),
          AppButton(
            label: 'Clear API Key',
            icon: Icons.delete_outline_rounded,
            outlined: true,
            onPressed: () async {
              apiKey.clear();
              await StorageService.instance.clearGeminiApiKey();
              if (context.mounted) {
                toast(context, 'API key cleared. AI features are disabled.');
                setState(() {});
              }
            },
          ),
        ],
      ),
    );
  }
}

class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});
  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final form = GlobalKey<FormState>();
  late final u = appState.user!;
  late final name = TextEditingController(text: u.name),
      email = TextEditingController(text: u.email),
      phone = TextEditingController(text: u.phone),
      specialization = TextEditingController(text: u.specialization),
      medicalHistory = TextEditingController(text: u.medicalHistory),
      age = TextEditingController(text: u.age?.toString());
  late String gender = u.gender ?? 'Male';
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Edit Profile')),
    body: Form(
      key: form,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          AppTextField(
            controller: name,
            label: 'Full Name',
            textCapitalization: TextCapitalization.words,
            validator: requiredValidator,
          ),
          const SizedBox(height: 12),
          AppTextField(
            controller: email,
            label: 'Email',
            keyboardType: TextInputType.emailAddress,
            readOnly: true,
            enabled: false,
            helperText: 'Email cannot be changed after account creation.',
          ),
          const SizedBox(height: 12),
          AppTextField(
            controller: phone,
            label: 'Phone Number',
            keyboardType: TextInputType.phone,
            validator: phoneValidator,
          ),
          if (u.isDoctor) ...[
            const SizedBox(height: 12),
            AppTextField(
              controller: specialization,
              label: 'Specialization',
              textCapitalization: TextCapitalization.words,
              validator: requiredValidator,
            ),
          ] else ...[
            const SizedBox(height: 12),
            AppTextField(
              controller: age,
              label: 'Age',
              keyboardType: TextInputType.number,
              validator: ageValidator,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField(
              initialValue: gender,
              decoration: const InputDecoration(labelText: 'Gender'),
              items: const [
                'Male',
                'Female',
                'Other',
              ].map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
              onChanged: (v) => gender = v!,
            ),
            const SizedBox(height: 12),
            AppTextField(
              controller: medicalHistory,
              label: 'Medical History optional',
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
            ),
          ],
          const SizedBox(height: 24),
          AppButton(
            label: 'Save',
            onPressed: () async {
              if (!form.currentState!.validate()) return;
              u.name = name.text.trim();
              u.phone = phone.text.trim();
              u.specialization = specialization.text.trim().isEmpty
                  ? null
                  : specialization.text.trim();
              u.age = int.tryParse(age.text);
              u.gender = u.isDoctor ? null : gender;
              u.medicalHistory = u.isDoctor
                  ? null
                  : (medicalHistory.text.trim().isEmpty
                        ? null
                        : medicalHistory.text.trim());
              await appState.auth.update(u);
              await appState.syncPatientAccountRecord(u);
              appState.refresh();
              if (context.mounted) {
                toast(context, 'Profile updated.');
                Navigator.pop(context);
              }
            },
          ),
        ],
      ),
    ),
  );
}

class SearchFilterScreen extends StatefulWidget {
  const SearchFilterScreen({super.key});
  @override
  State<SearchFilterScreen> createState() => _SearchFilterScreenState();
}

class _SearchFilterScreenState extends State<SearchFilterScreen> {
  final q = TextEditingController();
  String priority = 'All';
  @override
  Widget build(BuildContext context) {
    final results = appState.patients.where((p) {
      final text = q.text.toLowerCase();
      return (p.name.toLowerCase().contains(text) ||
              p.disease.toLowerCase().contains(text) ||
              p.priorityLevel.toLowerCase().contains(text)) &&
          (priority == 'All' || p.priorityLevel == priority);
    }).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Search & Filter')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: TextField(
              controller: q,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search_rounded),
                labelText: 'Name, disease, priority, dates',
              ),
            ),
          ),
          SizedBox(
            height: 42,
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              scrollDirection: Axis.horizontal,
              children: ['All', 'Low', 'Medium', 'High', 'Urgent']
                  .map(
                    (f) => Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(f),
                        selected: priority == f,
                        onSelected: (_) => setState(() => priority = f),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: results.map((p) => _PatientCard(p)).toList(),
            ),
          ),
        ],
      ),
    );
  }
}
