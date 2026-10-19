/// Physical printers used by this PC. Store KDS routing is configured separately.
enum PrintStationMode {
  paperless,
  printer;

  bool allowsPurpose(String purpose) => this == printer || purpose == 'receipt';

  static PrintStationMode? fromValue(String? value) => switch (value) {
    'paperless' => paperless,
    'printer' => printer,
    _ => null,
  };
}
