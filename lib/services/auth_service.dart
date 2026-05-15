import 'package:firebase_auth/firebase_auth.dart';

import '../models/app_user.dart';
import 'firestore_service.dart';
import 'storage_service.dart';

class AuthService {
  static const doctorCode = 'MEDI2655';
  final _storage = StorageService.instance;
  final _firestore = FirestoreService.instance;
  final _firebaseAuth = FirebaseAuth.instance;

  AppUser? currentUser() {
    final id = _firebaseAuth.currentUser?.uid ?? _storage.loggedInUserId;
    if (id == null) return null;
    final users = _storage.getUsers();
    final byId = users.where((u) => u.id == id).firstOrNull;
    if (byId != null) return byId;
    final email = _firebaseAuth.currentUser?.email?.toLowerCase();
    if (email == null) return null;
    return users.where((u) => u.email.toLowerCase() == email).firstOrNull;
  }

  Future<AppUser?> currentUserAsync() async {
    final firebaseUser = _firebaseAuth.currentUser;
    final local = currentUser();
    if (local != null) return local;
    if (firebaseUser == null) return null;
    return await _firestore.getUserById(firebaseUser.uid) ??
        await _firestore.getUserByEmail(firebaseUser.email ?? '');
  }

  Future<AppUser> login({
    required String email,
    required String password,
    required String role,
    String? code,
  }) async {
    if (role == 'Doctor' && code != doctorCode) {
      throw 'Invalid doctor access code.';
    }
    try {
      final credential = await _firebaseAuth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      final firebaseUser = credential.user;
      if (firebaseUser == null) throw 'Login failed. Please try again.';
      final user =
          _profileForFirebaseUser(firebaseUser) ??
          await _firestore.getUserById(firebaseUser.uid) ??
          await _firestore.getUserByEmail(email.trim());
      if (user == null) {
        await _firebaseAuth.signOut();
        throw 'No MediTrack profile found for this account.';
      }
      if (user.role != role) {
        await _firebaseAuth.signOut();
        throw 'This account is registered as ${user.role}.';
      }
      if (role == 'Doctor' && !user.doctorCodeVerified) {
        await _firebaseAuth.signOut();
        throw 'Invalid doctor access code.';
      }
      await _cacheUser(user);
      await _storage.remember(email.trim(), password);
      await _storage.setLoggedInUserId(user.id);
      return user;
    } on FirebaseAuthException catch (e) {
      throw _friendlyAuthError(e);
    }
  }

  Future<AppUser> signup(AppUser user) async {
    final users = _storage.getUsers();
    if (users.any((u) => u.email.toLowerCase() == user.email.toLowerCase())) {
      throw 'Email is already registered.';
    }
    try {
      final credential = await _firebaseAuth.createUserWithEmailAndPassword(
        email: user.email.trim(),
        password: user.password,
      );
      final firebaseUser = credential.user;
      if (firebaseUser == null) throw 'Account could not be created.';
      await firebaseUser.updateDisplayName(user.name);
      final savedUser = AppUser(
        id: firebaseUser.uid,
        name: user.name,
        email: user.email.trim(),
        password: '',
        phone: user.phone,
        role: user.role,
        doctorCodeVerified: user.doctorCodeVerified,
        specialization: user.specialization,
        age: user.age,
        gender: user.gender,
        medicalHistory: user.medicalHistory,
        profileImagePath: user.profileImagePath,
      );
      await _firestore.saveUser(savedUser);
      await _cacheUser(savedUser);
      await _storage.remember(savedUser.email, user.password);
      await _storage.setLoggedInUserId(savedUser.id);
      return savedUser;
    } on FirebaseAuthException catch (e) {
      throw _friendlyAuthError(e);
    }
  }

  Future<void> update(AppUser user) async {
    final users = _storage.getUsers();
    final index = users.indexWhere((u) => u.id == user.id);
    if (index >= 0) {
      users[index] = user;
    } else {
      users.add(user);
    }
    await _storage.saveUsers(users);
    await _firestore.saveUser(user);
    if (_firebaseAuth.currentUser?.uid == user.id) {
      await _firebaseAuth.currentUser?.updateDisplayName(user.name);
    }
  }

  Future<void> logout() async {
    await _firebaseAuth.signOut();
    await _storage.setLoggedInUserId(null);
  }

  AppUser? _profileForFirebaseUser(User firebaseUser) {
    final users = _storage.getUsers();
    return users.where((u) => u.id == firebaseUser.uid).firstOrNull ??
        users
            .where(
              (u) =>
                  u.email.toLowerCase() ==
                  (firebaseUser.email ?? '').toLowerCase(),
            )
            .firstOrNull;
  }

  Future<void> _cacheUser(AppUser user) async {
    final users = _storage.getUsers();
    final index = users.indexWhere((u) => u.id == user.id);
    if (index >= 0) {
      users[index] = user;
    } else {
      users.add(user);
    }
    await _storage.saveUsers(users);
  }

  String _friendlyAuthError(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-email':
        return 'Enter a valid email address.';
      case 'user-disabled':
        return 'This account has been disabled.';
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-credential':
        return 'Invalid email or password.';
      case 'email-already-in-use':
        return 'Email is already registered.';
      case 'weak-password':
        return 'Password must be at least 6 characters.';
      case 'network-request-failed':
        return 'Network error. Please check your internet connection.';
      default:
        return 'Authentication failed. Please try again.';
    }
  }
}
