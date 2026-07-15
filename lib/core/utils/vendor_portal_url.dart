Uri? validatedVendorPortalUri(String? rawUrl) {
  final value = rawUrl?.trim();
  if (value == null || value.isEmpty) return null;

  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme.toLowerCase() != 'https' ||
      !uri.hasAuthority ||
      uri.userInfo.isNotEmpty ||
      (uri.hasPort && uri.port != 443)) {
    return null;
  }

  final host = uri.host.toLowerCase();
  if (host != 'wetax.com.vn' && !host.endsWith('.wetax.com.vn')) {
    return null;
  }

  return uri;
}
