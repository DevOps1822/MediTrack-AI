class AiSummary {
  AiSummary({
    required this.summary,
    required this.importantPoints,
    required this.disclaimer,
    this.isDemo = false,
  });
  final String summary;
  final List<String> importantPoints;
  final String disclaimer;
  final bool isDemo;
  Map<String, dynamic> toJson() => {
    'summary': summary,
    'importantPoints': importantPoints,
    'disclaimer': disclaimer,
    'isDemo': isDemo,
  };
  factory AiSummary.fromJson(Map<String, dynamic> json) => AiSummary(
    summary: json['summary'] ?? '',
    importantPoints: List<String>.from(json['importantPoints'] ?? const []),
    disclaimer:
        json['disclaimer'] ??
        'AI-generated summary. Doctor review is required.',
    isDemo: json['isDemo'] ?? false,
  );
}

class PrioritySuggestion {
  PrioritySuggestion({
    required this.priorityLevel,
    required this.reason,
    required this.safetyNote,
    this.isDemo = false,
  });
  final String priorityLevel;
  final String reason;
  final String safetyNote;
  final bool isDemo;
  Map<String, dynamic> toJson() => {
    'priorityLevel': priorityLevel,
    'reason': reason,
    'safetyNote': safetyNote,
    'isDemo': isDemo,
  };
  factory PrioritySuggestion.fromJson(
    Map<String, dynamic> json,
  ) => PrioritySuggestion(
    priorityLevel: json['priorityLevel'] ?? 'Low',
    reason: json['reason'] ?? '',
    safetyNote:
        json['safetyNote'] ??
        'This is not a diagnosis. It only assists with appointment prioritization.',
    isDemo: json['isDemo'] ?? false,
  );
}

class FollowUpSuggestion {
  FollowUpSuggestion({
    required this.suggestedPeriod,
    this.suggestedDate,
    required this.reason,
    required this.disclaimer,
    this.isDemo = false,
  });
  final String suggestedPeriod;
  final String? suggestedDate;
  final String reason;
  final String disclaimer;
  final bool isDemo;
  Map<String, dynamic> toJson() => {
    'suggestedPeriod': suggestedPeriod,
    'suggestedDate': suggestedDate,
    'reason': reason,
    'disclaimer': disclaimer,
    'isDemo': isDemo,
  };
  factory FollowUpSuggestion.fromJson(Map<String, dynamic> json) =>
      FollowUpSuggestion(
        suggestedPeriod: json['suggestedPeriod'] ?? 'within 1-2 weeks',
        suggestedDate: json['suggestedDate'],
        reason: json['reason'] ?? '',
        disclaimer:
            json['disclaimer'] ??
            'Doctor can accept, edit, or ignore this suggestion.',
        isDemo: json['isDemo'] ?? false,
      );
}
