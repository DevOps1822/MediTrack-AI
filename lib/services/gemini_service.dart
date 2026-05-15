import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import '../models/ai_models.dart';
import '../models/appointment.dart';
import '../models/patient.dart';
import 'storage_service.dart';

class MissingApiKeyException implements Exception {
  const MissingApiKeyException();

  @override
  String toString() => 'Please set up an API key before using AI features.';
}

class GeminiService {
  static const _dartDefineApiKey = String.fromEnvironment('GEMINI_API_KEY');
  static const _model = 'gemini-1.5-flash';
  String get _apiKey {
    final stored = StorageService.instance.geminiApiKey;
    return stored.isNotEmpty ? stored : _dartDefineApiKey;
  }

  bool get hasApiKey => _apiKey.isNotEmpty;

  void _requireApiKey() {
    if (!hasApiKey) throw const MissingApiKeyException();
  }

  Future<AiSummary> generatePatientSummary(Patient p) async {
    _requireApiKey();
    try {
      final json = await _call(_summaryPrompt(p));
      final summary = AiSummary.fromJson(json);
      return _polishSummary(summary, p);
    } catch (_) {
      return _fallbackSummary(p);
    }
  }

  Future<PrioritySuggestion> classifyAppointmentPriority({
    Patient? patient,
    Appointment? appointment,
  }) async {
    final text =
        '${patient?.symptoms ?? appointment?.symptoms ?? ''} ${appointment?.reason ?? ''}'
            .toLowerCase();
    _requireApiKey();
    try {
      final json = await _call(
        _priorityPrompt(patient: patient, appointment: appointment),
      );
      final priority = PrioritySuggestion.fromJson(json);
      return _polishPriority(priority, text);
    } catch (_) {
      return _fallbackPriority(text);
    }
  }

  Future<FollowUpSuggestion> suggestFollowUp(Patient p) async {
    _requireApiKey();
    try {
      final json = await _call(_followUpPrompt(p));
      final followUp = FollowUpSuggestion.fromJson(json);
      return _polishFollowUp(followUp, p);
    } catch (_) {
      return _fallbackFollowUp(p);
    }
  }

