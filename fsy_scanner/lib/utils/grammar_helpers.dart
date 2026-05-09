String sn(int count, String singular) =>
    count == 1 ? '$count $singular' : '$count ${singular}s';

String areIs(int count) => count == 1 ? 'is' : 'are';

String hasHave(int count) => count == 1 ? 'has' : 'have';

String verb(int count, String singular, String plural) =>
    count == 1 ? singular : plural;

String noun(int count, String singular, [String? plural]) =>
    count == 1 ? singular : (plural ?? '${singular}s');
