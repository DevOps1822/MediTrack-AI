class Appointment {
  Appointment({
    required this.id,
    required this.patientUserId,
    required this.patientName,
    required this.doctorNameOrSpecialty,
    required this.date,
    required this.time,
    required this.symptoms,
    required this.reason,
    this.doctorId,
    this.disease,
    this.status = 'pending',
    this.priorityLevel,
    this.priorityReason,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;
  final String patientUserId;
  String patientName;
  String? doctorId;
  String doctorNameOrSpecialty;
  DateTime date;
  String time;
  String symptoms;
  String reason;
  String? disease;
  String status;
  String? priorityLevel;
  String? priorityReason;
  DateTime createdAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'patientUserId': patientUserId,
    'patientName': patientName,
    'doctorId': doctorId,
    'doctorNameOrSpecialty': doctorNameOrSpecialty,
    'date': date.toIso8601String(),
    'time': time,
    'symptoms': symptoms,
    'reason': reason,
    'disease': disease,
    'status': status,
    'priorityLevel': priorityLevel,
    'priorityReason': priorityReason,
    'createdAt': createdAt.toIso8601String(),
  };

  factory Appointment.fromJson(Map<String, dynamic> json) => Appointment(
    id: json['id'],
    patientUserId: json['patientUserId'],
    patientName: json['patientName'],
    doctorId: json['doctorId'],
    doctorNameOrSpecialty: json['doctorNameOrSpecialty'],
    date: DateTime.parse(json['date']),
    time: json['time'],
    symptoms: json['symptoms'],
    reason: json['reason'],
    disease: json['disease'],
    status: json['status'] ?? 'pending',
    priorityLevel: json['priorityLevel'],
    priorityReason: json['priorityReason'],
    createdAt: DateTime.parse(json['createdAt']),
  );
}
