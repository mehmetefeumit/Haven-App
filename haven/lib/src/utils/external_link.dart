/// Shared external-link launcher.
///
/// Extracted because the same handler was duplicated verbatim twice inside
/// `about_page.dart` alone, and the Privacy page adds several more call sites.
/// Centralising it keeps one rule in one place: a link failure never surfaces
/// a raw error to the user.
library;

import 'package:flutter/material.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens [url] in the platform browser, reporting failure with a generic
/// localized message.
///
/// Raw exception detail is written to [debugPrint] as a type name only and is
/// never shown to the user: launcher errors can carry internal state, and
/// Haven's security rules forbid surfacing it. [logTag] identifies the calling
/// screen in that debug line.
///
/// A malformed [url] is a no-op rather than an error, since there is nothing
/// actionable for the user in "this hard-coded constant did not parse".
///
/// The [ScaffoldMessenger] is captured before the `await` so no [BuildContext]
/// is used across an async gap.
Future<void> openExternalLink(
  BuildContext context,
  String url, {
  required String logTag,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final l10n = AppLocalizations.of(context);
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } on Object catch (e) {
    debugPrint('[$logTag] link launch failed: ${e.runtimeType}');
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.aboutLinkOpenError)),
    );
  }
}
