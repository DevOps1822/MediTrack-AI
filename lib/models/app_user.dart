class AppUser {
  AppUser({
    required this.id,
    required this.name,
    required this.email,
    required this.password,
    required this.phone,
    required this.role,
    this.doctorCodeVerified = false,
    this.specialization,
    this.age,
    this.gender,
    this.medicalHistory,
    this.profileImagePath,
  });

  final String id;
  String name;
  String email;
  String password;
  String phone;
  String role;
  bool doctorCodeVerified;
  String? specialization;
  int? age;
  String? gender;
  String? medicalHistory;
  String? profileImagePath;

  bool get isDoctor => role == 'Doctor';

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'email': email,
    'password': password,
    'phone': phone,
    'role': role,
    'doctorCodeVerified': doctorCodeVerified,
    'specialization': specialization,
    'age': age,
    'gender': gender,
    'medicalHistory': medicalHistory,
    'profileImagePath': profileImagePath,
  };

  factory AppUser.fromJson(Map<String, dynamic> json) => AppUser(
    id: json['id'],
    name: json['name'],
    email: json['email'],
    password: json['password'],
    phone: json['phone'],
    role: json['role'],
    doctorCodeVerified: json['doctorCodeVerified'] ?? false,
    specialization: json['specialization'],
    age: json['age'],
    gender: json['gender'],
    medicalHistory: json['medicalHistory'],
    profileImagePath: json['profileImagePath'],
  );
}