  Future<Map<String, dynamic>> _call(String prompt) async {
    final uri = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/$_model:generateContent',
    );
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json', 'x-goog-api-key': _apiKey},
      body: jsonEncode({
        'contents': [
          {
            'role': 'user',
            'parts': [
              {'text': prompt},
            ],
          },
        ],
        'generationConfig': {
          'temperature': 0.2,
          'response_mime_type': 'application/json',
        },
      }),
    );
    if (response.statusCode >= 400) throw 'AI service unavailable.';
    final data = jsonDecode(response.body);
    final text =
        data['candidates']?[0]?['content']?['parts']?[0]?['text']?.toString() ??
        '{}';
    final cleaned = _extractJson(text);
    return Map<String, dynamic>.from(jsonDecode(cleaned));
  }

  String _extractJson(String text) {
    final cleaned = text.replaceAll('```json', '').replaceAll('```', '').trim();
    final start = cleaned.indexOf('{');
    final end = cleaned.lastIndexOf('}');
    if (start >= 0 && end > start) {
      return cleaned.substring(start, end + 1);
    }
    return cleaned;
  }

  String _summaryPrompt(Patient p) =>
      '''
Return only valid JSON:
{"summary":"short professional patient summary","importantPoints":["point 1","point 2"],"disclaimer":"AI-generated summary. Doctor review is required."}
Write concise, clinically professional, non-alarming text. Do not diagnose. Do not prescribe. Do not invent vitals, tests, medicines, or findings not provided. Mention uncertainty when data is missing. Use plain language suitable for a doctor reviewing a patient record.
Patient: ${p.name}, age ${p.age}, gender ${p.gender}, disease ${p.disease}, symptoms ${p.symptoms}, history ${p.medicalHistory}, notes ${p.doctorNotes}, last visit ${p.lastVisitDate}, next appointment ${p.nextAppointmentDate}.
''';

  String _priorityPrompt({Patient? patient, Appointment? appointment}) =>
      '''
Return only valid JSON:
{"priorityLevel":"Low|Medium|High|Urgent","reason":"short reason","safetyNote":"This is not a diagnosis. It only assists with appointment prioritization."}
Do not diagnose. Do not prescribe. Classify only scheduling priority. Use Urgent for chest pain, severe bleeding, breathing difficulty, unconsciousness, severe allergic reaction, severe injury. If information is incomplete, choose the safer reasonable priority and explain briefly.
Patient disease: ${patient?.disease ?? appointment?.disease}; symptoms: ${patient?.symptoms ?? appointment?.symptoms}; reason: ${appointment?.reason}; notes: ${patient?.doctorNotes}.
''';

  String _followUpPrompt(Patient p) =>
      '''
Return only valid JSON:
{"suggestedPeriod":"within 1-2 weeks","suggestedDate":"YYYY-MM-DD or null","reason":"short reason","disclaimer":"Doctor can accept, edit, or ignore this suggestion."}
Do not diagnose or prescribe. Suggest a conservative follow-up window based only on the provided data. If the symptoms sound urgent, recommend immediate clinical review rather than a routine follow-up.
Disease ${p.disease}, symptoms ${p.symptoms}, last visit ${p.lastVisitDate ?? 'not recorded'}, notes ${p.doctorNotes}.
''';

  AiSummary _fallbackSummary(Patient p, {bool isDemo = false}) => AiSummary(
    summary:
        '${p.name} is a ${p.age}-year-old ${p.gender.toLowerCase()} patient with a recorded condition of ${_clean(p.disease)}. Reported symptoms include ${_clean(p.symptoms)}. ${p.lastVisitDate == null ? 'No last visit date is recorded' : 'The last visit was on ${DateFormat('MMM d, yyyy').format(p.lastVisitDate!)}'}${p.nextAppointmentDate == null ? '' : ', with a next appointment planned for ${DateFormat('MMM d, yyyy').format(p.nextAppointmentDate!)}'}.',
    importantPoints: [
      'Review current symptoms and compare with previous visit notes.',
      if (p.medicalHistory.trim().isNotEmpty)
        'Consider the documented medical history during clinical review.',
      if (p.doctorNotes.trim().isNotEmpty)
        'Recheck doctor notes before finalizing the care plan.',
      'Confirm follow-up timing based on clinical judgment.',
    ],
    disclaimer: 'AI-generated summary. Doctor review is required.',
    isDemo: isDemo,
  );

  PrioritySuggestion _fallbackPriority(String text, {bool isDemo = false}) {
    final level = _safePriorityLevel(text);
    return PrioritySuggestion(
      priorityLevel: level,
      reason: switch (level) {
        'Urgent' =>
          'Reported symptoms may need immediate clinical attention or urgent appointment review.',
        'High' =>
          'Reported symptoms may require earlier review than a routine appointment.',
        'Medium' =>
          'Symptoms should be reviewed in a timely way, but no urgent red flags were identified from the entered text.',
        _ =>
          'Entered information suggests routine scheduling unless symptoms worsen.',
      },
      safetyNote:
          'This is not a diagnosis. It only assists with appointment prioritization.',
      isDemo: isDemo,
    );
  }

  FollowUpSuggestion _fallbackFollowUp(Patient p, {bool isDemo = false}) {
    final text = '${p.disease} ${p.symptoms} ${p.doctorNotes}'.toLowerCase();
    final urgent = _safePriorityLevel(text) == 'Urgent';
    final days = urgent
        ? 1
        : text.contains('pain') || text.contains('dizziness')
        ? 7
        : 14;
    final date = DateTime.now().add(Duration(days: days));
    return FollowUpSuggestion(
      suggestedPeriod: urgent
          ? 'as soon as possible'
          : days == 7
          ? 'within 1 week'
          : 'within 1-2 weeks',
      suggestedDate: DateFormat('yyyy-MM-dd').format(date),
      reason: urgent
          ? 'Symptoms include potential red flags, so prompt clinical review is safer than routine follow-up.'
          : 'A follow-up helps reassess ${_clean(p.disease)} symptoms after the recent visit.',
      disclaimer: 'Doctor can accept, edit, or ignore this suggestion.',
      isDemo: isDemo,
    );
  }

  AiSummary _polishSummary(AiSummary value, Patient p) {
    if (value.summary.trim().length < 30) return _fallbackSummary(p);
    final points = value.importantPoints
        .where((p) => p.trim().isNotEmpty)
        .toList();
    return AiSummary(
      summary: value.summary.trim(),
      importantPoints: points.isEmpty
          ? _fallbackSummary(p).importantPoints
          : points.take(5).toList(),
      disclaimer: 'AI-generated summary. Doctor review is required.',
      isDemo: value.isDemo,
    );
  }

  PrioritySuggestion _polishPriority(PrioritySuggestion value, String text) {
    final allowed = ['Low', 'Medium', 'High', 'Urgent'];
    final safeLevel = _safePriorityLevel(text);
    final level = allowed.contains(value.priorityLevel)
        ? value.priorityLevel
        : safeLevel;
    return PrioritySuggestion(
      priorityLevel: safeLevel == 'Urgent' ? 'Urgent' : level,
      reason: value.reason.trim().isEmpty
          ? _fallbackPriority(text).reason
          : value.reason.trim(),
      safetyNote:
          'This is not a diagnosis. It only assists with appointment prioritization.',
      isDemo: value.isDemo,
    );
  }

  FollowUpSuggestion _polishFollowUp(FollowUpSuggestion value, Patient p) {
    final fallback = _fallbackFollowUp(p);
    final date =
        value.suggestedDate == null || value.suggestedDate!.trim().isEmpty
        ? fallback.suggestedDate
        : value.suggestedDate;
    return FollowUpSuggestion(
      suggestedPeriod: value.suggestedPeriod.trim().isEmpty
          ? fallback.suggestedPeriod
          : value.suggestedPeriod.trim(),
      suggestedDate: date,
      reason: value.reason.trim().isEmpty
          ? fallback.reason
          : value.reason.trim(),
      disclaimer: 'Doctor can accept, edit, or ignore this suggestion.',
      isDemo: value.isDemo,
    );
  }

  String _safePriorityLevel(String text) {
    final urgentWords = [
      'chest pain',
      'severe bleeding',
      'breathing difficulty',
      'shortness of breath',
      'unconscious',
      'fainting',
      'severe allergic',
      'severe injury',
      'stroke',
      'seizure',
    ];
    if (urgentWords.any(text.contains)) return 'Urgent';
    if (text.contains('dizziness') ||
        text.contains('high fever') ||
        text.contains('severe pain') ||
        text.contains('worsening')) {
      return 'High';
    }
    if (text.trim().isEmpty || text.contains('routine')) return 'Low';
    return 'Medium';
  }

  String _clean(String value) =>
      value.trim().isEmpty ? 'not specified' : value.trim();
}
