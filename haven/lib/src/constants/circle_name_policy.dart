/// Policy constant for circle display names.
library;

/// Maximum length, in UTF-16 code units, of a circle's display name.
///
/// `nameCircleNameTooLongError` quotes this number verbatim; the two are
/// pinned together by `test/constants/circle_name_policy_test.dart`.
const int kCircleNameMaxLength = 50;
