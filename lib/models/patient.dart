import 'ai_models.dart';

class Patient {
  Patient({
    required this.id,
    required this.name,
    required this.age,
    required this.gender,
    required this.phone,
    required this.disease,
    required this.symptoms,
    required this.medicalHistory,
    required this.doctorNotes,
    this.lastVisitDate,
    this.email,
    this.nextAppointmentDate,
    this.aiSummary,
    this.priorityLevel = 'Low',
    this.priorityReason,
    this.followUpSuggestion,
    this.followUpDate,
    this.linkedPatientUserId,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  final String id;
  String name;
  int age;
  String gender;
  String phone;
  String? email;
  String disease;
  String symptoms;
  String medicalHistory;
  String doctorNotes;
  DateTime? lastVisitDate;
  DateTime? nextAppointmentDate;
  AiSummary? aiSummary;
  String priorityLevel;
  String? priorityReason;
  FollowUpSuggestion? followUpSuggestion;
  DateTime? followUpDate;
  String? linkedPatientUserId;
  DateTime createdAt;
  DateTime updatedAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'age': age,
    'gender': gender,
    'phone': phone,
    'phoneNormalized': phone.replaceAll(RegExp(r'\D'), ''),
    'email': email,
    'disease': disease,
    'symptoms': symptoms,
    'medicalHistory': medicalHistory,
    'doctorNotes': doctorNotes,
    'lastVisitDate': lastVisitDate?.toIso8601String(),
    'nextAppointmentDate': nextAppointmentDate?.toIso8601String(),
    'aiSummary': aiSummary?.toJson(),
    'priorityLevel': priorityLevel,
    'priorityReason': priorityReason,
    'followUpSuggestion': followUpSuggestion?.toJson(),
    'followUpDate': followUpDate?.toIso8601String(),
    'linkedPatientUserId': linkedPatientUserId,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory Patient.fromJson(Map<String, dynamic> json) => Patient(
    id: json['id'],
    name: json['name'],
    age: json['age'],
    gender: json['gender'],
    phone: json['phone'],
    email: json['email'],
    disease: json['disease'],
    symptoms: json['symptoms'],
    medicalHistory: json['medicalHistory'] ?? '',
    doctorNotes: json['doctorNotes'] ?? '',
    lastVisitDate: json['lastVisitDate'] == null
        ? null
        : DateTime.parse(json['lastVisitDate']),
    nextAppointmentDate: json['nextAppointmentDate'] == null
        ? null
        : DateTime.parse(json['nextAppointmentDate']),
    aiSummary: json['aiSummary'] == null
        ? null
        : AiSummary.fromJson(Map<String, dynamic>.from(json['aiSummary'])),
    priorityLevel: json['priorityLevel'] ?? 'Low',
    priorityReason: json['priorityReason'],
    followUpSuggestion: json['followUpSuggestion'] == null
        ? null
        : FollowUpSuggestion.fromJson(
            Map<String, dynamic>.from(json['followUpSuggestion']),
          ),
    followUpDate: json['followUpDate'] == null
        ? null
        : DateTime.parse(json['followUpDate']),
    linkedPatientUserId: json['linkedPatientUserId'],
    createdAt: DateTime.parse(json['createdAt']),
    updatedAt: DateTime.parse(json['updatedAt']),
  );
}
