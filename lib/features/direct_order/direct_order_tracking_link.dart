import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'direct_order_copy.dart';

/// URLs are preserved verbatim and never passed through translation.
Uri? directOrderTrackingUri(String value) {
  if (RegExp(r'\s').hasMatch(value) || value.length > 2048) {
    return null;
  }
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      (uri.hasPort && uri.port != 443)) {
    return null;
  }
  return uri;
}

List<String> directOrderTrackingLinks(String text) =>
    RegExp(r'https://[^\s<>]+')
        .allMatches(text)
        .map(
          (match) =>
              match.group(0)!.replaceFirst(RegExp(r'[.,;!\)\]\}]+$'), ''),
        )
        .where((value) => directOrderTrackingUri(value) != null)
        .toSet()
        .toList(growable: false);

class DirectOrderTrackingLink extends StatelessWidget {
  const DirectOrderTrackingLink({
    super.key,
    required this.url,
    this.opener,
    this.copier,
  });
  final String url;
  final Future<bool> Function(Uri)? opener;
  final Future<void> Function(String)? copier;

  @override
  Widget build(BuildContext context) {
    final copy = DirectOrderCopy(Localizations.localeOf(context).languageCode);
    final uri = directOrderTrackingUri(url);
    if (uri == null) return SelectableText(url);
    void notice(String message) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }

    Future<void> copyLink() async {
      try {
        if (copier != null) {
          await copier!(url);
        } else {
          await Clipboard.setData(ClipboardData(text: url));
        }
        notice(copy.deliveryLinkCopied);
      } catch (_) {
        notice(copy.deliveryLinkCopyFailed);
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            FilledButton.icon(
              onPressed: () async {
                try {
                  final opened =
                      await (opener?.call(uri) ??
                          launchUrl(uri, mode: LaunchMode.externalApplication));
                  if (opened) return;
                } catch (_) {
                  /* Show the same recoverable fallback for launch errors. */
                }
                notice(copy.deliveryLinkOpenFailed);
              },
              icon: const Icon(Icons.open_in_new_rounded, size: 18),
              label: Text(copy.openGrab),
            ),
            OutlinedButton.icon(
              onPressed: copyLink,
              icon: const Icon(Icons.copy, size: 18),
              label: Text(copy.copyDeliveryLink),
            ),
          ],
        ),
        SelectableText(url, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
